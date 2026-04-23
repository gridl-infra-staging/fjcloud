//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/migration/validation.rs.
use uuid::Uuid;

use crate::models::vm_inventory::VmInventory;

use super::{MigrationError, MigrationRequest, MigrationService};

impl MigrationService {
    /// Validates a migration request: ensures source and destination VMs
    /// differ, both exist in the inventory, and the destination VM is in
    /// "active" status. Returns the loaded [`VmInventory`] pair on success.
    pub(super) async fn validate_request(
        &self,
        req: &MigrationRequest,
    ) -> Result<(VmInventory, VmInventory), MigrationError> {
        if req.source_vm_id == req.dest_vm_id {
            return Err(MigrationError::Protocol(
                "source VM and destination VM must differ".to_string(),
            ));
        }

        let source_vm = self.load_vm(req.source_vm_id).await?;
        let dest_vm = self.load_vm(req.dest_vm_id).await?;

        if dest_vm.status != "active" {
            return Err(MigrationError::Protocol(format!(
                "destination VM must be active (vm_id={}, status={})",
                dest_vm.id, dest_vm.status
            )));
        }

        Ok((source_vm, dest_vm))
    }

    pub(super) async fn load_vm(&self, vm_id: Uuid) -> Result<VmInventory, MigrationError> {
        self.vm_inventory_repo
            .get(vm_id)
            .await
            .map_err(|err| MigrationError::Repo(err.to_string()))?
            .ok_or(MigrationError::VmNotFound(vm_id))
    }
}
