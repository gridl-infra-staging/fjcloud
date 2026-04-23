mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{create_test_jwt, mock_repo, MockCustomerRepo, TestStateBuilder};
use http_body_util::BodyExt;
use std::sync::Arc;
use tower::ServiceExt;
use uuid::Uuid;

use api::models::ayb_tenant::{AybTenantStatus, NewAybTenant};
use api::repos::ayb_tenant_repo::AybTenantRepo;
use api::repos::InMemoryAybTenantRepo;
use api::router::build_router;
use api::services::ayb_admin::{
    AybAdminClient, AybAdminError, AybTenantResponse, CreateTenantRequest,
};
use api::state::AppState;
use async_trait::async_trait;
use billing::plan::PlanTier;
use std::sync::Mutex;

// ---------------------------------------------------------------------------
// Local helpers (builders.rs is near 800-line limit — keep helpers here)
// ---------------------------------------------------------------------------

fn seed_ayb_tenant_repo() -> Arc<InMemoryAybTenantRepo> {
    Arc::new(InMemoryAybTenantRepo::new())
}

fn new_ayb_tenant(customer_id: Uuid) -> NewAybTenant {
    NewAybTenant {
        customer_id,
        ayb_tenant_id: format!("ayb-tid-{}", Uuid::new_v4()),
        ayb_slug: format!("slug-{}", &Uuid::new_v4().to_string()[..8]),
        ayb_cluster_id: "cluster-01".to_string(),
        ayb_url: "https://ayb.test/cluster-01".to_string(),
        status: AybTenantStatus::Ready,
        plan: PlanTier::Starter,
    }
}

fn test_state_with_ayb(
    customer_repo: Arc<MockCustomerRepo>,
    ayb_repo: Arc<InMemoryAybTenantRepo>,
) -> AppState {
    let mut state = TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .build();
    state.ayb_tenant_repo = ayb_repo;
    state
}

async fn body_json(body: Body) -> serde_json::Value {
    let bytes = body.collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

fn test_state_with_ayb_and_client(
    customer_repo: Arc<MockCustomerRepo>,
    ayb_repo: Arc<InMemoryAybTenantRepo>,
    ayb_client: Arc<dyn AybAdminClient + Send + Sync>,
) -> AppState {
    let mut state = TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_ayb_admin_client(ayb_client)
        .build();
    state.ayb_tenant_repo = ayb_repo;
    state
}

// ---------------------------------------------------------------------------
// Configurable mock AybAdminClient for DELETE tests
// ---------------------------------------------------------------------------

enum DeleteBehavior {
    Success,
    NotFound,
    ServiceUnavailable,
    BadRequest,
}

struct MockDeleteAybClient {
    behavior: Mutex<DeleteBehavior>,
}

impl MockDeleteAybClient {
    fn succeeding() -> Arc<Self> {
        Arc::new(Self {
            behavior: Mutex::new(DeleteBehavior::Success),
        })
    }

    fn not_found() -> Arc<Self> {
        Arc::new(Self {
            behavior: Mutex::new(DeleteBehavior::NotFound),
        })
    }

    fn unavailable() -> Arc<Self> {
        Arc::new(Self {
            behavior: Mutex::new(DeleteBehavior::ServiceUnavailable),
        })
    }

    fn bad_request() -> Arc<Self> {
        Arc::new(Self {
            behavior: Mutex::new(DeleteBehavior::BadRequest),
        })
    }
}

#[async_trait]
impl AybAdminClient for MockDeleteAybClient {
    fn base_url(&self) -> &str {
        "https://mock.ayb.test"
    }

    fn cluster_id(&self) -> &str {
        "cluster-01"
    }

    async fn create_tenant(
        &self,
        _request: CreateTenantRequest,
    ) -> Result<AybTenantResponse, AybAdminError> {
        unimplemented!("create_tenant not used in DELETE tests")
    }

    async fn delete_tenant(&self, tenant_id: &str) -> Result<AybTenantResponse, AybAdminError> {
        let behavior = self.behavior.lock().unwrap();
        match *behavior {
            DeleteBehavior::Success => Ok(AybTenantResponse {
                tenant_id: tenant_id.to_string(),
                name: "deleted".to_string(),
                slug: "deleted".to_string(),
                state: "deleting".to_string(),
                plan_tier: PlanTier::Starter,
            }),
            DeleteBehavior::NotFound => Err(AybAdminError::NotFound("AYB tenant not found".into())),
            DeleteBehavior::ServiceUnavailable => Err(AybAdminError::ServiceUnavailable),
            DeleteBehavior::BadRequest => {
                Err(AybAdminError::BadRequest("raw ayb delete failure".into()))
            }
        }
    }
}

// ---------------------------------------------------------------------------
// GET /allyourbase/instances — list
// ---------------------------------------------------------------------------

#[tokio::test]
async fn list_instances_returns_customer_tenants() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Test User", "test@example.com");
    let ayb_repo = seed_ayb_tenant_repo();
    let tenant = ayb_repo.create(new_ayb_tenant(customer.id)).await.unwrap();

    let token = create_test_jwt(customer.id);
    let app = build_router(test_state_with_ayb(customer_repo, ayb_repo));

    let req = Request::builder()
        .method("GET")
        .uri("/allyourbase/instances")
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp.into_body()).await;
    let instances = json.as_array().expect("response should be an array");
    assert_eq!(instances.len(), 1);
    assert_eq!(instances[0]["id"], tenant.id.to_string());
    assert_eq!(instances[0]["status"], "ready");
    assert_eq!(instances[0]["plan"], "starter");
}

