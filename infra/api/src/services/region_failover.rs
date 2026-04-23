use std::collections::HashMap;
use std::sync::Arc;

use tokio::sync::watch;
use tracing::{info, warn};

use crate::repos::index_replica_repo::IndexReplicaRepo;
use crate::repos::tenant_repo::TenantRepo;
use crate::repos::vm_inventory_repo::VmInventoryRepo;
use crate::services::alerting::{Alert, AlertService, AlertSeverity};

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const DEFAULT_CYCLE_INTERVAL_SECS: u64 = 60;
const DEFAULT_UNHEALTHY_THRESHOLD: u32 = 3;
const DEFAULT_RECOVERY_THRESHOLD: u32 = 2;

#[derive(Debug, Clone)]
pub struct RegionFailoverConfig {
    /// How often the monitor runs a cycle, in seconds.
    pub cycle_interval_secs: u64,
    /// Consecutive cycles a region must be fully down before triggering failover.
    pub unhealthy_threshold: u32,
    /// Consecutive healthy cycles before transitioning a region back to Healthy.
    pub recovery_threshold: u32,
}

impl Default for RegionFailoverConfig {
    fn default() -> Self {
        Self {
            cycle_interval_secs: DEFAULT_CYCLE_INTERVAL_SECS,
            unhealthy_threshold: DEFAULT_UNHEALTHY_THRESHOLD,
            recovery_threshold: DEFAULT_RECOVERY_THRESHOLD,
        }
    }
}

impl RegionFailoverConfig {
    pub fn from_env() -> Self {
        Self::from_reader(|key| std::env::var(key).ok())
    }

    /// Reads failover configuration from the environment via a `ConfigReader` closure.
    ///
    /// Parses cycle interval, unhealthy threshold (consecutive failures before
    /// failover), and recovery threshold (consecutive successes before recovery).
    /// Zero values are filtered out so that an unset or zero-valued variable
    /// falls through to the compiled default rather than disabling the feature.
    pub fn from_reader<F>(read: F) -> Self
    where
        F: Fn(&str) -> Option<String>,
    {
        let cycle_interval_secs = read("REGION_FAILOVER_CYCLE_INTERVAL_SECS")
            .and_then(|v| v.parse::<u64>().ok())
            .filter(|v| *v > 0)
            .unwrap_or(DEFAULT_CYCLE_INTERVAL_SECS);
        let unhealthy_threshold = read("REGION_FAILOVER_UNHEALTHY_THRESHOLD")
            .and_then(|v| v.parse::<u32>().ok())
            .filter(|v| *v > 0)
            .unwrap_or(DEFAULT_UNHEALTHY_THRESHOLD);
        let recovery_threshold = read("REGION_FAILOVER_RECOVERY_THRESHOLD")
            .and_then(|v| v.parse::<u32>().ok())
            .filter(|v| *v > 0)
            .unwrap_or(DEFAULT_RECOVERY_THRESHOLD);

        Self {
            cycle_interval_secs,
            unhealthy_threshold,
            recovery_threshold,
        }
    }
}

// ---------------------------------------------------------------------------
// Region health state
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RegionHealthStatus {
    Healthy,
    Degraded,
    Down,
}

/// Tracks a failover: which replica VM was promoted and from which source region.
#[derive(Debug, Clone)]
struct FailoverEntry {
    _replica_vm_id: uuid::Uuid,
    source_region: String,
}

// ---------------------------------------------------------------------------
// Monitor
// ---------------------------------------------------------------------------

/// Background monitor that polls region health endpoints on a configurable interval.
///
/// Tracks per-region consecutive unhealthy and recovery counts, manages failover
/// state transitions (Healthy -> Degraded -> Down, and back), and fires alerts
/// on state changes. When a region is declared Down, promotes the lowest-lag
/// replica for each affected index onto a healthy VM in another region.
pub struct RegionFailoverMonitor {
    vm_repo: Arc<dyn VmInventoryRepo + Send + Sync>,
    tenant_repo: Arc<dyn TenantRepo + Send + Sync>,
    replica_repo: Arc<dyn IndexReplicaRepo>,
    alert_service: Arc<dyn AlertService>,
    http_client: reqwest::Client,
    config: RegionFailoverConfig,
    /// Consecutive unhealthy-cycle count per region.
    unhealthy_counts: std::sync::Mutex<HashMap<String, u32>>,
    /// Consecutive healthy-cycle count per region (after being Down).
    recovery_counts: std::sync::Mutex<HashMap<String, u32>>,
    /// Current region health statuses.
    region_states: std::sync::Mutex<HashMap<String, RegionHealthStatus>>,
    /// Track which indexes have already been failed over to prevent duplicate promotions.
    failed_over_indexes: std::sync::Mutex<HashMap<String, FailoverEntry>>,
}

