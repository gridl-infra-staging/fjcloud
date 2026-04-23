//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/scheduler/noisy_neighbors.rs.
use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use tracing::{info, warn};
use uuid::Uuid;

use crate::models::resource_vector::ResourceVector;
use crate::models::tenant::CustomerTenant;
use crate::models::vm_inventory::VmInventory;
use crate::services::alerting::{Alert, AlertSeverity};
use crate::services::placement::place_index;
use crate::services::tenant_quota::QuotaDefaults;

use super::{MigrationRequest, SchedulerService, COLD_TIERS};

struct NoisyNeighborContext<'a> {
    all_vms: &'a [VmInventory],
    vm_loads: &'a HashMap<Uuid, ResourceVector>,
    vm_scraped_at: &'a HashMap<Uuid, DateTime<Utc>>,
    now: Instant,
}

struct NoisyNeighborViolation<'a> {
    vm: &'a VmInventory,
    tenant: &'a CustomerTenant,
    index_name: String,
    index_vector: &'a ResourceVector,
    violations: Vec<(String, f64, f64)>,
    tracking_key: String,
}

impl SchedulerService {
    /// Compare an index's actual resource usage against its quota. Returns list of
    /// (dimension_name, actual_value, quota_limit) for each exceeded dimension.
    fn detect_quota_violations(
        vector: &ResourceVector,
        quota: &serde_json::Value,
        defaults: &QuotaDefaults,
    ) -> Vec<(String, f64, f64)> {
        let mut violations = Vec::new();

        let max_query_rps = quota
            .get("max_query_rps")
            .and_then(|v| v.as_f64())
            .filter(|v| *v > 0.0)
            .unwrap_or(defaults.max_query_rps as f64);
        if vector.query_rps > max_query_rps {
            violations.push(("query_rps".to_string(), vector.query_rps, max_query_rps));
        }

        let max_write_rps = quota
            .get("max_write_rps")
            .and_then(|v| v.as_f64())
            .filter(|v| *v > 0.0)
            .unwrap_or(defaults.max_write_rps as f64);
        if vector.indexing_rps > max_write_rps {
            violations.push((
                "indexing_rps".to_string(),
                vector.indexing_rps,
                max_write_rps,
            ));
        }

        let max_storage_bytes = quota
            .get("max_storage_bytes")
            .and_then(|v| v.as_u64())
            .filter(|v| *v > 0)
            .unwrap_or(defaults.max_storage_bytes);
        if vector.disk_bytes > max_storage_bytes {
            violations.push((
                "disk_bytes".to_string(),
                vector.disk_bytes as f64,
                max_storage_bytes as f64,
            ));
        }

        violations
    }

    /// Check per-index resource usage against tenant quotas. Fire alerts for sustained
    /// violations and trigger migrations for prolonged offenders.
    pub(super) async fn check_noisy_neighbors(
        &self,
        all_vms: &[VmInventory],
        vm_per_index: &HashMap<Uuid, HashMap<String, ResourceVector>>,
        vm_loads: &HashMap<Uuid, ResourceVector>,
        vm_scraped_at: &HashMap<Uuid, DateTime<Utc>>,
        now: Instant,
    ) {
        let context = NoisyNeighborContext {
            all_vms,
            vm_loads,
            vm_scraped_at,
            now,
        };

        // Collect all currently-violating index keys so we can prune non-violators after.
        let mut current_violators: HashSet<String> = HashSet::new();

        for vm in all_vms {
            self.check_noisy_neighbors_for_vm(vm, vm_per_index, &context, &mut current_violators)
                .await;
        }

        // Clear tracking for indexes that are no longer violating.
        self.noisy_neighbor_first_seen
            .lock()
            .unwrap()
            .retain(|key, _| current_violators.contains(key));
    }

