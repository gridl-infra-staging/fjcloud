use std::collections::BTreeSet;
use std::sync::Arc;

use api::models::vm_inventory::{NewVmInventory, VmInventory};
use api::repos::{TenantRepo, VmInventoryRepo};
use api::router::build_router;
use api::secrets::mock::MockNodeSecretManager;
use api::secrets::NodeSecretManager;
use api::services::flapjack_proxy::FlapjackProxy;
use axum::body::Body;
use axum::http::{self, Request, StatusCode};
use serde_json::{json, Value};
use tower::ServiceExt;
use uuid::Uuid;

use crate::common::flapjack_proxy_test_support::{test_flapjack_uid, MockFlapjackHttpClient};
use crate::common::indexes_route_test_support::response_json;
use crate::common::{
    create_test_jwt, mock_deployment_repo, mock_repo, mock_tenant_repo, mock_vm_inventory_repo,
    TestStateBuilder,
};

const PRIMARY_HOST_SENTINEL: &str = "primary-private.internal";
const REPLICA_HOST_SENTINEL: &str = "replica-private.internal";
const PRIMARY_URL_SENTINEL: &str = "http://192.0.2.10:7700";
const REPLICA_URL_SENTINEL: &str = "http://198.51.100.20:7700";
const SHARED_NODE_SECRET_SENTINEL: &str = "shared-node-secret-path";
const CAPACITY_SENTINEL: u64 = 424_242_424_242;
const TENANT_A_INDEX: &str = "products";
const TENANT_B_INDEX: &str = "foreign_products";
const TENANT_B_DOCS_SENTINEL: u64 = 987_654;
const TENANT_B_STORAGE_SENTINEL: u64 = 876_543_210;
const TENANT_B_SEARCH_SENTINEL: u64 = 765_432;
const TENANT_B_WRITES_SENTINEL: u64 = 654_321;

struct InfrastructureFixture {
    app: axum::Router,
    jwt: String,
    http_client: Arc<MockFlapjackHttpClient>,
    customer_id: Uuid,
    foreign_customer_id: Uuid,
    primary_vm: VmInventory,
    vm_repo: Arc<crate::common::MockVmInventoryRepo>,
}

fn infrastructure_request(jwt: &str, index_name: &str) -> Request<Body> {
    Request::builder()
        .method(http::Method::GET)
        .uri(format!("/indexes/{index_name}/infrastructure"))
        .header("authorization", format!("Bearer {jwt}"))
        .body(Body::empty())
        .unwrap()
}

fn vector(load_ratio: f64) -> Value {
    json!({
        "cpu_weight": CAPACITY_SENTINEL as f64 * load_ratio,
        "mem_rss_bytes": (CAPACITY_SENTINEL as f64 * load_ratio) as u64,
        "disk_bytes": (CAPACITY_SENTINEL as f64 * load_ratio) as u64,
        "query_rps": CAPACITY_SENTINEL as f64 * load_ratio,
        "indexing_rps": CAPACITY_SENTINEL as f64 * load_ratio,
    })
}

fn capacity_vector() -> Value {
    json!({
        "cpu_weight": CAPACITY_SENTINEL as f64,
        "mem_rss_bytes": CAPACITY_SENTINEL,
        "disk_bytes": CAPACITY_SENTINEL,
        "query_rps": CAPACITY_SENTINEL as f64,
        "indexing_rps": CAPACITY_SENTINEL as f64,
    })
}

fn metrics_fixture(uid: &str, storage_bytes: u64) -> String {
    format!(
        "flapjack_documents_count{{index=\"{uid}\"}} 321\n\
         flapjack_storage_bytes{{index=\"{uid}\"}} {storage_bytes}\n\
         flapjack_search_requests_total{{index=\"{uid}\"}} 9001\n\
         flapjack_documents_indexed_total{{index=\"{uid}\"}} 77\n\
         flapjack_documents_count{{index=\"foreign-uid\"}} 999999\n\
         flapjack_storage_bytes{{index=\"foreign-uid\"}} 999999\n"
    )
}

fn shared_vm_metrics_fixture(tenant_a_uid: &str, tenant_b_uid: &str) -> String {
    format!(
        "flapjack_documents_count{{index=\"{tenant_a_uid}\"}} 321\n\
         flapjack_storage_bytes{{index=\"{tenant_a_uid}\"}} 600\n\
         flapjack_search_requests_total{{index=\"{tenant_a_uid}\"}} 9001\n\
         flapjack_documents_indexed_total{{index=\"{tenant_a_uid}\"}} 77\n\
         flapjack_documents_count{{index=\"{tenant_b_uid}\"}} {TENANT_B_DOCS_SENTINEL}\n\
         flapjack_storage_bytes{{index=\"{tenant_b_uid}\"}} {TENANT_B_STORAGE_SENTINEL}\n\
         flapjack_search_requests_total{{index=\"{tenant_b_uid}\"}} {TENANT_B_SEARCH_SENTINEL}\n\
         flapjack_documents_indexed_total{{index=\"{tenant_b_uid}\"}} {TENANT_B_WRITES_SENTINEL}\n"
    )
}

