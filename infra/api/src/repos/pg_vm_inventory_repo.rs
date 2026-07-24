use async_trait::async_trait;
use sqlx::{PgPool, Postgres, Transaction};
use uuid::Uuid;

use crate::models::vm_inventory::{NewVmInventory, VmInventory};
use crate::repos::advisory_lock::{advisory_lock, vm_provisioning_lock_key, AdvisoryLockGuard};
use crate::repos::error::RepoError;
use crate::repos::vm_inventory_repo::{
    validate_vm_retirement_candidate, VmDecommissionResult, VmInventoryRepo,
    VmRetirementAssessment, VmRetirementBlocker, VmRetirementCandidateStatus, VmRetirementConflict,
};

#[derive(sqlx::FromRow)]
struct LockedVmIdentity {
    hostname: String,
    status: String,
}

pub struct PgVmInventoryRepo {
    pool: PgPool,
}

impl PgVmInventoryRepo {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    async fn lock_vm_for_retirement(
        transaction: &mut Transaction<'_, Postgres>,
        id: Uuid,
    ) -> Result<Option<LockedVmIdentity>, RepoError> {
        sqlx::query_as(
            "SELECT hostname, status
             FROM vm_inventory
             WHERE id = $1
             FOR UPDATE",
        )
        .bind(id)
        .fetch_optional(&mut **transaction)
        .await
        .map_err(Self::repo_error)
    }

    async fn load_retirement_blockers(
        transaction: &mut Transaction<'_, Postgres>,
        id: Uuid,
    ) -> Result<Vec<VmRetirementBlocker>, RepoError> {
        sqlx::query_as(
            "SELECT owner, reference_column, blocker_count AS count
             FROM vm_inventory_reference_blockers($1)
             WHERE blocker_count > 0
             ORDER BY owner, reference_column",
        )
        .bind(id)
        .fetch_all(&mut **transaction)
        .await
        .map_err(Self::repo_error)
    }

    fn repo_error(error: sqlx::Error) -> RepoError {
        RepoError::Other(error.to_string())
    }
}

