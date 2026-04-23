//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/repos/pg_restore_job_repo.rs.
use async_trait::async_trait;
use sqlx::PgPool;
use uuid::Uuid;

use crate::models::restore_job::{NewRestoreJob, RestoreJob};
use crate::repos::error::{is_unique_violation, RepoError};
use crate::repos::restore_job_repo::RestoreJobRepo;

pub struct PgRestoreJobRepo {
    pool: PgPool,
}

impl PgRestoreJobRepo {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl RestoreJobRepo for PgRestoreJobRepo {
    /// Inserts a new restore job and returns the created record.
    /// Returns `Conflict` on duplicate idempotency key.
    async fn create(&self, job: NewRestoreJob) -> Result<RestoreJob, RepoError> {
        sqlx::query_as::<_, RestoreJob>(
            "INSERT INTO restore_jobs (customer_id, tenant_id, snapshot_id, dest_vm_id, idempotency_key) \
             VALUES ($1, $2, $3, $4, $5) RETURNING *",
        )
        .bind(job.customer_id)
        .bind(&job.tenant_id)
        .bind(job.snapshot_id)
        .bind(job.dest_vm_id)
        .bind(&job.idempotency_key)
        .fetch_one(&self.pool)
        .await
        .map_err(|e| {
            if is_unique_violation(&e) {
                RepoError::Conflict(format!(
                    "restore job already exists for key '{}'",
                    job.idempotency_key
                ))
            } else {
                RepoError::Other(e.to_string())
            }
        })
    }

    async fn get(&self, id: Uuid) -> Result<Option<RestoreJob>, RepoError> {
        sqlx::query_as::<_, RestoreJob>("SELECT * FROM restore_jobs WHERE id = $1")
            .bind(id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn find_by_idempotency_key(&self, key: &str) -> Result<Option<RestoreJob>, RepoError> {
        // Only return active jobs — completed/failed jobs should not block new restores.
        sqlx::query_as::<_, RestoreJob>(
            "SELECT * FROM restore_jobs WHERE idempotency_key = $1 \
             AND status IN ('queued', 'downloading', 'importing')",
        )
        .bind(key)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn find_latest_by_idempotency_key(
        &self,
        key: &str,
    ) -> Result<Option<RestoreJob>, RepoError> {
        sqlx::query_as::<_, RestoreJob>(
            "SELECT * FROM restore_jobs WHERE idempotency_key = $1 \
             ORDER BY created_at DESC LIMIT 1",
        )
        .bind(key)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    /// Updates the job status and optional error message. When transitioning
    /// to `downloading`, sets `started_at` once (idempotent on repeated calls).
    async fn update_status(
        &self,
        id: Uuid,
        status: &str,
        error: Option<&str>,
    ) -> Result<(), RepoError> {
        let result = sqlx::query(
            "UPDATE restore_jobs SET status = $2, error = $3, \
             started_at = CASE WHEN $2 = 'downloading' AND started_at IS NULL THEN NOW() ELSE started_at END \
             WHERE id = $1",
        )
        .bind(id)
        .bind(status)
        .bind(error)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        if result.rows_affected() == 0 {
            return Err(RepoError::NotFound);
        }
        Ok(())
    }

    async fn set_completed(&self, id: Uuid) -> Result<(), RepoError> {
        let result = sqlx::query(
            "UPDATE restore_jobs SET status = 'completed', completed_at = NOW() WHERE id = $1",
        )
        .bind(id)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        if result.rows_affected() == 0 {
            return Err(RepoError::NotFound);
        }
        Ok(())
    }

    async fn list_active(&self) -> Result<Vec<RestoreJob>, RepoError> {
        sqlx::query_as::<_, RestoreJob>(
            "SELECT * FROM restore_jobs \
             WHERE status IN ('queued', 'downloading', 'importing') \
             ORDER BY created_at",
        )
        .fetch_all(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn count_active(&self) -> Result<i64, RepoError> {
        let row: (i64,) = sqlx::query_as(
            "SELECT COUNT(*) FROM restore_jobs \
             WHERE status IN ('queued', 'downloading', 'importing')",
        )
        .fetch_one(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        Ok(row.0)
    }
}
