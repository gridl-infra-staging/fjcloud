mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{create_test_jwt, mock_repo, MockCustomerRepo, TestStateBuilder};
use http_body_util::BodyExt;
use std::sync::{Arc, Mutex};
use tower::ServiceExt;
use uuid::Uuid;

use api::models::ayb_tenant::{AybTenant, NewAybTenant};
use api::repos::ayb_tenant_repo::AybTenantRepo;
use api::repos::error::RepoError;
use api::repos::InMemoryAybTenantRepo;
use api::router::build_router;
use api::services::ayb_admin::{
    AybAdminClient, AybAdminError, AybTenantResponse, CreateTenantRequest,
};
use api::state::AppState;
use async_trait::async_trait;
use billing::plan::PlanTier;

// ---------------------------------------------------------------------------
// State helpers
// ---------------------------------------------------------------------------

/// Build AppState WITH an AYB client — for tests that exercise the handler logic.
fn test_state_with_ayb_and_client(
    customer_repo: Arc<MockCustomerRepo>,
    ayb_repo: Arc<dyn AybTenantRepo + Send + Sync>,
    ayb_client: Arc<dyn AybAdminClient + Send + Sync>,
) -> AppState {
    let mut state = TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_ayb_admin_client(ayb_client)
        .build();
    state.ayb_tenant_repo = ayb_repo;
    state
}

/// Build AppState WITHOUT an AYB client — for the "not configured" test.
fn test_state_without_ayb_client(
    customer_repo: Arc<MockCustomerRepo>,
    ayb_repo: Arc<dyn AybTenantRepo + Send + Sync>,
) -> AppState {
    let mut state = TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .build();
    state.ayb_tenant_repo = ayb_repo;
    state
}

// ---------------------------------------------------------------------------
// Request / response helpers
// ---------------------------------------------------------------------------

async fn body_json(body: Body) -> serde_json::Value {
    let bytes = body.collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

fn create_request(token: &str, body: serde_json::Value) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri("/allyourbase/instances")
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap()
}

fn list_request(token: &str) -> Request<Body> {
    Request::builder()
        .method("GET")
        .uri("/allyourbase/instances")
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap()
}

// ---------------------------------------------------------------------------
// Configurable mock AybAdminClient for CREATE tests
// ---------------------------------------------------------------------------

/// Controls what `create_tenant` returns. Each variant maps to an AybAdminError
/// or a success response.
enum CreateBehavior {
    Success,
    BadRequest,
    Conflict,
    ServiceUnavailable,
}

struct MockCreateAybClient {
    create_behavior: Mutex<CreateBehavior>,
    create_requests: Mutex<Vec<CreateTenantRequest>>,
    delete_requests: Mutex<Vec<String>>,
}

/// Wrapper repo that forces create() to fail while delegating read/delete
/// operations to an in-memory backing store.
struct FailCreateAybTenantRepo {
    inner: Arc<InMemoryAybTenantRepo>,
}

impl FailCreateAybTenantRepo {
    fn with_inner(inner: Arc<InMemoryAybTenantRepo>) -> Arc<Self> {
        Arc::new(Self { inner })
    }
}

#[async_trait]
impl AybTenantRepo for FailCreateAybTenantRepo {
    async fn create(&self, _tenant: NewAybTenant) -> Result<AybTenant, RepoError> {
        Err(RepoError::Conflict(
            "forced local persist failure for rollback test".into(),
        ))
    }

    async fn find_active_by_customer(
        &self,
        customer_id: Uuid,
    ) -> Result<Vec<AybTenant>, RepoError> {
        self.inner.find_active_by_customer(customer_id).await
    }

    async fn find_active_by_customer_and_id(
        &self,
        customer_id: Uuid,
        id: Uuid,
    ) -> Result<Option<AybTenant>, RepoError> {
        self.inner
            .find_active_by_customer_and_id(customer_id, id)
            .await
    }

    async fn soft_delete_for_customer(&self, customer_id: Uuid, id: Uuid) -> Result<(), RepoError> {
        self.inner.soft_delete_for_customer(customer_id, id).await
    }
}

impl MockCreateAybClient {
    fn succeeding() -> Arc<Self> {
        Arc::new(Self {
            create_behavior: Mutex::new(CreateBehavior::Success),
            create_requests: Mutex::new(Vec::new()),
            delete_requests: Mutex::new(Vec::new()),
        })
    }

    fn with_behavior(behavior: CreateBehavior) -> Arc<Self> {
        Arc::new(Self {
            create_behavior: Mutex::new(behavior),
            create_requests: Mutex::new(Vec::new()),
            delete_requests: Mutex::new(Vec::new()),
        })
    }
}