    /// Checks every index on `vm` for quota violations via
    /// `detect_quota_violations`. For each violating index, delegates to
    /// [`Self::handle_noisy_neighbor_violation`] which enforces duration-based
    /// warning and migration windows. Skips indexes not in the tenant catalog
    /// (possible race during migration).
    async fn check_noisy_neighbors_for_vm(
        &self,
        vm: &VmInventory,
        vm_per_index: &HashMap<Uuid, HashMap<String, ResourceVector>>,
        context: &NoisyNeighborContext<'_>,
        current_violators: &mut HashSet<String>,
    ) {
        let Some(per_index) = vm_per_index.get(&vm.id) else {
            return;
        };
        if per_index.is_empty() {
            return;
        }

        let tenant_map = match self.active_tenants_by_index(vm.id).await {
            Some(map) => map,
            None => return,
        };

        for (index_name, index_vector) in per_index {
            let Some(tenant) = tenant_map.get(index_name.as_str()) else {
                continue; // index not in catalog (race during migration)
            };

            let violations = Self::detect_quota_violations(
                index_vector,
                &tenant.resource_quota,
                &self.quota_defaults,
            );
            if violations.is_empty() {
                continue;
            }

            let violation = NoisyNeighborViolation {
                vm,
                tenant,
                index_name: index_name.clone(),
                index_vector,
                tracking_key: format!("{}:{}", tenant.customer_id, index_name),
                violations,
            };
            current_violators.insert(violation.tracking_key.clone());

            self.handle_noisy_neighbor_violation(context, &violation)
                .await;
        }
    }

    /// Returns a map of `index_name → CustomerTenant` for active (non-cold)
    /// tenants on the given VM. Returns `None` if the tenant repo query fails.
    async fn active_tenants_by_index(
        &self,
        vm_id: Uuid,
    ) -> Option<HashMap<String, CustomerTenant>> {
        let tenants = match self.tenant_repo.list_by_vm(vm_id).await {
            Ok(rows) => rows,
            Err(err) => {
                warn!(
                    vm_id = %vm_id,
                    error = %err,
                    "noisy-neighbor: failed to list tenants for VM"
                );
                return None;
            }
        };

        let active_tenants = tenants
            .into_iter()
            .filter(|tenant| !COLD_TIERS.contains(&tenant.tier.as_str()))
            .map(|tenant| (tenant.tenant_id.clone(), tenant))
            .collect();

        Some(active_tenants)
    }

    /// Handles a sustained quota violation for one index, enforcing two
    /// time-based escalation stages:
    ///
    /// 1. After `noisy_neighbor_warning_secs`: sends a warning alert (once).
    /// 2. After `noisy_neighbor_migration_secs`: attempts migration to another
    ///    same-provider VM; if no capacity, sends a "no capacity" alert (once).
    ///
    /// Tracks `(first_seen, warning_sent, no_capacity_warning_sent)` per
    /// `"{customer_id}:{index_name}"` key.
    async fn handle_noisy_neighbor_violation(
        &self,
        context: &NoisyNeighborContext<'_>,
        violation: &NoisyNeighborViolation<'_>,
    ) {
        let (first_seen, warning_sent, no_capacity_warning_sent) =
            self.noisy_neighbor_tracking_state(&violation.tracking_key, context.now);
        let elapsed = context.now.duration_since(first_seen);

        if !warning_sent && elapsed >= Duration::from_secs(self.config.noisy_neighbor_warning_secs)
        {
            self.send_noisy_neighbor_warning_alert(violation, elapsed)
                .await;
            self.mark_noisy_neighbor_warning_sent(&violation.tracking_key);
        }

        if elapsed < Duration::from_secs(self.config.noisy_neighbor_migration_secs) {
            return;
        }

        let candidate_vms = Self::build_same_provider_candidates(
            violation.vm,
            context.all_vms,
            context.vm_loads,
            context.vm_scraped_at,
        );

        if let Some(dest_vm_id) = place_index(violation.index_vector, &candidate_vms) {
            self.request_noisy_neighbor_migration(violation, dest_vm_id)
                .await;
            return;
        }

        if !no_capacity_warning_sent {
            self.send_noisy_neighbor_no_capacity_alert(violation, elapsed)
                .await;
            self.mark_noisy_neighbor_no_capacity_warning_sent(&violation.tracking_key);
        }
    }

    fn noisy_neighbor_tracking_state(
        &self,
        tracking_key: &str,
        now: Instant,
    ) -> (Instant, bool, bool) {
        let mut map = self.noisy_neighbor_first_seen.lock().unwrap();
        *map.entry(tracking_key.to_string())
            .or_insert((now, false, false))
    }

