use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use tokio::sync::watch;
use tracing::{info, warn};
use uuid::Uuid;

use crate::helpers::parse_with_default;
use crate::models::resource_vector::ResourceVector;
use crate::models::vm_inventory::VmInventory;
use crate::repos::{TenantRepo, VmInventoryRepo};
use crate::secrets::{NodeSecretError, NodeSecretManager};
use crate::services::alerting::AlertService;
use crate::services::prometheus_parser::{
    extract_resource_vectors, parse_internal_storage_bytes, parse_metrics, CounterSnapshot,
};
use crate::services::replication_error::{INTERNAL_APP_ID_HEADER, INTERNAL_AUTH_HEADER};
use crate::services::tenant_quota::QuotaDefaults;

mod initial_placement;
mod noisy_neighbors;
mod overload;
mod run_cycle;
mod underload;

/// Tiers that represent offline indexes — excluded from scheduler decisions.
const COLD_TIERS: &[&str] = &["cold", "restoring"];

const DEFAULT_SCRAPE_INTERVAL_SECS: u64 = 300;
const DEFAULT_OVERLOAD_THRESHOLD: f64 = 0.85;
const DEFAULT_UNDERLOAD_THRESHOLD: f64 = 0.20;
const DEFAULT_MAX_CONCURRENT_MIGRATIONS: u32 = 3;
const DEFAULT_OVERLOAD_DURATION_SECS: u64 = 600;
const DEFAULT_UNDERLOAD_DURATION_SECS: u64 = 1800;
const DEFAULT_NOISY_NEIGHBOR_WARNING_SECS: u64 = 300;
const DEFAULT_NOISY_NEIGHBOR_MIGRATION_SECS: u64 = 1800;

#[derive(Debug, Clone, PartialEq)]
pub struct SchedulerConfig {
    pub scrape_interval_secs: u64,
    pub overload_threshold: f64,
    pub underload_threshold: f64,
    pub max_concurrent_migrations: u32,
    pub overload_duration_secs: u64,
    pub underload_duration_secs: u64,
    pub noisy_neighbor_warning_secs: u64,
    pub noisy_neighbor_migration_secs: u64,
}

impl Default for SchedulerConfig {
    fn default() -> Self {
        Self {
            scrape_interval_secs: DEFAULT_SCRAPE_INTERVAL_SECS,
            overload_threshold: DEFAULT_OVERLOAD_THRESHOLD,
            underload_threshold: DEFAULT_UNDERLOAD_THRESHOLD,
            max_concurrent_migrations: DEFAULT_MAX_CONCURRENT_MIGRATIONS,
            overload_duration_secs: DEFAULT_OVERLOAD_DURATION_SECS,
            underload_duration_secs: DEFAULT_UNDERLOAD_DURATION_SECS,
            noisy_neighbor_warning_secs: DEFAULT_NOISY_NEIGHBOR_WARNING_SECS,
            noisy_neighbor_migration_secs: DEFAULT_NOISY_NEIGHBOR_MIGRATION_SECS,
        }
    }
}

impl SchedulerConfig {
    pub fn from_env() -> Self {
        Self::from_reader(|key| std::env::var(key).ok())
    }

