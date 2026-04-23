#![allow(clippy::await_holding_lock)]

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::sync::Mutex;
use std::time::Duration;

use api::models::vm_inventory::NewVmInventory;
use api::repos::TenantRepo;
use api::repos::VmInventoryRepo;
use api::secrets::NodeSecretManager;
use api::services::alerting::{AlertService, MockAlertService};
use api::services::scheduler::{
    MigrationRequest, NoopSchedulerMigrationService, SchedulerConfig, SchedulerHttpClient,
    SchedulerHttpClientError, SchedulerMigrationService, SchedulerService,
};
use async_trait::async_trait;
use chrono::Utc;
use tokio::sync::watch;

mod common;

fn reader(vars: HashMap<&'static str, &'static str>) -> impl Fn(&str) -> Option<String> {
    move |k| vars.get(k).map(|v| v.to_string())
}

#[test]
fn scheduler_config_defaults_when_env_missing() {
    let cfg = SchedulerConfig::from_reader(|_| None);
    assert_eq!(cfg.scrape_interval_secs, 300);
    assert!((cfg.overload_threshold - 0.85).abs() < f64::EPSILON);
    assert!((cfg.underload_threshold - 0.20).abs() < f64::EPSILON);
    assert_eq!(cfg.max_concurrent_migrations, 3);
    assert_eq!(cfg.overload_duration_secs, 600);
    assert_eq!(cfg.underload_duration_secs, 1800);
}

#[test]
fn scheduler_config_reads_env_values() {
    let cfg = SchedulerConfig::from_reader(reader(HashMap::from([
        ("SCHEDULER_SCRAPE_INTERVAL_SECS", "42"),
        ("SCHEDULER_OVERLOAD_THRESHOLD", "0.91"),
        ("SCHEDULER_UNDERLOAD_THRESHOLD", "0.12"),
        ("SCHEDULER_MAX_CONCURRENT_MIGRATIONS", "7"),
        ("SCHEDULER_OVERLOAD_DURATION_SECS", "1200"),
        ("SCHEDULER_UNDERLOAD_DURATION_SECS", "2400"),
    ])));

    assert_eq!(cfg.scrape_interval_secs, 42);
    assert!((cfg.overload_threshold - 0.91).abs() < f64::EPSILON);
    assert!((cfg.underload_threshold - 0.12).abs() < f64::EPSILON);
    assert_eq!(cfg.max_concurrent_migrations, 7);
    assert_eq!(cfg.overload_duration_secs, 1200);
    assert_eq!(cfg.underload_duration_secs, 2400);
}

#[test]
fn scheduler_config_invalid_values_fall_back_to_defaults() {
    let cfg = SchedulerConfig::from_reader(reader(HashMap::from([
        ("SCHEDULER_SCRAPE_INTERVAL_SECS", "abc"),
        ("SCHEDULER_OVERLOAD_THRESHOLD", "not-a-number"),
        ("SCHEDULER_UNDERLOAD_THRESHOLD", "-"),
        ("SCHEDULER_MAX_CONCURRENT_MIGRATIONS", "zero"),
        ("SCHEDULER_OVERLOAD_DURATION_SECS", ""),
        ("SCHEDULER_UNDERLOAD_DURATION_SECS", " "),
    ])));

    assert_eq!(cfg.scrape_interval_secs, 300);
    assert!((cfg.overload_threshold - 0.85).abs() < f64::EPSILON);
    assert!((cfg.underload_threshold - 0.20).abs() < f64::EPSILON);
    assert_eq!(cfg.max_concurrent_migrations, 3);
    assert_eq!(cfg.overload_duration_secs, 600);
    assert_eq!(cfg.underload_duration_secs, 1800);
}

fn new_vm_with_capacity(
    url: &str,
    hostname: &str,
    provider: &str,
    capacity: serde_json::Value,
) -> NewVmInventory {
    NewVmInventory {
        region: "us-east-1".to_string(),
        provider: provider.to_string(),
        hostname: hostname.to_string(),
        flapjack_url: url.to_string(),
        capacity,
    }
}

fn new_vm_with_provider(url: &str, hostname: &str, provider: &str) -> NewVmInventory {
    new_vm_with_capacity(
        url,
        hostname,
        provider,
        common::capacity_profiles::vm_capacity_json(),
    )
}

fn new_vm(url: &str, hostname: &str) -> NewVmInventory {
    new_vm_with_provider(url, hostname, "aws")
}

fn small_capacity_json() -> serde_json::Value {
    serde_json::json!({
        "cpu_weight": 4.0,
        "mem_rss_bytes": 1_000_u64,
        "disk_bytes": 1_000_u64,
        "query_rps": 100.0,
        "indexing_rps": 100.0,
    })
}

fn new_vm_small_with_provider(url: &str, hostname: &str, provider: &str) -> NewVmInventory {
    new_vm_with_capacity(url, hostname, provider, small_capacity_json())
}

fn new_vm_small(url: &str, hostname: &str) -> NewVmInventory {
    new_vm_small_with_provider(url, hostname, "aws")
}

#[derive(Default)]
struct MockSchedulerHttpClient {
    responses: Mutex<HashMap<String, Vec<Result<String, SchedulerHttpClientError>>>>,
    observed_headers: Mutex<HashMap<String, Vec<HashMap<String, String>>>>,
}

impl MockSchedulerHttpClient {
    fn push_ok(&self, url: &str, body: &str) {
        self.responses
            .lock()
            .unwrap()
            .entry(url.to_string())
            .or_default()
            .push(Ok(body.to_string()));
    }

    fn push_err(&self, url: &str, message: &str) {
        self.responses
            .lock()
            .unwrap()
            .entry(url.to_string())
            .or_default()
            .push(Err(SchedulerHttpClientError::Unreachable(
                message.to_string(),
            )));
    }
}

#[async_trait]
impl SchedulerHttpClient for MockSchedulerHttpClient {
    async fn get_text(
        &self,
        url: &str,
        headers: HashMap<String, String>,
    ) -> Result<String, SchedulerHttpClientError> {
        self.observed_headers
            .lock()
            .unwrap()
            .entry(url.to_string())
            .or_default()
            .push(headers);
        let mut responses = self.responses.lock().unwrap();
        let queue = responses.entry(url.to_string()).or_default();
        if queue.is_empty() {
            return Err(SchedulerHttpClientError::Unreachable(format!(
                "missing mocked response for {url}"
            )));
        }
        queue.remove(0)
    }
}

fn scheduler_service(
    vm_repo: Arc<common::MockVmInventoryRepo>,
    scrape_interval_secs: u64,
    http_client: Arc<dyn SchedulerHttpClient>,
) -> SchedulerService {
    SchedulerService::with_http_client(
        SchedulerConfig {
            scrape_interval_secs,
            ..SchedulerConfig::default()
        },
        vm_repo,
        common::mock_tenant_repo(),
        Arc::new(NoopSchedulerMigrationService),
        Arc::new(MockAlertService::new()),
        common::mock_node_secret_manager(),
        http_client,
    )
}

#[tokio::test]
async fn scheduler_run_cycle_returns_active_vm_count() {
    let vm_repo = common::mock_vm_inventory_repo();
    let mock_http = Arc::new(MockSchedulerHttpClient::default());

    mock_http.push_ok(
        "http://vm-active.flapjack.foo/metrics",
        "flapjack_documents_count{index=\"products\"} 1\nflapjack_memory_heap_bytes 100\n",
    );
    mock_http.push_ok(
        "http://vm-active.flapjack.foo/internal/storage",
        r#"{"tenants":[{"id":"products","bytes":10}]}"#,
    );

    let active_vm = vm_repo
        .create(NewVmInventory {
            region: "us-east-1".to_string(),
            provider: "aws".to_string(),
            hostname: "vm-active.flapjack.foo".to_string(),
            flapjack_url: "http://vm-active.flapjack.foo".to_string(),
            capacity: serde_json::json!({"cpu_weight": 4.0}),
        })
        .await
        .unwrap();

    let decommissioned_vm = vm_repo
        .create(NewVmInventory {
            region: "us-east-1".to_string(),
            provider: "aws".to_string(),
            hostname: "vm-old.flapjack.foo".to_string(),
            flapjack_url: "http://vm-old.flapjack.foo".to_string(),
            capacity: serde_json::json!({"cpu_weight": 4.0}),
        })
        .await
        .unwrap();

    vm_repo
        .set_status(decommissioned_vm.id, "decommissioned")
        .await
        .unwrap();

    let svc = scheduler_service(Arc::clone(&vm_repo), 60, mock_http);

    let count = svc.run_cycle().await.unwrap();
    assert_eq!(count, 1);

    let listed = svc
        .vm_inventory_repo()
        .get(active_vm.id)
        .await
        .unwrap()
        .expect("active VM should still exist");
    assert_eq!(listed.hostname, "vm-active.flapjack.foo");
}

#[tokio::test]
async fn run_cycle_scrapes_metrics_and_updates_vm_load() {
    let vm_repo = common::mock_vm_inventory_repo();
    let mock_http = Arc::new(MockSchedulerHttpClient::default());
    let base_url = "http://vm-scrape.local";
    mock_http.push_ok(
        "http://vm-scrape.local/metrics",
        r#"
flapjack_search_requests_total{index="products"} 100
flapjack_documents_indexed_total{index="products"} 20
flapjack_documents_count{index="products"} 3
flapjack_documents_count{index="orders"} 1
flapjack_memory_heap_bytes 400
"#,
    );
    mock_http.push_ok(
        "http://vm-scrape.local/internal/storage",
        r#"{"tenants":[{"id":"products","bytes":250},{"id":"orders","bytes":50}]}"#,
    );
    let vm = vm_repo
        .create(new_vm_small(base_url, "vm-scrape.flapjack.foo"))
        .await
        .unwrap();

    let svc = scheduler_service(Arc::clone(&vm_repo), 60, mock_http);
    let count = svc.run_cycle().await.unwrap();

    assert_eq!(count, 1);
    let updated = vm_repo.get(vm.id).await.unwrap().unwrap();
    assert_eq!(updated.current_load["mem_rss_bytes"], 400);
    assert_eq!(updated.current_load["disk_bytes"], 300);
    assert_eq!(updated.current_load["query_rps"], 0.0);
    assert_eq!(updated.current_load["indexing_rps"], 0.0);
    assert_eq!(updated.current_load["utilization"]["mem_rss_bytes"], 0.4);
    assert_eq!(updated.current_load["utilization"]["disk_bytes"], 0.3);
}

