//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/scheduler/underload.rs.
use std::collections::HashMap;

use chrono::{DateTime, Utc};
use tracing::{info, warn};
use uuid::Uuid;

use crate::models::resource_vector::ResourceVector;
use crate::models::tenant::CustomerTenant;
use crate::models::vm_inventory::VmInventory;
use crate::services::placement::{place_index, VmWithLoad};

use super::{MigrationRequest, SchedulerService, COLD_TIERS};

impl SchedulerService {
    /// Handle underload detection for a VM: migrate all indexes off, set VM to draining.
    /// Returns true if all indexes were successfully placed (or none existed).
    pub(super) async fn handle_underload(
        &self,
        vm: &VmInventory,
        per_index_vectors: &HashMap<String, ResourceVector>,
        all_vms: &[VmInventory],
        vm_loads: &HashMap<Uuid, ResourceVector>,
        vm_scraped_at: &HashMap<Uuid, DateTime<Utc>>,
    ) -> bool {
        let Some(active_tenants) = self.load_active_underload_tenants(vm).await else {
            return false;
        };

        if active_tenants.is_empty() {
            // No indexes to migrate; just drain
            let _ = self.set_vm_draining(vm.id).await;
            return true;
        }

        let mut candidate_vms =
            Self::build_same_provider_candidates(vm, all_vms, vm_loads, vm_scraped_at);

        let mut all_indexes_placed = true;
        for tenant in &active_tenants {
            let index_vector = per_index_vectors
                .get(&tenant.tenant_id)
                .cloned()
                .unwrap_or_else(ResourceVector::zero);

            if !self
                .request_drain_migration(vm.id, tenant, &index_vector, &mut candidate_vms)
                .await
            {
                all_indexes_placed = false;
            }
        }

        // Only set draining once every index on the source VM has a migration destination.
        if all_indexes_placed && self.set_vm_draining(vm.id).await {
            info!(vm_id = %vm.id, "underloaded VM set to draining");
        }

        all_indexes_placed
    }

    /// Loads all active (non-cold, non-restoring) tenant indexes on a VM.
    /// Returns `None` if the tenant repo query fails.
    async fn load_active_underload_tenants(&self, vm: &VmInventory) -> Option<Vec<CustomerTenant>> {
        let tenants = match self.tenant_repo.list_by_vm(vm.id).await {
            Ok(rows) => rows,
            Err(err) => {
                warn!(
                    vm_id = %vm.id,
                    error = %err,
                    "failed to list tenants for underloaded VM"
                );
                return None;
            }
        };

        Some(
            tenants
                .into_iter()
                .filter(|tenant| !COLD_TIERS.contains(&tenant.tier.as_str()))
                .collect(),
        )
    }

    /// Requests a drain migration for one index via [`place_index`]. On success,
    /// creates a `MigrationRequest` with `reason="drain"`, updates
    /// `candidate_vms` load to reflect the placement, and returns `true`. On
    /// failure (no destination or migration service error), returns `false`.
    async fn request_drain_migration(
        &self,
        source_vm_id: Uuid,
        tenant: &CustomerTenant,
        index_vector: &ResourceVector,
        candidate_vms: &mut [VmWithLoad],
    ) -> bool {
        let dest_vm_id = match place_index(index_vector, candidate_vms) {
            Some(vm_id) => vm_id,
            None => {
                warn!(
                    vm_id = %source_vm_id,
                    index = %tenant.tenant_id,
                    "underload drain: no destination for index"
                );
                return false;
            }
        };

        let request = MigrationRequest {
            index_name: tenant.tenant_id.clone(),
            customer_id: tenant.customer_id,
            source_vm_id,
            dest_vm_id,
            reason: "drain".to_string(),
        };

        if let Err(err) = self.migration_service.request_migration(request).await {
            warn!(
                vm_id = %source_vm_id,
                index = %tenant.tenant_id,
                error = %err,
                "failed to request drain migration"
            );
            return false;
        }

        if let Some(candidate_vm) = candidate_vms
            .iter_mut()
            .find(|candidate| candidate.vm_id == dest_vm_id)
        {
            candidate_vm.current_load = candidate_vm.current_load.add(index_vector);
        }

        true
    }

    async fn set_vm_draining(&self, vm_id: Uuid) -> bool {
        if let Err(err) = self.vm_inventory_repo.set_status(vm_id, "draining").await {
            warn!(vm_id = %vm_id, error = %err, "failed to set underloaded VM to draining");
            return false;
        }

        true
    }
}
