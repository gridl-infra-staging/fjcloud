use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use api::models::vm_inventory::NewVmInventory;
use api::repos::{TenantRepo, VmInventoryRepo};
use api::secrets::NodeSecretManager;
use api::services::discovery::DiscoveryService;
use api::services::migration::{
    MigrationHttpClient, MigrationHttpClientError, MigrationHttpRequest, MigrationHttpResponse,
    MigrationService, MigrationStatus,
};
use async_trait::async_trait;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use serde_json::json;
use tower::ServiceExt;
use uuid::Uuid;

async fn body_json(resp: axum::response::Response) -> serde_json::Value {
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

#[tokio::test]
async fn admin_migrations_get_returns_empty_list_by_default() {
    let app = api::router::build_router(crate::common::test_state());

    let req = Request::builder()
        .uri("/admin/migrations")
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    assert_eq!(json, serde_json::json!([]));
}

#[tokio::test]
async fn admin_migrations_get_rejects_invalid_status_filter() {
    let app = api::router::build_router(crate::common::test_state());

    let req = Request::builder()
        .uri("/admin/migrations?status=banana")
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let json = body_json(resp).await;
    assert_eq!(
        json,
        serde_json::json!({
            "error": "status must be one of: active, pending, replicating, cutting_over, completed, failed, rolled_back"
        })
    );
}

#[tokio::test]
async fn admin_migrations_post_unknown_index_returns_404() {
    let app = api::router::build_router(crate::common::test_state());

    let req = Request::builder()
        .method("POST")
        .uri("/admin/migrations")
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::to_string(&serde_json::json!({
                "index_name": "missing-index",
                "dest_vm_id": Uuid::new_v4()
            }))
            .unwrap(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);

    let json = body_json(resp).await;
    assert_eq!(json, serde_json::json!({"error": "index not found"}));
}

#[tokio::test]
async fn admin_migrations_post_rejects_same_source_and_destination_vm() {
    let customer_repo = crate::common::mock_repo();
    let tenant_repo = crate::common::mock_tenant_repo();
    let vm_repo = crate::common::mock_vm_inventory_repo();
    let migration_repo = crate::common::mock_index_migration_repo();
    let alert_service = crate::common::mock_alert_service();
    let discovery_service = Arc::new(DiscoveryService::new(tenant_repo.clone(), vm_repo.clone()));
    let migration_service = Arc::new(MigrationService::new(
        tenant_repo.clone(),
        vm_repo.clone(),
        migration_repo.clone(),
        alert_service.clone(),
        discovery_service.clone(),
        crate::common::mock_node_secret_manager(),
        reqwest::Client::new(),
        3,
    ));

    let customer_id = customer_repo.seed("Alice", "alice@example.com").id;
    let deployment_id = Uuid::new_v4();
    let index_name = "products";
    tenant_repo.seed_deployment(
        deployment_id,
        "us-east-1",
        Some("http://source-vm.test"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer_id, index_name, deployment_id)
        .await
        .expect("seed tenant");

    let source_vm = vm_repo
        .create(NewVmInventory {
            region: "us-east-1".to_string(),
            provider: "aws".to_string(),
            hostname: "vm-source.flapjack.foo".to_string(),
            flapjack_url: "http://source-vm.test".to_string(),
            capacity: serde_json::json!({
                "cpu_weight": 100.0,
                "mem_rss_bytes": 10_000_000_u64,
                "disk_bytes": 10_000_000_u64,
                "query_rps": 10_000.0,
                "indexing_rps": 10_000.0
            }),
        })
        .await
        .expect("seed source vm");

    tenant_repo
        .set_vm_id(customer_id, index_name, source_vm.id)
        .await
        .expect("set tenant vm assignment");

    let mut state = crate::common::test_state();
    state.customer_repo = customer_repo;
    state.tenant_repo = tenant_repo;
    state.vm_inventory_repo = vm_repo;
    state.index_migration_repo = migration_repo;
    state.alert_service = alert_service;
    state.discovery_service = discovery_service;
    state.migration_service = migration_service;

    let app = api::router::build_router(state);

    let req = Request::builder()
        .method("POST")
        .uri("/admin/migrations")
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::to_string(&serde_json::json!({
                "index_name": index_name,
                "dest_vm_id": source_vm.id
            }))
            .unwrap(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let json = body_json(resp).await;
    let message = json["error"].as_str().unwrap_or_default();
    assert!(message.contains("source VM and destination VM must differ"));
}

#[tokio::test]
async fn admin_migrations_post_rejects_ambiguous_index_name() {
    let customer_repo = crate::common::mock_repo();
    let tenant_repo = crate::common::mock_tenant_repo();
    let vm_repo = crate::common::mock_vm_inventory_repo();
    let migration_repo = crate::common::mock_index_migration_repo();
    let alert_service = crate::common::mock_alert_service();
    let discovery_service = Arc::new(DiscoveryService::new(tenant_repo.clone(), vm_repo.clone()));
    let migration_service = Arc::new(MigrationService::new(
        tenant_repo.clone(),
        vm_repo.clone(),
        migration_repo.clone(),
        alert_service.clone(),
        discovery_service.clone(),
        crate::common::mock_node_secret_manager(),
        reqwest::Client::new(),
        3,
    ));

    let alice = customer_repo.seed("Alice", "alice@example.com");
    let bob = customer_repo.seed("Bob", "bob@example.com");
    let index_name = "shared-index";

    let alice_deployment_id = Uuid::new_v4();
    tenant_repo.seed_deployment(
        alice_deployment_id,
        "us-east-1",
        Some("http://alice-source.test"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(alice.id, index_name, alice_deployment_id)
        .await
        .expect("seed alice tenant");

    let bob_deployment_id = Uuid::new_v4();
    tenant_repo.seed_deployment(
        bob_deployment_id,
        "us-east-1",
        Some("http://bob-source.test"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(bob.id, index_name, bob_deployment_id)
        .await
        .expect("seed bob tenant");

    let alice_vm = vm_repo
        .create(NewVmInventory {
            region: "us-east-1".to_string(),
            provider: "aws".to_string(),
            hostname: "vm-alice-source.flapjack.foo".to_string(),
            flapjack_url: "http://alice-source.test".to_string(),
            capacity: serde_json::json!({
                "cpu_weight": 100.0,
                "mem_rss_bytes": 10_000_000_u64,
                "disk_bytes": 10_000_000_u64,
                "query_rps": 10_000.0,
                "indexing_rps": 10_000.0
            }),
        })
        .await
        .expect("seed alice vm");

    let bob_vm = vm_repo
        .create(NewVmInventory {
            region: "us-east-1".to_string(),
            provider: "aws".to_string(),
            hostname: "vm-bob-source.flapjack.foo".to_string(),
            flapjack_url: "http://bob-source.test".to_string(),
            capacity: serde_json::json!({
                "cpu_weight": 100.0,
                "mem_rss_bytes": 10_000_000_u64,
                "disk_bytes": 10_000_000_u64,
                "query_rps": 10_000.0,
                "indexing_rps": 10_000.0
            }),
        })
        .await
        .expect("seed bob vm");

    let dest_vm = vm_repo
        .create(NewVmInventory {
            region: "us-east-1".to_string(),
            provider: "aws".to_string(),
            hostname: "vm-destination.flapjack.foo".to_string(),
            flapjack_url: "http://dest-vm.test".to_string(),
            capacity: serde_json::json!({
                "cpu_weight": 100.0,
                "mem_rss_bytes": 10_000_000_u64,
                "disk_bytes": 10_000_000_u64,
                "query_rps": 10_000.0,
                "indexing_rps": 10_000.0
            }),
        })
        .await
        .expect("seed destination vm");

    tenant_repo
        .set_vm_id(alice.id, index_name, alice_vm.id)
        .await
        .expect("assign alice source vm");
    tenant_repo
        .set_vm_id(bob.id, index_name, bob_vm.id)
        .await
        .expect("assign bob source vm");

    let mut state = crate::common::test_state();
    state.customer_repo = customer_repo;
    state.tenant_repo = tenant_repo;
    state.vm_inventory_repo = vm_repo;
    state.index_migration_repo = migration_repo;
    state.alert_service = alert_service;
    state.discovery_service = discovery_service;
    state.migration_service = migration_service;

    let app = api::router::build_router(state);

    let req = Request::builder()
        .method("POST")
        .uri("/admin/migrations")
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::to_string(&serde_json::json!({
                "index_name": index_name,
                "dest_vm_id": dest_vm.id
            }))
            .unwrap(),
        ))
        .unwrap();

    let resp = app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::CONFLICT);

    let json = body_json(resp).await;
    let message = json["error"].as_str().unwrap_or_default();
    assert!(message.contains("multiple customers"));

    let targeted_req = Request::builder()
        .method("POST")
        .uri("/admin/migrations")
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::to_string(&serde_json::json!({
                "customer_id": alice.id,
                "index_name": index_name,
                "dest_vm_id": Uuid::new_v4()
            }))
            .unwrap(),
        ))
        .unwrap();

    let targeted_resp = app.oneshot(targeted_req).await.unwrap();
    assert_eq!(targeted_resp.status(), StatusCode::NOT_FOUND);
    assert_eq!(
        body_json(targeted_resp).await,
        serde_json::json!({"error": "destination VM not found"})
    );
}

#[tokio::test]
async fn admin_migrations_post_rejects_already_migrating_index() {
    let customer_repo = crate::common::mock_repo();
    let tenant_repo = crate::common::mock_tenant_repo();
    let vm_repo = crate::common::mock_vm_inventory_repo();
    let migration_repo = crate::common::mock_index_migration_repo();
    let alert_service = crate::common::mock_alert_service();
    let discovery_service = Arc::new(DiscoveryService::new(tenant_repo.clone(), vm_repo.clone()));
    let migration_service = Arc::new(MigrationService::new(
        tenant_repo.clone(),
        vm_repo.clone(),
        migration_repo.clone(),
        alert_service.clone(),
        discovery_service.clone(),
        crate::common::mock_node_secret_manager(),
        reqwest::Client::new(),
        3,
    ));

    let customer_id = customer_repo.seed("Alice", "alice@example.com").id;
    let deployment_id = Uuid::new_v4();
    let index_name = "products";
    tenant_repo.seed_deployment(
        deployment_id,
        "us-east-1",
        Some("http://source-vm.test"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer_id, index_name, deployment_id)
        .await
        .expect("seed tenant");

    let source_vm = vm_repo
        .create(NewVmInventory {
            region: "us-east-1".to_string(),
            provider: "aws".to_string(),
            hostname: "vm-source.flapjack.foo".to_string(),
            flapjack_url: "http://source-vm.test".to_string(),
            capacity: serde_json::json!({
                "cpu_weight": 100.0,
                "mem_rss_bytes": 10_000_000_u64,
                "disk_bytes": 10_000_000_u64,
                "query_rps": 10_000.0,
                "indexing_rps": 10_000.0
            }),
        })
        .await
        .expect("seed source vm");

    let dest_vm = vm_repo
        .create(NewVmInventory {
            region: "us-east-1".to_string(),
            provider: "aws".to_string(),
            hostname: "vm-dest.flapjack.foo".to_string(),
            flapjack_url: "http://dest-vm.test".to_string(),
            capacity: serde_json::json!({
                "cpu_weight": 100.0,
                "mem_rss_bytes": 10_000_000_u64,
                "disk_bytes": 10_000_000_u64,
                "query_rps": 10_000.0,
                "indexing_rps": 10_000.0
            }),
        })
        .await
        .expect("seed dest vm");

    tenant_repo
        .set_vm_id(customer_id, index_name, source_vm.id)
        .await
        .expect("assign source vm");

    // Set tier to migrating — simulates an in-progress migration
    tenant_repo
        .set_tier(customer_id, index_name, "migrating")
        .await
        .expect("set tier to migrating");

    let mut state = crate::common::test_state();
    state.customer_repo = customer_repo;
    state.tenant_repo = tenant_repo;
    state.vm_inventory_repo = vm_repo;
    state.index_migration_repo = migration_repo;
    state.alert_service = alert_service;
    state.discovery_service = discovery_service;
    state.migration_service = migration_service;

    let app = api::router::build_router(state);

    let req = Request::builder()
        .method("POST")
        .uri("/admin/migrations")
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::to_string(&serde_json::json!({
                "index_name": index_name,
                "dest_vm_id": dest_vm.id
            }))
            .unwrap(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::CONFLICT);

    let json = body_json(resp).await;
    let message = json["error"].as_str().unwrap_or_default();
    assert!(
        message.contains("already migrating"),
        "expected 'already migrating' error, got: {message}"
    );
}

/// Mock HTTP client that returns pre-queued responses for migration protocol.
#[derive(Default)]
struct AlwaysSuccessMigrationHttpClient {
    responses: Mutex<VecDeque<Result<MigrationHttpResponse, MigrationHttpClientError>>>,
    active_index_uid: Mutex<Option<String>>,
    requests: Mutex<Vec<MigrationHttpRequest>>,
}

static PROBE_SEAM_ENV_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

impl AlwaysSuccessMigrationHttpClient {
    fn enqueue(&self, resp: Result<MigrationHttpResponse, MigrationHttpClientError>) {
        self.responses.lock().unwrap().push_back(resp);
    }

    /// Queue the 8 HTTP responses expected by a successful migration protocol:
    /// fetch_ops, start_replication, source_seq, dest_seq, pause, source_seq, dest_seq, resume
    fn queue_successful_protocol(&self) {
        let ok = || {
            Ok(MigrationHttpResponse {
                status: 200,
                body: "{}".to_string(),
            })
        };
        self.enqueue(Ok(MigrationHttpResponse {
            status: 200,
            body: serde_json::json!({
                "tenant_id": "test",
                "ops": [],
                "current_seq": 100
            })
            .to_string(),
        }));
        // start_replication
        self.enqueue(ok());
        // wait_for_replication_lag: source_seq, dest_seq
        self.enqueue_metric(100);
        self.enqueue_metric(100);
        // pause
        self.enqueue(ok());
        // wait_for_replication_lag (final): source_seq, dest_seq
        self.enqueue_metric(100);
        self.enqueue_metric(100);
        // resume
        self.enqueue(ok());
    }

    fn enqueue_metric(&self, seq: i64) {
        self.enqueue(Ok(MigrationHttpResponse {
            status: 200,
            body: format!("__metric_seq:{seq}"),
        }));
    }

    fn queue_begin_replication_then_delete(&self) {
        let ok = || {
            Ok(MigrationHttpResponse {
                status: 200,
                body: "{}".to_string(),
            })
        };
        self.enqueue(Ok(MigrationHttpResponse {
            status: 200,
            body: serde_json::json!({
                "tenant_id": "test",
                "ops": [],
                "current_seq": 100
            })
            .to_string(),
        }));
        self.enqueue(ok());
        self.enqueue(ok());
    }

    fn queue_begin_replication_then_recover(&self) {
        let ok = || {
            Ok(MigrationHttpResponse {
                status: 200,
                body: "{}".to_string(),
            })
        };
        self.enqueue(Ok(MigrationHttpResponse {
            status: 200,
            body: serde_json::json!({
                "tenant_id": "test",
                "ops": [],
                "current_seq": 100
            })
            .to_string(),
        }));
        self.enqueue(ok());
        self.enqueue(ok());
        self.enqueue(ok());
    }

    fn recorded_requests(&self) -> Vec<MigrationHttpRequest> {
        self.requests.lock().unwrap().clone()
    }
}

#[async_trait]
impl MigrationHttpClient for AlwaysSuccessMigrationHttpClient {
    async fn send(
        &self,
        request: MigrationHttpRequest,
    ) -> Result<MigrationHttpResponse, MigrationHttpClientError> {
        self.requests.lock().unwrap().push(request.clone());
        if request.url.ends_with("/internal/replicate") {
            let index_uid = request
                .json_body
                .as_ref()
                .and_then(|body| body.get("tenant_id"))
                .and_then(|value| value.as_str())
                .expect("replication request should include tenant_id")
                .to_string();
            *self.active_index_uid.lock().unwrap() = Some(index_uid);
        }

        let response = self
            .responses
            .lock()
            .unwrap()
            .pop_front()
            .expect("test must enqueue HTTP responses before migration")?;

        if let Some(seq) = response.body.strip_prefix("__metric_seq:") {
            let index_uid = self
                .active_index_uid
                .lock()
                .unwrap()
                .clone()
                .expect("metrics should be requested after replication starts");
            return Ok(MigrationHttpResponse {
                status: response.status,
                body: format!(r#"flapjack_oplog_current_seq{{index="{index_uid}"}} {seq}"#),
            });
        }

        Ok(response)
    }
}

/// Helper: build test state with migration service wired up from given repos.
/// Uses reqwest (real HTTP) — suitable for tests that don't reach execute().
fn build_migration_test_state(
    customer_repo: Arc<crate::common::MockCustomerRepo>,
    tenant_repo: Arc<crate::common::MockTenantRepo>,
    vm_repo: Arc<crate::common::MockVmInventoryRepo>,
) -> api::state::AppState {
    let migration_repo = crate::common::mock_index_migration_repo();
    let alert_service = crate::common::mock_alert_service();
    let discovery_service = Arc::new(DiscoveryService::new(tenant_repo.clone(), vm_repo.clone()));
    let migration_service = Arc::new(MigrationService::new(
        tenant_repo.clone(),
        vm_repo.clone(),
        migration_repo.clone(),
        alert_service.clone(),
        discovery_service.clone(),
        crate::common::mock_node_secret_manager(),
        reqwest::Client::new(),
        3,
    ));

    let mut state = crate::common::test_state();
    state.customer_repo = customer_repo;
    state.tenant_repo = tenant_repo;
    state.vm_inventory_repo = vm_repo;
    state.index_migration_repo = migration_repo;
    state.alert_service = alert_service;
    state.discovery_service = discovery_service;
    state.migration_service = migration_service;
    state
}

/// Helper: build test state with mock HTTP client — suitable for tests that call execute().
async fn build_migration_test_state_with_mock_http(
    customer_repo: Arc<crate::common::MockCustomerRepo>,
    tenant_repo: Arc<crate::common::MockTenantRepo>,
    vm_repo: Arc<crate::common::MockVmInventoryRepo>,
    http_client: Arc<AlwaysSuccessMigrationHttpClient>,
) -> api::state::AppState {
    let migration_repo = crate::common::mock_index_migration_repo();
    let alert_service = crate::common::mock_alert_service();
    let discovery_service = Arc::new(DiscoveryService::new(tenant_repo.clone(), vm_repo.clone()));
    let node_secret_manager = crate::common::mock_node_secret_manager();

    for hostname in ["vm-source.flapjack.foo", "vm-dest.flapjack.foo"] {
        if let Some(vm) = vm_repo
            .find_by_hostname(hostname)
            .await
            .expect("find vm by hostname")
        {
            node_secret_manager
                .create_node_api_key(vm.node_secret_id(), &vm.region)
                .await
                .expect("seed migration internal key");
        }
    }

    let migration_service = Arc::new(MigrationService::with_http_client(
        tenant_repo.clone(),
        vm_repo.clone(),
        migration_repo.clone(),
        alert_service.clone(),
        discovery_service.clone(),
        node_secret_manager,
        http_client,
        3,
    ));

    let mut state = crate::common::test_state();
    state.customer_repo = customer_repo;
    state.tenant_repo = tenant_repo;
    state.vm_inventory_repo = vm_repo;
    state.index_migration_repo = migration_repo;
    state.alert_service = alert_service;
    state.discovery_service = discovery_service;
    state.migration_service = migration_service;
    state
}

/// Seed VMs and tenant for migration endpoint testing.
/// Returns (customer_repo, tenant_repo, vm_repo, source_vm_id, dest_vm_id, index_name).
async fn seed_migration_repos(
    dest_region: &str,
    dest_provider: &str,
    dest_url: &str,
) -> (
    Arc<crate::common::MockCustomerRepo>,
    Arc<crate::common::MockTenantRepo>,
    Arc<crate::common::MockVmInventoryRepo>,
    uuid::Uuid,
    uuid::Uuid,
    String,
) {
    let customer_repo = crate::common::mock_repo();
    let tenant_repo = crate::common::mock_tenant_repo();
    let vm_repo = crate::common::mock_vm_inventory_repo();

    let customer_id = customer_repo.seed("Alice", "alice@example.com").id;
    let deployment_id = Uuid::new_v4();
    let index_name = "products";

    tenant_repo.seed_deployment(
        deployment_id,
        "us-east-1",
        Some("http://source-vm.test"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer_id, index_name, deployment_id)
        .await
        .expect("seed tenant");

    let source_vm = vm_repo
        .create(NewVmInventory {
            region: "us-east-1".to_string(),
            provider: "aws".to_string(),
            hostname: "vm-source.flapjack.foo".to_string(),
            flapjack_url: "http://source-vm.test".to_string(),
            capacity: json!({
                "cpu_weight": 100.0,
                "mem_rss_bytes": 10_000_000_u64,
                "disk_bytes": 10_000_000_u64,
                "query_rps": 10_000.0,
                "indexing_rps": 10_000.0
            }),
        })
        .await
        .expect("seed source vm");

    let dest_vm = vm_repo
        .create(NewVmInventory {
            region: dest_region.to_string(),
            provider: dest_provider.to_string(),
            hostname: "vm-dest.flapjack.foo".to_string(),
            flapjack_url: dest_url.to_string(),
            capacity: json!({
                "cpu_weight": 100.0,
                "mem_rss_bytes": 10_000_000_u64,
                "disk_bytes": 10_000_000_u64,
                "query_rps": 10_000.0,
                "indexing_rps": 10_000.0
            }),
        })
        .await
        .expect("seed dest vm");

    tenant_repo
        .set_vm_id(customer_id, index_name, source_vm.id)
        .await
        .expect("set tenant vm assignment");

    (
        customer_repo,
        tenant_repo,
        vm_repo,
        source_vm.id,
        dest_vm.id,
        index_name.to_string(),
    )
}

/// Seed VMs and tenant for cross-provider migration testing.
/// Returns (customer_repo, tenant_repo, vm_repo, source_vm_id, dest_vm_id, index_name).
async fn seed_cross_provider_repos() -> (
    Arc<crate::common::MockCustomerRepo>,
    Arc<crate::common::MockTenantRepo>,
    Arc<crate::common::MockVmInventoryRepo>,
    uuid::Uuid,
    uuid::Uuid,
    String,
) {
    seed_migration_repos("eu-central-1", "hetzner", "http://dest-vm.test").await
}

/// Seed VMs and tenant for same-provider migration testing.
/// Returns (customer_repo, tenant_repo, vm_repo, source_vm_id, dest_vm_id, index_name).
async fn seed_same_provider_repos() -> (
    Arc<crate::common::MockCustomerRepo>,
    Arc<crate::common::MockTenantRepo>,
    Arc<crate::common::MockVmInventoryRepo>,
    uuid::Uuid,
    uuid::Uuid,
    String,
) {
    seed_migration_repos("us-east-1", "aws", "http://dest-vm.test").await
}

#[tokio::test]
async fn admin_migrations_post_rejects_cross_provider() {
    let (customer_repo, tenant_repo, vm_repo, _source_vm_id, dest_vm_id, index_name) =
        seed_cross_provider_repos().await;
    let state = build_migration_test_state(customer_repo, tenant_repo, vm_repo);
    let app = api::router::build_router(state);

    let req = Request::builder()
        .method("POST")
        .uri("/admin/migrations")
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::to_string(&json!({
                "index_name": index_name,
                "dest_vm_id": dest_vm_id
            }))
            .unwrap(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let json = body_json(resp).await;
    let message = json["error"].as_str().unwrap_or_default();
    assert!(
        message.contains("cross-provider"),
        "expected cross-provider rejection, got: {message}"
    );
}

#[tokio::test]
async fn admin_migrations_post_synchronous_success_returns_completed() {
    let (customer_repo, tenant_repo, vm_repo, _source_vm_id, dest_vm_id, index_name) =
        seed_same_provider_repos().await;

    let http_client = Arc::new(AlwaysSuccessMigrationHttpClient::default());
    http_client.queue_successful_protocol();

    let state =
        build_migration_test_state_with_mock_http(customer_repo, tenant_repo, vm_repo, http_client)
            .await;
    let app = api::router::build_router(state);

    let req = Request::builder()
        .method("POST")
        .uri("/admin/migrations")
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::to_string(&json!({
                "index_name": index_name,
                "dest_vm_id": dest_vm_id
            }))
            .unwrap(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    assert!(json["migration_id"].is_string());
    assert_eq!(
        json["status"].as_str(),
        Some(MigrationStatus::Completed.as_str())
    );
}

#[tokio::test]
async fn admin_cross_provider_migration_succeeds() {
    let (customer_repo, tenant_repo, vm_repo, _source_vm_id, dest_vm_id, index_name) =
        seed_cross_provider_repos().await;

    let http_client = Arc::new(AlwaysSuccessMigrationHttpClient::default());
    http_client.queue_successful_protocol();

    let state =
        build_migration_test_state_with_mock_http(customer_repo, tenant_repo, vm_repo, http_client)
            .await;
    let app = api::router::build_router(state);

    let req = Request::builder()
        .method("POST")
        .uri("/admin/migrations/cross-provider")
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::to_string(&json!({
                "index_name": index_name,
                "dest_vm_id": dest_vm_id
            }))
            .unwrap(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::OK,
        "cross-provider migration via explicit endpoint should complete synchronously"
    );

    let json = body_json(resp).await;
    assert!(
        json["migration_id"].is_string(),
        "should return migration_id"
    );
    assert_eq!(
        json["status"].as_str(),
        Some(MigrationStatus::Completed.as_str())
    );
}

#[tokio::test(flavor = "current_thread")]
async fn admin_probe_recovery_seams_require_explicit_env_gate() {
    let _guard = PROBE_SEAM_ENV_LOCK.lock().await;
    std::env::remove_var("ENGINE_INDEX_IDENTITY_PROBE_RECOVERY_SEAMS");
    let (customer_repo, tenant_repo, vm_repo, _source_vm_id, dest_vm_id, index_name) =
        seed_cross_provider_repos().await;

    let http_client = Arc::new(AlwaysSuccessMigrationHttpClient::default());
    let state =
        build_migration_test_state_with_mock_http(customer_repo, tenant_repo, vm_repo, http_client)
            .await;
    let app = api::router::build_router(state);

    let req = Request::builder()
        .method("POST")
        .uri("/admin/migrations/probe/rollback-after-replication")
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::to_string(&json!({
                "index_name": index_name,
                "dest_vm_id": dest_vm_id
            }))
            .unwrap(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
    let json = body_json(resp).await;
    assert_eq!(
        json,
        serde_json::json!({"error": "engine index identity probe recovery seams are disabled"})
    );
}

#[tokio::test(flavor = "current_thread")]
async fn admin_probe_recovery_seams_drive_replicating_rollback_and_failure_cleanup() {
    let _guard = PROBE_SEAM_ENV_LOCK.lock().await;
    std::env::set_var("ENGINE_INDEX_IDENTITY_PROBE_RECOVERY_SEAMS", "1");
    let (customer_repo, tenant_repo, vm_repo, _source_vm_id, dest_vm_id, index_name) =
        seed_cross_provider_repos().await;

    let http_client = Arc::new(AlwaysSuccessMigrationHttpClient::default());
    http_client.queue_begin_replication_then_delete();
    http_client.queue_begin_replication_then_recover();

    let state = build_migration_test_state_with_mock_http(
        customer_repo,
        tenant_repo,
        vm_repo,
        http_client.clone(),
    )
    .await;
    let app = api::router::build_router(state);
    let body = serde_json::to_string(&json!({
        "index_name": index_name,
        "dest_vm_id": dest_vm_id
    }))
    .unwrap();

    let rollback_req = Request::builder()
        .method("POST")
        .uri("/admin/migrations/probe/rollback-after-replication")
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(body.clone()))
        .unwrap();
    let rollback_resp = app.clone().oneshot(rollback_req).await.unwrap();
    assert_eq!(rollback_resp.status(), StatusCode::OK);
    let rollback_body = body_json(rollback_resp).await;
    assert_eq!(rollback_body["status"].as_str(), Some("rolled_back"));
    assert_eq!(
        rollback_body["scenario"].as_str(),
        Some("rollback_after_replication")
    );

    let failure_req = Request::builder()
        .method("POST")
        .uri("/admin/migrations/probe/failure-after-replication")
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(body))
        .unwrap();
    let failure_resp = app.oneshot(failure_req).await.unwrap();
    assert_eq!(failure_resp.status(), StatusCode::OK);
    let failure_body = body_json(failure_resp).await;
    assert_eq!(failure_body["status"].as_str(), Some("failed"));
    assert_eq!(
        failure_body["scenario"].as_str(),
        Some("failure_after_replication")
    );

    let requests = http_client.recorded_requests();
    let delete_count = requests
        .iter()
        .filter(|request| {
            request.method == reqwest::Method::DELETE && request.url.contains("/1/indexes/")
        })
        .count();
    assert_eq!(
        delete_count, 2,
        "rollback and failure cleanup should both delete the destination index: {requests:#?}"
    );
    std::env::remove_var("ENGINE_INDEX_IDENTITY_PROBE_RECOVERY_SEAMS");
}

#[tokio::test]
async fn admin_cross_provider_migration_rejects_same_provider() {
    let (customer_repo, tenant_repo, vm_repo, _source_vm_id, dest_vm_id, index_name) =
        seed_same_provider_repos().await;

    let http_client = Arc::new(AlwaysSuccessMigrationHttpClient::default());
    http_client.queue_successful_protocol();
    let state =
        build_migration_test_state_with_mock_http(customer_repo, tenant_repo, vm_repo, http_client)
            .await;
    let app = api::router::build_router(state);

    let req = Request::builder()
        .method("POST")
        .uri("/admin/migrations/cross-provider")
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::to_string(&json!({
                "index_name": index_name,
                "dest_vm_id": dest_vm_id
            }))
            .unwrap(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let json = body_json(resp).await;
    let message = json["error"].as_str().unwrap_or_default();
    assert!(
        message.contains("same-provider"),
        "expected same-provider rejection, got: {message}"
    );
}

#[tokio::test]
async fn admin_migrations_post_rejects_inactive_source_vm() {
    let (customer_repo, tenant_repo, vm_repo, source_vm_id, dest_vm_id, index_name) =
        seed_same_provider_repos().await;
    vm_repo
        .set_status(source_vm_id, "stopped")
        .await
        .expect("set source vm status");

    let state = build_migration_test_state(customer_repo, tenant_repo, vm_repo);
    let app = api::router::build_router(state);

    let req = Request::builder()
        .method("POST")
        .uri("/admin/migrations")
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::to_string(&json!({
                "index_name": index_name,
                "dest_vm_id": dest_vm_id
            }))
            .unwrap(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let json = body_json(resp).await;
    let message = json["error"].as_str().unwrap_or_default();
    assert!(
        message.contains("source VM must be active"),
        "expected inactive source rejection, got: {message}"
    );
}