    /// Builds a [`SchedulerConfig`] by reading environment variables through the
    /// provided closure. Missing or unparseable keys fall back to compile-time
    /// defaults (e.g. 300 s scrape interval, 0.85 overload threshold, 0.20
    /// underload threshold).
    pub fn from_reader<F>(read: F) -> Self
    where
        F: Fn(&str) -> Option<String>,
    {
        Self {
            scrape_interval_secs: parse_with_default(
                &read,
                "SCHEDULER_SCRAPE_INTERVAL_SECS",
                DEFAULT_SCRAPE_INTERVAL_SECS,
            ),
            overload_threshold: parse_with_default(
                &read,
                "SCHEDULER_OVERLOAD_THRESHOLD",
                DEFAULT_OVERLOAD_THRESHOLD,
            ),
            underload_threshold: parse_with_default(
                &read,
                "SCHEDULER_UNDERLOAD_THRESHOLD",
                DEFAULT_UNDERLOAD_THRESHOLD,
            ),
            max_concurrent_migrations: parse_with_default(
                &read,
                "SCHEDULER_MAX_CONCURRENT_MIGRATIONS",
                DEFAULT_MAX_CONCURRENT_MIGRATIONS,
            ),
            overload_duration_secs: parse_with_default(
                &read,
                "SCHEDULER_OVERLOAD_DURATION_SECS",
                DEFAULT_OVERLOAD_DURATION_SECS,
            ),
            underload_duration_secs: parse_with_default(
                &read,
                "SCHEDULER_UNDERLOAD_DURATION_SECS",
                DEFAULT_UNDERLOAD_DURATION_SECS,
            ),
            noisy_neighbor_warning_secs: parse_with_default(
                &read,
                "SCHEDULER_NOISY_NEIGHBOR_WARNING_SECS",
                DEFAULT_NOISY_NEIGHBOR_WARNING_SECS,
            ),
            noisy_neighbor_migration_secs: parse_with_default(
                &read,
                "SCHEDULER_NOISY_NEIGHBOR_MIGRATION_SECS",
                DEFAULT_NOISY_NEIGHBOR_MIGRATION_SECS,
            ),
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum SchedulerError {
    #[error("repo error: {0}")]
    Repo(String),
}

#[derive(Debug, thiserror::Error, Clone, PartialEq)]
pub enum SchedulerHttpClientError {
    #[error("http timeout")]
    Timeout,
    #[error("unreachable: {0}")]
    Unreachable(String),
    #[error("http status {status}: {body}")]
    HttpStatus { status: u16, body: String },
}

#[async_trait]
pub trait SchedulerHttpClient: Send + Sync {
    async fn get_text(
        &self,
        url: &str,
        headers: HashMap<String, String>,
    ) -> Result<String, SchedulerHttpClientError>;
}

struct ReqwestSchedulerHttpClient {
    client: reqwest::Client,
}

impl ReqwestSchedulerHttpClient {
    fn new(client: reqwest::Client) -> Self {
        Self { client }
    }
}

#[async_trait]
impl SchedulerHttpClient for ReqwestSchedulerHttpClient {
    /// Sends an HTTP GET to `url` with the supplied headers and returns the
    /// response body as a string. Timeouts map to
    /// [`SchedulerHttpClientError::Timeout`]; connection failures map to
    /// `Unreachable`; non-2xx status codes return `HttpStatus` with the body.
    async fn get_text(
        &self,
        url: &str,
        headers: HashMap<String, String>,
    ) -> Result<String, SchedulerHttpClientError> {
        let mut request = self.client.get(url);
        for (name, value) in headers {
            request = request.header(&name, value);
        }

        let response = request.send().await.map_err(|e| {
            if e.is_timeout() {
                SchedulerHttpClientError::Timeout
            } else {
                SchedulerHttpClientError::Unreachable(e.to_string())
            }
        })?;

        let status = response.status();
        let body = response
            .text()
            .await
            .map_err(|e| SchedulerHttpClientError::Unreachable(e.to_string()))?;

        if status.is_success() {
            Ok(body)
        } else {
            Err(SchedulerHttpClientError::HttpStatus {
                status: status.as_u16(),
                body,
            })
        }
    }
}

/// A request to migrate an index from one VM to another, produced by scheduler decisions.
#[derive(Debug, Clone)]
pub struct MigrationRequest {
    pub index_name: String,
    pub customer_id: Uuid,
    pub source_vm_id: Uuid,
    pub dest_vm_id: Uuid,
    pub reason: String,
}

#[async_trait]
pub trait SchedulerMigrationService: Send + Sync {
    async fn request_migration(&self, req: MigrationRequest) -> Result<(), String>;
}

pub struct NoopSchedulerMigrationService;

#[async_trait]
impl SchedulerMigrationService for NoopSchedulerMigrationService {
    async fn request_migration(&self, _req: MigrationRequest) -> Result<(), String> {
        Ok(())
    }
}

/// Core scheduler orchestrator for VM load balancing.
///
/// Periodically scrapes Prometheus `/metrics` and `/internal/storage` from
/// every active VM, computes per-dimension utilization, and triggers index
/// migrations when sustained overload, underload, or noisy-neighbor quota
/// violations are detected. Tracking maps (`overload_first_seen`,
/// `underload_first_seen`, `noisy_neighbor_first_seen`) enforce duration
/// windows so transient spikes do not cause premature migrations.
pub struct SchedulerService {
    config: SchedulerConfig,
    vm_inventory_repo: Arc<dyn VmInventoryRepo + Send + Sync>,
    tenant_repo: Arc<dyn TenantRepo + Send + Sync>,
    migration_service: Arc<dyn SchedulerMigrationService + Send + Sync>,
    quota_defaults: QuotaDefaults,
    alert_service: Arc<dyn AlertService>,
    node_secret_manager: Arc<dyn NodeSecretManager>,
    http_client: Arc<dyn SchedulerHttpClient + Send + Sync>,
    previous_counters_by_vm: Mutex<HashMap<Uuid, CounterSnapshot>>,
    /// Tracks when each VM first crossed the overload threshold (any dimension).
    overload_first_seen: Mutex<HashMap<Uuid, Instant>>,
    /// Tracks when each VM first crossed the underload threshold (all dimensions).
    underload_first_seen: Mutex<HashMap<Uuid, Instant>>,
    /// Tracks when each per-index quota violation was first detected.
    /// Key: "{customer_id}:{index_name}", Value:
    /// (first_seen, quota_warning_sent, no_capacity_warning_sent)
    noisy_neighbor_first_seen: Mutex<HashMap<String, (Instant, bool, bool)>>,
    /// Tracks indexes with an accepted migration request to suppress duplicates.
    in_flight_migrations: Mutex<HashSet<String>>,
}

impl SchedulerService {
    /// Creates a [`SchedulerService`] with a default [`ReqwestSchedulerHttpClient`]
    /// wrapping the provided `reqwest::Client`. Delegates to
    /// [`Self::with_http_client`].
    pub fn new(
        config: SchedulerConfig,
        vm_inventory_repo: Arc<dyn VmInventoryRepo + Send + Sync>,
        tenant_repo: Arc<dyn TenantRepo + Send + Sync>,
        migration_service: Arc<dyn SchedulerMigrationService + Send + Sync>,
        alert_service: Arc<dyn AlertService>,
        node_secret_manager: Arc<dyn NodeSecretManager>,
        http_client: reqwest::Client,
    ) -> Self {
        Self::with_http_client(
            config,
            vm_inventory_repo,
            tenant_repo,
            migration_service,
            alert_service,
            node_secret_manager,
            Arc::new(ReqwestSchedulerHttpClient::new(http_client)),
        )
    }

    /// Creates a [`SchedulerService`] with an injectable HTTP client (useful for
    /// testing with mocks). Initialises all tracking state maps as empty and
    /// loads [`QuotaDefaults`] from the environment.
    pub fn with_http_client(
        config: SchedulerConfig,
        vm_inventory_repo: Arc<dyn VmInventoryRepo + Send + Sync>,
        tenant_repo: Arc<dyn TenantRepo + Send + Sync>,
        migration_service: Arc<dyn SchedulerMigrationService + Send + Sync>,
        alert_service: Arc<dyn AlertService>,
        node_secret_manager: Arc<dyn NodeSecretManager>,
        http_client: Arc<dyn SchedulerHttpClient + Send + Sync>,
    ) -> Self {
        Self {
            config,
            vm_inventory_repo,
            tenant_repo,
            migration_service,
            quota_defaults: QuotaDefaults::from_env(),
            alert_service,
            node_secret_manager,
            http_client,
            previous_counters_by_vm: Mutex::new(HashMap::new()),
            overload_first_seen: Mutex::new(HashMap::new()),
            underload_first_seen: Mutex::new(HashMap::new()),
            noisy_neighbor_first_seen: Mutex::new(HashMap::new()),
            in_flight_migrations: Mutex::new(HashSet::new()),
        }
    }

    pub fn config(&self) -> &SchedulerConfig {
        &self.config
    }

    pub fn vm_inventory_repo(&self) -> Arc<dyn VmInventoryRepo + Send + Sync> {
        Arc::clone(&self.vm_inventory_repo)
    }

    /// Builds internal authentication headers for a VM's Flapjack endpoints.
    ///
    /// Retrieves (or creates, if missing) the node API key via
    /// [`NodeSecretManager`] and returns `INTERNAL_AUTH_HEADER` and
    /// `INTERNAL_APP_ID_HEADER` ("flapjack") entries.
    async fn build_auth_headers(
        &self,
        vm: &VmInventory,
    ) -> Result<HashMap<String, String>, String> {
        let secret_id = vm.node_secret_id();
        let key = match self
            .node_secret_manager
            .get_node_api_key(secret_id, &vm.region)
            .await
        {
            Ok(key) => key,
            Err(error) if is_missing_node_secret_error(&error) => self
                .node_secret_manager
                .create_node_api_key(secret_id, &vm.region)
                .await
                .map_err(|create_error| {
                    format!(
                        "failed to create internal key for vm {} (secret id {}): {}",
                        vm.id, secret_id, create_error
                    )
                })?,
            Err(error) => {
                return Err(format!(
                    "failed to load internal key for vm {} (secret id {}): {}",
                    vm.id, secret_id, error
                ));
            }
        };

        Ok(HashMap::from([
            (INTERNAL_AUTH_HEADER.to_string(), key),
            (INTERNAL_APP_ID_HEADER.to_string(), "flapjack".to_string()),
        ]))
    }

    /// Main loop: sleeps for `config.scrape_interval_secs` between cycles,
    /// calling [`Self::run_cycle`] each iteration. Errors are logged without
    /// crashing. Exits cleanly when the `shutdown` watch signal fires.
    pub async fn run(&self, mut shutdown: watch::Receiver<bool>) {
        info!(
            scrape_interval_secs = self.config.scrape_interval_secs,
            "scheduler started"
        );

        loop {
            tokio::select! {
                _ = tokio::time::sleep(Duration::from_secs(self.config.scrape_interval_secs)) => {
                    if let Err(err) = self.run_cycle().await {
                        warn!(error = %err, "scheduler cycle failed");
                    }
                }
                _ = shutdown.changed() => {
                    if *shutdown.borrow() {
                        info!("scheduler shutting down");
                        return;
                    }
                }
            }
        }
    }

    /// Fetches `/metrics` and `/internal/storage` from a single VM, parses the
    /// Prometheus response into per-index [`ResourceVector`]s (using
    /// `previous_counters` for delta-based counter derivation), and returns the
    /// aggregate load, per-index map, and updated counter snapshot.
    async fn scrape_vm(
        &self,
        vm: &VmInventory,
    ) -> Result<
        (
            ResourceVector,
            HashMap<String, ResourceVector>,
            CounterSnapshot,
        ),
        String,
    > {
        let metrics_url = Self::endpoint_url(&vm.flapjack_url, "/metrics");
        let storage_url = Self::endpoint_url(&vm.flapjack_url, "/internal/storage");
        let headers = self.build_auth_headers(vm).await?;

        let metrics_text = self
            .http_client
            .get_text(&metrics_url, headers.clone())
            .await
            .map_err(|err| format!("metrics scrape failed at {metrics_url}: {err}"))?;

        let storage_text = self
            .http_client
            .get_text(&storage_url, headers)
            .await
            .map_err(|err| format!("storage scrape failed at {storage_url}: {err}"))?;

        let metrics = parse_metrics(&metrics_text);
        let storage_override = match parse_internal_storage_bytes(&storage_text) {
            Ok(parsed) => Some(parsed),
            Err(err) => {
                warn!(
                    vm_id = %vm.id,
                    hostname = %vm.hostname,
                    error = %err,
                    "failed to parse /internal/storage payload; continuing without storage override"
                );
                None
            }
        };

        let previous_counters = self
            .previous_counters_by_vm
            .lock()
            .unwrap()
            .get(&vm.id)
            .cloned()
            .unwrap_or_default();

        let extraction = extract_resource_vectors(
            &metrics,
            storage_override.as_ref(),
            &previous_counters,
            self.config.scrape_interval_secs as f64,
        );

        let aggregate = Self::aggregate_vm_load(&extraction.vectors);
        Ok((aggregate, extraction.vectors, extraction.next_counters))
    }

    /// Check if a VM is overloaded: any utilization dimension exceeds threshold.
    fn is_overloaded(utilization: &serde_json::Value, threshold: f64) -> bool {
        let dimensions = [
            "cpu_weight",
            "mem_rss_bytes",
            "disk_bytes",
            "query_rps",
            "indexing_rps",
        ];
        for dimension in &dimensions {
            if let Some(value) = utilization.get(dimension).and_then(|v| v.as_f64()) {
                if value > threshold {
                    return true;
                }
            }
        }
        false
    }

    /// Check if a VM is underloaded: all utilization dimensions below threshold.
    fn is_underloaded(utilization: &serde_json::Value, threshold: f64) -> bool {
        let dimensions = [
            "cpu_weight",
            "mem_rss_bytes",
            "disk_bytes",
            "query_rps",
            "indexing_rps",
        ];
        for dimension in &dimensions {
            if let Some(value) = utilization.get(dimension).and_then(|v| v.as_f64()) {
                if value >= threshold {
                    return false;
                }
            }
        }
        true
    }
}

fn is_missing_node_secret_error(error: &NodeSecretError) -> bool {
    match error {
        NodeSecretError::Api(message) => {
            let normalized = message.to_ascii_lowercase();
            normalized.contains("no key found for node")
                || normalized.contains("parameter not found")
                || normalized.contains("parameternotfound")
        }
        NodeSecretError::NotConfigured => false,
    }
}

#[cfg(test)]
mod layout_tests {
    use std::path::Path;

    #[test]
    fn scheduler_split_has_no_shared_module_file() {
        let scheduler_shared_module =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("src/services/scheduler/shared.rs");
        assert!(
            !scheduler_shared_module.exists(),
            "Stage 4 locked layout forbids scheduler/shared.rs"
        );
    }
}

#[cfg(test)]
mod run_cycle_tests {
    use super::SchedulerService;
    use crate::models::resource_vector::ResourceVector;
    use std::collections::HashMap;

    #[test]
    fn endpoint_url_joins_base_and_path() {
        assert_eq!(
            SchedulerService::endpoint_url("http://10.0.0.1:7700", "/metrics"),
            "http://10.0.0.1:7700/metrics"
        );
    }

    #[test]
    fn endpoint_url_strips_trailing_and_leading_slashes() {
        assert_eq!(
            SchedulerService::endpoint_url("http://host:7700/", "/metrics"),
            "http://host:7700/metrics"
        );
        assert_eq!(
            SchedulerService::endpoint_url("http://host:7700/", "metrics"),
            "http://host:7700/metrics"
        );
        assert_eq!(
            SchedulerService::endpoint_url("http://host:7700", "metrics"),
            "http://host:7700/metrics"
        );
    }

    /// Verifies utilization is computed as load / capacity per dimension
    /// (cpu 0.5, mem 0.5, disk 0.5, query_rps 0.1, indexing_rps 0.1).
    #[test]
    fn calculate_utilization_normal_load() {
        let load = ResourceVector {
            cpu_weight: 0.5,
            mem_rss_bytes: 500,
            disk_bytes: 1000,
            query_rps: 10.0,
            indexing_rps: 2.0,
        };
        let capacity = ResourceVector {
            cpu_weight: 1.0,
            mem_rss_bytes: 1000,
            disk_bytes: 2000,
            query_rps: 100.0,
            indexing_rps: 20.0,
        };
        let util = SchedulerService::calculate_utilization(&load, &capacity);
        assert_eq!(util["cpu_weight"].as_f64().unwrap(), 0.5);
        assert_eq!(util["mem_rss_bytes"].as_f64().unwrap(), 0.5);
        assert_eq!(util["disk_bytes"].as_f64().unwrap(), 0.5);
        assert_eq!(util["query_rps"].as_f64().unwrap(), 0.1);
        assert_eq!(util["indexing_rps"].as_f64().unwrap(), 0.1);
    }

    #[test]
    fn calculate_utilization_zero_capacity_returns_zero() {
        let load = ResourceVector {
            cpu_weight: 10.0,
            mem_rss_bytes: 500,
            disk_bytes: 1000,
            query_rps: 5.0,
            indexing_rps: 1.0,
        };
        let capacity = ResourceVector::zero();
        let util = SchedulerService::calculate_utilization(&load, &capacity);
        assert_eq!(util["cpu_weight"].as_f64().unwrap(), 0.0);
        assert_eq!(util["mem_rss_bytes"].as_f64().unwrap(), 0.0);
        assert_eq!(util["disk_bytes"].as_f64().unwrap(), 0.0);
    }

    /// Verifies that per-index resource vectors are summed element-wise to
    /// produce a single aggregate VM load vector.
    #[test]
    fn aggregate_vm_load_sums_all_vectors() {
        let mut map = HashMap::new();
        map.insert(
            "idx_a".to_string(),
            ResourceVector {
                cpu_weight: 0.3,
                mem_rss_bytes: 100,
                disk_bytes: 200,
                query_rps: 5.0,
                indexing_rps: 1.0,
            },
        );
        map.insert(
            "idx_b".to_string(),
            ResourceVector {
                cpu_weight: 0.7,
                mem_rss_bytes: 200,
                disk_bytes: 300,
                query_rps: 10.0,
                indexing_rps: 2.0,
            },
        );
        let agg = SchedulerService::aggregate_vm_load(&map);
        assert!((agg.cpu_weight - 1.0).abs() < f64::EPSILON);
        assert_eq!(agg.mem_rss_bytes, 300);
        assert_eq!(agg.disk_bytes, 500);
        assert!((agg.query_rps - 15.0).abs() < f64::EPSILON);
        assert!((agg.indexing_rps - 3.0).abs() < f64::EPSILON);
    }

    #[test]
    fn aggregate_vm_load_empty_map_returns_zero() {
        let map: HashMap<String, ResourceVector> = HashMap::new();
        let agg = SchedulerService::aggregate_vm_load(&map);
        assert_eq!(agg, ResourceVector::zero());
    }

    /// Verifies that the serialized VM load JSON includes a nested
    /// `"utilization"` key with per-dimension percentages.
    #[test]
    fn serialize_vm_load_includes_utilization() {
        let load = ResourceVector {
            cpu_weight: 0.5,
            mem_rss_bytes: 250,
            disk_bytes: 500,
            query_rps: 10.0,
            indexing_rps: 2.0,
        };
        let capacity = ResourceVector {
            cpu_weight: 1.0,
            mem_rss_bytes: 1000,
            disk_bytes: 1000,
            query_rps: 100.0,
            indexing_rps: 10.0,
        };
        let serialized = SchedulerService::serialize_vm_load(&load, &capacity);
        assert!(serialized.get("utilization").is_some());
        let util = &serialized["utilization"];
        assert_eq!(util["cpu_weight"].as_f64().unwrap(), 0.5);
        assert_eq!(util["disk_bytes"].as_f64().unwrap(), 0.5);
    }
}

#[cfg(test)]
mod threshold_tests {
    use super::SchedulerService;

    #[test]
    fn is_overloaded_when_any_dimension_exceeds_threshold() {
        let util = serde_json::json!({
            "cpu_weight": 0.9,
            "mem_rss_bytes": 0.3,
            "disk_bytes": 0.4,
            "query_rps": 0.5,
            "indexing_rps": 0.2,
        });
        assert!(SchedulerService::is_overloaded(&util, 0.85));
    }

    #[test]
    fn is_overloaded_false_when_all_below() {
        let util = serde_json::json!({
            "cpu_weight": 0.5,
            "mem_rss_bytes": 0.3,
            "disk_bytes": 0.4,
            "query_rps": 0.5,
            "indexing_rps": 0.2,
        });
        assert!(!SchedulerService::is_overloaded(&util, 0.85));
    }

    #[test]
    fn is_overloaded_false_at_exact_threshold() {
        let util = serde_json::json!({
            "cpu_weight": 0.85,
            "mem_rss_bytes": 0.85,
            "disk_bytes": 0.85,
            "query_rps": 0.85,
            "indexing_rps": 0.85,
        });
        // ">" not ">=" — at exact threshold is NOT overloaded
        assert!(!SchedulerService::is_overloaded(&util, 0.85));
    }

    #[test]
    fn is_underloaded_when_all_below_threshold() {
        let util = serde_json::json!({
            "cpu_weight": 0.1,
            "mem_rss_bytes": 0.05,
            "disk_bytes": 0.15,
            "query_rps": 0.02,
            "indexing_rps": 0.01,
        });
        assert!(SchedulerService::is_underloaded(&util, 0.20));
    }

    #[test]
    fn is_underloaded_false_when_any_at_or_above() {
        let util = serde_json::json!({
            "cpu_weight": 0.1,
            "mem_rss_bytes": 0.20,
            "disk_bytes": 0.05,
            "query_rps": 0.02,
            "indexing_rps": 0.01,
        });
        // ">=" — at exact threshold is NOT underloaded
        assert!(!SchedulerService::is_underloaded(&util, 0.20));
    }

    #[test]
    fn is_underloaded_true_when_all_zero() {
        let util = serde_json::json!({
            "cpu_weight": 0.0,
            "mem_rss_bytes": 0.0,
            "disk_bytes": 0.0,
            "query_rps": 0.0,
            "indexing_rps": 0.0,
        });
        assert!(SchedulerService::is_underloaded(&util, 0.20));
    }
}
