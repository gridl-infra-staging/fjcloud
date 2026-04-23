mod common;

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use api::models::vm_inventory::NewVmInventory;
use api::repos::index_migration_repo::IndexMigrationRepo;
use api::repos::{TenantRepo, VmInventoryRepo};
use api::secrets::NodeSecretManager;
use api::services::discovery::DiscoveryService;
use api::services::migration::{
    MigrationConfig, MigrationError, MigrationHttpClient, MigrationHttpClientError,
    MigrationHttpRequest, MigrationHttpResponse, MigrationRequest, MigrationService,
};
use async_trait::async_trait;
use uuid::Uuid;

#[derive(Default)]
struct MockMigrationHttpClient {
    requests: Mutex<Vec<MigrationHttpRequest>>,
    responses: Mutex<VecDeque<Result<MigrationHttpResponse, MigrationHttpClientError>>>,
}

impl MockMigrationHttpClient {
    fn enqueue_response(&self, response: Result<MigrationHttpResponse, MigrationHttpClientError>) {
        self.responses.lock().unwrap().push_back(response);
    }

    fn recorded_requests(&self) -> Vec<MigrationHttpRequest> {
        self.requests.lock().unwrap().clone()
    }
}

#[async_trait]
impl MigrationHttpClient for MockMigrationHttpClient {
    async fn send(
        &self,
        request: MigrationHttpRequest,
    ) -> Result<MigrationHttpResponse, MigrationHttpClientError> {
        self.requests.lock().unwrap().push(request);
        self.responses
            .lock()
            .unwrap()
            .pop_front()
            .expect("test must enqueue HTTP responses")
    }
}

// ---------------------------------------------------------------------------
// Setup helpers
// ---------------------------------------------------------------------------

fn vm_seed(region: &str, hostname: &str, flapjack_url: &str) -> NewVmInventory {
    NewVmInventory {
        region: region.to_string(),
        provider: "aws".to_string(),
        hostname: hostname.to_string(),
        flapjack_url: flapjack_url.to_string(),
        capacity: serde_json::json!({
            "cpu_weight": 100.0,
            "mem_rss_bytes": 10_000_000_u64,
            "disk_bytes": 10_000_000_u64,
            "query_rps": 10_000.0,
            "indexing_rps": 10_000.0
        }),
    }
}

#[allow(dead_code)]
struct MigrationTestFixture {
    service: MigrationService,
    tenant_repo: Arc<common::MockTenantRepo>,
    migration_repo: Arc<common::MockIndexMigrationRepo>,
    alert_service: Arc<api::services::alerting::MockAlertService>,
    discovery_service: Arc<DiscoveryService>,
    http_client: Arc<MockMigrationHttpClient>,
    customer_id: Uuid,
    index_name: String,
    source_vm: api::models::vm_inventory::VmInventory,
    dest_vm: api::models::vm_inventory::VmInventory,
}

async fn setup_fixture(index_name: &str, max_concurrent: u32) -> MigrationTestFixture {
    let tenant_repo = common::mock_tenant_repo();
    let vm_repo = common::mock_vm_inventory_repo();
    let migration_repo = common::mock_index_migration_repo();
    let alert_service = common::mock_alert_service();
    let discovery_service = Arc::new(DiscoveryService::with_ttl(
        tenant_repo.clone(),
        vm_repo.clone(),
        3600,
    ));
    let http_client = Arc::new(MockMigrationHttpClient::default());
    let node_secret_manager = common::mock_node_secret_manager();

    let config = MigrationConfig {
        max_concurrent,
        rollback_window: chrono::Duration::seconds(300),
        replication_timeout: Duration::from_secs(1),
        replication_poll_interval: Duration::from_millis(10),
        replication_near_zero_lag_ops: 10,
        long_running_warning_threshold: Duration::from_secs(600),
    };

    let service = MigrationService::with_http_client_and_config(
        tenant_repo.clone(),
        vm_repo.clone(),
        migration_repo.clone(),
        alert_service.clone(),
        discovery_service.clone(),
        node_secret_manager.clone(),
        http_client.clone(),
        config,
    );

    let customer_id = Uuid::new_v4();
    let deployment_id = Uuid::new_v4();
    tenant_repo
        .create(customer_id, index_name, deployment_id)
        .await
        .expect("seed tenant");

    let source_vm = vm_repo
        .create(vm_seed(
            "us-east-1",
            "vm-source.flapjack.foo",
            "http://source-vm.test",
        ))
        .await
        .expect("seed source vm");

    let dest_vm = vm_repo
        .create(vm_seed(
            "us-east-1",
            "vm-dest.flapjack.foo",
            "http://dest-vm.test",
        ))
        .await
        .expect("seed destination vm");

    node_secret_manager
        .create_node_api_key(&source_vm.id.to_string(), &source_vm.region)
        .await
        .expect("seed source vm key");
    node_secret_manager
        .create_node_api_key(&dest_vm.id.to_string(), &dest_vm.region)
        .await
        .expect("seed destination vm key");

    tenant_repo
        .set_vm_id(customer_id, index_name, source_vm.id)
        .await
        .expect("seed tenant vm assignment");

    MigrationTestFixture {
        service,
        tenant_repo,
        migration_repo,
        alert_service,
        discovery_service,
        http_client,
        customer_id,
        index_name: index_name.to_string(),
        source_vm,
        dest_vm,
    }
}

