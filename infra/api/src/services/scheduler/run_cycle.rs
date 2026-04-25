//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/scheduler/run_cycle.rs.
use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use tracing::{info, warn};
use uuid::Uuid;

use crate::models::resource_vector::ResourceVector;
use crate::models::vm_inventory::VmInventory;

use super::{SchedulerError, SchedulerService, COLD_TIERS};

#[derive(Default)]
struct CycleScrapeState {
    vm_loads: HashMap<Uuid, ResourceVector>,
    vm_per_index: HashMap<Uuid, HashMap<String, ResourceVector>>,
    vm_utilizations: HashMap<Uuid, serde_json::Value>,
    vm_scraped_at: HashMap<Uuid, DateTime<Utc>>,
}

struct ScrapedVmState {
    aggregate_load: ResourceVector,
    per_index_vectors: HashMap<String, ResourceVector>,
    utilization: serde_json::Value,
    scraped_at: DateTime<Utc>,
    next_counters: crate::services::prometheus_parser::CounterSnapshot,
}

impl SchedulerService {
    pub(super) fn endpoint_url(base: &str, path: &str) -> String {
        format!(
            "{}/{}",
            base.trim_end_matches('/'),
            path.trim_start_matches('/')
        )
    }

    /// Computes utilization as `load / capacity` per resource dimension.
    ///
    /// Returns a JSON object with keys `cpu_weight`, `mem_rss_bytes`,
    /// `disk_bytes`, `query_rps`, `indexing_rps`. Zero or non-finite capacity
    /// yields 0.0 for that dimension (safe division).
    pub(super) fn calculate_utilization(
        load: &ResourceVector,
        capacity: &ResourceVector,
    ) -> serde_json::Value {
        let safe_div_f64 = |used: f64, cap: f64| {
            if cap > 0.0 && used.is_finite() {
                (used / cap).max(0.0)
            } else {
                0.0
            }
        };
        let safe_div_u64 = |used: u64, cap: u64| {
            if cap > 0 {
                used as f64 / cap as f64
            } else {
                0.0
            }
        };

        serde_json::json!({
            "cpu_weight": safe_div_f64(load.cpu_weight, capacity.cpu_weight),
            "mem_rss_bytes": safe_div_u64(load.mem_rss_bytes, capacity.mem_rss_bytes),
            "disk_bytes": safe_div_u64(load.disk_bytes, capacity.disk_bytes),
            "query_rps": safe_div_f64(load.query_rps, capacity.query_rps),
            "indexing_rps": safe_div_f64(load.indexing_rps, capacity.indexing_rps),
        })
    }

    pub(super) fn aggregate_vm_load(vectors: &HashMap<String, ResourceVector>) -> ResourceVector {
        vectors
            .values()
            .fold(ResourceVector::zero(), |acc, vector| acc.add(vector))
    }

    pub(super) fn serialize_vm_load(
        load: &ResourceVector,
        capacity: &ResourceVector,
    ) -> serde_json::Value {
        let mut value: serde_json::Value = load.clone().into();
        if let Some(obj) = value.as_object_mut() {
            obj.insert(
                "utilization".to_string(),
                Self::calculate_utilization(load, capacity),
            );
        }
        value
    }

    /// Executes one scheduling cycle: loads active VMs, scrapes and persists
    /// metrics, clears in-flight migration tracking, evaluates overload/underload
    /// thresholds, checks noisy-neighbor quota violations, assigns unplaced
    /// indexes, and prunes stale tracking state. Returns the count of active VMs
    /// processed.
    pub async fn run_cycle(&self) -> Result<usize, SchedulerError> {
        let active_vms = self
            .vm_inventory_repo
            .list_active(None)
            .await
            .map_err(|err| SchedulerError::Repo(err.to_string()))?;

        let mut active_vm_ids = HashSet::with_capacity(active_vms.len());
        let mut cycle_state = self
            .scrape_and_persist_vm_data(&active_vms, &mut active_vm_ids)
            .await;

        // Clear stale entries from prior cycles; deduplication is only needed within one cycle.
        self.in_flight_migrations.lock().unwrap().clear();

        let now = Instant::now();
        self.evaluate_load_thresholds(&active_vms, &cycle_state, now)
            .await;

        self.check_noisy_neighbors(
            &active_vms,
            &cycle_state.vm_per_index,
            &cycle_state.vm_loads,
            &cycle_state.vm_scraped_at,
            now,
        )
        .await;

        self.assign_unplaced_indexes(
            &active_vms,
            &mut cycle_state.vm_loads,
            &cycle_state.vm_scraped_at,
        )
        .await;

        self.prune_vm_tracking_state(&active_vm_ids);
        self.prune_noisy_neighbor_tracking(&cycle_state.vm_per_index);

        info!(
            active_vm_count = active_vms.len(),
            "scheduler cycle completed"
        );

        Ok(active_vms.len())
    }