impl RegionFailoverMonitor {
    fn increment_unhealthy_count(&self, region: &str) -> u32 {
        let mut counts = self.unhealthy_counts.lock().unwrap();
        let count = counts.entry(region.to_string()).or_insert(0);
        *count += 1;
        *count
    }

    /// Constructs the monitor with deployment and VM inventory repos, alert
    /// service, and config. Builds an internal reqwest client with a 5-second
    /// timeout for health probes.
    pub fn new(
        vm_repo: Arc<dyn VmInventoryRepo + Send + Sync>,
        tenant_repo: Arc<dyn TenantRepo + Send + Sync>,
        replica_repo: Arc<dyn IndexReplicaRepo>,
        alert_service: Arc<dyn AlertService>,
        config: RegionFailoverConfig,
    ) -> Self {
        let http_client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(5))
            .build()
            .expect("failed to build reqwest client");

        Self {
            vm_repo,
            tenant_repo,
            replica_repo,
            alert_service,
            http_client,
            config,
            unhealthy_counts: std::sync::Mutex::new(HashMap::new()),
            recovery_counts: std::sync::Mutex::new(HashMap::new()),
            region_states: std::sync::Mutex::new(HashMap::new()),
            failed_over_indexes: std::sync::Mutex::new(HashMap::new()),
        }
    }

    /// Spawn the monitor loop as a background task.
    pub fn spawn(self: Arc<Self>, shutdown: watch::Receiver<bool>) -> tokio::task::JoinHandle<()> {
        tokio::spawn(async move {
            self.run(shutdown).await;
        })
    }

    /// Run the monitor loop until shutdown is signaled.
    pub async fn run(&self, mut shutdown: watch::Receiver<bool>) {
        info!(
            cycle_interval_secs = self.config.cycle_interval_secs,
            unhealthy_threshold = self.config.unhealthy_threshold,
            "region failover monitor started"
        );

        loop {
            tokio::select! {
                _ = tokio::time::sleep(std::time::Duration::from_secs(self.config.cycle_interval_secs)) => {
                    self.run_cycle_live().await;
                }
                _ = shutdown.changed() => {
                    if *shutdown.borrow() {
                        info!("region failover monitor shutting down");
                        return;
                    }
                }
            }
        }
    }

    /// Production cycle: checks VM health via HTTP GET `{flapjack_url}/health`.
    async fn run_cycle_live(&self) {
        let all_vms = match self.vm_repo.list_active(None).await {
            Ok(vms) => vms,
            Err(err) => {
                warn!(error = %err, "region failover: failed to list active VMs");
                return;
            }
        };

        // Probe all VMs concurrently via JoinSet
        let mut set = tokio::task::JoinSet::new();
        for vm in &all_vms {
            let client = self.http_client.clone();
            let url = vm.flapjack_url.clone();
            set.spawn(async move {
                let health_url = format!("{url}/health");
                let healthy = client
                    .get(&health_url)
                    .send()
                    .await
                    .is_ok_and(|r| r.status().is_success());
                (url, healthy)
            });
        }

        let mut health_results: HashMap<String, bool> = HashMap::new();
        while let Some(result) = set.join_next().await {
            if let Ok((url, healthy)) = result {
                health_results.insert(url, healthy);
            }
        }

        self.run_cycle_with_health(|url| health_results.get(url).copied().unwrap_or(false))
            .await;
    }

    /// Snapshot of current region health statuses.
    pub fn region_statuses(&self) -> HashMap<String, RegionHealthStatus> {
        self.region_states.lock().unwrap().clone()
    }

    /// Run one cycle with a provided health-check function (for testability).
    /// `health_fn` takes a flapjack_url and returns true if the VM is healthy.
    pub async fn run_cycle_with_health<F>(&self, health_fn: F)
    where
        F: Fn(&str) -> bool,
    {
        // 1. List all active VMs, grouped by region
        let all_vms = match self.vm_repo.list_active(None).await {
            Ok(vms) => vms,
            Err(err) => {
                warn!(error = %err, "region failover: failed to list active VMs");
                return;
            }
        };

        let mut vms_by_region: HashMap<String, Vec<_>> = HashMap::new();
        for vm in &all_vms {
            vms_by_region.entry(vm.region.clone()).or_default().push(vm);
        }
        let vm_health: HashMap<uuid::Uuid, bool> = all_vms
            .iter()
            .map(|vm| (vm.id, health_fn(&vm.flapjack_url)))
            .collect();

        // 2. Check health per region
        for (region, vms) in &vms_by_region {
            let healthy_count = vms
                .iter()
                .filter(|vm| vm_health.get(&vm.id).copied().unwrap_or(false))
                .count();
            let total = vms.len();
            let all_down = healthy_count == 0;
            let all_healthy = healthy_count == total;

            let current_state = self
                .region_states
                .lock()
                .unwrap()
                .get(region)
                .copied()
                .unwrap_or(RegionHealthStatus::Healthy);

            if all_down {
                // Increment unhealthy counter
                let count = self.increment_unhealthy_count(region);

                // Reset recovery counter
                self.recovery_counts.lock().unwrap().remove(region);

                if count >= self.config.unhealthy_threshold {
                    if current_state != RegionHealthStatus::Down {
                        // Transition to Down once and alert once per outage.
                        self.region_states
                            .lock()
                            .unwrap()
                            .insert(region.clone(), RegionHealthStatus::Down);

                        self.fire_alert(
                            AlertSeverity::Critical,
                            format!("Region down — {region}"),
                            format!(
                                "All {total} VMs in region {region} are unreachable. Initiating automatic failover for indexes with replicas."
                            ),
                            {
                                let mut m = HashMap::new();
                                m.insert("region".to_string(), region.clone());
                                m.insert("vm_count".to_string(), total.to_string());
                                m
                            },
                        )
                        .await;
                    }

                    // Retry failover every down-cycle so newly affected indexes
                    // are promoted without waiting for a recovery transition.
                    self.failover_region(region, &vm_health).await;
                } else if current_state != RegionHealthStatus::Down {
                    // Not yet at threshold — mark degraded
                    self.region_states
                        .lock()
                        .unwrap()
                        .insert(region.clone(), RegionHealthStatus::Degraded);
                }
            } else if all_healthy {
                // Reset unhealthy counter
                self.unhealthy_counts.lock().unwrap().remove(region);

                if current_state == RegionHealthStatus::Down {
                    // Increment recovery counter
                    let recovery_count = {
                        let mut counts = self.recovery_counts.lock().unwrap();
                        let count = counts.entry(region.clone()).or_insert(0);
                        *count += 1;
                        *count
                    };

                    if recovery_count >= self.config.recovery_threshold {
                        self.region_states
                            .lock()
                            .unwrap()
                            .insert(region.clone(), RegionHealthStatus::Healthy);
                        self.recovery_counts.lock().unwrap().remove(region);

                        // Clean up failover tracking for this region only
                        {
                            let mut failed_over = self.failed_over_indexes.lock().unwrap();
                            failed_over.retain(|_key, entry| entry.source_region != *region);
                        }

                        self.fire_alert(
                            AlertSeverity::Info,
                            format!("Region recovered — {region}"),
                            format!(
                                "All {total} VMs in region {region} are healthy again. Automatic switchback is NOT performed — admin must manually restore original topology if desired."
                            ),
                            {
                                let mut m = HashMap::new();
                                m.insert("region".to_string(), region.clone());
                                m
                            },
                        )
                        .await;
                    }
                } else {
                    // Transitioned to Healthy from Degraded (or Healthy → Healthy).
                    // Clear any stale failover tracking so a future outage can
                    // trigger a fresh failover. Covers the Down → Degraded → Healthy
                    // path where the recovery-threshold block above is not reached.
                    {
                        let mut failed_over = self.failed_over_indexes.lock().unwrap();
                        failed_over.retain(|_key, entry| entry.source_region != *region);
                    }
                    self.region_states
                        .lock()
                        .unwrap()
                        .insert(region.clone(), RegionHealthStatus::Healthy);
                    self.recovery_counts.lock().unwrap().remove(region);
                }
            } else {
                // Partial health — degraded. Increment unhealthy counter so partial
                // failures accumulate toward the Down threshold.
                self.increment_unhealthy_count(region);
                self.recovery_counts.lock().unwrap().remove(region);
                self.region_states
                    .lock()
                    .unwrap()
                    .insert(region.clone(), RegionHealthStatus::Degraded);
            }
        }
    }

    /// Drives failover for all indexes in a downed region by collecting affected
    /// tenants and attempting per-tenant replica promotion.
    async fn failover_region(&self, region: &str, vm_health: &HashMap<uuid::Uuid, bool>) {
        let region_vms = match self.vm_repo.list_active(Some(region)).await {
            Ok(vms) => vms,
            Err(err) => {
                warn!(error = %err, region, "failover: failed to list VMs for region");
                return;
            }
        };

        let affected_tenants = self.collect_affected_tenants(&region_vms).await;

        for tenant in &affected_tenants {
            self.try_failover_tenant(tenant, region, vm_health).await;
        }
    }

    /// Collects all customer tenants hosted on the given VMs. Logs and skips
    /// individual VM lookup failures so one broken VM doesn't block the rest.
    async fn collect_affected_tenants(
        &self,
        region_vms: &[crate::models::vm_inventory::VmInventory],
    ) -> Vec<crate::models::tenant::CustomerTenant> {
        let mut affected = Vec::new();
        for vm in region_vms {
            match self.tenant_repo.list_by_vm(vm.id).await {
                Ok(tenants) => affected.extend(tenants),
                Err(err) => {
                    warn!(error = %err, vm_id = %vm.id, "failover: failed to list tenants on VM");
                }
            }
        }
        affected
    }

    /// Attempts to fail over a single tenant's index to the best available replica.
    /// Skips tenants already failed over. On success, promotes the lowest-lag active
    /// replica on a healthy VM, suspends it, and records the failover.
    async fn try_failover_tenant(
        &self,
        tenant: &crate::models::tenant::CustomerTenant,
        region: &str,
        vm_health: &HashMap<uuid::Uuid, bool>,
    ) {
        let failover_key = format!("{}:{}", tenant.customer_id, tenant.tenant_id);

        if self
            .failed_over_indexes
            .lock()
            .unwrap()
            .contains_key(&failover_key)
        {
            return;
        }

        let replicas = match self
            .replica_repo
            .list_by_index(tenant.customer_id, &tenant.tenant_id)
            .await
        {
            Ok(r) => r,
            Err(err) => {
                warn!(
                    error = %err,
                    tenant_id = %tenant.tenant_id,
                    "failover: failed to list replicas"
                );
                return;
            }
        };

        // Filter to active replicas on healthy VMs only
        let mut active_replicas: Vec<_> = replicas
            .into_iter()
            .filter(|r| {
                r.status == "active" && vm_health.get(&r.replica_vm_id).copied().unwrap_or(false)
            })
            .collect();

        if active_replicas.is_empty() {
            self.fire_alert(
                AlertSeverity::Warning,
                format!("No failover target — {}", tenant.tenant_id),
                format!(
                    "Index '{}' (customer {}) in region {} has no active replica available for failover on a healthy VM.",
                    tenant.tenant_id, tenant.customer_id, region
                ),
                {
                    let mut m = HashMap::new();
                    m.insert("region".to_string(), region.to_string());
                    m.insert("customer_id".to_string(), tenant.customer_id.to_string());
                    m.insert("tenant_id".to_string(), tenant.tenant_id.clone());
                    m
                },
            )
            .await;
            return;
        }

        // Select lowest-lag replica
        active_replicas.sort_by_key(|r| r.lag_ops);
        let best_replica = &active_replicas[0];

        // Promote: flip tenant vm_id to the replica's VM
        if let Err(err) = self
            .tenant_repo
            .set_vm_id(
                tenant.customer_id,
                &tenant.tenant_id,
                best_replica.replica_vm_id,
            )
            .await
        {
            warn!(
                error = %err,
                tenant_id = %tenant.tenant_id,
                replica_vm_id = %best_replica.replica_vm_id,
                "failover: failed to promote replica"
            );
            return;
        }

        // Suspend the replica so the replication orchestrator skips it.
        if let Err(err) = self
            .replica_repo
            .set_status(best_replica.id, "suspended")
            .await
        {
            warn!(
                error = %err,
                replica_id = %best_replica.id,
                "failover: failed to suspend promoted replica"
            );
        }

        // Track the failover with source region for scoped cleanup on recovery
        self.failed_over_indexes.lock().unwrap().insert(
            failover_key,
            FailoverEntry {
                _replica_vm_id: best_replica.replica_vm_id,
                source_region: region.to_string(),
            },
        );

        info!(
            tenant_id = %tenant.tenant_id,
            customer_id = %tenant.customer_id,
            source_region = region,
            target_region = %best_replica.replica_region,
            target_vm_id = %best_replica.replica_vm_id,
            lag_ops = best_replica.lag_ops,
            "failover: promoted replica to primary"
        );

        self.fire_alert(
            AlertSeverity::Warning,
            format!("Index failed over — {}", tenant.tenant_id),
            format!(
                "Index '{}' (customer {}) failed over from {} to {} (replica VM {}, lag {} ops).",
                tenant.tenant_id,
                tenant.customer_id,
                region,
                best_replica.replica_region,
                best_replica.replica_vm_id,
                best_replica.lag_ops,
            ),
            {
                let mut m = HashMap::new();
                m.insert("region".to_string(), region.to_string());
                m.insert(
                    "target_region".to_string(),
                    best_replica.replica_region.clone(),
                );
                m.insert("customer_id".to_string(), tenant.customer_id.to_string());
                m.insert("tenant_id".to_string(), tenant.tenant_id.clone());
                m.insert(
                    "replica_vm_id".to_string(),
                    best_replica.replica_vm_id.to_string(),
                );
                m.insert("lag_ops".to_string(), best_replica.lag_ops.to_string());
                m
            },
        )
        .await;
    }

    /// Dispatches an [`Alert`] to the configured alert service.
    ///
    /// Logs a warning if delivery fails but never propagates the error, so
    /// health monitoring is not disrupted by alerting failures.
    async fn fire_alert(
        &self,
        severity: AlertSeverity,
        title: String,
        message: String,
        metadata: HashMap<String, String>,
    ) {
        let alert = Alert {
            severity,
            title,
            message,
            metadata,
        };
        if let Err(e) = self.alert_service.send_alert(alert).await {
            warn!(error = %e, "region failover: failed to send alert");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_defaults_are_reasonable() {
        let config = RegionFailoverConfig::default();
        assert_eq!(config.cycle_interval_secs, 60);
        assert_eq!(config.unhealthy_threshold, 3);
        assert_eq!(config.recovery_threshold, 2);
    }

    #[test]
    fn config_from_reader_all_set() {
        let config = RegionFailoverConfig::from_reader(|key| match key {
            "REGION_FAILOVER_CYCLE_INTERVAL_SECS" => Some("120".to_string()),
            "REGION_FAILOVER_UNHEALTHY_THRESHOLD" => Some("5".to_string()),
            "REGION_FAILOVER_RECOVERY_THRESHOLD" => Some("4".to_string()),
            _ => None,
        });
        assert_eq!(config.cycle_interval_secs, 120);
        assert_eq!(config.unhealthy_threshold, 5);
        assert_eq!(config.recovery_threshold, 4);
    }

    #[test]
    fn config_from_reader_uses_defaults_when_missing() {
        let config = RegionFailoverConfig::from_reader(|_| None);
        assert_eq!(config.cycle_interval_secs, DEFAULT_CYCLE_INTERVAL_SECS);
        assert_eq!(config.unhealthy_threshold, DEFAULT_UNHEALTHY_THRESHOLD);
        assert_eq!(config.recovery_threshold, DEFAULT_RECOVERY_THRESHOLD);
    }

    #[test]
    fn config_from_reader_rejects_zero_values() {
        let config = RegionFailoverConfig::from_reader(|key| match key {
            "REGION_FAILOVER_CYCLE_INTERVAL_SECS" => Some("0".to_string()),
            "REGION_FAILOVER_UNHEALTHY_THRESHOLD" => Some("0".to_string()),
            "REGION_FAILOVER_RECOVERY_THRESHOLD" => Some("0".to_string()),
            _ => None,
        });
        // Zero is filtered out, so defaults are used
        assert_eq!(config.cycle_interval_secs, DEFAULT_CYCLE_INTERVAL_SECS);
        assert_eq!(config.unhealthy_threshold, DEFAULT_UNHEALTHY_THRESHOLD);
        assert_eq!(config.recovery_threshold, DEFAULT_RECOVERY_THRESHOLD);
    }

    #[test]
    fn config_from_reader_ignores_non_numeric() {
        let config = RegionFailoverConfig::from_reader(|key| match key {
            "REGION_FAILOVER_CYCLE_INTERVAL_SECS" => Some("abc".to_string()),
            _ => None,
        });
        assert_eq!(config.cycle_interval_secs, DEFAULT_CYCLE_INTERVAL_SECS);
    }

    #[test]
    fn region_health_status_equality() {
        assert_eq!(RegionHealthStatus::Healthy, RegionHealthStatus::Healthy);
        assert_eq!(RegionHealthStatus::Degraded, RegionHealthStatus::Degraded);
        assert_eq!(RegionHealthStatus::Down, RegionHealthStatus::Down);
        assert_ne!(RegionHealthStatus::Healthy, RegionHealthStatus::Down);
    }
}
