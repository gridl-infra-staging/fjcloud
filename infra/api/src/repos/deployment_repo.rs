use async_trait::async_trait;
use chrono::{DateTime, Utc};
use uuid::Uuid;

use crate::models::vm_inventory::VmInventory;
use crate::models::Deployment;
use crate::repos::error::RepoError;

/// Deployment lifecycle repository: VM creation, atomic provisioning claims
/// (prevents duplicate side-effects), health monitoring, and termination.
/// Provisioning updates are batched (VM ID, IP, hostname, flapjack URL).
#[async_trait]
pub trait DeploymentRepo {
    async fn list_by_customer(
        &self,
        customer_id: Uuid,
        include_terminated: bool,
    ) -> Result<Vec<Deployment>, RepoError>;

    async fn find_by_id(&self, id: Uuid) -> Result<Option<Deployment>, RepoError>;

    /// Finds the requested deployments with the same raw inclusion semantics
    /// as `find_by_id`; status and `flapjack_url` are not filtered.
    async fn find_by_ids(&self, ids: &[Uuid]) -> Result<Vec<Deployment>, RepoError>;

    async fn create_running_shared_deployment(
        &self,
        customer_id: Uuid,
        region: &str,
        vm: &VmInventory,
    ) -> Result<Deployment, RepoError>;

    async fn create(
        &self,
        customer_id: Uuid,
        node_id: &str,
        region: &str,
        vm_type: &str,
        vm_provider: &str,
        ip_address: Option<&str>,
    ) -> Result<Deployment, RepoError>;

    async fn update(
        &self,
        id: Uuid,
        ip_address: Option<&str>,
        status: Option<&str>,
    ) -> Result<Option<Deployment>, RepoError>;

    async fn terminate(&self, id: Uuid) -> Result<bool, RepoError>;

    /// All non-terminated deployments that have a `flapjack_url` set
    /// (for health monitor — can't health-check a VM that hasn't finished provisioning).
    async fn list_active(&self) -> Result<Vec<Deployment>, RepoError>;

    /// Update health_status and last_health_check_at for a deployment.
    async fn update_health(
        &self,
        id: Uuid,
        health_status: &str,
        last_health_check_at: DateTime<Utc>,
    ) -> Result<(), RepoError>;

    /// Atomically claim a deployment for provisioning side effects.
    ///
    /// Returns `true` only for the first caller while the deployment is still
    /// in `provisioning` state and unclaimed. Subsequent concurrent callers
    /// must receive `false` and avoid creating VM/DNS/secret side effects.
    async fn claim_provisioning(&self, id: Uuid) -> Result<bool, RepoError>;

    /// Mark a provisioning deployment as failed and clear any transient claim state.
    ///
    /// This is used by provisioning rollback/error paths to ensure synthetic
    /// claim markers (if any) do not leak into persisted deployment metadata.
    async fn mark_failed_provisioning(
        &self,
        id: Uuid,
        failure_reason: Option<&str>,
    ) -> Result<bool, RepoError>;

    /// Batch update after VM creation + DNS setup.
    async fn update_provisioning(
        &self,
        id: Uuid,
        provider_vm_id: &str,
        ip_address: &str,
        hostname: &str,
        flapjack_url: &str,
    ) -> Result<Option<Deployment>, RepoError>;
}