    /// Scrapes metrics for all active VMs, filters out cold-tier indexes,
    /// persists computed loads, and populates a [`CycleScrapeState`] with
    /// per-VM load, per-index vectors, utilization, and scrape timestamps.
    /// VMs that fail to scrape are silently skipped for this cycle.
    async fn scrape_and_persist_vm_data(
        &self,
        active_vms: &[VmInventory],
        active_vm_ids: &mut HashSet<Uuid>,
    ) -> CycleScrapeState {
        let mut cycle_state = CycleScrapeState::default();

        for vm in active_vms {
            active_vm_ids.insert(vm.id);

            let Some(scraped_vm) = self.scrape_cycle_state_for_vm(vm).await else {
                continue;
            };

            cycle_state
                .vm_loads
                .insert(vm.id, scraped_vm.aggregate_load);
            cycle_state
                .vm_per_index
                .insert(vm.id, scraped_vm.per_index_vectors);
            cycle_state
                .vm_utilizations
                .insert(vm.id, scraped_vm.utilization);
            cycle_state
                .vm_scraped_at
                .insert(vm.id, scraped_vm.scraped_at);
            self.previous_counters_by_vm
                .lock()
                .unwrap()
                .insert(vm.id, scraped_vm.next_counters);
        }

        cycle_state
    }

    /// Scrapes one VM's metrics, filters cold-tier indexes, computes aggregate
    /// load and utilization, persists the load to the VM inventory repo, and
    /// returns a [`ScrapedVmState`]. Returns `None` if any step fails (scrape
    /// error, tenant lookup, or persistence), logging a warning.
    async fn scrape_cycle_state_for_vm(&self, vm: &VmInventory) -> Option<ScrapedVmState> {
        let (_aggregate_load, mut per_index_vectors, next_counters) = match self.scrape_vm(vm).await
        {
            Ok(result) => result,
            Err(err) => {
                warn!(
                    vm_id = %vm.id,
                    hostname = %vm.hostname,
                    error = %err,
                    "scheduler scrape failed; skipping VM for this cycle"
                );
                return None;
            }
        };

        if let Err(err) = self
            .filter_cold_tiers_for_vm(vm, &mut per_index_vectors)
            .await
        {
            warn!(
                vm_id = %vm.id,
                hostname = %vm.hostname,
                error = %err,
                "failed to load tenant tiers for VM; skipping VM for this cycle"
            );
            return None;
        }

        let aggregate_load = Self::aggregate_vm_load(&per_index_vectors);
        let capacity = ResourceVector::from(vm.capacity.clone());
        let utilization = Self::calculate_utilization(&aggregate_load, &capacity);
        let current_load = Self::serialize_vm_load(&aggregate_load, &capacity);
        let scraped_at = Utc::now();

        if let Err(err) = self
            .vm_inventory_repo
            .update_load(vm.id, current_load)
            .await
        {
            warn!(
                vm_id = %vm.id,
                hostname = %vm.hostname,
                error = %err,
                "failed to persist VM load; skipping VM for this cycle"
            );
            return None;
        }

        Some(ScrapedVmState {
            aggregate_load,
            per_index_vectors,
            utilization,
            scraped_at,
            next_counters,
        })
    }

    /// Removes cold and restoring tier indexes from `per_index_vectors` in-place.
    /// Loads the tenant list for the VM and retains only indexes whose tier is
    /// active, so cold storage tenants do not influence load-balancing decisions.
    async fn filter_cold_tiers_for_vm(
        &self,
        vm: &VmInventory,
        per_index_vectors: &mut HashMap<String, ResourceVector>,
    ) -> Result<(), String> {
        let tenant_rows = self
            .tenant_repo
            .list_by_vm(vm.id)
            .await
            .map_err(|err| err.to_string())?;

        if tenant_rows.is_empty() {
            return Ok(());
        }

        let active_tenant_names: HashSet<String> = tenant_rows
            .into_iter()
            .filter(|tenant| !COLD_TIERS.contains(&tenant.tier.as_str()))
            .map(|tenant| tenant.tenant_id)
            .collect();

        per_index_vectors.retain(|tenant_id, _| active_tenant_names.contains(tenant_id));
        Ok(())
    }

    /// Iterates active VMs and evaluates overload and underload conditions for
    /// each. Skips VMs without utilization data (scrape failed this cycle).
    async fn evaluate_load_thresholds(
        &self,
        active_vms: &[VmInventory],
        cycle_state: &CycleScrapeState,
        now: Instant,
    ) {
        for vm in active_vms {
            let Some(utilization) = cycle_state.vm_utilizations.get(&vm.id) else {
                continue; // scrape failed for this VM
            };

            self.evaluate_overload_for_vm(vm, utilization, active_vms, cycle_state, now)
                .await;
            self.evaluate_underload_for_vm(vm, utilization, active_vms, cycle_state, now)
                .await;
        }
    }

