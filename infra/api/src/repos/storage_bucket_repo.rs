//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/repos/storage_bucket_repo.rs.
use async_trait::async_trait;
use uuid::Uuid;

use crate::models::storage::{NewStorageBucket, StorageBucket};
use crate::repos::error::RepoError;

/// Object-storage bucket repository: CRUD, atomic size/object-count and
/// egress-byte counters, egress watermark resets for billing cycles, and
/// soft deletion.
#[async_trait]
pub trait StorageBucketRepo {
    /// Create a new storage bucket.
    async fn create(
        &self,
        bucket: NewStorageBucket,
        garage_bucket: &str,
    ) -> Result<StorageBucket, RepoError>;

    /// Get a bucket by ID.
    async fn get(&self, id: Uuid) -> Result<Option<StorageBucket>, RepoError>;

    /// Get an active bucket by customer ID and name.
    async fn get_by_name(
        &self,
        customer_id: Uuid,
        name: &str,
    ) -> Result<Option<StorageBucket>, RepoError>;

    /// List all active buckets for a customer.
    async fn list_by_customer(&self, customer_id: Uuid) -> Result<Vec<StorageBucket>, RepoError>;

    /// List all active buckets across all customers (for billing).
    async fn list_all(&self) -> Result<Vec<StorageBucket>, RepoError>;

    /// Atomically adjust size_bytes and object_count.
    async fn increment_size(
        &self,
        id: Uuid,
        size_delta: i64,
        count_delta: i64,
    ) -> Result<(), RepoError>;

    /// Atomically increment egress_bytes.
    async fn increment_egress(&self, id: Uuid, bytes: i64) -> Result<(), RepoError>;

    /// Set egress_watermark_bytes to a new value (for billing cycle resets).
    async fn update_egress_watermark(&self, id: Uuid, new_watermark: i64) -> Result<(), RepoError>;

    /// Soft-delete a bucket by setting status to 'deleted'.
    async fn set_deleted(&self, id: Uuid) -> Result<(), RepoError>;
}