#[tokio::test]
async fn run_cycle_uses_vm_hostname_secret_for_internal_scrapes() {
    let vm_repo = common::mock_vm_inventory_repo();
    let mock_http = Arc::new(MockSchedulerHttpClient::default());
    let node_secret_manager = common::mock_node_secret_manager();
    let base_url = "http://vm-auth.local";

    mock_http.push_ok(
        "http://vm-auth.local/metrics",
        "flapjack_memory_heap_bytes 10\n",
    );
    mock_http.push_ok("http://vm-auth.local/internal/storage", r#"{"tenants":[]}"#);

    let vm = vm_repo
        .create(new_vm(base_url, "vm-auth.flapjack.foo"))
        .await
        .unwrap();
    let expected_key = node_secret_manager
        .create_node_api_key(vm.node_secret_id(), &vm.region)
        .await
        .unwrap();

    let svc = SchedulerService::with_http_client(
        SchedulerConfig {
            scrape_interval_secs: 60,
            ..SchedulerConfig::default()
        },
        vm_repo,
        common::mock_tenant_repo(),
        Arc::new(NoopSchedulerMigrationService),
        Arc::new(MockAlertService::new()),
        node_secret_manager,
        mock_http.clone(),
    );

    svc.run_cycle().await.unwrap();

    let recorded = mock_http.observed_headers.lock().unwrap();
    let headers = recorded
        .get("http://vm-auth.local/metrics")
        .and_then(|requests| requests.first())
        .expect("metrics request should record headers");
    assert_eq!(
        headers.get("x-algolia-api-key"),
        Some(&expected_key),
        "scheduler should authenticate internal scrapes with the VM hostname secret"
    );
    assert_eq!(
        headers.get("x-algolia-application-id"),
        Some(&"flapjack".to_string())
    );
}

#[tokio::test]
async fn run_cycle_uses_previous_counters_for_rps_delta() {
    let vm_repo = common::mock_vm_inventory_repo();
    let mock_http = Arc::new(MockSchedulerHttpClient::default());
    let base_url = "http://vm-delta.local";
    mock_http.push_ok(
        "http://vm-delta.local/metrics",
        r#"
flapjack_search_requests_total{index="products"} 100
flapjack_documents_indexed_total{index="products"} 20
flapjack_documents_count{index="products"} 1
flapjack_memory_heap_bytes 200
"#,
    );
    mock_http.push_ok(
        "http://vm-delta.local/internal/storage",
        r#"{"tenants":[{"id":"products","bytes":100}]}"#,
    );
    mock_http.push_ok(
        "http://vm-delta.local/metrics",
        r#"
flapjack_search_requests_total{index="products"} 160
flapjack_documents_indexed_total{index="products"} 50
flapjack_documents_count{index="products"} 1
flapjack_memory_heap_bytes 200
"#,
    );
    mock_http.push_ok(
        "http://vm-delta.local/internal/storage",
        r#"{"tenants":[{"id":"products","bytes":100}]}"#,
    );
    let vm = vm_repo
        .create(new_vm(base_url, "vm-delta.flapjack.foo"))
        .await
        .unwrap();

    let svc = scheduler_service(Arc::clone(&vm_repo), 60, mock_http);
    svc.run_cycle().await.unwrap();
    svc.run_cycle().await.unwrap();

    let updated = vm_repo.get(vm.id).await.unwrap().unwrap();
    assert!((updated.current_load["query_rps"].as_f64().unwrap() - 1.0).abs() < 1e-9);
    assert!((updated.current_load["indexing_rps"].as_f64().unwrap() - 0.5).abs() < 1e-9);
}

#[tokio::test]
async fn scrape_failure_does_not_crash_cycle() {
    let vm_repo = common::mock_vm_inventory_repo();
    let mock_http = Arc::new(MockSchedulerHttpClient::default());
    mock_http.push_ok(
        "http://vm-healthy.local/metrics",
        r#"
flapjack_documents_count{index="products"} 1
flapjack_memory_heap_bytes 100
"#,
    );
    mock_http.push_ok(
        "http://vm-healthy.local/internal/storage",
        r#"{"tenants":[{"id":"products","bytes":5}]}"#,
    );
    mock_http.push_err("http://vm-unreachable.local/metrics", "connect failed");
    mock_http.push_err(
        "http://vm-unreachable.local/internal/storage",
        "connect failed",
    );

    let healthy_vm = vm_repo
        .create(new_vm("http://vm-healthy.local", "vm-healthy.flapjack.foo"))
        .await
        .unwrap();
    let unreachable_vm = vm_repo
        .create(new_vm(
            "http://vm-unreachable.local",
            "vm-unreachable.flapjack.foo",
        ))
        .await
        .unwrap();

    let svc = scheduler_service(Arc::clone(&vm_repo), 60, mock_http);
    let count = svc.run_cycle().await.unwrap();

    assert_eq!(count, 2);

    let healthy_updated = vm_repo.get(healthy_vm.id).await.unwrap().unwrap();
    assert_eq!(healthy_updated.current_load["disk_bytes"], 5);

    let unreachable_unmodified = vm_repo.get(unreachable_vm.id).await.unwrap().unwrap();
    assert_eq!(unreachable_unmodified.current_load, serde_json::json!({}));
}

#[tokio::test]
async fn run_cycle_handles_repo_list_active_failure_gracefully() {
    let vm_repo = common::mock_vm_inventory_repo();
    let mock_http = Arc::new(MockSchedulerHttpClient::default());
    let svc = scheduler_service(
        Arc::clone(&vm_repo),
        60,
        Arc::clone(&mock_http) as Arc<dyn SchedulerHttpClient>,
    );

    vm_repo.set_should_fail(true);
    let first = svc.run_cycle().await;
    assert!(
        matches!(
            first,
            Err(api::services::scheduler::SchedulerError::Repo(ref msg))
            if msg.contains("mock vm inventory failure")
        ),
        "run_cycle should return SchedulerError::Repo on list_active failure: {first:?}"
    );

    vm_repo.set_should_fail(false);
    mock_http.push_ok(
        "http://vm-recovery.local/metrics",
        r#"
flapjack_documents_count{index="products"} 1
flapjack_memory_heap_bytes 100
"#,
    );
    mock_http.push_ok(
        "http://vm-recovery.local/internal/storage",
        r#"{"tenants":[{"id":"products","bytes":5}]}"#,
    );

    let vm = vm_repo
        .create(new_vm(
            "http://vm-recovery.local",
            "vm-recovery.flapjack.foo",
        ))
        .await
        .unwrap();

    let second = svc.run_cycle().await;
    assert!(
        second.is_ok(),
        "run_cycle should recover after repo list_active failure: {second:?}"
    );
    assert_eq!(second.unwrap(), 1);

    let updated = vm_repo.get(vm.id).await.unwrap().unwrap();
    assert_eq!(updated.current_load["disk_bytes"], 5);
}

#[tokio::test]
async fn scheduler_run_stops_on_shutdown_signal() {
    let svc = SchedulerService::new(
        SchedulerConfig {
            scrape_interval_secs: 600,
            ..SchedulerConfig::default()
        },
        common::mock_vm_inventory_repo(),
        common::mock_tenant_repo(),
        Arc::new(NoopSchedulerMigrationService),
        Arc::new(MockAlertService::new()),
        common::mock_node_secret_manager(),
        reqwest::Client::new(),
    );

    let (shutdown_tx, shutdown_rx) = watch::channel(false);

    let handle = tokio::spawn(async move {
        svc.run(shutdown_rx).await;
    });

    shutdown_tx.send(true).unwrap();

    let join_result = tokio::time::timeout(Duration::from_secs(1), handle)
        .await
        .expect("scheduler should stop promptly");
    assert!(join_result.is_ok());
}

// ---------------------------------------------------------------------------
// MockSchedulerMigrationService — records migration requests for assertions
// ---------------------------------------------------------------------------

#[derive(Default)]
struct MockSchedulerMigrationService {
    requests: Mutex<Vec<MigrationRequest>>,
}

#[async_trait]
impl SchedulerMigrationService for MockSchedulerMigrationService {
    async fn request_migration(&self, req: MigrationRequest) -> Result<(), String> {
        self.requests.lock().unwrap().push(req);
        Ok(())
    }
}

struct FailableMockSchedulerMigrationService {
    requests: Mutex<Vec<MigrationRequest>>,
    should_fail: AtomicBool,
}

impl Default for FailableMockSchedulerMigrationService {
    fn default() -> Self {
        Self {
            requests: Mutex::new(Vec::new()),
            should_fail: AtomicBool::new(false),
        }
    }
}

impl FailableMockSchedulerMigrationService {
    fn set_should_fail(&self, should_fail: bool) {
        self.should_fail.store(should_fail, Ordering::SeqCst);
    }

    fn request_count(&self) -> usize {
        self.requests.lock().unwrap().len()
    }
}

#[async_trait]
impl SchedulerMigrationService for FailableMockSchedulerMigrationService {
    async fn request_migration(&self, req: MigrationRequest) -> Result<(), String> {
        self.requests.lock().unwrap().push(req);
        if self.should_fail.load(Ordering::SeqCst) {
            Err("simulated failure".to_string())
        } else {
            Ok(())
        }
    }
}

// Helper: build scheduler with a specific tenant repo and migration service
fn scheduler_with_deps<M>(
    vm_repo: Arc<common::MockVmInventoryRepo>,
    tenant_repo: Arc<common::MockTenantRepo>,
    migration_svc: Arc<M>,
    http_client: Arc<dyn SchedulerHttpClient>,
    config: SchedulerConfig,
) -> SchedulerService
where
    M: SchedulerMigrationService + Send + Sync + 'static,
{
    SchedulerService::with_http_client(
        config,
        vm_repo,
        tenant_repo,
        migration_svc,
        Arc::new(MockAlertService::new()),
        common::mock_node_secret_manager(),
        http_client,
    )
}

fn scheduler_with_alerts<M>(
    vm_repo: Arc<common::MockVmInventoryRepo>,
    tenant_repo: Arc<common::MockTenantRepo>,
    migration_svc: Arc<M>,
    alert_service: Arc<MockAlertService>,
    http_client: Arc<dyn SchedulerHttpClient>,
    config: SchedulerConfig,
) -> SchedulerService
where
    M: SchedulerMigrationService + Send + Sync + 'static,
{
    SchedulerService::with_http_client(
        config,
        vm_repo,
        tenant_repo,
        migration_svc,
        alert_service,
        common::mock_node_secret_manager(),
        http_client,
    )
}

/// VM overloaded for threshold duration → heaviest index selected for migration.
///
/// Setup: one VM with capacity (4 CPU, 1000 mem, 1000 disk, 100 qps, 100 ips).
/// Metrics show disk at 900 of 1000 (90% > 85% threshold).
/// Two indexes on the VM: "heavy" (800 disk) and "light" (100 disk).
/// Duration threshold = 0 (trigger immediately).
/// Expect: migration requested for "heavy" index.
#[tokio::test]
async fn overload_triggers_migration_of_heaviest_index() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let migration_svc = Arc::new(MockSchedulerMigrationService::default());
    let mock_http = Arc::new(MockSchedulerHttpClient::default());

    // Create two VMs: one overloaded, one with spare capacity (migration destination)
    let overloaded_vm = vm_repo
        .create(new_vm_small(
            "http://vm-overloaded.local",
            "vm-overloaded.flapjack.foo",
        ))
        .await
        .unwrap();

    let dest_vm = vm_repo
        .create(new_vm_small("http://vm-dest.local", "vm-dest.flapjack.foo"))
        .await
        .unwrap();

    // Destination VM: metrics show light load
    mock_http.push_ok(
        "http://vm-dest.local/metrics",
        "flapjack_documents_count{index=\"other\"} 1\nflapjack_memory_heap_bytes 50\n",
    );
    mock_http.push_ok(
        "http://vm-dest.local/internal/storage",
        r#"{"tenants":[{"id":"other","bytes":10}]}"#,
    );

    // Overloaded VM: 900 of 1000 disk bytes (90%) — exceeds 85% threshold
    mock_http.push_ok(
        "http://vm-overloaded.local/metrics",
        r#"
flapjack_documents_count{index="heavy"} 8
flapjack_documents_count{index="light"} 2
flapjack_memory_heap_bytes 100
"#,
    );
    mock_http.push_ok(
        "http://vm-overloaded.local/internal/storage",
        r#"{"tenants":[{"id":"heavy","bytes":800},{"id":"light","bytes":100}]}"#,
    );

    register_heavy_and_light_indexes(&tenant_repo, overloaded_vm.id).await;

    let config = SchedulerConfig {
        scrape_interval_secs: 60,
        overload_threshold: 0.85,
        overload_duration_secs: 0, // trigger immediately
        ..SchedulerConfig::default()
    };

    let svc = scheduler_with_deps(
        Arc::clone(&vm_repo),
        tenant_repo,
        Arc::clone(&migration_svc),
        mock_http,
        config,
    );

    svc.run_cycle().await.unwrap();

    let requests = migration_svc.requests.lock().unwrap();
    assert_eq!(requests.len(), 1, "should have triggered one migration");
    assert_eq!(
        requests[0].index_name, "heavy",
        "heaviest index should be migrated"
    );
    assert_eq!(requests[0].source_vm_id, overloaded_vm.id);
    assert_eq!(requests[0].dest_vm_id, dest_vm.id);
    assert_eq!(requests[0].reason, "overload");
}

