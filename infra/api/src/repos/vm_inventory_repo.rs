//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/repos/vm_inventory_repo.rs.
use async_trait::async_trait;
use uuid::Uuid;

use crate::models::vm_inventory::{NewVmInventory, VmInventory};
use crate::repos::error::RepoError;

/// VM inventory repository: physical VM fleet tracking with creation,
/// load-metric JSONB updates, status transitions (active → draining →
/// decommissioned), and region-filtered active-VM queries.
#[async_trait]
pub trait VmInventoryRepo {
    /// All VMs with status=active, optionally filtered by region.
    async fn list_active(&self, region: Option<&str>) -> Result<Vec<VmInventory>, RepoError>;

    /// Get a single VM by id.
    async fn get(&self, id: Uuid) -> Result<Option<VmInventory>, RepoError>;

    /// Insert a new VM into the inventory.
    async fn create(&self, vm: NewVmInventory) -> Result<VmInventory, RepoError>;

    /// Update the current_load JSONB for a VM (called by scheduler after scraping metrics).
    async fn update_load(&self, id: Uuid, load: serde_json::Value) -> Result<(), RepoError>;

    /// Transition VM status (active → draining → decommissioned).
    async fn set_status(&self, id: Uuid, status: &str) -> Result<(), RepoError>;

    /// Look up a VM by its hostname.
    async fn find_by_hostname(&self, hostname: &str) -> Result<Option<VmInventory>, RepoError>;
}
