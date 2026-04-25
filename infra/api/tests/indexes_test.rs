mod common;

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use sqlx::postgres::PgPoolOptions;

use api::provisioner::region_map::RegionConfig;
use api::provisioner::{CreateVmRequest, VmInstance, VmProvisioner, VmProvisionerError, VmStatus};
use api::repos::vm_inventory_repo::VmInventoryRepo;
use api::router::build_router;
use api::secrets::NodeSecretManager;
use api::services::flapjack_proxy::{FlapjackProxy, ProxyError};
use async_trait::async_trait;
use axum::body::Body;
use axum::http::{self, Request, StatusCode};
use common::indexes_route_test_support::response_json;
use common::{
    create_test_jwt, mock_deployment_repo, mock_flapjack_proxy, mock_repo, mock_tenant_repo,
    mock_vm_inventory_repo, test_app_with_indexes, test_app_with_indexes_and_vm_inventory,
    test_app_with_repos, test_state_with_indexes, test_state_with_indexes_and_vm_inventory,
};
use serde_json::{json, Value};
use tokio::sync::{Notify, Semaphore};
use tower::ServiceExt;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Returns a real PgPool connected to DATABASE_URL for tests that need advisory locks.
/// Returns `None` with a skip message when the database backend is unavailable.
#[allow(clippy::await_holding_lock)]
async fn advisory_lock_test_pool() -> Option<sqlx::PgPool> {
    let _env_guard = process_env_lock().lock().unwrap();
    advisory_lock_test_pool_with_current_env().await
}

async fn advisory_lock_test_pool_with_current_env() -> Option<sqlx::PgPool> {
    let url = match std::env::var("DATABASE_URL") {
        Ok(u) => u,
        Err(_) => {
            eprintln!("SKIP: DATABASE_URL not set — advisory lock tests require a real database");
            return None;
        }
    };
    let pool = match tokio::time::timeout(
        Duration::from_millis(500),
        PgPoolOptions::new().max_connections(5).connect(&url),
    )
    .await
    {
        Ok(Ok(pool)) => pool,
        Ok(Err(err)) => {
            eprintln!(
                "SKIP: DATABASE_URL is not reachable — advisory lock tests require a real database: {err}"
            );
            return None;
        }
        Err(_) => {
            eprintln!(
                "SKIP: DATABASE_URL connection timed out — advisory lock tests require a real database"
            );
            return None;
        }
    };
    if let Err(err) = sqlx::query_scalar::<_, bool>("SELECT pg_try_advisory_lock($1)")
        .bind(1_i64)
        .fetch_one(&pool)
        .await
    {
        eprintln!("SKIP: advisory lock backend unavailable for indexes tests: {err}");
        return None;
    }
    let _ = sqlx::query("SELECT pg_advisory_unlock($1)")
        .bind(1_i64)
        .execute(&pool)
        .await;
    if let Err(err) = sqlx::migrate!("../migrations").run(&pool).await {
        eprintln!("SKIP: failed to run advisory lock test migrations: {err}");
        return None;
    }
    Some(pool)
}

#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn advisory_lock_test_pool_returns_none_without_database_url() {
    let _env_guard = process_env_lock().lock().unwrap();
    let _database_url = EnvVarGuard::unset("DATABASE_URL");

    assert!(advisory_lock_test_pool_with_current_env().await.is_none());
}

#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn advisory_lock_test_pool_returns_none_when_database_is_unreachable() {
    let _env_guard = process_env_lock().lock().unwrap();
    let _database_url = EnvVarGuard::set(
        "DATABASE_URL",
        "postgres://fake:fake@127.0.0.1:1/fjcloud_test",
    );

    assert!(advisory_lock_test_pool_with_current_env().await.is_none());
}

#[derive(Debug)]
struct ClassicRouteProxyFailureCase {
    index_name: &'static str,
    route_method: http::Method,
    route_path: String,
    route_body: Option<Value>,
    expected_proxy_method: reqwest::Method,
    expected_proxy_url: String,
    expected_proxy_body: Option<Value>,
}

impl ClassicRouteProxyFailureCase {
    fn search(index_name: &'static str, body: Value) -> Self {
        Self {
            index_name,
            route_method: http::Method::POST,
            route_path: format!("/indexes/{index_name}/search"),
            route_body: Some(body.clone()),
            expected_proxy_method: reqwest::Method::POST,
            expected_proxy_url: format!(
                "https://vm-test.flapjack.foo/1/indexes/{index_name}/query"
            ),
            expected_proxy_body: Some(body),
        }
    }

    fn get_settings(index_name: &'static str) -> Self {
        Self {
            index_name,
            route_method: http::Method::GET,
            route_path: format!("/indexes/{index_name}/settings"),
            route_body: None,
            expected_proxy_method: reqwest::Method::GET,
            expected_proxy_url: format!(
                "https://vm-test.flapjack.foo/1/indexes/{index_name}/settings"
            ),
            expected_proxy_body: None,
        }
    }

    fn update_settings(index_name: &'static str, body: Value) -> Self {
        Self {
            index_name,
            route_method: http::Method::PUT,
            route_path: format!("/indexes/{index_name}/settings"),
            route_body: Some(body.clone()),
            expected_proxy_method: reqwest::Method::POST,
            expected_proxy_url: format!(
                "https://vm-test.flapjack.foo/1/indexes/{index_name}/settings"
            ),
            expected_proxy_body: Some(body),
        }
    }
}

#[derive(Debug)]
struct ProxyFailureExpectation {
    status: StatusCode,
    message: &'static str,
    forbidden_message_fragment: Option<&'static str>,
}

impl ProxyFailureExpectation {
    fn service_unavailable(message: &'static str) -> Self {
        Self {
            status: StatusCode::SERVICE_UNAVAILABLE,
            message,
            forbidden_message_fragment: None,
        }
    }

    fn internal_server_error(
        message: &'static str,
        forbidden_message_fragment: Option<&'static str>,
    ) -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            message,
            forbidden_message_fragment,
        }
    }
}

fn build_authenticated_json_request(
    method: http::Method,
    path: &str,
    jwt: &str,
    json_body: Option<Value>,
) -> Request<Body> {
    let mut builder = Request::builder()
        .method(method)
        .uri(path)
        .header("authorization", format!("Bearer {jwt}"));

    if json_body.is_some() {
        builder = builder.header("content-type", "application/json");
    }

    let body = json_body
        .map(|json| Body::from(json.to_string()))
        .unwrap_or_else(Body::empty);

    builder.body(body).unwrap()
}

fn build_settings_route_request(
    index_name: &str,
    method: http::Method,
    jwt: &str,
    json_body: Option<Value>,
) -> Request<Body> {
    build_authenticated_json_request(
        method,
        &format!("/indexes/{index_name}/settings"),
        jwt,
        json_body,
    )
}

async fn assert_classic_route_proxy_error(
    case: ClassicRouteProxyFailureCase,
    proxy_error: ProxyError,
    expected: ProxyFailureExpectation,
) {
    let (app, jwt, http_client, customer_id) = setup_ready_index(case.index_name).await;
    http_client.push_error(proxy_error);

    let req = if case.route_path.ends_with("/settings") {
        build_settings_route_request(
            case.index_name,
            case.route_method.clone(),
            &jwt,
            case.route_body.clone(),
        )
    } else {
        build_authenticated_json_request(
            case.route_method.clone(),
            &case.route_path,
            &jwt,
            case.route_body.clone(),
        )
    };

    let resp = app.oneshot(req).await.unwrap();
    let (status, body) = response_json(resp).await;

    assert_eq!(status, expected.status);
    assert_eq!(body["error"], expected.message);
    if let Some(forbidden) = expected.forbidden_message_fragment {
        assert!(
            !body["error"]
                .as_str()
                .unwrap_or_default()
                .contains(forbidden),
            "unexpected upstream leak in error body: {}",
            body["error"]
        );
    }

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, case.expected_proxy_method);
    // The proxy now namespaces index UIDs per tenant, so compute the expected URL
    let expected_url = case.expected_proxy_url.replace(
        &format!("/indexes/{}/", case.index_name),
        &format!(
            "/indexes/{}/",
            test_flapjack_uid(customer_id, case.index_name)
        ),
    );
    assert_eq!(requests[0].url, expected_url);
    assert_eq!(requests[0].json_body, case.expected_proxy_body);
}

use common::flapjack_proxy_test_support::MockFlapjackHttpClient;

fn process_env_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

struct EnvVarGuard {
    key: &'static str,
    old_value: Option<String>,
}

impl EnvVarGuard {
    fn set(key: &'static str, value: &str) -> Self {
        let old_value = std::env::var(key).ok();
        std::env::set_var(key, value);
        Self { key, old_value }
    }

    fn unset(key: &'static str) -> Self {
        let old_value = std::env::var(key).ok();
        std::env::remove_var(key);
        Self { key, old_value }
    }
}

impl Drop for EnvVarGuard {
    fn drop(&mut self) {
        match &self.old_value {
            Some(value) => std::env::set_var(self.key, value),
            None => std::env::remove_var(self.key),
        }
    }
}

/// Set up a customer + shared VM with a hermetic in-process flapjack transport.
/// Index creation goes through the shared-placement path (vm_inventory).
struct ProxyTestSetup {
    jwt: String,
    app: axum::Router,
    http_client: Arc<MockFlapjackHttpClient>,
    customer_id: uuid::Uuid,
}

