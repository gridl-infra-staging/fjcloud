mod common;

use std::sync::{Arc, Mutex};
use std::time::Duration;

use api::models::cold_snapshot::NewColdSnapshot;
use api::models::vm_inventory::NewVmInventory;
use api::repos::{
    ColdSnapshotRepo, InMemoryColdSnapshotRepo, InMemoryRestoreJobRepo, RestoreJobRepo, TenantRepo,
    VmInventoryRepo,
};
use api::services::alerting::MockAlertService;
use api::services::cold_tier::{ColdTierError, FlapjackNodeClient};
use api::services::discovery::DiscoveryService;
use api::services::object_store::{InMemoryObjectStore, ObjectStore, RegionObjectStoreResolver};
use api::services::restore::{RestoreConfig, RestoreService};
use async_trait::async_trait;
use axum::body::Body;
use axum::http::{self, Request, StatusCode};
use http_body_util::BodyExt;
use serde_json::json;
use tower::ServiceExt;
use uuid::Uuid;

struct MockRestoreNodeClient {
    import_calls: Mutex<Vec<(String, String, String)>>,
    verify_calls: Mutex<Vec<(String, String, String)>>,
}

impl MockRestoreNodeClient {
    fn new() -> Self {
        Self {
            import_calls: Mutex::new(Vec::new()),
            verify_calls: Mutex::new(Vec::new()),
        }
    }

    fn import_call_count(&self) -> usize {
        self.import_calls.lock().unwrap().len()
    }

    fn verify_call_count(&self) -> usize {
        self.verify_calls.lock().unwrap().len()
    }
}

#[async_trait]
impl FlapjackNodeClient for MockRestoreNodeClient {
    async fn export_index(
        &self,
        _flapjack_url: &str,
        _index_name: &str,
        _api_key: &str,
    ) -> Result<Vec<u8>, ColdTierError> {
        Ok(Vec::new())
    }

    async fn delete_index(
        &self,
        _flapjack_url: &str,
        _index_name: &str,
        _api_key: &str,
    ) -> Result<(), ColdTierError> {
        Ok(())
    }

    async fn import_index(
        &self,
        flapjack_url: &str,
        index_name: &str,
        _data: &[u8],
        api_key: &str,
    ) -> Result<(), ColdTierError> {
        self.import_calls.lock().unwrap().push((
            flapjack_url.to_string(),
            index_name.to_string(),
            api_key.to_string(),
        ));
        Ok(())
    }

    async fn verify_index(
        &self,
        flapjack_url: &str,
        index_name: &str,
        api_key: &str,
    ) -> Result<(), ColdTierError> {
        self.verify_calls.lock().unwrap().push((
            flapjack_url.to_string(),
            index_name.to_string(),
            api_key.to_string(),
        ));
        Ok(())
    }
}

async fn response_json(resp: axum::http::Response<Body>) -> (StatusCode, serde_json::Value) {
    let status = resp.status();
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let body = serde_json::from_slice(&bytes).unwrap_or_else(|_| json!({}));
    (status, body)
}

struct RestoreRouteHarness {
    app: axum::Router,
    customer_id: Uuid,
    snapshot_id: Uuid,
    jwt: String,
    tenant_repo: Arc<common::MockTenantRepo>,
    restore_job_repo: Arc<InMemoryRestoreJobRepo>,
    node_client: Arc<MockRestoreNodeClient>,
}

