//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/scheduler/initial_placement.rs.
use std::collections::HashMap;

use chrono::{DateTime, Utc};
use tracing::{info, warn};
use uuid::Uuid;

use crate::models::resource_vector::ResourceVector;
use crate::models::tenant::CustomerTenant;
use crate::models::vm_inventory::VmInventory;
use crate::services::placement::place_index;

use super::{SchedulerService, COLD_TIERS};

impl SchedulerService {
    /// Estimates a resource vector for an unplaced index from its tenant quota.
    ///
    /// Uses heuristics before real metrics are available: `cpu_weight` from
    /// query and write RPS limits, `mem_rss_bytes` as 1/10 of storage quota,
    /// `disk_bytes` as the full storage quota. Negative values are clamped to
    /// 0.0.
    fn estimate_unplaced_index_vector(quota: &serde_json::Value) -> ResourceVector {
        let query_rps = quota
            .get("max_query_rps")
            .and_then(|v| v.as_f64())
            .unwrap_or(0.0)
            .max(0.0);
        let indexing_rps = quota
            .get("max_write_rps")
            .and_then(|v| v.as_f64())
            .unwrap_or(0.0)
            .max(0.0);
        let disk_bytes = quota
            .get("max_storage_bytes")
            .and_then(|v| v.as_u64())
            .unwrap_or(0);

        ResourceVector {
            // Heuristic estimate used only for initial placement before real metrics exist.
            cpu_weight: (query_rps / 100.0) + (indexing_rps / 50.0),
            mem_rss_bytes: disk_bytes / 10,
            disk_bytes,
            query_rps,
            indexing_rps,
        }
    }

    /// Places all unplaced, active (non-cold) indexes onto VMs. For each index,
    /// resolves its region, builds region-specific candidate VMs, calls
    /// [`place_index`], and persists the assignment. Updates `vm_loads` after
    /// each placement so subsequent placements account for accumulated load.
    pub(super) async fn assign_unplaced_indexes(
        &self,
        all_vms: &[VmInventory],
        vm_loads: &mut HashMap<Uuid, ResourceVector>,
        vm_scraped_at: &HashMap<Uuid, DateTime<Utc>>,
    ) {
        let unplaced_tenants = self.load_schedulable_unplaced_indexes().await;

        for tenant in unplaced_tenants {
            let Some(region) = self.resolve_unplaced_index_region(&tenant).await else {
                continue;
            };

            let candidate_vms = Self::build_candidate_vms(all_vms, vm_loads, vm_scraped_at, |vm| {
                vm.status == "active" && vm.region == region
            });
            let index_vector = Self::estimate_unplaced_index_vector(&tenant.resource_quota);
            let dest_vm_id = match place_index(&index_vector, &candidate_vms) {
                Some(vm_id) => vm_id,
                None => {
                    info!(
                        event = "scheduler_unplaced_assignment_skipped",
                        customer_id = %tenant.customer_id,
                        index = %tenant.tenant_id,
                        region = %region,
                        "unplaced index has no placement candidate"
                    );
                    continue;
                }
            };

            if self
                .persist_unplaced_assignment(&tenant, &region, dest_vm_id, &index_vector, vm_loads)
                .await
            {
                continue;
            }
        }
    }

    async fn load_schedulable_unplaced_indexes(&self) -> Vec<CustomerTenant> {
        let unplaced = match self.tenant_repo.list_unplaced().await {
            Ok(rows) => rows,
            Err(err) => {
                warn!(error = %err, "failed to list unplaced indexes");
                return Vec::new();
            }
        };

        // Cold/restoring indexes are managed by restore service, not auto-placed.
        unplaced
            .into_iter()
            .filter(|tenant| !COLD_TIERS.contains(&tenant.tier.as_str()))
            .collect()
    }

    /// Looks up the region for an unplaced index by querying its deployment
    /// summary via the tenant repo. Returns `None` on repo failure or if the
    /// tenant is not found.
    async fn resolve_unplaced_index_region(&self, tenant: &CustomerTenant) -> Option<String> {
        match self
            .tenant_repo
            .find_by_name(tenant.customer_id, &tenant.tenant_id)
            .await
        {
            Ok(Some(summary)) => Some(summary.region),
            Ok(None) => {
                warn!(
                    customer_id = %tenant.customer_id,
                    index = %tenant.tenant_id,
                    "unplaced index missing deployment summary; skipping"
                );
                None
            }
            Err(err) => {
                warn!(
                    customer_id = %tenant.customer_id,
                    index = %tenant.tenant_id,
                    error = %err,
                    "failed to resolve deployment summary for unplaced index"
                );
                None
            }
        }
    }