async fn setup_proxy_test() -> ProxyTestSetup {
    use api::models::vm_inventory::NewVmInventory;
    use api::repos::vm_inventory_repo::VmInventoryRepo;

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let node_secret_manager = Arc::new(api::secrets::mock::MockNodeSecretManager::new());

    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let jwt = create_test_jwt(customer.id);

    // Seed a shared VM in us-east-1 for the placement scheduler
    let seeded_vm = vm_inventory_repo
        .create(NewVmInventory {
            region: "us-east-1".to_string(),
            provider: "aws".to_string(),
            hostname: "vm-proxy.flapjack.foo".to_string(),
            flapjack_url: "https://vm-proxy.flapjack.foo".to_string(),
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
    vm_inventory_repo
        .update_load(seeded_vm.id, serde_json::json!({}))
        .await
        .unwrap();

    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client(
        http_client.clone(),
        node_secret_manager.clone(),
    ));

    // Share node_secret_manager between proxy and provisioning service so keys
    // created during index placement are visible to the proxy.
    let vm_provisioner = Arc::new(api::provisioner::mock::MockVmProvisioner::new());
    let dns_manager = Arc::new(api::dns::mock::MockDnsManager::new());
    let provisioning_service = Arc::new(api::services::provisioning::ProvisioningService::new(
        vm_provisioner,
        dns_manager,
        node_secret_manager,
        deployment_repo.clone(),
        customer_repo.clone(),
        "flapjack.foo".to_string(),
    ));

    let mut state = test_state_with_indexes_and_vm_inventory(
        customer_repo,
        deployment_repo,
        tenant_repo,
        flapjack_proxy,
        vm_inventory_repo,
    );
    state.provisioning_service = provisioning_service;

    let app = build_router(state);

    ProxyTestSetup {
        jwt,
        app,
        http_client,
        customer_id: customer.id,
    }
}

struct AutoProvisionCapacitySetup {
    app: axum::Router,
    jwt: String,
    customer_id: uuid::Uuid,
    saturated_vm_id: uuid::Uuid,
    vm_inventory_repo: Arc<common::MockVmInventoryRepo>,
    tenant_repo: Arc<common::MockTenantRepo>,
    vm_provisioner: Arc<api::provisioner::mock::MockVmProvisioner>,
    http_client: Arc<MockFlapjackHttpClient>,
}

struct CapacityExhaustionSetupCore {
    app: axum::Router,
    jwt: String,
    customer_id: uuid::Uuid,
    saturated_vm_id: uuid::Uuid,
    vm_inventory_repo: Arc<common::MockVmInventoryRepo>,
    tenant_repo: Arc<common::MockTenantRepo>,
    http_client: Arc<MockFlapjackHttpClient>,
}

struct EmptyRegionAutoProvisionSetup {
    app: axum::Router,
    jwt: String,
    vm_provisioner: Arc<api::provisioner::mock::MockVmProvisioner>,
    vm_inventory_repo: Arc<common::MockVmInventoryRepo>,
    http_client: Arc<MockFlapjackHttpClient>,
}

struct ControlledVmProvisioner {
    inner: Arc<api::provisioner::mock::MockVmProvisioner>,
    create_calls: AtomicUsize,
    first_create_started: Notify,
    first_create_release: Arc<Semaphore>,
    block_first_create: bool,
    fail_first_create: bool,
}

impl ControlledVmProvisioner {
    fn new(block_first_create: bool, fail_first_create: bool) -> Self {
        Self {
            inner: Arc::new(api::provisioner::mock::MockVmProvisioner::new()),
            create_calls: AtomicUsize::new(0),
            first_create_started: Notify::new(),
            first_create_release: Arc::new(Semaphore::new(0)),
            block_first_create,
            fail_first_create,
        }
    }

    fn create_call_count(&self) -> usize {
        self.create_calls.load(Ordering::SeqCst)
    }

    fn vm_count(&self) -> usize {
        self.inner.vm_count()
    }

    async fn wait_for_first_create_started(&self) {
        if self.create_call_count() > 0 {
            return;
        }
        self.first_create_started.notified().await;
    }

    fn release_first_create(&self) {
        self.first_create_release.add_permits(1);
    }
}

#[async_trait]
impl VmProvisioner for ControlledVmProvisioner {
    async fn create_vm(&self, config: &CreateVmRequest) -> Result<VmInstance, VmProvisionerError> {
        let call_index = self.create_calls.fetch_add(1, Ordering::SeqCst);
        if call_index == 0 {
            self.first_create_started.notify_waiters();
            if self.block_first_create {
                let permit = self.first_create_release.acquire().await.unwrap();
                drop(permit);
            }
            if self.fail_first_create {
                return Err(VmProvisionerError::Api(
                    "injected first-create failure".to_string(),
                ));
            }
        }

        self.inner.create_vm(config).await
    }

    async fn destroy_vm(&self, provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        self.inner.destroy_vm(provider_vm_id).await
    }

    async fn stop_vm(&self, provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        self.inner.stop_vm(provider_vm_id).await
    }

    async fn start_vm(&self, provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        self.inner.start_vm(provider_vm_id).await
    }

    async fn get_vm_status(&self, provider_vm_id: &str) -> Result<VmStatus, VmProvisionerError> {
        self.inner.get_vm_status(provider_vm_id).await
    }
}

async fn setup_capacity_exhaustion_with_vm_provisioner(
    vm_provisioner: Arc<dyn VmProvisioner>,
) -> Option<CapacityExhaustionSetupCore> {
    use api::models::vm_inventory::NewVmInventory;
    use api::repos::vm_inventory_repo::VmInventoryRepo;

    // These tests use advisory locks which require a real database connection.
    let pool = advisory_lock_test_pool().await?;

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let node_secret_manager = Arc::new(api::secrets::mock::MockNodeSecretManager::new());

    let customer = customer_repo.seed_verified_shared_customer("SharedCo", "shared@example.com");
    let jwt = create_test_jwt(customer.id);

    // Seed one fresh VM that is over capacity so placement returns None.
    let saturated_vm = vm_inventory_repo
        .create(NewVmInventory {
            region: "us-east-1".to_string(),
            provider: "aws".to_string(),
            hostname: "vm-saturated.flapjack.foo".to_string(),
            flapjack_url: "https://vm-saturated.flapjack.foo".to_string(),
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
    vm_inventory_repo
        .update_load(
            saturated_vm.id,
            serde_json::json!({
                "cpu_weight": 10.0,
                "mem_rss_bytes": 8_589_934_592_u64,
                "disk_bytes": 107_374_182_400_u64,
                "query_rps": 500.0,
                "indexing_rps": 200.0
            }),
        )
        .await
        .unwrap();

    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client(
        http_client.clone(),
        node_secret_manager.clone(),
    ));
    let dns_manager = Arc::new(api::dns::mock::MockDnsManager::new());
    let provisioning_service = Arc::new(api::services::provisioning::ProvisioningService::new(
        vm_provisioner.clone(),
        dns_manager.clone(),
        node_secret_manager,
        deployment_repo.clone(),
        customer_repo.clone(),
        "flapjack.foo".to_string(),
    ));

    let mut state = test_state_with_indexes_and_vm_inventory(
        customer_repo,
        deployment_repo,
        tenant_repo.clone(),
        flapjack_proxy,
        vm_inventory_repo.clone(),
    );
    state.pool = pool;
    state.vm_provisioner = vm_provisioner.clone();
    state.dns_manager = dns_manager;
    state.provisioning_service = provisioning_service;

    Some(CapacityExhaustionSetupCore {
        app: build_router(state),
        jwt,
        customer_id: customer.id,
        saturated_vm_id: saturated_vm.id,
        vm_inventory_repo,
        tenant_repo,
        http_client,
    })
}

async fn setup_empty_region_auto_provision_test() -> Option<EmptyRegionAutoProvisionSetup> {
    // These tests use advisory locks which require a real database connection.
    let pool = advisory_lock_test_pool().await?;

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo(); // EMPTY inventory repo
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let node_secret_manager = Arc::new(api::secrets::mock::MockNodeSecretManager::new());

    let vm_provisioner = Arc::new(api::provisioner::mock::MockVmProvisioner::new());
    let dns_manager = Arc::new(api::dns::mock::MockDnsManager::new());
    let customer = customer_repo.seed_verified_shared_customer("SharedCo", "shared@example.com");
    let jwt = create_test_jwt(customer.id);

    let provisioning_service = Arc::new(api::services::provisioning::ProvisioningService::new(
        vm_provisioner.clone(),
        dns_manager.clone(),
        node_secret_manager.clone(),
        deployment_repo.clone(),
        customer_repo.clone(),
        "flapjack.foo".to_string(),
    ));

    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client(
        http_client.clone(),
        node_secret_manager,
    ));

    let mut state = test_state_with_indexes_and_vm_inventory(
        customer_repo,
        deployment_repo,
        tenant_repo.clone(),
        flapjack_proxy,
        vm_inventory_repo.clone(),
    );
    state.pool = pool;
    state.vm_provisioner = vm_provisioner.clone();
    state.dns_manager = dns_manager;
    state.provisioning_service = provisioning_service;

    Some(EmptyRegionAutoProvisionSetup {
        app: build_router(state),
        jwt,
        vm_provisioner,
        vm_inventory_repo,
        http_client,
    })
}

async fn setup_capacity_exhaustion_auto_provision_test(
    vm_provisioner_should_fail: bool,
) -> Option<AutoProvisionCapacitySetup> {
    let vm_provisioner = Arc::new(api::provisioner::mock::MockVmProvisioner::new());
    if vm_provisioner_should_fail {
        vm_provisioner.set_should_fail(true);
    }

    let setup = setup_capacity_exhaustion_with_vm_provisioner(
        vm_provisioner.clone() as Arc<dyn VmProvisioner>
    )
    .await?;

    Some(AutoProvisionCapacitySetup {
        app: setup.app,
        jwt: setup.jwt,
        customer_id: setup.customer_id,
        saturated_vm_id: setup.saturated_vm_id,
        vm_inventory_repo: setup.vm_inventory_repo,
        tenant_repo: setup.tenant_repo,
        vm_provisioner,
        http_client: setup.http_client,
    })
}

// ---------------------------------------------------------------------------
// 1. create returns 201 with index details
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_returns_201_with_index_details() {
    let setup = setup_proxy_test().await;

    let expected_uid = test_flapjack_uid(setup.customer_id, "my-index");
    setup
        .http_client
        .push_json_response(200, json!({"uid": expected_uid}));

    let resp = setup
        .app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {}", setup.jwt))
                .body(Body::from(
                    json!({"name": "my-index", "region": "us-east-1"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(body["name"], "my-index");
    assert_eq!(body["region"], "us-east-1");
    assert!(body["endpoint"].is_string());
    assert_eq!(body["entries"], 0);
    assert_eq!(body["tier"], "active");
    assert!(body.get("last_accessed_at").is_none());
    assert!(body.get("cold_since").is_none());
    assert!(body["created_at"].is_string());

    let requests = setup.http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(requests[0].url, "https://vm-proxy.flapjack.foo/1/indexes");
    assert_eq!(requests[0].json_body, Some(json!({"uid": expected_uid})));
}

// ---------------------------------------------------------------------------
// 2. create returns 400 when no VM capacity exists in requested region
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// 3. create without shared capacity returns 400 (dedicated fallback removed)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_auto_provisions_shared_vm_when_existing_vms_are_at_capacity() {
    use api::repos::tenant_repo::TenantRepo;
    use api::repos::vm_inventory_repo::VmInventoryRepo;

    let Some(setup) = setup_capacity_exhaustion_auto_provision_test(false).await else {
        return;
    };
    setup.http_client.push_json_response(200, json!({}));

    let resp = setup
        .app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {}", setup.jwt))
                .body(Body::from(
                    json!({"name": "auto-provisioned", "region": "us-east-1"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, _body) = response_json(resp).await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(
        setup.vm_provisioner.vm_count(),
        1,
        "capacity exhaustion should trigger one VM provision call"
    );

    let vms = setup
        .vm_inventory_repo
        .list_active(Some("us-east-1"))
        .await
        .unwrap();
    assert_eq!(vms.len(), 2, "auto-provision should add a new shared VM");

    let tenant = setup
        .tenant_repo
        .find_raw(setup.customer_id, "auto-provisioned")
        .await
        .unwrap()
        .expect("tenant should exist after successful create");
    let placed_vm_id = tenant.vm_id.expect("tenant should be assigned a VM");
    assert_ne!(
        placed_vm_id, setup.saturated_vm_id,
        "index should not be placed on the saturated VM"
    );
}

#[tokio::test]
async fn create_auto_provisioned_vm_retries_transient_unreachable_proxy() {
    let Some(setup) = setup_capacity_exhaustion_auto_provision_test(false).await else {
        return;
    };
    setup
        .http_client
        .push_error(ProxyError::Unreachable("dns still propagating".into()));
    setup.http_client.push_json_response(200, json!({}));

    let resp = setup
        .app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {}", setup.jwt))
                .body(Body::from(
                    json!({"name": "warmup-retry", "region": "us-east-1"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::CREATED, "body={body:?}");

    let requests = setup.http_client.take_requests();
    assert_eq!(requests.len(), 2, "fresh shared VM should retry once");
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(requests[1].method, reqwest::Method::POST);
    assert_eq!(requests[0].url, requests[1].url);
}

#[tokio::test]
async fn create_auto_provisioned_vm_is_active_and_receives_index_assignment() {
    use api::repos::tenant_repo::TenantRepo;
    use api::repos::vm_inventory_repo::VmInventoryRepo;

    let Some(setup) = setup_capacity_exhaustion_auto_provision_test(false).await else {
        return;
    };
    setup.http_client.push_json_response(200, json!({}));

    let resp = setup
        .app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {}", setup.jwt))
                .body(Body::from(
                    json!({"name": "fresh-placement", "region": "us-east-1"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, _body) = response_json(resp).await;
    assert_eq!(status, StatusCode::CREATED);

    let tenant = setup
        .tenant_repo
        .find_raw(setup.customer_id, "fresh-placement")
        .await
        .unwrap()
        .expect("tenant should exist after successful create");
    let placed_vm_id = tenant.vm_id.expect("tenant should be assigned a VM");
    let vm_rows = setup
        .vm_inventory_repo
        .list_active(Some("us-east-1"))
        .await
        .unwrap();
    let auto_vm = vm_rows
        .iter()
        .find(|vm| vm.id == placed_vm_id)
        .expect("placement VM row must exist");
    assert_eq!(auto_vm.status, "active");
    assert!(
        auto_vm.load_scraped_at.is_none(),
        "newly auto-provisioned VM should start unscraped with NULL load_scraped_at"
    );

    let requests = setup.http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0].url,
        format!("{}/1/indexes", auto_vm.flapjack_url),
        "index create should be routed to the auto-provisioned VM"
    );
}

#[tokio::test]
async fn create_existing_shared_vm_unreachable_returns_503_without_retry() {
    let setup = setup_proxy_test().await;
    setup
        .http_client
        .push_error(ProxyError::Unreachable("connection refused".into()));

    let resp = setup
        .app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {}", setup.jwt))
                .body(Body::from(
                    json!({"name": "existing-unreachable", "region": "us-east-1"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body["error"], "backend temporarily unavailable");

    let requests = setup.http_client.take_requests();
    assert_eq!(requests.len(), 1, "existing shared VM should fail fast");
}

#[tokio::test]
async fn create_returns_503_when_auto_provisioning_fails() {
    use api::repos::vm_inventory_repo::VmInventoryRepo;

    let Some(setup) = setup_capacity_exhaustion_auto_provision_test(true).await else {
        return;
    };

    let resp = setup
        .app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {}", setup.jwt))
                .body(Body::from(
                    json!({"name": "provision-fails", "region": "us-east-1"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert!(
        body["error"]
            .as_str()
            .unwrap_or("")
            .contains("auto-provision"),
        "error should clearly indicate auto-provisioning failure: {body}"
    );

    let vm_rows = setup
        .vm_inventory_repo
        .list_active(Some("us-east-1"))
        .await
        .unwrap();
    assert_eq!(vm_rows.len(), 1, "failed provisioning must not add VM rows");
    assert_eq!(
        setup.http_client.take_requests().len(),
        0,
        "flapjack create_index should not run when auto-provisioning fails"
    );
}

#[tokio::test]
async fn create_auto_provisions_when_region_has_no_vms() {
    let Some(setup) = setup_empty_region_auto_provision_test().await else {
        return;
    };
    setup.http_client.push_json_response(200, json!({}));

    let resp = setup
        .app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {}", setup.jwt))
                .body(Body::from(
                    json!({"name": "auto-provisioned", "region": "us-east-1"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, _body) = response_json(resp).await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(
        setup.vm_provisioner.vm_count(),
        1,
        "empty region should trigger one VM provision call"
    );
}

#[tokio::test]
async fn create_auto_provisions_in_empty_region() {
    let Some(setup) = setup_empty_region_auto_provision_test().await else {
        return;
    };
    setup.http_client.push_json_response(200, json!({}));

    let resp = setup
        .app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {}", setup.jwt))
                .body(Body::from(
                    json!({"name": "auto-provisioned", "region": "us-east-1"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, _body) = response_json(resp).await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(
        setup.vm_provisioner.vm_count(),
        1,
        "empty region should trigger exactly one VM provision"
    );

    let active_vms = setup
        .vm_inventory_repo
        .list_active(Some("us-east-1"))
        .await
        .unwrap();
    assert_eq!(active_vms.len(), 1, "exactly one VM should be provisioned");

    let requests = setup.http_client.take_requests();
    assert_eq!(
        requests.len(),
        1,
        "one Flapjack HTTP request should be sent"
    );
}

#[tokio::test]
async fn create_auto_provision_empty_region_vm_matches_request_region() {
    let Some(setup) = setup_empty_region_auto_provision_test().await else {
        return;
    };
    setup.http_client.push_json_response(200, json!({}));

    let resp = setup
        .app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {}", setup.jwt))
                .body(Body::from(
                    json!({"name": "auto-provisioned", "region": "eu-west-1"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, _body) = response_json(resp).await;
    assert_eq!(status, StatusCode::CREATED);

    let active_vms = setup
        .vm_inventory_repo
        .list_active(Some("eu-west-1"))
        .await
        .unwrap();
    assert_eq!(
        active_vms.len(),
        1,
        "exactly one VM should be provisioned in eu-west-1"
    );
    assert_eq!(
        active_vms[0].region, "eu-west-1",
        "Provisioned VM must be in requested region"
    );
}

#[tokio::test]
async fn create_auto_provision_empty_region_provisioner_failure_returns_503() {
    let Some(setup) = setup_empty_region_auto_provision_test().await else {
        return;
    };

    // Set up the provisioner to fail
    setup.vm_provisioner.set_should_fail(true);

    let resp = setup
        .app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {}", setup.jwt))
                .body(Body::from(
                    json!({"name": "auto-provisioned", "region": "us-east-1"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert!(body["error"].as_str().unwrap().contains("auto-provision"));
    assert_eq!(
        setup.vm_provisioner.vm_count(),
        0,
        "VM provisioner must not count failed provisions"
    );

    let requests = setup.http_client.take_requests();
    assert_eq!(
        requests.len(),
        0,
        "No Flapjack HTTP requests should be sent when provisioner fails"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn create_concurrent_capacity_exhaustion_provisions_exactly_one_vm() {
    use api::repos::tenant_repo::TenantRepo;
    use api::repos::vm_inventory_repo::VmInventoryRepo;

    let controlled = Arc::new(ControlledVmProvisioner::new(false, false));
    let Some(setup) =
        setup_capacity_exhaustion_with_vm_provisioner(controlled.clone() as Arc<dyn VmProvisioner>)
            .await
    else {
        return;
    };

    setup.http_client.push_json_response(200, json!({}));
    setup.http_client.push_json_response(200, json!({}));

    let app_one = setup.app.clone();
    let app_two = setup.app.clone();
    let jwt = setup.jwt.clone();

    let request_one = Request::builder()
        .method(http::Method::POST)
        .uri("/indexes")
        .header("content-type", "application/json")
        .header("authorization", format!("Bearer {jwt}"))
        .body(Body::from(
            json!({"name": "concurrent-a", "region": "us-east-1"}).to_string(),
        ))
        .unwrap();
    let request_two = Request::builder()
        .method(http::Method::POST)
        .uri("/indexes")
        .header("content-type", "application/json")
        .header("authorization", format!("Bearer {jwt}"))
        .body(Body::from(
            json!({"name": "concurrent-b", "region": "us-east-1"}).to_string(),
        ))
        .unwrap();

    let (resp_one, resp_two) =
        tokio::join!(app_one.oneshot(request_one), app_two.oneshot(request_two));
    let (status_one, body_one) = response_json(resp_one.unwrap()).await;
    let (status_two, body_two) = response_json(resp_two.unwrap()).await;

    assert_eq!(
        status_one,
        StatusCode::CREATED,
        "first request failed: {body_one}"
    );
    assert_eq!(
        status_two,
        StatusCode::CREATED,
        "second request failed: {body_two}"
    );
    assert_eq!(
        controlled.create_call_count(),
        1,
        "exactly one VM should be provisioned for concurrent capacity exhaustion"
    );

    let vms = setup
        .vm_inventory_repo
        .list_active(Some("us-east-1"))
        .await
        .unwrap();
    assert_eq!(
        vms.len(),
        2,
        "should keep one saturated + one newly provisioned VM"
    );

    let tenant_a = setup
        .tenant_repo
        .find_raw(setup.customer_id, "concurrent-a")
        .await
        .unwrap()
        .expect("first tenant should exist");
    let tenant_b = setup
        .tenant_repo
        .find_raw(setup.customer_id, "concurrent-b")
        .await
        .unwrap()
        .expect("second tenant should exist");
    assert_eq!(tenant_a.vm_id, tenant_b.vm_id);
    assert_ne!(
        tenant_a.vm_id.expect("first tenant should have vm_id"),
        setup.saturated_vm_id
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn create_concurrent_second_request_waits_and_then_uses_new_vm() {
    use api::repos::tenant_repo::TenantRepo;

    let controlled = Arc::new(ControlledVmProvisioner::new(true, false));
    let Some(setup) =
        setup_capacity_exhaustion_with_vm_provisioner(controlled.clone() as Arc<dyn VmProvisioner>)
            .await
    else {
        return;
    };

    setup.http_client.push_json_response(200, json!({}));
    setup.http_client.push_json_response(200, json!({}));

    let app_one = setup.app.clone();
    let app_two = setup.app.clone();
    let jwt = setup.jwt.clone();

    let first_handle = tokio::spawn(async move {
        app_one
            .oneshot(
                Request::builder()
                    .method(http::Method::POST)
                    .uri("/indexes")
                    .header("content-type", "application/json")
                    .header("authorization", format!("Bearer {jwt}"))
                    .body(Body::from(
                        json!({"name": "wait-first", "region": "us-east-1"}).to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap()
    });

    controlled.wait_for_first_create_started().await;

    let second_jwt = setup.jwt.clone();
    let second_handle = tokio::spawn(async move {
        app_two
            .oneshot(
                Request::builder()
                    .method(http::Method::POST)
                    .uri("/indexes")
                    .header("content-type", "application/json")
                    .header("authorization", format!("Bearer {second_jwt}"))
                    .body(Body::from(
                        json!({"name": "wait-second", "region": "us-east-1"}).to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap()
    });

    tokio::time::sleep(Duration::from_millis(150)).await;
    assert!(
        !second_handle.is_finished(),
        "second request should block while first request is inside provisioning lock"
    );

    controlled.release_first_create();

    let first_resp = first_handle.await.unwrap();
    let second_resp = second_handle.await.unwrap();
    let (first_status, first_body) = response_json(first_resp).await;
    let (second_status, second_body) = response_json(second_resp).await;
    assert_eq!(
        first_status,
        StatusCode::CREATED,
        "first request failed: {first_body}"
    );
    assert_eq!(
        second_status,
        StatusCode::CREATED,
        "second request should succeed after first finishes: {second_body}"
    );
    assert_eq!(
        controlled.create_call_count(),
        1,
        "second request should reuse VM provisioned by the first request"
    );

    let tenant_first = setup
        .tenant_repo
        .find_raw(setup.customer_id, "wait-first")
        .await
        .unwrap()
        .expect("first tenant should exist");
    let tenant_second = setup
        .tenant_repo
        .find_raw(setup.customer_id, "wait-second")
        .await
        .unwrap()
        .expect("second tenant should exist");
    assert_eq!(tenant_first.vm_id, tenant_second.vm_id);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn create_lock_releases_after_provision_failure_so_second_request_can_succeed() {
    let controlled = Arc::new(ControlledVmProvisioner::new(true, true));
    let Some(setup) =
        setup_capacity_exhaustion_with_vm_provisioner(controlled.clone() as Arc<dyn VmProvisioner>)
            .await
    else {
        return;
    };

    setup.http_client.push_json_response(200, json!({}));
    setup.http_client.push_json_response(200, json!({}));

    let app_one = setup.app.clone();
    let app_two = setup.app.clone();
    let jwt = setup.jwt.clone();

    let first_handle = tokio::spawn(async move {
        app_one
            .oneshot(
                Request::builder()
                    .method(http::Method::POST)
                    .uri("/indexes")
                    .header("content-type", "application/json")
                    .header("authorization", format!("Bearer {jwt}"))
                    .body(Body::from(
                        json!({"name": "fail-first", "region": "us-east-1"}).to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap()
    });

    controlled.wait_for_first_create_started().await;

    let second_jwt = setup.jwt.clone();
    let second_handle = tokio::spawn(async move {
        app_two
            .oneshot(
                Request::builder()
                    .method(http::Method::POST)
                    .uri("/indexes")
                    .header("content-type", "application/json")
                    .header("authorization", format!("Bearer {second_jwt}"))
                    .body(Body::from(
                        json!({"name": "after-failure", "region": "us-east-1"}).to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap()
    });

    tokio::time::sleep(Duration::from_millis(150)).await;
    assert!(
        !second_handle.is_finished(),
        "second request should wait while first request owns the lock, even if first fails"
    );

    controlled.release_first_create();

    let first_resp = first_handle.await.unwrap();
    let second_resp = second_handle.await.unwrap();
    let (first_status, first_body) = response_json(first_resp).await;
    let (second_status, second_body) = response_json(second_resp).await;
    assert_eq!(
        first_status,
        StatusCode::SERVICE_UNAVAILABLE,
        "first request should fail provisioning: {first_body}"
    );
    assert_eq!(
        second_status,
        StatusCode::CREATED,
        "second request should proceed after lock release: {second_body}"
    );
    assert_eq!(
        controlled.create_call_count(),
        2,
        "first create should fail and second create should retry after lock release"
    );
    assert_eq!(
        controlled.vm_count(),
        1,
        "only the second (successful) provisioning attempt should produce a VM"
    );
}

// ---------------------------------------------------------------------------
// 4. create with invalid name returns 400
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_with_invalid_name_returns_400() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let jwt = create_test_jwt(customer.id);
    let app = test_app_with_repos(customer_repo, mock_deployment_repo());

    // Leading hyphen
    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(
                    json!({"name": "-bad-name", "region": "us-east-1"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body["error"].as_str().unwrap().contains("alphanumeric"));
}

// ---------------------------------------------------------------------------
// 5. create with invalid region returns 400
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_with_invalid_region_returns_400() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let jwt = create_test_jwt(customer.id);
    let app = test_app_with_repos(customer_repo, mock_deployment_repo());

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(
                    json!({"name": "good-name", "region": "ap-southeast-1"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body["error"].as_str().unwrap().contains("region"));
}

// ---------------------------------------------------------------------------
// 6. create exceeds limit returns 400
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_exceeds_limit_returns_400() {
    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let customer = customer_repo.seed_verified_shared_customer("Alice", "alice@example.com");
    let jwt = create_test_jwt(customer.id);

    // Seed a running deployment
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

    // Seed MAX indexes
    use api::repos::tenant_repo::TenantRepo;
    for i in 0..20 {
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
                .method(http::Method::POST)
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
    assert!(body["error"].as_str().unwrap().contains("limit"));
}

// ---------------------------------------------------------------------------
// 7. create duplicate name returns 409
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_duplicate_name_returns_409() {
    let setup = setup_proxy_test().await;

    setup
        .http_client
        .push_json_response(409, json!({"error": "index already exists"}));

    let resp = setup
        .app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {}", setup.jwt))
                .body(Body::from(
                    json!({"name": "existing-index", "region": "us-east-1"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, _body) = response_json(resp).await;
    // Flapjack returns 409 → ProxyError::FlapjackError{409} → ApiError::Conflict → 409
    // OR tenant_repo.create returns Conflict if name+customer already exists
    assert_eq!(status, StatusCode::CONFLICT);

    let requests = setup.http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(requests[0].url, "https://vm-proxy.flapjack.foo/1/indexes");
}

// ---------------------------------------------------------------------------
// 8. list returns all indexes
// ---------------------------------------------------------------------------

#[tokio::test]
async fn list_returns_all_indexes() {
    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
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

    use api::repos::tenant_repo::TenantRepo;
    tenant_repo
        .create(customer.id, "index-1", deployment.id)
        .await
        .unwrap();
    tenant_repo
        .create(customer.id, "index-2", deployment.id)
        .await
        .unwrap();

    let app = test_app_with_indexes(
        customer_repo,
        deployment_repo,
        tenant_repo,
        mock_flapjack_proxy(),
    );

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/indexes")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    let indexes = body.as_array().unwrap();
    assert_eq!(indexes.len(), 2);
    let names: Vec<&str> = indexes
        .iter()
        .map(|i| i["name"].as_str().unwrap())
        .collect();
    assert!(names.contains(&"index-1"));
    assert!(names.contains(&"index-2"));
    assert!(
        indexes.iter().all(|i| i["tier"] == "active"),
        "all seeded indexes should default to active tier"
    );
    assert!(indexes
        .iter()
        .all(|i| i.get("last_accessed_at").is_none() && i.get("cold_since").is_none()));
}

#[tokio::test]
async fn list_includes_cold_since_for_cold_indexes() {
    use api::models::cold_snapshot::NewColdSnapshot;
    use api::repos::cold_snapshot_repo::ColdSnapshotRepo;
    use api::repos::tenant_repo::TenantRepo;
    use api::repos::InMemoryColdSnapshotRepo;
    use chrono::Utc;
    use uuid::Uuid;

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let cold_snapshot_repo = Arc::new(InMemoryColdSnapshotRepo::new());
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
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

    tenant_repo
        .create(customer.id, "cold-index", deployment.id)
        .await
        .unwrap();
    tenant_repo
        .set_tier(customer.id, "cold-index", "cold")
        .await
        .unwrap();
    let last_accessed_at = Utc::now();
    tenant_repo
        .set_last_accessed_at(customer.id, "cold-index", Some(last_accessed_at))
        .unwrap();

    let snapshot = cold_snapshot_repo
        .create(NewColdSnapshot {
            customer_id: customer.id,
            tenant_id: "cold-index".to_string(),
            source_vm_id: Uuid::new_v4(),
            object_key: "cold/test/cold-index.fj".to_string(),
        })
        .await
        .unwrap();
    cold_snapshot_repo.set_exporting(snapshot.id).await.unwrap();
    cold_snapshot_repo
        .set_completed(snapshot.id, 1024, "deadbeef")
        .await
        .unwrap();
    let completed_at = cold_snapshot_repo
        .get(snapshot.id)
        .await
        .unwrap()
        .unwrap()
        .completed_at
        .unwrap();

    tenant_repo
        .set_cold_snapshot_id(customer.id, "cold-index", Some(snapshot.id))
        .await
        .unwrap();

    let mut state = test_state_with_indexes(
        customer_repo,
        deployment_repo,
        tenant_repo,
        mock_flapjack_proxy(),
    );
    state.cold_snapshot_repo = cold_snapshot_repo;
    let app = build_router(state);

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/indexes")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    let indexes = body.as_array().expect("list response array");
    assert_eq!(indexes.len(), 1);
    assert_eq!(indexes[0]["name"], "cold-index");
    assert_eq!(indexes[0]["tier"], "cold");
    assert_eq!(
        indexes[0]["last_accessed_at"].as_str().unwrap(),
        last_accessed_at.to_rfc3339()
    );
    assert_eq!(
        indexes[0]["cold_since"].as_str().unwrap(),
        completed_at.to_rfc3339()
    );
}

// ---------------------------------------------------------------------------
// 9. list empty returns empty array
// ---------------------------------------------------------------------------

#[tokio::test]
async fn list_empty_returns_empty_array() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let jwt = create_test_jwt(customer.id);
    let app = test_app_with_repos(customer_repo, mock_deployment_repo());

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/indexes")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body.as_array().unwrap().len(), 0);
}

// ---------------------------------------------------------------------------
// 10. get returns index with stats
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_returns_index_with_stats() {
    use api::repos::tenant_repo::TenantRepo;

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let node_secret_manager = Arc::new(api::secrets::mock::MockNodeSecretManager::new());

    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
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

    tenant_repo
        .create(customer.id, "my-index", deployment.id)
        .await
        .unwrap();

    let vm = vm_inventory_repo.seed("us-east-1", "https://vm-test.flapjack.foo");
    tenant_repo
        .set_vm_id(customer.id, "my-index", vm.id)
        .await
        .unwrap();

    // Mock flapjack list_indexes response (get_index_stats fetches all then filters).
    // The proxy looks up by UID (customer_id + index_name), so the mock must match.
    let flapjack_uid = test_flapjack_uid(customer.id, "my-index");
    http_client.push_json_response(
        200,
        json!({
            "items": [
                {
                    "name": flapjack_uid,
                    "entries": 1500,
                    "dataSize": 4096000,
                    "fileSize": 8192000,
                    "createdAt": "2026-02-20T10:00:00Z",
                    "updatedAt": "2026-02-21T10:00:00Z"
                }
            ],
            "nbPages": 1
        }),
    );

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

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/indexes/my-index")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["name"], "my-index");
    assert_eq!(body["entries"], 1500);
    assert_eq!(body["data_size_bytes"], 4096000);
    assert_eq!(body["region"], "us-east-1");
    assert_eq!(body["status"], "healthy");
    assert_eq!(body["tier"], "active");
    assert!(body.get("last_accessed_at").is_none());
    assert!(body.get("cold_since").is_none());

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(requests[0].url, "https://vm-test.flapjack.foo/1/indexes");
}

#[tokio::test]
async fn get_returns_cold_since_for_cold_index() {
    use api::models::cold_snapshot::NewColdSnapshot;
    use api::repos::cold_snapshot_repo::ColdSnapshotRepo;
    use api::repos::tenant_repo::TenantRepo;
    use api::repos::InMemoryColdSnapshotRepo;
    use uuid::Uuid;

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let cold_snapshot_repo = Arc::new(InMemoryColdSnapshotRepo::new());
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let jwt = create_test_jwt(customer.id);

    let deployment = deployment_repo.seed(
        customer.id,
        "node-a1",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
    );
    tenant_repo.seed_deployment(deployment.id, "us-east-1", None, "healthy", "running");

    tenant_repo
        .create(customer.id, "cold-index", deployment.id)
        .await
        .unwrap();
    tenant_repo
        .set_tier(customer.id, "cold-index", "cold")
        .await
        .unwrap();

    let snapshot = cold_snapshot_repo
        .create(NewColdSnapshot {
            customer_id: customer.id,
            tenant_id: "cold-index".to_string(),
            source_vm_id: Uuid::new_v4(),
            object_key: "cold/test/cold-index.fj".to_string(),
        })
        .await
        .unwrap();
    cold_snapshot_repo.set_exporting(snapshot.id).await.unwrap();
    cold_snapshot_repo
        .set_completed(snapshot.id, 4096, "checksum")
        .await
        .unwrap();
    let completed_at = cold_snapshot_repo
        .get(snapshot.id)
        .await
        .unwrap()
        .unwrap()
        .completed_at
        .unwrap();

    tenant_repo
        .set_cold_snapshot_id(customer.id, "cold-index", Some(snapshot.id))
        .await
        .unwrap();

    let mut state = test_state_with_indexes(
        customer_repo,
        deployment_repo,
        tenant_repo,
        mock_flapjack_proxy(),
    );
    state.cold_snapshot_repo = cold_snapshot_repo;
    let app = build_router(state);

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/indexes/cold-index")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["name"], "cold-index");
    assert_eq!(body["tier"], "cold");
    assert_eq!(body["entries"], 0);
    assert_eq!(body["data_size_bytes"], 0);
    assert_eq!(
        body["cold_since"].as_str().unwrap(),
        completed_at.to_rfc3339()
    );
}

// ---------------------------------------------------------------------------
// 11. get non-existent returns 404
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_nonexistent_returns_404() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let jwt = create_test_jwt(customer.id);
    let app = test_app_with_repos(customer_repo, mock_deployment_repo());

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/indexes/nonexistent")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(body["error"].as_str().unwrap().contains("nonexistent"));
}

// ---------------------------------------------------------------------------
// 12. delete with confirm returns 204
// ---------------------------------------------------------------------------

#[tokio::test]
async fn delete_with_confirm_returns_204() {
    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let node_secret_manager = Arc::new(api::secrets::mock::MockNodeSecretManager::new());

    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
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

    use api::repos::tenant_repo::TenantRepo;
    tenant_repo
        .create(customer.id, "doomed-index", deployment.id)
        .await
        .unwrap();

    let vm = vm_inventory_repo.seed("us-east-1", "https://vm-test.flapjack.foo");
    tenant_repo
        .set_vm_id(customer.id, "doomed-index", vm.id)
        .await
        .unwrap();

    http_client.push_json_response(200, json!({}));

    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client(
        http_client.clone(),
        node_secret_manager,
    ));
    let app = test_app_with_indexes_and_vm_inventory(
        customer_repo,
        deployment_repo,
        Arc::clone(&tenant_repo),
        flapjack_proxy,
        vm_inventory_repo,
    );

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::DELETE)
                .uri("/indexes/doomed-index")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(json!({"confirm": true}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NO_CONTENT);

    // Verify it was removed from catalog
    let result = tenant_repo
        .find_by_name(customer.id, "doomed-index")
        .await
        .unwrap();
    assert!(result.is_none());

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::DELETE);
    assert_eq!(
        requests[0].url,
        format!(
            "https://vm-test.flapjack.foo/1/indexes/{}",
            test_flapjack_uid(customer.id, "doomed-index")
        )
    );
}

// ---------------------------------------------------------------------------
// 13. delete without confirm returns 400
// ---------------------------------------------------------------------------

#[tokio::test]
async fn delete_without_confirm_returns_400() {
    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
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

    use api::repos::tenant_repo::TenantRepo;
    tenant_repo
        .create(customer.id, "my-index", deployment.id)
        .await
        .unwrap();

    let app = test_app_with_indexes(
        customer_repo,
        deployment_repo,
        tenant_repo,
        mock_flapjack_proxy(),
    );

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::DELETE)
                .uri("/indexes/my-index")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(json!({"confirm": false}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body["error"].as_str().unwrap().contains("confirm"));
}

// ---------------------------------------------------------------------------
// 14. search proxies to flapjack
// ---------------------------------------------------------------------------

#[tokio::test]
async fn search_proxies_to_flapjack() {
    let (app, jwt, http_client, customer_id) = setup_ready_index("searchable").await;

    http_client.push_json_response(
        200,
        json!({
            "hits": [{"objectID": "1", "title": "Hello World"}],
            "nbHits": 1,
            "processingTimeMs": 2
        }),
    );

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/searchable/search")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(json!({"query": "hello"}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["nbHits"], 1);
    assert_eq!(body["hits"][0]["title"], "Hello World");

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(
        requests[0].url,
        format!(
            "https://vm-test.flapjack.foo/1/indexes/{}/query",
            test_flapjack_uid(customer_id, "searchable")
        )
    );
}

// ---------------------------------------------------------------------------
// 14b. search returns 503 when flapjack is unreachable
// ---------------------------------------------------------------------------

#[tokio::test]
async fn search_returns_503_when_flapjack_unreachable() {
    assert_classic_route_proxy_error(
        ClassicRouteProxyFailureCase::search("searchable", json!({"query": "hello"})),
        ProxyError::Unreachable("connection refused".into()),
        ProxyFailureExpectation::service_unavailable("backend temporarily unavailable"),
    )
    .await;
}

#[tokio::test]
async fn search_returns_503_when_flapjack_times_out() {
    assert_classic_route_proxy_error(
        ClassicRouteProxyFailureCase::search("searchable", json!({"query": "hello"})),
        ProxyError::Timeout,
        ProxyFailureExpectation::service_unavailable("request timed out"),
    )
    .await;
}

#[tokio::test]
async fn search_returns_500_when_flapjack_returns_502() {
    assert_classic_route_proxy_error(
        ClassicRouteProxyFailureCase::search("searchable", json!({"query": "hello"})),
        ProxyError::FlapjackError {
            status: 502,
            message: "bad gateway from upstream engine".into(),
        },
        ProxyFailureExpectation::internal_server_error(
            "internal server error",
            Some("bad gateway from upstream engine"),
        ),
    )
    .await;
}

// ---------------------------------------------------------------------------
// 15. settings returns config
// ---------------------------------------------------------------------------

#[tokio::test]
async fn settings_returns_config() {
    let (app, jwt, http_client, customer_id) = setup_ready_index("configured").await;

    http_client.push_json_response(
        200,
        json!({
            "searchableAttributes": ["title", "body"],
            "filterableAttributes": ["category"],
            "sortableAttributes": ["date"]
        }),
    );

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/indexes/configured/settings")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert!(body["searchableAttributes"].is_array());
    assert_eq!(body["searchableAttributes"][0], "title");

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        format!(
            "https://vm-test.flapjack.foo/1/indexes/{}/settings",
            test_flapjack_uid(customer_id, "configured")
        )
    );
}

// ---------------------------------------------------------------------------
// 16. create key returns key value
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_key_returns_key_value() {
    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let node_secret_manager = Arc::new(api::secrets::mock::MockNodeSecretManager::new());

    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
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

    use api::repos::tenant_repo::TenantRepo;
    tenant_repo
        .create(customer.id, "keyed-index", deployment.id)
        .await
        .unwrap();

    let vm = vm_inventory_repo.seed("us-east-1", "https://vm-test.flapjack.foo");
    tenant_repo
        .set_vm_id(customer.id, "keyed-index", vm.id)
        .await
        .unwrap();

    http_client.push_json_response(
        200,
        json!({
            "key": "fj_search_abc123def456",
            "createdAt": "2026-02-21T12:00:00Z"
        }),
    );

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

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/keyed-index/keys")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(
                    json!({
                        "description": "production key",
                        "acl": ["search", "browse"]
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(body["key"], "fj_search_abc123def456");
    assert!(body["createdAt"].is_string());

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(requests[0].url, "https://vm-test.flapjack.foo/1/keys");
    let payload = requests[0]
        .json_body
        .as_ref()
        .expect("create key request should include json body");
    assert_eq!(payload["description"], "production key");
    assert_eq!(
        payload["indexes"],
        json!([test_flapjack_uid(customer.id, "keyed-index")])
    );
    assert_eq!(payload["acl"], json!(["search", "browse"]));
}

// ---------------------------------------------------------------------------
// 16b. create key accepts addObject ACL
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_key_with_add_object_acl_returns_key_value() {
    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let node_secret_manager = Arc::new(api::secrets::mock::MockNodeSecretManager::new());

    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
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

    use api::repos::tenant_repo::TenantRepo;
    tenant_repo
        .create(customer.id, "add-object-index", deployment.id)
        .await
        .unwrap();

    let vm = vm_inventory_repo.seed("us-east-1", "https://vm-test.flapjack.foo");
    tenant_repo
        .set_vm_id(customer.id, "add-object-index", vm.id)
        .await
        .unwrap();

    http_client.push_json_response(
        200,
        json!({
            "key": "fj_search_with_add_object_acl",
            "createdAt": "2026-02-21T12:00:00Z"
        }),
    );

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

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/add-object-index/keys")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(
                    json!({
                        "description": "ingest key",
                        "acl": ["search", "addObject"]
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(body["key"], "fj_search_with_add_object_acl");
    assert!(body["createdAt"].is_string());

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(requests[0].url, "https://vm-test.flapjack.foo/1/keys");
    let payload = requests[0]
        .json_body
        .as_ref()
        .expect("create key request should include json body");
    assert_eq!(payload["description"], "ingest key");
    assert_eq!(
        payload["indexes"],
        json!([test_flapjack_uid(customer.id, "add-object-index")])
    );
    assert_eq!(payload["acl"], json!(["search", "addObject"]));
}

// ---------------------------------------------------------------------------
// 17. create key with invalid acl returns 400
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_key_with_invalid_acl_returns_400() {
    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
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

    use api::repos::tenant_repo::TenantRepo;
    tenant_repo
        .create(customer.id, "my-index", deployment.id)
        .await
        .unwrap();

    let app = test_app_with_indexes(
        customer_repo,
        deployment_repo,
        tenant_repo,
        mock_flapjack_proxy(),
    );

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/my-index/keys")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(
                    json!({
                        "description": "bad key",
                        "acl": ["search", "indexing"]
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body["error"].as_str().unwrap().contains("indexing"));
}

// ---------------------------------------------------------------------------
// 18. 401 without auth
// ---------------------------------------------------------------------------

#[tokio::test]
async fn no_auth_returns_401() {
    let app = test_app_with_repos(mock_repo(), mock_deployment_repo());

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/indexes")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

// ---------------------------------------------------------------------------
// 19. create key with empty acl returns 400
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_key_with_empty_acl_returns_400() {
    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
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

    use api::repos::tenant_repo::TenantRepo;
    tenant_repo
        .create(customer.id, "my-index", deployment.id)
        .await
        .unwrap();

    let app = test_app_with_indexes(
        customer_repo,
        deployment_repo,
        tenant_repo,
        mock_flapjack_proxy(),
    );

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/my-index/keys")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(
                    json!({
                        "description": "empty acl key",
                        "acl": []
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body["error"].as_str().unwrap().contains("empty"));
}

// ---------------------------------------------------------------------------
// 20. create with reserved name returns 400
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_with_reserved_name_returns_400() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let jwt = create_test_jwt(customer.id);
    let app = test_app_with_repos(customer_repo, mock_deployment_repo());

    for reserved in &["health", "metrics"] {
        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(http::Method::POST)
                    .uri("/indexes")
                    .header("content-type", "application/json")
                    .header("authorization", format!("Bearer {jwt}"))
                    .body(Body::from(
                        json!({"name": reserved, "region": "us-east-1"}).to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();

        let (status, body) = response_json(resp).await;
        assert_eq!(
            status,
            StatusCode::BAD_REQUEST,
            "reserved name '{reserved}' should be rejected"
        );
        assert!(
            body["error"].as_str().unwrap().contains("reserved"),
            "error for '{reserved}' should mention 'reserved'"
        );
    }
}

// ---------------------------------------------------------------------------
// 21. create with too-long name returns 400
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_with_too_long_name_returns_400() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let jwt = create_test_jwt(customer.id);
    let app = test_app_with_repos(customer_repo, mock_deployment_repo());

    let long_name = "a".repeat(65);
    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(
                    json!({"name": long_name, "region": "us-east-1"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body["error"].as_str().unwrap().contains("64"));
}

// ---------------------------------------------------------------------------
// 22. delete succeeds even when flapjack proxy fails (catalog-first ordering)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn delete_succeeds_when_flapjack_proxy_fails() {
    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let node_secret_manager = Arc::new(api::secrets::mock::MockNodeSecretManager::new());

    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
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

    use api::repos::tenant_repo::TenantRepo;
    tenant_repo
        .create(customer.id, "doomed-index", deployment.id)
        .await
        .unwrap();

    let vm = vm_inventory_repo.seed("us-east-1", "https://vm-test.flapjack.foo");
    tenant_repo
        .set_vm_id(customer.id, "doomed-index", vm.id)
        .await
        .unwrap();

    // Flapjack returns 500 — catalog deletion should still succeed.
    http_client.push_json_response(500, json!({"error": "internal error"}));

    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client(
        http_client.clone(),
        node_secret_manager,
    ));
    let app = test_app_with_indexes_and_vm_inventory(
        customer_repo,
        deployment_repo,
        Arc::clone(&tenant_repo),
        flapjack_proxy,
        vm_inventory_repo,
    );

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::DELETE)
                .uri("/indexes/doomed-index")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(json!({"confirm": true}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR);
    assert_eq!(body["error"], "internal server error");

    // Verify the catalog row is retained so the customer can retry deletion
    // instead of leaving backend data orphaned behind a previously issued key.
    let result = tenant_repo
        .find_by_name(customer.id, "doomed-index")
        .await
        .unwrap();
    assert!(
        result.is_some(),
        "index should remain in catalog when flapjack deletion fails"
    );

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::DELETE);
    assert_eq!(
        requests[0].url,
        format!(
            "https://vm-test.flapjack.foo/1/indexes/{}",
            test_flapjack_uid(customer.id, "doomed-index")
        )
    );
}

// ---------------------------------------------------------------------------
// 23. delete still succeeds when vm_inventory mapping is missing
// ---------------------------------------------------------------------------

#[tokio::test]
async fn delete_succeeds_when_vm_inventory_row_is_missing() {
    use api::repos::tenant_repo::TenantRepo;
    use uuid::Uuid;

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let node_secret_manager = Arc::new(api::secrets::mock::MockNodeSecretManager::new());

    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
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
        Some("https://legacy-vm.flapjack.foo"),
    );

    tenant_repo.seed_deployment(
        deployment.id,
        "us-east-1",
        Some("https://legacy-vm.flapjack.foo"),
        "healthy",
        "running",
    );

    tenant_repo
        .create(customer.id, "orphaned-index", deployment.id)
        .await
        .unwrap();

    // Simulate stale mapping: vm_id exists on tenant row but referenced VM row is gone.
    tenant_repo
        .set_vm_id(customer.id, "orphaned-index", Uuid::new_v4())
        .await
        .unwrap();

    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client(
        http_client.clone(),
        node_secret_manager,
    ));
    let app = test_app_with_indexes(
        customer_repo,
        deployment_repo,
        Arc::clone(&tenant_repo),
        flapjack_proxy,
    );

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::DELETE)
                .uri("/indexes/orphaned-index")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(json!({"confirm": true}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NO_CONTENT);

    let result = tenant_repo
        .find_by_name(customer.id, "orphaned-index")
        .await
        .unwrap();
    assert!(
        result.is_none(),
        "catalog row should be removed even when vm_inventory mapping is stale"
    );

    assert!(
        http_client.take_requests().is_empty(),
        "no flapjack call should be made when vm target cannot be resolved"
    );
}

// ---------------------------------------------------------------------------
// 24. delete non-existent index returns 404
// ---------------------------------------------------------------------------

#[tokio::test]
async fn delete_succeeds_when_deployment_row_is_missing() {
    use api::repos::tenant_repo::TenantRepo;
    use uuid::Uuid;

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let node_secret_manager = Arc::new(api::secrets::mock::MockNodeSecretManager::new());

    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let jwt = create_test_jwt(customer.id);
    let missing_deployment_id = Uuid::new_v4();

    // Seed summary metadata so find_by_name succeeds, but do not seed deployment_repo.
    // This simulates a stale tenant->deployment pointer in route-layer state.
    tenant_repo.seed_deployment(
        missing_deployment_id,
        "us-east-1",
        Some("https://legacy-vm.flapjack.foo"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(
            customer.id,
            "missing-deployment-index",
            missing_deployment_id,
        )
        .await
        .unwrap();

    let vm = vm_inventory_repo.seed("us-east-1", "https://shared-vm.flapjack.foo");
    tenant_repo
        .set_vm_id(customer.id, "missing-deployment-index", vm.id)
        .await
        .unwrap();

    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client(
        http_client.clone(),
        node_secret_manager,
    ));
    let app = test_app_with_indexes_and_vm_inventory(
        customer_repo,
        deployment_repo,
        Arc::clone(&tenant_repo),
        flapjack_proxy,
        vm_inventory_repo,
    );

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::DELETE)
                .uri("/indexes/missing-deployment-index")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(json!({"confirm": true}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NO_CONTENT);

    let result = tenant_repo
        .find_by_name(customer.id, "missing-deployment-index")
        .await
        .unwrap();
    assert!(
        result.is_none(),
        "catalog row should be removed even when deployment mapping is stale"
    );

    assert!(
        http_client.take_requests().is_empty(),
        "no flapjack call should be made when deployment/node metadata cannot be resolved"
    );
}

#[tokio::test]
async fn delete_nonexistent_returns_404() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let jwt = create_test_jwt(customer.id);
    let app = test_app_with_repos(customer_repo, mock_deployment_repo());

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::DELETE)
                .uri("/indexes/nonexistent")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(json!({"confirm": true}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(body["error"].as_str().unwrap().contains("nonexistent"));
}

// ---------------------------------------------------------------------------
// 24. cross-tenant isolation — customer B cannot see customer A's indexes
// ---------------------------------------------------------------------------

#[tokio::test]
async fn cross_tenant_isolation_list() {
    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();

    let alice = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let bob = customer_repo.seed_verified_free_customer("Bob", "bob@example.com");

    // Alice has a deployment and an index
    let deployment = deployment_repo.seed_provisioned(
        alice.id,
        "node-a1",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("https://vm-alice.flapjack.foo"),
    );
    tenant_repo.seed_deployment(
        deployment.id,
        "us-east-1",
        Some("https://vm-alice.flapjack.foo"),
        "healthy",
        "running",
    );
    use api::repos::tenant_repo::TenantRepo;
    tenant_repo
        .create(alice.id, "alice-secret-index", deployment.id)
        .await
        .unwrap();

    let bob_jwt = create_test_jwt(bob.id);

    let app = test_app_with_indexes(
        customer_repo,
        deployment_repo,
        tenant_repo,
        mock_flapjack_proxy(),
    );

    // Bob lists indexes — should see none (not Alice's)
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/indexes")
                .header("authorization", format!("Bearer {bob_jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        body.as_array().unwrap().len(),
        0,
        "Bob must not see Alice's indexes"
    );

    // Bob tries to get Alice's index by name — should get 404
    let resp = app
        .oneshot(
            Request::builder()
                .uri("/indexes/alice-secret-index")
                .header("authorization", format!("Bearer {bob_jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, _body) = response_json(resp).await;
    assert_eq!(
        status,
        StatusCode::NOT_FOUND,
        "Bob must not access Alice's index by name"
    );
}

// ---------------------------------------------------------------------------
// 25. get_index graceful degradation when proxy fails — returns 200 with entries=0
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_index_returns_zeros_when_proxy_fails() {
    use api::repos::tenant_repo::TenantRepo;

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let node_secret_manager = Arc::new(api::secrets::mock::MockNodeSecretManager::new());

    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
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

    tenant_repo
        .create(customer.id, "my-index", deployment.id)
        .await
        .unwrap();

    let vm = vm_inventory_repo.seed("us-east-1", "https://vm-test.flapjack.foo");
    tenant_repo
        .set_vm_id(customer.id, "my-index", vm.id)
        .await
        .unwrap();

    // Flapjack returns 500 — handler should degrade gracefully.
    http_client.push_json_response(500, json!({"error": "internal error"}));

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

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/indexes/my-index")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    // Should return 200 with zeros, not propagate the 500
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["name"], "my-index");
    assert_eq!(body["entries"], 0, "entries should be 0 when proxy fails");
    assert_eq!(
        body["data_size_bytes"], 0,
        "data_size_bytes should be 0 when proxy fails"
    );
    assert_eq!(body["region"], "us-east-1");

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(requests[0].url, "https://vm-test.flapjack.foo/1/indexes");
}

// ---------------------------------------------------------------------------
// 26. search on index with no flapjack_url returns 400
// ---------------------------------------------------------------------------

#[tokio::test]
async fn search_on_provisioning_index_returns_400() {
    use api::repos::tenant_repo::TenantRepo;

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let jwt = create_test_jwt(customer.id);

    // Seed a provisioning deployment with no flapjack_url
    let deployment = deployment_repo.seed(
        customer.id,
        "node-a1",
        "us-east-1",
        "t4g.small",
        "aws",
        "provisioning",
    );
    tenant_repo.seed_deployment(deployment.id, "us-east-1", None, "unknown", "provisioning");

    tenant_repo
        .create(customer.id, "early-index", deployment.id)
        .await
        .unwrap();

    let app = test_app_with_indexes(
        customer_repo,
        deployment_repo,
        tenant_repo,
        mock_flapjack_proxy(),
    );

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/early-index/search")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(json!({"query": "test"}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(
        body["error"].as_str().unwrap().contains("not ready"),
        "should indicate endpoint not ready, got: {}",
        body["error"]
    );
}

// ---------------------------------------------------------------------------
// 27. search on index with stale vm_id mapping returns 400 (not 500)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn search_with_stale_vm_mapping_returns_400() {
    use api::repos::tenant_repo::TenantRepo;
    use uuid::Uuid;

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let jwt = create_test_jwt(customer.id);

    let deployment = deployment_repo.seed_provisioned(
        customer.id,
        "node-a1",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("https://legacy-vm.flapjack.foo"),
    );
    tenant_repo.seed_deployment(
        deployment.id,
        "us-east-1",
        Some("https://legacy-vm.flapjack.foo"),
        "healthy",
        "running",
    );

    tenant_repo
        .create(customer.id, "stale-index", deployment.id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer.id, "stale-index", Uuid::new_v4())
        .await
        .unwrap();

    let app = test_app_with_indexes(
        customer_repo,
        deployment_repo,
        tenant_repo,
        mock_flapjack_proxy(),
    );

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/stale-index/search")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(json!({"query": "test"}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(
        body["error"].as_str().unwrap().contains("not ready"),
        "stale vm mapping should degrade to not-ready response, got: {}",
        body["error"]
    );
}

// ---------------------------------------------------------------------------
// 28. settings on index with no flapjack_url returns 400
// ---------------------------------------------------------------------------

#[tokio::test]
async fn settings_on_provisioning_index_returns_400() {
    use api::repos::tenant_repo::TenantRepo;

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let jwt = create_test_jwt(customer.id);

    let deployment = deployment_repo.seed(
        customer.id,
        "node-a1",
        "us-east-1",
        "t4g.small",
        "aws",
        "provisioning",
    );
    tenant_repo.seed_deployment(deployment.id, "us-east-1", None, "unknown", "provisioning");

    tenant_repo
        .create(customer.id, "early-index", deployment.id)
        .await
        .unwrap();

    let app = test_app_with_indexes(
        customer_repo,
        deployment_repo,
        tenant_repo,
        mock_flapjack_proxy(),
    );

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/indexes/early-index/settings")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(
        body["error"].as_str().unwrap().contains("not ready"),
        "should indicate endpoint not ready, got: {}",
        body["error"]
    );
}

// ---------------------------------------------------------------------------
// 29. create key on index with no flapjack_url returns 400
// ---------------------------------------------------------------------------

struct ProvisioningCreateKeySetup {
    app: axum::Router,
    tenant_repo: Arc<common::MockTenantRepo>,
    customer_id: uuid::Uuid,
    jwt: String,
}

async fn setup_provisioning_create_key_test() -> ProvisioningCreateKeySetup {
    use api::repos::tenant_repo::TenantRepo;

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let jwt = create_test_jwt(customer.id);

    let deployment = deployment_repo.seed(
        customer.id,
        "node-a1",
        "us-east-1",
        "t4g.small",
        "aws",
        "provisioning",
    );
    tenant_repo.seed_deployment(deployment.id, "us-east-1", None, "unknown", "provisioning");

    tenant_repo
        .create(customer.id, "early-index", deployment.id)
        .await
        .unwrap();

    let app = test_app_with_indexes(
        customer_repo,
        deployment_repo,
        tenant_repo.clone(),
        mock_flapjack_proxy(),
    );

    ProvisioningCreateKeySetup {
        app,
        tenant_repo,
        customer_id: customer.id,
        jwt,
    }
}

fn create_key_request(jwt: &str, index_name: &str) -> Request<Body> {
    Request::builder()
        .method(http::Method::POST)
        .uri(format!("/indexes/{index_name}/keys"))
        .header("content-type", "application/json")
        .header("authorization", format!("Bearer {jwt}"))
        .body(Body::from(
            json!({"description": "test key", "acl": ["search"]}).to_string(),
        ))
        .unwrap()
}

#[tokio::test]
async fn create_key_on_provisioning_index_returns_400() {
    let setup = setup_provisioning_create_key_test().await;

    let resp = setup
        .app
        .oneshot(create_key_request(&setup.jwt, "early-index"))
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(
        body["error"].as_str().unwrap().contains("not ready"),
        "should indicate endpoint not ready, got: {}",
        body["error"]
    );
}

#[tokio::test]
async fn create_key_on_provisioning_index_still_enforces_write_rate_limit() {
    use api::repos::tenant_repo::TenantRepo;

    let setup = setup_provisioning_create_key_test().await;
    setup
        .tenant_repo
        .set_resource_quota(
            setup.customer_id,
            "early-index",
            json!({"max_write_rps": 1}),
        )
        .await
        .unwrap();

    let first = setup
        .app
        .clone()
        .oneshot(create_key_request(&setup.jwt, "early-index"))
        .await
        .unwrap();

    let (first_status, first_body) = response_json(first).await;
    assert_eq!(first_status, StatusCode::BAD_REQUEST);
    assert!(
        first_body["error"].as_str().unwrap().contains("not ready"),
        "first request should still surface endpoint readiness, got: {}",
        first_body["error"]
    );

    let second = setup
        .app
        .oneshot(create_key_request(&setup.jwt, "early-index"))
        .await
        .unwrap();

    let retry_after = second.headers().get("retry-after").cloned();
    let (second_status, second_body) = response_json(second).await;
    assert_eq!(second_status, StatusCode::TOO_MANY_REQUESTS);
    assert!(
        retry_after.is_some(),
        "throttled write response should include retry-after"
    );
    assert!(
        second_body["error"]
            .as_str()
            .unwrap()
            .contains("write rate limit exceeded"),
        "second request should be throttled before endpoint readiness, got: {}",
        second_body["error"]
    );
}

// ---------------------------------------------------------------------------
// 30. get routes via vm_inventory when tenant has vm_id assigned
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_routes_via_vm_inventory_when_tenant_has_vm_id() {
    use api::models::vm_inventory::NewVmInventory;
    use api::repos::tenant_repo::TenantRepo;
    use api::repos::vm_inventory_repo::VmInventoryRepo;

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let node_secret_manager = Arc::new(api::secrets::mock::MockNodeSecretManager::new());

    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
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
        Some("https://legacy-vm.flapjack.foo"),
    );

    tenant_repo.seed_deployment(
        deployment.id,
        "us-east-1",
        Some("https://legacy-vm.flapjack.foo"),
        "healthy",
        "running",
    );

    tenant_repo
        .create(customer.id, "my-index", deployment.id)
        .await
        .unwrap();

    let vm = vm_inventory_repo
        .create(NewVmInventory {
            region: "us-east-1".to_string(),
            provider: "aws".to_string(),
            hostname: "vm-shared.flapjack.foo".to_string(),
            flapjack_url: "https://shared-vm.flapjack.foo".to_string(),
            capacity: serde_json::json!({}),
        })
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer.id, "my-index", vm.id)
        .await
        .unwrap();

    // The proxy looks up stats by UID, so mock response must use the UID format
    let flapjack_uid = test_flapjack_uid(customer.id, "my-index");
    http_client.push_json_response(
        200,
        json!({
            "items": [{
                "name": flapjack_uid,
                "entries": 999,
                "dataSize": 9999,
                "fileSize": 8888,
                "createdAt": "2026-02-20T10:00:00Z",
                "updatedAt": "2026-02-21T10:00:00Z"
            }],
            "nbPages": 1
        }),
    );

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

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/indexes/my-index")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        body["entries"], 999,
        "when vm_id is set, routing should use vm_inventory.flapjack_url"
    );
    assert_eq!(body["data_size_bytes"], 9999);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(requests[0].url, "https://shared-vm.flapjack.foo/1/indexes");
}

// ---------------------------------------------------------------------------
// 30. delete routes via vm_inventory when tenant has vm_id assigned
// ---------------------------------------------------------------------------

#[tokio::test]
async fn delete_routes_via_vm_inventory_when_tenant_has_vm_id() {
    use api::models::vm_inventory::NewVmInventory;
    use api::repos::tenant_repo::TenantRepo;
    use api::repos::vm_inventory_repo::VmInventoryRepo;

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let node_secret_manager = Arc::new(api::secrets::mock::MockNodeSecretManager::new());

    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
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
        Some("https://legacy-vm.flapjack.foo"),
    );

    tenant_repo.seed_deployment(
        deployment.id,
        "us-east-1",
        Some("https://legacy-vm.flapjack.foo"),
        "healthy",
        "running",
    );

    tenant_repo
        .create(customer.id, "delete-me", deployment.id)
        .await
        .unwrap();

    let vm = vm_inventory_repo
        .create(NewVmInventory {
            region: "us-east-1".to_string(),
            provider: "aws".to_string(),
            hostname: "vm-shared.flapjack.foo".to_string(),
            flapjack_url: "https://shared-vm.flapjack.foo".to_string(),
            capacity: serde_json::json!({}),
        })
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer.id, "delete-me", vm.id)
        .await
        .unwrap();

    // Flapjack returns success for the DELETE
    http_client.push_json_response(200, json!({}));

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

    let resp = app
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri("/indexes/delete-me")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from(r#"{"confirm":true}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NO_CONTENT);

    // The DELETE request must go to the shared VM, not the legacy URL
    let requests = http_client.take_requests();
    assert_eq!(
        requests.len(),
        1,
        "proxy should have received one DELETE request"
    );
    assert_eq!(requests[0].method, reqwest::Method::DELETE);
    assert_eq!(
        requests[0].url,
        format!(
            "https://shared-vm.flapjack.foo/1/indexes/{}",
            test_flapjack_uid(customer.id, "delete-me")
        ),
        "delete should route via vm_inventory, not legacy deployment URL"
    );
}

// ---------------------------------------------------------------------------
// 31. search routes via vm_inventory when tenant has vm_id assigned
// ---------------------------------------------------------------------------

#[tokio::test]
async fn search_routes_via_vm_inventory_when_tenant_has_vm_id() {
    use api::models::vm_inventory::NewVmInventory;
    use api::repos::tenant_repo::TenantRepo;
    use api::repos::vm_inventory_repo::VmInventoryRepo;

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let node_secret_manager = Arc::new(api::secrets::mock::MockNodeSecretManager::new());

    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
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
        Some("https://legacy-vm.flapjack.foo"),
    );

    tenant_repo.seed_deployment(
        deployment.id,
        "us-east-1",
        Some("https://legacy-vm.flapjack.foo"),
        "healthy",
        "running",
    );

    tenant_repo
        .create(customer.id, "searchable", deployment.id)
        .await
        .unwrap();

    let vm = vm_inventory_repo
        .create(NewVmInventory {
            region: "us-east-1".to_string(),
            provider: "aws".to_string(),
            hostname: "vm-shared.flapjack.foo".to_string(),
            flapjack_url: "https://shared-vm.flapjack.foo".to_string(),
            capacity: serde_json::json!({}),
        })
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer.id, "searchable", vm.id)
        .await
        .unwrap();

    // Flapjack returns search results
    http_client.push_json_response(
        200,
        json!({
            "hits": [{"objectID": "1", "title": "Hello World"}],
            "nbHits": 1,
            "processingTimeMs": 2
        }),
    );

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

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/searchable/search")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(json!({"query": "hello"}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["nbHits"], 1);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(
        requests[0].url,
        format!(
            "https://shared-vm.flapjack.foo/1/indexes/{}/query",
            test_flapjack_uid(customer.id, "searchable")
        ),
        "search should route via vm_inventory, not legacy deployment URL"
    );
}

// ---------------------------------------------------------------------------
// 32. create always uses shared placement (no dedicated provisioning path)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_index_always_uses_shared_placement() {
    use api::models::vm_inventory::NewVmInventory;
    use api::repos::tenant_repo::TenantRepo;
    use api::repos::vm_inventory_repo::VmInventoryRepo;
    use api::repos::DeploymentRepo;

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let node_secret_manager = Arc::new(api::secrets::mock::MockNodeSecretManager::new());

    // Create a customer with no existing deployment.
    let customer = customer_repo.seed_verified_shared_customer("SharedCo", "shared@example.com");
    let jwt = create_test_jwt(customer.id);

    // Create a shared VM in us-east-1 with capacity
    let vm = vm_inventory_repo
        .create(NewVmInventory {
            region: "us-east-1".to_string(),
            provider: "aws".to_string(),
            hostname: "vm-shared-pool.flapjack.foo".to_string(),
            flapjack_url: "https://shared-pool.flapjack.foo".to_string(),
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
    vm_inventory_repo
        .update_load(vm.id, serde_json::json!({}))
        .await
        .unwrap();
    let vm_secret = node_secret_manager
        .create_node_api_key(vm.node_secret_id(), &vm.region)
        .await
        .unwrap();

    // No deployment exists for this customer — shared path should NOT auto-provision a VM

    // FlapjackProxy returns success for index creation
    http_client.push_json_response(200, json!({}));

    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client(
        http_client.clone(),
        node_secret_manager.clone(),
    ));

    // Build AppState with shared NodeSecretManager between proxy and provisioning service
    // so that keys created by the shared-placement path are visible to FlapjackProxy.
    let vm_provisioner = Arc::new(api::provisioner::mock::MockVmProvisioner::new());
    let dns_manager = Arc::new(api::dns::mock::MockDnsManager::new());
    let provisioning_service = Arc::new(api::services::provisioning::ProvisioningService::new(
        vm_provisioner.clone(),
        dns_manager.clone(),
        node_secret_manager.clone(), // same instance as proxy
        deployment_repo.clone(),
        customer_repo.clone(),
        "flapjack.foo".to_string(),
    ));
    let mut state = common::test_state_with_indexes_and_vm_inventory(
        customer_repo.clone(),
        deployment_repo.clone(),
        tenant_repo.clone(),
        flapjack_proxy,
        vm_inventory_repo.clone(),
    );
    state.vm_provisioner = vm_provisioner;
    state.dns_manager = dns_manager;
    state.provisioning_service = provisioning_service;

    let app = api::router::build_router(state);

    let resp = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/indexes")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({"name": "products", "region": "us-east-1"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;

    // Shared placement should return 201 immediately, not provisioning semantics.
    assert_eq!(
        status,
        StatusCode::CREATED,
        "create should be immediate shared placement, not async provisioning: {body}"
    );
    assert_eq!(body["name"], "products");
    assert_eq!(body["region"], "us-east-1");
    assert_eq!(
        body["endpoint"], "https://shared-pool.flapjack.foo",
        "endpoint should be the shared VM's URL"
    );

    // The index creation HTTP request should go to the shared VM
    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1, "should have exactly one proxy request");
    assert_eq!(
        requests[0].url, "https://shared-pool.flapjack.foo/1/indexes",
        "index should be created on the shared VM, not a newly provisioned one"
    );
    assert_eq!(
        requests[0].api_key, vm_secret,
        "shared placement must authenticate with the shared VM secret, not the synthetic deployment node"
    );
    assert_eq!(
        node_secret_manager.secret_count(),
        1,
        "shared placement should not create an extra per-deployment node secret"
    );

    // Verify tenant entry has vm_id set to the shared VM
    let raw_tenant = tenant_repo
        .find_raw(customer.id, "products")
        .await
        .unwrap()
        .expect("tenant should exist after creation");
    assert_eq!(
        raw_tenant.vm_id,
        Some(vm.id),
        "tenant should have vm_id pointing to the placed shared VM"
    );

    // Verify NO new VMs were provisioned (deployment_repo should have a lightweight
    // shared deployment, not a provisioning one)
    let deployments = deployment_repo
        .list_by_customer(customer.id, false)
        .await
        .unwrap();
    assert_eq!(deployments.len(), 1, "should have exactly one deployment");
    assert_eq!(
        deployments[0].vm_type, "shared",
        "deployment vm_type should be 'shared' to indicate lightweight shared deployment"
    );
}

// ---------------------------------------------------------------------------
// 33. shared customers use scheduler placement even when a legacy deployment exists
// ---------------------------------------------------------------------------

#[tokio::test]
async fn shared_customer_with_existing_deployment_still_uses_scheduler_placement() {
    use api::models::vm_inventory::NewVmInventory;
    use api::repos::tenant_repo::TenantRepo;
    use api::repos::vm_inventory_repo::VmInventoryRepo;

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let node_secret_manager = Arc::new(api::secrets::mock::MockNodeSecretManager::new());

    let customer =
        customer_repo.seed_verified_shared_customer("SharedCo", "shared-existing@example.com");
    let jwt = create_test_jwt(customer.id);

    // Existing region deployment should not force routing to the legacy endpoint.
    let legacy_deployment = deployment_repo.seed_provisioned(
        customer.id,
        "legacy-node",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("https://legacy-dedicated.flapjack.foo"),
    );
    tenant_repo.seed_deployment(
        legacy_deployment.id,
        "us-east-1",
        Some("https://legacy-dedicated.flapjack.foo"),
        "healthy",
        "running",
    );
    node_secret_manager
        .create_node_api_key("legacy-node", "us-east-1")
        .await
        .unwrap();

    let shared_vm = vm_inventory_repo
        .create(NewVmInventory {
            region: "us-east-1".to_string(),
            provider: "aws".to_string(),
            hostname: "vm-shared-2.flapjack.foo".to_string(),
            flapjack_url: "https://shared-placement.flapjack.foo".to_string(),
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
    vm_inventory_repo
        .update_load(shared_vm.id, serde_json::json!({}))
        .await
        .unwrap();

    http_client.push_json_response(200, json!({}));

    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client(
        http_client.clone(),
        node_secret_manager.clone(),
    ));

    let vm_provisioner = Arc::new(api::provisioner::mock::MockVmProvisioner::new());
    let dns_manager = Arc::new(api::dns::mock::MockDnsManager::new());
    let provisioning_service = Arc::new(api::services::provisioning::ProvisioningService::new(
        vm_provisioner.clone(),
        dns_manager.clone(),
        node_secret_manager.clone(),
        deployment_repo.clone(),
        customer_repo.clone(),
        "flapjack.foo".to_string(),
    ));

    let mut state = common::test_state_with_indexes_and_vm_inventory(
        customer_repo.clone(),
        deployment_repo.clone(),
        tenant_repo.clone(),
        flapjack_proxy,
        vm_inventory_repo,
    );
    state.vm_provisioner = vm_provisioner;
    state.dns_manager = dns_manager;
    state.provisioning_service = provisioning_service;

    let app = api::router::build_router(state);

    let resp = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/indexes")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({"name": "catalog", "region": "us-east-1"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(body["endpoint"], "https://shared-placement.flapjack.foo");

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0].url, "https://shared-placement.flapjack.foo/1/indexes",
        "create should always place on shared VM inventory, not legacy deployment URL"
    );

    let tenant = tenant_repo
        .find_raw(customer.id, "catalog")
        .await
        .unwrap()
        .expect("tenant should exist");
    assert_eq!(tenant.vm_id, Some(shared_vm.id));
}

// ---------------------------------------------------------------------------
// Stage 9 §3: region validation uses RegionConfig, not hard-coded list
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_with_hetzner_region_auto_provisions_when_no_capacity() {
    let Some(setup) = setup_empty_region_auto_provision_test().await else {
        return;
    };
    setup.http_client.push_json_response(200, json!({}));

    let resp = setup
        .app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {}", setup.jwt))
                .body(Body::from(
                    json!({"name": "hetzner-idx", "region": "eu-central-1"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(
        status,
        StatusCode::CREATED,
        "auto-provision should create a VM for empty regions, including Hetzner regions"
    );
    assert_eq!(body["region"], "eu-central-1");

    let autos = setup
        .vm_inventory_repo
        .list_active(Some("eu-central-1"))
        .await
        .unwrap();
    assert_eq!(
        autos.len(),
        1,
        "empty Hetzner region should auto-provision one shared VM"
    );
    assert_eq!(
        autos[0].provider, "hetzner",
        "region-to-provider mapping must select Hetzner for eu-central-1"
    );
}

#[tokio::test]
async fn create_rejects_unknown_region_via_region_config() {
    // "us-west-99" doesn't exist in RegionConfig::defaults() — must be rejected.
    let customer_repo = mock_repo();
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let jwt = create_test_jwt(customer.id);
    let app = test_app_with_repos(customer_repo, mock_deployment_repo());

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(
                    json!({"name": "bad-region-idx", "region": "us-west-99"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(
        body["error"].as_str().unwrap().contains("region"),
        "error should mention region: {body}"
    );
}

#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn create_rejects_unavailable_region_via_region_config() {
    let _env_guard = process_env_lock().lock().unwrap();
    let _region_config = EnvVarGuard::set(
        "REGION_CONFIG",
        &json!({
            "us-east-1": {
                "provider": "aws",
                "provider_location": "us-east-1",
                "display_name": "US East (Virginia)",
                "available": false
            }
        })
        .to_string(),
    );

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let jwt = create_test_jwt(customer.id);

    let mut state = test_state_with_indexes(
        customer_repo,
        deployment_repo,
        tenant_repo,
        mock_flapjack_proxy(),
    );
    state.region_config = RegionConfig::from_env();
    let app = build_router(state);

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(
                    json!({"name": "unavailable-idx", "region": "us-east-1"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(
        body["error"].as_str().unwrap().contains("region"),
        "error should mention region for unavailable mapping: {body}"
    );
}

fn replica_test_vm(
    region: &str,
    provider: &str,
    hostname: &str,
) -> api::models::vm_inventory::NewVmInventory {
    api::models::vm_inventory::NewVmInventory {
        region: region.to_string(),
        provider: provider.to_string(),
        hostname: hostname.to_string(),
        flapjack_url: format!("https://{hostname}"),
        capacity: json!({
            "cpu_weight": 4.0,
            "mem_rss_bytes": 8_589_934_592_u64,
            "disk_bytes": 107_374_182_400_u64,
            "query_rps": 500.0,
            "indexing_rps": 200.0,
        }),
    }
}

#[tokio::test]
async fn index_replica_crud_endpoints_round_trip() {
    use api::repos::tenant_repo::TenantRepo;
    use api::repos::vm_inventory_repo::VmInventoryRepo;

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let jwt = create_test_jwt(customer.id);

    let deployment = deployment_repo.seed_provisioned(
        customer.id,
        "node-a1",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("https://vm-primary.flapjack.foo"),
    );
    tenant_repo.seed_deployment(
        deployment.id,
        "us-east-1",
        Some("https://vm-primary.flapjack.foo"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer.id, "products", deployment.id)
        .await
        .unwrap();

    let primary_vm = vm_inventory_repo
        .create(replica_test_vm(
            "us-east-1",
            "aws",
            "vm-primary.flapjack.foo",
        ))
        .await
        .unwrap();
    vm_inventory_repo
        .update_load(primary_vm.id, serde_json::json!({}))
        .await
        .unwrap();

    let replica_vm = vm_inventory_repo
        .create(replica_test_vm(
            "eu-central-1",
            "hetzner",
            "vm-replica.flapjack.foo",
        ))
        .await
        .unwrap();
    vm_inventory_repo
        .update_load(replica_vm.id, serde_json::json!({}))
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer.id, "products", primary_vm.id)
        .await
        .unwrap();

    let app = test_app_with_indexes_and_vm_inventory(
        customer_repo,
        deployment_repo,
        tenant_repo,
        mock_flapjack_proxy(),
        vm_inventory_repo,
    );

    let create_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/products/replicas")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(json!({"region": "eu-central-1"}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    let (create_status, create_body) = response_json(create_resp).await;
    assert_eq!(create_status, StatusCode::CREATED);
    assert_eq!(create_body["replica_region"], "eu-central-1");
    assert_eq!(create_body["status"], "provisioning");
    let replica_id = create_body["id"]
        .as_str()
        .expect("id string in create response")
        .to_string();

    let list_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/products/replicas")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let (list_status, list_body) = response_json(list_resp).await;
    assert_eq!(list_status, StatusCode::OK);
    let replicas = list_body.as_array().expect("replicas array");
    assert_eq!(replicas.len(), 1);
    assert_eq!(replicas[0]["id"], replica_id);
    // Customer-facing response must NOT include internal VM hostname
    assert!(
        replicas[0].get("replica_vm_hostname").is_none(),
        "replica_vm_hostname should not be in customer response"
    );
    // Customer-facing response uses 'endpoint' instead of 'replica_flapjack_url'
    assert!(
        replicas[0]["endpoint"].is_string(),
        "endpoint should be present"
    );

    let delete_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method(http::Method::DELETE)
                .uri(format!("/indexes/products/replicas/{replica_id}"))
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(delete_resp.status(), StatusCode::NO_CONTENT);

    let list_after_delete_resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/products/replicas")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let (list_after_status, list_after_body) = response_json(list_after_delete_resp).await;
    assert_eq!(list_after_status, StatusCode::OK);
    assert_eq!(
        list_after_body
            .as_array()
            .expect("replicas array after delete")
            .len(),
        0
    );
}

#[tokio::test]
async fn index_replica_delete_requires_matching_index_path() {
    use api::repos::tenant_repo::TenantRepo;
    use api::repos::vm_inventory_repo::VmInventoryRepo;

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let jwt = create_test_jwt(customer.id);

    let deployment = deployment_repo.seed_provisioned(
        customer.id,
        "node-a1",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("https://vm-primary.flapjack.foo"),
    );
    tenant_repo.seed_deployment(
        deployment.id,
        "us-east-1",
        Some("https://vm-primary.flapjack.foo"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer.id, "products", deployment.id)
        .await
        .unwrap();
    tenant_repo
        .create(customer.id, "logs", deployment.id)
        .await
        .unwrap();

    let primary_vm = vm_inventory_repo
        .create(replica_test_vm(
            "us-east-1",
            "aws",
            "vm-primary.flapjack.foo",
        ))
        .await
        .unwrap();
    vm_inventory_repo
        .update_load(primary_vm.id, serde_json::json!({}))
        .await
        .unwrap();

    let replica_vm = vm_inventory_repo
        .create(replica_test_vm(
            "eu-central-1",
            "hetzner",
            "vm-replica.flapjack.foo",
        ))
        .await
        .unwrap();
    vm_inventory_repo
        .update_load(replica_vm.id, serde_json::json!({}))
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer.id, "products", primary_vm.id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer.id, "logs", primary_vm.id)
        .await
        .unwrap();

    let app = test_app_with_indexes_and_vm_inventory(
        customer_repo,
        deployment_repo,
        tenant_repo,
        mock_flapjack_proxy(),
        vm_inventory_repo,
    );

    let create_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/products/replicas")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(json!({"region": "eu-central-1"}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    let (create_status, create_body) = response_json(create_resp).await;
    assert_eq!(create_status, StatusCode::CREATED);
    let replica_id = create_body["id"]
        .as_str()
        .expect("id string in create response");

    let wrong_path_delete = app
        .oneshot(
            Request::builder()
                .method(http::Method::DELETE)
                .uri(format!("/indexes/logs/replicas/{replica_id}"))
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(wrong_path_delete).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(body["error"]
        .as_str()
        .unwrap_or_default()
        .contains("not found"));
}

// ===========================================================================
// Stage 4: Settings write + Rules CRUD
// ===========================================================================

use common::flapjack_proxy_test_support::{setup_ready_index, test_flapjack_uid};

// ---------------------------------------------------------------------------
// S4-1. update_settings proxies to flapjack
// ---------------------------------------------------------------------------

#[tokio::test]
async fn update_settings_proxies_to_flapjack() {
    let (app, jwt, http_client, customer_id) = setup_ready_index("products").await;

    http_client.push_json_response(
        200,
        json!({"updatedAt": "2026-02-25T00:00:00Z", "taskID": 42}),
    );

    let settings_body = json!({
        "searchableAttributes": ["title", "body"],
        "filterableAttributes": ["category"]
    });

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::PUT)
                .uri("/indexes/products/settings")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(settings_body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["taskID"], 42);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(
        requests[0].url,
        format!(
            "https://vm-test.flapjack.foo/1/indexes/{}/settings",
            test_flapjack_uid(customer_id, "products")
        )
    );
    assert_eq!(requests[0].json_body, Some(settings_body));
}

// ---------------------------------------------------------------------------
// S4-1b. update_settings returns 503 when flapjack times out
// ---------------------------------------------------------------------------

#[tokio::test]
async fn update_settings_returns_503_when_flapjack_times_out() {
    assert_classic_route_proxy_error(
        ClassicRouteProxyFailureCase::update_settings(
            "products",
            json!({"searchableAttributes": ["title"]}),
        ),
        ProxyError::Timeout,
        ProxyFailureExpectation::service_unavailable("request timed out"),
    )
    .await;
}

#[tokio::test]
async fn get_settings_returns_503_when_flapjack_unreachable() {
    assert_classic_route_proxy_error(
        ClassicRouteProxyFailureCase::get_settings("products"),
        ProxyError::Unreachable("connection refused".into()),
        ProxyFailureExpectation::service_unavailable("backend temporarily unavailable"),
    )
    .await;
}

#[tokio::test]
async fn get_settings_returns_503_when_flapjack_times_out() {
    assert_classic_route_proxy_error(
        ClassicRouteProxyFailureCase::get_settings("products"),
        ProxyError::Timeout,
        ProxyFailureExpectation::service_unavailable("request timed out"),
    )
    .await;
}

#[tokio::test]
async fn get_settings_returns_500_when_flapjack_returns_502() {
    assert_classic_route_proxy_error(
        ClassicRouteProxyFailureCase::get_settings("products"),
        ProxyError::FlapjackError {
            status: 502,
            message: "settings get bad gateway from upstream engine".into(),
        },
        ProxyFailureExpectation::internal_server_error(
            "internal server error",
            Some("settings get bad gateway from upstream engine"),
        ),
    )
    .await;
}

#[tokio::test]
async fn update_settings_returns_503_when_flapjack_unreachable() {
    assert_classic_route_proxy_error(
        ClassicRouteProxyFailureCase::update_settings(
            "products",
            json!({"searchableAttributes": ["title"]}),
        ),
        ProxyError::Unreachable("connection refused".into()),
        ProxyFailureExpectation::service_unavailable("backend temporarily unavailable"),
    )
    .await;
}

#[tokio::test]
async fn update_settings_returns_500_when_flapjack_returns_502() {
    assert_classic_route_proxy_error(
        ClassicRouteProxyFailureCase::update_settings(
            "products",
            json!({"searchableAttributes": ["title"]}),
        ),
        ProxyError::FlapjackError {
            status: 502,
            message: "settings update bad gateway from upstream engine".into(),
        },
        ProxyFailureExpectation::internal_server_error(
            "internal server error",
            Some("settings update bad gateway from upstream engine"),
        ),
    )
    .await;
}

// ---------------------------------------------------------------------------
// S4-2. update_settings returns 404 for nonexistent index
// ---------------------------------------------------------------------------

#[tokio::test]
async fn update_settings_returns_404_for_nonexistent_index() {
    let (app, jwt, _http_client, _customer_id) = setup_ready_index("products").await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::PUT)
                .uri("/indexes/no-such-index/settings")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(
                    json!({"searchableAttributes": ["title"]}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(body["error"].as_str().unwrap().contains("not found"));
}

// ---------------------------------------------------------------------------
// S4-3. update_settings on index without ready endpoint returns 503
// ---------------------------------------------------------------------------

#[tokio::test]
async fn update_settings_on_index_without_ready_endpoint_returns_503() {
    use api::repos::tenant_repo::TenantRepo;

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let jwt = create_test_jwt(customer.id);

    let deployment = deployment_repo.seed(
        customer.id,
        "node-a1",
        "us-east-1",
        "t4g.small",
        "aws",
        "provisioning",
    );
    tenant_repo.seed_deployment(deployment.id, "us-east-1", None, "unknown", "provisioning");

    tenant_repo
        .create(customer.id, "early-index", deployment.id)
        .await
        .unwrap();

    let app = test_app_with_indexes(
        customer_repo,
        deployment_repo,
        tenant_repo,
        mock_flapjack_proxy(),
    );

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::PUT)
                .uri("/indexes/early-index/settings")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(
                    json!({"searchableAttributes": ["title"]}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert!(
        body["error"].as_str().unwrap().contains("not ready"),
        "should indicate endpoint not ready, got: {}",
        body["error"]
    );
}

// ---------------------------------------------------------------------------
// S4-4. search_rules returns empty list for new index
// ---------------------------------------------------------------------------

#[tokio::test]
async fn search_rules_returns_empty_list_for_new_index() {
    let (app, jwt, http_client, customer_id) = setup_ready_index("products").await;

    http_client.push_json_response(
        200,
        json!({"hits": [], "nbHits": 0, "page": 0, "nbPages": 0}),
    );

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/products/rules/search")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(
                    json!({"query": "", "page": 0, "hitsPerPage": 50}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["hits"].as_array().unwrap().len(), 0);
    assert_eq!(body["nbHits"], 0);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(
        requests[0].url,
        format!(
            "https://vm-test.flapjack.foo/1/indexes/{}/rules/search",
            test_flapjack_uid(customer_id, "products")
        )
    );
}

// ---------------------------------------------------------------------------
// S4-5. save and get rule round trip
// ---------------------------------------------------------------------------

#[tokio::test]
async fn save_and_get_rule_round_trip() {
    let (app, jwt, http_client, customer_id) = setup_ready_index("products").await;

    // Save rule response
    http_client.push_json_response(
        200,
        json!({"taskID": 7, "updatedAt": "2026-02-25T01:00:00Z", "id": "boost-shoes"}),
    );

    let rule_body = json!({
        "objectID": "boost-shoes",
        "conditions": [{"pattern": "shoes", "anchoring": "contains"}],
        "consequence": {"promote": [{"objectID": "shoe-1", "position": 0}]},
        "description": "Boost shoes to top"
    });

    let save_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method(http::Method::PUT)
                .uri("/indexes/products/rules/boost-shoes")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(rule_body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (save_status, save_body) = response_json(save_resp).await;
    assert_eq!(save_status, StatusCode::OK);
    assert_eq!(save_body["id"], "boost-shoes");

    // Get rule response
    http_client.push_json_response(200, rule_body.clone());

    let get_resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/products/rules/boost-shoes")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (get_status, get_body) = response_json(get_resp).await;
    assert_eq!(get_status, StatusCode::OK);
    assert_eq!(get_body["objectID"], "boost-shoes");
    assert_eq!(get_body["description"], "Boost shoes to top");

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0].method, reqwest::Method::PUT);
    assert_eq!(
        requests[0].url,
        format!(
            "https://vm-test.flapjack.foo/1/indexes/{}/rules/boost-shoes",
            test_flapjack_uid(customer_id, "products")
        )
    );
    assert_eq!(requests[1].method, reqwest::Method::GET);
    assert_eq!(
        requests[1].url,
        format!(
            "https://vm-test.flapjack.foo/1/indexes/{}/rules/boost-shoes",
            test_flapjack_uid(customer_id, "products")
        )
    );
}

// ---------------------------------------------------------------------------
// S4-6. delete rule removes it
// ---------------------------------------------------------------------------

#[tokio::test]
async fn delete_rule_removes_it() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    // Save a rule first
    http_client.push_json_response(
        200,
        json!({"taskID": 7, "updatedAt": "2026-02-25T01:00:00Z", "id": "temp-rule"}),
    );

    let save_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method(http::Method::PUT)
                .uri("/indexes/products/rules/temp-rule")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(
                    json!({"objectID": "temp-rule", "conditions": [], "consequence": {}})
                        .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    let (save_status, _) = response_json(save_resp).await;
    assert_eq!(save_status, StatusCode::OK);

    // Delete the rule
    http_client.push_json_response(
        200,
        json!({"taskID": 12, "deletedAt": "2026-02-25T02:00:00Z"}),
    );

    let delete_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method(http::Method::DELETE)
                .uri("/indexes/products/rules/temp-rule")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (delete_status, delete_body) = response_json(delete_resp).await;
    assert_eq!(delete_status, StatusCode::OK);
    assert!(delete_body["deletedAt"].is_string());

    // Search rules — should be empty
    http_client.push_json_response(
        200,
        json!({"hits": [], "nbHits": 0, "page": 0, "nbPages": 0}),
    );

    let search_resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/products/rules/search")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(
                    json!({"query": "", "page": 0, "hitsPerPage": 50}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (search_status, search_body) = response_json(search_resp).await;
    assert_eq!(search_status, StatusCode::OK);
    assert_eq!(search_body["nbHits"], 0);
}

// ---------------------------------------------------------------------------
// S4-7. cross-tenant isolation for rules
// ---------------------------------------------------------------------------

#[tokio::test]
async fn rules_cross_tenant_isolation() {
    use api::repos::tenant_repo::TenantRepo;

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let node_secret_manager = Arc::new(api::secrets::mock::MockNodeSecretManager::new());

    let alice = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let bob = customer_repo.seed_verified_free_customer("Bob", "bob@example.com");
    let _alice_jwt = create_test_jwt(alice.id);
    let bob_jwt = create_test_jwt(bob.id);

    node_secret_manager
        .create_node_api_key("node-a1", "us-east-1")
        .await
        .unwrap();

    let deployment = deployment_repo.seed_provisioned(
        alice.id,
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
        .create(alice.id, "alice-index", deployment.id)
        .await
        .unwrap();

    let vm = vm_inventory_repo.seed("us-east-1", "https://vm-test.flapjack.foo");
    tenant_repo
        .set_vm_id(alice.id, "alice-index", vm.id)
        .await
        .unwrap();

    let http_client = Arc::new(MockFlapjackHttpClient::default());
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

    // Bob tries to access Alice's index rules — should get 404
    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/alice-index/rules/some-rule")
                .header("authorization", format!("Bearer {bob_jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(body["error"].as_str().unwrap().contains("not found"));

    // Verify no proxy requests were made (rejected at tenant lookup)
    assert_eq!(http_client.take_requests().len(), 0);
}

// ---------------------------------------------------------------------------
// S4-8. update_settings rejects non-object body (array / primitive)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn update_settings_rejects_array_body() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::PUT)
                .uri("/indexes/products/settings")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(json!(["title", "body"]).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(
        body["error"].as_str().unwrap().contains("JSON object"),
        "should say must be JSON object, got: {}",
        body["error"]
    );

    // No proxy request should have been made
    assert_eq!(http_client.take_requests().len(), 0);
}

// ===========================================================================
// Stage 5: Synonyms + Query Suggestions
// ===========================================================================

// ---------------------------------------------------------------------------
// S5-1. search_synonyms returns empty list for new index
// ---------------------------------------------------------------------------

#[tokio::test]
async fn search_synonyms_returns_empty_list_for_new_index() {
    let (app, jwt, http_client, customer_id) = setup_ready_index("products").await;

    http_client.push_json_response(200, json!({"hits": [], "nbHits": 0}));

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/products/synonyms/search")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(
                    json!({"query": "", "page": 0, "hitsPerPage": 50}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["hits"].as_array().unwrap().len(), 0);
    assert_eq!(body["nbHits"], 0);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(
        requests[0].url,
        format!(
            "https://vm-test.flapjack.foo/1/indexes/{}/synonyms/search",
            test_flapjack_uid(customer_id, "products")
        )
    );
    assert_eq!(
        requests[0].json_body,
        Some(json!({"query": "", "page": 0, "hitsPerPage": 50}))
    );
}

// ---------------------------------------------------------------------------
// S5-2. save and get synonym round trip
// ---------------------------------------------------------------------------

#[tokio::test]
async fn save_and_get_synonym_round_trip() {
    let (app, jwt, http_client, customer_id) = setup_ready_index("products").await;

    http_client.push_json_response(
        200,
        json!({"taskID": 7, "updatedAt": "2026-02-25T01:00:00Z", "id": "laptop-syn"}),
    );

    let synonym_body = json!({
        "objectID": "laptop-syn",
        "type": "synonym",
        "synonyms": ["laptop", "notebook", "computer"]
    });

    let save_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method(http::Method::PUT)
                .uri("/indexes/products/synonyms/laptop-syn")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(synonym_body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (save_status, save_body) = response_json(save_resp).await;
    assert_eq!(save_status, StatusCode::OK);
    assert_eq!(save_body["id"], "laptop-syn");

    http_client.push_json_response(200, synonym_body.clone());

    let get_resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/products/synonyms/laptop-syn")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (get_status, get_body) = response_json(get_resp).await;
    assert_eq!(get_status, StatusCode::OK);
    assert_eq!(get_body["objectID"], "laptop-syn");
    assert_eq!(get_body["type"], "synonym");

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0].method, reqwest::Method::PUT);
    assert_eq!(
        requests[0].url,
        format!(
            "https://vm-test.flapjack.foo/1/indexes/{}/synonyms/laptop-syn",
            test_flapjack_uid(customer_id, "products")
        )
    );
    assert_eq!(requests[1].method, reqwest::Method::GET);
    assert_eq!(
        requests[1].url,
        format!(
            "https://vm-test.flapjack.foo/1/indexes/{}/synonyms/laptop-syn",
            test_flapjack_uid(customer_id, "products")
        )
    );
}

// ---------------------------------------------------------------------------
// S5-3. delete synonym removes it
// ---------------------------------------------------------------------------

#[tokio::test]
async fn delete_synonym_removes_it() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    http_client.push_json_response(
        200,
        json!({"taskID": 7, "updatedAt": "2026-02-25T01:00:00Z", "id": "temp-syn"}),
    );

    let save_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method(http::Method::PUT)
                .uri("/indexes/products/synonyms/temp-syn")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(
                    json!({"objectID": "temp-syn", "type": "synonym", "synonyms": ["a", "b"]})
                        .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    let (save_status, _) = response_json(save_resp).await;
    assert_eq!(save_status, StatusCode::OK);

    http_client.push_json_response(
        200,
        json!({"taskID": 12, "deletedAt": "2026-02-25T02:00:00Z"}),
    );

    let delete_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method(http::Method::DELETE)
                .uri("/indexes/products/synonyms/temp-syn")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (delete_status, delete_body) = response_json(delete_resp).await;
    assert_eq!(delete_status, StatusCode::OK);
    assert!(delete_body["deletedAt"].is_string());

    http_client.push_json_response(200, json!({"hits": [], "nbHits": 0}));

    let search_resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/products/synonyms/search")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(
                    json!({"query": "", "page": 0, "hitsPerPage": 50}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (search_status, search_body) = response_json(search_resp).await;
    assert_eq!(search_status, StatusCode::OK);
    assert_eq!(search_body["nbHits"], 0);
}

// ---------------------------------------------------------------------------
// S5-4. cross-tenant isolation for synonyms
// ---------------------------------------------------------------------------

#[tokio::test]
async fn synonyms_cross_tenant_isolation() {
    use api::repos::tenant_repo::TenantRepo;

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let node_secret_manager = Arc::new(api::secrets::mock::MockNodeSecretManager::new());

    let alice = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let bob = customer_repo.seed_verified_free_customer("Bob", "bob@example.com");
    let bob_jwt = create_test_jwt(bob.id);

    node_secret_manager
        .create_node_api_key("node-a1", "us-east-1")
        .await
        .unwrap();

    let deployment = deployment_repo.seed_provisioned(
        alice.id,
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
        .create(alice.id, "alice-index", deployment.id)
        .await
        .unwrap();

    let vm = vm_inventory_repo.seed("us-east-1", "https://vm-test.flapjack.foo");
    tenant_repo
        .set_vm_id(alice.id, "alice-index", vm.id)
        .await
        .unwrap();

    let http_client = Arc::new(MockFlapjackHttpClient::default());
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

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/alice-index/synonyms/some-syn")
                .header("authorization", format!("Bearer {bob_jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(body["error"].as_str().unwrap().contains("not found"));
    assert_eq!(http_client.take_requests().len(), 0);
}

// ---------------------------------------------------------------------------
// S5-5. save synonym returns 404 for nonexistent index
// ---------------------------------------------------------------------------

#[tokio::test]
async fn save_synonym_returns_404_for_nonexistent_index() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::PUT)
                .uri("/indexes/no-such-index/synonyms/laptop-syn")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(
                    json!({"objectID": "laptop-syn", "type": "synonym", "synonyms": ["laptop"]})
                        .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(body["error"].as_str().unwrap().contains("not found"));
    assert_eq!(http_client.take_requests().len(), 0);
}

// ---------------------------------------------------------------------------
// S5-6. get query suggestions config
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_qs_config_returns_config_for_index() {
    let (app, jwt, http_client, customer_id) = setup_ready_index("products").await;

    let config = json!({
        "indexName": "products",
        "sourceIndices": [],
        "languages": ["en"],
        "exclude": [],
        "allowSpecialCharacters": false,
        "enablePersonalization": false
    });
    http_client.push_json_response(200, config.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/products/suggestions")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, config);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        format!(
            "https://vm-test.flapjack.foo/1/configs/{}",
            test_flapjack_uid(customer_id, "products")
        )
    );
}

// ---------------------------------------------------------------------------
// S5-7. save query suggestions config proxies through upsert
// ---------------------------------------------------------------------------

#[tokio::test]
async fn save_qs_config_proxies_to_flapjack() {
    let (app, jwt, http_client, customer_id) = setup_ready_index("products").await;

    let config_body = json!({
        "sourceIndices": [
            {
                "indexName": "products",
                "minHits": 5,
                "minLetters": 4,
                "facets": [],
                "generate": [],
                "analyticsTags": [],
                "replicas": false
            }
        ],
        "languages": ["en"],
        "exclude": [],
        "allowSpecialCharacters": false,
        "enablePersonalization": false
    });

    // Upsert create path: PUT 404 then POST 200
    http_client.push_json_response(404, json!({"error": "config not found"}));
    let created = json!({"status": "created"});
    http_client.push_json_response(200, created.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::PUT)
                .uri("/indexes/products/suggestions")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(config_body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, created);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0].method, reqwest::Method::PUT);
    assert_eq!(
        requests[0].url,
        format!(
            "https://vm-test.flapjack.foo/1/configs/{}",
            test_flapjack_uid(customer_id, "products")
        )
    );
    assert_eq!(requests[0].json_body, Some(config_body.clone()));
    assert_eq!(requests[1].method, reqwest::Method::POST);
    assert_eq!(requests[1].url, "https://vm-test.flapjack.foo/1/configs");
    assert_eq!(
        requests[1].json_body.as_ref().unwrap()["indexName"],
        test_flapjack_uid(customer_id, "products")
    );
}

// ---------------------------------------------------------------------------
// S5-8. get query suggestions status
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_qs_status_returns_build_status() {
    let (app, jwt, http_client, customer_id) = setup_ready_index("products").await;

    let status_body = json!({
        "indexName": "products",
        "isRunning": false,
        "lastBuiltAt": "2026-02-25T03:00:00Z",
        "lastSuccessfulBuiltAt": "2026-02-25T03:00:00Z"
    });
    http_client.push_json_response(200, status_body.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/products/suggestions/status")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, status_body);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        format!(
            "https://vm-test.flapjack.foo/1/configs/{}/status",
            test_flapjack_uid(customer_id, "products")
        )
    );
}

// ---------------------------------------------------------------------------
// S5-9. delete query suggestions config
// ---------------------------------------------------------------------------

#[tokio::test]
async fn delete_qs_config_removes_config() {
    let (app, jwt, http_client, customer_id) = setup_ready_index("products").await;

    let deleted = json!({"deletedAt": "2026-02-25T04:00:00Z"});
    http_client.push_json_response(200, deleted.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::DELETE)
                .uri("/indexes/products/suggestions")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, deleted);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::DELETE);
    assert_eq!(
        requests[0].url,
        format!(
            "https://vm-test.flapjack.foo/1/configs/{}",
            test_flapjack_uid(customer_id, "products")
        )
    );
}

// ---------------------------------------------------------------------------
// S5-10. query suggestions routes return 404 for nonexistent index
// ---------------------------------------------------------------------------

#[tokio::test]
async fn qs_config_returns_404_for_nonexistent_index() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/no-such-index/suggestions")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(body["error"].as_str().unwrap().contains("not found"));
    assert_eq!(http_client.take_requests().len(), 0);
}

// ===========================================================================
// Stage 6: Analytics
// ===========================================================================

#[tokio::test]
async fn analytics_top_searches_returns_searches_array() {
    let (app, jwt, http_client, customer_id) = setup_ready_index("products").await;

    let analytics = json!({
        "searches": [
            {"search": "laptop", "count": 42, "nbHits": 15}
        ]
    });
    http_client.push_json_response(200, analytics.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/products/analytics/searches?startDate=2026-02-18&endDate=2026-02-25&limit=10")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, analytics);
    assert_eq!(body["searches"].as_array().unwrap().len(), 1);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        format!("https://vm-test.flapjack.foo/2/searches?index={}&startDate=2026-02-18&endDate=2026-02-25&limit=10", test_flapjack_uid(customer_id, "products"))
    );
}

#[tokio::test]
async fn analytics_search_count_returns_count_and_dates() {
    let (app, jwt, http_client, customer_id) = setup_ready_index("products").await;

    let analytics = json!({
        "count": 1234,
        "dates": [
            {"date": "2026-02-24", "count": 180}
        ]
    });
    http_client.push_json_response(200, analytics.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/products/analytics/searches/count?startDate=2026-02-18&endDate=2026-02-25")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["count"], 1234);
    assert_eq!(body["dates"].as_array().unwrap().len(), 1);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        format!("https://vm-test.flapjack.foo/2/searches/count?index={}&startDate=2026-02-18&endDate=2026-02-25", test_flapjack_uid(customer_id, "products"))
    );
}

#[tokio::test]
async fn analytics_no_results_returns_searches_array() {
    let (app, jwt, http_client, customer_id) = setup_ready_index("products").await;

    let analytics = json!({
        "searches": [
            {"search": "lapptop", "count": 8, "nbHits": 0}
        ]
    });
    http_client.push_json_response(200, analytics.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/products/analytics/searches/noResults?startDate=2026-02-18&endDate=2026-02-25&limit=10")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, analytics);
    assert_eq!(body["searches"].as_array().unwrap().len(), 1);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        format!("https://vm-test.flapjack.foo/2/searches/noResults?index={}&startDate=2026-02-18&endDate=2026-02-25&limit=10", test_flapjack_uid(customer_id, "products"))
    );
}

#[tokio::test]
async fn analytics_no_result_rate_returns_rate_response() {
    let (app, jwt, http_client, customer_id) = setup_ready_index("products").await;

    let analytics = json!({
        "rate": 0.12,
        "count": 1234,
        "noResults": 148,
        "dates": [
            {"date": "2026-02-24", "rate": 0.10, "count": 180, "noResults": 18}
        ]
    });
    http_client.push_json_response(200, analytics.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/products/analytics/searches/noResultRate?startDate=2026-02-18&endDate=2026-02-25")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, analytics);
    assert_eq!(body["rate"], 0.12);
    assert_eq!(body["noResults"], 148);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        format!("https://vm-test.flapjack.foo/2/searches/noResultRate?index={}&startDate=2026-02-18&endDate=2026-02-25", test_flapjack_uid(customer_id, "products"))
    );
}

#[tokio::test]
async fn analytics_status_returns_status() {
    let (app, jwt, http_client, customer_id) = setup_ready_index("products").await;

    let analytics = json!({
        "indexName": "products",
        "enabled": true
    });
    http_client.push_json_response(200, analytics.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/products/analytics/status")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, analytics);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        format!(
            "https://vm-test.flapjack.foo/2/status?index={}",
            test_flapjack_uid(customer_id, "products")
        )
    );
}

#[tokio::test]
async fn analytics_returns_404_for_nonexistent_index() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/no-such-index/analytics/searches?startDate=2026-02-18&endDate=2026-02-25")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(body["error"].as_str().unwrap().contains("not found"));
    assert_eq!(http_client.take_requests().len(), 0);
}

#[tokio::test]
async fn analytics_cross_tenant_isolation() {
    use api::repos::tenant_repo::TenantRepo;

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let node_secret_manager = Arc::new(api::secrets::mock::MockNodeSecretManager::new());

    let alice = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let bob = customer_repo.seed_verified_free_customer("Bob", "bob@example.com");
    let bob_jwt = create_test_jwt(bob.id);

    node_secret_manager
        .create_node_api_key("node-a1", "us-east-1")
        .await
        .unwrap();

    let deployment = deployment_repo.seed_provisioned(
        alice.id,
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
        .create(alice.id, "alice-index", deployment.id)
        .await
        .unwrap();

    let vm = vm_inventory_repo.seed("us-east-1", "https://vm-test.flapjack.foo");
    tenant_repo
        .set_vm_id(alice.id, "alice-index", vm.id)
        .await
        .unwrap();

    let http_client = Arc::new(MockFlapjackHttpClient::default());
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

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/alice-index/analytics/status")
                .header("authorization", format!("Bearer {bob_jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(body["error"].as_str().unwrap().contains("not found"));
    assert_eq!(http_client.take_requests().len(), 0);
}

#[tokio::test]
async fn analytics_rejects_invalid_start_date_format() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/products/analytics/searches?startDate=2026-2-18&endDate=2026-02-25")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body["error"].as_str().unwrap().contains("YYYY-MM-DD"));
    assert_eq!(http_client.take_requests().len(), 0);
}

#[tokio::test]
async fn analytics_rejects_end_date_before_start_date() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/products/analytics/searches?startDate=2026-02-25&endDate=2026-02-18")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body["error"].as_str().unwrap().contains("on or after"));
    assert_eq!(http_client.take_requests().len(), 0);
}

#[tokio::test]
async fn analytics_rejects_date_range_over_90_days() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/products/analytics/searches?startDate=2025-10-01&endDate=2026-02-25")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body["error"].as_str().unwrap().contains("90 days"));
    assert_eq!(http_client.take_requests().len(), 0);
}

#[tokio::test]
async fn analytics_rejects_non_integer_limit() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/products/analytics/searches?startDate=2026-02-18&endDate=2026-02-25&limit=ten")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body["error"]
        .as_str()
        .unwrap()
        .contains("limit must be an integer"));
    assert_eq!(http_client.take_requests().len(), 0);
}

#[tokio::test]
async fn analytics_rejects_date_range_of_91_days_inclusive() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    // 2025-11-27..2026-02-25 is 91 days inclusive and must be rejected.
    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/products/analytics/searches?startDate=2025-11-27&endDate=2026-02-25")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body["error"].as_str().unwrap().contains("90 days"));
    assert_eq!(http_client.take_requests().len(), 0);
}

#[tokio::test]
async fn analytics_strips_incoming_index_query_param() {
    let (app, jwt, http_client, customer_id) = setup_ready_index("products").await;

    http_client.push_json_response(200, json!({"searches": []}));

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/products/analytics/searches?index=wrong-index&startDate=2026-02-18&endDate=2026-02-25")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, _body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0].url,
        format!("https://vm-test.flapjack.foo/2/searches?index={}&startDate=2026-02-18&endDate=2026-02-25", test_flapjack_uid(customer_id, "products"))
    );
}

#[tokio::test]
async fn analytics_caps_limit_at_1000() {
    let (app, jwt, http_client, customer_id) = setup_ready_index("products").await;

    http_client.push_json_response(200, json!({"searches": []}));

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/products/analytics/searches?startDate=2026-02-18&endDate=2026-02-25&limit=5000")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, _body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0].url,
        format!("https://vm-test.flapjack.foo/2/searches?index={}&startDate=2026-02-18&endDate=2026-02-25&limit=1000", test_flapjack_uid(customer_id, "products"))
    );
}

// ===========================================================================
// Stage 7: Experiments
// ===========================================================================

#[tokio::test]
async fn experiment_list_returns_abtests_array() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let upstream = json!({
        "abtests": [
            {"abTestID": 1, "name": "Products ranking", "status": "created", "variants": [{"index": "products", "trafficPercentage": 50}]},
            {"abTestID": 2, "name": "Other prefix", "status": "created", "variants": [{"index": "products-archive", "trafficPercentage": 50}]}
        ],
        "count": 2,
        "total": 2
    });
    http_client.push_json_response(200, upstream);

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/products/experiments")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["abtests"].as_array().unwrap().len(), 1);
    assert_eq!(body["abtests"][0]["abTestID"], 1);
    assert_eq!(body["count"], 1);
    assert_eq!(body["total"], 1);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        "https://vm-test.flapjack.foo/2/abtests?indexPrefix=products"
    );
}

#[tokio::test]
async fn experiment_create_returns_abtest_id() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let req_body = json!({
        "name": "Ranking test",
        "variants": [
            {"index": "products", "trafficPercentage": 50},
            {"index": "products", "trafficPercentage": 50, "customSearchParameters": {"enableRules": false}}
        ]
    });
    let created = json!({"abTestID": 7, "index": "products", "taskID": 11});
    http_client.push_json_response(200, created.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/products/experiments")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(req_body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["abTestID"], 7);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(requests[0].url, "https://vm-test.flapjack.foo/2/abtests");
    assert_eq!(requests[0].json_body, Some(req_body));
}

#[tokio::test]
async fn experiment_get_returns_experiment() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let upstream = json!({
        "abTestID": 7,
        "name": "Ranking test",
        "status": "running",
        "variants": [{"index": "products", "trafficPercentage": 50}]
    });
    http_client.push_json_response(200, upstream.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/products/experiments/7")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, upstream);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(requests[0].url, "https://vm-test.flapjack.foo/2/abtests/7");
}

#[tokio::test]
async fn experiment_delete_returns_action_response() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let deleted = json!({"abTestID": 7, "index": "products", "taskID": 12});
    http_client.push_json_response(200, deleted.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::DELETE)
                .uri("/indexes/products/experiments/7")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, deleted);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::DELETE);
    assert_eq!(requests[0].url, "https://vm-test.flapjack.foo/2/abtests/7");
}

#[tokio::test]
async fn experiment_start_returns_action_response() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let started = json!({"abTestID": 7, "index": "products", "taskID": 13});
    http_client.push_json_response(200, started.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/products/experiments/7/start")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, started);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(
        requests[0].url,
        "https://vm-test.flapjack.foo/2/abtests/7/start"
    );
}

#[tokio::test]
async fn experiment_stop_returns_action_response() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let stopped = json!({"abTestID": 7, "index": "products", "taskID": 14});
    http_client.push_json_response(200, stopped.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/products/experiments/7/stop")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, stopped);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(
        requests[0].url,
        "https://vm-test.flapjack.foo/2/abtests/7/stop"
    );
}

#[tokio::test]
async fn experiment_conclude_returns_experiment() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let req_body = json!({
        "winner": "variant",
        "reason": "variant has better ctr",
        "controlMetric": 0.05,
        "variantMetric": 0.08,
        "confidence": 0.97,
        "significant": true,
        "promoted": false
    });
    let concluded = json!({"abTestID": 7, "index": "products", "taskID": 15});
    http_client.push_json_response(200, concluded.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/products/experiments/7/conclude")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(req_body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, concluded);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(
        requests[0].url,
        "https://vm-test.flapjack.foo/2/abtests/7/conclude"
    );
    assert_eq!(requests[0].json_body, Some(req_body));
}

#[tokio::test]
async fn experiment_results_returns_results() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let results = json!({
        "experimentID": "7",
        "name": "Ranking test",
        "status": "running",
        "indexName": "products",
        "trafficSplit": 0.5,
        "primaryMetric": "ctr",
        "sampleRatioMismatch": false,
        "guardRailAlerts": [],
        "cupedApplied": true
    });
    http_client.push_json_response(200, results.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/products/experiments/7/results")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, results);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        "https://vm-test.flapjack.foo/2/abtests/7/results"
    );
}

#[tokio::test]
async fn experiment_returns_404_for_nonexistent_index() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/no-such-index/experiments")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(body["error"].as_str().unwrap().contains("not found"));
    assert_eq!(http_client.take_requests().len(), 0);
}

#[tokio::test]
async fn experiments_cross_tenant_isolation() {
    use api::repos::tenant_repo::TenantRepo;

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let node_secret_manager = Arc::new(api::secrets::mock::MockNodeSecretManager::new());

    let alice = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let bob = customer_repo.seed_verified_free_customer("Bob", "bob@example.com");
    let bob_jwt = create_test_jwt(bob.id);

    node_secret_manager
        .create_node_api_key("node-a1", "us-east-1")
        .await
        .unwrap();

    let deployment = deployment_repo.seed_provisioned(
        alice.id,
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
        .create(alice.id, "alice-index", deployment.id)
        .await
        .unwrap();

    let vm = vm_inventory_repo.seed("us-east-1", "https://vm-test.flapjack.foo");
    tenant_repo
        .set_vm_id(alice.id, "alice-index", vm.id)
        .await
        .unwrap();

    let http_client = Arc::new(MockFlapjackHttpClient::default());
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

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/alice-index/experiments")
                .header("authorization", format!("Bearer {bob_jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(body["error"].as_str().unwrap().contains("not found"));
    assert_eq!(http_client.take_requests().len(), 0);
}

// ---------------------------------------------------------------------------
// Stage 8: event debugger
// ---------------------------------------------------------------------------

#[tokio::test]
async fn event_debug_returns_events_array() {
    let (app, jwt, http_client, customer_id) = setup_ready_index("products").await;

    let events = json!({
        "events": [
            {
                "timestampMs": 1709251200000_i64,
                "index": "products",
                "eventType": "view",
                "eventSubtype": null,
                "eventName": "Viewed Product",
                "userToken": "user_abc",
                "objectIds": ["obj1", "obj2"],
                "httpCode": 200,
                "validationErrors": []
            }
        ],
        "count": 1
    });
    http_client.push_json_response(200, events.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/products/events/debug")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, events);
    assert_eq!(body["events"].as_array().unwrap().len(), 1);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        format!(
            "https://vm-test.flapjack.foo/1/events/debug?index={}",
            test_flapjack_uid(customer_id, "products")
        )
    );
}

#[tokio::test]
async fn event_debug_returns_404_for_nonexistent_index() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/no-such-index/events/debug")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(body["error"].as_str().unwrap().contains("not found"));
    assert_eq!(http_client.take_requests().len(), 0);
}

#[tokio::test]
async fn event_debug_cross_tenant_isolation() {
    use api::repos::tenant_repo::TenantRepo;

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let node_secret_manager = Arc::new(api::secrets::mock::MockNodeSecretManager::new());

    let alice = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let bob = customer_repo.seed_verified_free_customer("Bob", "bob@example.com");
    let bob_jwt = create_test_jwt(bob.id);

    node_secret_manager
        .create_node_api_key("node-a1", "us-east-1")
        .await
        .unwrap();

    let deployment = deployment_repo.seed_provisioned(
        alice.id,
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
        .create(alice.id, "alice-index", deployment.id)
        .await
        .unwrap();

    let vm = vm_inventory_repo.seed("us-east-1", "https://vm-test.flapjack.foo");
    tenant_repo
        .set_vm_id(alice.id, "alice-index", vm.id)
        .await
        .unwrap();

    let http_client = Arc::new(MockFlapjackHttpClient::default());
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

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/alice-index/events/debug")
                .header("authorization", format!("Bearer {bob_jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(body["error"].as_str().unwrap().contains("not found"));
    assert_eq!(http_client.take_requests().len(), 0);
}

#[tokio::test]
async fn event_debug_forwards_filter_params() {
    let (app, jwt, http_client, customer_id) = setup_ready_index("products").await;

    let events = json!({"events": [], "count": 0});
    http_client.push_json_response(200, events.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/products/events/debug?eventType=click&status=error&limit=50")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, events);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0].url,
        format!("https://vm-test.flapjack.foo/1/events/debug?index={}&eventType=click&status=error&limit=50", test_flapjack_uid(customer_id, "products"))
    );
}

#[tokio::test]
async fn event_debug_strips_injected_index_param() {
    let (app, jwt, http_client, customer_id) = setup_ready_index("products").await;

    let events = json!({"events": [], "count": 0});
    http_client.push_json_response(200, events.clone());

    // Customer tries to inject index=evil to read another index's events
    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/products/events/debug?index=evil&eventType=click")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, _body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    // The injected `index=evil` must be stripped; only the server-set index is present
    assert_eq!(
        requests[0].url,
        format!(
            "https://vm-test.flapjack.foo/1/events/debug?index={}&eventType=click",
            test_flapjack_uid(customer_id, "products")
        )
    );
}

// ---------------------------------------------------------------------------
// Posthoc review: cold tier blocks proxy operations (not just search)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_settings_returns_gone_for_cold_index() {
    use api::repos::tenant_repo::TenantRepo;

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let node_secret_manager = Arc::new(api::secrets::mock::MockNodeSecretManager::new());

    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
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

    tenant_repo
        .create(customer.id, "cold-index", deployment.id)
        .await
        .unwrap();
    let vm = vm_inventory_repo.seed("us-east-1", "https://vm-test.flapjack.foo");
    tenant_repo
        .set_vm_id(customer.id, "cold-index", vm.id)
        .await
        .unwrap();
    tenant_repo
        .set_tier(customer.id, "cold-index", "cold")
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

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/indexes/cold-index/settings")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(
        status,
        StatusCode::GONE,
        "cold index settings should return 410 GONE"
    );
    assert!(
        body["error"].as_str().unwrap().contains("cold"),
        "error message should mention cold storage"
    );

    // Proxy must NOT have been called
    let requests = http_client.take_requests();
    assert_eq!(
        requests.len(),
        0,
        "no flapjack requests should be made for cold index"
    );
}

#[tokio::test]
async fn analytics_returns_gone_for_cold_index() {
    use api::repos::tenant_repo::TenantRepo;

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let node_secret_manager = Arc::new(api::secrets::mock::MockNodeSecretManager::new());

    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
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

    tenant_repo
        .create(customer.id, "cold-index", deployment.id)
        .await
        .unwrap();
    let vm = vm_inventory_repo.seed("us-east-1", "https://vm-test.flapjack.foo");
    tenant_repo
        .set_vm_id(customer.id, "cold-index", vm.id)
        .await
        .unwrap();
    tenant_repo
        .set_tier(customer.id, "cold-index", "cold")
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

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/indexes/cold-index/analytics/searches?startDate=2026-02-18&endDate=2026-02-25")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(
        status,
        StatusCode::GONE,
        "cold index analytics should return 410 GONE"
    );
    assert!(
        body["error"].as_str().unwrap().contains("cold"),
        "error message should mention cold storage"
    );

    let requests = http_client.take_requests();
    assert_eq!(
        requests.len(),
        0,
        "no flapjack requests should be made for cold index"
    );
}

// ---------------------------------------------------------------------------
// Structured search params (Stage 4)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn search_forwards_structured_params_to_flapjack() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    http_client.push_json_response(
        200,
        json!({
            "hits": [{"objectID": "1", "title": "Laptop"}],
            "nbHits": 42,
            "page": 2,
            "hitsPerPage": 5,
            "processingTimeMS": 3,
            "facets": {"category": {"electronics": 42}}
        }),
    );

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/products/search")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(
                    json!({
                        "query": "laptop",
                        "page": 2,
                        "hitsPerPage": 5,
                        "facets": ["category"],
                        "facetFilters": [["category:electronics"]]
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    // Response preserves full flapjack metadata instead of narrowing
    assert_eq!(body["nbHits"], 42);
    assert_eq!(body["page"], 2);
    assert_eq!(body["hitsPerPage"], 5);
    assert_eq!(body["facets"]["category"]["electronics"], 42);

    // Verify structured params were forwarded to flapjack
    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    let sent_body: Value = requests[0]
        .json_body
        .clone()
        .expect("request should have json body");
    assert_eq!(sent_body["query"], "laptop");
    assert_eq!(sent_body["page"], 2);
    assert_eq!(sent_body["hitsPerPage"], 5);
    assert_eq!(sent_body["facets"], json!(["category"]));
    assert_eq!(sent_body["facetFilters"], json!([["category:electronics"]]));
}

// ===========================================================================
// Stage 2-route: Document routes (batch, browse, get, delete)
// ===========================================================================

// ---------------------------------------------------------------------------
// documents: batch write forwards request body to engine
// ---------------------------------------------------------------------------

#[tokio::test]
async fn documents_batch_write_forwards_body_to_engine() {
    let (app, jwt, http_client, customer_id) = setup_ready_index("products").await;

    let upstream_response = json!({"taskID": 99, "objectIDs": ["obj-1", "obj-2"]});
    http_client.push_json_response(200, upstream_response.clone());

    let batch_body = json!({
        "requests": [
            {"action": "addObject", "body": {"objectID": "obj-1", "title": "First"}},
            {"action": "addObject", "body": {"objectID": "obj-2", "title": "Second"}}
        ]
    });

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/products/batch")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(batch_body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["taskID"], 99);
    assert_eq!(body["objectIDs"][0], "obj-1");

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(
        requests[0].url,
        format!(
            "https://vm-test.flapjack.foo/1/indexes/{}/batch",
            test_flapjack_uid(customer_id, "products")
        )
    );
    assert_eq!(requests[0].json_body, Some(batch_body));
}

// ---------------------------------------------------------------------------
// documents: legacy documents[] envelope is rejected
// ---------------------------------------------------------------------------

#[tokio::test]
async fn documents_batch_rejects_legacy_documents_envelope() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/products/batch")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(
                    json!({
                        "documents": [{"objectID": "obj-1", "title": "First"}]
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, _body) = response_json(resp).await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(http_client.take_requests().len(), 0);
}

// ---------------------------------------------------------------------------
// documents: batch write returns 404 for missing index
// ---------------------------------------------------------------------------

#[tokio::test]
async fn documents_batch_write_returns_404_for_missing_index() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/nonexistent/batch")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(json!({"requests": []}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, _body) = response_json(resp).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(http_client.take_requests().len(), 0);
}

// ---------------------------------------------------------------------------
// documents: browse forwards body with cursor
// ---------------------------------------------------------------------------

#[tokio::test]
async fn documents_browse_forwards_body_and_cursor() {
    let (app, jwt, http_client, customer_id) = setup_ready_index("products").await;

    let upstream_response = json!({
        "hits": [{"objectID": "obj-1", "title": "First"}],
        "nbHits": 1,
        "page": 0,
        "nbPages": 1,
        "hitsPerPage": 20,
        "cursor": "next-cursor"
    });
    http_client.push_json_response(200, upstream_response.clone());

    let browse_body = json!({"cursor": "prev-cursor", "hitsPerPage": 20});

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/products/browse")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(browse_body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["cursor"], "next-cursor");
    assert_eq!(body["hits"][0]["objectID"], "obj-1");

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(
        requests[0].url,
        format!(
            "https://vm-test.flapjack.foo/1/indexes/{}/browse",
            test_flapjack_uid(customer_id, "products")
        )
    );
    assert_eq!(requests[0].json_body, Some(browse_body));
}

// ---------------------------------------------------------------------------
// documents: browse rejects fields outside the frozen contract
// ---------------------------------------------------------------------------

#[tokio::test]
async fn documents_browse_rejects_unknown_fields() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/products/browse")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(json!({"page": 1}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, _body) = response_json(resp).await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(http_client.take_requests().len(), 0);
}

// ---------------------------------------------------------------------------
// documents: get single document by object ID
// ---------------------------------------------------------------------------

#[tokio::test]
async fn documents_get_object_returns_document() {
    let (app, jwt, http_client, customer_id) = setup_ready_index("products").await;

    let upstream_response = json!({
        "objectID": "obj-42",
        "title": "My Document",
        "description": "Some content"
    });
    http_client.push_json_response(200, upstream_response.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/products/objects/obj-42")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["objectID"], "obj-42");
    assert_eq!(body["title"], "My Document");

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        format!(
            "https://vm-test.flapjack.foo/1/indexes/{}/obj-42",
            test_flapjack_uid(customer_id, "products")
        )
    );
}

// ---------------------------------------------------------------------------
// documents: delete single document by object ID
// ---------------------------------------------------------------------------

#[tokio::test]
async fn documents_delete_object_returns_task() {
    let (app, jwt, http_client, customer_id) = setup_ready_index("products").await;

    let upstream_response = json!({"taskID": 101, "deletedAt": "2026-03-18T12:00:00Z"});
    http_client.push_json_response(200, upstream_response.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::DELETE)
                .uri("/indexes/products/objects/obj-42")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["taskID"], 101);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::DELETE);
    assert_eq!(
        requests[0].url,
        format!(
            "https://vm-test.flapjack.foo/1/indexes/{}/obj-42",
            test_flapjack_uid(customer_id, "products")
        )
    );
}

// ---------------------------------------------------------------------------
// documents: object ID with path traversal is rejected
// ---------------------------------------------------------------------------

#[tokio::test]
async fn documents_get_object_rejects_path_traversal() {
    let (app, jwt, _http_client, _customer_id) = setup_ready_index("products").await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/products/objects/..%2F..%2Fetc%2Fpasswd")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, _body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

// ---------------------------------------------------------------------------
// documents: cross-tenant isolation rejects access before proxying
// ---------------------------------------------------------------------------

#[tokio::test]
async fn documents_cross_tenant_isolation() {
    use api::repos::tenant_repo::TenantRepo;

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let node_secret_manager = Arc::new(api::secrets::mock::MockNodeSecretManager::new());

    let alice = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let bob = customer_repo.seed_verified_free_customer("Bob", "bob@example.com");
    let bob_jwt = create_test_jwt(bob.id);

    node_secret_manager
        .create_node_api_key("node-a1", "us-east-1")
        .await
        .unwrap();

    let deployment = deployment_repo.seed_provisioned(
        alice.id,
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
        .create(alice.id, "alice-index", deployment.id)
        .await
        .unwrap();

    let vm = vm_inventory_repo.seed("us-east-1", "https://vm-test.flapjack.foo");
    tenant_repo
        .set_vm_id(alice.id, "alice-index", vm.id)
        .await
        .unwrap();

    let http_client = Arc::new(MockFlapjackHttpClient::default());
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

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/alice-index/objects/obj-42")
                .header("authorization", format!("Bearer {bob_jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(body["error"].as_str().unwrap().contains("not found"));
    assert_eq!(http_client.take_requests().len(), 0);
}

// ===========================================================================
// Stage 3-route: Dictionary routes (languages, search, batch, settings)
// ===========================================================================

#[tokio::test]
async fn dictionary_languages_route_forwards_request_to_engine() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let upstream_response = json!({
        "en": {
            "stopwords": {"nbCustomEntries": 2},
            "plurals": null,
            "compounds": null
        }
    });
    http_client.push_json_response(200, upstream_response.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/products/dictionaries/languages")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, upstream_response);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        "https://vm-test.flapjack.foo/1/dictionaries/*/languages"
    );
    assert_eq!(requests[0].json_body, None);
}

#[tokio::test]
async fn dictionary_search_route_forwards_request_to_engine() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let upstream_response = json!({
        "hits": [{"objectID": "stop-the", "language": "en", "word": "the", "type": "custom"}],
        "nbHits": 1,
        "page": 0,
        "nbPages": 1
    });
    http_client.push_json_response(200, upstream_response.clone());

    let search_body = json!({
        "query": "",
        "language": "en"
    });

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/products/dictionaries/stopwords/search")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(search_body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, upstream_response);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(
        requests[0].url,
        "https://vm-test.flapjack.foo/1/dictionaries/stopwords/search"
    );
    assert_eq!(requests[0].json_body, Some(search_body));
}

#[tokio::test]
async fn dictionary_batch_route_forwards_request_to_engine() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let upstream_response = json!({"taskID": 87, "updatedAt": "2026-03-19T00:00:00Z"});
    http_client.push_json_response(200, upstream_response.clone());

    let batch_body = json!({
        "clearExistingDictionaryEntries": false,
        "requests": [
            {
                "action": "addEntry",
                "body": {"objectID": "stop-the", "language": "en", "word": "the"}
            }
        ]
    });

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/products/dictionaries/stopwords/batch")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(batch_body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, upstream_response);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(
        requests[0].url,
        "https://vm-test.flapjack.foo/1/dictionaries/stopwords/batch"
    );
    assert_eq!(requests[0].json_body, Some(batch_body));
}

#[tokio::test]
async fn dictionary_settings_get_route_forwards_request_to_engine() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let upstream_response = json!({
        "disableStandardEntries": false,
        "customNormalization": false
    });
    http_client.push_json_response(200, upstream_response.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/products/dictionaries/settings")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, upstream_response);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        "https://vm-test.flapjack.foo/1/dictionaries/*/settings"
    );
    assert_eq!(requests[0].json_body, None);
}

#[tokio::test]
async fn dictionary_settings_put_route_forwards_request_to_engine() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let upstream_response = json!({"taskID": 88, "updatedAt": "2026-03-19T00:00:00Z"});
    http_client.push_json_response(200, upstream_response.clone());

    let settings_body = json!({
        "disableStandardEntries": true,
        "customNormalization": false
    });

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::PUT)
                .uri("/indexes/products/dictionaries/settings")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(settings_body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, upstream_response);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::PUT);
    assert_eq!(
        requests[0].url,
        "https://vm-test.flapjack.foo/1/dictionaries/*/settings"
    );
    assert_eq!(requests[0].json_body, Some(settings_body));
}

#[tokio::test]
async fn dictionary_routes_reject_invalid_dictionary_names_before_proxying() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/products/dictionaries/not-a-dictionary/search")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(
                    json!({"query": "", "language": "en"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body["error"]
        .as_str()
        .unwrap_or_default()
        .contains("invalid dictionary name"));
    assert_eq!(http_client.take_requests().len(), 0);
}
