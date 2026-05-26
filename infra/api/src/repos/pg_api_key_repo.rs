//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/repos/pg_api_key_repo.rs.
use async_trait::async_trait;
use sqlx::PgPool;
use uuid::Uuid;

use crate::models::api_key::ApiKeyRow;
use crate::repos::api_key_repo::{ApiKeyManagedKeyParams, ApiKeyRepo};
use crate::repos::error::RepoError;

pub struct PgApiKeyRepo {
    pool: PgPool,
}

impl PgApiKeyRepo {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl ApiKeyRepo for PgApiKeyRepo {
    /// Inserts a new API key row with the given hash, prefix, and scopes,
    /// and returns the created record.
    async fn create(
        &self,
        customer_id: Uuid,
        name: &str,
        key_hash: &str,
        key_prefix: &str,
        scopes: &[String],
        managed: ApiKeyManagedKeyParams,
    ) -> Result<ApiKeyRow, RepoError> {
        sqlx::query_as::<_, ApiKeyRow>(
            "INSERT INTO api_keys (
                customer_id, name, description, key_hash, key_prefix, scopes,
                indexes, restrict_sources, expires_at, max_hits_per_query, max_queries_per_ip_per_hour
            ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11) RETURNING *",
        )
        .bind(customer_id)
        .bind(name)
        .bind(managed.description)
        .bind(key_hash)
        .bind(key_prefix)
        .bind(scopes)
        .bind(managed.indexes)
        .bind(managed.restrict_sources)
        .bind(managed.expires_at)
        .bind(managed.max_hits_per_query)
        .bind(managed.max_queries_per_ip_per_hour)
        .fetch_one(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn list_by_customer(&self, customer_id: Uuid) -> Result<Vec<ApiKeyRow>, RepoError> {
        sqlx::query_as::<_, ApiKeyRow>(
            "SELECT * FROM api_keys \
             WHERE customer_id = $1 AND revoked_at IS NULL \
             ORDER BY created_at DESC",
        )
        .bind(customer_id)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn find_by_id(&self, id: Uuid) -> Result<Option<ApiKeyRow>, RepoError> {
        sqlx::query_as::<_, ApiKeyRow>("SELECT * FROM api_keys WHERE id = $1")
            .bind(id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn find_by_prefix(&self, key_prefix: &str) -> Result<Vec<ApiKeyRow>, RepoError> {
        sqlx::query_as::<_, ApiKeyRow>(
            "SELECT * FROM api_keys \
             WHERE key_prefix = $1 AND revoked_at IS NULL",
        )
        .bind(key_prefix)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn revoke(&self, id: Uuid) -> Result<ApiKeyRow, RepoError> {
        sqlx::query_as::<_, ApiKeyRow>(
            "UPDATE api_keys SET revoked_at = NOW() \
             WHERE id = $1 AND revoked_at IS NULL \
             RETURNING *",
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?
        .ok_or_else(|| RepoError::Conflict("key not found or already revoked".into()))
    }

    async fn update_last_used(&self, id: Uuid) -> Result<(), RepoError> {
        sqlx::query("UPDATE api_keys SET last_used_at = NOW() WHERE id = $1")
            .bind(id)
            .execute(&self.pool)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))?;
        Ok(())
    }
}
