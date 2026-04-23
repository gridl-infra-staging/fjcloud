mod common;

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use api::repos::tenant_repo::TenantRepo;
use api::secrets::NodeSecretManager;
use api::services::flapjack_proxy::{
    FlapjackHttpClient, FlapjackHttpRequest, FlapjackHttpResponse, FlapjackProxy, ProxyError,
};
use async_trait::async_trait;
use axum::body::Body;
use axum::http::{self, Request, StatusCode};
use common::{
    create_test_jwt, mock_deployment_repo, mock_flapjack_proxy, mock_repo, mock_tenant_repo,
    mock_vm_inventory_repo, test_app_with_indexes, test_app_with_indexes_and_vm_inventory,
};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use tower::ServiceExt;
use uuid::Uuid;

async fn response_json(resp: axum::http::Response<Body>) -> (StatusCode, Value) {
    let status = resp.status();
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let json: Value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
    (status, json)
}

#[derive(Default)]
struct MockFlapjackHttpClient {
    requests: Mutex<Vec<FlapjackHttpRequest>>,
    responses: Mutex<VecDeque<Result<FlapjackHttpResponse, ProxyError>>>,
}

impl MockFlapjackHttpClient {
    fn request_count(&self) -> usize {
        self.requests.lock().unwrap().len()
    }

    fn push_json_response(&self, status: u16, body: serde_json::Value) {
        self.responses
            .lock()
            .unwrap()
            .push_back(Ok(FlapjackHttpResponse {
                status,
                body: body.to_string(),
            }));
    }
}

#[async_trait]
impl FlapjackHttpClient for MockFlapjackHttpClient {
    async fn send(&self, request: FlapjackHttpRequest) -> Result<FlapjackHttpResponse, ProxyError> {
        self.requests.lock().unwrap().push(request);
        Ok(self
            .responses
            .lock()
            .unwrap()
            .pop_front()
            .unwrap_or_else(|| {
                Ok(FlapjackHttpResponse {
                    status: 200,
                    body: json!({"hits": [], "nbHits": 0}).to_string(),
                })
            })?)
    }
}

struct SearchSetup {
    app: axum::Router,
    customer_id: Uuid,
    deployment_id: Uuid,
    vm_id: Uuid,
    jwt: String,
    tenant_repo: Arc<common::MockTenantRepo>,
    http_client: Arc<MockFlapjackHttpClient>,
}

async fn setup_search_app(index_names: &[&str]) -> SearchSetup {
    use api::models::vm_inventory::NewVmInventory;
    use api::repos::vm_inventory_repo::VmInventoryRepo;

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let node_secret_manager = Arc::new(api::secrets::mock::MockNodeSecretManager::new());
    let http_client = Arc::new(MockFlapjackHttpClient::default());

    let customer = customer_repo.seed("Alice", "alice@example.com");
    let jwt = create_test_jwt(customer.id);

    node_secret_manager
        .create_node_api_key("node-a1", "us-east-1")
        .await
        .unwrap();

    let deployment = deployment_repo.seed_provisioned(
        customer.id,
        "node-a1",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("https://vm-test.flapjack.foo"),
    );
    tenant_repo.seed_deployment(
        deployment.id,
        "us-east-1",
        Some("https://vm-test.flapjack.foo"),
        "healthy",
        "running",
    );

    // Register the VM in vm_inventory so resolve_flapjack_target can find it
    let vm = vm_inventory_repo
        .create(NewVmInventory {
            region: "us-east-1".to_string(),
            provider: "aws".to_string(),
            hostname: "vm-test.flapjack.foo".to_string(),
            flapjack_url: "https://vm-test.flapjack.foo".to_string(),
            capacity: serde_json::json!({
                "cpu_weight": 4.0,
                "mem_rss_bytes": 8_589_934_592_u64,
                "disk_bytes": 107_374_182_400_u64,
                "query_rps": 500.0,
                "indexing_rps": 200.0
            }),
        })
        .await
        .unwrap();

    for index_name in index_names {
        tenant_repo
            .create(customer.id, index_name, deployment.id)
            .await
            .unwrap();
        // Set vm_id so the search/key-create handlers can resolve the flapjack target
        tenant_repo
            .set_vm_id(customer.id, index_name, vm.id)
            .await
            .unwrap();
    }

    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client(
        http_client.clone(),
        node_secret_manager,
    ));
    let app = test_app_with_indexes_and_vm_inventory(
        customer_repo,
        deployment_repo,
        tenant_repo.clone(),
        flapjack_proxy,
        vm_inventory_repo,
    );

    SearchSetup {
        app,
        customer_id: customer.id,
        deployment_id: deployment.id,
        vm_id: vm.id,
        jwt,
        tenant_repo,
        http_client,
    }
}

