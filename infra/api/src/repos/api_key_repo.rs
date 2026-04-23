//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/repos/api_key_repo.rs.
use async_trait::async_trait;
use uuid::Uuid;

use crate::models::api_key::ApiKeyRow;
use crate::repos::error::RepoError;

/// API key management repository: scoped key creation, lookup by ID or
/// prefix for authentication, revocation, and last-used timestamp tracking.
#[async_trait]
pub trait ApiKeyRepo {
    async fn create(
        &self,
        customer_id: Uuid,
        name: &str,
        key_hash: &str,
        key_prefix: &str,
        scopes: &[String],
    ) -> Result<ApiKeyRow, RepoError>;

    async fn list_by_customer(&self, customer_id: Uuid) -> Result<Vec<ApiKeyRow>, RepoError>;

    async fn find_by_id(&self, id: Uuid) -> Result<Option<ApiKeyRow>, RepoError>;

    async fn find_by_prefix(&self, key_prefix: &str) -> Result<Vec<ApiKeyRow>, RepoError>;

    async fn revoke(&self, id: Uuid) -> Result<ApiKeyRow, RepoError>;

    async fn update_last_used(&self, id: Uuid) -> Result<(), RepoError>;
}
