//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/repos/storage_key_repo.rs.
use async_trait::async_trait;
use uuid::Uuid;

use crate::models::storage::{PreparedStorageAccessKey, StorageAccessKeyRow};
use crate::repos::error::RepoError;

pub(crate) fn duplicate_storage_access_key_error() -> RepoError {
    RepoError::Conflict("storage access key already exists".to_string())
}

/// Storage access-key repository: creation with pre-encrypted secrets,
/// lookup by public access-key string, per-bucket listing, and revocation.
#[async_trait]
pub trait StorageKeyRepo {
    /// Insert a new access key with pre-encrypted secret.
    async fn create(&self, key: PreparedStorageAccessKey)
        -> Result<StorageAccessKeyRow, RepoError>;

    /// Get a key row by its internal ID.
    async fn get(&self, id: Uuid) -> Result<Option<StorageAccessKeyRow>, RepoError>;

    /// Look up an access key row by its public access key string.
    async fn get_by_access_key(
        &self,
        access_key: &str,
    ) -> Result<Option<StorageAccessKeyRow>, RepoError>;

    /// List all non-revoked keys for a bucket.
    async fn list_active_for_bucket(
        &self,
        bucket_id: Uuid,
    ) -> Result<Vec<StorageAccessKeyRow>, RepoError>;

    /// Revoke a key by setting revoked_at.
    async fn revoke(&self, id: Uuid) -> Result<(), RepoError>;
}