async fn setup_infrastructure_fixture() -> InfrastructureFixture {
    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_repo = mock_vm_inventory_repo();
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let node_secret_manager = Arc::new(MockNodeSecretManager::new());

    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let foreign_customer = customer_repo.seed_verified_free_customer("Bob", "bob@example.com");
    let jwt = create_test_jwt(customer.id);
    node_secret_manager
        .create_node_api_key(PRIMARY_HOST_SENTINEL, "us-east-1")
        .await
        .unwrap();

    let deployment = deployment_repo.seed_provisioned(
        customer.id,
        SHARED_NODE_SECRET_SENTINEL,
        "us-east-1",
        "shared",
        "aws",
        "running",
        Some(PRIMARY_URL_SENTINEL),
    );
    tenant_repo.seed_deployment(
        deployment.id,
        "us-east-1",
        Some(PRIMARY_URL_SENTINEL),
        "degraded",
        "running",
    );
    tenant_repo
        .create(customer.id, TENANT_A_INDEX, deployment.id)
        .await
        .unwrap();
    tenant_repo
        .set_resource_quota(
            customer.id,
            TENANT_A_INDEX,
            json!({"max_storage_bytes": 1_000_u64}),
        )
        .await
        .unwrap();

    let primary_vm = vm_repo
        .create(NewVmInventory {
            region: "us-east-1".to_string(),
            provider: "aws".to_string(),
            hostname: PRIMARY_HOST_SENTINEL.to_string(),
            flapjack_url: PRIMARY_URL_SENTINEL.to_string(),
            capacity: capacity_vector(),
        })
        .await
        .unwrap();
    vm_repo
        .update_load(primary_vm.id, vector(0.50))
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer.id, TENANT_A_INDEX, primary_vm.id)
        .await
        .unwrap();

    let foreign_deployment = deployment_repo.seed_provisioned(
        foreign_customer.id,
        SHARED_NODE_SECRET_SENTINEL,
        "us-east-1",
        "shared",
        "aws",
        "running",
        Some(PRIMARY_URL_SENTINEL),
    );
    tenant_repo.seed_deployment(
        foreign_deployment.id,
        "us-east-1",
        Some(PRIMARY_URL_SENTINEL),
        "healthy",
        "running",
    );
    tenant_repo
        .create(foreign_customer.id, TENANT_B_INDEX, foreign_deployment.id)
        .await
        .unwrap();
    tenant_repo
        .set_resource_quota(
            foreign_customer.id,
            TENANT_B_INDEX,
            json!({"max_storage_bytes": 9_999_999_999_u64}),
        )
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(foreign_customer.id, TENANT_B_INDEX, primary_vm.id)
        .await
        .unwrap();

    let replica_vm = vm_repo
        .create(NewVmInventory {
            region: "eu-central-1".to_string(),
            provider: "hetzner".to_string(),
            hostname: REPLICA_HOST_SENTINEL.to_string(),
            flapjack_url: REPLICA_URL_SENTINEL.to_string(),
            capacity: capacity_vector(),
        })
        .await
        .unwrap();
    vm_repo
        .update_load(replica_vm.id, vector(0.25))
        .await
        .unwrap();

    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client(
        http_client.clone(),
        node_secret_manager.clone(),
    ));
    let state = TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_deployment_repo(deployment_repo)
        .with_tenant_repo(tenant_repo)
        .with_vm_inventory_repo(vm_repo.clone())
        .with_node_secret_manager(node_secret_manager.clone())
        .with_flapjack_proxy(flapjack_proxy)
        .build();
    let replica_repo = state.index_replica_repo.clone();

    let active_replica = replica_repo
        .create(
            customer.id,
            TENANT_A_INDEX,
            primary_vm.id,
            replica_vm.id,
            "eu-central-1",
        )
        .await
        .unwrap();
    replica_repo
        .set_status(active_replica.id, "active")
        .await
        .unwrap();
    replica_repo.set_lag(active_replica.id, 37).await.unwrap();

    replica_repo
        .create(
            customer.id,
            TENANT_A_INDEX,
            primary_vm.id,
            Uuid::new_v4(),
            "ap-south-1",
        )
        .await
        .unwrap();

    let app = build_router(state);

    InfrastructureFixture {
        app,
        jwt,
        http_client,
        customer_id: customer.id,
        foreign_customer_id: foreign_customer.id,
        primary_vm,
        vm_repo,
    }
}

