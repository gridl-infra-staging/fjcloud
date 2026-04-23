//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/repos/pg_tenant_repo.rs.
use async_trait::async_trait;
use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

use crate::models::tenant::{CustomerTenant, CustomerTenantSummary};
use crate::repos::error::{is_unique_violation, RepoError};
use crate::repos::tenant_repo::TenantRepo;

pub struct PgTenantRepo {
    pool: PgPool,
}

impl PgTenantRepo {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl TenantRepo for PgTenantRepo {
    /// Inserts a new tenant mapping. Unique violation on (customer_id, tenant_id)
    /// returns `Conflict`. Uses INSERT ... RETURNING for single round-trip.
    async fn create(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
        deployment_id: Uuid,
    ) -> Result<CustomerTenant, RepoError> {
        sqlx::query_as::<_, CustomerTenant>(
            "INSERT INTO customer_tenants (customer_id, tenant_id, deployment_id) \
             VALUES ($1, $2, $3) RETURNING *",
        )
        .bind(customer_id)
        .bind(tenant_id)
        .bind(deployment_id)
        .fetch_one(&self.pool)
        .await
        .map_err(|e| {
            if is_unique_violation(&e) {
                RepoError::Conflict(format!(
                    "index '{tenant_id}' already exists for this customer"
                ))
            } else {
                RepoError::Other(e.to_string())
            }
        })
    }

