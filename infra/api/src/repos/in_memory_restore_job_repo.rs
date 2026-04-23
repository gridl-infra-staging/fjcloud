//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar19_3_load_testing_chaos/fjcloud_dev/infra/api/src/repos/in_memory_restore_job_repo.rs.
use async_trait::async_trait;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use uuid::Uuid;

use crate::models::restore_job::{NewRestoreJob, RestoreJob};
use crate::repos::error::RepoError;
use crate::repos::restore_job_repo::RestoreJobRepo;

const ACTIVE_RESTORE_JOB_STATUSES: [&str; 3] = ["queued", "downloading", "importing"];

#[derive(Clone, Default)]
pub struct InMemoryRestoreJobRepo {
    jobs: Arc<Mutex<HashMap<Uuid, RestoreJob>>>,
}

impl InMemoryRestoreJobRepo {
    pub fn new() -> Self {
        Self::default()
    }
}

#[async_trait]
impl RestoreJobRepo for InMemoryRestoreJobRepo {
    /// In-memory restore-job creation for tests/local dev. Rejects with
    /// `Conflict` if an active job (queued/downloading/importing) with the
    /// same idempotency key already exists.
    async fn create(&self, job: NewRestoreJob) -> Result<RestoreJob, RepoError> {
        let mut jobs = self.jobs.lock().unwrap();

        if jobs.values().any(|existing| {
            existing.idempotency_key == job.idempotency_key
                && ACTIVE_RESTORE_JOB_STATUSES.contains(&existing.status.as_str())
        }) {
            return Err(RepoError::Conflict(format!(
                "restore job already exists for key '{}'",
                job.idempotency_key
            )));
        }

        let row = RestoreJob {
            id: Uuid::new_v4(),
            customer_id: job.customer_id,
            tenant_id: job.tenant_id,
            snapshot_id: job.snapshot_id,
            dest_vm_id: job.dest_vm_id,
            status: "queued".to_string(),
            idempotency_key: job.idempotency_key,
            error: None,
            created_at: chrono::Utc::now(),
            started_at: None,
            completed_at: None,
        };
        jobs.insert(row.id, row.clone());
        Ok(row)
    }

    async fn get(&self, id: Uuid) -> Result<Option<RestoreJob>, RepoError> {
        Ok(self.jobs.lock().unwrap().get(&id).cloned())
    }

    async fn find_by_idempotency_key(&self, key: &str) -> Result<Option<RestoreJob>, RepoError> {
        Ok(self
            .jobs
            .lock()
            .unwrap()
            .values()
            .find(|job| {
                job.idempotency_key == key
                    && ACTIVE_RESTORE_JOB_STATUSES.contains(&job.status.as_str())
            })
            .cloned())
    }

    async fn find_latest_by_idempotency_key(
        &self,
        key: &str,
    ) -> Result<Option<RestoreJob>, RepoError> {
        Ok(self
            .jobs
            .lock()
            .unwrap()
            .values()
            .filter(|job| job.idempotency_key == key)
            .max_by_key(|job| job.created_at)
            .cloned())
    }

    /// Updates job status and optional error message. Sets `started_at` on
    /// first transition to "downloading" (idempotent — will not overwrite
    /// if already set).
    async fn update_status(
        &self,
        id: Uuid,
        status: &str,
        error: Option<&str>,
    ) -> Result<(), RepoError> {
        let mut jobs = self.jobs.lock().unwrap();
        match jobs.get_mut(&id) {
            Some(job) => {
                job.status = status.to_string();
                job.error = error.map(ToString::to_string);
                if status == "downloading" && job.started_at.is_none() {
                    job.started_at = Some(chrono::Utc::now());
                }
                Ok(())
            }
            None => Err(RepoError::NotFound),
        }
    }

    async fn set_completed(&self, id: Uuid) -> Result<(), RepoError> {
        let mut jobs = self.jobs.lock().unwrap();
        match jobs.get_mut(&id) {
            Some(job) => {
                job.status = "completed".to_string();
                job.completed_at = Some(chrono::Utc::now());
                Ok(())
            }
            None => Err(RepoError::NotFound),
        }
    }

    async fn list_active(&self) -> Result<Vec<RestoreJob>, RepoError> {
        let mut active: Vec<RestoreJob> = self
            .jobs
            .lock()
            .unwrap()
            .values()
            .filter(|job| ACTIVE_RESTORE_JOB_STATUSES.contains(&job.status.as_str()))
            .cloned()
            .collect();
        active.sort_by_key(|job| job.created_at);
        Ok(active)
    }