#[tokio::test]
async fn list_instances_empty_when_no_tenants() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Test User", "test@example.com");
    let ayb_repo = seed_ayb_tenant_repo();

    let token = create_test_jwt(customer.id);
    let app = build_router(test_state_with_ayb(customer_repo, ayb_repo));

    let req = Request::builder()
        .method("GET")
        .uri("/allyourbase/instances")
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp.into_body()).await;
    let instances = json.as_array().expect("response should be an array");
    assert!(instances.is_empty());
}

// ---------------------------------------------------------------------------
// Customer isolation — customer A cannot see customer B's instances
// ---------------------------------------------------------------------------

#[tokio::test]
async fn list_instances_customer_isolation() {
    let customer_repo = mock_repo();
    let customer_a = customer_repo.seed("User A", "a@example.com");
    let customer_b = customer_repo.seed("User B", "b@example.com");
    let ayb_repo = seed_ayb_tenant_repo();

    ayb_repo
        .create(new_ayb_tenant(customer_a.id))
        .await
        .unwrap();
    ayb_repo
        .create(new_ayb_tenant(customer_b.id))
        .await
        .unwrap();

    let token_a = create_test_jwt(customer_a.id);
    let app = build_router(test_state_with_ayb(customer_repo, ayb_repo));

    let req = Request::builder()
        .method("GET")
        .uri("/allyourbase/instances")
        .header("authorization", format!("Bearer {token_a}"))
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp.into_body()).await;
    let instances = json.as_array().unwrap();
    assert_eq!(
        instances.len(),
        1,
        "customer A should only see their own instance"
    );
}

#[tokio::test]
async fn get_instance_customer_isolation() {
    let customer_repo = mock_repo();
    let customer_a = customer_repo.seed("User A", "a@example.com");
    let customer_b = customer_repo.seed("User B", "b@example.com");
    let ayb_repo = seed_ayb_tenant_repo();

    ayb_repo
        .create(new_ayb_tenant(customer_a.id))
        .await
        .unwrap();
    let tenant_b = ayb_repo
        .create(new_ayb_tenant(customer_b.id))
        .await
        .unwrap();

    let token_a = create_test_jwt(customer_a.id);
    let app = build_router(test_state_with_ayb(customer_repo, ayb_repo));

    // Customer A tries to fetch customer B's instance by local ID
    let req = Request::builder()
        .method("GET")
        .uri(format!("/allyourbase/instances/{}", tenant_b.id))
        .header("authorization", format!("Bearer {token_a}"))
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

// ---------------------------------------------------------------------------
// Soft-delete filtering — deleted_at IS NULL
// ---------------------------------------------------------------------------

#[tokio::test]
async fn list_instances_excludes_soft_deleted() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Test User", "test@example.com");
    let ayb_repo = seed_ayb_tenant_repo();

    let tenant = ayb_repo.create(new_ayb_tenant(customer.id)).await.unwrap();
    ayb_repo
        .soft_delete_for_customer(customer.id, tenant.id)
        .await
        .unwrap();

    let token = create_test_jwt(customer.id);
    let app = build_router(test_state_with_ayb(customer_repo, ayb_repo));

    let req = Request::builder()
        .method("GET")
        .uri("/allyourbase/instances")
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp.into_body()).await;
    let instances = json.as_array().unwrap();
    assert!(
        instances.is_empty(),
        "soft-deleted instances should not appear in list"
    );
}