#[tokio::test]
async fn scheduler_places_within_same_provider() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let migration_svc = Arc::new(MockSchedulerMigrationService::default());
    let mock_http = Arc::new(MockSchedulerHttpClient::default());

    let overloaded_vm = vm_repo
        .create(new_vm_small_with_provider(
            "http://vm-overloaded.local",
            "vm-overloaded.flapjack.foo",
            "aws",
        ))
        .await
        .unwrap();
    let hetzner_dest_vm = vm_repo
        .create(new_vm_small_with_provider(
            "http://vm-hetzner-dest.local",
            "vm-hetzner-dest.flapjack.foo",
            "hetzner",
        ))
        .await
        .unwrap();
    let aws_dest_vm = vm_repo
        .create(new_vm_small_with_provider(
            "http://vm-aws-dest.local",
            "vm-aws-dest.flapjack.foo",
            "aws",
        ))
        .await
        .unwrap();

    mock_http.push_ok(
        "http://vm-overloaded.local/metrics",
        r#"
flapjack_documents_count{index="heavy"} 8
flapjack_documents_count{index="light"} 2
flapjack_memory_heap_bytes 100
"#,
    );
    mock_http.push_ok(
        "http://vm-overloaded.local/internal/storage",
        r#"{"tenants":[{"id":"heavy","bytes":800},{"id":"light","bytes":100}]}"#,
    );

    mock_http.push_ok(
        "http://vm-hetzner-dest.local/metrics",
        "flapjack_documents_count{index=\"other\"} 1\nflapjack_memory_heap_bytes 50\n",
    );
    mock_http.push_ok(
        "http://vm-hetzner-dest.local/internal/storage",
        r#"{"tenants":[{"id":"other","bytes":10}]}"#,
    );

    mock_http.push_ok(
        "http://vm-aws-dest.local/metrics",
        "flapjack_documents_count{index=\"other2\"} 1\nflapjack_memory_heap_bytes 50\n",
    );
    mock_http.push_ok(
        "http://vm-aws-dest.local/internal/storage",
        r#"{"tenants":[{"id":"other2","bytes":10}]}"#,
    );

    register_heavy_and_light_indexes(&tenant_repo, overloaded_vm.id).await;

    let svc = scheduler_with_deps(
        Arc::clone(&vm_repo),
        tenant_repo,
        Arc::clone(&migration_svc),
        mock_http,
        SchedulerConfig {
            scrape_interval_secs: 60,
            overload_threshold: 0.85,
            overload_duration_secs: 0,
            ..SchedulerConfig::default()
        },
    );

    let count = svc.run_cycle().await.unwrap();
    assert_eq!(
        count, 3,
        "run_cycle must consider active VMs across providers in the same region"
    );

    let requests = migration_svc.requests.lock().unwrap();
    assert_eq!(requests.len(), 1, "expected overload migration request");
    assert_eq!(
        requests[0].dest_vm_id, aws_dest_vm.id,
        "scheduler must pick same-provider destination"
    );
    assert_ne!(
        requests[0].dest_vm_id, hetzner_dest_vm.id,
        "scheduler must not cross providers automatically"
    );
}

#[tokio::test]
async fn scheduler_alerts_when_no_same_provider_capacity() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let migration_svc = Arc::new(MockSchedulerMigrationService::default());
    let alert_svc = Arc::new(MockAlertService::new());
    let mock_http = Arc::new(MockSchedulerHttpClient::default());

    let overloaded_vm = vm_repo
        .create(new_vm_small_with_provider(
            "http://vm-overloaded.local",
            "vm-overloaded.flapjack.foo",
            "aws",
        ))
        .await
        .unwrap();
    vm_repo
        .create(new_vm_small_with_provider(
            "http://vm-hetzner-dest.local",
            "vm-hetzner-dest.flapjack.foo",
            "hetzner",
        ))
        .await
        .unwrap();

    mock_http.push_ok(
        "http://vm-overloaded.local/metrics",
        r#"
flapjack_documents_count{index="heavy"} 8
flapjack_documents_count{index="light"} 2
flapjack_memory_heap_bytes 100
"#,
    );
    mock_http.push_ok(
        "http://vm-overloaded.local/internal/storage",
        r#"{"tenants":[{"id":"heavy","bytes":800},{"id":"light","bytes":100}]}"#,
    );

    mock_http.push_ok(
        "http://vm-hetzner-dest.local/metrics",
        "flapjack_documents_count{index=\"other\"} 1\nflapjack_memory_heap_bytes 50\n",
    );
    mock_http.push_ok(
        "http://vm-hetzner-dest.local/internal/storage",
        r#"{"tenants":[{"id":"other","bytes":10}]}"#,
    );

    register_heavy_and_light_indexes(&tenant_repo, overloaded_vm.id).await;

    let svc = scheduler_with_alerts(
        Arc::clone(&vm_repo),
        tenant_repo,
        Arc::clone(&migration_svc),
        Arc::clone(&alert_svc),
        mock_http,
        SchedulerConfig {
            scrape_interval_secs: 60,
            overload_threshold: 0.85,
            overload_duration_secs: 0,
            ..SchedulerConfig::default()
        },
    );

    svc.run_cycle().await.unwrap();

    let requests = migration_svc.requests.lock().unwrap();
    assert_eq!(
        requests.len(),
        0,
        "scheduler must skip auto-migration when only cross-provider capacity exists"
    );

    let alerts = alert_svc.get_recent_alerts(100).await.unwrap();
    let warning = alerts
        .iter()
        .find(|alert| {
            alert.severity == api::services::alerting::AlertSeverity::Warning
                && alert.title.contains("Cross-provider migration blocked")
        })
        .expect("expected warning alert for no same-provider capacity");

    assert_eq!(
        warning
            .metadata
            .get("source_provider")
            .and_then(|value| value.as_str()),
        Some("aws")
    );
}

