mod common;

use api::models::ayb_tenant::{AybTenant, NewAybTenant};
use api::repos::{AybTenantRepo, CustomerRepo};
use api::repos::{InMemoryAybTenantRepo, RepoError};
use api::services::ayb_admin::{
    AybAdminClient, AybAdminError, AybTenantResponse, CreateTenantRequest,
};
use async_trait::async_trait;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use chrono::{Duration, SecondsFormat, Utc};
use common::{
    create_test_jwt, mock_repo, new_ready_ayb_tenant, seed_ayb_tenant_repo,
    test_state_with_ayb_tenant_repo, TestStateBuilder,
};
use http_body_util::BodyExt;
use rust_decimal::Decimal;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use tokio::sync::oneshot;
use tower::ServiceExt;
use uuid::Uuid;

fn test_app(customer_repo: std::sync::Arc<common::MockCustomerRepo>) -> axum::Router {
    api::router::build_router(common::test_state_with_repo(customer_repo))
}

fn test_app_with_api_key_repo(
    customer_repo: std::sync::Arc<common::MockCustomerRepo>,
    api_key_repo: std::sync::Arc<common::MockApiKeyRepo>,
) -> axum::Router {
    api::router::build_router(common::test_state_with_api_key_repo(
        customer_repo,
        api_key_repo,
    ))
}