    /// Persists a placement decision by setting the VM ID on the tenant record
    /// and updating `vm_loads` with the index's estimated resource vector for
    /// use in subsequent placements. Returns `false` if persistence fails.
    async fn persist_unplaced_assignment(
        &self,
        tenant: &CustomerTenant,
        region: &str,
        dest_vm_id: Uuid,
        index_vector: &ResourceVector,
        vm_loads: &mut HashMap<Uuid, ResourceVector>,
    ) -> bool {
        if let Err(err) = self
            .tenant_repo
            .set_vm_id(tenant.customer_id, &tenant.tenant_id, dest_vm_id)
            .await
        {
            warn!(
                customer_id = %tenant.customer_id,
                index = %tenant.tenant_id,
                dest_vm_id = %dest_vm_id,
                error = %err,
                "failed to assign vm_id for unplaced index"
            );
            return false;
        }

        if let Some(load) = vm_loads.get_mut(&dest_vm_id) {
            *load = load.add(index_vector);
        }

        info!(
            event = "scheduler_unplaced_assigned",
            customer_id = %tenant.customer_id,
            index = %tenant.tenant_id,
            region = %region,
            dest_vm_id = %dest_vm_id,
            "assigned unplaced index to VM"
        );

        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn estimate_vector_from_full_quota() {
        let quota = json!({
            "max_query_rps": 200.0,
            "max_write_rps": 100.0,
            "max_storage_bytes": 1_000_000_u64
        });
        let v = SchedulerService::estimate_unplaced_index_vector(&quota);
        // cpu_weight = 200/100 + 100/50 = 2.0 + 2.0 = 4.0
        assert!((v.cpu_weight - 4.0).abs() < f64::EPSILON);
        assert_eq!(v.mem_rss_bytes, 100_000); // disk_bytes / 10
        assert_eq!(v.disk_bytes, 1_000_000);
        assert!((v.query_rps - 200.0).abs() < f64::EPSILON);
        assert!((v.indexing_rps - 100.0).abs() < f64::EPSILON);
    }

    #[test]
    fn estimate_vector_missing_fields_defaults_to_zero() {
        let quota = json!({});
        let v = SchedulerService::estimate_unplaced_index_vector(&quota);
        assert!((v.cpu_weight - 0.0).abs() < f64::EPSILON);
        assert_eq!(v.mem_rss_bytes, 0);
        assert_eq!(v.disk_bytes, 0);
        assert!((v.query_rps - 0.0).abs() < f64::EPSILON);
        assert!((v.indexing_rps - 0.0).abs() < f64::EPSILON);
    }

    #[test]
    fn estimate_vector_negative_rps_clamped_to_zero() {
        let quota = json!({
            "max_query_rps": -50.0,
            "max_write_rps": -10.0,
            "max_storage_bytes": 500_u64
        });
        let v = SchedulerService::estimate_unplaced_index_vector(&quota);
        assert!((v.query_rps - 0.0).abs() < f64::EPSILON);
        assert!((v.indexing_rps - 0.0).abs() < f64::EPSILON);
        assert!((v.cpu_weight - 0.0).abs() < f64::EPSILON);
        assert_eq!(v.disk_bytes, 500);
    }

    #[test]
    fn estimate_vector_null_value_treated_as_zero() {
        let quota = json!({
            "max_query_rps": null,
            "max_write_rps": null,
            "max_storage_bytes": null
        });
        let v = SchedulerService::estimate_unplaced_index_vector(&quota);
        assert!((v.cpu_weight - 0.0).abs() < f64::EPSILON);
        assert_eq!(v.disk_bytes, 0);
    }

    #[test]
    fn estimate_vector_query_only() {
        let quota = json!({ "max_query_rps": 500.0 });
        let v = SchedulerService::estimate_unplaced_index_vector(&quota);
        // cpu_weight = 500/100 + 0/50 = 5.0
        assert!((v.cpu_weight - 5.0).abs() < f64::EPSILON);
        assert!((v.indexing_rps - 0.0).abs() < f64::EPSILON);
    }
}