#[tokio::test]
async fn get_instance_returns_404_for_soft_deleted() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Test User", "test@example.com");
    let ayb_repo = seed_ayb_tenant_repo();

    let tenant = ayb_repo.create(new_ayb_tenant(customer.id)).await.unwrap();
    let tenant_id = tenant.id;
    ayb_repo
        .soft_delete_for_customer(customer.id, tenant_id)
        .await
        .unwrap();

    let token = create_test_jwt(customer.id);
    let app = build_router(test_state_with_ayb(customer_repo, ayb_repo));

    let req = Request::builder()
        .method("GET")
        .uri(format!("/allyourbase/instances/{tenant_id}"))
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

// ---------------------------------------------------------------------------
// GET /allyourbase/instances/:id — uses local ID, not upstream AYB tenant ID
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_instance_by_local_id() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Test User", "test@example.com");
    let ayb_repo = seed_ayb_tenant_repo();

    let tenant = ayb_repo.create(new_ayb_tenant(customer.id)).await.unwrap();

    let token = create_test_jwt(customer.id);
    let app = build_router(test_state_with_ayb(customer_repo, ayb_repo));

    let req = Request::builder()
        .method("GET")
        .uri(format!("/allyourbase/instances/{}", tenant.id))
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp.into_body()).await;
    assert_eq!(json["id"], tenant.id.to_string());
    assert_eq!(json["ayb_slug"], tenant.ayb_slug);
    assert_eq!(json["status"], "ready");
    assert_eq!(json["plan"], "starter");
}

#[tokio::test]
async fn get_instance_by_upstream_ayb_id_returns_404() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Test User", "test@example.com");
    let ayb_repo = seed_ayb_tenant_repo();

    let tenant = ayb_repo.create(new_ayb_tenant(customer.id)).await.unwrap();

    let token = create_test_jwt(customer.id);
    let app = build_router(test_state_with_ayb(customer_repo, ayb_repo));

    // Use the upstream AYB tenant ID (a string, not a UUID) — should NOT resolve
    let req = Request::builder()
        .method("GET")
        .uri(format!("/allyourbase/instances/{}", tenant.ayb_tenant_id))
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    // ayb_tenant_id is not a valid UUID, so Axum rejects the path param (400)
    // The key invariant: upstream AYB IDs cannot resolve to a local instance
    let status = resp.status();
    assert!(
        status == StatusCode::BAD_REQUEST || status == StatusCode::NOT_FOUND,
        "expected 400 or 404, got {status}"
    );
}

#[tokio::test]
async fn get_instance_nonexistent_returns_404() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Test User", "test@example.com");
    let ayb_repo = seed_ayb_tenant_repo();

    let token = create_test_jwt(customer.id);
    let app = build_router(test_state_with_ayb(customer_repo, ayb_repo));

    let req = Request::builder()
        .method("GET")
        .uri(format!("/allyourbase/instances/{}", Uuid::new_v4()))
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

// ---------------------------------------------------------------------------
// Auth required
// ---------------------------------------------------------------------------

