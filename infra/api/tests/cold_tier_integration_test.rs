use std::sync::Arc;
use std::sync::Mutex;

use api::models::vm_inventory::NewVmInventory;
use api::repos::ColdSnapshotRepo;
use api::repos::TenantRepo;
use api::repos::VmInventoryRepo;
use api::services::alerting::AlertService;
use api::services::alerting::MockAlertService;
use api::services::scheduler::{
    MigrationRequest, SchedulerConfig, SchedulerHttpClient, SchedulerHttpClientError,
    SchedulerMigrationService, SchedulerService,
};
use async_trait::async_trait;
use tower::ServiceExt;

mod common;

// ---------------------------------------------------------------------------
// Shared test helpers
// ---------------------------------------------------------------------------

fn new_vm(url: &str, hostname: &str) -> NewVmInventory {
    NewVmInventory {
        region: "us-east-1".to_string(),
        provider: "aws".to_string(),
        hostname: hostname.to_string(),
        flapjack_url: url.to_string(),
        capacity: serde_json::json!({
            "cpu_weight": 4.0,
            "mem_rss_bytes": 1_000_u64,
            "disk_bytes": 1_000_u64,
            "query_rps": 100.0,
            "indexing_rps": 100.0,
        }),
    }
}

#[derive(Default)]
struct MockSchedulerHttpClient {
    responses:
        Mutex<std::collections::HashMap<String, Vec<Result<String, SchedulerHttpClientError>>>>,
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
}

#[async_trait]
impl SchedulerHttpClient for MockSchedulerHttpClient {
    async fn get_text(
        &self,
        url: &str,
        _headers: std::collections::HashMap<String, String>,
    ) -> Result<String, SchedulerHttpClientError> {
        let mut map = self.responses.lock().unwrap();
        let queue = map.get_mut(url).ok_or_else(|| {
            SchedulerHttpClientError::Unreachable(format!("missing mocked response for {url}"))
        })?;
        if queue.is_empty() {
            return Err(SchedulerHttpClientError::Unreachable(format!(
                "missing mocked response for {url}"
            )));
        }
        queue.remove(0)
    }
}

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

fn build_scheduler(
    vm_repo: Arc<common::MockVmInventoryRepo>,
    tenant_repo: Arc<common::MockTenantRepo>,
    migration_svc: Arc<MockSchedulerMigrationService>,
    alert_svc: Arc<MockAlertService>,
    http_client: Arc<dyn SchedulerHttpClient>,
    config: SchedulerConfig,
) -> SchedulerService {
    SchedulerService::with_http_client(
        config,
        vm_repo,
        tenant_repo,
        migration_svc,
        alert_svc,
        common::mock_node_secret_manager(),
        http_client,
    )
}