#[tokio::test]
async fn infrastructure_returns_safe_topology_footprint_refresh_and_headroom() {
    let fixture = setup_infrastructure_fixture().await;
    let uid = test_flapjack_uid(fixture.customer_id, TENANT_A_INDEX);
    fixture
        .http_client
        .push_text_response(200, &metrics_fixture(&uid, 600));

    let resp = fixture
        .app
        .oneshot(infrastructure_request(&fixture.jwt, TENANT_A_INDEX))
        .await
        .unwrap();
    let (status, body) = response_json(resp).await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["index"], TENANT_A_INDEX);
    assert_eq!(body["primary"]["region"], "us-east-1");
    assert_eq!(body["primary"]["status"], "degraded");
    assert_eq!(body["primary"]["utilization"], "yellow");
    assert_eq!(body["minimum_refresh_interval_seconds"], 60);
    assert_eq!(body["headroom"], "busy");
    assert_eq!(body["footprint"]["documents_count"], 321);
    assert_eq!(body["footprint"]["storage_bytes"], 600);
    assert_eq!(body["footprint"]["search_requests_total"], 9001);
    assert_eq!(body["footprint"]["write_operations_total"], 77);

    let replicas = body["replicas"].as_array().unwrap();
    assert_eq!(replicas.len(), 2);
    assert_eq!(replicas[0]["region"], "eu-central-1");
    assert_eq!(replicas[0]["status"], "active");
    assert_eq!(replicas[0]["lag_ops"], 37);
    assert_eq!(replicas[0]["utilization"], "green");
    assert_eq!(replicas[1]["region"], "ap-south-1");
    assert_eq!(replicas[1]["utilization"], Value::Null);

    assert_no_private_sentinels(&body);
    assert_infrastructure_json_shape(&body);
}

#[tokio::test]
async fn stale_primary_load_returns_null_utilization() {
    let fixture = setup_infrastructure_fixture().await;
    fixture
        .vm_repo
        .set_load_scraped_at(fixture.primary_vm.id, None);
    let uid = test_flapjack_uid(fixture.customer_id, TENANT_A_INDEX);
    fixture
        .http_client
        .push_text_response(200, &metrics_fixture(&uid, 100));

    let resp = fixture
        .app
        .oneshot(infrastructure_request(&fixture.jwt, TENANT_A_INDEX))
        .await
        .unwrap();
    let (status, body) = response_json(resp).await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["primary"]["utilization"], Value::Null);
}

#[tokio::test]
async fn infrastructure_response_filters_shared_vm_metrics_and_keys() {
    let fixture = setup_infrastructure_fixture().await;
    let tenant_a_uid = test_flapjack_uid(fixture.customer_id, TENANT_A_INDEX);
    let tenant_b_uid = test_flapjack_uid(fixture.foreign_customer_id, TENANT_B_INDEX);
    fixture.http_client.push_text_response(
        200,
        &shared_vm_metrics_fixture(&tenant_a_uid, &tenant_b_uid),
    );

    let resp = fixture
        .app
        .oneshot(infrastructure_request(&fixture.jwt, TENANT_A_INDEX))
        .await
        .unwrap();
    let (status, body) = response_json(resp).await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["index"], TENANT_A_INDEX);
    assert_eq!(body["footprint"]["documents_count"], 321);
    assert_eq!(body["footprint"]["storage_bytes"], 600);
    assert_eq!(body["footprint"]["search_requests_total"], 9001);
    assert_eq!(body["footprint"]["write_operations_total"], 77);

    assert_infrastructure_json_shape(&body);
    assert_no_private_sentinels(&body);
    assert_response_omits_shared_vm_neighbor_sentinels(
        &body,
        &tenant_b_uid,
        fixture.foreign_customer_id,
    );

    // The handler must read the shared VM's metrics exactly once for Alice. A
    // second upstream send would be masked by MockFlapjackHttpClient's default
    // `200 {}` fallback, so pinning the count (and the target URL) is what
    // proves no hidden extra cross-tenant shared-VM fetch occurred.
    let requests = fixture.http_client.take_requests();
    assert_eq!(
        requests.len(),
        1,
        "expected exactly one upstream shared-VM fetch, got: {requests:?}"
    );
    assert_eq!(requests[0].method, http::Method::GET);
    assert_eq!(requests[0].url, format!("{PRIMARY_URL_SENTINEL}/metrics"));
}

