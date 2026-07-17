// Each test binary compiles this support module independently, so helpers
// that are used by one test file appear unused in others.
#![allow(dead_code)]

use std::collections::VecDeque;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};

use api::secrets::mock::MockNodeSecretManager;
use api::secrets::NodeSecretManager;
use api::services::flapjack_proxy::{
    FlapjackHttpClient, FlapjackHttpRequest, FlapjackHttpResponse, FlapjackProxy, ProxyError,
};
use async_trait::async_trait;

type SendBoundaryHook = Box<dyn FnOnce() -> Pin<Box<dyn Future<Output = ()> + Send>> + Send>;

#[derive(Default)]
pub struct MockFlapjackHttpClient {
    requests: Mutex<Vec<FlapjackHttpRequest>>,
    responses: Mutex<VecDeque<Result<FlapjackHttpResponse, ProxyError>>>,
    before_next_send: Mutex<Option<SendBoundaryHook>>,
    after_next_send: Mutex<Option<SendBoundaryHook>>,
}

impl MockFlapjackHttpClient {
    pub fn push_json_response(&self, status: u16, body: serde_json::Value) {
        self.responses
            .lock()
            .unwrap()
            .push_back(Ok(FlapjackHttpResponse {
                status,
                body: body.to_string(),
                request_api_key: String::new(),
            }));
    }

    pub fn push_text_response(&self, status: u16, body: &str) {
        self.responses
            .lock()
            .unwrap()
            .push_back(Ok(FlapjackHttpResponse {
                status,
                body: body.to_string(),
                request_api_key: String::new(),
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

    pub fn before_next_send<F, Fut>(&self, hook: F)
    where
        F: FnOnce() -> Fut + Send + 'static,
        Fut: Future<Output = ()> + Send + 'static,
    {
        *self.before_next_send.lock().unwrap() = Some(Box::new(move || Box::pin(hook())));
    }

    pub fn after_next_send<F, Fut>(&self, hook: F)
    where
        F: FnOnce() -> Fut + Send + 'static,
        Fut: Future<Output = ()> + Send + 'static,
    {
        *self.after_next_send.lock().unwrap() = Some(Box::new(move || Box::pin(hook())));
    }

    async fn run_boundary_hook(slot: &Mutex<Option<SendBoundaryHook>>) {
        let hook = slot.lock().unwrap().take();
        if let Some(hook) = hook {
            hook().await;
        }
    }
}

#[async_trait]
impl FlapjackHttpClient for MockFlapjackHttpClient {
    async fn send(&self, request: FlapjackHttpRequest) -> Result<FlapjackHttpResponse, ProxyError> {
        Self::run_boundary_hook(&self.before_next_send).await;
        let request_api_key = request.api_key.clone();
        self.requests.lock().unwrap().push(request);

        let response = self
            .responses
            .lock()
            .unwrap()
            .pop_front()
            .unwrap_or_else(|| {
                Ok(FlapjackHttpResponse {
                    status: 200,
                    body: "{}".to_string(),
                    request_api_key: String::new(),
                })
            });
        Self::run_boundary_hook(&self.after_next_send).await;
        let mut response = response?;
        response.request_api_key = request_api_key;
        Ok(response)
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

async fn setup_ready_index_inner(
    index_name: &str,
) -> (
    axum::Router,
    String,
    Arc<MockFlapjackHttpClient>,
    uuid::Uuid,
    Arc<api::state::MetricsCache>,
) {
    use api::repos::tenant_repo::TenantRepo;
    use api::state::MetricsCache;

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
    let metrics_cache = Arc::new(MetricsCache::default());
    let app = super::test_app_with_indexes_vm_inventory_and_metrics_cache(
        customer_repo,
        deployment_repo,
        tenant_repo,
        flapjack_proxy,
        vm_inventory_repo,
        metrics_cache.clone(),
    );

    (app, jwt, http_client, customer.id, metrics_cache)
}

pub async fn setup_ready_index(
    index_name: &str,
) -> (
    axum::Router,
    String,
    Arc<MockFlapjackHttpClient>,
    uuid::Uuid,
) {
    let (app, jwt, http_client, customer_id, _) = setup_ready_index_inner(index_name).await;
    (app, jwt, http_client, customer_id)
}

pub async fn setup_ready_index_with_metrics_cache(
    index_name: &str,
) -> (
    axum::Router,
    String,
    Arc<MockFlapjackHttpClient>,
    uuid::Uuid,
    Arc<api::state::MetricsCache>,
) {
    setup_ready_index_inner(index_name).await
}