// ---------------------------------------------------------------------------
// Test 1: scheduler_skips_cold_indexes_in_noisy_neighbor
//
// A cold index on a VM (edge case: vm_id not yet cleared) should NOT trigger
// noisy-neighbor quota violation alerts, because cold indexes have no live traffic.
// ---------------------------------------------------------------------------
#[tokio::test]
async fn scheduler_skips_cold_indexes_in_noisy_neighbor() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let migration_svc = Arc::new(MockSchedulerMigrationService::default());
    let alert_svc = Arc::new(MockAlertService::new());
    let mock_http = Arc::new(MockSchedulerHttpClient::default());

    let vm = vm_repo
        .create(new_vm("http://vm-cold-nn.local", "vm-cold-nn.flapjack.foo"))
        .await
        .unwrap();

    // Two scrapes for counter delta computation
    mock_http.push_ok(
        "http://vm-cold-nn.local/metrics",
        "flapjack_search_requests_total{index=\"cold-idx\"} 0\nflapjack_memory_heap_bytes 100\n",
    );
    mock_http.push_ok(
        "http://vm-cold-nn.local/internal/storage",
        r#"{"tenants":[{"id":"cold-idx","bytes":100}]}"#,
    );
    mock_http.push_ok(
        "http://vm-cold-nn.local/metrics",
        "flapjack_search_requests_total{index=\"cold-idx\"} 4800\nflapjack_memory_heap_bytes 100\n",
    );
    mock_http.push_ok(
        "http://vm-cold-nn.local/internal/storage",
        r#"{"tenants":[{"id":"cold-idx","bytes":100}]}"#,
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
        .create(customer_id, "cold-idx", deploy_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "cold-idx", vm.id)
        .await
        .unwrap();
    tenant_repo
        .set_resource_quota(
            customer_id,
            "cold-idx",
            serde_json::json!({"max_query_rps": 50}),
        )
        .await
        .unwrap();
    // Mark the index as cold
    tenant_repo
        .set_tier(customer_id, "cold-idx", "cold")
        .await
        .unwrap();

    let svc = build_scheduler(
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

    // Two cycles for delta
    svc.run_cycle().await.unwrap();
    svc.run_cycle().await.unwrap();

    let alerts = alert_svc.get_recent_alerts(100).await.unwrap();
    let noisy_warnings: Vec<_> = alerts
        .iter()
        .filter(|a| a.title.contains("oisy") || a.title.contains("quota"))
        .collect();

    assert!(
        noisy_warnings.is_empty(),
        "cold index should NOT trigger noisy-neighbor alert; got: {noisy_warnings:?}"
    );
}

// ---------------------------------------------------------------------------
// Test 2: scheduler_skips_cold_indexes_in_overload_calc
//
// A cold index on a VM should be excluded from the heaviest-index selection
// when the scheduler decides which index to migrate off an overloaded VM.
// If the only index is cold, no migration should be triggered.
// ---------------------------------------------------------------------------
#[tokio::test]
async fn scheduler_skips_cold_indexes_in_overload_calc() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let migration_svc = Arc::new(MockSchedulerMigrationService::default());
    let alert_svc = Arc::new(MockAlertService::new());
    let mock_http = Arc::new(MockSchedulerHttpClient::default());

    let overloaded_vm = vm_repo
        .create(new_vm(
            "http://vm-overload-cold.local",
            "vm-overload-cold.flapjack.foo",
        ))
        .await
        .unwrap();
    // Destination VM for potential migrations
    let _dest_vm = vm_repo
        .create(new_vm(
            "http://vm-dest-cold.local",
            "vm-dest-cold.flapjack.foo",
        ))
        .await
        .unwrap();

    // Overloaded VM: disk at 900/1000 = 90% (> 85% threshold)
    mock_http.push_ok(
        "http://vm-overload-cold.local/metrics",
        "flapjack_documents_count{index=\"cold-heavy\"} 1\nflapjack_memory_heap_bytes 100\n",
    );
    mock_http.push_ok(
        "http://vm-overload-cold.local/internal/storage",
        r#"{"tenants":[{"id":"cold-heavy","bytes":900}]}"#,
    );
    // Dest VM: idle
    mock_http.push_ok(
        "http://vm-dest-cold.local/metrics",
        "flapjack_memory_heap_bytes 10\n",
    );
    mock_http.push_ok(
        "http://vm-dest-cold.local/internal/storage",
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
        .create(customer_id, "cold-heavy", deploy_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "cold-heavy", overloaded_vm.id)
        .await
        .unwrap();
    // Mark the index as cold
    tenant_repo
        .set_tier(customer_id, "cold-heavy", "cold")
        .await
        .unwrap();

    let svc = build_scheduler(
        vm_repo,
        tenant_repo,
        Arc::clone(&migration_svc),
        alert_svc,
        mock_http,
        SchedulerConfig {
            scrape_interval_secs: 60,
            overload_duration_secs: 0, // trigger immediately
            ..SchedulerConfig::default()
        },
    );

    svc.run_cycle().await.unwrap();

    let migrations = migration_svc.requests.lock().unwrap();
    assert!(
        migrations.is_empty(),
        "cold index should NOT be selected for overload migration; got: {migrations:?}"
    );
}

// ---------------------------------------------------------------------------
// Test 3: scheduler_skips_restoring_indexes_in_unplaced
//
// An index with tier='restoring' and vm_id=NULL should NOT be auto-placed by
// the scheduler (the restore service handles placement).
// ---------------------------------------------------------------------------
#[tokio::test]
async fn scheduler_skips_restoring_indexes_in_unplaced() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let migration_svc = Arc::new(MockSchedulerMigrationService::default());
    let alert_svc = Arc::new(MockAlertService::new());
    let mock_http = Arc::new(MockSchedulerHttpClient::default());

    let _vm = vm_repo
        .create(new_vm(
            "http://vm-restore-skip.local",
            "vm-restore-skip.flapjack.foo",
        ))
        .await
        .unwrap();

    mock_http.push_ok(
        "http://vm-restore-skip.local/metrics",
        "flapjack_memory_heap_bytes 50\n",
    );
    mock_http.push_ok(
        "http://vm-restore-skip.local/internal/storage",
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
        .create(customer_id, "restoring-idx", deploy_id)
        .await
        .unwrap();
    // It's unplaced (vm_id=NULL) and tier='restoring' — scheduler should NOT auto-place it
    tenant_repo
        .set_tier(customer_id, "restoring-idx", "restoring")
        .await
        .unwrap();

    let svc = build_scheduler(
        vm_repo,
        tenant_repo.clone(),
        migration_svc,
        alert_svc,
        mock_http,
        SchedulerConfig {
            scrape_interval_secs: 60,
            ..SchedulerConfig::default()
        },
    );

    svc.run_cycle().await.unwrap();

    let raw = tenant_repo
        .find_raw(customer_id, "restoring-idx")
        .await
        .unwrap()
        .expect("tenant should exist");
    assert!(
        raw.vm_id.is_none(),
        "restoring index should NOT be auto-placed by scheduler; vm_id should be None"
    );
}

// ---------------------------------------------------------------------------
// Test 4: tenant_map_includes_tier_field
//
// The /internal/tenant-map response should include the tier field so the
// metering agent can filter cold/restoring indexes.
// ---------------------------------------------------------------------------
#[tokio::test]
async fn tenant_map_includes_tier_field() {
    let tenant_repo = common::mock_tenant_repo();
    let deploy_id = uuid::Uuid::new_v4();
    tenant_repo.seed_deployment(
        deploy_id,
        "us-east-1",
        Some("http://fj.local"),
        "healthy",
        "running",
    );

    let cid = uuid::Uuid::new_v4();
    tenant_repo
        .create(cid, "active-idx", deploy_id)
        .await
        .unwrap();
    tenant_repo
        .create(cid, "cold-idx", deploy_id)
        .await
        .unwrap();
    tenant_repo.set_tier(cid, "cold-idx", "cold").await.unwrap();

    let app = common::test_app_with_tenant_repo(tenant_repo.clone());
    let response = app
        .oneshot(
            axum::http::Request::builder()
                .uri("/internal/tenant-map")
                .header("x-internal-key", common::TEST_INTERNAL_AUTH_TOKEN)
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), axum::http::StatusCode::OK);
    let body = axum::body::to_bytes(response.into_body(), 1_000_000)
        .await
        .unwrap();
    let entries: Vec<serde_json::Value> = serde_json::from_slice(&body).unwrap();

    // Every entry should have a "tier" field
    for entry in &entries {
        assert!(
            entry.get("tier").is_some(),
            "tenant-map entry missing tier field: {entry}"
        );
    }

    let cold_entry = entries
        .iter()
        .find(|e| e["tenant_id"] == "cold-idx")
        .unwrap();
    assert_eq!(cold_entry["tier"], "cold");

    let active_entry = entries
        .iter()
        .find(|e| e["tenant_id"] == "active-idx")
        .unwrap();
    assert_eq!(active_entry["tier"], "active");
}

