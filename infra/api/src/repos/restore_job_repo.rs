//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/repos/restore_job_repo.rs.
use async_trait::async_trait;
use uuid::Uuid;

use crate::models::restore_job::{NewRestoreJob, RestoreJob};
use crate::repos::error::RepoError;

/// Restore-job repository: cold-snapshot restore lifecycle with idempotency
/// keys to prevent duplicate concurrent restores, status tracking, and
/// active-job counting for concurrency limits.
#[async_trait]
pub trait RestoreJobRepo {
    /// Insert a new restore job record.
    async fn create(&self, job: NewRestoreJob) -> Result<RestoreJob, RepoError>;

    /// Get a restore job by id.
    async fn get(&self, id: Uuid) -> Result<Option<RestoreJob>, RepoError>;

    /// Find an active job by idempotency key (prevents duplicate concurrent restores).
    /// Returns None for completed/failed jobs so retries can create new jobs.
    async fn find_by_idempotency_key(&self, key: &str) -> Result<Option<RestoreJob>, RepoError>;

    /// Find the latest job by idempotency key, including terminal jobs.
    /// Used by status polling so fast completed restores remain observable.
    async fn find_latest_by_idempotency_key(
        &self,
        key: &str,
    ) -> Result<Option<RestoreJob>, RepoError>;

    /// Update the status of a restore job, optionally with an error message.
    async fn update_status(
        &self,
        id: Uuid,
        status: &str,
        error: Option<&str>,
    ) -> Result<(), RepoError>;

    /// Mark a restore job as completed (sets completed_at).
    async fn set_completed(&self, id: Uuid) -> Result<(), RepoError>;

    /// List all active (queued/downloading/importing) restore jobs.
    async fn list_active(&self) -> Result<Vec<RestoreJob>, RepoError>;

    /// Count active restore jobs (for concurrency limiting).
    async fn count_active(&self) -> Result<i64, RepoError>;
}