    fn mark_noisy_neighbor_warning_sent(&self, tracking_key: &str) {
        self.noisy_neighbor_first_seen
            .lock()
            .unwrap()
            .entry(tracking_key.to_string())
            .and_modify(|(_, sent, _)| *sent = true);
    }

    fn mark_noisy_neighbor_no_capacity_warning_sent(&self, tracking_key: &str) {
        self.noisy_neighbor_first_seen
            .lock()
            .unwrap()
            .entry(tracking_key.to_string())
            .and_modify(|(_, _, sent)| *sent = true);
    }

    /// Fires a `Warning`-severity alert when an index exceeds its quota for
    /// `noisy_neighbor_warning_secs`. Metadata includes `index_name`,
    /// `customer_id`, `vm_id`, elapsed time, and the violated dimensions with
    /// their actual values.
    async fn send_noisy_neighbor_warning_alert(
        &self,
        violation: &NoisyNeighborViolation<'_>,
        elapsed: Duration,
    ) {
        let violation_description: Vec<String> = violation
            .violations
            .iter()
            .map(|(dimension, actual, limit)| format!("{dimension}: {actual:.1} > {limit:.1}"))
            .collect();

        let alert = Alert {
            severity: AlertSeverity::Warning,
            title: format!(
                "Noisy neighbor: quota exceeded for index {}",
                violation.index_name
            ),
            message: format!(
                "Index '{}' owned by customer {} has exceeded quota for {:.0}s. Violations: {}",
                violation.index_name,
                violation.tenant.customer_id,
                elapsed.as_secs_f64(),
                violation_description.join(", "),
            ),
            metadata: HashMap::from([
                ("index_name".to_string(), violation.index_name.clone()),
                (
                    "customer_id".to_string(),
                    violation.tenant.customer_id.to_string(),
                ),
                ("vm_id".to_string(), violation.vm.id.to_string()),
            ]),
        };

        if let Err(err) = self.alert_service.send_alert(alert).await {
            warn!(
                index = %violation.index_name,
                error = %err,
                "noisy-neighbor: failed to send warning alert"
            );
        }
    }

    /// Submits a migration request with `reason="noisy_neighbor"`. On success,
    /// removes the tracking entry so a fresh duration window starts if the
    /// violation recurs. On failure, logs a warning and keeps tracking (may
    /// retry next cycle).
    async fn request_noisy_neighbor_migration(
        &self,
        violation: &NoisyNeighborViolation<'_>,
        dest_vm_id: Uuid,
    ) {
        let request = MigrationRequest {
            index_name: violation.index_name.clone(),
            customer_id: violation.tenant.customer_id,
            source_vm_id: violation.vm.id,
            dest_vm_id,
            reason: "noisy_neighbor".to_string(),
        };

        if let Err(err) = self.migration_service.request_migration(request).await {
            warn!(
                index = %violation.index_name,
                error = %err,
                "noisy-neighbor: failed to request migration"
            );
            return;
        }

        info!(
            event = "scheduler_noisy_neighbor_migration",
            index = %violation.index_name,
            customer_id = %violation.tenant.customer_id,
            source_vm_id = %violation.vm.id,
            dest_vm_id = %dest_vm_id,
            "noisy-neighbor migration requested"
        );

        // Migration requested successfully; reset violation tracking for this
        // index so future violations start a fresh duration window.
        self.noisy_neighbor_first_seen
            .lock()
            .unwrap()
            .remove(&violation.tracking_key);
    }

