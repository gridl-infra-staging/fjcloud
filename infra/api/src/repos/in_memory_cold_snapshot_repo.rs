//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar19_3_load_testing_chaos/fjcloud_dev/infra/api/src/repos/in_memory_cold_snapshot_repo.rs.
use async_trait::async_trait;
use chrono::{NaiveDate, TimeDelta, Utc};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use uuid::Uuid;

use crate::models::cold_snapshot::{ColdSnapshot, NewColdSnapshot};
use crate::repos::cold_snapshot_repo::ColdSnapshotRepo;
use crate::repos::error::RepoError;

const ACTIVE_SNAPSHOT_STATUSES: [&str; 3] = ["pending", "exporting", "completed"];

#[derive(Clone, Default)]
pub struct InMemoryColdSnapshotRepo {
    snapshots: Arc<Mutex<HashMap<Uuid, ColdSnapshot>>>,
}

impl InMemoryColdSnapshotRepo {
    pub fn new() -> Self {
        Self::default()
    }
}

#[async_trait]
impl ColdSnapshotRepo for InMemoryColdSnapshotRepo {
    /// In-memory cold-snapshot creation for tests/local dev. Rejects with
    /// `Conflict` if an active snapshot (pending/exporting/completed) already
    /// exists for the same index. No SQL; HashMap with mutex.
    async fn create(&self, snapshot: NewColdSnapshot) -> Result<ColdSnapshot, RepoError> {
        let mut snapshots = self.snapshots.lock().unwrap();

        if snapshots.values().any(|existing| {
            existing.customer_id == snapshot.customer_id
                && existing.tenant_id == snapshot.tenant_id
                && ACTIVE_SNAPSHOT_STATUSES.contains(&existing.status.as_str())
        }) {
            return Err(RepoError::Conflict(format!(
                "active snapshot already exists for index '{}'",
                snapshot.tenant_id
            )));
        }

        let row = ColdSnapshot {
            id: Uuid::new_v4(),
            customer_id: snapshot.customer_id,
            tenant_id: snapshot.tenant_id,
            source_vm_id: snapshot.source_vm_id,
            object_key: snapshot.object_key,
            size_bytes: 0,
            checksum: None,
            status: "pending".to_string(),
            error: None,
            created_at: Utc::now(),
            completed_at: None,
            expires_at: None,
        };
        snapshots.insert(row.id, row.clone());
        Ok(row)
    }

    async fn get(&self, id: Uuid) -> Result<Option<ColdSnapshot>, RepoError> {
        Ok(self.snapshots.lock().unwrap().get(&id).cloned())
    }

    async fn find_active_for_index(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
    ) -> Result<Option<ColdSnapshot>, RepoError> {
        let snapshots = self.snapshots.lock().unwrap();
        Ok(snapshots
            .values()
            .find(|snapshot| {
                snapshot.customer_id == customer_id
                    && snapshot.tenant_id == tenant_id
                    && ACTIVE_SNAPSHOT_STATUSES.contains(&snapshot.status.as_str())
            })
            .cloned())
    }

    async fn set_exporting(&self, id: Uuid) -> Result<(), RepoError> {
        let mut snapshots = self.snapshots.lock().unwrap();
        match snapshots.get_mut(&id) {
            Some(snapshot) if snapshot.status == "pending" => {
                snapshot.status = "exporting".to_string();
                Ok(())
            }
            _ => Err(RepoError::NotFound),
        }
    }

    /// Transitions from exporting to completed, recording size and checksum.
    /// Returns `NotFound` if the snapshot is not in exporting status.
    async fn set_completed(
        &self,
        id: Uuid,
        size_bytes: i64,
        checksum: &str,
    ) -> Result<(), RepoError> {
        let mut snapshots = self.snapshots.lock().unwrap();
        match snapshots.get_mut(&id) {
            Some(snapshot) if snapshot.status == "exporting" => {
                snapshot.status = "completed".to_string();
                snapshot.size_bytes = size_bytes;
                snapshot.checksum = Some(checksum.to_string());
                snapshot.completed_at = Some(Utc::now());
                Ok(())
            }
            _ => Err(RepoError::NotFound),
        }
    }