#[tokio::test]
async fn scheduler_overload_no_destination_capacity_does_not_overcommit() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let migration_svc = Arc::new(MockSchedulerMigrationService::default());
    let alert_svc = Arc::new(MockAlertService::new());
    let mock_http = Arc::new(MockSchedulerHttpClient::default());

    let overloaded_vm = vm_repo
        .create(new_vm_small(
            "http://vm-overloaded.local",
            "vm-overloaded.flapjack.foo",
        ))
        .await
        .unwrap();
    vm_repo
        .create(new_vm_small("http://vm-dest.local", "vm-dest.flapjack.foo"))
        .await
        .unwrap();

    mock_http.push_ok(
        "http://vm-overloaded.local/metrics",
        r#"
flapjack_documents_count{index="heavy"} 8
flapjack_documents_count{index="light"} 2
flapjack_memory_heap_bytes 100
"#,
    );
    mock_http.push_ok(
        "http://vm-overloaded.local/internal/storage",
        r#"{"tenants":[{"id":"heavy","bytes":800},{"id":"light","bytes":100}]}"#,
    );

    mock_http.push_ok(
        "http://vm-dest.local/metrics",
        "flapjack_documents_count{index=\"other\"} 9\nflapjack_memory_heap_bytes 50\n",
    );
    mock_http.push_ok(
        "http://vm-dest.local/internal/storage",
        r#"{"tenants":[{"id":"other","bytes":950}]}"#,
    );

    register_heavy_and_light_indexes(&tenant_repo, overloaded_vm.id).await;

    let svc = scheduler_with_alerts(
        Arc::clone(&vm_repo),
        tenant_repo,
        Arc::clone(&migration_svc),
        Arc::clone(&alert_svc),
        mock_http,
        SchedulerConfig {
            scrape_interval_secs: 60,
            overload_threshold: 0.85,
            overload_duration_secs: 0,
            ..SchedulerConfig::default()
        },
    );

    svc.run_cycle().await.unwrap();

    assert!(
        migration_svc.requests.lock().unwrap().is_empty(),
        "scheduler must not request a migration that would overcommit destination capacity"
    );

    let alerts = alert_svc.get_recent_alerts(100).await.unwrap();
    assert!(
        alerts.iter().any(|alert| {
            alert.severity == api::services::alerting::AlertSeverity::Warning
                && alert.title.contains("Cross-provider migration blocked")
        }),
        "expected warning alert when overload migration has no same-provider capacity"
    );
}

async fn register_heavy_and_light_indexes(
    tenant_repo: &Arc<common::MockTenantRepo>,
    vm_id: uuid::Uuid,
) {
    let customer_id = uuid::Uuid::new_v4();
    let deploy_id = uuid::Uuid::new_v4();
    tenant_repo
        .create(customer_id, "heavy", deploy_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "heavy", vm_id)
        .await
        .unwrap();
    tenant_repo
        .create(customer_id, "light", deploy_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "light", vm_id)
        .await
        .unwrap();
}

fn push_overloaded_cycle(
    mock_http: &MockSchedulerHttpClient,
    overloaded_url: &str,
    dest_url: &str,
) {
    mock_http.push_ok(
        &format!("{overloaded_url}/metrics"),
        r#"
flapjack_documents_count{index="heavy"} 8
flapjack_documents_count{index="light"} 2
flapjack_memory_heap_bytes 100
"#,
    );
    mock_http.push_ok(
        &format!("{overloaded_url}/internal/storage"),
        r#"{"tenants":[{"id":"heavy","bytes":800},{"id":"light","bytes":100}]}"#,
    );
    mock_http.push_ok(
        &format!("{dest_url}/metrics"),
        "flapjack_documents_count{index=\"other\"} 1\nflapjack_memory_heap_bytes 50\n",
    );
    mock_http.push_ok(
        &format!("{dest_url}/internal/storage"),
        r#"{"tenants":[{"id":"other","bytes":10}]}"#,
    );
}

fn push_relieved_cycle(mock_http: &MockSchedulerHttpClient, overloaded_url: &str, dest_url: &str) {
    mock_http.push_ok(
        &format!("{overloaded_url}/metrics"),
        r#"
flapjack_documents_count{index="heavy"} 1
flapjack_documents_count{index="light"} 1
flapjack_memory_heap_bytes 100
"#,
    );
    mock_http.push_ok(
        &format!("{overloaded_url}/internal/storage"),
        r#"{"tenants":[{"id":"heavy","bytes":100},{"id":"light","bytes":100}]}"#,
    );
    mock_http.push_ok(
        &format!("{dest_url}/metrics"),
        "flapjack_documents_count{index=\"other\"} 1\nflapjack_memory_heap_bytes 50\n",
    );
    mock_http.push_ok(
        &format!("{dest_url}/internal/storage"),
        r#"{"tenants":[{"id":"other","bytes":10}]}"#,
    );
}

#[tokio::test]
async fn overload_duration_gates_migration() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let migration_svc = Arc::new(MockSchedulerMigrationService::default());
    let mock_http = Arc::new(MockSchedulerHttpClient::default());

    let overloaded_vm = vm_repo
        .create(new_vm_small(
            "http://vm-overloaded.local",
            "vm-overloaded.flapjack.foo",
        ))
        .await
        .unwrap();
    vm_repo
        .create(new_vm_small("http://vm-dest.local", "vm-dest.flapjack.foo"))
        .await
        .unwrap();
    register_heavy_and_light_indexes(&tenant_repo, overloaded_vm.id).await;

    push_overloaded_cycle(
        &mock_http,
        "http://vm-overloaded.local",
        "http://vm-dest.local",
    );
    push_overloaded_cycle(
        &mock_http,
        "http://vm-overloaded.local",
        "http://vm-dest.local",
    );

    let svc = scheduler_with_deps(
        Arc::clone(&vm_repo),
        tenant_repo,
        Arc::clone(&migration_svc),
        mock_http,
        SchedulerConfig {
            scrape_interval_secs: 60,
            overload_threshold: 0.85,
            overload_duration_secs: 1,
            ..SchedulerConfig::default()
        },
    );

    svc.run_cycle().await.unwrap();
    assert_eq!(migration_svc.requests.lock().unwrap().len(), 0);

    tokio::time::sleep(Duration::from_millis(1100)).await;
    svc.run_cycle().await.unwrap();
    assert_eq!(migration_svc.requests.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn overload_clears_timer_when_load_drops() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let migration_svc = Arc::new(MockSchedulerMigrationService::default());
    let mock_http = Arc::new(MockSchedulerHttpClient::default());

    let overloaded_vm = vm_repo
        .create(new_vm_small(
            "http://vm-overloaded.local",
            "vm-overloaded.flapjack.foo",
        ))
        .await
        .unwrap();
    vm_repo
        .create(new_vm_small("http://vm-dest.local", "vm-dest.flapjack.foo"))
        .await
        .unwrap();
    register_heavy_and_light_indexes(&tenant_repo, overloaded_vm.id).await;

    push_overloaded_cycle(
        &mock_http,
        "http://vm-overloaded.local",
        "http://vm-dest.local",
    );
    push_relieved_cycle(
        &mock_http,
        "http://vm-overloaded.local",
        "http://vm-dest.local",
    );
    push_overloaded_cycle(
        &mock_http,
        "http://vm-overloaded.local",
        "http://vm-dest.local",
    );

    let svc = scheduler_with_deps(
        Arc::clone(&vm_repo),
        tenant_repo,
        Arc::clone(&migration_svc),
        mock_http,
        SchedulerConfig {
            scrape_interval_secs: 60,
            overload_threshold: 0.85,
            overload_duration_secs: 1,
            ..SchedulerConfig::default()
        },
    );

    svc.run_cycle().await.unwrap();
    assert_eq!(migration_svc.requests.lock().unwrap().len(), 0);

    svc.run_cycle().await.unwrap();
    assert_eq!(migration_svc.requests.lock().unwrap().len(), 0);

    tokio::time::sleep(Duration::from_millis(1100)).await;
    svc.run_cycle().await.unwrap();
    assert_eq!(
        migration_svc.requests.lock().unwrap().len(),
        0,
        "overload timer should restart after load drops"
    );
}

#[tokio::test]
async fn migration_failure_preserves_overload_timer() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let migration_svc = Arc::new(FailableMockSchedulerMigrationService::default());
    let mock_http = Arc::new(MockSchedulerHttpClient::default());

    let overloaded_vm = vm_repo
        .create(new_vm_small(
            "http://vm-overloaded.local",
            "vm-overloaded.flapjack.foo",
        ))
        .await
        .unwrap();
    vm_repo
        .create(new_vm_small("http://vm-dest.local", "vm-dest.flapjack.foo"))
        .await
        .unwrap();
    register_heavy_and_light_indexes(&tenant_repo, overloaded_vm.id).await;

    push_overloaded_cycle(
        &mock_http,
        "http://vm-overloaded.local",
        "http://vm-dest.local",
    );
    push_overloaded_cycle(
        &mock_http,
        "http://vm-overloaded.local",
        "http://vm-dest.local",
    );
    push_overloaded_cycle(
        &mock_http,
        "http://vm-overloaded.local",
        "http://vm-dest.local",
    );

    migration_svc.set_should_fail(true);
    let svc = scheduler_with_deps(
        Arc::clone(&vm_repo),
        tenant_repo,
        Arc::clone(&migration_svc),
        mock_http,
        SchedulerConfig {
            scrape_interval_secs: 60,
            overload_threshold: 0.85,
            overload_duration_secs: 1,
            ..SchedulerConfig::default()
        },
    );

    svc.run_cycle().await.unwrap();
    assert_eq!(migration_svc.request_count(), 0);

    tokio::time::sleep(Duration::from_millis(1100)).await;
    svc.run_cycle().await.unwrap();
    assert_eq!(migration_svc.request_count(), 1);

    svc.run_cycle().await.unwrap();
    assert_eq!(
        migration_svc.request_count(),
        2,
        "failed migrations should not reset overload timing window"
    );
}

#[tokio::test]
async fn overload_re_migration_allowed_on_subsequent_cycle() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let migration_svc = Arc::new(MockSchedulerMigrationService::default());
    let mock_http = Arc::new(MockSchedulerHttpClient::default());

    let overloaded_vm = vm_repo
        .create(new_vm_small(
            "http://vm-overloaded.local",
            "vm-overloaded.flapjack.foo",
        ))
        .await
        .unwrap();
    vm_repo
        .create(new_vm_small("http://vm-dest.local", "vm-dest.flapjack.foo"))
        .await
        .unwrap();
    register_heavy_and_light_indexes(&tenant_repo, overloaded_vm.id).await;

    push_overloaded_cycle(
        &mock_http,
        "http://vm-overloaded.local",
        "http://vm-dest.local",
    );
    push_overloaded_cycle(
        &mock_http,
        "http://vm-overloaded.local",
        "http://vm-dest.local",
    );

    let svc = scheduler_with_deps(
        Arc::clone(&vm_repo),
        tenant_repo,
        Arc::clone(&migration_svc),
        mock_http,
        SchedulerConfig {
            scrape_interval_secs: 60,
            overload_threshold: 0.85,
            overload_duration_secs: 0,
            ..SchedulerConfig::default()
        },
    );

    svc.run_cycle().await.unwrap();
    assert_eq!(migration_svc.requests.lock().unwrap().len(), 1);

    svc.run_cycle().await.unwrap();
    assert_eq!(
        migration_svc.requests.lock().unwrap().len(),
        2,
        "in-flight migration should not suppress the same index across separate run cycles"
    );
}

