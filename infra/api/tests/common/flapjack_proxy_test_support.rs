//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar25_am_3_customer_multitenant_multiregion_coverage/fjcloud_dev/infra/api/tests/common/flapjack_proxy_test_support.rs.
// Each test binary compiles this support module independently, so helpers
// that are used by one test file appear unused in others.
#![allow(dead_code)]

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use api::secrets::mock::MockNodeSecretManager;
use api::secrets::NodeSecretManager;
use api::services::flapjack_proxy::{
    FlapjackHttpClient, FlapjackHttpRequest, FlapjackHttpResponse, FlapjackProxy, ProxyError,
};
use async_trait::async_trait;

#[derive(Default)]
pub struct MockFlapjackHttpClient {
    requests: Mutex<Vec<FlapjackHttpRequest>>,
    responses: Mutex<VecDeque<Result<FlapjackHttpResponse, ProxyError>>>,
}

impl MockFlapjackHttpClient {
    pub fn push_json_response(&self, status: u16, body: serde_json::Value) {
        self.responses
            .lock()
            .unwrap()
            .push_back(Ok(FlapjackHttpResponse {
                status,
                body: body.to_string(),
            }));
    }

    pub fn push_text_response(&self, status: u16, body: &str) {
        self.responses
            .lock()
            .unwrap()
            .push_back(Ok(FlapjackHttpResponse {
                status,
                body: body.to_string(),
            }));
    }

    pub fn push_error(&self, error: ProxyError) {
        self.responses.lock().unwrap().push_back(Err(error));
    }

    pub fn take_requests(&self) -> Vec<FlapjackHttpRequest> {
        self.requests.lock().unwrap().clone()
    }

    pub fn request_count(&self) -> usize {
        self.requests.lock().unwrap().len()
    }
}

#[async_trait]
impl FlapjackHttpClient for MockFlapjackHttpClient {
    async fn send(&self, request: FlapjackHttpRequest) -> Result<FlapjackHttpResponse, ProxyError> {
        self.requests.lock().unwrap().push(request);

        self.responses
            .lock()
            .unwrap()
            .pop_front()
            .unwrap_or_else(|| {
                Ok(FlapjackHttpResponse {
                    status: 200,
                    body: "{}".to_string(),
                })
            })
    }
}

/// Create bare proxy triplet (http_client, secret_manager, proxy) without
/// tenant or router setup. Useful for low-level proxy unit tests.
pub async fn setup() -> (
    Arc<MockFlapjackHttpClient>,
    Arc<MockNodeSecretManager>,
    FlapjackProxy,
) {
    let http = Arc::new(MockFlapjackHttpClient::default());
    let ssm = Arc::new(MockNodeSecretManager::new());

    ssm.create_node_api_key("node-1", "us-east-1")
        .await
        .unwrap();

    let proxy = FlapjackProxy::with_http_client(http.clone(), ssm.clone());

    (http, ssm, proxy)
}

/// Set up a verified customer with a ready index on a shared VM, wired to
/// a hermetic in-process flapjack transport. Returns (router, jwt, http_client).
/// Build the expected flapjack-side index UID for a test customer. Mirrors the
/// production `flapjack_index_uid` in `routes::indexes::mod.rs`.
pub fn test_flapjack_uid(customer_id: uuid::Uuid, index_name: &str) -> String {
    format!("{}_{}", customer_id.as_simple(), index_name)
}

/// Bootstraps a complete, ready-to-use index fixture for flapjack proxy tests.
///
/// Sets up:
/// - A verified free-tier customer seeded into `MockCustomerRepo`
/// - A provisioned, running deployment on node `"node-a1"` in `"us-east-1"`
/// - A flapjack tenant entry for `index_name` linked to that deployment
/// - A VM inventory entry with the node URL wired back into the tenant repo
/// - A `FlapjackProxy` backed by `MockFlapjackHttpClient` (all HTTP calls
///   are intercepted in-process — no real flapjack node required)
///
/// Returns `(router, jwt, http_client, customer_id)` where:
/// - `router` is the full axum [`Router`] ready to receive test requests
/// - `jwt` is a signed token for the seeded customer
/// - `http_client` is the shared mock so callers can enqueue responses and
///   inspect which requests were sent to flapjack
/// - `customer_id` is the UUID of the seeded customer
pub async fn setup_ready_index(
    index_name: &str,
) -> (
    axum::Router,
    String,
    Arc<MockFlapjackHttpClient>,
    uuid::Uuid,
) {
    use api::repos::tenant_repo::TenantRepo;

    let customer_repo = super::mock_repo();
    let deployment_repo = super::mock_deployment_repo();
    let tenant_repo = super::mock_tenant_repo();
    let vm_inventory_repo = super::mock_vm_inventory_repo();
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let node_secret_manager = Arc::new(MockNodeSecretManager::new());

    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let jwt = super::create_test_jwt(customer.id);

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
    tenant_repo
        .create(customer.id, index_name, deployment.id)
        .await
        .unwrap();

    let vm = vm_inventory_repo.seed("us-east-1", "https://vm-test.flapjack.foo");
    tenant_repo
        .set_vm_id(customer.id, index_name, vm.id)
        .await
        .unwrap();

    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client(
        http_client.clone(),
        node_secret_manager,
    ));
    let app = super::test_app_with_indexes_and_vm_inventory(
        customer_repo,
        deployment_repo,
        tenant_repo,
        flapjack_proxy,
        vm_inventory_repo,
    );

    (app, jwt, http_client, customer.id)
}
