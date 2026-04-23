//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/repos/in_memory_storage_bucket_repo.rs.
use async_trait::async_trait;
use chrono::Utc;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use uuid::Uuid;

use crate::models::storage::{NewStorageBucket, StorageBucket};
use crate::repos::error::RepoError;
use crate::repos::storage_bucket_repo::StorageBucketRepo;

#[derive(Clone, Default)]
pub struct InMemoryStorageBucketRepo {
    buckets: Arc<Mutex<HashMap<Uuid, StorageBucket>>>,
    fail_update_egress_watermark_after: Arc<Mutex<Option<usize>>>,
}

impl InMemoryStorageBucketRepo {
    pub fn new() -> Self {
        Self::default()
    }

    /// Inject a single watermark-update failure after `successful_calls` successful writes.
    pub fn fail_update_egress_watermark_after(&self, successful_calls: usize) {
        *self.fail_update_egress_watermark_after.lock().unwrap() = Some(successful_calls);
    }

    fn mutate(&self, id: Uuid, f: impl FnOnce(&mut StorageBucket)) -> Result<(), RepoError> {
        let mut buckets = self.buckets.lock().unwrap();
        let bucket = buckets.get_mut(&id).ok_or(RepoError::NotFound)?;
        f(bucket);
        bucket.updated_at = Utc::now();
        Ok(())
    }
}

#[async_trait]
impl StorageBucketRepo for InMemoryStorageBucketRepo {
    /// In-memory bucket creation for tests/local dev. Rejects with `Conflict`
    /// if a non-deleted bucket with the same name exists for the customer.
    async fn create(
        &self,
        bucket: NewStorageBucket,
        garage_bucket: &str,
    ) -> Result<StorageBucket, RepoError> {
        let mut buckets = self.buckets.lock().unwrap();

        let has_conflict = buckets.values().any(|b| {
            b.customer_id == bucket.customer_id && b.name == bucket.name && b.status != "deleted"
        });
        if has_conflict {
            return Err(RepoError::Conflict(format!(
                "active bucket '{}' already exists for customer",
                bucket.name
            )));
        }

        let now = Utc::now();
        let row = StorageBucket {
            id: Uuid::new_v4(),
            customer_id: bucket.customer_id,
            name: bucket.name,
            garage_bucket: garage_bucket.to_string(),
            size_bytes: 0,
            object_count: 0,
            egress_bytes: 0,
            egress_watermark_bytes: 0,
            status: "active".to_string(),
            created_at: now,
            updated_at: now,
        };
        buckets.insert(row.id, row.clone());
        Ok(row)
    }

    async fn get(&self, id: Uuid) -> Result<Option<StorageBucket>, RepoError> {
        Ok(self.buckets.lock().unwrap().get(&id).cloned())
    }

    async fn get_by_name(
        &self,
        customer_id: Uuid,
        name: &str,
    ) -> Result<Option<StorageBucket>, RepoError> {
        Ok(self
            .buckets
            .lock()
            .unwrap()
            .values()
            .find(|b| b.customer_id == customer_id && b.name == name && b.status != "deleted")
            .cloned())
    }

    async fn list_by_customer(&self, customer_id: Uuid) -> Result<Vec<StorageBucket>, RepoError> {
        let buckets = self.buckets.lock().unwrap();
        let mut rows: Vec<StorageBucket> = buckets
            .values()
            .filter(|b| b.customer_id == customer_id && b.status != "deleted")
            .cloned()
            .collect();
        rows.sort_by_key(|b| b.created_at);
        Ok(rows)
    }

    async fn list_all(&self) -> Result<Vec<StorageBucket>, RepoError> {
        let buckets = self.buckets.lock().unwrap();
        let mut rows: Vec<StorageBucket> = buckets
            .values()
            .filter(|b| b.status != "deleted")
            .cloned()
            .collect();
        rows.sort_by_key(|b| b.created_at);
        Ok(rows)
    }

    async fn increment_size(
        &self,
        id: Uuid,
        size_delta: i64,
        count_delta: i64,
    ) -> Result<(), RepoError> {
        self.mutate(id, |b| {
            b.size_bytes += size_delta;
            b.object_count += count_delta;
        })
    }

    async fn increment_egress(&self, id: Uuid, bytes: i64) -> Result<(), RepoError> {
        self.mutate(id, |b| b.egress_bytes += bytes)
    }

    async fn update_egress_watermark(&self, id: Uuid, new_watermark: i64) -> Result<(), RepoError> {
        {
            let mut fail_after = self.fail_update_egress_watermark_after.lock().unwrap();
            if let Some(remaining_successes) = fail_after.as_mut() {
                if *remaining_successes == 0 {
                    *fail_after = None;
                    return Err(RepoError::Other(
                        "injected update_egress_watermark failure".into(),
                    ));
                }
                *remaining_successes -= 1;
            }
        }
        self.mutate(id, |b| b.egress_watermark_bytes = new_watermark)
    }

    async fn set_deleted(&self, id: Uuid) -> Result<(), RepoError> {
        self.mutate(id, |b| b.status = "deleted".to_string())
    }
}
