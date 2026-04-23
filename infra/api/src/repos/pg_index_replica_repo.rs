//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/repos/pg_index_replica_repo.rs.
use async_trait::async_trait;
use sqlx::PgPool;
use uuid::Uuid;

use crate::models::index_replica::IndexReplica;
use crate::repos::error::{is_unique_violation, RepoError};
use crate::repos::index_replica_repo::IndexReplicaRepo;

pub struct PgIndexReplicaRepo {
    pool: PgPool,
}

impl PgIndexReplicaRepo {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl IndexReplicaRepo for PgIndexReplicaRepo {
    /// Inserts a new index replica and returns the created record.
    /// Returns `Conflict` if a replica already exists on the target VM.
    async fn create(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
        primary_vm_id: Uuid,
        replica_vm_id: Uuid,
        replica_region: &str,
    ) -> Result<IndexReplica, RepoError> {
        sqlx::query_as::<_, IndexReplica>(
            "INSERT INTO index_replicas (customer_id, tenant_id, primary_vm_id, replica_vm_id, replica_region) \
             VALUES ($1, $2, $3, $4, $5) RETURNING *",
        )
        .bind(customer_id)
        .bind(tenant_id)
        .bind(primary_vm_id)
        .bind(replica_vm_id)
        .bind(replica_region)
        .fetch_one(&self.pool)
        .await
        .map_err(|e| {
            if is_unique_violation(&e) {
                RepoError::Conflict("replica already exists on this VM".into())
            } else {
                RepoError::Other(e.to_string())
            }
        })
    }

    async fn get(&self, id: Uuid) -> Result<Option<IndexReplica>, RepoError> {
        sqlx::query_as::<_, IndexReplica>("SELECT * FROM index_replicas WHERE id = $1")
            .bind(id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn list_by_index(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
    ) -> Result<Vec<IndexReplica>, RepoError> {
        sqlx::query_as::<_, IndexReplica>(
            "SELECT * FROM index_replicas WHERE customer_id = $1 AND tenant_id = $2 ORDER BY created_at",
        )
        .bind(customer_id)
        .bind(tenant_id)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    /// Lists replicas for an index filtered to `active` status only,
    /// ordered by creation time.
    async fn list_healthy_by_index(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
    ) -> Result<Vec<IndexReplica>, RepoError> {
        sqlx::query_as::<_, IndexReplica>(
            "SELECT * FROM index_replicas \
             WHERE customer_id = $1 AND tenant_id = $2 AND status = 'active' \
             ORDER BY created_at",
        )
        .bind(customer_id)
        .bind(tenant_id)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn set_status(&self, id: Uuid, status: &str) -> Result<(), RepoError> {
        let result =
            sqlx::query("UPDATE index_replicas SET status = $2, updated_at = NOW() WHERE id = $1")
                .bind(id)
                .bind(status)
                .execute(&self.pool)
                .await
                .map_err(|e| RepoError::Other(e.to_string()))?;

        if result.rows_affected() == 0 {
            return Err(RepoError::NotFound);
        }
        Ok(())
    }

    async fn set_lag(&self, id: Uuid, lag_ops: i64) -> Result<(), RepoError> {
        // Intentionally does NOT update `updated_at` — lag updates happen every
        // orchestrator cycle and must not reset the syncing-timeout clock.
        let result = sqlx::query("UPDATE index_replicas SET lag_ops = $2 WHERE id = $1")
            .bind(id)
            .bind(lag_ops)
            .execute(&self.pool)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))?;

        if result.rows_affected() == 0 {
            return Err(RepoError::NotFound);
        }
        Ok(())
    }

    async fn delete(&self, id: Uuid) -> Result<bool, RepoError> {
        let result = sqlx::query("DELETE FROM index_replicas WHERE id = $1")
            .bind(id)
            .execute(&self.pool)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))?;

        Ok(result.rows_affected() > 0)
    }

    async fn count_by_index(&self, customer_id: Uuid, tenant_id: &str) -> Result<i64, RepoError> {
        let row: (i64,) = sqlx::query_as(
            "SELECT COUNT(*) FROM index_replicas WHERE customer_id = $1 AND tenant_id = $2",
        )
        .bind(customer_id)
        .bind(tenant_id)
        .fetch_one(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        Ok(row.0)
    }

    async fn list_actionable(&self) -> Result<Vec<IndexReplica>, RepoError> {
        sqlx::query_as::<_, IndexReplica>(
            "SELECT * FROM index_replicas WHERE status NOT IN ('failed', 'removing', 'suspended') ORDER BY created_at",
        )
        .fetch_all(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn list_all(&self) -> Result<Vec<IndexReplica>, RepoError> {
        sqlx::query_as::<_, IndexReplica>("SELECT * FROM index_replicas ORDER BY created_at")
            .fetch_all(&self.pool)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))
    }
}