async fn setup_restore_route_harness() -> RestoreRouteHarness {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let tenant_repo = common::mock_tenant_repo();
    let vm_inventory_repo = common::mock_vm_inventory_repo();

    let customer = customer_repo.seed("ColdCo", "cold@example.com");
    let jwt = common::create_test_jwt(customer.id);

    let deployment_id = Uuid::new_v4();
    tenant_repo.seed_deployment(
        deployment_id,
        "us-east-1",
        Some("http://legacy-vm.flapjack.foo"),
        "healthy",
        "running",
    );

    tenant_repo
        .create(customer.id, "cold-index", deployment_id)
        .await
        .expect("seed tenant");

    let vm = vm_inventory_repo
        .create(NewVmInventory {
            region: "us-east-1".to_string(),
            provider: "aws".to_string(),
            hostname: "restore-vm.flapjack.foo".to_string(),
            flapjack_url: "http://restore-vm.flapjack.foo".to_string(),
            capacity: json!({
                "cpu": 100.0,
                "memory_mb": 4096.0,
                "disk_gb": 100.0
            }),
        })
        .await
        .expect("seed vm");
    vm_inventory_repo
        .update_load(
            vm.id,
            json!({
                "cpu_weight": 0.0,
                "mem_rss_bytes": 0_u64,
                "disk_bytes": 0_u64,
                "query_rps": 0.0,
                "indexing_rps": 0.0
            }),
        )
        .await
        .expect("mark restore target vm as freshly scraped");

    let cold_snapshot_repo = Arc::new(InMemoryColdSnapshotRepo::new());
    let restore_job_repo = Arc::new(InMemoryRestoreJobRepo::new());
    let object_store = Arc::new(InMemoryObjectStore::new());

    let snapshot = cold_snapshot_repo
        .create(NewColdSnapshot {
            customer_id: customer.id,
            tenant_id: "cold-index".to_string(),
            source_vm_id: vm.id,
            object_key: format!("cold/{}/{}/snapshot.fj", customer.id, "cold-index"),
        })
        .await
        .expect("create snapshot");
    cold_snapshot_repo
        .set_exporting(snapshot.id)
        .await
        .expect("set exporting");
    cold_snapshot_repo
        .set_completed(snapshot.id, 1024, "abc123")
        .await
        .expect("set completed");

    object_store
        .put(&snapshot.object_key, b"snapshot-bytes")
        .await
        .expect("store snapshot bytes");

    tenant_repo
        .set_tier(customer.id, "cold-index", "cold")
        .await
        .expect("set cold tier");
    tenant_repo
        .set_cold_snapshot_id(customer.id, "cold-index", Some(snapshot.id))
        .await
        .expect("set cold snapshot id");
    tenant_repo
        .clear_vm_id(customer.id, "cold-index")
        .await
        .expect("clear vm id");

    let node_client = Arc::new(MockRestoreNodeClient::new());
    let discovery_service = Arc::new(DiscoveryService::with_ttl(
        tenant_repo.clone(),
        vm_inventory_repo.clone(),
        3600,
    ));

    let restore_service = Arc::new(RestoreService::new(
        RestoreConfig::default(),
        tenant_repo.clone(),
        cold_snapshot_repo,
        restore_job_repo.clone(),
        vm_inventory_repo.clone(),
        Arc::new(RegionObjectStoreResolver::single(object_store)),
        Arc::new(MockAlertService::new()),
        discovery_service,
        node_client.clone(),
        common::mock_node_secret_manager(),
    ));

    let mut state = common::test_state_with_indexes_and_vm_inventory(
        customer_repo,
        deployment_repo,
        tenant_repo.clone(),
        common::mock_flapjack_proxy(),
        vm_inventory_repo,
    );
    state.restore_service = Some(restore_service);

    RestoreRouteHarness {
        app: api::router::build_router(state),
        customer_id: customer.id,
        snapshot_id: snapshot.id,
        jwt,
        tenant_repo,
        restore_job_repo,
        node_client,
    }
}