#[tokio::test]
async fn infrastructure_cross_tenant_rejects_foreign_index() {
    let fixture = setup_infrastructure_fixture().await;

    let resp = fixture
        .app
        .oneshot(infrastructure_request(&fixture.jwt, TENANT_B_INDEX))
        .await
        .unwrap();
    let (status, body) = response_json(resp).await;

    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(body["error"], format!("index '{TENANT_B_INDEX}' not found"));
    assert_eq!(fixture.http_client.request_count(), 0);
}

fn assert_key_set(value: &Value, expected: &[&str]) {
    let actual = value
        .as_object()
        .expect("response field should be a JSON object")
        .keys()
        .cloned()
        .collect::<BTreeSet<_>>();
    let expected = expected
        .iter()
        .map(|key| (*key).to_owned())
        .collect::<BTreeSet<_>>();
    assert_eq!(actual, expected);
}

fn assert_infrastructure_json_shape(body: &Value) {
    assert_key_set(
        body,
        &[
            "footprint",
            "headroom",
            "index",
            "minimum_refresh_interval_seconds",
            "primary",
            "replicas",
        ],
    );
    assert_key_set(&body["primary"], &["region", "status", "utilization"]);
    assert_key_set(
        &body["footprint"],
        &[
            "documents_count",
            "search_requests_total",
            "storage_bytes",
            "write_operations_total",
        ],
    );

    for replica in body["replicas"]
        .as_array()
        .expect("replicas should be a JSON array")
    {
        assert_key_set(replica, &["lag_ops", "region", "status", "utilization"]);
    }
    for forbidden_key in [
        "endpoint",
        "hostname",
        "ip",
        "flapjack_url",
        "vm_id",
        "replica_vm_id",
        "created_at",
        "updated_at",
        "load_scraped_at",
        "fetched_at",
        "timestamp",
        "capacity",
        "current_load",
        "cpu_weight",
        "mem_rss_bytes",
        "disk_bytes",
        "query_rps",
        "indexing_rps",
        "tenant_id",
        "customer_id",
        "tenant_count",
        "index_count",
        "neighbor_count",
        "other_tenant_count",
    ] {
        assert_no_key_recursive(body, forbidden_key);
    }
}

fn assert_no_key_recursive(value: &Value, forbidden_key: &str) {
    match value {
        Value::Object(fields) => {
            assert!(
                !fields.contains_key(forbidden_key),
                "infrastructure response leaked forbidden key {forbidden_key}: {value}"
            );
            for child in fields.values() {
                assert_no_key_recursive(child, forbidden_key);
            }
        }
        Value::Array(values) => {
            for child in values {
                assert_no_key_recursive(child, forbidden_key);
            }
        }
        _ => {}
    }
}

fn assert_no_private_sentinels(body: &Value) {
    let serialized = body.to_string();
    for sentinel in [
        PRIMARY_HOST_SENTINEL,
        REPLICA_HOST_SENTINEL,
        PRIMARY_URL_SENTINEL,
        REPLICA_URL_SENTINEL,
        SHARED_NODE_SECRET_SENTINEL,
        "192.0.2.10",
        "198.51.100.20",
        "flapjack_url",
        "endpoint",
        "vm_id",
        "replica_vm_id",
        "load_scraped_at",
        "fetched_at",
        "capacity",
        "current_load",
        "mem_rss_bytes",
        "disk_bytes",
        "query_rps",
        "indexing_rps",
        "424242424242",
    ] {
        assert!(
            !serialized.contains(sentinel),
            "infrastructure response leaked private sentinel {sentinel}: {serialized}"
        );
    }
}

fn assert_response_omits_shared_vm_neighbor_sentinels(
    body: &Value,
    tenant_b_uid: &str,
    foreign_customer_id: Uuid,
) {
    let serialized = body.to_string();
    for sentinel in [
        tenant_b_uid.to_string(),
        foreign_customer_id.to_string(),
        foreign_customer_id.as_simple().to_string(),
        TENANT_B_INDEX.to_string(),
        TENANT_B_DOCS_SENTINEL.to_string(),
        TENANT_B_STORAGE_SENTINEL.to_string(),
        TENANT_B_SEARCH_SENTINEL.to_string(),
        TENANT_B_WRITES_SENTINEL.to_string(),
    ] {
        assert!(
            !serialized.contains(&sentinel),
            "infrastructure response leaked neighbor sentinel {sentinel}: {serialized}"
        );
    }
}