async fn body_json(body: Body) -> serde_json::Value {
    let bytes = body.collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

/// Extract JSON from a full response (consumes the response).
async fn resp_json(resp: axum::response::Response) -> serde_json::Value {
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

/// Hash a password using argon2 (same as the API does internally).
fn hash_password(password: &str) -> String {
    api::password::hash_password(password).expect("hashing should not fail in tests")
}

struct BlockingCreateAybClient {
    entered_tx: Mutex<Option<oneshot::Sender<()>>>,
    release_rx: Mutex<Option<oneshot::Receiver<()>>>,
}

impl BlockingCreateAybClient {
    fn new(entered_tx: oneshot::Sender<()>, release_rx: oneshot::Receiver<()>) -> Arc<Self> {
        Arc::new(Self {
            entered_tx: Mutex::new(Some(entered_tx)),
            release_rx: Mutex::new(Some(release_rx)),
        })
    }
}

#[async_trait]
impl AybAdminClient for BlockingCreateAybClient {
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
        if let Some(tx) = self.entered_tx.lock().unwrap().take() {
            let _ = tx.send(());
        }

        let release_rx = { self.release_rx.lock().unwrap().take() };
        if let Some(rx) = release_rx {
            let _ = rx.await;
        }

        Ok(AybTenantResponse {
            tenant_id: format!("ayb-tid-{}", Uuid::new_v4()),
            name: request.name,
            slug: request.slug,
            state: "ready".to_string(),
            plan_tier: request.plan_tier,
        })
    }

    async fn delete_tenant(&self, _tenant_id: &str) -> Result<AybTenantResponse, AybAdminError> {
        unimplemented!("delete_tenant not used in this test")
    }
}

struct BlockFirstFindActiveAybTenantRepo {
    inner: Arc<InMemoryAybTenantRepo>,
    blocked_once: AtomicBool,
    entered_tx: Mutex<Option<oneshot::Sender<()>>>,
    release_rx: Mutex<Option<oneshot::Receiver<()>>>,
}

impl BlockFirstFindActiveAybTenantRepo {
    fn new(
        inner: Arc<InMemoryAybTenantRepo>,
        entered_tx: oneshot::Sender<()>,
        release_rx: oneshot::Receiver<()>,
    ) -> Arc<Self> {
        Arc::new(Self {
            inner,
            blocked_once: AtomicBool::new(false),
            entered_tx: Mutex::new(Some(entered_tx)),
            release_rx: Mutex::new(Some(release_rx)),
        })
    }
}

#[async_trait]
impl AybTenantRepo for BlockFirstFindActiveAybTenantRepo {
    async fn create(&self, tenant: NewAybTenant) -> Result<AybTenant, RepoError> {
        self.inner.create(tenant).await
    }

    async fn find_active_by_customer(
        &self,
        customer_id: Uuid,
    ) -> Result<Vec<AybTenant>, RepoError> {
        if !self.blocked_once.swap(true, Ordering::SeqCst) {
            if let Some(tx) = self.entered_tx.lock().unwrap().take() {
                let _ = tx.send(());
            }

            let release_rx = { self.release_rx.lock().unwrap().take() };
            if let Some(rx) = release_rx {
                let _ = rx.await;
            }
        }

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

struct DeletedAccountContext {
    app: axum::Router,
    repo: std::sync::Arc<common::MockCustomerRepo>,
    token: String,
    customer_id: Uuid,
    email: &'static str,
    password: &'static str,
    original_customer_count: usize,
}

async fn setup_deleted_account_context() -> DeletedAccountContext {
    let repo = mock_repo();
    let app = test_app(repo.clone());
    let email = "delete@example.com";
    let password = "strongpassword123";

    let register_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/auth/register")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "name": "DeleteMe",
                        "email": email,
                        "password": password
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(register_resp.status(), StatusCode::CREATED);

    let login_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/auth/login")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "email": email,
                        "password": password
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(login_resp.status(), StatusCode::OK);

    let token = resp_json(login_resp).await["token"]
        .as_str()
        .expect("login should return JWT")
        .to_owned();

    let customer = repo
        .find_by_email(email)
        .await
        .expect("mock repo lookup should succeed")
        .expect("registered customer should exist");
    let customer_id = customer.id;
    let original_customer_count = repo
        .list()
        .await
        .expect("mock repo list should succeed")
        .len();

    let delete_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri("/account")
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({ "password": password }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(delete_resp.status(), StatusCode::NO_CONTENT);

    DeletedAccountContext {
        app,
        repo,
        token,
        customer_id,
        email,
        password,
        original_customer_count,
    }
}

#[tokio::test]
async fn get_profile_returns_correct_data() {
    let repo = mock_repo();
    let customer = repo.seed("Alice", "alice@example.com");
    let token = create_test_jwt(customer.id);
    let app = test_app(repo);

    let resp = app
        .oneshot(
            Request::get("/account")
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp.into_body()).await;
    assert_eq!(json["id"], customer.id.to_string());
    assert_eq!(json["name"], "Alice");
    assert_eq!(json["email"], "alice@example.com");
    assert_eq!(json["email_verified"], false);
    assert_eq!(json["billing_plan"], "free");
    assert!(json["created_at"].is_string());
    // Sensitive fields must NOT be present
    assert!(json.get("password_hash").is_none());
    assert!(json.get("stripe_customer_id").is_none());
}

#[tokio::test]
async fn update_name_works() {
    let repo = mock_repo();
    let customer = repo.seed("OldName", "user@example.com");
    let token = create_test_jwt(customer.id);
    let app = test_app(repo);

    let resp = app
        .oneshot(
            Request::builder()
                .method("PATCH")
                .uri("/account")
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(r#"{"name":"NewName"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp.into_body()).await;
    assert_eq!(json["name"], "NewName");
    assert_eq!(json["email"], "user@example.com");
    assert_eq!(json["billing_plan"], "free");
}

#[tokio::test]
async fn get_profile_returns_shared_billing_plan() {
    let repo = mock_repo();
    let customer = repo.seed_verified_shared_customer("Bob", "bob@example.com");
    let token = create_test_jwt(customer.id);
    let app = test_app(repo);

    let resp = app
        .oneshot(
            Request::get("/account")
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp.into_body()).await;
    assert_eq!(json["billing_plan"], "shared");
}

#[tokio::test]
async fn account_export_returns_exact_profile_payload_without_sensitive_fields() {
    let customer_repo = mock_repo();
    let api_key_repo = common::mock_api_key_repo();
    let customer = customer_repo.seed_verified_shared_customer("Export User", "export@example.com");
    let token = create_test_jwt(customer.id);
    let app = test_app_with_api_key_repo(customer_repo.clone(), api_key_repo.clone());

    let seeded_stripe_id = "cus_sensitive_export_123";
    let seeded_email_verify_token = "verify-token-sensitive-export";
    let seeded_password_reset_token = "reset-token-sensitive-export";
    let seeded_api_key_name = "sensitive-export-key-name";
    let seeded_api_key_prefix = "fjx_sensitive_prefix";
    let seeded_api_key_hash = "sensitive-export-key-hash";
    let seeded_quota_warning_at = Utc::now();

    customer_repo
        .set_stripe_customer_id(customer.id, seeded_stripe_id)
        .await
        .expect("seed stripe customer id");
    customer_repo
        .set_email_verify_token(
            customer.id,
            seeded_email_verify_token,
            seeded_quota_warning_at + Duration::hours(1),
        )
        .await
        .expect("seed email verify token");
    customer_repo
        .set_password_reset_token(
            customer.id,
            seeded_password_reset_token,
            seeded_quota_warning_at + Duration::hours(2),
        )
        .await
        .expect("seed password reset token");
    customer_repo
        .set_quota_warning_sent_at(customer.id, seeded_quota_warning_at)
        .await
        .expect("seed quota warning timestamp");
    customer_repo
        .set_object_storage_egress_carryforward_cents(customer.id, Decimal::new(1250, 2))
        .await
        .expect("seed egress carry-forward cents");
    api_key_repo.seed(
        customer.id,
        seeded_api_key_name,
        seeded_api_key_hash,
        seeded_api_key_prefix,
        vec!["indexes:read".to_string()],
    );

    let resp = app
        .oneshot(
            Request::get("/account/export")
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let status = resp.status();
    let cache_control = resp
        .headers()
        .get("cache-control")
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned);
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let raw_body = String::from_utf8(bytes.to_vec()).expect("response body should be utf-8");

    assert_eq!(status, StatusCode::OK);
    assert_eq!(cache_control.as_deref(), Some("private, no-store"));

    let json: serde_json::Value =
        serde_json::from_str(&raw_body).expect("account export response should be valid JSON");
    let expected = serde_json::json!({
        "profile": {
            "id": customer.id.to_string(),
            "name": "Export User",
            "email": "export@example.com",
            "email_verified": true,
            "billing_plan": "shared",
            "created_at": customer.created_at.to_rfc3339_opts(SecondsFormat::AutoSi, true)
        }
    });

    assert_eq!(json, expected);

    for forbidden_term in [
        "password_hash",
        "$argon2",
        "stripe_customer_id",
        seeded_stripe_id,
        "api_keys",
        "key_hash",
        seeded_api_key_hash,
        seeded_api_key_prefix,
        seeded_api_key_name,
        "email_verify_token",
        "password_reset_token",
        "quota_warning_sent_at",
        "object_storage_egress_carryforward_cents",
        "status",
        "updated_at",
        "deleted_at",
    ] {
        assert!(
            !raw_body.contains(forbidden_term),
            "export response leaked forbidden term: {forbidden_term}"
        );
    }
}

#[tokio::test]
async fn get_profile_canonicalizes_non_lowercase_billing_plan() {
    let repo = mock_repo();
    let customer = repo.seed("Casey", "casey@example.com");
    repo.set_billing_plan(customer.id, "FREE").await.unwrap();
    let token = create_test_jwt(customer.id);
    let app = test_app(repo);

    let resp = app
        .oneshot(
            Request::get("/account")
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp.into_body()).await;
    assert_eq!(json["billing_plan"], "free");
}

#[tokio::test]
async fn update_with_empty_name_returns_400() {
    let repo = mock_repo();
    let customer = repo.seed("Name", "user@example.com");
    let token = create_test_jwt(customer.id);
    let app = test_app(repo);

    let resp = app
        .oneshot(
            Request::builder()
                .method("PATCH")
                .uri("/account")
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(r#"{"name":"  "}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn change_password_with_correct_current_succeeds() {
    let repo = mock_repo();
    let hashed = hash_password("oldpassword");
    let customer = repo
        .create_with_password("User", "user@example.com", &hashed)
        .await
        .unwrap();
    let token = create_test_jwt(customer.id);
    let app = test_app(repo);

    let resp = app
        .oneshot(
            Request::post("/account/change-password")
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::to_string(&serde_json::json!({
                        "current_password": "oldpassword",
                        "new_password": "newpassword123"
                    }))
                    .unwrap(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn account_endpoints_401_without_auth() {
    let app = test_app(mock_repo());

    // GET /account
    let resp = app
        .clone()
        .oneshot(Request::get("/account").body(Body::empty()).unwrap())
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

    // GET /account/export
    let resp = app
        .clone()
        .oneshot(Request::get("/account/export").body(Body::empty()).unwrap())
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

    // PATCH /account
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("PATCH")
                .uri("/account")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"name":"X"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

    // POST /account/change-password
    let resp = app
        .oneshot(
            Request::post("/account/change-password")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"current_password":"a","new_password":"b"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

/// Change-password should reject new passwords exceeding 128 chars (Argon2 DoS prevention).
#[tokio::test]
async fn change_password_rejects_new_password_exceeding_max_length() {
    let repo = mock_repo();
    let hashed = hash_password("oldpassword");
    let customer = repo
        .create_with_password("User", "user@example.com", &hashed)
        .await
        .unwrap();
    let app = test_app(repo);
    let token = create_test_jwt(customer.id);
    let long_password = "a".repeat(129);

    let resp = app
        .oneshot(
            Request::post("/account/change-password")
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "current_password": "oldpassword",
                        "new_password": long_password
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

/// Wrong current password error must not leak account details (ID, email, hash).
#[tokio::test]
async fn change_password_wrong_current_password_does_not_leak_account_info() {
    let repo = mock_repo();
    let hashed = hash_password("realpassword");
    let customer = repo
        .create_with_password("User", "user@example.com", &hashed)
        .await
        .unwrap();
    let token = create_test_jwt(customer.id);
    let app = test_app(repo);

    let resp = app
        .oneshot(
            Request::post("/account/change-password")
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "current_password": "wrongpassword",
                        "new_password": "newpassword123"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let json = body_json(resp.into_body()).await;
    // Must contain ONLY the safe error key
    assert_eq!(
        json,
        serde_json::json!({"error": "current password is incorrect"}),
        "response must contain only the safe error string, no account details"
    );
    // Paranoia: verify no sensitive fields leaked
    let body_str = json.to_string();
    assert!(
        !body_str.contains(&customer.id.to_string()),
        "customer ID leaked"
    );
    assert!(!body_str.contains("user@example.com"), "email leaked");
    assert!(!body_str.contains("$argon2"), "password hash leaked");
}

/// Change-password should reject current passwords exceeding 128 chars (defense-in-depth).
#[tokio::test]
async fn change_password_rejects_current_password_exceeding_max_length() {
    let repo = mock_repo();
    let hashed = hash_password("oldpassword");
    let customer = repo
        .create_with_password("User", "user@example.com", &hashed)
        .await
        .unwrap();
    let app = test_app(repo);
    let token = create_test_jwt(customer.id);
    let long_current = "a".repeat(129);

    let resp = app
        .oneshot(
            Request::post("/account/change-password")
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "current_password": long_current,
                        "new_password": "newpassword123"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let json = body_json(resp.into_body()).await;
    assert!(
        json["error"].as_str().unwrap().contains("at most 128"),
        "expected length error, got: {:?}",
        json
    );
}

// ---------------------------------------------------------------------------
// DELETE /account (soft-delete with password re-authentication)
// ---------------------------------------------------------------------------

/// Successful account deletion: register with password via HTTP → login via
/// HTTP → DELETE /account with the correct password → 200 → GET /account → 401.
#[tokio::test]
async fn delete_account_with_correct_password_succeeds() {
    let delete_context = setup_deleted_account_context().await;

    let resp = delete_context
        .app
        .clone()
        .oneshot(
            Request::get("/account")
                .header("authorization", format!("Bearer {}", delete_context.token))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn delete_account_with_active_ayb_tenant_returns_409_and_preserves_active_customer() {
    let repo = mock_repo();
    let hashed = hash_password("realpassword");
    let customer = repo
        .create_with_password("User", "user@example.com", &hashed)
        .await
        .unwrap();
    let token = create_test_jwt(customer.id);
    let ayb_repo = seed_ayb_tenant_repo();
    ayb_repo
        .create(new_ready_ayb_tenant(customer.id))
        .await
        .expect("active AYB tenant seed should succeed");
    let app = api::router::build_router(test_state_with_ayb_tenant_repo(repo.clone(), ayb_repo));

    let resp = app
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri("/account")
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({ "password": "realpassword" }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CONFLICT);

    let json = body_json(resp.into_body()).await;
    assert_eq!(
        json["error"],
        "Delete your active AllYourBase instance before deleting your account."
    );

    let persisted_customer = repo
        .find_by_id(customer.id)
        .await
        .expect("mock repo lookup should succeed")
        .expect("customer row should still exist");
    assert_eq!(
        persisted_customer.status, "active",
        "conflict path must not soft-delete the customer"
    );
}

#[tokio::test]
async fn delete_account_concurrent_ayb_create_keeps_customer_active_and_avoids_orphan_state() {
    let customer_repo = mock_repo();
    let hashed = hash_password("realpassword");
    let customer = customer_repo
        .create_with_password("User", "user@example.com", &hashed)
        .await
        .unwrap();
    let token = create_test_jwt(customer.id);
    let ayb_repo = seed_ayb_tenant_repo();
    let (entered_tx, entered_rx) = oneshot::channel();
    let (release_tx, release_rx) = oneshot::channel();
    let client = BlockingCreateAybClient::new(entered_tx, release_rx);

    let mut state = TestStateBuilder::new()
        .with_customer_repo(customer_repo.clone())
        .with_ayb_admin_client(client)
        .build();
    state.ayb_tenant_repo = ayb_repo.clone();
    let app = api::router::build_router(state);

    let create_task = tokio::spawn({
        let app = app.clone();
        let token = token.clone();
        async move {
            app.oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/allyourbase/instances")
                    .header("authorization", format!("Bearer {token}"))
                    .header("content-type", "application/json")
                    .body(Body::from(
                        serde_json::json!({
                            "name": "Primary",
                            "slug": format!("acct-race-{}", &Uuid::new_v4().to_string()[..8]),
                            "plan": "starter"
                        })
                        .to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .expect("create request should complete")
        }
    });

    // Bound the wait: if the create handler short-circuits before reaching
    // client.create_tenant() (e.g. because lock_account_lifecycle returns
    // 503 in a misconfigured test pool), the BlockingCreateAybClient still
    // owns entered_tx via the AppState, so a plain `.await` would hang
    // forever. Failing loudly at 30s makes that misconfiguration a test
    // assertion instead of a CI timeout.
    tokio::time::timeout(std::time::Duration::from_secs(30), entered_rx)
        .await
        .expect("create flow should reach AYB create call within 30s")
        .expect("create flow should reach AYB create call");

    let delete_task = tokio::spawn({
        let app = app.clone();
        let token = token.clone();
        async move {
            app.oneshot(
                Request::builder()
                    .method("DELETE")
                    .uri("/account")
                    .header("authorization", format!("Bearer {token}"))
                    .header("content-type", "application/json")
                    .body(Body::from(
                        serde_json::json!({ "password": "realpassword" }).to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .expect("delete request should complete")
        }
    });

    let _ = release_tx.send(());

    let create_resp = create_task
        .await
        .expect("create task should join without panicking");
    let delete_resp = delete_task
        .await
        .expect("delete task should join without panicking");

    assert_eq!(create_resp.status(), StatusCode::CREATED);
    assert_eq!(delete_resp.status(), StatusCode::CONFLICT);

    let persisted_customer = customer_repo
        .find_by_id(customer.id)
        .await
        .expect("mock repo lookup should succeed")
        .expect("customer row should still exist");
    assert_eq!(
        persisted_customer.status, "active",
        "concurrent create/delete must not leave a soft-deleted customer"
    );

    let active_tenants = ayb_repo
        .find_active_by_customer(customer.id)
        .await
        .expect("active tenant lookup should succeed");
    assert_eq!(
        active_tenants.len(),
        1,
        "create should persist one active AYB tenant row"
    );
}

#[tokio::test]
async fn delete_account_concurrent_delete_first_blocks_stale_token_create_and_persists_no_tenant() {
    let customer_repo = mock_repo();
    let hashed = hash_password("realpassword");
    let customer = customer_repo
        .create_with_password("User", "user@example.com", &hashed)
        .await
        .unwrap();
    let token = create_test_jwt(customer.id);

    let inner_ayb_repo = seed_ayb_tenant_repo();
    let (delete_entered_tx, delete_entered_rx) = oneshot::channel();
    let (release_delete_tx, release_delete_rx) = oneshot::channel();
    let blocking_ayb_repo = BlockFirstFindActiveAybTenantRepo::new(
        inner_ayb_repo.clone(),
        delete_entered_tx,
        release_delete_rx,
    );

    let (create_entered_tx, _create_entered_rx) = oneshot::channel();
    let (release_create_tx, release_create_rx) = oneshot::channel();
    let client = BlockingCreateAybClient::new(create_entered_tx, release_create_rx);
    let _ = release_create_tx.send(());

    let mut state = TestStateBuilder::new()
        .with_customer_repo(customer_repo.clone())
        .with_ayb_admin_client(client)
        .build();
    state.ayb_tenant_repo = blocking_ayb_repo;
    let app = api::router::build_router(state);

    let delete_task = tokio::spawn({
        let app = app.clone();
        let token = token.clone();
        async move {
            app.oneshot(
                Request::builder()
                    .method("DELETE")
                    .uri("/account")
                    .header("authorization", format!("Bearer {token}"))
                    .header("content-type", "application/json")
                    .body(Body::from(
                        serde_json::json!({ "password": "realpassword" }).to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .expect("delete request should complete")
        }
    });

    // Bound the wait so a handler that 503s before reaching find_active_by_customer
    // surfaces as an assertion failure, not a hang (see corresponding guard in
    // delete_account_concurrent_ayb_create_keeps_customer_active for context).
    tokio::time::timeout(std::time::Duration::from_secs(30), delete_entered_rx)
        .await
        .expect("delete flow should reach find_active_by_customer within 30s")
        .expect("delete flow should hold lifecycle lock before soft-delete");

    let create_task = tokio::spawn({
        let app = app.clone();
        let token = token.clone();
        async move {
            app.oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/allyourbase/instances")
                    .header("authorization", format!("Bearer {token}"))
                    .header("content-type", "application/json")
                    .body(Body::from(
                        serde_json::json!({
                            "name": "Primary",
                            "slug": format!("acct-stale-{}", &Uuid::new_v4().to_string()[..8]),
                            "plan": "starter"
                        })
                        .to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .expect("create request should complete")
        }
    });

    tokio::task::yield_now().await;
    let _ = release_delete_tx.send(());

    let delete_resp = delete_task
        .await
        .expect("delete task should join without panicking");
    let create_resp = create_task
        .await
        .expect("create task should join without panicking");

    assert_eq!(delete_resp.status(), StatusCode::NO_CONTENT);
    assert_eq!(create_resp.status(), StatusCode::NOT_FOUND);

    let create_json = body_json(create_resp.into_body()).await;
    assert_eq!(create_json["error"], "customer not found");

    let persisted_customer = customer_repo
        .find_by_id(customer.id)
        .await
        .expect("mock repo lookup should succeed")
        .expect("customer row should still exist");
    assert_eq!(
        persisted_customer.status, "deleted",
        "delete-first ordering should soft-delete the customer"
    );

    let active_tenants = inner_ayb_repo
        .find_active_by_customer(customer.id)
        .await
        .expect("active tenant lookup should succeed");
    assert!(
        active_tenants.is_empty(),
        "stale-token create must not persist AYB tenants after delete succeeds"
    );
}

#[tokio::test]
async fn delete_account_soft_delete_retains_row_for_audit_visibility() {
    let delete_context = setup_deleted_account_context().await;

    let retained_customer = delete_context
        .repo
        .find_by_id(delete_context.customer_id)
        .await
        .expect("mock repo find_by_id should succeed")
        .expect("soft-deleted customer row should still exist");
    assert_eq!(retained_customer.status, "deleted");
    assert_eq!(retained_customer.email, delete_context.email);

    let customers_after_delete = delete_context
        .repo
        .list()
        .await
        .expect("mock repo list should succeed after soft-delete");
    assert_eq!(
        customers_after_delete.len(),
        delete_context.original_customer_count,
        "soft-delete must not create replacement rows"
    );
    let matching_email_customers: Vec<_> = customers_after_delete
        .iter()
        .filter(|candidate| candidate.email == delete_context.email)
        .collect();
    assert_eq!(
        matching_email_customers.len(),
        1,
        "soft-delete must preserve exactly one retained row for the original email"
    );
    assert_eq!(
        matching_email_customers[0].id, delete_context.customer_id,
        "retained row must keep the original customer ID"
    );
}

#[tokio::test]
async fn delete_account_login_after_delete_returns_generic_invalid_credentials_without_leaks() {
    let delete_context = setup_deleted_account_context().await;

    let resp = delete_context
        .app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/auth/login")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "email": delete_context.email,
                        "password": delete_context.password
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let login_after_delete_json = resp_json(resp).await;
    assert_eq!(
        login_after_delete_json,
        serde_json::json!({ "error": "invalid email or password" }),
        "deleted credentials must return the generic invalid-credentials error"
    );
    let login_after_delete_body = login_after_delete_json.to_string();
    assert!(
        !login_after_delete_body.contains("token"),
        "failed login body must not include token fields"
    );
    assert!(
        !login_after_delete_body.contains("customer"),
        "failed login body must not include customer fields"
    );
    assert!(
        !login_after_delete_body.contains(&delete_context.customer_id.to_string()),
        "failed login body must not include customer IDs"
    );
    assert!(
        !login_after_delete_body.contains(delete_context.email),
        "failed login body must not include submitted email addresses"
    );
    assert!(
        !login_after_delete_body.contains("password_hash"),
        "failed login body must not include password-hash fields"
    );
    assert!(
        !login_after_delete_body.contains("$argon2"),
        "failed login body must not include password-hash material"
    );
}

/// Wrong password on delete → 400.
#[tokio::test]
async fn delete_account_with_wrong_password_returns_400() {
    let repo = mock_repo();
    let hashed = hash_password("correctpassword");
    let customer = repo
        .create_with_password("User", "user@example.com", &hashed)
        .await
        .unwrap();
    let token = create_test_jwt(customer.id);
    let app = test_app(repo);

    let resp = app
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri("/account")
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({ "password": "wrongpassword" }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

/// OAuth account (no password_hash) trying to delete → 400.
#[tokio::test]
async fn delete_account_without_password_hash_returns_400() {
    let repo = mock_repo();
    // seed() creates a customer with no password_hash (simulates OAuth)
    let customer = repo.seed("OAuthUser", "oauth@example.com");
    let token = create_test_jwt(customer.id);
    let app = test_app(repo);

    let resp = app
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri("/account")
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({ "password": "anything" }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

/// Already-deleted customer → auth middleware returns 401 before handler runs.
#[tokio::test]
async fn delete_account_already_deleted_returns_401() {
    let repo = mock_repo();
    let customer = repo.seed_deleted("Gone", "gone@example.com");
    let token = create_test_jwt(customer.id);
    let app = test_app(repo);

    let resp = app
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri("/account")
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({ "password": "anything" }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

/// DELETE /account without auth → 401.
#[tokio::test]
async fn delete_account_without_auth_returns_401() {
    let app = test_app(mock_repo());

    let resp = app
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri("/account")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({ "password": "anything" }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

/// DELETE /account should reject passwords exceeding 128 chars (Argon2 DoS prevention).
#[tokio::test]
async fn delete_account_rejects_password_exceeding_max_length() {
    let repo = mock_repo();
    let hashed = hash_password("realpassword");
    let customer = repo
        .create_with_password("User", "user@example.com", &hashed)
        .await
        .unwrap();
    let token = create_test_jwt(customer.id);
    let app = test_app(repo);
    let long_password = "a".repeat(129);

    let resp = app
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri("/account")
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({ "password": long_password }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let json = body_json(resp.into_body()).await;
    assert!(
        json["error"].as_str().unwrap().contains("at most 128"),
        "expected length error, got: {:?}",
        json
    );
}

/// If soft-delete loses the row after auth succeeds, the handler should return 404.
#[tokio::test]
async fn delete_account_returns_404_when_soft_delete_reports_missing() {
    let repo = mock_repo();
    let hashed = hash_password("realpassword");
    let customer = repo
        .create_with_password("User", "user@example.com", &hashed)
        .await
        .unwrap();
    repo.fail_next_soft_delete();
    let token = create_test_jwt(customer.id);
    let app = test_app(repo);

    let resp = app
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri("/account")
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({ "password": "realpassword" }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

/// Update profile should reject names exceeding 128 chars.
#[tokio::test]
async fn update_profile_rejects_name_exceeding_max_length() {
    let repo = mock_repo();
    let hashed = hash_password("password123");
    let customer = repo
        .create_with_password("User", "user@example.com", &hashed)
        .await
        .unwrap();
    let app = test_app(repo);
    let token = create_test_jwt(customer.id);
    let long_name = "a".repeat(129);

    let resp = app
        .oneshot(
            Request::builder()
                .method("PATCH")
                .uri("/account")
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({ "name": long_name }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}