#[async_trait]
impl AybAdminClient for MockCreateAybClient {
    fn base_url(&self) -> &str {
        "https://mock.ayb.test"
    }

    fn cluster_id(&self) -> &str {
        "cluster-01"
    }

    async fn create_tenant(
        &self,
        request: CreateTenantRequest,
    ) -> Result<AybTenantResponse, AybAdminError> {
        self.create_requests.lock().unwrap().push(request.clone());
        let behavior = self.create_behavior.lock().unwrap();
        match *behavior {
            CreateBehavior::Success => Ok(AybTenantResponse {
                tenant_id: "ayb-created-1".to_string(),
                name: request.name,
                slug: request.slug,
                state: "provisioning".to_string(),
                plan_tier: request.plan_tier,
            }),
            CreateBehavior::BadRequest => {
                Err(AybAdminError::BadRequest("invalid tenant payload".into()))
            }
            CreateBehavior::Conflict => Err(AybAdminError::Conflict("slug already taken".into())),
            CreateBehavior::ServiceUnavailable => Err(AybAdminError::ServiceUnavailable),
        }
    }

    async fn delete_tenant(&self, tenant_id: &str) -> Result<AybTenantResponse, AybAdminError> {
        self.delete_requests
            .lock()
            .unwrap()
            .push(tenant_id.to_string());
        Ok(AybTenantResponse {
            tenant_id: tenant_id.to_string(),
            name: "deleted".to_string(),
            slug: "deleted".to_string(),
            state: "deleting".to_string(),
            plan_tier: PlanTier::Starter,
        })
    }
}

// ---------------------------------------------------------------------------
// Happy-path tests (carried forward from Stage 1)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_instance_returns_201_and_persists_provisioning_row() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Test User", "test@example.com");
    let ayb_repo = Arc::new(InMemoryAybTenantRepo::new());
    let client = MockCreateAybClient::succeeding();
    let token = create_test_jwt(customer.id);
    let app = build_router(test_state_with_ayb_and_client(
        customer_repo,
        ayb_repo.clone(),
        client.clone(),
    ));

    let resp = app
        .oneshot(create_request(
            &token,
            serde_json::json!({"name":"  Test Tenant  ","slug":"tenant-123","plan":"starter"}),
        ))
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::CREATED);
    let json = body_json(resp.into_body()).await;
    assert_eq!(json["ayb_slug"], "tenant-123");
    assert_eq!(json["status"], "provisioning");
    assert_eq!(json["plan"], "starter");
    assert_eq!(json["ayb_url"], "https://mock.ayb.test");

    let saved = ayb_repo.find_active_by_customer(customer.id).await.unwrap();
    assert_eq!(saved.len(), 1);
    assert_eq!(saved[0].ayb_tenant_id, "ayb-created-1");
    assert_eq!(saved[0].status, "provisioning");

    let sent = client.create_requests.lock().unwrap();
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].name, "Test Tenant");
    assert_eq!(sent[0].slug, "tenant-123");
    let owner_id = customer.id.to_string();
    assert_eq!(sent[0].owner_user_id.as_deref(), Some(owner_id.as_str()));
}

#[tokio::test]
async fn create_instance_rejects_invalid_slug_before_upstream_call() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Test User", "test@example.com");
    let ayb_repo = Arc::new(InMemoryAybTenantRepo::new());
    let client = MockCreateAybClient::succeeding();
    let token = create_test_jwt(customer.id);
    let app = build_router(test_state_with_ayb_and_client(
        customer_repo,
        ayb_repo,
        client.clone(),
    ));

    let resp = app
        .oneshot(create_request(
            &token,
            serde_json::json!({"name":"Tenant","slug":"Bad-Slug","plan":"starter"}),
        ))
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    assert!(client.create_requests.lock().unwrap().is_empty());
}

#[tokio::test]
async fn create_instance_deletes_upstream_tenant_when_local_persist_fails() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Test User", "test@example.com");
    let backing_repo = Arc::new(InMemoryAybTenantRepo::new());
    let ayb_repo = FailCreateAybTenantRepo::with_inner(backing_repo.clone());

    let client = MockCreateAybClient::succeeding();
    let token = create_test_jwt(customer.id);
    let app = build_router(test_state_with_ayb_and_client(
        customer_repo,
        ayb_repo,
        client.clone(),
    ));

    let resp = app
        .oneshot(create_request(
            &token,
            serde_json::json!({"name":"Tenant","slug":"tenant-123","plan":"starter"}),
        ))
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::CONFLICT);
    assert_eq!(client.create_requests.lock().unwrap().len(), 1);
    assert_eq!(
        client.delete_requests.lock().unwrap().as_slice(),
        ["ayb-created-1"]
    );
    assert!(
        backing_repo
            .find_active_by_customer(customer.id)
            .await
            .unwrap()
            .is_empty(),
        "no local row should persist when create() fails"
    );
}

