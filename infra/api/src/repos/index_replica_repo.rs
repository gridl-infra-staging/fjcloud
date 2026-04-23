//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/repos/index_replica_repo.rs.
use async_trait::async_trait;
use uuid::Uuid;

use crate::models::index_replica::IndexReplica;
use crate::repos::error::RepoError;

/// Index-replica repository: manages read replicas across the fleet.
/// Tracks replica status, replication lag, and provides health-filtered
/// queries for discovery and fleet-wide listing for admin/orchestrator.
#[async_trait]
pub trait IndexReplicaRepo: Send + Sync {
    /// Insert a new replica record.
    async fn create(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
        primary_vm_id: Uuid,
        replica_vm_id: Uuid,
        replica_region: &str,
    ) -> Result<IndexReplica, RepoError>;

    /// Lookup by id.
    async fn get(&self, id: Uuid) -> Result<Option<IndexReplica>, RepoError>;

    /// All replicas for an index.
    async fn list_by_index(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
    ) -> Result<Vec<IndexReplica>, RepoError>;

    /// All replicas in active status (for discovery).
    async fn list_healthy_by_index(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
    ) -> Result<Vec<IndexReplica>, RepoError>;

    /// Update replica status.
    async fn set_status(&self, id: Uuid, status: &str) -> Result<(), RepoError>;

    /// Update replication lag.
    async fn set_lag(&self, id: Uuid, lag_ops: i64) -> Result<(), RepoError>;

    /// Delete a replica record.
    async fn delete(&self, id: Uuid) -> Result<bool, RepoError>;

    /// Count replicas for a given index.
    async fn count_by_index(&self, customer_id: Uuid, tenant_id: &str) -> Result<i64, RepoError>;

    /// All non-terminal replicas (for orchestrator scanning).
    /// Returns replicas not in `failed` or `removing` status.
    async fn list_actionable(&self) -> Result<Vec<IndexReplica>, RepoError>;

    /// All replicas across the fleet (for admin views).
    async fn list_all(&self) -> Result<Vec<IndexReplica>, RepoError>;
}