#[async_trait]
impl VmInventoryRepo for PgVmInventoryRepo {
    async fn lock_provisioning_hostname(
        &self,
        hostname: &str,
    ) -> Result<AdvisoryLockGuard<'_>, RepoError> {
        let key = vm_provisioning_lock_key(&self.pool, hostname).await?;
        advisory_lock(&self.pool, key).await
    }

    /// Lists VMs with `active` status, optionally filtered by region,
    /// ordered by creation time.
    async fn list_active(&self, region: Option<&str>) -> Result<Vec<VmInventory>, RepoError> {
        match region {
            Some(r) => {
                sqlx::query_as::<_, VmInventory>(
                    "SELECT * FROM vm_inventory WHERE status = 'active' AND region = $1 ORDER BY created_at",
                )
                .bind(r)
                .fetch_all(&self.pool)
                .await
            }
            None => {
                sqlx::query_as::<_, VmInventory>(
                    "SELECT * FROM vm_inventory WHERE status = 'active' ORDER BY created_at",
                )
                .fetch_all(&self.pool)
                .await
            }
        }
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn list_non_decommissioned(&self) -> Result<Vec<VmInventory>, RepoError> {
        sqlx::query_as::<_, VmInventory>(
            "SELECT * FROM vm_inventory WHERE status != 'decommissioned' ORDER BY created_at",
        )
        .fetch_all(&self.pool)
        .await
        .map_err(Self::repo_error)
    }

    async fn get(&self, id: Uuid) -> Result<Option<VmInventory>, RepoError> {
        sqlx::query_as::<_, VmInventory>("SELECT * FROM vm_inventory WHERE id = $1")
            .bind(id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn create(&self, vm: NewVmInventory) -> Result<VmInventory, RepoError> {
        sqlx::query_as::<_, VmInventory>(
            "INSERT INTO vm_inventory (region, provider, hostname, flapjack_url, capacity) \
             VALUES ($1, $2, $3, $4, $5) RETURNING *",
        )
        .bind(&vm.region)
        .bind(&vm.provider)
        .bind(&vm.hostname)
        .bind(&vm.flapjack_url)
        .bind(&vm.capacity)
        .fetch_one(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn update_load(&self, id: Uuid, load: serde_json::Value) -> Result<(), RepoError> {
        sqlx::query(
            "UPDATE vm_inventory \
             SET current_load = $1, load_scraped_at = NOW(), updated_at = NOW() \
             WHERE id = $2",
        )
        .bind(&load)
        .bind(id)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;
        Ok(())
    }

    async fn set_status(&self, id: Uuid, status: &str) -> Result<(), RepoError> {
        sqlx::query("UPDATE vm_inventory SET status = $1, updated_at = NOW() WHERE id = $2")
            .bind(status)
            .bind(id)
            .execute(&self.pool)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))?;
        Ok(())
    }

    async fn retirement_blockers(
        &self,
        id: Uuid,
        expected_hostname: &str,
    ) -> Result<VmRetirementAssessment, RepoError> {
        let mut transaction = self.pool.begin().await.map_err(Self::repo_error)?;
        let vm = Self::lock_vm_for_retirement(&mut transaction, id).await?;
        let candidate = vm
            .as_ref()
            .map(|vm| (vm.hostname.as_str(), vm.status.as_str()));
        let assessment = match validate_vm_retirement_candidate(id, expected_hostname, candidate) {
            Err(conflict) => VmRetirementAssessment::Conflict(conflict),
            Ok(VmRetirementCandidateStatus::Decommissioned) => {
                VmRetirementAssessment::Conflict(VmRetirementConflict::InvalidStatus {
                    actual_status: VmRetirementCandidateStatus::Decommissioned
                        .as_str()
                        .to_string(),
                })
            }
            Ok(VmRetirementCandidateStatus::Active) => {
                match Self::load_retirement_blockers(&mut transaction, id).await? {
                    blockers if blockers.is_empty() => VmRetirementAssessment::Eligible,
                    blockers => VmRetirementAssessment::Blocked(blockers),
                }
            }
        };

        transaction.commit().await.map_err(Self::repo_error)?;
        Ok(assessment)
    }

    async fn decommission_if_unreferenced(
        &self,
        id: Uuid,
        expected_hostname: &str,
    ) -> Result<VmDecommissionResult, RepoError> {
        let mut transaction = self.pool.begin().await.map_err(Self::repo_error)?;
        let vm = Self::lock_vm_for_retirement(&mut transaction, id).await?;
        let candidate = vm
            .as_ref()
            .map(|vm| (vm.hostname.as_str(), vm.status.as_str()));
        let result = match validate_vm_retirement_candidate(id, expected_hostname, candidate) {
            Err(conflict) => VmDecommissionResult::Conflict(conflict),
            Ok(VmRetirementCandidateStatus::Decommissioned) => {
                VmDecommissionResult::AlreadyDecommissioned
            }
            Ok(VmRetirementCandidateStatus::Active) => {
                let blockers = Self::load_retirement_blockers(&mut transaction, id).await?;
                if blockers.is_empty() {
                    let update = sqlx::query(
                        "UPDATE vm_inventory
                     SET status = 'decommissioned', updated_at = NOW()
                     WHERE id = $1 AND status = 'active'",
                    )
                    .bind(id)
                    .execute(&mut *transaction)
                    .await
                    .map_err(Self::repo_error)?;
                    if update.rows_affected() != 1 {
                        return Err(RepoError::Other(
                            "locked active VM was not decommissioned".to_string(),
                        ));
                    }
                    VmDecommissionResult::Decommissioned
                } else {
                    VmDecommissionResult::Blocked(blockers)
                }
            }
        };

        transaction.commit().await.map_err(Self::repo_error)?;
        Ok(result)
    }

    async fn find_by_hostname(&self, hostname: &str) -> Result<Option<VmInventory>, RepoError> {
        sqlx::query_as::<_, VmInventory>("SELECT * FROM vm_inventory WHERE hostname = $1")
            .bind(hostname)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))
    }
}