#[tokio::test]
async fn in_flight_dedup_is_per_cycle_only() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let migration_svc = Arc::new(MockSchedulerMigrationService::default());
    let mock_http = Arc::new(MockSchedulerHttpClient::default());

    let overloaded_vm = vm_repo
        .create(new_vm_small(
            "http://vm-overloaded.local",
            "vm-overloaded.flapjack.foo",
        ))
        .await
        .unwrap();
    vm_repo
        .create(new_vm_small("http://vm-dest.local", "vm-dest.flapjack.foo"))
        .await
        .unwrap();
    register_heavy_and_light_indexes(&tenant_repo, overloaded_vm.id).await;

    // Cycle 1-3: overloaded repeatedly.
    push_overloaded_cycle(
        &mock_http,
        "http://vm-overloaded.local",
        "http://vm-dest.local",
    );
    push_overloaded_cycle(
        &mock_http,
        "http://vm-overloaded.local",
        "http://vm-dest.local",
    );
    push_overloaded_cycle(
        &mock_http,
        "http://vm-overloaded.local",
        "http://vm-dest.local",
    );

    let svc = scheduler_with_deps(
        Arc::clone(&vm_repo),
        tenant_repo,
        Arc::clone(&migration_svc),
        mock_http,
        SchedulerConfig {
            scrape_interval_secs: 60,
            overload_threshold: 0.85,
            overload_duration_secs: 0,
            ..SchedulerConfig::default()
        },
    );

    svc.run_cycle().await.unwrap();
    assert_eq!(migration_svc.requests.lock().unwrap().len(), 1);

    // in_flight_migrations is cleared between cycles, so each cycle may re-trigger
    svc.run_cycle().await.unwrap();
    assert_eq!(migration_svc.requests.lock().unwrap().len(), 2);

    svc.run_cycle().await.unwrap();
    assert_eq!(
        migration_svc.requests.lock().unwrap().len(),
        3,
        "each overloaded cycle independently triggers migration (per-cycle dedup only)"
    );
}

/// VM underloaded for threshold duration → all indexes migrated off, VM set to draining.
///
/// Setup: one VM with very low load (all dims < 20%).
/// One index on it, and another VM available.
/// Duration threshold = 0 (trigger immediately).
/// Expect: migration requested for the index, VM set to draining.
#[tokio::test]
async fn underload_triggers_drain() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let migration_svc = Arc::new(MockSchedulerMigrationService::default());
    let mock_http = Arc::new(MockSchedulerHttpClient::default());

    let underloaded_vm = vm_repo
        .create(new_vm(
            "http://vm-underloaded.local",
            "vm-underloaded.flapjack.foo",
        ))
        .await
        .unwrap();

    let dest_vm = vm_repo
        .create(new_vm("http://vm-dest.local", "vm-dest.flapjack.foo"))
        .await
        .unwrap();

    // Underloaded VM: very low load (10 of 1000 disk = 1%)
    mock_http.push_ok(
        "http://vm-underloaded.local/metrics",
        "flapjack_documents_count{index=\"lonely\"} 1\nflapjack_memory_heap_bytes 10\n",
    );
    mock_http.push_ok(
        "http://vm-underloaded.local/internal/storage",
        r#"{"tenants":[{"id":"lonely","bytes":10}]}"#,
    );

    // Destination VM: moderate load
    mock_http.push_ok(
        "http://vm-dest.local/metrics",
        "flapjack_documents_count{index=\"existing\"} 1\nflapjack_memory_heap_bytes 200\n",
    );
    mock_http.push_ok(
        "http://vm-dest.local/internal/storage",
        r#"{"tenants":[{"id":"existing","bytes":200}]}"#,
    );

    // Register tenant on underloaded VM
    let customer_id = uuid::Uuid::new_v4();
    let deploy_id = uuid::Uuid::new_v4();
    tenant_repo
        .create(customer_id, "lonely", deploy_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "lonely", underloaded_vm.id)
        .await
        .unwrap();

    let config = SchedulerConfig {
        scrape_interval_secs: 60,
        underload_threshold: 0.20,
        underload_duration_secs: 0, // trigger immediately
        ..SchedulerConfig::default()
    };

    let svc = scheduler_with_deps(
        Arc::clone(&vm_repo),
        tenant_repo,
        Arc::clone(&migration_svc),
        mock_http,
        config,
    );

    svc.run_cycle().await.unwrap();

    // Verify migration was requested for the index
    let requests = migration_svc.requests.lock().unwrap();
    assert_eq!(
        requests.len(),
        1,
        "should have triggered migration for the lonely index"
    );
    assert_eq!(requests[0].index_name, "lonely");
    assert_eq!(requests[0].source_vm_id, underloaded_vm.id);
    assert_eq!(requests[0].dest_vm_id, dest_vm.id);
    assert_eq!(requests[0].reason, "drain");

    // Verify VM was set to draining
    let vm = vm_repo.get(underloaded_vm.id).await.unwrap().unwrap();
    assert_eq!(
        vm.status, "draining",
        "underloaded VM should be set to draining"
    );
}

/// Underload drain failure preserves the timer for immediate retry.
///
/// Setup: one underloaded VM with one index, migration service set to fail.
/// Cycle 1: underloaded, timer starts (duration not met).
/// Sleep > duration. Cycle 2: drain attempted → migration fails → timer preserved.
/// Cycle 3: timer still active → immediate retry (no re-wait).
#[tokio::test]
async fn underload_drain_failure_preserves_timer() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let migration_svc = Arc::new(FailableMockSchedulerMigrationService::default());
    let mock_http = Arc::new(MockSchedulerHttpClient::default());

    // Underloaded VM: realistic capacity so tiny metrics → ~0% utilization → underloaded
    let underloaded_vm = vm_repo
        .create(new_vm(
            "http://vm-underloaded.local",
            "vm-underloaded.flapjack.foo",
        ))
        .await
        .unwrap();

    // Dest VM: small capacity so moderate metrics → ≥20% utilization → NOT underloaded
    vm_repo
        .create(new_vm_small("http://vm-dest.local", "vm-dest.flapjack.foo"))
        .await
        .unwrap();

    // 3 cycles of metrics: underloaded VM at ~0%, dest VM at ≥20% disk (500/1000)
    for _ in 0..3 {
        mock_http.push_ok(
            "http://vm-underloaded.local/metrics",
            "flapjack_documents_count{index=\"lonely\"} 1\nflapjack_memory_heap_bytes 10\n",
        );
        mock_http.push_ok(
            "http://vm-underloaded.local/internal/storage",
            r#"{"tenants":[{"id":"lonely","bytes":10}]}"#,
        );
        mock_http.push_ok(
            "http://vm-dest.local/metrics",
            "flapjack_documents_count{index=\"existing\"} 1\nflapjack_memory_heap_bytes 500\n",
        );
        mock_http.push_ok(
            "http://vm-dest.local/internal/storage",
            r#"{"tenants":[{"id":"existing","bytes":500}]}"#,
        );
    }

    let customer_id = uuid::Uuid::new_v4();
    let deploy_id = uuid::Uuid::new_v4();
    tenant_repo
        .create(customer_id, "lonely", deploy_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "lonely", underloaded_vm.id)
        .await
        .unwrap();

    migration_svc.set_should_fail(true);

    let svc = scheduler_with_deps(
        Arc::clone(&vm_repo),
        tenant_repo,
        Arc::clone(&migration_svc),
        mock_http,
        SchedulerConfig {
            scrape_interval_secs: 60,
            underload_threshold: 0.20,
            underload_duration_secs: 1,
            ..SchedulerConfig::default()
        },
    );

    // Cycle 1: underloaded but duration not met yet
    svc.run_cycle().await.unwrap();
    assert_eq!(migration_svc.request_count(), 0);

    // Sleep past the duration threshold
    tokio::time::sleep(Duration::from_millis(1100)).await;

    // Cycle 2: duration met → drain attempted → migration fails
    svc.run_cycle().await.unwrap();
    assert_eq!(migration_svc.request_count(), 1);

    // Cycle 3: timer should be preserved → immediate retry without re-waiting
    svc.run_cycle().await.unwrap();
    assert_eq!(
        migration_svc.request_count(),
        2,
        "failed underload drain should not reset timer — retry immediately"
    );

    // Verify VM was NOT set to draining (migration failed)
    let vm = vm_repo.get(underloaded_vm.id).await.unwrap().unwrap();
    assert_eq!(
        vm.status, "active",
        "VM should remain active when drain fails"
    );
}

#[tokio::test]
async fn overload_does_not_migrate_to_vm_with_failed_scrape() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let migration_svc = Arc::new(MockSchedulerMigrationService::default());
    let mock_http = Arc::new(MockSchedulerHttpClient::default());

    let overloaded_vm = vm_repo
        .create(new_vm(
            "http://vm-overloaded.local",
            "vm-overloaded.flapjack.foo",
        ))
        .await
        .unwrap();

    vm_repo
        .create(new_vm("http://vm-failed.local", "vm-failed.flapjack.foo"))
        .await
        .unwrap();

    mock_http.push_ok(
        "http://vm-overloaded.local/metrics",
        r#"
flapjack_documents_count{index="heavy"} 9
flapjack_documents_count{index="light"} 1
flapjack_memory_heap_bytes 100
"#,
    );
    mock_http.push_ok(
        "http://vm-overloaded.local/internal/storage",
        r#"{"tenants":[{"id":"heavy","bytes":800},{"id":"light","bytes":100}]}"#,
    );

    mock_http.push_err("http://vm-failed.local/metrics", "connect failed");

    let customer_id = uuid::Uuid::new_v4();
    let deploy_id = uuid::Uuid::new_v4();
    tenant_repo
        .create(customer_id, "heavy", deploy_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "heavy", overloaded_vm.id)
        .await
        .unwrap();
    tenant_repo
        .create(customer_id, "light", deploy_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "light", overloaded_vm.id)
        .await
        .unwrap();

    let config = SchedulerConfig {
        scrape_interval_secs: 60,
        overload_threshold: 0.85,
        overload_duration_secs: 0,
        ..SchedulerConfig::default()
    };

    let svc = scheduler_with_deps(
        Arc::clone(&vm_repo),
        tenant_repo,
        Arc::clone(&migration_svc),
        mock_http,
        config,
    );

    svc.run_cycle().await.unwrap();

    let requests = migration_svc.requests.lock().unwrap();
    assert_eq!(
        requests.len(),
        0,
        "must not migrate to destination VMs that failed scraping"
    );
}