// ---------------------------------------------------------------------------
// Upstream failure tests (CreateBehavior-driven)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_instance_returns_503_when_ayb_unavailable() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Test User", "test@example.com");
    let ayb_repo = Arc::new(InMemoryAybTenantRepo::new());
    let client = MockCreateAybClient::with_behavior(CreateBehavior::ServiceUnavailable);
    let token = create_test_jwt(customer.id);
    let app = build_router(test_state_with_ayb_and_client(
        customer_repo,
        ayb_repo.clone(),
        client,
    ));

    let resp = app
        .oneshot(create_request(
            &token,
            serde_json::json!({"name":"Tenant","slug":"tenant-123","plan":"starter"}),
        ))
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::SERVICE_UNAVAILABLE);
    // No row should be persisted when upstream fails
    let saved = ayb_repo.find_active_by_customer(customer.id).await.unwrap();
    assert!(saved.is_empty());
}

#[tokio::test]
async fn create_instance_returns_400_when_ayb_rejects_request() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Test User", "test@example.com");
    let ayb_repo = Arc::new(InMemoryAybTenantRepo::new());
    let client = MockCreateAybClient::with_behavior(CreateBehavior::BadRequest);
    let token = create_test_jwt(customer.id);
    let app = build_router(test_state_with_ayb_and_client(
        customer_repo,
        ayb_repo.clone(),
        client,
    ));

    let resp = app
        .oneshot(create_request(
            &token,
            serde_json::json!({"name":"Tenant","slug":"tenant-123","plan":"starter"}),
        ))
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let json = body_json(resp.into_body()).await;
    assert_eq!(json["error"], "invalid tenant payload");
    // No row persisted
    let saved = ayb_repo.find_active_by_customer(customer.id).await.unwrap();
    assert!(saved.is_empty());
}

#[tokio::test]
async fn create_instance_returns_409_when_ayb_reports_conflict() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Test User", "test@example.com");
    let ayb_repo = Arc::new(InMemoryAybTenantRepo::new());
    let client = MockCreateAybClient::with_behavior(CreateBehavior::Conflict);
    let token = create_test_jwt(customer.id);
    let app = build_router(test_state_with_ayb_and_client(
        customer_repo,
        ayb_repo.clone(),
        client,
    ));

    let resp = app
        .oneshot(create_request(
            &token,
            serde_json::json!({"name":"Tenant","slug":"tenant-123","plan":"starter"}),
        ))
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::CONFLICT);
    let json = body_json(resp.into_body()).await;
    assert_eq!(json["error"], "slug already taken");
    // No row persisted
    let saved = ayb_repo.find_active_by_customer(customer.id).await.unwrap();
    assert!(saved.is_empty());
}

#[tokio::test]
async fn create_instance_returns_503_when_ayb_client_not_configured() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Test User", "test@example.com");
    let ayb_repo = Arc::new(InMemoryAybTenantRepo::new());
    let token = create_test_jwt(customer.id);
    // No AybAdminClient configured — state.ayb_admin_client is None
    let app = build_router(test_state_without_ayb_client(customer_repo, ayb_repo));

    let resp = app
        .oneshot(create_request(
            &token,
            serde_json::json!({"name":"Tenant","slug":"tenant-123","plan":"starter"}),
        ))
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::SERVICE_UNAVAILABLE);
    let json = body_json(resp.into_body()).await;
    assert_eq!(json["error"], "service_not_configured");
}

// ---------------------------------------------------------------------------
// Input validation tests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_instance_rejects_empty_name() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Test User", "test@example.com");
    let ayb_repo = Arc::new(InMemoryAybTenantRepo::new());
    let client = MockCreateAybClient::succeeding();
    let token = create_test_jwt(customer.id);
    let app = build_router(test_state_with_ayb_and_client(
        customer_repo,
        ayb_repo,
        client.clone(),
    ));

    // Name is whitespace-only — after trim it becomes empty
    let resp = app
        .oneshot(create_request(
            &token,
            serde_json::json!({"name":"   ","slug":"tenant-123","plan":"starter"}),
        ))
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let json = body_json(resp.into_body()).await;
    assert_eq!(json["error"], "name must not be empty");
    // No upstream call should have been made
    assert!(client.create_requests.lock().unwrap().is_empty());
}