    async fn count_active(&self) -> Result<i64, RepoError> {
        Ok(self
            .jobs
            .lock()
            .unwrap()
            .values()
            .filter(|job| ACTIVE_RESTORE_JOB_STATUSES.contains(&job.status.as_str()))
            .count() as i64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cid() -> Uuid {
        Uuid::parse_str("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa").unwrap()
    }
    fn snap_id() -> Uuid {
        Uuid::parse_str("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb").unwrap()
    }
    fn vm() -> Uuid {
        Uuid::parse_str("11111111-1111-1111-1111-111111111111").unwrap()
    }
    fn new_job(key: &str) -> NewRestoreJob {
        NewRestoreJob {
            customer_id: cid(),
            tenant_id: "my-index".to_string(),
            snapshot_id: snap_id(),
            dest_vm_id: Some(vm()),
            idempotency_key: key.to_string(),
        }
    }

    #[tokio::test]
    async fn create_and_get_roundtrip() {
        let repo = InMemoryRestoreJobRepo::new();
        let job = repo.create(new_job("key-1")).await.unwrap();
        assert_eq!(job.status, "queued");
        assert!(job.started_at.is_none());
        assert!(job.completed_at.is_none());
        let fetched = repo.get(job.id).await.unwrap().unwrap();
        assert_eq!(fetched.idempotency_key, "key-1");
    }

    #[tokio::test]
    async fn idempotency_conflict_on_active_job() {
        let repo = InMemoryRestoreJobRepo::new();
        repo.create(new_job("key-1")).await.unwrap();
        let err = repo.create(new_job("key-1")).await.unwrap_err();
        assert!(matches!(err, RepoError::Conflict(_)));
    }

    #[tokio::test]
    async fn completed_job_allows_new_create_with_same_key() {
        let repo = InMemoryRestoreJobRepo::new();
        let job = repo.create(new_job("key-1")).await.unwrap();
        repo.set_completed(job.id).await.unwrap();
        // "completed" is not in ACTIVE_RESTORE_JOB_STATUSES
        repo.create(new_job("key-1")).await.unwrap();
    }

    #[tokio::test]
    async fn update_status_to_downloading_sets_started_at() {
        let repo = InMemoryRestoreJobRepo::new();
        let job = repo.create(new_job("key-1")).await.unwrap();
        assert!(job.started_at.is_none());
        repo.update_status(job.id, "downloading", None)
            .await
            .unwrap();
        let j = repo.get(job.id).await.unwrap().unwrap();
        assert_eq!(j.status, "downloading");
        assert!(j.started_at.is_some());
    }

    /// Verifies that `started_at` is set only on the first transition to
    /// "downloading" and is not overwritten by subsequent downloading transitions.
    #[tokio::test]
    async fn update_status_downloading_only_sets_started_at_once() {
        let repo = InMemoryRestoreJobRepo::new();
        let job = repo.create(new_job("key-1")).await.unwrap();
        repo.update_status(job.id, "downloading", None)
            .await
            .unwrap();
        let first_started = repo.get(job.id).await.unwrap().unwrap().started_at;
        // Update to importing then back to downloading
        repo.update_status(job.id, "importing", None).await.unwrap();
        repo.update_status(job.id, "downloading", None)
            .await
            .unwrap();
        let second_started = repo.get(job.id).await.unwrap().unwrap().started_at;
        assert_eq!(
            first_started, second_started,
            "started_at should not change once set"
        );
    }

    #[tokio::test]
    async fn update_status_with_error() {
        let repo = InMemoryRestoreJobRepo::new();
        let job = repo.create(new_job("key-1")).await.unwrap();
        repo.update_status(job.id, "failed", Some("disk full"))
            .await
            .unwrap();
        let j = repo.get(job.id).await.unwrap().unwrap();
        assert_eq!(j.status, "failed");
        assert_eq!(j.error.as_deref(), Some("disk full"));
    }

    #[tokio::test]
    async fn set_completed_sets_completed_at() {
        let repo = InMemoryRestoreJobRepo::new();
        let job = repo.create(new_job("key-1")).await.unwrap();
        repo.set_completed(job.id).await.unwrap();
        let j = repo.get(job.id).await.unwrap().unwrap();
        assert_eq!(j.status, "completed");
        assert!(j.completed_at.is_some());
    }

    #[tokio::test]
    async fn find_by_idempotency_key_only_returns_active() {
        let repo = InMemoryRestoreJobRepo::new();
        let job = repo.create(new_job("key-1")).await.unwrap();
        assert!(repo
            .find_by_idempotency_key("key-1")
            .await
            .unwrap()
            .is_some());
        repo.set_completed(job.id).await.unwrap();
        assert!(repo
            .find_by_idempotency_key("key-1")
            .await
            .unwrap()
            .is_none());
    }

    #[tokio::test]
    async fn list_active_excludes_completed_and_failed() {
        let repo = InMemoryRestoreJobRepo::new();
        let j1 = repo.create(new_job("k1")).await.unwrap();
        let j2 = repo.create(new_job("k2")).await.unwrap();
        let _j3 = repo.create(new_job("k3")).await.unwrap();
        repo.set_completed(j1.id).await.unwrap();
        repo.update_status(j2.id, "failed", Some("err"))
            .await
            .unwrap();
        let active = repo.list_active().await.unwrap();
        assert_eq!(active.len(), 1);
        assert_eq!(active[0].idempotency_key, "k3");
    }

    #[tokio::test]
    async fn count_active_matches_list_active() {
        let repo = InMemoryRestoreJobRepo::new();
        repo.create(new_job("k1")).await.unwrap();
        let j2 = repo.create(new_job("k2")).await.unwrap();
        repo.set_completed(j2.id).await.unwrap();
        assert_eq!(repo.count_active().await.unwrap(), 1);
    }

    #[tokio::test]
    async fn update_status_missing_returns_not_found() {
        let repo = InMemoryRestoreJobRepo::new();
        assert!(matches!(
            repo.update_status(Uuid::new_v4(), "downloading", None)
                .await,
            Err(RepoError::NotFound)
        ));
    }

    #[tokio::test]
    async fn set_completed_missing_returns_not_found() {
        let repo = InMemoryRestoreJobRepo::new();
        assert!(matches!(
            repo.set_completed(Uuid::new_v4()).await,
            Err(RepoError::NotFound)
        ));
    }
}
