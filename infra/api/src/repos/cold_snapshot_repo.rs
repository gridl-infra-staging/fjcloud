//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/repos/cold_snapshot_repo.rs.
use async_trait::async_trait;
use chrono::NaiveDate;
use uuid::Uuid;

use crate::models::cold_snapshot::{ColdSnapshot, NewColdSnapshot};
use crate::repos::error::RepoError;

/// Cold-snapshot repository: lifecycle transitions for offloaded index
/// snapshots (pending → exporting → completed/failed → expired) and
/// billing-period queries for completed snapshots.
#[async_trait]
pub trait ColdSnapshotRepo {
    /// Insert a new cold snapshot record.
    async fn create(&self, snapshot: NewColdSnapshot) -> Result<ColdSnapshot, RepoError>;

    /// Get a snapshot by id.
    async fn get(&self, id: Uuid) -> Result<Option<ColdSnapshot>, RepoError>;

    /// Find the active (pending/exporting/completed) snapshot for a customer's index.
    async fn find_active_for_index(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
    ) -> Result<Option<ColdSnapshot>, RepoError>;

    /// Transition snapshot to exporting state.
    async fn set_exporting(&self, id: Uuid) -> Result<(), RepoError>;

    /// Transition snapshot to completed state with size and checksum.
    async fn set_completed(
        &self,
        id: Uuid,
        size_bytes: i64,
        checksum: &str,
    ) -> Result<(), RepoError>;

    /// Transition snapshot to failed state with error message.
    async fn set_failed(&self, id: Uuid, error: &str) -> Result<(), RepoError>;

    /// Mark snapshot as expired.
    async fn set_expired(&self, id: Uuid) -> Result<(), RepoError>;

    /// List snapshots that were in `completed` status during the billing period.
    /// Includes snapshots completed before the period that haven't expired/failed.
    async fn list_completed_for_billing(
        &self,
        period_start: NaiveDate,
        period_end: NaiveDate,
    ) -> Result<Vec<ColdSnapshot>, RepoError>;
}