fn fixture_request(f: &MigrationTestFixture) -> MigrationRequest {
    MigrationRequest {
        index_name: f.index_name.clone(),
        customer_id: f.customer_id,
        source_vm_id: f.source_vm.id,
        dest_vm_id: f.dest_vm.id,
        requested_by: "scheduler".to_string(),
    }
}

fn sample_request(index_name: &str) -> MigrationRequest {
    MigrationRequest {
        index_name: index_name.to_string(),
        customer_id: Uuid::new_v4(),
        source_vm_id: Uuid::new_v4(),
        dest_vm_id: Uuid::new_v4(),
        requested_by: "scheduler".to_string(),
    }
}

// ---------------------------------------------------------------------------
// Class 1: Concurrent migration pressure — max-concurrent enforced
// ---------------------------------------------------------------------------

/// When active migrations reach max_concurrent, additional execute() calls are
/// rejected with ConcurrencyLimitReached. No HTTP calls, no repo creation, and
/// no partial state changes leak.
#[tokio::test]
async fn migration_pressure_rejects_when_at_capacity() {
    let f = setup_fixture("pressure", 2).await;

    // Seed 2 active migrations (pending status counts as active)
    f.migration_repo
        .create(&sample_request("already-running-1"))
        .await
        .unwrap();
    f.migration_repo
        .create(&sample_request("already-running-2"))
        .await
        .unwrap();

    assert_eq!(f.migration_repo.count_active().await.unwrap(), 2);

    // Attempt to execute another migration — should be rejected
    let err = f
        .service
        .execute(fixture_request(&f))
        .await
        .expect_err("should reject when at max_concurrent=2");

    assert!(
        matches!(
            err,
            MigrationError::ConcurrencyLimitReached { active, max } if active == 2 && max == 2
        ),
        "error should report correct active/max counts"
    );

    // No HTTP requests should have been sent
    assert!(
        f.http_client.recorded_requests().is_empty(),
        "no HTTP calls when concurrency limit reached"
    );

    // No new migration row created (still only 2)
    assert_eq!(
        f.migration_repo.count_active().await.unwrap(),
        2,
        "no new migration row should be created when rejected"
    );

    // Tenant tier should remain unchanged (not flipped to "migrating")
    let tenant = f
        .tenant_repo
        .find_raw(f.customer_id, &f.index_name)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        tenant.tier, "active",
        "tenant tier should not change when migration is rejected"
    );
}

/// After an active migration completes, a new migration should be allowed
/// (count_active decreases below threshold).
#[tokio::test]
async fn migration_pressure_allows_after_slot_freed() {
    let repo = common::mock_index_migration_repo();

    // Seed one active migration
    let active = repo
        .create(&sample_request("blocking"))
        .await
        .expect("seed active migration");
    assert_eq!(repo.count_active().await.unwrap(), 1);

    // Complete it — frees the slot
    repo.set_completed(active.id).await.unwrap();
    assert_eq!(repo.count_active().await.unwrap(), 0);

    // Now create a new one — should succeed
    let new_migration = repo
        .create(&sample_request("new-after-free"))
        .await
        .unwrap();
    assert_eq!(new_migration.status, "pending");
    assert_eq!(repo.count_active().await.unwrap(), 1);
}

// ---------------------------------------------------------------------------
// Class 2: Cutover health-race abort — unhealthy destination during cutover
// ---------------------------------------------------------------------------