    /// Fires a `Warning`-severity alert when a noisy-neighbor migration cannot
    /// find a same-provider destination. Metadata includes `index_name`,
    /// `customer_id`, `vm_id`, and elapsed time.
    async fn send_noisy_neighbor_no_capacity_alert(
        &self,
        violation: &NoisyNeighborViolation<'_>,
        elapsed: Duration,
    ) {
        let alert = Alert {
            severity: AlertSeverity::Warning,
            title: format!(
                "Noisy neighbor migration blocked for index {}",
                violation.index_name
            ),
            message: format!(
                "Index '{}' exceeded quota for {:.0}s but no same-provider destination capacity is available on active VMs.",
                violation.index_name,
                elapsed.as_secs_f64(),
            ),
            metadata: HashMap::from([
                ("index_name".to_string(), violation.index_name.clone()),
                (
                    "customer_id".to_string(),
                    violation.tenant.customer_id.to_string(),
                ),
                ("vm_id".to_string(), violation.vm.id.to_string()),
            ]),
        };

        if let Err(err) = self.alert_service.send_alert(alert).await {
            warn!(
                index = %violation.index_name,
                error = %err,
                "noisy-neighbor: failed to send no-capacity warning alert"
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use crate::models::resource_vector::ResourceVector;
    use crate::services::tenant_quota::QuotaDefaults;
    use serde_json::json;

    use super::super::SchedulerService;

    fn rv(cpu: f64, mem: u64, disk: u64, qrps: f64, irps: f64) -> ResourceVector {
        ResourceVector {
            cpu_weight: cpu,
            mem_rss_bytes: mem,
            disk_bytes: disk,
            query_rps: qrps,
            indexing_rps: irps,
        }
    }

    fn defaults() -> QuotaDefaults {
        QuotaDefaults {
            max_query_rps: 100,
            max_write_rps: 50,
            max_storage_bytes: 10_000,
            max_indexes: 10,
        }
    }

    #[test]
    fn no_violations_when_within_quota() {
        let v = rv(1.0, 5_000, 8_000, 50.0, 20.0);
        let quota = json!({});
        let violations = SchedulerService::detect_quota_violations(&v, &quota, &defaults());
        assert!(violations.is_empty());
    }

    #[test]
    fn detects_query_rps_violation() {
        let v = rv(1.0, 5_000, 8_000, 150.0, 20.0);
        let quota = json!({});
        let violations = SchedulerService::detect_quota_violations(&v, &quota, &defaults());
        assert_eq!(violations.len(), 1);
        assert_eq!(violations[0].0, "query_rps");
        assert!((violations[0].1 - 150.0).abs() < f64::EPSILON);
        assert!((violations[0].2 - 100.0).abs() < f64::EPSILON);
    }

    #[test]
    fn detects_write_rps_violation() {
        let v = rv(1.0, 5_000, 8_000, 50.0, 60.0);
        let quota = json!({});
        let violations = SchedulerService::detect_quota_violations(&v, &quota, &defaults());
        assert_eq!(violations.len(), 1);
        assert_eq!(violations[0].0, "indexing_rps");
    }

    #[test]
    fn detects_disk_violation() {
        let v = rv(1.0, 5_000, 15_000, 50.0, 20.0);
        let quota = json!({});
        let violations = SchedulerService::detect_quota_violations(&v, &quota, &defaults());
        assert_eq!(violations.len(), 1);
        assert_eq!(violations[0].0, "disk_bytes");
    }

    #[test]
    fn detects_multiple_violations() {
        let v = rv(1.0, 5_000, 15_000, 150.0, 60.0);
        let quota = json!({});
        let violations = SchedulerService::detect_quota_violations(&v, &quota, &defaults());
        assert_eq!(violations.len(), 3);
        let dims: Vec<&str> = violations.iter().map(|(d, _, _)| d.as_str()).collect();
        assert!(dims.contains(&"query_rps"));
        assert!(dims.contains(&"indexing_rps"));
        assert!(dims.contains(&"disk_bytes"));
    }

    #[test]
    fn uses_per_index_overrides_from_quota() {
        let v = rv(1.0, 5_000, 8_000, 150.0, 20.0);
        // Override max_query_rps to 200 — should no longer violate
        let quota = json!({ "max_query_rps": 200.0 });
        let violations = SchedulerService::detect_quota_violations(&v, &quota, &defaults());
        assert!(violations.is_empty());
    }

    #[test]
    fn ignores_zero_quota_overrides() {
        let v = rv(1.0, 5_000, 8_000, 150.0, 20.0);
        // Zero override should fall back to defaults
        let quota = json!({ "max_query_rps": 0 });
        let violations = SchedulerService::detect_quota_violations(&v, &quota, &defaults());
        assert_eq!(violations.len(), 1);
        assert_eq!(violations[0].0, "query_rps");
    }
}
