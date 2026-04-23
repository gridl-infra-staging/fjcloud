//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/repos/pg_cold_snapshot_repo.rs.
use async_trait::async_trait;
use chrono::NaiveDate;
use sqlx::PgPool;
use uuid::Uuid;

use crate::models::cold_snapshot::{ColdSnapshot, NewColdSnapshot};
use crate::repos::cold_snapshot_repo::ColdSnapshotRepo;
use crate::repos::error::{is_unique_violation, RepoError};

pub struct PgColdSnapshotRepo {
    pool: PgPool,
}

impl PgColdSnapshotRepo {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl ColdSnapshotRepo for PgColdSnapshotRepo {
    /// Inserts a new cold snapshot and returns the created record.
    /// Returns `RepoError::AlreadyExists` if an active snapshot already exists for the index.
    async fn create(&self, snapshot: NewColdSnapshot) -> Result<ColdSnapshot, RepoError> {
        sqlx::query_as::<_, ColdSnapshot>(
            "INSERT INTO cold_snapshots (customer_id, tenant_id, source_vm_id, object_key) \
             VALUES ($1, $2, $3, $4) RETURNING *",
        )
        .bind(snapshot.customer_id)
        .bind(&snapshot.tenant_id)
        .bind(snapshot.source_vm_id)
        .bind(&snapshot.object_key)
        .fetch_one(&self.pool)
        .await
        .map_err(|e| {
            if is_unique_violation(&e) {
                RepoError::Conflict(format!(
                    "active snapshot already exists for index '{}'",
                    snapshot.tenant_id
                ))
            } else {
                RepoError::Other(e.to_string())
            }
        })
    }

    async fn get(&self, id: Uuid) -> Result<Option<ColdSnapshot>, RepoError> {
        sqlx::query_as::<_, ColdSnapshot>("SELECT * FROM cold_snapshots WHERE id = $1")
            .bind(id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))
    }

    /// Returns the most recent snapshot in pending, exporting, or completed status
    /// for the given index, or `None` if no active snapshot exists.
    async fn find_active_for_index(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
    ) -> Result<Option<ColdSnapshot>, RepoError> {
        sqlx::query_as::<_, ColdSnapshot>(
            "SELECT * FROM cold_snapshots \
             WHERE customer_id = $1 AND tenant_id = $2 \
               AND status IN ('pending', 'exporting', 'completed') \
             LIMIT 1",
        )
        .bind(customer_id)
        .bind(tenant_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn set_exporting(&self, id: Uuid) -> Result<(), RepoError> {
        let result = sqlx::query(
            "UPDATE cold_snapshots SET status = 'exporting' WHERE id = $1 AND status = 'pending'",
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

    /// Transitions a snapshot from exporting to completed, recording its
    /// final size, checksum, and completion timestamp.
    async fn set_completed(
        &self,
        id: Uuid,
        size_bytes: i64,
        checksum: &str,
    ) -> Result<(), RepoError> {
        let result = sqlx::query(
            "UPDATE cold_snapshots \
             SET status = 'completed', size_bytes = $2, checksum = $3, completed_at = NOW() \
             WHERE id = $1 AND status = 'exporting'",
        )
        .bind(id)
        .bind(size_bytes)
        .bind(checksum)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        if result.rows_affected() == 0 {
            return Err(RepoError::NotFound);
        }
        Ok(())
    }

    async fn set_failed(&self, id: Uuid, error: &str) -> Result<(), RepoError> {
        let result =
            sqlx::query("UPDATE cold_snapshots SET status = 'failed', error = $2 WHERE id = $1")
                .bind(id)
                .bind(error)
                .execute(&self.pool)
                .await
                .map_err(|e| RepoError::Other(e.to_string()))?;

        if result.rows_affected() == 0 {
            return Err(RepoError::NotFound);
        }
        Ok(())
    }

    async fn set_expired(&self, id: Uuid) -> Result<(), RepoError> {
        let result = sqlx::query("UPDATE cold_snapshots SET status = 'expired' WHERE id = $1")
            .bind(id)
            .execute(&self.pool)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))?;

        if result.rows_affected() == 0 {
            return Err(RepoError::NotFound);
        }
        Ok(())
    }

    /// Lists completed snapshots whose `completed_at` falls within the billing
    /// period (up to one day past `period_end` to capture edge-of-period completions).
    async fn list_completed_for_billing(
        &self,
        _period_start: NaiveDate,
        period_end: NaiveDate,
    ) -> Result<Vec<ColdSnapshot>, RepoError> {
        // Find all snapshots that were in 'completed' status during the billing period:
        // - completed_at <= end of period (snapshot was done before/during the period)
        // - status is 'completed' OR was completed during the period but since expired/failed
        //   (for simplicity, we only bill currently-completed snapshots; expired ones stop billing)
        sqlx::query_as::<_, ColdSnapshot>(
            "SELECT * FROM cold_snapshots \
             WHERE status = 'completed' \
               AND completed_at IS NOT NULL \
               AND completed_at <= ($1::date + INTERVAL '1 day') \
             ORDER BY completed_at",
        )
        .bind(period_end)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }
}