/// When the destination resume fails during cutover (HTTP 500 on
/// /internal/resume), the migration service must:
/// 1. Restore routing to the source VM (set_vm_id back to source)
/// 2. Resume source writes (POST /internal/resume on source)
/// 3. Restore tenant tier to "active" (not left in "migrating")
/// 4. Return an error
#[tokio::test]
async fn cutover_abort_on_dest_failure_restores_source_routing() {
    let f = setup_fixture("cutover-abort", 3).await;

    // Full protocol flow up to destination resume failure:
    // 1) start_replication → 200
    // 2) source oplog (near-zero) → 100
    // 3) dest oplog (near-zero) → 95 (lag=5, within near_zero=10)
    // 4) pause source → 200
    // 5) source oplog (exact) → 100
    // 6) dest oplog (exact) → 100 (lag=0)
    // 7) dest resume → 500 (FAIL — triggers recovery)
    // 8) source resume (recovery) → 200
    f.http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: "{}".to_string(),
    }));
    f.http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: common::oplog_metric(&f.index_name, 100),
    }));
    f.http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: common::oplog_metric(&f.index_name, 95),
    }));
    f.http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: "{}".to_string(),
    }));
    f.http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: common::oplog_metric(&f.index_name, 100),
    }));
    f.http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: common::oplog_metric(&f.index_name, 100),
    }));
    // Destination resume fails — triggers cutover abort/recovery
    f.http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 500,
        body: "destination unhealthy during cutover".to_string(),
    }));
    // Source resume during recovery
    f.http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: "{}".to_string(),
    }));
    // Destination cleanup during recovery
    f.http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: "{}".to_string(),
    }));

    let err = f
        .service
        .execute(fixture_request(&f))
        .await
        .expect_err("should fail when destination resume fails");
    assert!(matches!(err, MigrationError::Http(_)));

    // Routing must be restored to source VM
    let tenant = f
        .tenant_repo
        .find_raw(f.customer_id, &f.index_name)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        tenant.vm_id,
        Some(f.source_vm.id),
        "routing must be restored to source VM after cutover abort"
    );
    assert_eq!(
        tenant.tier, "active",
        "tenant tier must be restored to active after cutover abort"
    );

    // Discovery cache must reflect source VM
    let discovered = f
        .discovery_service
        .discover(f.customer_id, &f.index_name)
        .await
        .expect("discover should still succeed");
    assert_eq!(
        discovered.vm, f.source_vm.hostname,
        "discovery must resolve to source VM after cutover abort"
    );

    // Source resume call must have been sent
    let requests = f.http_client.recorded_requests();
    assert!(
        requests.iter().any(|r| {
            r.url
                == format!(
                    "{}/internal/resume/{}",
                    f.source_vm.flapjack_url, f.index_name
                )
        }),
        "recovery must resume source writes"
    );
}

/// When destination resume AND source resume both fail during cutover recovery,
/// the migration service still restores DB routing to the source VM. Source
/// resume is best-effort; the DB state must be correct regardless.
#[tokio::test]
async fn cutover_abort_restores_routing_even_when_source_resume_fails() {
    let f = setup_fixture("cutover-double-fail", 3).await;

    // Same protocol flow as above, but source resume also fails:
    f.http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: "{}".to_string(),
    }));
    f.http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: common::oplog_metric(&f.index_name, 100),
    }));
    f.http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: common::oplog_metric(&f.index_name, 95),
    }));
    f.http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: "{}".to_string(),
    }));
    f.http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: common::oplog_metric(&f.index_name, 100),
    }));
    f.http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: common::oplog_metric(&f.index_name, 100),
    }));
    // Destination resume fails
    f.http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 500,
        body: "destination unhealthy".to_string(),
    }));
    // Source resume also fails (double failure)
    f.http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 500,
        body: "source also down".to_string(),
    }));
    f.http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: "{}".to_string(),
    }));

    let err = f
        .service
        .execute(fixture_request(&f))
        .await
        .expect_err("should fail when destination resume fails");
    assert!(matches!(err, MigrationError::Http(_)));

    // DB routing must still point to source VM even with double failure
    let tenant = f
        .tenant_repo
        .find_raw(f.customer_id, &f.index_name)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        tenant.vm_id,
        Some(f.source_vm.id),
        "source routing must be restored even when source resume call fails"
    );
    assert_eq!(tenant.tier, "active");
}