    async fn set_failed(&self, id: Uuid, error: &str) -> Result<(), RepoError> {
        let mut snapshots = self.snapshots.lock().unwrap();
        match snapshots.get_mut(&id) {
            Some(snapshot) => {
                snapshot.status = "failed".to_string();
                snapshot.error = Some(error.to_string());
                Ok(())
            }
            None => Err(RepoError::NotFound),
        }
    }

    async fn set_expired(&self, id: Uuid) -> Result<(), RepoError> {
        let mut snapshots = self.snapshots.lock().unwrap();
        match snapshots.get_mut(&id) {
            Some(snapshot) => {
                snapshot.status = "expired".to_string();
                Ok(())
            }
            None => Err(RepoError::NotFound),
        }
    }

    /// Returns completed snapshots with `completed_at` within the billing period.
    /// Simplified vs PG: only checks completed_at ≤ period_end, ignores
    /// period_start. Sorted by completed_at.
    async fn list_completed_for_billing(
        &self,
        _period_start: NaiveDate,
        period_end: NaiveDate,
    ) -> Result<Vec<ColdSnapshot>, RepoError> {
        let cutoff = period_end.and_hms_opt(0, 0, 0).expect("valid midnight") + TimeDelta::days(1);

        let mut rows: Vec<ColdSnapshot> = self
            .snapshots
            .lock()
            .unwrap()
            .values()
            .filter(|snapshot| {
                snapshot.status == "completed"
                    && snapshot
                        .completed_at
                        .is_some_and(|completed_at| completed_at.naive_utc() <= cutoff)
            })
            .cloned()
            .collect();

        rows.sort_by_key(|snapshot| snapshot.completed_at);
        Ok(rows)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cid() -> Uuid {
        Uuid::parse_str("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa").unwrap()
    }
    fn vm() -> Uuid {
        Uuid::parse_str("11111111-1111-1111-1111-111111111111").unwrap()
    }
    fn new_snapshot(tenant: &str) -> NewColdSnapshot {
        NewColdSnapshot {
            customer_id: cid(),
            tenant_id: tenant.to_string(),
            source_vm_id: vm(),
            object_key: format!("cold/us-east-1/{}/{}.fj", cid(), tenant),
        }
    }

    #[tokio::test]
    async fn create_and_get_roundtrip() {
        let repo = InMemoryColdSnapshotRepo::new();
        let snap = repo.create(new_snapshot("idx")).await.unwrap();
        assert_eq!(snap.status, "pending");
        assert_eq!(snap.size_bytes, 0);
        assert!(snap.checksum.is_none());
        let fetched = repo.get(snap.id).await.unwrap().unwrap();
        assert_eq!(fetched.tenant_id, "idx");
    }

    #[tokio::test]
    async fn conflict_on_active_snapshot_for_same_index() {
        let repo = InMemoryColdSnapshotRepo::new();
        repo.create(new_snapshot("idx")).await.unwrap();
        let err = repo.create(new_snapshot("idx")).await.unwrap_err();
        assert!(matches!(err, RepoError::Conflict(_)));
    }

    #[tokio::test]
    async fn failed_snapshot_allows_new_create() {
        let repo = InMemoryColdSnapshotRepo::new();
        let snap = repo.create(new_snapshot("idx")).await.unwrap();
        repo.set_failed(snap.id, "disk full").await.unwrap();
        // Failed is not in ACTIVE_SNAPSHOT_STATUSES, so new create should succeed
        repo.create(new_snapshot("idx")).await.unwrap();
    }

    #[tokio::test]
    async fn state_machine_pending_to_exporting_to_completed() {
        let repo = InMemoryColdSnapshotRepo::new();
        let snap = repo.create(new_snapshot("idx")).await.unwrap();
        repo.set_exporting(snap.id).await.unwrap();
        let s = repo.get(snap.id).await.unwrap().unwrap();
        assert_eq!(s.status, "exporting");
        repo.set_completed(snap.id, 1024, "abc123").await.unwrap();
        let s = repo.get(snap.id).await.unwrap().unwrap();
        assert_eq!(s.status, "completed");
        assert_eq!(s.size_bytes, 1024);
        assert_eq!(s.checksum.as_deref(), Some("abc123"));
        assert!(s.completed_at.is_some());
    }

    #[tokio::test]
    async fn set_exporting_rejects_non_pending() {
        let repo = InMemoryColdSnapshotRepo::new();
        let snap = repo.create(new_snapshot("idx")).await.unwrap();
        repo.set_exporting(snap.id).await.unwrap();
        // Already exporting — should fail
        assert!(matches!(
            repo.set_exporting(snap.id).await,
            Err(RepoError::NotFound)
        ));
    }

    #[tokio::test]
    async fn set_completed_rejects_non_exporting() {
        let repo = InMemoryColdSnapshotRepo::new();
        let snap = repo.create(new_snapshot("idx")).await.unwrap();
        // Still pending, not exporting
        assert!(matches!(
            repo.set_completed(snap.id, 100, "x").await,
            Err(RepoError::NotFound)
        ));
    }

    #[tokio::test]
    async fn set_failed_works_from_any_status() {
        let repo = InMemoryColdSnapshotRepo::new();
        let snap = repo.create(new_snapshot("idx")).await.unwrap();
        repo.set_failed(snap.id, "error msg").await.unwrap();
        let s = repo.get(snap.id).await.unwrap().unwrap();
        assert_eq!(s.status, "failed");
        assert_eq!(s.error.as_deref(), Some("error msg"));
    }

    #[tokio::test]
    async fn set_expired_transitions_status() {
        let repo = InMemoryColdSnapshotRepo::new();
        let snap = repo.create(new_snapshot("idx")).await.unwrap();
        repo.set_exporting(snap.id).await.unwrap();
        repo.set_completed(snap.id, 500, "hash").await.unwrap();
        repo.set_expired(snap.id).await.unwrap();
        assert_eq!(repo.get(snap.id).await.unwrap().unwrap().status, "expired");
    }

    #[tokio::test]
    async fn find_active_for_index_returns_active_snapshot() {
        let repo = InMemoryColdSnapshotRepo::new();
        let snap = repo.create(new_snapshot("idx")).await.unwrap();
        let found = repo.find_active_for_index(cid(), "idx").await.unwrap();
        assert_eq!(found.unwrap().id, snap.id);
    }

    #[tokio::test]
    async fn find_active_for_index_ignores_failed() {
        let repo = InMemoryColdSnapshotRepo::new();
        let snap = repo.create(new_snapshot("idx")).await.unwrap();
        repo.set_failed(snap.id, "err").await.unwrap();
        assert!(repo
            .find_active_for_index(cid(), "idx")
            .await
            .unwrap()
            .is_none());
    }

    /// Verifies that state-transition methods (set_exporting, set_failed,
    /// set_expired) all return `NotFound` for non-existent snapshot IDs.
    #[tokio::test]
    async fn missing_id_operations_return_not_found() {
        let repo = InMemoryColdSnapshotRepo::new();
        let missing = Uuid::new_v4();
        assert!(matches!(
            repo.set_exporting(missing).await,
            Err(RepoError::NotFound)
        ));
        assert!(matches!(
            repo.set_failed(missing, "e").await,
            Err(RepoError::NotFound)
        ));
        assert!(matches!(
            repo.set_expired(missing).await,
            Err(RepoError::NotFound)
        ));
    }
}