#[tokio::test]
async fn create_instance_rejects_slug_too_short() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Test User", "test@example.com");
    let ayb_repo = Arc::new(InMemoryAybTenantRepo::new());
    let client = MockCreateAybClient::succeeding();
    let token = create_test_jwt(customer.id);
    let app = build_router(test_state_with_ayb_and_client(
        customer_repo,
        ayb_repo,
        client.clone(),
    ));

    let resp = app
        .oneshot(create_request(
            &token,
            serde_json::json!({"name":"Tenant","slug":"ab","plan":"starter"}),
        ))
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let json = body_json(resp.into_body()).await;
    assert_eq!(json["error"], "slug must be between 3 and 63 characters");
    assert!(client.create_requests.lock().unwrap().is_empty());
}

#[tokio::test]
async fn create_instance_rejects_slug_with_trailing_hyphen() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Test User", "test@example.com");
    let ayb_repo = Arc::new(InMemoryAybTenantRepo::new());
    let client = MockCreateAybClient::succeeding();
    let token = create_test_jwt(customer.id);
    let app = build_router(test_state_with_ayb_and_client(
        customer_repo,
        ayb_repo,
        client.clone(),
    ));

    let resp = app
        .oneshot(create_request(
            &token,
            serde_json::json!({"name":"Tenant","slug":"tenant-","plan":"starter"}),
        ))
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let json = body_json(resp.into_body()).await;
    assert_eq!(
        json["error"],
        "slug must end with a lowercase letter or digit"
    );
    assert!(client.create_requests.lock().unwrap().is_empty());
}

// ---------------------------------------------------------------------------
// Soft-delete + re-create test
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_instance_succeeds_after_soft_delete_of_prior_instance() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Test User", "test@example.com");
    let ayb_repo = Arc::new(InMemoryAybTenantRepo::new());

    // Seed an existing instance, then soft-delete it
    let first = ayb_repo
        .create(NewAybTenant {
            customer_id: customer.id,
            ayb_tenant_id: "old-upstream".to_string(),
            ayb_slug: "old-slug".to_string(),
            ayb_cluster_id: "cluster-01".to_string(),
            ayb_url: "https://mock.ayb.test".to_string(),
            status: api::models::ayb_tenant::AybTenantStatus::Ready,
            plan: PlanTier::Starter,
        })
        .await
        .unwrap();
    ayb_repo
        .soft_delete_for_customer(customer.id, first.id)
        .await
        .unwrap();

    let client = MockCreateAybClient::succeeding();
    let token = create_test_jwt(customer.id);
    let app = build_router(test_state_with_ayb_and_client(
        customer_repo,
        ayb_repo.clone(),
        client,
    ));

    let resp = app
        .oneshot(create_request(
            &token,
            serde_json::json!({"name":"New Tenant","slug":"new-slug","plan":"starter"}),
        ))
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::CREATED);
    // Only the new (active) instance should appear
    let active = ayb_repo.find_active_by_customer(customer.id).await.unwrap();
    assert_eq!(active.len(), 1);
    assert_eq!(active[0].ayb_slug, "new-slug");
}

// ---------------------------------------------------------------------------
// Auth / isolation tests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_instance_returns_401_without_jwt() {
    let customer_repo = mock_repo();
    let ayb_repo = Arc::new(InMemoryAybTenantRepo::new());
    let client = MockCreateAybClient::succeeding();
    let app = build_router(test_state_with_ayb_and_client(
        customer_repo,
        ayb_repo,
        client,
    ));

    // POST without Authorization header
    let req = Request::builder()
        .method("POST")
        .uri("/allyourbase/instances")
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({"name":"Tenant","slug":"tenant-123","plan":"starter"}).to_string(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn create_instance_customer_isolation() {
    let customer_repo = mock_repo();
    let customer_a = customer_repo.seed("Alice", "alice@example.com");
    let customer_b = customer_repo.seed("Bob", "bob@example.com");
    let ayb_repo = Arc::new(InMemoryAybTenantRepo::new());
    let client = MockCreateAybClient::succeeding();
    let token_a = create_test_jwt(customer_a.id);
    let token_b = create_test_jwt(customer_b.id);

    let state = test_state_with_ayb_and_client(customer_repo, ayb_repo.clone(), client);
    let app = build_router(state);

    // Customer A creates an instance
    let resp = app
        .clone()
        .oneshot(create_request(
            &token_a,
            serde_json::json!({"name":"Alice Tenant","slug":"alice-db","plan":"starter"}),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);

    // Customer B lists instances — should see empty array
    let resp = app.oneshot(list_request(&token_b)).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let json = body_json(resp.into_body()).await;
    let instances = json.as_array().expect("response should be an array");
    assert!(
        instances.is_empty(),
        "customer B should not see A's instance"
    );
}
