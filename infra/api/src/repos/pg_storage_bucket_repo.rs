//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/repos/pg_storage_bucket_repo.rs.
use async_trait::async_trait;
use sqlx::PgPool;
use uuid::Uuid;

use crate::models::storage::{NewStorageBucket, StorageBucket};
use crate::repos::error::{is_unique_violation, RepoError};
use crate::repos::storage_bucket_repo::StorageBucketRepo;

pub struct PgStorageBucketRepo {
    pool: PgPool,
}

impl PgStorageBucketRepo {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl StorageBucketRepo for PgStorageBucketRepo {
    /// Inserts a new storage bucket and returns the created record.
    /// Returns `RepoError::AlreadyExists` on duplicate bucket name.
    async fn create(
        &self,
        bucket: NewStorageBucket,
        garage_bucket: &str,
    ) -> Result<StorageBucket, RepoError> {
        sqlx::query_as::<_, StorageBucket>(
            "INSERT INTO storage_buckets (customer_id, name, garage_bucket) \
             VALUES ($1, $2, $3) RETURNING *",
        )
        .bind(bucket.customer_id)
        .bind(&bucket.name)
        .bind(garage_bucket)
        .fetch_one(&self.pool)
        .await
        .map_err(|e| {
            if is_unique_violation(&e) {
                RepoError::Conflict(format!(
                    "active bucket '{}' already exists for customer",
                    bucket.name
                ))
            } else {
                RepoError::Other(e.to_string())
            }
        })
    }

    async fn get(&self, id: Uuid) -> Result<Option<StorageBucket>, RepoError> {
        sqlx::query_as::<_, StorageBucket>("SELECT * FROM storage_buckets WHERE id = $1")
            .bind(id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn get_by_name(
        &self,
        customer_id: Uuid,
        name: &str,
    ) -> Result<Option<StorageBucket>, RepoError> {
        sqlx::query_as::<_, StorageBucket>(
            "SELECT * FROM storage_buckets \
             WHERE customer_id = $1 AND name = $2 AND status != 'deleted'",
        )
        .bind(customer_id)
        .bind(name)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn list_by_customer(&self, customer_id: Uuid) -> Result<Vec<StorageBucket>, RepoError> {
        sqlx::query_as::<_, StorageBucket>(
            "SELECT * FROM storage_buckets \
             WHERE customer_id = $1 AND status != 'deleted' \
             ORDER BY created_at",
        )
        .bind(customer_id)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn list_all(&self) -> Result<Vec<StorageBucket>, RepoError> {
        sqlx::query_as::<_, StorageBucket>(
            "SELECT * FROM storage_buckets WHERE status != 'deleted' ORDER BY created_at",
        )
        .fetch_all(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    /// Atomically increments `size_bytes` and `object_count` by the given deltas.
    async fn increment_size(
        &self,
        id: Uuid,
        size_delta: i64,
        count_delta: i64,
    ) -> Result<(), RepoError> {
        let result = sqlx::query(
            "UPDATE storage_buckets \
             SET size_bytes = size_bytes + $2, \
                 object_count = object_count + $3, \
                 updated_at = NOW() \
             WHERE id = $1",
        )
        .bind(id)
        .bind(size_delta)
        .bind(count_delta)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        if result.rows_affected() == 0 {
            return Err(RepoError::NotFound);
        }
        Ok(())
    }

    /// Atomically increments `egress_bytes` by the given delta.
    async fn increment_egress(&self, id: Uuid, bytes: i64) -> Result<(), RepoError> {
        let result = sqlx::query(
            "UPDATE storage_buckets \
             SET egress_bytes = egress_bytes + $2, \
                 updated_at = NOW() \
             WHERE id = $1",
        )
        .bind(id)
        .bind(bytes)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        if result.rows_affected() == 0 {
            return Err(RepoError::NotFound);
        }
        Ok(())
    }

    /// Sets the egress watermark to the given value.
    /// Returns `RepoError::NotFound` if the bucket does not exist.
    async fn update_egress_watermark(&self, id: Uuid, new_watermark: i64) -> Result<(), RepoError> {
        let result = sqlx::query(
            "UPDATE storage_buckets \
             SET egress_watermark_bytes = $2, \
                 updated_at = NOW() \
             WHERE id = $1",
        )
        .bind(id)
        .bind(new_watermark)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        if result.rows_affected() == 0 {
            return Err(RepoError::NotFound);
        }
        Ok(())
    }

    /// Soft-deletes the bucket by setting its status to `deleted`.
    async fn set_deleted(&self, id: Uuid) -> Result<(), RepoError> {
        let result = sqlx::query(
            "UPDATE storage_buckets \
             SET status = 'deleted', updated_at = NOW() \
             WHERE id = $1",
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
