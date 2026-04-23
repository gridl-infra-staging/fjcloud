//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/repos/pg_index_migration_repo.rs.
use async_trait::async_trait;
use sqlx::PgPool;
use uuid::Uuid;

use crate::models::index_migration::IndexMigration;
use crate::repos::error::RepoError;
use crate::repos::index_migration_repo::IndexMigrationRepo;
use crate::services::migration::{MigrationRequest, MigrationStatus};

pub struct PgIndexMigrationRepo {
    pool: PgPool,
}

impl PgIndexMigrationRepo {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl IndexMigrationRepo for PgIndexMigrationRepo {
    async fn get(&self, id: Uuid) -> Result<Option<IndexMigration>, RepoError> {
        sqlx::query_as::<_, IndexMigration>("SELECT * FROM index_migrations WHERE id = $1")
            .bind(id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))
    }

    /// Inserts a new index migration from a `MigrationRequest` and returns
    /// the created record.
    async fn create(&self, req: &MigrationRequest) -> Result<IndexMigration, RepoError> {
        sqlx::query_as::<_, IndexMigration>(
            "INSERT INTO index_migrations \
             (index_name, customer_id, source_vm_id, dest_vm_id, requested_by) \
             VALUES ($1, $2, $3, $4, $5) \
             RETURNING *",
        )
        .bind(&req.index_name)
        .bind(req.customer_id)
        .bind(req.source_vm_id)
        .bind(req.dest_vm_id)
        .bind(&req.requested_by)
        .fetch_one(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    /// Updates the migration status and optionally sets an error message.
    async fn update_status(
        &self,
        id: Uuid,
        status: &str,
        error: Option<&str>,
    ) -> Result<(), RepoError> {
        let result = sqlx::query(
            "UPDATE index_migrations \
             SET status = $1, error = $2 \
             WHERE id = $3",
        )
        .bind(status)
        .bind(error)
        .bind(id)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        if result.rows_affected() == 0 {
            return Err(RepoError::NotFound);
        }
        Ok(())
    }

    /// Marks the migration as completed, sets `completed_at` to now,
    /// and clears any previous error.
    async fn set_completed(&self, id: Uuid) -> Result<(), RepoError> {
        let result = sqlx::query(
            "UPDATE index_migrations \
             SET status = $1, completed_at = NOW(), error = NULL \
             WHERE id = $2",
        )
        .bind(MigrationStatus::Completed.as_str())
        .bind(id)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        if result.rows_affected() == 0 {
            return Err(RepoError::NotFound);
        }
        Ok(())
    }

    async fn list_active(&self) -> Result<Vec<IndexMigration>, RepoError> {
        sqlx::query_as::<_, IndexMigration>(
            "SELECT * FROM index_migrations \
             WHERE status IN ('pending', 'replicating', 'cutting_over') \
             ORDER BY started_at ASC",
        )
        .fetch_all(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn list_recent(&self, limit: i64) -> Result<Vec<IndexMigration>, RepoError> {
        if limit <= 0 {
            return Ok(Vec::new());
        }
        sqlx::query_as::<_, IndexMigration>(
            "SELECT * FROM index_migrations \
             ORDER BY started_at DESC \
             LIMIT $1",
        )
        .bind(limit)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn count_active(&self) -> Result<i64, RepoError> {
        let row: (i64,) = sqlx::query_as(
            "SELECT COUNT(*) FROM index_migrations \
             WHERE status IN ('pending', 'replicating', 'cutting_over')",
        )
        .fetch_one(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        Ok(row.0)
    }
}
