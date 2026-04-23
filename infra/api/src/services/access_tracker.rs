use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::{DateTime, Utc};
use tokio::task::JoinHandle;
use uuid::Uuid;

use crate::repos::{RepoError, TenantRepo};

type AccessKey = (Uuid, String);
type PendingAccess = HashMap<AccessKey, DateTime<Utc>>;

/// Debounced access tracker for updating `customer_tenants.last_accessed_at`
/// without a write on every query request.
pub struct AccessTracker {
    tenant_repo: Arc<dyn TenantRepo + Send + Sync>,
    pending: Arc<Mutex<PendingAccess>>,
}

impl AccessTracker {
    pub fn new(tenant_repo: Arc<dyn TenantRepo + Send + Sync>) -> Self {
        Self {
            tenant_repo,
            pending: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// Record an access in-memory. No database write is performed here.
    pub fn record_access(&self, customer_id: Uuid, tenant_id: &str) {
        let mut pending = self.pending.lock().unwrap();
        pending.insert((customer_id, tenant_id.to_string()), Utc::now());
    }

    /// Flush pending accesses with a single batch update.
    pub async fn flush(&self) -> Result<(), RepoError> {
        let drained: PendingAccess = {
            let mut pending = self.pending.lock().unwrap();
            if pending.is_empty() {
                return Ok(());
            }
            std::mem::take(&mut *pending)
        };

        let updates: Vec<(Uuid, String, DateTime<Utc>)> = drained
            .iter()
            .map(|((customer_id, tenant_id), ts)| (*customer_id, tenant_id.clone(), *ts))
            .collect();

        if let Err(err) = self.tenant_repo.update_last_accessed_batch(&updates).await {
            // Keep updates on failure so the next flush can retry.
            let mut pending = self.pending.lock().unwrap();
            for (key, ts) in drained {
                pending
                    .entry(key)
                    .and_modify(|existing| {
                        if ts > *existing {
                            *existing = ts;
                        }
                    })
                    .or_insert(ts);
            }
            return Err(err);
        }

        Ok(())
    }

    /// Start periodic flush loop.
    pub fn start(self: Arc<Self>, interval_secs: u64) -> JoinHandle<()> {
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_secs(interval_secs));
            loop {
                interval.tick().await;
                if let Err(err) = self.flush().await {
                    tracing::warn!(error = %err, "failed to flush access tracker batch");
                }
            }
        })
    }

    /// Number of pending access updates.
    pub fn pending_count(&self) -> usize {
        self.pending.lock().unwrap().len()
    }

    /// Whether a specific `(customer_id, tenant_id)` has a pending access entry.
    pub fn has_pending(&self, customer_id: Uuid, tenant_id: &str) -> bool {
        self.pending
            .lock()
            .unwrap()
            .contains_key(&(customer_id, tenant_id.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    /// Stub repo that panics if any method is called — these tests only
    /// exercise the in-memory `record_access` / `has_pending` / `pending_count`
    /// path which never touches the repo.
    struct StubTenantRepo;

    #[async_trait::async_trait]
    impl crate::repos::TenantRepo for StubTenantRepo {
        async fn create(
            &self,
            _: Uuid,
            _: &str,
            _: Uuid,
        ) -> Result<crate::models::tenant::CustomerTenant, crate::repos::RepoError> {
            unimplemented!()
        }
        async fn find_by_customer(
            &self,
            _: Uuid,
        ) -> Result<Vec<crate::models::tenant::CustomerTenantSummary>, crate::repos::RepoError>
        {
            unimplemented!()
        }
        async fn find_by_name(
            &self,
            _: Uuid,
            _: &str,
        ) -> Result<Option<crate::models::tenant::CustomerTenantSummary>, crate::repos::RepoError>
        {
            unimplemented!()
        }
        async fn delete(&self, _: Uuid, _: &str) -> Result<bool, crate::repos::RepoError> {
            unimplemented!()
        }
        async fn count_by_customer(&self, _: Uuid) -> Result<i64, crate::repos::RepoError> {
            unimplemented!()
        }
        async fn find_by_deployment(
            &self,
            _: Uuid,
        ) -> Result<Vec<crate::models::tenant::CustomerTenant>, crate::repos::RepoError> {
            unimplemented!()
        }
        async fn set_vm_id(
            &self,
            _: Uuid,
            _: &str,
            _: Uuid,
        ) -> Result<(), crate::repos::RepoError> {
            unimplemented!()
        }
        async fn set_tier(&self, _: Uuid, _: &str, _: &str) -> Result<(), crate::repos::RepoError> {
            unimplemented!()
        }
        async fn list_by_vm(
            &self,
            _: Uuid,
        ) -> Result<Vec<crate::models::tenant::CustomerTenant>, crate::repos::RepoError> {
            unimplemented!()
        }
        async fn list_migrating(
            &self,
        ) -> Result<Vec<crate::models::tenant::CustomerTenant>, crate::repos::RepoError> {
            unimplemented!()
        }
        async fn list_unplaced(
            &self,
        ) -> Result<Vec<crate::models::tenant::CustomerTenant>, crate::repos::RepoError> {
            unimplemented!()
        }
        async fn list_active_global(
            &self,
        ) -> Result<Vec<crate::models::tenant::CustomerTenant>, crate::repos::RepoError> {
            unimplemented!()
        }
        async fn find_by_tenant_id_global(
            &self,
            _: &str,
        ) -> Result<Option<crate::models::tenant::CustomerTenantSummary>, crate::repos::RepoError>
        {
            unimplemented!()
        }
        async fn find_raw(
            &self,
            _: Uuid,
            _: &str,
        ) -> Result<Option<crate::models::tenant::CustomerTenant>, crate::repos::RepoError>
        {
            unimplemented!()
        }
        async fn set_resource_quota(
            &self,
            _: Uuid,
            _: &str,
            _: serde_json::Value,
        ) -> Result<(), crate::repos::RepoError> {
            unimplemented!()
        }
        async fn list_raw_by_customer(
            &self,
            _: Uuid,
        ) -> Result<Vec<crate::models::tenant::CustomerTenant>, crate::repos::RepoError> {
            unimplemented!()
        }
        async fn update_last_accessed_batch(
            &self,
            _: &[(Uuid, String, chrono::DateTime<chrono::Utc>)],
        ) -> Result<(), crate::repos::RepoError> {
            unimplemented!()
        }
        async fn set_cold_snapshot_id(
            &self,
            _: Uuid,
            _: &str,
            _: Option<Uuid>,
        ) -> Result<(), crate::repos::RepoError> {
            unimplemented!()
        }
        async fn clear_vm_id(&self, _: Uuid, _: &str) -> Result<(), crate::repos::RepoError> {
            unimplemented!()
        }
    }

    fn make_tracker() -> AccessTracker {
        let repo: Arc<dyn crate::repos::TenantRepo + Send + Sync> = Arc::new(StubTenantRepo);
        AccessTracker::new(repo)
    }

    #[test]
    fn record_access_increments_pending() {
        let tracker = make_tracker();
        let cid = Uuid::new_v4();
        assert_eq!(tracker.pending_count(), 0);

        tracker.record_access(cid, "my-index");
        assert_eq!(tracker.pending_count(), 1);
        assert!(tracker.has_pending(cid, "my-index"));
    }

    #[test]
    fn record_access_deduplicates_same_key() {
        let tracker = make_tracker();
        let cid = Uuid::new_v4();

        tracker.record_access(cid, "idx");
        tracker.record_access(cid, "idx");
        tracker.record_access(cid, "idx");
        assert_eq!(tracker.pending_count(), 1);
    }

    #[test]
    fn record_access_separate_tenants_are_distinct() {
        let tracker = make_tracker();
        let cid = Uuid::new_v4();

        tracker.record_access(cid, "index-a");
        tracker.record_access(cid, "index-b");
        assert_eq!(tracker.pending_count(), 2);
    }

    #[test]
    fn record_access_separate_customers_are_distinct() {
        let tracker = make_tracker();
        let cid1 = Uuid::new_v4();
        let cid2 = Uuid::new_v4();

        tracker.record_access(cid1, "idx");
        tracker.record_access(cid2, "idx");
        assert_eq!(tracker.pending_count(), 2);
    }

    #[test]
    fn has_pending_returns_false_for_unknown() {
        let tracker = make_tracker();
        assert!(!tracker.has_pending(Uuid::new_v4(), "nope"));
    }
}