#[tokio::test]
async fn underload_drain_updates_intermediate_capacity_between_indexes() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let migration_svc = Arc::new(MockSchedulerMigrationService::default());
    let mock_http = Arc::new(MockSchedulerHttpClient::default());

    let underloaded_vm = vm_repo
        .create(new_vm(
            "http://vm-underloaded.local",
            "vm-underloaded.flapjack.foo",
        ))
        .await
        .unwrap();

    let small_capacity_dest = vm_repo
        .create(NewVmInventory {
            region: "us-east-1".to_string(),
            provider: "aws".to_string(),
            hostname: "vm-small-dest.flapjack.foo".to_string(),
            flapjack_url: "http://vm-small-dest.local".to_string(),
            capacity: serde_json::json!({
                "cpu_weight": 4.0,
                "mem_rss_bytes": 1_000_u64,
                "disk_bytes": 150_u64,
                "query_rps": 100.0,
                "indexing_rps": 100.0,
            }),
        })
        .await
        .unwrap();

    mock_http.push_ok(
        "http://vm-underloaded.local/metrics",
        r#"
flapjack_documents_count{index="a"} 1
flapjack_documents_count{index="b"} 1
flapjack_memory_heap_bytes 20
"#,
    );
    mock_http.push_ok(
        "http://vm-underloaded.local/internal/storage",
        r#"{"tenants":[{"id":"a","bytes":90},{"id":"b","bytes":80}]}"#,
    );

    mock_http.push_ok(
        "http://vm-small-dest.local/metrics",
        "flapjack_memory_heap_bytes 10\n",
    );
    mock_http.push_ok(
        "http://vm-small-dest.local/internal/storage",
        r#"{"tenants":[]}"#,
    );

    let customer_id = uuid::Uuid::new_v4();
    let deploy_id = uuid::Uuid::new_v4();
    tenant_repo
        .create(customer_id, "a", deploy_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "a", underloaded_vm.id)
        .await
        .unwrap();
    tenant_repo
        .create(customer_id, "b", deploy_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "b", underloaded_vm.id)
        .await
        .unwrap();

    let config = SchedulerConfig {
        scrape_interval_secs: 60,
        underload_threshold: 0.20,
        underload_duration_secs: 0,
        ..SchedulerConfig::default()
    };

    let svc = scheduler_with_deps(
        Arc::clone(&vm_repo),
        tenant_repo,
        Arc::clone(&migration_svc),
        mock_http,
        config,
    );

    svc.run_cycle().await.unwrap();

    let requests = migration_svc.requests.lock().unwrap();
    assert_eq!(
        requests.len(),
        1,
        "drain planning must update destination load after each placement"
    );
    assert_eq!(requests[0].dest_vm_id, small_capacity_dest.id);

    let vm = vm_repo.get(underloaded_vm.id).await.unwrap().unwrap();
    assert_eq!(
        vm.status, "active",
        "source VM should not switch to draining when all indexes were not placeable"
    );
}

#[tokio::test]
async fn unplaced_index_gets_assigned_to_active_vm() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let migration_svc = Arc::new(MockSchedulerMigrationService::default());
    let mock_http = Arc::new(MockSchedulerHttpClient::default());

    let vm = vm_repo
        .create(new_vm("http://vm-assign.local", "vm-assign.flapjack.foo"))
        .await
        .unwrap();

    mock_http.push_ok(
        "http://vm-assign.local/metrics",
        "flapjack_memory_heap_bytes 50\n",
    );
    mock_http.push_ok(
        "http://vm-assign.local/internal/storage",
        r#"{"tenants":[]}"#,
    );

    let customer_id = uuid::Uuid::new_v4();
    let deploy_id = uuid::Uuid::new_v4();
    tenant_repo.seed_deployment(
        deploy_id,
        "us-east-1",
        Some("https://legacy.flapjack.foo"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer_id, "new-index", deploy_id)
        .await
        .unwrap();

    let svc = scheduler_with_deps(
        Arc::clone(&vm_repo),
        Arc::clone(&tenant_repo),
        Arc::clone(&migration_svc),
        mock_http,
        SchedulerConfig {
            scrape_interval_secs: 60,
            ..SchedulerConfig::default()
        },
    );

    svc.run_cycle().await.unwrap();

    let raw = tenant_repo
        .find_raw(customer_id, "new-index")
        .await
        .unwrap()
        .expect("tenant should exist");
    assert_eq!(raw.vm_id, Some(vm.id), "unplaced index should be assigned");
}