#[tokio::test]
async fn list_instances_unauthorized_without_auth() {
    let app = build_router(TestStateBuilder::new().build());

    let req = Request::builder()
        .method("GET")
        .uri("/allyourbase/instances")
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn get_instance_unauthorized_without_auth() {
    let app = build_router(TestStateBuilder::new().build());

    let req = Request::builder()
        .method("GET")
        .uri(format!("/allyourbase/instances/{}", Uuid::new_v4()))
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

// ---------------------------------------------------------------------------
// DELETE /allyourbase/instances/:id
// ---------------------------------------------------------------------------

#[tokio::test]
async fn delete_instance_returns_204() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Test User", "test@example.com");
    let ayb_repo = seed_ayb_tenant_repo();
    let tenant = ayb_repo.create(new_ayb_tenant(customer.id)).await.unwrap();

    let client = MockDeleteAybClient::succeeding();
    let token = create_test_jwt(customer.id);
    let app = build_router(test_state_with_ayb_and_client(
        customer_repo,
        ayb_repo,
        client,
    ));

    let req = Request::builder()
        .method("DELETE")
        .uri(format!("/allyourbase/instances/{}", tenant.id))
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn delete_instance_second_delete_returns_404_after_soft_delete() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Test User", "test@example.com");
    let ayb_repo = seed_ayb_tenant_repo();
    let tenant = ayb_repo.create(new_ayb_tenant(customer.id)).await.unwrap();

    let client = MockDeleteAybClient::succeeding();
    let token = create_test_jwt(customer.id);
    let app = build_router(test_state_with_ayb_and_client(
        customer_repo,
        ayb_repo,
        client,
    ));
    let uri = format!("/allyourbase/instances/{}", tenant.id);

    let first_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri(&uri)
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(first_resp.status(), StatusCode::NO_CONTENT);

    let second_resp = app
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri(&uri)
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(second_resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn delete_instance_customer_isolation() {
    let customer_repo = mock_repo();
    let customer_a = customer_repo.seed("User A", "a@example.com");
    let customer_b = customer_repo.seed("User B", "b@example.com");
    let ayb_repo = seed_ayb_tenant_repo();

    ayb_repo
        .create(new_ayb_tenant(customer_a.id))
        .await
        .unwrap();
    let tenant_b = ayb_repo
        .create(new_ayb_tenant(customer_b.id))
        .await
        .unwrap();

    let client = MockDeleteAybClient::succeeding();
    let token_a = create_test_jwt(customer_a.id);
    let app = build_router(test_state_with_ayb_and_client(
        customer_repo,
        ayb_repo,
        client,
    ));

    // Customer A tries to delete customer B's instance
    let req = Request::builder()
        .method("DELETE")
        .uri(format!("/allyourbase/instances/{}", tenant_b.id))
        .header("authorization", format!("Bearer {token_a}"))
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn delete_instance_idempotent_when_ayb_returns_not_found() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Test User", "test@example.com");
    let ayb_repo = seed_ayb_tenant_repo();
    let tenant = ayb_repo.create(new_ayb_tenant(customer.id)).await.unwrap();

    // AYB says tenant already gone upstream — treat as delete-complete
    let client = MockDeleteAybClient::not_found();
    let token = create_test_jwt(customer.id);
    let app = build_router(test_state_with_ayb_and_client(
        customer_repo,
        ayb_repo,
        client,
    ));

    let req = Request::builder()
        .method("DELETE")
        .uri(format!("/allyourbase/instances/{}", tenant.id))
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn delete_instance_503_when_ayb_client_not_configured() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Test User", "test@example.com");
    let ayb_repo = seed_ayb_tenant_repo();
    let tenant = ayb_repo.create(new_ayb_tenant(customer.id)).await.unwrap();

    // No AybAdminClient configured — state.ayb_admin_client is None
    let token = create_test_jwt(customer.id);
    let app = build_router(test_state_with_ayb(customer_repo, ayb_repo));

    let req = Request::builder()
        .method("DELETE")
        .uri(format!("/allyourbase/instances/{}", tenant.id))
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::SERVICE_UNAVAILABLE);

    let json = body_json(resp.into_body()).await;
    assert_eq!(json["error"], "service_not_configured");
}

#[tokio::test]
async fn delete_instance_propagates_upstream_failure() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Test User", "test@example.com");
    let ayb_repo = seed_ayb_tenant_repo();
    let tenant = ayb_repo.create(new_ayb_tenant(customer.id)).await.unwrap();

    // AYB service is down
    let client = MockDeleteAybClient::unavailable();
    let token = create_test_jwt(customer.id);
    let app = build_router(test_state_with_ayb_and_client(
        customer_repo,
        ayb_repo,
        client,
    ));

    let req = Request::builder()
        .method("DELETE")
        .uri(format!("/allyourbase/instances/{}", tenant.id))
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::SERVICE_UNAVAILABLE);
}

#[tokio::test]
async fn delete_instance_hides_raw_upstream_error_text() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Test User", "test@example.com");
    let ayb_repo = seed_ayb_tenant_repo();
    let tenant = ayb_repo.create(new_ayb_tenant(customer.id)).await.unwrap();

    let client = MockDeleteAybClient::bad_request();
    let token = create_test_jwt(customer.id);
    let app = build_router(test_state_with_ayb_and_client(
        customer_repo,
        ayb_repo,
        client,
    ));

    let req = Request::builder()
        .method("DELETE")
        .uri(format!("/allyourbase/instances/{}", tenant.id))
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::INTERNAL_SERVER_ERROR);

    let json = body_json(resp.into_body()).await;
    assert_eq!(json["error"], "internal server error");
}

#[tokio::test]
async fn delete_instance_unauthorized_without_auth() {
    let app = build_router(TestStateBuilder::new().build());

    let req = Request::builder()
        .method("DELETE")
        .uri(format!("/allyourbase/instances/{}", Uuid::new_v4()))
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}