    /// Detects sustained overload (any dimension > `overload_threshold`).
    ///
    /// Tracks `first_seen` timestamp; only triggers a migration after the
    /// condition persists for `overload_duration_secs` (default 600 s). Resets
    /// tracking when the VM drops below threshold or a migration succeeds.
    async fn evaluate_overload_for_vm(
        &self,
        vm: &VmInventory,
        utilization: &serde_json::Value,
        active_vms: &[VmInventory],
        cycle_state: &CycleScrapeState,
        now: Instant,
    ) {
        if Self::is_overloaded(utilization, self.config.overload_threshold) {
            let first_seen = {
                let mut map = self.overload_first_seen.lock().unwrap();
                *map.entry(vm.id).or_insert(now)
            };
            let elapsed = now.duration_since(first_seen);
            if elapsed >= Duration::from_secs(self.config.overload_duration_secs) {
                let mut migrated = false;
                if let Some(per_index) = cycle_state.vm_per_index.get(&vm.id) {
                    migrated = self
                        .handle_overload(
                            vm,
                            per_index,
                            active_vms,
                            &cycle_state.vm_loads,
                            &cycle_state.vm_scraped_at,
                        )
                        .await;
                }
                if migrated {
                    // Reset tracking only after a successful migration request.
                    self.overload_first_seen.lock().unwrap().remove(&vm.id);
                }
            }
        } else {
            self.overload_first_seen.lock().unwrap().remove(&vm.id);
        }
    }

    /// Detects sustained underload (all dimensions < `underload_threshold`).
    ///
    /// Tracks `first_seen` timestamp; only triggers a drain after the condition
    /// persists for `underload_duration_secs` (default 1800 s). Draining
    /// migrates all active indexes off the VM and sets its status to draining.
    /// Resets tracking when the VM rises above threshold or drain completes.
    async fn evaluate_underload_for_vm(
        &self,
        vm: &VmInventory,
        utilization: &serde_json::Value,
        active_vms: &[VmInventory],
        cycle_state: &CycleScrapeState,
        now: Instant,
    ) {
        if Self::is_underloaded(utilization, self.config.underload_threshold) {
            let first_seen = {
                let mut map = self.underload_first_seen.lock().unwrap();
                *map.entry(vm.id).or_insert(now)
            };
            let elapsed = now.duration_since(first_seen);
            if elapsed >= Duration::from_secs(self.config.underload_duration_secs) {
                let mut drained = false;
                if let Some(per_index) = cycle_state.vm_per_index.get(&vm.id) {
                    drained = self
                        .handle_underload(
                            vm,
                            per_index,
                            active_vms,
                            &cycle_state.vm_loads,
                            &cycle_state.vm_scraped_at,
                        )
                        .await;
                }
                if drained {
                    // Reset tracking only after all indexes were successfully placed.
                    self.underload_first_seen.lock().unwrap().remove(&vm.id);
                }
            }
        } else {
            self.underload_first_seen.lock().unwrap().remove(&vm.id);
        }
    }

    fn prune_vm_tracking_state(&self, active_vm_ids: &HashSet<Uuid>) {
        self.previous_counters_by_vm
            .lock()
            .unwrap()
            .retain(|vm_id, _| active_vm_ids.contains(vm_id));
        self.overload_first_seen
            .lock()
            .unwrap()
            .retain(|vm_id, _| active_vm_ids.contains(vm_id));
        self.underload_first_seen
            .lock()
            .unwrap()
            .retain(|vm_id, _| active_vm_ids.contains(vm_id));
    }

    /// Removes stale entries from `noisy_neighbor_first_seen` for indexes that
    /// no longer appear on any active VM. Parses the tracking key format
    /// `"{customer_id}:{index_name}"` and retains only entries whose
    /// `index_name` still exists in the current cycle's per-index data.
    fn prune_noisy_neighbor_tracking(
        &self,
        vm_per_index: &HashMap<Uuid, HashMap<String, ResourceVector>>,
    ) {
        let active_index_keys: HashSet<String> = vm_per_index
            .values()
            .flat_map(|per_index| per_index.keys().cloned())
            .collect();

        self.noisy_neighbor_first_seen
            .lock()
            .unwrap()
            .retain(|key, _| {
                // Key format: "{customer_id}:{index_name}" — check index_name portion.
                key.split(':')
                    .nth(1)
                    .map(|index_name| active_index_keys.contains(index_name))
                    .unwrap_or(false)
            });
    }
}