#[tokio::test]
async fn unplaced_index_assignment_is_region_aware() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let migration_svc = Arc::new(MockSchedulerMigrationService::default());
    let mock_http = Arc::new(MockSchedulerHttpClient::default());

    let eu_vm = vm_repo
        .create(NewVmInventory {
            region: "eu-west-1".to_string(),
            provider: "aws".to_string(),
            hostname: "vm-eu.flapjack.foo".to_string(),
            flapjack_url: "http://vm-eu.local".to_string(),
            capacity: serde_json::json!({
                "cpu_weight": 4.0,
                "mem_rss_bytes": 1_000_u64,
                "disk_bytes": 1_000_u64,
                "query_rps": 100.0,
                "indexing_rps": 100.0,
            }),
        })
        .await
        .unwrap();
    let us_vm = vm_repo
        .create(NewVmInventory {
            region: "us-east-1".to_string(),
            provider: "aws".to_string(),
            hostname: "vm-us.flapjack.foo".to_string(),
            flapjack_url: "http://vm-us.local".to_string(),
            capacity: serde_json::json!({
                "cpu_weight": 4.0,
                "mem_rss_bytes": 1_000_u64,
                "disk_bytes": 1_000_u64,
                "query_rps": 100.0,
                "indexing_rps": 100.0,
            }),
        })
        .await
        .unwrap();

    mock_http.push_ok(
        "http://vm-eu.local/metrics",
        "flapjack_memory_heap_bytes 50\n",
    );
    mock_http.push_ok("http://vm-eu.local/internal/storage", r#"{"tenants":[]}"#);
    mock_http.push_ok(
        "http://vm-us.local/metrics",
        "flapjack_memory_heap_bytes 50\n",
    );
    mock_http.push_ok("http://vm-us.local/internal/storage", r#"{"tenants":[]}"#);

    let customer_id = uuid::Uuid::new_v4();
    let deploy_id = uuid::Uuid::new_v4();
    tenant_repo.seed_deployment(
        deploy_id,
        "us-east-1",
        Some("https://legacy.flapjack.foo"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer_id, "regional-index", deploy_id)
        .await
        .unwrap();

    let svc = scheduler_with_deps(
        Arc::clone(&vm_repo),
        Arc::clone(&tenant_repo),
        Arc::clone(&migration_svc),
        mock_http,
        SchedulerConfig {
            scrape_interval_secs: 60,
            ..SchedulerConfig::default()
        },
    );

    svc.run_cycle().await.unwrap();

    let raw = tenant_repo
        .find_raw(customer_id, "regional-index")
        .await
        .unwrap()
        .expect("tenant should exist");
    assert_eq!(
        raw.vm_id,
        Some(us_vm.id),
        "unplaced index should only be assigned within deployment region"
    );
    assert_ne!(raw.vm_id, Some(eu_vm.id));
}

/// Index exceeds its quota for the configured warning duration → Warning alert fires.
///
/// Setup: one VM, one index with max_query_rps=50 quota. Scraped metrics show query_rps=80.
/// noisy_neighbor_warning_secs=0 (trigger immediately on first detection).
/// Expect: Warning alert with index name, customer_id, resource dimension, actual vs quota.
#[tokio::test]
async fn noisy_neighbor_warning_alert_after_sustained_quota_overage() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let migration_svc = Arc::new(MockSchedulerMigrationService::default());
    let alert_svc = Arc::new(MockAlertService::new());
    let mock_http = Arc::new(MockSchedulerHttpClient::default());

    let vm = vm_repo
        .create(new_vm("http://vm-noisy.local", "vm-noisy.flapjack.foo"))
        .await
        .unwrap();

    // Two scrapes needed for RPS delta calculation
    // First scrape: baseline counters
    mock_http.push_ok(
        "http://vm-noisy.local/metrics",
        "flapjack_search_requests_total{index=\"products\"} 0\nflapjack_documents_indexed_total{index=\"products\"} 0\nflapjack_memory_heap_bytes 100\n",
    );
    mock_http.push_ok(
        "http://vm-noisy.local/internal/storage",
        r#"{"tenants":[{"id":"products","bytes":100}]}"#,
    );
    // Second scrape: counters advanced (80 search requests in 60s = 80/60 ≈ 1.33 rps, but we need to exceed quota)
    // Actually, with scrape_interval_secs=60, delta/interval = rps.
    // To get query_rps=80, we need delta=4800 (80*60) in 60s interval.
    mock_http.push_ok(
        "http://vm-noisy.local/metrics",
        "flapjack_search_requests_total{index=\"products\"} 4800\nflapjack_documents_indexed_total{index=\"products\"} 0\nflapjack_memory_heap_bytes 100\n",
    );
    mock_http.push_ok(
        "http://vm-noisy.local/internal/storage",
        r#"{"tenants":[{"id":"products","bytes":100}]}"#,
    );

    let customer_id = uuid::Uuid::new_v4();
    let deploy_id = uuid::Uuid::new_v4();
    tenant_repo.seed_deployment(
        deploy_id,
        "us-east-1",
        Some("https://legacy.flapjack.foo"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer_id, "products", deploy_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "products", vm.id)
        .await
        .unwrap();
    // Set a quota of max_query_rps=50 — the scraped 80 rps will exceed it
    tenant_repo
        .set_resource_quota(
            customer_id,
            "products",
            serde_json::json!({"max_query_rps": 50}),
        )
        .await
        .unwrap();

    let svc = scheduler_with_alerts(
        vm_repo,
        tenant_repo,
        migration_svc,
        Arc::clone(&alert_svc),
        mock_http,
        SchedulerConfig {
            scrape_interval_secs: 60,
            noisy_neighbor_warning_secs: 0, // trigger immediately
            noisy_neighbor_migration_secs: 1800,
            ..SchedulerConfig::default()
        },
    );

    // First cycle: baseline counters (no RPS yet)
    svc.run_cycle().await.unwrap();
    // Second cycle: RPS computed from delta → quota exceeded → Warning alert
    svc.run_cycle().await.unwrap();

    let alerts = alert_svc.get_recent_alerts(100).await.unwrap();
    let warnings: Vec<_> = alerts
        .iter()
        .filter(|a| a.severity == api::services::alerting::AlertSeverity::Warning)
        .filter(|a| {
            a.title.contains("noisy") || a.title.contains("Noisy") || a.title.contains("quota")
        })
        .collect();

    assert!(
        !warnings.is_empty(),
        "expected Warning alert for noisy-neighbor quota overage; got alerts: {alerts:?}"
    );

    let alert = &warnings[0];
    let meta = &alert.metadata;
    assert!(
        alert.message.contains("products"),
        "alert should mention index name"
    );
    assert!(
        meta.get("index_name")
            .and_then(|v: &serde_json::Value| v.as_str())
            == Some("products")
            || alert.message.contains("products"),
        "alert metadata or message should contain index_name"
    );
}

#[tokio::test]
async fn noisy_neighbor_uses_default_quotas_when_override_missing() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let migration_svc = Arc::new(MockSchedulerMigrationService::default());
    let alert_svc = Arc::new(MockAlertService::new());
    let mock_http = Arc::new(MockSchedulerHttpClient::default());

    let vm = vm_repo
        .create(new_vm(
            "http://vm-default-quota.local",
            "vm-default-quota.flapjack.foo",
        ))
        .await
        .unwrap();

    // Baseline scrape for counter deltas.
    mock_http.push_ok(
        "http://vm-default-quota.local/metrics",
        "flapjack_search_requests_total{index=\"products\"} 0\nflapjack_documents_indexed_total{index=\"products\"} 0\nflapjack_memory_heap_bytes 100\n",
    );
    mock_http.push_ok(
        "http://vm-default-quota.local/internal/storage",
        r#"{"tenants":[{"id":"products","bytes":100}]}"#,
    );

    // 7200 requests in 60s = 120 rps. This should exceed the default 100 query-rps quota.
    mock_http.push_ok(
        "http://vm-default-quota.local/metrics",
        "flapjack_search_requests_total{index=\"products\"} 7200\nflapjack_documents_indexed_total{index=\"products\"} 0\nflapjack_memory_heap_bytes 100\n",
    );
    mock_http.push_ok(
        "http://vm-default-quota.local/internal/storage",
        r#"{"tenants":[{"id":"products","bytes":100}]}"#,
    );

    let customer_id = uuid::Uuid::new_v4();
    let deploy_id = uuid::Uuid::new_v4();
    tenant_repo.seed_deployment(
        deploy_id,
        "us-east-1",
        Some("https://legacy.flapjack.foo"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer_id, "products", deploy_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "products", vm.id)
        .await
        .unwrap();

    let svc = scheduler_with_alerts(
        vm_repo,
        tenant_repo,
        migration_svc,
        Arc::clone(&alert_svc),
        mock_http,
        SchedulerConfig {
            scrape_interval_secs: 60,
            noisy_neighbor_warning_secs: 0,
            noisy_neighbor_migration_secs: 1800,
            ..SchedulerConfig::default()
        },
    );

    svc.run_cycle().await.unwrap();
    svc.run_cycle().await.unwrap();

    let alerts = alert_svc.get_recent_alerts(100).await.unwrap();
    let warning = alerts
        .iter()
        .find(|a| a.severity == api::services::alerting::AlertSeverity::Warning)
        .expect("expected warning alert when default quota is exceeded");

    assert!(warning.title.contains("products"));
}

/// Index exceeds quota for the migration threshold duration → migration triggered.
///
/// Setup: two VMs, one index exceeding quota on vm1. noisy_neighbor_migration_secs=0.
/// Expect: migration requested for the offending index.
#[tokio::test]
async fn noisy_neighbor_migration_after_prolonged_quota_overage() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let migration_svc = Arc::new(MockSchedulerMigrationService::default());
    let alert_svc = Arc::new(MockAlertService::new());
    let mock_http = Arc::new(MockSchedulerHttpClient::default());

    let vm1 = vm_repo
        .create(new_vm("http://vm-source.local", "vm-source.flapjack.foo"))
        .await
        .unwrap();
    let _vm2 = vm_repo
        .create(new_vm("http://vm-dest2.local", "vm-dest2.flapjack.foo"))
        .await
        .unwrap();

    // Scrape 1: baseline
    mock_http.push_ok(
        "http://vm-source.local/metrics",
        "flapjack_search_requests_total{index=\"loud\"} 0\nflapjack_documents_indexed_total{index=\"loud\"} 0\nflapjack_memory_heap_bytes 100\n",
    );
    mock_http.push_ok(
        "http://vm-source.local/internal/storage",
        r#"{"tenants":[{"id":"loud","bytes":100}]}"#,
    );
    mock_http.push_ok(
        "http://vm-dest2.local/metrics",
        "flapjack_memory_heap_bytes 50\n",
    );
    mock_http.push_ok(
        "http://vm-dest2.local/internal/storage",
        r#"{"tenants":[]}"#,
    );

    // Scrape 2: high query rate (exceeds quota)
    mock_http.push_ok(
        "http://vm-source.local/metrics",
        "flapjack_search_requests_total{index=\"loud\"} 6000\nflapjack_documents_indexed_total{index=\"loud\"} 0\nflapjack_memory_heap_bytes 100\n",
    );
    mock_http.push_ok(
        "http://vm-source.local/internal/storage",
        r#"{"tenants":[{"id":"loud","bytes":100}]}"#,
    );
    mock_http.push_ok(
        "http://vm-dest2.local/metrics",
        "flapjack_memory_heap_bytes 50\n",
    );
    mock_http.push_ok(
        "http://vm-dest2.local/internal/storage",
        r#"{"tenants":[]}"#,
    );

    let customer_id = uuid::Uuid::new_v4();
    let deploy_id = uuid::Uuid::new_v4();
    tenant_repo.seed_deployment(
        deploy_id,
        "us-east-1",
        Some("https://legacy.flapjack.foo"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer_id, "loud", deploy_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "loud", vm1.id)
        .await
        .unwrap();
    tenant_repo
        .set_resource_quota(
            customer_id,
            "loud",
            serde_json::json!({"max_query_rps": 50}),
        )
        .await
        .unwrap();

    let svc = scheduler_with_alerts(
        vm_repo,
        tenant_repo,
        Arc::clone(&migration_svc),
        alert_svc,
        mock_http,
        SchedulerConfig {
            scrape_interval_secs: 60,
            noisy_neighbor_warning_secs: 0,
            noisy_neighbor_migration_secs: 0, // trigger immediately
            ..SchedulerConfig::default()
        },
    );

    // Cycle 1: baseline counters
    svc.run_cycle().await.unwrap();
    // Cycle 2: RPS exceeds quota → detection + migration
    svc.run_cycle().await.unwrap();

    let requests = migration_svc.requests.lock().unwrap();
    let noisy_migrations: Vec<_> = requests
        .iter()
        .filter(|r| r.index_name == "loud" && r.reason == "noisy_neighbor")
        .collect();

    assert!(
        !noisy_migrations.is_empty(),
        "expected migration request for noisy-neighbor index; got: {requests:?}"
    );
    assert_eq!(noisy_migrations[0].source_vm_id, vm1.id);
}

#[tokio::test]
async fn noisy_neighbor_no_capacity_fires_admin_attention_alert() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let migration_svc = Arc::new(MockSchedulerMigrationService::default());
    let alert_svc = Arc::new(MockAlertService::new());
    let mock_http = Arc::new(MockSchedulerHttpClient::default());

    let vm1 = vm_repo
        .create(new_vm("http://vm-source.local", "vm-source.flapjack.foo"))
        .await
        .unwrap();

    // Scrape 1: baseline
    mock_http.push_ok(
        "http://vm-source.local/metrics",
        "flapjack_search_requests_total{index=\"loud\"} 0\nflapjack_documents_indexed_total{index=\"loud\"} 0\nflapjack_memory_heap_bytes 100\n",
    );
    mock_http.push_ok(
        "http://vm-source.local/internal/storage",
        r#"{"tenants":[{"id":"loud","bytes":100}]}"#,
    );

    // Scrape 2: high query rate (exceeds quota)
    mock_http.push_ok(
        "http://vm-source.local/metrics",
        "flapjack_search_requests_total{index=\"loud\"} 6000\nflapjack_documents_indexed_total{index=\"loud\"} 0\nflapjack_memory_heap_bytes 100\n",
    );
    mock_http.push_ok(
        "http://vm-source.local/internal/storage",
        r#"{"tenants":[{"id":"loud","bytes":100}]}"#,
    );

    let customer_id = uuid::Uuid::new_v4();
    let deploy_id = uuid::Uuid::new_v4();
    tenant_repo.seed_deployment(
        deploy_id,
        "us-east-1",
        Some("https://legacy.flapjack.foo"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer_id, "loud", deploy_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "loud", vm1.id)
        .await
        .unwrap();
    tenant_repo
        .set_resource_quota(
            customer_id,
            "loud",
            serde_json::json!({"max_query_rps": 50}),
        )
        .await
        .unwrap();

    let svc = scheduler_with_alerts(
        vm_repo,
        tenant_repo,
        Arc::clone(&migration_svc),
        Arc::clone(&alert_svc),
        mock_http,
        SchedulerConfig {
            scrape_interval_secs: 60,
            noisy_neighbor_warning_secs: 3600, // avoid generic warning branch
            noisy_neighbor_migration_secs: 0,  // trigger migration branch immediately
            ..SchedulerConfig::default()
        },
    );

    // Cycle 1: baseline counters
    svc.run_cycle().await.unwrap();
    // Cycle 2: RPS exceeds quota; migration has no destination VM
    svc.run_cycle().await.unwrap();

    let requests = migration_svc.requests.lock().unwrap();
    assert!(
        requests.is_empty(),
        "expected no migration requests when no destination capacity exists"
    );

    let alerts = alert_svc.get_recent_alerts(100).await.unwrap();
    let no_capacity_warning = alerts.iter().find(|a| {
        a.severity == api::services::alerting::AlertSeverity::Warning
            && a.message.contains("no same-provider destination capacity")
    });

    assert!(
        no_capacity_warning.is_some(),
        "expected warning alert for noisy-neighbor migration with no capacity; got: {alerts:?}"
    );
}

// ---------------------------------------------------------------------------
// Scheduler Integration with load_scraped_at
// ---------------------------------------------------------------------------

/// After run_cycle() a successfully scraped VM must have load_scraped_at set
/// to a timestamp within 5 seconds of when the cycle ran.
#[tokio::test]
async fn run_cycle_sets_load_scraped_at_on_success() {
    let vm_repo = common::mock_vm_inventory_repo();
    let mock_http = Arc::new(MockSchedulerHttpClient::default());

    mock_http.push_ok(
        "http://vm-scraped-at.local/metrics",
        "flapjack_documents_count{index=\"products\"} 1\nflapjack_memory_heap_bytes 100\n",
    );
    mock_http.push_ok(
        "http://vm-scraped-at.local/internal/storage",
        r#"{"tenants":[{"id":"products","bytes":10}]}"#,
    );

    let vm = vm_repo
        .create(new_vm(
            "http://vm-scraped-at.local",
            "vm-scraped-at.flapjack.foo",
        ))
        .await
        .unwrap();

    // Newly created VM has no scraped_at.
    assert!(vm.load_scraped_at.is_none());

    let before = Utc::now();
    let svc = scheduler_service(Arc::clone(&vm_repo), 60, mock_http);
    svc.run_cycle().await.unwrap();
    let after = Utc::now();

    let updated = vm_repo.get(vm.id).await.unwrap().unwrap();
    let scraped_at = updated
        .load_scraped_at
        .expect("load_scraped_at must be set after a successful scrape");

    assert!(
        scraped_at >= before && scraped_at <= after,
        "load_scraped_at ({scraped_at}) must fall within the run_cycle window [{before}, {after}]"
    );
}

/// A VM whose scrape fails must NOT have load_scraped_at updated — it should
/// stay at its previous value (or NULL if never scraped).
#[tokio::test]
async fn run_cycle_does_not_update_load_scraped_at_on_scrape_failure() {
    let vm_repo = common::mock_vm_inventory_repo();
    let mock_http = Arc::new(MockSchedulerHttpClient::default());

    // Return a network error for the metrics endpoint so the scrape fails.
    mock_http.push_err("http://vm-fail-scrape.local/metrics", "connection refused");

    let vm = vm_repo
        .create(new_vm(
            "http://vm-fail-scrape.local",
            "vm-fail-scrape.flapjack.foo",
        ))
        .await
        .unwrap();

    assert!(
        vm.load_scraped_at.is_none(),
        "newly created VM has no scraped_at"
    );

    let svc = scheduler_service(Arc::clone(&vm_repo), 60, mock_http);
    svc.run_cycle().await.unwrap(); // cycle runs but skips the failing VM

    let unchanged = vm_repo.get(vm.id).await.unwrap().unwrap();
    assert!(
        unchanged.load_scraped_at.is_none(),
        "load_scraped_at must remain NULL when scrape fails; got: {:?}",
        unchanged.load_scraped_at
    );
}

// ---------------------------------------------------------------------------
// Reliability: no-capacity warning sent flag prevents duplicate alerts
// ---------------------------------------------------------------------------

/// The no_capacity_warning_sent flag in noisy_neighbor_first_seen should
/// prevent duplicate no-capacity alerts across repeated cycles. After the
/// first no-capacity warning fires, subsequent cycles with the same violation
/// must NOT fire additional no-capacity warnings.
#[tokio::test]
async fn noisy_neighbor_no_capacity_flag_prevents_duplicate_alerts() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let migration_svc = Arc::new(MockSchedulerMigrationService::default());
    let alert_svc = Arc::new(MockAlertService::new());
    let mock_http = Arc::new(MockSchedulerHttpClient::default());

    let vm1 = vm_repo
        .create(new_vm("http://vm-source.local", "vm-source.flapjack.foo"))
        .await
        .unwrap();

    // Scrape 1: baseline
    mock_http.push_ok(
        "http://vm-source.local/metrics",
        "flapjack_search_requests_total{index=\"loud\"} 0\nflapjack_documents_indexed_total{index=\"loud\"} 0\nflapjack_memory_heap_bytes 100\n",
    );
    mock_http.push_ok(
        "http://vm-source.local/internal/storage",
        r#"{"tenants":[{"id":"loud","bytes":100}]}"#,
    );

    // Scrape 2: high query rate (exceeds quota) → first no-capacity warning
    mock_http.push_ok(
        "http://vm-source.local/metrics",
        "flapjack_search_requests_total{index=\"loud\"} 6000\nflapjack_documents_indexed_total{index=\"loud\"} 0\nflapjack_memory_heap_bytes 100\n",
    );
    mock_http.push_ok(
        "http://vm-source.local/internal/storage",
        r#"{"tenants":[{"id":"loud","bytes":100}]}"#,
    );

    // Scrape 3: still high → should NOT produce a second no-capacity warning
    mock_http.push_ok(
        "http://vm-source.local/metrics",
        "flapjack_search_requests_total{index=\"loud\"} 12000\nflapjack_documents_indexed_total{index=\"loud\"} 0\nflapjack_memory_heap_bytes 100\n",
    );
    mock_http.push_ok(
        "http://vm-source.local/internal/storage",
        r#"{"tenants":[{"id":"loud","bytes":100}]}"#,
    );

    let customer_id = uuid::Uuid::new_v4();
    let deploy_id = uuid::Uuid::new_v4();
    tenant_repo.seed_deployment(
        deploy_id,
        "us-east-1",
        Some("https://legacy.flapjack.foo"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer_id, "loud", deploy_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "loud", vm1.id)
        .await
        .unwrap();
    tenant_repo
        .set_resource_quota(
            customer_id,
            "loud",
            serde_json::json!({"max_query_rps": 50}),
        )
        .await
        .unwrap();

    let svc = scheduler_with_alerts(
        vm_repo,
        tenant_repo,
        Arc::clone(&migration_svc),
        Arc::clone(&alert_svc),
        mock_http,
        SchedulerConfig {
            scrape_interval_secs: 60,
            noisy_neighbor_warning_secs: 3600, // avoid generic warning branch
            noisy_neighbor_migration_secs: 0,  // trigger migration branch immediately
            ..SchedulerConfig::default()
        },
    );

    // Cycle 1: baseline counters
    svc.run_cycle().await.unwrap();
    // Cycle 2: RPS exceeds quota; no destination → fires no-capacity warning
    svc.run_cycle().await.unwrap();

    let alerts_after_2 = alert_svc.get_recent_alerts(100).await.unwrap();
    let no_cap_count_2 = alerts_after_2
        .iter()
        .filter(|a| {
            a.severity == api::services::alerting::AlertSeverity::Warning
                && a.message.contains("no same-provider destination capacity")
        })
        .count();
    assert_eq!(
        no_cap_count_2, 1,
        "exactly 1 no-capacity warning after cycle 2"
    );

    // Cycle 3: still violating → flag should suppress duplicate warning
    svc.run_cycle().await.unwrap();

    let alerts_after_3 = alert_svc.get_recent_alerts(100).await.unwrap();
    let no_cap_count_3 = alerts_after_3
        .iter()
        .filter(|a| {
            a.severity == api::services::alerting::AlertSeverity::Warning
                && a.message.contains("no same-provider destination capacity")
        })
        .count();
    assert_eq!(
        no_cap_count_3, 1,
        "no-capacity warning count should remain 1 after cycle 3 (flag prevents duplicate)"
    );
}

/// Test that scheduler placement decisions are consistent whether using
/// profile artifacts or hardcoded constant values.
///
/// Validates that the profile-loading utilities produce equivalent capacity
/// data to the constants when artifacts exist.
#[tokio::test]
async fn placement_uses_profile_artifacts_consistently() {
    use common::capacity_profiles::{
        constant_profile_for_tier, load_profile_from_artifacts,
        profile_capacity_json_from_artifacts, resource_vector_to_json,
    };

    let tiers = ["1k", "10k", "100k"];

    for tier in tiers {
        let constant = constant_profile_for_tier(tier).expect("known tier");

        // If artifacts exist, verify they match constants
        if let Some(loaded) = load_profile_from_artifacts(tier) {
            assert_eq!(
                loaded.mem_rss_bytes, constant.mem_rss_bytes,
                "{tier} mem_rss_bytes should match constant"
            );
            assert_eq!(
                loaded.disk_bytes, constant.disk_bytes,
                "{tier} disk_bytes should match constant"
            );
            assert_eq!(
                loaded.cpu_weight, constant.cpu_weight,
                "{tier} cpu_weight should match constant"
            );
            assert_eq!(
                loaded.query_rps, constant.query_rps,
                "{tier} query_rps should match constant"
            );
            assert_eq!(
                loaded.indexing_rps, constant.indexing_rps,
                "{tier} indexing_rps should match constant"
            );
        }

        // JSON generation should be consistent (artifact or constant fallback)
        let json_from_artifacts = profile_capacity_json_from_artifacts(tier);
        let expected_json = resource_vector_to_json(&constant);
        assert_eq!(
            json_from_artifacts, expected_json,
            "{tier}: profile_capacity_json_from_artifacts should match constant-derived JSON"
        );
    }
}
