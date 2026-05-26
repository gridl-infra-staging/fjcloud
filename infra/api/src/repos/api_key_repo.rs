//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/repos/api_key_repo.rs.
use async_trait::async_trait;
use chrono::{DateTime, Utc};
use uuid::Uuid;

use crate::models::api_key::ApiKeyRow;
use crate::repos::error::RepoError;

/// Managed-key parity fields stored with each API key row.
#[derive(Debug, Clone)]
pub struct ApiKeyManagedKeyParams {
    pub description: Option<String>,
    pub indexes: Vec<String>,
    pub restrict_sources: Vec<String>,
    pub expires_at: Option<DateTime<Utc>>,
    pub max_hits_per_query: Option<i32>,
    pub max_queries_per_ip_per_hour: Option<i32>,
}

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
        managed: ApiKeyManagedKeyParams,
    ) -> Result<ApiKeyRow, RepoError>;

    async fn list_by_customer(&self, customer_id: Uuid) -> Result<Vec<ApiKeyRow>, RepoError>;

    async fn find_by_id(&self, id: Uuid) -> Result<Option<ApiKeyRow>, RepoError>;

    async fn find_by_prefix(&self, key_prefix: &str) -> Result<Vec<ApiKeyRow>, RepoError>;

    async fn revoke(&self, id: Uuid) -> Result<ApiKeyRow, RepoError>;

    async fn update_last_used(&self, id: Uuid) -> Result<(), RepoError>;
}
