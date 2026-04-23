//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/repos/pg_storage_key_repo.rs.
use async_trait::async_trait;
use sqlx::PgPool;
use uuid::Uuid;

use crate::models::storage::{PreparedStorageAccessKey, StorageAccessKeyRow};
use crate::repos::error::{is_unique_violation, RepoError};
use crate::repos::storage_key_repo::{duplicate_storage_access_key_error, StorageKeyRepo};

pub struct PgStorageKeyRepo {
    pool: PgPool,
}

impl PgStorageKeyRepo {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl StorageKeyRepo for PgStorageKeyRepo {
    /// Inserts a new storage access key and returns the created row.
    /// Returns a duplicate-key error on unique-constraint violation.
    async fn create(
        &self,
        key: PreparedStorageAccessKey,
    ) -> Result<StorageAccessKeyRow, RepoError> {
        sqlx::query_as::<_, StorageAccessKeyRow>(
            "INSERT INTO storage_access_keys \
                 (customer_id, bucket_id, access_key, garage_access_key_id, secret_key_enc, secret_key_nonce, label) \
             VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING *",
        )
        .bind(key.customer_id)
        .bind(key.bucket_id)
        .bind(&key.access_key)
        .bind(&key.garage_access_key_id)
        .bind(&key.secret_key_enc)
        .bind(&key.secret_key_nonce)
        .bind(&key.label)
        .fetch_one(&self.pool)
        .await
        .map_err(|e| {
            if is_unique_violation(&e) {
                duplicate_storage_access_key_error()
            } else {
                RepoError::Other(e.to_string())
            }
        })
    }

    async fn get(&self, id: Uuid) -> Result<Option<StorageAccessKeyRow>, RepoError> {
        sqlx::query_as::<_, StorageAccessKeyRow>("SELECT * FROM storage_access_keys WHERE id = $1")
            .bind(id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn get_by_access_key(
        &self,
        access_key: &str,
    ) -> Result<Option<StorageAccessKeyRow>, RepoError> {
        sqlx::query_as::<_, StorageAccessKeyRow>(
            "SELECT * FROM storage_access_keys \
             WHERE access_key = $1 AND revoked_at IS NULL",
        )
        .bind(access_key)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn list_active_for_bucket(
        &self,
        bucket_id: Uuid,
    ) -> Result<Vec<StorageAccessKeyRow>, RepoError> {
        sqlx::query_as::<_, StorageAccessKeyRow>(
            "SELECT * FROM storage_access_keys \
             WHERE bucket_id = $1 AND revoked_at IS NULL \
             ORDER BY created_at",
        )
        .bind(bucket_id)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    /// Revokes an access key by setting `revoked_at` to now.
    /// Only affects non-revoked keys; returns `NotFound` if no row is updated.
    async fn revoke(&self, id: Uuid) -> Result<(), RepoError> {
        let result = sqlx::query(
            "UPDATE storage_access_keys \
             SET revoked_at = NOW() \
             WHERE id = $1 AND revoked_at IS NULL",
        )
        .bind(id)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        if result.rows_affected() == 0 {
            return Err(RepoError::NotFound);
        }
        Ok(())
    }
}