async fn post_search(app: axum::Router, jwt: &str, index_name: &str) -> axum::http::Response<Body> {
    app.oneshot(
        Request::builder()
            .method(http::Method::POST)
            .uri(format!("/indexes/{index_name}/search"))
            .header("content-type", "application/json")
            .header("authorization", format!("Bearer {jwt}"))
            .body(Body::from(json!({"query": "hello"}).to_string()))
            .unwrap(),
    )
    .await
    .unwrap()
}

#[tokio::test]
async fn quota_enforcement_rejects_excess_indexes() {
    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();

    let customer = customer_repo.seed_verified_shared_customer("Alice", "alice@example.com");
    let jwt = create_test_jwt(customer.id);

    let deployment = deployment_repo.seed_provisioned(
        customer.id,
        "node-a1",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("https://vm-test.flapjack.foo"),
    );
    tenant_repo.seed_deployment(
        deployment.id,
        "us-east-1",
        Some("https://vm-test.flapjack.foo"),
        "healthy",
        "running",
    );

    // Stage 7 default tenant quota is max_indexes=10.
    for i in 0..10 {
        tenant_repo
            .create(customer.id, &format!("index-{i}"), deployment.id)
            .await
            .unwrap();
    }

    let app = test_app_with_indexes(
        customer_repo,
        deployment_repo,
        tenant_repo,
        mock_flapjack_proxy(),
    );

    let resp = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/indexes")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(
                    json!({"name": "one-too-many", "region": "us-east-1"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(
        body["error"].as_str().unwrap_or("").contains("max 10"),
        "error should report the max_indexes quota"
    );
}

#[tokio::test]
async fn proxy_throttles_tenant_at_query_rate_limit() {
    let setup = setup_search_app(&["searchable"]).await;
    setup
        .tenant_repo
        .set_resource_quota(
            setup.customer_id,
            "searchable",
            json!({"max_query_rps": 1, "max_write_rps": 50}),
        )
        .await
        .unwrap();

    setup
        .http_client
        .push_json_response(200, json!({"hits": [{"id": "1"}], "nbHits": 1}));

    let first = post_search(setup.app.clone(), &setup.jwt, "searchable").await;
    assert_eq!(first.status(), StatusCode::OK);

    let second = post_search(setup.app.clone(), &setup.jwt, "searchable").await;
    assert_eq!(second.status(), StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(
        setup.http_client.request_count(),
        1,
        "second request should be throttled before proxying"
    );
}

#[tokio::test]
async fn proxy_throttle_does_not_affect_other_tenants() {
    use api::models::vm_inventory::NewVmInventory;
    use api::repos::vm_inventory_repo::VmInventoryRepo;

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let node_secret_manager = Arc::new(api::secrets::mock::MockNodeSecretManager::new());
    let http_client = Arc::new(MockFlapjackHttpClient::default());

    let alice = customer_repo.seed("Alice", "alice@example.com");
    let bob = customer_repo.seed("Bob", "bob@example.com");
    let alice_jwt = create_test_jwt(alice.id);
    let bob_jwt = create_test_jwt(bob.id);

    node_secret_manager
        .create_node_api_key("node-a1", "us-east-1")
        .await
        .unwrap();
    node_secret_manager
        .create_node_api_key("node-b1", "us-east-1")
        .await
        .unwrap();

    // Register shared VM in vm_inventory
    let vm = vm_inventory_repo
        .create(NewVmInventory {
            region: "us-east-1".to_string(),
            provider: "aws".to_string(),
            hostname: "vm-shared.flapjack.foo".to_string(),
            flapjack_url: "https://vm-shared.flapjack.foo".to_string(),
            capacity: serde_json::json!({
                "cpu_weight": 4.0,
                "mem_rss_bytes": 8_589_934_592_u64,
                "disk_bytes": 107_374_182_400_u64,
                "query_rps": 500.0,
                "indexing_rps": 200.0
            }),
        })
        .await
        .unwrap();

    let alice_deployment = deployment_repo.seed_provisioned(
        alice.id,
        "node-a1",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("https://vm-shared.flapjack.foo"),
    );
    tenant_repo.seed_deployment(
        alice_deployment.id,
        "us-east-1",
        Some("https://vm-shared.flapjack.foo"),
        "healthy",
        "running",
    );

    let bob_deployment = deployment_repo.seed_provisioned(
        bob.id,
        "node-b1",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("https://vm-shared.flapjack.foo"),
    );
    tenant_repo.seed_deployment(
        bob_deployment.id,
        "us-east-1",
        Some("https://vm-shared.flapjack.foo"),
        "healthy",
        "running",
    );

    tenant_repo
        .create(alice.id, "shared-index", alice_deployment.id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(alice.id, "shared-index", vm.id)
        .await
        .unwrap();
    tenant_repo
        .create(bob.id, "shared-index", bob_deployment.id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(bob.id, "shared-index", vm.id)
        .await
        .unwrap();
    tenant_repo
        .set_resource_quota(
            alice.id,
            "shared-index",
            json!({"max_query_rps": 1, "max_write_rps": 50}),
        )
        .await
        .unwrap();

    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client(
        http_client.clone(),
        node_secret_manager,
    ));
    let app = test_app_with_indexes_and_vm_inventory(
        customer_repo,
        deployment_repo,
        tenant_repo,
        flapjack_proxy,
        vm_inventory_repo,
    );

    let alice_first = post_search(app.clone(), &alice_jwt, "shared-index").await;
    assert_eq!(alice_first.status(), StatusCode::OK);
    let alice_second = post_search(app.clone(), &alice_jwt, "shared-index").await;
    assert_eq!(alice_second.status(), StatusCode::TOO_MANY_REQUESTS);

    let bob_first = post_search(app.clone(), &bob_jwt, "shared-index").await;
    assert_eq!(
        bob_first.status(),
        StatusCode::OK,
        "tenant B should not be throttled by tenant A's overage"
    );
    assert_eq!(
        http_client.request_count(),
        2,
        "only successful requests should reach flapjack"
    );
}

#[tokio::test]
async fn proxy_throttle_uses_per_index_quota_override() {
    let setup = setup_search_app(&["strict-index", "default-index"]).await;
    setup
        .tenant_repo
        .set_resource_quota(
            setup.customer_id,
            "strict-index",
            json!({"max_query_rps": 1, "max_write_rps": 50}),
        )
        .await
        .unwrap();

    let strict_first = post_search(setup.app.clone(), &setup.jwt, "strict-index").await;
    assert_eq!(strict_first.status(), StatusCode::OK);
    let strict_second = post_search(setup.app.clone(), &setup.jwt, "strict-index").await;
    assert_eq!(strict_second.status(), StatusCode::TOO_MANY_REQUESTS);

    let default_first = post_search(setup.app.clone(), &setup.jwt, "default-index").await;
    assert_eq!(default_first.status(), StatusCode::OK);
    let default_second = post_search(setup.app.clone(), &setup.jwt, "default-index").await;
    assert_eq!(default_second.status(), StatusCode::OK);
}

#[tokio::test]
async fn proxy_throttle_429_includes_retry_after() {
    let setup = setup_search_app(&["retry-index"]).await;
    setup
        .tenant_repo
        .set_resource_quota(
            setup.customer_id,
            "retry-index",
            json!({"max_query_rps": 1, "max_write_rps": 50}),
        )
        .await
        .unwrap();

    let _ = post_search(setup.app.clone(), &setup.jwt, "retry-index").await;
    let second = post_search(setup.app, &setup.jwt, "retry-index").await;

    assert_eq!(second.status(), StatusCode::TOO_MANY_REQUESTS);
    assert!(
        second.headers().get("retry-after").is_some(),
        "throttled response should include retry-after"
    );
}

#[tokio::test]
async fn unknown_index_quota_lookup_does_not_poison_future_quota_cache() {
    let setup = setup_search_app(&[]).await;

    let missing = post_search(setup.app.clone(), &setup.jwt, "late-index").await;
    assert_eq!(
        missing.status(),
        StatusCode::NOT_FOUND,
        "unknown index should return 404"
    );

    setup
        .tenant_repo
        .create(setup.customer_id, "late-index", setup.deployment_id)
        .await
        .unwrap();
    setup
        .tenant_repo
        .set_vm_id(setup.customer_id, "late-index", setup.vm_id)
        .await
        .unwrap();
    setup
        .tenant_repo
        .set_resource_quota(
            setup.customer_id,
            "late-index",
            json!({"max_query_rps": 1, "max_write_rps": 50}),
        )
        .await
        .unwrap();

    setup
        .http_client
        .push_json_response(200, json!({"hits": [{"id": "1"}], "nbHits": 1}));

    let first = post_search(setup.app.clone(), &setup.jwt, "late-index").await;
    assert_eq!(first.status(), StatusCode::OK);

    let second = post_search(setup.app.clone(), &setup.jwt, "late-index").await;
    assert_eq!(
        second.status(),
        StatusCode::TOO_MANY_REQUESTS,
        "newly created index should honor strict quota immediately"
    );

    assert_eq!(
        setup.http_client.request_count(),
        1,
        "second request should be throttled before proxying"
    );
}

#[tokio::test]
async fn zero_query_quota_override_is_clamped_safely() {
    let setup = setup_search_app(&["products"]).await;
    setup
        .tenant_repo
        .set_resource_quota(
            setup.customer_id,
            "products",
            json!({"max_query_rps": 0, "max_write_rps": 50}),
        )
        .await
        .unwrap();

    let resp = post_search(setup.app, &setup.jwt, "products").await;
    assert_eq!(
        resp.status(),
        StatusCode::OK,
        "invalid zero quota must not trigger a panic/500"
    );
}

// ---------------------------------------------------------------------------
// Write rate throttling
// ---------------------------------------------------------------------------

async fn post_create_key(
    app: axum::Router,
    jwt: &str,
    index_name: &str,
) -> axum::http::Response<Body> {
    app.oneshot(
        Request::builder()
            .method(http::Method::POST)
            .uri(format!("/indexes/{index_name}/keys"))
            .header("content-type", "application/json")
            .header("authorization", format!("Bearer {jwt}"))
            .body(Body::from(
                json!({"description": "test key", "acl": ["search"]}).to_string(),
            ))
            .unwrap(),
    )
    .await
    .unwrap()
}

#[tokio::test]
async fn proxy_throttles_tenant_at_write_rate_limit() {
    let setup = setup_search_app(&["writable"]).await;
    setup
        .tenant_repo
        .set_resource_quota(
            setup.customer_id,
            "writable",
            json!({"max_query_rps": 100, "max_write_rps": 1}),
        )
        .await
        .unwrap();

    // First create_key succeeds
    setup.http_client.push_json_response(
        200,
        json!({"key": "fj_key_123", "createdAt": "2026-02-22T00:00:00Z"}),
    );
    let first = post_create_key(setup.app.clone(), &setup.jwt, "writable").await;
    let (first_status, first_body) = response_json(first).await;
    assert_eq!(
        first_status,
        StatusCode::CREATED,
        "first create_key failed: {first_body}"
    );

    // Second create_key within the same window should be throttled
    let second = post_create_key(setup.app.clone(), &setup.jwt, "writable").await;
    assert_eq!(
        second.status(),
        StatusCode::TOO_MANY_REQUESTS,
        "write rate limit should throttle excess writes"
    );
    assert!(
        second.headers().get("retry-after").is_some(),
        "throttled write response should include retry-after"
    );
    assert_eq!(
        setup.http_client.request_count(),
        1,
        "second write request should be throttled before reaching flapjack"
    );
}

// ---------------------------------------------------------------------------
// Admin quota management
// ---------------------------------------------------------------------------

#[tokio::test]
async fn admin_get_quotas_returns_defaults_and_overrides() {
    let setup = setup_search_app(&["default-index", "strict-index"]).await;
    setup
        .tenant_repo
        .set_resource_quota(
            setup.customer_id,
            "strict-index",
            json!({"max_query_rps": 7, "max_storage_bytes": 777}),
        )
        .await
        .unwrap();

    let resp = setup
        .app
        .clone()
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri(format!("/admin/tenants/{}/quotas", setup.customer_id))
                .header("x-admin-key", common::TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);

    assert_eq!(body["defaults"]["max_query_rps"], 10);
    assert_eq!(body["defaults"]["max_write_rps"], 10);
    assert_eq!(body["defaults"]["max_storage_bytes"], 10_737_418_240u64);
    assert_eq!(body["defaults"]["max_indexes"], 10);

    let indexes = body["indexes"]
        .as_array()
        .expect("indexes should be an array");
    assert_eq!(indexes.len(), 2);

    let by_name = indexes
        .iter()
        .map(|row| (row["index_name"].as_str().unwrap(), row))
        .collect::<std::collections::HashMap<_, _>>();

    let default = by_name
        .get("default-index")
        .expect("default-index row missing");
    assert_eq!(default["effective"]["max_query_rps"], 10);
    assert_eq!(default["effective"]["max_write_rps"], 10);
    assert_eq!(default["effective"]["max_storage_bytes"], 10_737_418_240u64);
    assert_eq!(default["effective"]["max_indexes"], 10);
    assert_eq!(default["override"], json!({}));

    let strict = by_name
        .get("strict-index")
        .expect("strict-index row missing");
    assert_eq!(strict["effective"]["max_query_rps"], 7);
    assert_eq!(strict["effective"]["max_write_rps"], 10);
    assert_eq!(strict["effective"]["max_storage_bytes"], 777);
    assert_eq!(strict["effective"]["max_indexes"], 10);
    assert_eq!(
        strict["override"],
        json!({"max_query_rps": 7, "max_storage_bytes": 777})
    );
}

#[tokio::test]
async fn admin_put_quotas_updates_resource_quota() {
    let setup = setup_search_app(&["alpha", "beta"]).await;

    let update_body = json!({
        "max_query_rps": 21,
        "max_write_rps": 9,
        "max_storage_bytes": 12345,
        "max_indexes": 3
    });

    let put_resp = setup
        .app
        .clone()
        .oneshot(
            Request::builder()
                .method(http::Method::PUT)
                .uri(format!("/admin/tenants/{}/quotas", setup.customer_id))
                .header("x-admin-key", common::TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(update_body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (put_status, _) = response_json(put_resp).await;
    assert_eq!(put_status, StatusCode::OK);

    let get_resp = setup
        .app
        .clone()
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri(format!("/admin/tenants/{}/quotas", setup.customer_id))
                .header("x-admin-key", common::TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (get_status, body) = response_json(get_resp).await;
    assert_eq!(get_status, StatusCode::OK);
    let indexes = body["indexes"]
        .as_array()
        .expect("indexes should be an array");
    assert_eq!(indexes.len(), 2);
    for row in indexes {
        assert_eq!(row["effective"]["max_query_rps"], 21);
        assert_eq!(row["effective"]["max_write_rps"], 9);
        assert_eq!(row["effective"]["max_storage_bytes"], 12345);
        assert_eq!(row["effective"]["max_indexes"], 3);
        assert_eq!(row["override"], update_body);
    }

    let raw_rows = setup
        .tenant_repo
        .list_raw_by_customer(setup.customer_id)
        .await
        .expect("list_raw_by_customer should succeed");
    assert_eq!(raw_rows.len(), 2);
    for row in raw_rows {
        assert_eq!(row.resource_quota, update_body);
    }
}

#[tokio::test]
async fn admin_put_quotas_rejects_empty_update() {
    let setup = setup_search_app(&["alpha"]).await;

    let resp = setup
        .app
        .clone()
        .oneshot(
            Request::builder()
                .method(http::Method::PUT)
                .uri(format!("/admin/tenants/{}/quotas", setup.customer_id))
                .header("x-admin-key", common::TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(json!({}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(
        body["error"]
            .as_str()
            .unwrap_or("")
            .contains("no fields to update"),
        "empty update body should be rejected"
    );
}

#[tokio::test]
async fn admin_put_quotas_returns_404_for_unknown_tenant() {
    let setup = setup_search_app(&["alpha"]).await;
    let unknown_id = Uuid::new_v4();

    let resp = setup
        .app
        .clone()
        .oneshot(
            Request::builder()
                .method(http::Method::PUT)
                .uri(format!("/admin/tenants/{unknown_id}/quotas"))
                .header("x-admin-key", common::TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(json!({"max_query_rps": 42}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, _) = response_json(resp).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn admin_get_quotas_returns_404_for_unknown_tenant() {
    let setup = setup_search_app(&["alpha"]).await;
    let unknown_id = Uuid::new_v4();

    let resp = setup
        .app
        .clone()
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri(format!("/admin/tenants/{unknown_id}/quotas"))
                .header("x-admin-key", common::TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, _) = response_json(resp).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}