#[tokio::test]
async fn restore_endpoint_queues_and_completes_restore_job() {
    let h = setup_restore_route_harness().await;

    let resp = h
        .app
        .clone()
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/cold-index/restore")
                .header("authorization", format!("Bearer {}", h.jwt))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::ACCEPTED);
    assert_eq!(body["status"], "queued");
    assert_eq!(body["poll_url"], "/indexes/cold-index/restore-status");

    let job_id = Uuid::parse_str(
        body["restore_job_id"]
            .as_str()
            .expect("restore_job_id should be string"),
    )
    .expect("restore_job_id should be a uuid");

    let mut completed = false;
    for _ in 0..40 {
        if let Some(job) = h
            .restore_job_repo
            .get(job_id)
            .await
            .expect("get restore job")
        {
            if job.status == "completed" {
                completed = true;
                break;
            }
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }

    assert!(completed, "restore job should complete in background task");

    let tenant = h
        .tenant_repo
        .find_raw(h.customer_id, "cold-index")
        .await
        .expect("find tenant")
        .expect("tenant should exist");

    assert_eq!(tenant.tier, "active");
    assert!(
        tenant.vm_id.is_some(),
        "restore should assign a destination vm"
    );
    assert!(
        tenant.cold_snapshot_id.is_none(),
        "restore should clear cold_snapshot_id"
    );

    assert_eq!(h.node_client.import_call_count(), 1);
    assert_eq!(h.node_client.verify_call_count(), 1);
}

#[tokio::test]
async fn search_on_cold_index_returns_410_with_restore_url() {
    let h = setup_restore_route_harness().await;

    let resp = h
        .app
        .clone()
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/cold-index/search")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {}", h.jwt))
                .body(Body::from(json!({"query": "hello"}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::GONE);
    assert_eq!(body["error"], "index_cold");
    assert_eq!(body["restore_url"], "/indexes/cold-index/restore");
}

#[tokio::test]
async fn search_on_restoring_index_returns_503_with_poll_url() {
    let h = setup_restore_route_harness().await;

    h.tenant_repo
        .set_tier(h.customer_id, "cold-index", "restoring")
        .await
        .expect("set restoring tier");

    let resp = h
        .app
        .clone()
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/cold-index/search")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {}", h.jwt))
                .body(Body::from(json!({"query": "hello"}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(
        resp.headers()
            .get("retry-after")
            .and_then(|v| v.to_str().ok()),
        Some("30")
    );

    let (_, body) = response_json(resp).await;
    assert_eq!(body["error"], "index_restoring");
    assert_eq!(body["poll_url"], "/indexes/cold-index/restore-status");
}

#[tokio::test]
async fn admin_cold_routes_are_registered() {
    let h = setup_restore_route_harness().await;

    let list_resp = h
        .app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/admin/cold")
                .header("x-admin-key", common::TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (list_status, list_body) = response_json(list_resp).await;
    assert_eq!(list_status, StatusCode::OK);
    assert_eq!(list_body.as_array().map(|a| a.len()), Some(1));

    let restore_resp = h
        .app
        .clone()
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri(format!("/admin/cold/{}/restore", h.snapshot_id))
                .header("x-admin-key", common::TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (restore_status, restore_body) = response_json(restore_resp).await;
    assert_eq!(restore_status, StatusCode::ACCEPTED);
    assert!(restore_body["restore_job_id"].is_string());
}

#[tokio::test]
async fn restore_status_endpoint_returns_active_job() {
    let h = setup_restore_route_harness().await;

    // Initiate a restore so there's an active job
    let restore_resp = h
        .app
        .clone()
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/cold-index/restore")
                .header("authorization", format!("Bearer {}", h.jwt))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(restore_resp).await;
    assert_eq!(status, StatusCode::ACCEPTED);
    let job_id = body["restore_job_id"].as_str().unwrap();

    // Poll restore-status — should return the active job
    let status_resp = h
        .app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/indexes/cold-index/restore-status")
                .header("authorization", format!("Bearer {}", h.jwt))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(status_resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["restore_job_id"], job_id);
    assert!(
        body["estimated_completion_at"].is_string(),
        "restore-status should include estimated completion timestamp"
    );
    assert!(
        ["queued", "downloading", "importing", "completed"]
            .contains(&body["status"].as_str().unwrap()),
        "status should be a valid restore job status"
    );
}

#[tokio::test]
async fn restore_status_endpoint_returns_404_when_no_restore() {
    let h = setup_restore_route_harness().await;

    // No restore initiated — should return 404
    let resp = h
        .app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/indexes/cold-index/restore-status")
                .header("authorization", format!("Bearer {}", h.jwt))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}