// ---------------------------------------------------------------------------
// Test 5: cold_storage_usage_endpoint_returns_snapshot_sizes
//
// The /internal/cold-storage-usage endpoint returns completed cold snapshots
// with customer_id, tenant_id, and size_bytes for metering.
// ---------------------------------------------------------------------------
#[tokio::test]
async fn cold_storage_usage_endpoint_returns_snapshot_sizes() {
    let cold_snapshot_repo = common::mock_cold_snapshot_repo();
    let customer_id = uuid::Uuid::new_v4();

    // Seed a completed snapshot
    use api::models::cold_snapshot::NewColdSnapshot;
    let snap = cold_snapshot_repo
        .create(NewColdSnapshot {
            customer_id,
            tenant_id: "my-index".to_string(),
            source_vm_id: uuid::Uuid::new_v4(),
            object_key: "cold/test/my-index/snap.fj".to_string(),
        })
        .await
        .unwrap();
    cold_snapshot_repo.set_exporting(snap.id).await.unwrap();
    cold_snapshot_repo
        .set_completed(snap.id, 1_073_741_824, "abc123") // 1 GB
        .await
        .unwrap();

    let app = common::test_app_with_cold_snapshot_repo(cold_snapshot_repo);
    let response = app
        .oneshot(
            axum::http::Request::builder()
                .uri("/internal/cold-storage-usage")
                .header("x-internal-key", common::TEST_INTERNAL_AUTH_TOKEN)
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), axum::http::StatusCode::OK);
    let body = axum::body::to_bytes(response.into_body(), 1_000_000)
        .await
        .unwrap();
    let entries: Vec<serde_json::Value> = serde_json::from_slice(&body).unwrap();

    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0]["customer_id"], customer_id.to_string());
    assert_eq!(entries[0]["tenant_id"], "my-index");
    assert_eq!(entries[0]["size_bytes"], 1_073_741_824_i64);
}
