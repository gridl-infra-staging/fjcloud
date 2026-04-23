//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/scheduler/overload.rs.
use std::collections::HashMap;

use chrono::{DateTime, Utc};
use tracing::{info, warn};
use uuid::Uuid;

use crate::models::resource_vector::ResourceVector;
use crate::models::vm_inventory::VmInventory;
use crate::services::alerting::{Alert, AlertSeverity};
use crate::services::placement::{place_index, VmWithLoad};

use super::{MigrationRequest, SchedulerService, COLD_TIERS};

impl SchedulerService {
    /// Find the heaviest index on a VM by total_weight of its resource vector.
    fn heaviest_index(per_index_vectors: &HashMap<String, ResourceVector>) -> Option<String> {
        per_index_vectors
            .iter()
            .max_by(|left, right| {
                left.1
                    .total_weight()
                    .partial_cmp(&right.1.total_weight())
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
            .map(|(name, _)| name.clone())
    }

    pub(super) fn build_same_provider_candidates(
        source_vm: &VmInventory,
        all_vms: &[VmInventory],
        vm_loads: &HashMap<Uuid, ResourceVector>,
        vm_scraped_at: &HashMap<Uuid, DateTime<Utc>>,
    ) -> Vec<VmWithLoad> {
        Self::build_candidate_vms(all_vms, vm_loads, vm_scraped_at, |vm| {
            vm.status == "active" && vm.id != source_vm.id && vm.provider == source_vm.provider
        })
    }

    /// Filters VMs through `predicate` and wraps each with its current load for
    /// placement scoring. VMs missing from `vm_loads` (no metrics yet) are
    /// excluded. `load_scraped_at` prefers the cycle-level timestamp from
    /// `vm_scraped_at`, falling back to the VM's persisted value.
    pub(super) fn build_candidate_vms<F>(
        all_vms: &[VmInventory],
        vm_loads: &HashMap<Uuid, ResourceVector>,
        vm_scraped_at: &HashMap<Uuid, DateTime<Utc>>,
        mut predicate: F,
    ) -> Vec<VmWithLoad>
    where
        F: FnMut(&VmInventory) -> bool,
    {
        all_vms
            .iter()
            .filter(|vm| predicate(vm))
            .filter_map(|vm| {
                vm_loads.get(&vm.id).map(|current_load| VmWithLoad {
                    vm_id: vm.id,
                    capacity: ResourceVector::from(vm.capacity.clone()),
                    current_load: current_load.clone(),
                    status: vm.status.clone(),
                    load_scraped_at: Self::candidate_load_scraped_at(vm, vm_scraped_at),
                })
            })
            .collect()
    }

    fn candidate_load_scraped_at(
        vm: &VmInventory,
        vm_scraped_at: &HashMap<Uuid, DateTime<Utc>>,
    ) -> Option<DateTime<Utc>> {
        vm_scraped_at
            .get(&vm.id)
            .cloned()
            .or_else(|| vm.load_scraped_at.as_ref().cloned())
    }

    /// Handle overload detection for a VM. Returns true if a migration was triggered.
    pub(super) async fn handle_overload(
        &self,
        vm: &VmInventory,
        per_index_vectors: &HashMap<String, ResourceVector>,
        all_vms: &[VmInventory],
        vm_loads: &HashMap<Uuid, ResourceVector>,
        vm_scraped_at: &HashMap<Uuid, DateTime<Utc>>,
    ) -> bool {
        let Some(heaviest_index_name) = Self::heaviest_index(per_index_vectors) else {
            return false;
        };

        if self.is_overload_migration_in_flight(vm, &heaviest_index_name) {
            return false;
        }

        let Some(index_vector) = per_index_vectors.get(&heaviest_index_name) else {
            return false;
        };

        let Some(customer_id) = self
            .lookup_customer_id_for_index(vm.id, &heaviest_index_name)
            .await
        else {
            return false;
        };

        let candidate_vms =
            Self::build_same_provider_candidates(vm, all_vms, vm_loads, vm_scraped_at);

        let Some(dest_vm_id) = self
            .pick_overload_destination(
                vm,
                &heaviest_index_name,
                index_vector,
                customer_id,
                &candidate_vms,
            )
            .await
        else {
            return false;
        };

        self.request_overload_migration(vm.id, &heaviest_index_name, customer_id, dest_vm_id)
            .await
    }

    /// Returns `true` if `index_name` is already in the `in_flight_migrations`
    /// set, preventing duplicate migration requests within the same cycle.
    fn is_overload_migration_in_flight(&self, vm: &VmInventory, index_name: &str) -> bool {
        if self
            .in_flight_migrations
            .lock()
            .unwrap()
            .contains(index_name)
        {
            info!(
                vm_id = %vm.id,
                index = %index_name,
                "skipping overload migration for index with in-flight migration"
            );
            true
        } else {
            false
        }
    }

    /// Resolves the `customer_id` that owns `index_name` on the given VM.
    /// Queries the tenant repo, filters to active (non-cold) tenants, and
    /// returns `None` on repo failure, missing tenant, or cold tier status.
    async fn lookup_customer_id_for_index(&self, vm_id: Uuid, index_name: &str) -> Option<Uuid> {
        let tenants = match self.tenant_repo.list_by_vm(vm_id).await {
            Ok(tenants) => tenants,
            Err(err) => {
                warn!(
                    vm_id = %vm_id,
                    error = %err,
                    "failed to list tenants for overloaded VM"
                );
                return None;
            }
        };

        let customer_id = tenants
            .iter()
            .find(|tenant| {
                tenant.tenant_id == index_name && !COLD_TIERS.contains(&tenant.tier.as_str())
            })
            .map(|tenant| tenant.customer_id);

        if customer_id.is_none() {
            warn!(
                vm_id = %vm_id,
                index = %index_name,
                "heaviest index not found in tenant catalog"
            );
        }

        customer_id
    }

    /// Selects a destination VM for an overloaded index via [`place_index`].
    /// Only considers same-provider candidates. If no VM has sufficient
    /// capacity, sends a "cross-provider migration blocked" warning alert and
    /// returns `None`.
    async fn pick_overload_destination(
        &self,
        vm: &VmInventory,
        index_name: &str,
        index_vector: &ResourceVector,
        customer_id: Uuid,
        candidate_vms: &[crate::services::placement::VmWithLoad],
    ) -> Option<Uuid> {
        let destination_vm_id = place_index(index_vector, candidate_vms);
        if let Some(dest_vm_id) = destination_vm_id {
            return Some(dest_vm_id);
        }

        warn!(
            vm_id = %vm.id,
            index = %index_name,
            provider = %vm.provider,
            "overloaded VM: no same-provider destination available for heaviest index"
        );

        self.send_overload_blocked_alert(vm, index_name, customer_id)
            .await;
        None
    }

    /// Fires a `Warning`-severity alert when no same-provider destination is
    /// available for an overload migration. Metadata includes `index_name`,
    /// `customer_id`, `source_vm_id`, `source_provider`, and
    /// `reason="overload"`.
    async fn send_overload_blocked_alert(
        &self,
        vm: &VmInventory,
        index_name: &str,
        customer_id: Uuid,
    ) {
        let alert = Alert {
            severity: AlertSeverity::Warning,
            title: format!("Cross-provider migration blocked for index {index_name}"),
            message: format!(
                "Automatic overload migration for index '{}' on provider '{}' was skipped because no same-provider destination with capacity is available. Cross-provider migrations must be admin-triggered.",
                index_name, vm.provider
            ),
            metadata: HashMap::from([
                ("index_name".to_string(), index_name.to_string()),
                ("customer_id".to_string(), customer_id.to_string()),
                ("source_vm_id".to_string(), vm.id.to_string()),
                ("source_provider".to_string(), vm.provider.clone()),
                ("reason".to_string(), "overload".to_string()),
            ]),
        };

        if let Err(err) = self.alert_service.send_alert(alert).await {
            warn!(
                vm_id = %vm.id,
                index = %index_name,
                error = %err,
                "failed to send cross-provider blocked warning alert"
            );
        }
    }

    /// Submits a migration request with `reason="overload"` to the migration
    /// service. On success, adds the index to `in_flight_migrations` and returns
    /// `true`. On failure, logs a warning and returns `false`.
    async fn request_overload_migration(
        &self,
        source_vm_id: Uuid,
        index_name: &str,
        customer_id: Uuid,
        dest_vm_id: Uuid,
    ) -> bool {
        let request = MigrationRequest {
            index_name: index_name.to_string(),
            customer_id,
            source_vm_id,
            dest_vm_id,
            reason: "overload".to_string(),
        };

        if let Err(err) = self.migration_service.request_migration(request).await {
            warn!(
                vm_id = %source_vm_id,
                index = %index_name,
                error = %err,
                "failed to request overload migration"
            );
            return false;
        }

        self.in_flight_migrations
            .lock()
            .unwrap()
            .insert(index_name.to_string());

        info!(
            vm_id = %source_vm_id,
            index = %index_name,
            dest_vm_id = %dest_vm_id,
            "overload migration requested"
        );

        true
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use chrono::Utc;
    use serde_json::json;
    use uuid::Uuid;

    use crate::models::resource_vector::ResourceVector;
    use crate::models::vm_inventory::VmInventory;

    use super::super::SchedulerService;

    /// Verifies that `build_candidate_vms` applies the predicate filter, prefers
    /// cycle-level `vm_scraped_at` over the VM's fallback timestamp, and
    /// excludes VMs missing from `vm_loads`.
    #[test]
    fn build_candidate_vms_filters_and_resolves_scrape_timestamps() {
        let included_vm_id = Uuid::new_v4();
        let fallback_vm_id = Uuid::new_v4();
        let missing_load_vm_id = Uuid::new_v4();
        let excluded_vm_id = Uuid::new_v4();
        let fallback_scraped_at = Utc::now();
        let cycle_scraped_at = Utc::now() + chrono::Duration::seconds(5);

        let all_vms = vec![
            test_vm(
                included_vm_id,
                "aws",
                "us-east-1",
                Some(fallback_scraped_at),
                "active",
            ),
            test_vm(
                fallback_vm_id,
                "aws",
                "us-east-1",
                Some(fallback_scraped_at),
                "active",
            ),
            test_vm(missing_load_vm_id, "aws", "us-east-1", None, "active"),
            test_vm(excluded_vm_id, "gcp", "us-west-2", None, "draining"),
        ];
        let vm_loads = HashMap::from([
            (
                included_vm_id,
                ResourceVector {
                    cpu_weight: 1.5,
                    mem_rss_bytes: 2,
                    disk_bytes: 3,
                    query_rps: 4.0,
                    indexing_rps: 5.0,
                },
            ),
            (
                fallback_vm_id,
                ResourceVector {
                    cpu_weight: 2.5,
                    mem_rss_bytes: 4,
                    disk_bytes: 6,
                    query_rps: 8.0,
                    indexing_rps: 10.0,
                },
            ),
        ]);
        let vm_scraped_at = HashMap::from([(included_vm_id, cycle_scraped_at)]);

        let candidates =
            SchedulerService::build_candidate_vms(&all_vms, &vm_loads, &vm_scraped_at, |vm| {
                vm.provider == "aws" && vm.region == "us-east-1" && vm.status == "active"
            });

        assert_eq!(candidates.len(), 2);
        let included = candidates
            .iter()
            .find(|candidate| candidate.vm_id == included_vm_id)
            .expect("included vm should be present");
        assert_eq!(included.current_load, vm_loads[&included_vm_id]);
        assert_eq!(included.load_scraped_at, Some(cycle_scraped_at));
        assert_eq!(included.capacity.cpu_weight, 8.0);

        let fallback = candidates
            .iter()
            .find(|candidate| candidate.vm_id == fallback_vm_id)
            .expect("fallback vm should be present");
        assert_eq!(fallback.current_load, vm_loads[&fallback_vm_id]);
        assert_eq!(fallback.load_scraped_at, Some(fallback_scraped_at));
    }

    #[test]
    fn heaviest_index_returns_none_for_empty() {
        let map: HashMap<String, ResourceVector> = HashMap::new();
        assert!(SchedulerService::heaviest_index(&map).is_none());
    }

    /// Verifies that `heaviest_index` returns the index with the highest
    /// `total_weight` when multiple indexes are present.
    #[test]
    fn heaviest_index_returns_highest_total_weight() {
        let mut map = HashMap::new();
        map.insert(
            "light".to_string(),
            ResourceVector {
                cpu_weight: 0.5,
                mem_rss_bytes: 100,
                disk_bytes: 100,
                query_rps: 1.0,
                indexing_rps: 1.0,
            },
        );
        map.insert(
            "heavy".to_string(),
            ResourceVector {
                cpu_weight: 4.0,
                mem_rss_bytes: 4_000_000_000,
                disk_bytes: 10_000_000_000,
                query_rps: 200.0,
                indexing_rps: 100.0,
            },
        );
        assert_eq!(
            SchedulerService::heaviest_index(&map),
            Some("heavy".to_string())
        );
    }

    /// Test helper: creates a [`VmInventory`] with the given provider, region,
    /// `load_scraped_at`, and status for scheduler unit tests.
    fn test_vm(
        id: Uuid,
        provider: &str,
        region: &str,
        load_scraped_at: Option<chrono::DateTime<Utc>>,
        status: &str,
    ) -> VmInventory {
        let now = Utc::now();
        VmInventory {
            id,
            region: region.to_string(),
            provider: provider.to_string(),
            hostname: format!("{provider}-{region}"),
            flapjack_url: format!("http://{provider}-{region}.example"),
            capacity: json!({
                "cpu_weight": 8.0,
                "mem_rss_bytes": 8192,
                "disk_bytes": 16384,
                "query_rps": 200.0,
                "indexing_rps": 100.0,
            }),
            current_load: json!({}),
            load_scraped_at,
            status: status.to_string(),
            created_at: now,
            updated_at: now,
        }
    }
}