    /// Joins customer_tenants with customer_deployments to include region,
    /// flapjack_url, and health_status. Excludes terminated deployments.
    /// Ordered by created_at DESC.
    async fn find_by_customer(
        &self,
        customer_id: Uuid,
    ) -> Result<Vec<CustomerTenantSummary>, RepoError> {
        sqlx::query_as::<_, CustomerTenantSummary>(
            "SELECT ct.customer_id, ct.tenant_id, ct.deployment_id, ct.created_at, \
                    cd.region, cd.flapjack_url, cd.health_status, \
                    ct.tier, ct.last_accessed_at, ct.cold_snapshot_id, ct.service_type \
             FROM customer_tenants ct \
             JOIN customer_deployments cd ON ct.deployment_id = cd.id \
             WHERE ct.customer_id = $1 AND cd.status != 'terminated' \
             ORDER BY ct.created_at DESC",
        )
        .bind(customer_id)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    /// Single-row join lookup by (customer_id, tenant_id) with deployment
    /// info. Excludes terminated deployments.
    async fn find_by_name(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
    ) -> Result<Option<CustomerTenantSummary>, RepoError> {
        sqlx::query_as::<_, CustomerTenantSummary>(
            "SELECT ct.customer_id, ct.tenant_id, ct.deployment_id, ct.created_at, \
                    cd.region, cd.flapjack_url, cd.health_status, \
                    ct.tier, ct.last_accessed_at, ct.cold_snapshot_id, ct.service_type \
             FROM customer_tenants ct \
             JOIN customer_deployments cd ON ct.deployment_id = cd.id \
             WHERE ct.customer_id = $1 AND ct.tenant_id = $2 AND cd.status != 'terminated'",
        )
        .bind(customer_id)
        .bind(tenant_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn delete(&self, customer_id: Uuid, tenant_id: &str) -> Result<bool, RepoError> {
        let result =
            sqlx::query("DELETE FROM customer_tenants WHERE customer_id = $1 AND tenant_id = $2")
                .bind(customer_id)
                .bind(tenant_id)
                .execute(&self.pool)
                .await
                .map_err(|e| RepoError::Other(e.to_string()))?;

        Ok(result.rows_affected() > 0)
    }

    async fn count_by_customer(&self, customer_id: Uuid) -> Result<i64, RepoError> {
        let row: (i64,) = sqlx::query_as(
            "SELECT COUNT(*) FROM customer_tenants ct \
                 JOIN customer_deployments cd ON ct.deployment_id = cd.id \
                 WHERE ct.customer_id = $1 AND cd.status != 'terminated'",
        )
        .bind(customer_id)
        .fetch_one(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        Ok(row.0)
    }

    async fn find_by_deployment(
        &self,
        deployment_id: Uuid,
    ) -> Result<Vec<CustomerTenant>, RepoError> {
        sqlx::query_as::<_, CustomerTenant>(
            "SELECT * FROM customer_tenants WHERE deployment_id = $1 ORDER BY created_at DESC",
        )
        .bind(deployment_id)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    /// Updates vm_id for a tenant. Returns `NotFound` if no row matches
    /// the (customer_id, tenant_id) pair.
    async fn set_vm_id(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
        vm_id: Uuid,
    ) -> Result<(), RepoError> {
        let result = sqlx::query(
            "UPDATE customer_tenants SET vm_id = $1 WHERE customer_id = $2 AND tenant_id = $3",
        )
        .bind(vm_id)
        .bind(customer_id)
        .bind(tenant_id)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        if result.rows_affected() == 0 {
            return Err(RepoError::NotFound);
        }
        Ok(())
    }

    /// Updates the migration tier column. Returns `NotFound` if no row
    /// matches the (customer_id, tenant_id) pair.
    async fn set_tier(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
        tier: &str,
    ) -> Result<(), RepoError> {
        let result = sqlx::query(
            "UPDATE customer_tenants SET tier = $1 WHERE customer_id = $2 AND tenant_id = $3",
        )
        .bind(tier)
        .bind(customer_id)
        .bind(tenant_id)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        if result.rows_affected() == 0 {
            return Err(RepoError::NotFound);
        }
        Ok(())
    }

    async fn list_by_vm(&self, vm_id: Uuid) -> Result<Vec<CustomerTenant>, RepoError> {
        sqlx::query_as::<_, CustomerTenant>(
            "SELECT * FROM customer_tenants WHERE vm_id = $1 ORDER BY created_at DESC",
        )
        .bind(vm_id)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn list_migrating(&self) -> Result<Vec<CustomerTenant>, RepoError> {
        sqlx::query_as::<_, CustomerTenant>(
            "SELECT * FROM customer_tenants WHERE tier = 'migrating' ORDER BY created_at DESC",
        )
        .fetch_all(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn list_unplaced(&self) -> Result<Vec<CustomerTenant>, RepoError> {
        sqlx::query_as::<_, CustomerTenant>(
            "SELECT * FROM customer_tenants WHERE vm_id IS NULL ORDER BY created_at DESC",
        )
        .fetch_all(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn list_active_global(&self) -> Result<Vec<CustomerTenant>, RepoError> {
        sqlx::query_as::<_, CustomerTenant>(
            "SELECT ct.* FROM customer_tenants ct \
             JOIN customer_deployments cd ON ct.deployment_id = cd.id \
             WHERE cd.status != 'terminated' \
             ORDER BY ct.created_at DESC",
        )
        .fetch_all(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    /// Joins with deployments to find a tenant by name without a customer
    /// filter. Returns at most one row (LIMIT 1). Excludes terminated.
    async fn find_by_tenant_id_global(
        &self,
        tenant_id: &str,
    ) -> Result<Option<CustomerTenantSummary>, RepoError> {
        sqlx::query_as::<_, CustomerTenantSummary>(
            "SELECT ct.customer_id, ct.tenant_id, ct.deployment_id, ct.created_at, \
                    cd.region, cd.flapjack_url, cd.health_status, \
                    ct.tier, ct.last_accessed_at, ct.cold_snapshot_id, ct.service_type \
             FROM customer_tenants ct \
             JOIN customer_deployments cd ON ct.deployment_id = cd.id \
             WHERE ct.tenant_id = $1 AND cd.status != 'terminated' \
             LIMIT 1",
        )
        .bind(tenant_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn find_raw(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
    ) -> Result<Option<CustomerTenant>, RepoError> {
        sqlx::query_as::<_, CustomerTenant>(
            "SELECT * FROM customer_tenants WHERE customer_id = $1 AND tenant_id = $2",
        )
        .bind(customer_id)
        .bind(tenant_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    /// Overwrites the JSONB resource_quota column. Returns `NotFound` if
    /// no row matches the (customer_id, tenant_id) pair.
    async fn set_resource_quota(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
        quota: serde_json::Value,
    ) -> Result<(), RepoError> {
        let result = sqlx::query(
            "UPDATE customer_tenants SET resource_quota = $1 \
             WHERE customer_id = $2 AND tenant_id = $3",
        )
        .bind(&quota)
        .bind(customer_id)
        .bind(tenant_id)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        if result.rows_affected() == 0 {
            return Err(RepoError::NotFound);
        }
        Ok(())
    }

    async fn list_raw_by_customer(
        &self,
        customer_id: Uuid,
    ) -> Result<Vec<CustomerTenant>, RepoError> {
        sqlx::query_as::<_, CustomerTenant>(
            "SELECT * FROM customer_tenants WHERE customer_id = $1 ORDER BY created_at DESC",
        )
        .bind(customer_id)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    /// Batch-updates last_accessed_at using UNNEST arrays joined to the
    /// tenant table. No-ops on empty input.
    async fn update_last_accessed_batch(
        &self,
        updates: &[(Uuid, String, DateTime<Utc>)],
    ) -> Result<(), RepoError> {
        if updates.is_empty() {
            return Ok(());
        }

        let customer_ids: Vec<Uuid> = updates
            .iter()
            .map(|(customer_id, _, _)| *customer_id)
            .collect();
        let tenant_ids: Vec<&str> = updates
            .iter()
            .map(|(_, tenant_id, _)| tenant_id.as_str())
            .collect();
        let timestamps: Vec<DateTime<Utc>> = updates.iter().map(|(_, _, ts)| *ts).collect();

        sqlx::query(
            "UPDATE customer_tenants AS ct \
             SET last_accessed_at = u.last_accessed_at \
             FROM (
                 SELECT * FROM UNNEST($1::uuid[], $2::text[], $3::timestamptz[]) \
                 AS t(customer_id, tenant_id, last_accessed_at)
             ) AS u \
             WHERE ct.customer_id = u.customer_id AND ct.tenant_id = u.tenant_id",
        )
        .bind(customer_ids)
        .bind(tenant_ids)
        .bind(timestamps)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        Ok(())
    }

    /// Sets or clears the cold_snapshot_id FK on a tenant. Returns
    /// `NotFound` if no row matches the (customer_id, tenant_id) pair.
    async fn set_cold_snapshot_id(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
        snapshot_id: Option<Uuid>,
    ) -> Result<(), RepoError> {
        let result = sqlx::query(
            "UPDATE customer_tenants SET cold_snapshot_id = $3 \
             WHERE customer_id = $1 AND tenant_id = $2",
        )
        .bind(customer_id)
        .bind(tenant_id)
        .bind(snapshot_id)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        if result.rows_affected() == 0 {
            return Err(RepoError::NotFound);
        }
        Ok(())
    }

    /// Sets vm_id to NULL (unplaces the tenant from its VM). Returns
    /// `NotFound` if no row matches the (customer_id, tenant_id) pair.
    async fn clear_vm_id(&self, customer_id: Uuid, tenant_id: &str) -> Result<(), RepoError> {
        let result = sqlx::query(
            "UPDATE customer_tenants SET vm_id = NULL \
             WHERE customer_id = $1 AND tenant_id = $2",
        )
        .bind(customer_id)
        .bind(tenant_id)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        if result.rows_affected() == 0 {
            return Err(RepoError::NotFound);
        }
        Ok(())
    }
}
