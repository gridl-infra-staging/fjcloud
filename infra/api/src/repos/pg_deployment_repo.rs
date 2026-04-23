//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/repos/pg_deployment_repo.rs.
use async_trait::async_trait;
use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

use crate::models::Deployment;
use crate::repos::deployment_repo::DeploymentRepo;
use crate::repos::error::{is_unique_violation, RepoError};

pub struct PgDeploymentRepo {
    pool: PgPool,
}

impl PgDeploymentRepo {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl DeploymentRepo for PgDeploymentRepo {
    /// Lists deployments for a customer ordered by created_at DESC.
    /// Optionally includes terminated deployments.
    async fn list_by_customer(
        &self,
        customer_id: Uuid,
        include_terminated: bool,
    ) -> Result<Vec<Deployment>, RepoError> {
        let deployments = if include_terminated {
            sqlx::query_as::<_, Deployment>(
                "SELECT * FROM customer_deployments WHERE customer_id = $1 ORDER BY created_at DESC",
            )
            .bind(customer_id)
            .fetch_all(&self.pool)
            .await
        } else {
            sqlx::query_as::<_, Deployment>(
                "SELECT * FROM customer_deployments WHERE customer_id = $1 AND status != 'terminated' ORDER BY created_at DESC",
            )
            .bind(customer_id)
            .fetch_all(&self.pool)
            .await
        };

        deployments.map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn find_by_id(&self, id: Uuid) -> Result<Option<Deployment>, RepoError> {
        sqlx::query_as::<_, Deployment>("SELECT * FROM customer_deployments WHERE id = $1")
            .bind(id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))
    }

    /// INSERT RETURNING for a new deployment. Unique violation on node_id
    /// returns `Conflict`.
    async fn create(
        &self,
        customer_id: Uuid,
        node_id: &str,
        region: &str,
        vm_type: &str,
        vm_provider: &str,
        ip_address: Option<&str>,
    ) -> Result<Deployment, RepoError> {
        sqlx::query_as::<_, Deployment>(
            "INSERT INTO customer_deployments (customer_id, node_id, region, vm_type, vm_provider, ip_address) \
             VALUES ($1, $2, $3, $4, $5, $6) RETURNING *",
        )
        .bind(customer_id)
        .bind(node_id)
        .bind(region)
        .bind(vm_type)
        .bind(vm_provider)
        .bind(ip_address)
        .fetch_one(&self.pool)
        .await
        .map_err(|e| {
            if is_unique_violation(&e) {
                RepoError::Conflict("node_id already exists".into())
            } else {
                RepoError::Other(e.to_string())
            }
        })
    }

    /// COALESCE-based partial update for ip_address and status. Auto-sets
    /// terminated_at when status becomes 'terminated'. Skips already-terminated rows.
    async fn update(
        &self,
        id: Uuid,
        ip_address: Option<&str>,
        status: Option<&str>,
    ) -> Result<Option<Deployment>, RepoError> {
        sqlx::query_as::<_, Deployment>(
            "UPDATE customer_deployments SET \
                ip_address = COALESCE($2, ip_address), \
                status = COALESCE($3, status), \
                terminated_at = CASE WHEN $3 = 'terminated' THEN NOW() ELSE terminated_at END \
             WHERE id = $1 AND status != 'terminated' \
             RETURNING *",
        )
        .bind(id)
        .bind(ip_address)
        .bind(status)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn terminate(&self, id: Uuid) -> Result<bool, RepoError> {
        let result = sqlx::query(
            "UPDATE customer_deployments SET status = 'terminated', terminated_at = NOW() \
             WHERE id = $1 AND status != 'terminated'",
        )
        .bind(id)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        Ok(result.rows_affected() > 0)
    }

    async fn list_active(&self) -> Result<Vec<Deployment>, RepoError> {
        sqlx::query_as::<_, Deployment>(
            "SELECT * FROM customer_deployments \
             WHERE status != 'terminated' AND flapjack_url IS NOT NULL \
             ORDER BY created_at DESC",
        )
        .fetch_all(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    /// COALESCE-based partial update for ip_address and status. Auto-sets
    /// terminated_at when status becomes 'terminated'. Skips already-terminated rows.health.
    async fn update_health(
        &self,
        id: Uuid,
        health_status: &str,
        last_health_check_at: DateTime<Utc>,
    ) -> Result<(), RepoError> {
        let result = sqlx::query(
            "UPDATE customer_deployments \
             SET health_status = $2, last_health_check_at = $3 \
             WHERE id = $1",
        )
        .bind(id)
        .bind(health_status)
        .bind(last_health_check_at)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        if result.rows_affected() == 0 {
            Err(RepoError::NotFound)
        } else {
            Ok(())
        }
    }

    /// Atomic CAS claim: writes a lock marker to provider_vm_id only when
    /// status is 'provisioning' and provider_vm_id is NULL. Returns true
    /// for the first caller; concurrent callers receive false.
    async fn claim_provisioning(&self, id: Uuid) -> Result<bool, RepoError> {
        let lock_marker = format!("provisioning-lock:{id}");
        let result = sqlx::query(
            "UPDATE customer_deployments \
             SET provider_vm_id = $2 \
             WHERE id = $1 \
               AND status = 'provisioning' \
               AND provider_vm_id IS NULL",
        )
        .bind(id)
        .bind(lock_marker)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        Ok(result.rows_affected() == 1)
    }

    /// Sets status to 'failed' and NULLs all transient provisioning fields
    /// (provider_vm_id, ip_address, hostname, flapjack_url). Only acts
    /// on deployments still in 'provisioning' status.
    async fn mark_failed_provisioning(&self, id: Uuid) -> Result<bool, RepoError> {
        let result = sqlx::query(
            "UPDATE customer_deployments \
             SET status = 'failed', \
                 provider_vm_id = NULL, \
                 ip_address = NULL, \
                 hostname = NULL, \
                 flapjack_url = NULL \
             WHERE id = $1 \
               AND status = 'provisioning'",
        )
        .bind(id)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        Ok(result.rows_affected() == 1)
    }

    /// COALESCE-based partial update for ip_address and status. Auto-sets
    /// terminated_at when status becomes 'terminated'. Skips already-terminated rows.provisioning.
    async fn update_provisioning(
        &self,
        id: Uuid,
        provider_vm_id: &str,
        ip_address: &str,
        hostname: &str,
        flapjack_url: &str,
    ) -> Result<Option<Deployment>, RepoError> {
        sqlx::query_as::<_, Deployment>(
            "UPDATE customer_deployments SET \
                provider_vm_id = $2, \
                ip_address = $3, \
                hostname = $4, \
                flapjack_url = $5 \
             WHERE id = $1 \
             RETURNING *",
        )
        .bind(id)
        .bind(provider_vm_id)
        .bind(ip_address)
        .bind(hostname)
        .bind(flapjack_url)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }
}
