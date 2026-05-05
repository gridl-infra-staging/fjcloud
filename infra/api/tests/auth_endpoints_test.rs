mod common;

use api::models::vm_inventory::NewVmInventory;
use api::repos::vm_inventory_repo::VmInventoryRepo;
use api::repos::CustomerRepo;
use api::router::build_router;
use api::services::email::{BroadcastDeliveryStatus, EmailError, EmailService, MockEmailService};
use api::services::flapjack_proxy::{
    FlapjackHttpClient, FlapjackHttpRequest, FlapjackHttpResponse, FlapjackProxy, ProxyError,
};
use api::services::provisioning::{ProvisioningService, DEFAULT_DNS_DOMAIN};
use async_trait::async_trait;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use tower::ServiceExt;

// ---------------------------------------------------------------------------
// Helper: extract JSON body
// ---------------------------------------------------------------------------

async fn body_json(resp: axum::response::Response) -> serde_json::Value {
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

fn json_post(uri: &str, body: serde_json::Value) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(uri)
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap()
}

fn json_post_bearer(uri: &str, bearer: &str, body: serde_json::Value) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(uri)
        .header("content-type", "application/json")
        .header("authorization", format!("Bearer {bearer}"))
        .body(Body::from(body.to_string()))
        .unwrap()
}

fn post_bearer_empty(uri: &str, bearer: &str) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(uri)
        .header("authorization", format!("Bearer {bearer}"))
        .body(Body::empty())
        .unwrap()
}

#[derive(Default)]
struct StaticSuccessFlapjackHttpClient;

#[async_trait]
impl FlapjackHttpClient for StaticSuccessFlapjackHttpClient {
    async fn send(
        &self,
        _request: FlapjackHttpRequest,
    ) -> Result<FlapjackHttpResponse, ProxyError> {
        Ok(FlapjackHttpResponse {
            status: 200,
            body: "{}".to_string(),
        })
    }
}

#[derive(Default)]
struct AlwaysFailEmailService;

#[async_trait]
impl EmailService for AlwaysFailEmailService {
    async fn send_verification_email(
        &self,
        _to: &str,
        _verify_token: &str,
    ) -> Result<(), EmailError> {
        Err(EmailError::DeliveryFailed(
            "forced test failure".to_string(),
        ))
    }

    async fn send_password_reset_email(
        &self,
        _to: &str,
        _reset_token: &str,
    ) -> Result<(), EmailError> {
        Err(EmailError::DeliveryFailed(
            "forced test failure".to_string(),
        ))
    }

    async fn send_invoice_ready_email(
        &self,
        _to: &str,
        _invoice_id: &str,
        _invoice_url: &str,
        _pdf_url: Option<&str>,
    ) -> Result<(), EmailError> {
        Err(EmailError::DeliveryFailed(
            "forced test failure".to_string(),
        ))
    }

    async fn send_quota_warning_email(
        &self,
        _to: &str,
        _metric: &str,
        _percent_used: f64,
        _current_usage: u64,
        _limit: u64,
    ) -> Result<(), EmailError> {
        Err(EmailError::DeliveryFailed(
            "forced test failure".to_string(),
        ))
    }

    async fn send_broadcast_email(
        &self,
        _to: &str,
        _subject: &str,
        _html_body: Option<&str>,
        _text_body: Option<&str>,
    ) -> Result<BroadcastDeliveryStatus, EmailError> {
        Err(EmailError::DeliveryFailed(
            "forced test failure".to_string(),
        ))
    }
}

#[derive(Default)]
struct FailSecondVerificationEmailService {
    verification_attempt_count: AtomicUsize,
}

#[async_trait]
impl EmailService for FailSecondVerificationEmailService {
    async fn send_verification_email(
        &self,
        _to: &str,
        _verify_token: &str,
    ) -> Result<(), EmailError> {
        let attempt = self
            .verification_attempt_count
            .fetch_add(1, Ordering::SeqCst)
            + 1;
        if attempt == 2 {
            return Err(EmailError::DeliveryFailed(
                "forced resend delivery failure".to_string(),
            ));
        }
        Ok(())
    }

    async fn send_password_reset_email(
        &self,
        _to: &str,
        _reset_token: &str,
    ) -> Result<(), EmailError> {
        Ok(())
    }

    async fn send_invoice_ready_email(
        &self,
        _to: &str,
        _invoice_id: &str,
        _invoice_url: &str,
        _pdf_url: Option<&str>,
    ) -> Result<(), EmailError> {
        Ok(())
    }

    async fn send_quota_warning_email(
        &self,
        _to: &str,
        _metric: &str,
        _percent_used: f64,
        _current_usage: u64,
        _limit: u64,
    ) -> Result<(), EmailError> {
        Ok(())
    }

    async fn send_broadcast_email(
        &self,
        _to: &str,
        _subject: &str,
        _html_body: Option<&str>,
        _text_body: Option<&str>,
    ) -> Result<BroadcastDeliveryStatus, EmailError> {
        Ok(BroadcastDeliveryStatus::Sent)
    }
}

async fn build_index_capable_auth_app(
    customer_repo: Arc<common::MockCustomerRepo>,
    email_service: Arc<dyn EmailService>,
) -> axum::Router {
    let deployment_repo = common::mock_deployment_repo();
    let tenant_repo = common::mock_tenant_repo();
    let vm_inventory_repo = common::mock_vm_inventory_repo();

    let vm = vm_inventory_repo
        .create(NewVmInventory {
            region: "us-east-1".to_string(),
            provider: "aws".to_string(),
            hostname: "vm-auth-test.flapjack.foo".to_string(),
            flapjack_url: "https://vm-auth-test.flapjack.foo".to_string(),
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

    // Set load so placement considers this VM (load_scraped_at must be fresh)
    vm_inventory_repo
        .update_load(vm.id, serde_json::json!({}))
        .await
        .unwrap();

    let node_secret_manager = Arc::new(api::secrets::mock::MockNodeSecretManager::new());
    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client(
        Arc::new(StaticSuccessFlapjackHttpClient),
        node_secret_manager.clone(),
    ));

    let provisioning_service = Arc::new(ProvisioningService::new(
        common::mock_vm_provisioner(),
        common::mock_dns_manager(),
        node_secret_manager,
        deployment_repo.clone(),
        customer_repo.clone(),
        DEFAULT_DNS_DOMAIN.to_string(),
    ));

    let mut state = common::test_state_with_indexes_and_vm_inventory(
        customer_repo,
        deployment_repo,
        tenant_repo,
        flapjack_proxy,
        vm_inventory_repo,
    );
    state.provisioning_service = provisioning_service;
    state.email_service = email_service;
    build_router(state)
}

// ===========================================================================
// POST /auth/register
// ===========================================================================

#[tokio::test]
async fn register_success_returns_201_with_jwt() {
    let app = common::test_app();

    let req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "Alice",
            "email": "alice@example.com",
            "password": "strongpassword123"
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);

    let json = body_json(resp).await;
    assert!(json["token"].as_str().is_some(), "should return JWT token");
    assert!(
        json["customer_id"].as_str().is_some(),
        "should return customer_id"
    );

    // Verify the JWT is valid by decoding it
    let token = json["token"].as_str().unwrap();
    let customer_id = json["customer_id"].as_str().unwrap();

    let token_data = jsonwebtoken::decode::<api::auth::Claims>(
        token,
        &jsonwebtoken::DecodingKey::from_secret(common::TEST_JWT_SECRET.as_bytes()),
        &jsonwebtoken::Validation::new(jsonwebtoken::Algorithm::HS256),
    )
    .expect("JWT should be valid");

    assert_eq!(token_data.claims.sub, customer_id);
}

#[tokio::test]
async fn new_customer_defaults_to_free_plan() {
    let repo = common::mock_repo();
    let app = common::test_app_with_repo(repo.clone());

    let req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "Alice",
            "email": "alice@example.com",
            "password": "strongpassword123"
        }),
    );
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);

    let customer = repo
        .find_by_email("alice@example.com")
        .await
        .unwrap()
        .expect("customer should exist after registration");
    assert_eq!(customer.billing_plan, "free");
}

#[tokio::test]
async fn register_duplicate_email_returns_409() {
    let repo = common::mock_repo();
    repo.seed("Existing User", "taken@example.com");
    let app = common::test_app_with_repo(repo);

    let req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "New User",
            "email": "taken@example.com",
            "password": "strongpassword123"
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::CONFLICT);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "email already registered");
}

#[tokio::test]
async fn register_short_password_returns_400() {
    let app = common::test_app();

    let req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "Alice",
            "email": "alice@example.com",
            "password": "short"
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "password must be at least 8 characters");
}

#[tokio::test]
async fn register_empty_name_returns_400() {
    let app = common::test_app();

    let req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "",
            "email": "alice@example.com",
            "password": "strongpassword123"
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn register_invalid_email_format_returns_400() {
    let app = common::test_app();

    let req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "Alice",
            "email": "notanemail",
            "password": "strongpassword123"
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "invalid email format");
}

#[tokio::test]
async fn register_empty_email_returns_400() {
    let app = common::test_app();

    let req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "Alice",
            "email": "",
            "password": "strongpassword123"
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn register_normalizes_email_to_lowercase() {
    let repo = common::mock_repo();

    // Register with mixed-case email
    let app = common::test_app_with_repo(repo.clone());
    let req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "Alice",
            "email": "Alice@Example.COM",
            "password": "strongpassword123"
        }),
    );
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);

    // Verify stored email is lowercase
    let customer = repo
        .find_by_email("alice@example.com")
        .await
        .unwrap()
        .expect("should find customer by lowercase email");
    assert_eq!(customer.email, "alice@example.com");

    // Re-register with same email (different case) should conflict
    let app2 = common::test_app_with_repo(repo);
    let req2 = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "Alice Again",
            "email": "alice@example.com",
            "password": "strongpassword123"
        }),
    );
    let resp2 = app2.oneshot(req2).await.unwrap();
    assert_eq!(resp2.status(), StatusCode::CONFLICT);
}

// ===========================================================================
// POST /auth/login
// ===========================================================================

#[tokio::test]
async fn login_success_returns_200_with_jwt() {
    let repo = common::mock_repo();

    // First register a user to get a password hash
    let app = common::test_app_with_repo(repo.clone());
    let reg_req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "Bob",
            "email": "bob@example.com",
            "password": "correcthorsebattery"
        }),
    );
    let reg_resp = app.oneshot(reg_req).await.unwrap();
    assert_eq!(reg_resp.status(), StatusCode::CREATED);
    let reg_json = body_json(reg_resp).await;
    let customer_id = reg_json["customer_id"].as_str().unwrap().to_string();

    // Now login
    let app2 = common::test_app_with_repo(repo);
    let login_req = json_post(
        "/auth/login",
        serde_json::json!({
            "email": "bob@example.com",
            "password": "correcthorsebattery"
        }),
    );
    let login_resp = app2.oneshot(login_req).await.unwrap();
    assert_eq!(login_resp.status(), StatusCode::OK);

    let json = body_json(login_resp).await;
    assert!(json["token"].as_str().is_some());
    assert_eq!(json["customer_id"].as_str().unwrap(), customer_id);
}

#[tokio::test]
async fn login_wrong_password_returns_400() {
    let repo = common::mock_repo();

    // Register first
    let app = common::test_app_with_repo(repo.clone());
    let reg_req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "Bob",
            "email": "bob@example.com",
            "password": "correcthorsebattery"
        }),
    );
    app.oneshot(reg_req).await.unwrap();

    // Login with wrong password
    let app2 = common::test_app_with_repo(repo);
    let req = json_post(
        "/auth/login",
        serde_json::json!({
            "email": "bob@example.com",
            "password": "wrongpassword"
        }),
    );

    let resp = app2.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "invalid email or password");
}

#[tokio::test]
async fn login_nonexistent_email_returns_400() {
    let app = common::test_app();

    let req = json_post(
        "/auth/login",
        serde_json::json!({
            "email": "nobody@example.com",
            "password": "somepassword123"
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "invalid email or password");
}

#[tokio::test]
async fn login_deleted_customer_returns_400() {
    let repo = common::mock_repo();
    repo.seed_deleted("Deleted", "deleted@example.com");
    let app = common::test_app_with_repo(repo);

    let req = json_post(
        "/auth/login",
        serde_json::json!({
            "email": "deleted@example.com",
            "password": "somepassword123"
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "invalid email or password");
}

#[tokio::test]
async fn login_no_password_hash_returns_400() {
    // Customer created via admin (no password) trying to login
    let repo = common::mock_repo();
    repo.seed("No Password", "nopass@example.com");
    let app = common::test_app_with_repo(repo);

    let req = json_post(
        "/auth/login",
        serde_json::json!({
            "email": "nopass@example.com",
            "password": "somepassword123"
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "invalid email or password");
}

// ===========================================================================
// POST /auth/verify-email
// ===========================================================================

#[tokio::test]
async fn unverified_customer_cannot_create_index() {
    let repo = common::mock_repo();
    let email_svc = Arc::new(MockEmailService::new());
    let app = build_index_capable_auth_app(repo, email_svc).await;

    let reg_req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "Unverified",
            "email": "unverified@example.com",
            "password": "strongpassword123"
        }),
    );
    let reg_resp = app.clone().oneshot(reg_req).await.unwrap();
    assert_eq!(reg_resp.status(), StatusCode::CREATED);
    let reg_json = body_json(reg_resp).await;
    let jwt = reg_json["token"].as_str().unwrap().to_string();

    let create_req = json_post_bearer(
        "/indexes",
        &jwt,
        serde_json::json!({
            "name": "blocked-index",
            "region": "us-east-1"
        }),
    );
    let create_resp = app.oneshot(create_req).await.unwrap();
    assert_eq!(create_resp.status(), StatusCode::FORBIDDEN);
    let create_json = body_json(create_resp).await;
    assert_eq!(create_json["error"], "email_not_verified");
}

#[tokio::test]
async fn verification_with_valid_token_marks_verified() {
    let repo = common::mock_repo();
    let email_svc = Arc::new(MockEmailService::new());
    let app = build_index_capable_auth_app(repo.clone(), email_svc).await;

    // Register user (which sets verify token)
    let reg_req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "Carol",
            "email": "carol@example.com",
            "password": "strongpassword123"
        }),
    );
    let reg_resp = app.clone().oneshot(reg_req).await.unwrap();
    assert_eq!(reg_resp.status(), StatusCode::CREATED);
    let reg_json = body_json(reg_resp).await;
    let jwt = reg_json["token"].as_str().unwrap().to_string();

    // Get the verify token from the repo
    let customer = repo
        .find_by_email("carol@example.com")
        .await
        .unwrap()
        .unwrap();
    let verify_token = customer.email_verify_token.unwrap();

    // Verify
    let req = json_post(
        "/auth/verify-email",
        serde_json::json!({ "token": verify_token }),
    );
    let resp = app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    assert_eq!(json["message"], "email verified");

    // Check the customer is now verified
    let updated = repo
        .find_by_email("carol@example.com")
        .await
        .unwrap()
        .unwrap();
    assert!(updated.email_verified_at.is_some());
    assert!(updated.email_verify_token.is_none());
    assert!(
        updated.stripe_customer_id.is_some(),
        "verify-email should trigger Stripe customer creation"
    );

    // Verified customer can now create an index
    let create_req = json_post_bearer(
        "/indexes",
        &jwt,
        serde_json::json!({
            "name": "my-index",
            "region": "us-east-1"
        }),
    );
    let create_resp = app.oneshot(create_req).await.unwrap();
    assert_eq!(create_resp.status(), StatusCode::CREATED);
}

#[tokio::test]
async fn verification_with_unknown_token_returns_400() {
    let app = common::test_app();

    let req = json_post(
        "/auth/verify-email",
        serde_json::json!({ "token": "nonexistent-token" }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "invalid or expired verification token");
}

#[tokio::test]
async fn verification_with_expired_token_returns_400() {
    let repo = common::mock_repo();

    // Create a customer manually and set an expired verify token
    let customer = repo.seed("Expired", "expired@example.com");
    let expired_time = chrono::Utc::now() - chrono::Duration::hours(1);
    repo.set_email_verify_token(customer.id, "expired-token", expired_time)
        .await
        .unwrap();

    let app = common::test_app_with_repo(repo);
    let req = json_post(
        "/auth/verify-email",
        serde_json::json!({ "token": "expired-token" }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "invalid or expired verification token");
}

#[tokio::test]
async fn verify_email_already_verified_returns_400() {
    let repo = common::mock_repo();

    // Register and verify
    let app = common::test_app_with_repo(repo.clone());
    let reg_req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "Carol",
            "email": "carol@example.com",
            "password": "strongpassword123"
        }),
    );
    app.oneshot(reg_req).await.unwrap();

    let customer = repo
        .find_by_email("carol@example.com")
        .await
        .unwrap()
        .unwrap();
    let verify_token = customer.email_verify_token.clone().unwrap();

    // Verify once
    let app2 = common::test_app_with_repo(repo.clone());
    let req = json_post(
        "/auth/verify-email",
        serde_json::json!({ "token": &verify_token }),
    );
    let resp = app2.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // Try to verify again with same token — token is now cleared, should fail
    let app3 = common::test_app_with_repo(repo);
    let req2 = json_post(
        "/auth/verify-email",
        serde_json::json!({ "token": &verify_token }),
    );
    let resp2 = app3.oneshot(req2).await.unwrap();
    assert_eq!(resp2.status(), StatusCode::BAD_REQUEST);
}

// ===========================================================================
// POST /auth/forgot-password
// ===========================================================================

#[tokio::test]
async fn forgot_password_sends_reset_email() {
    let repo = common::mock_repo();
    let email_svc = Arc::new(MockEmailService::new());

    // Register
    let app = common::test_app_with_repo(repo.clone());
    let reg_req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "Dave",
            "email": "dave@example.com",
            "password": "strongpassword123"
        }),
    );
    app.oneshot(reg_req).await.unwrap();

    // Forgot password
    let app2 = common::build_test_app_with_email(repo.clone(), email_svc.clone());
    let req = json_post(
        "/auth/forgot-password",
        serde_json::json!({ "email": "dave@example.com" }),
    );
    let resp = app2.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    assert_eq!(
        json["message"],
        "if an account exists with that email, a password reset link has been sent"
    );

    // Verify a reset token was set and included in email body.
    let customer = repo
        .find_by_email("dave@example.com")
        .await
        .unwrap()
        .unwrap();
    let reset_token = customer
        .password_reset_token
        .clone()
        .expect("should have set a reset token");
    assert!(
        customer.password_reset_expires_at.is_some(),
        "should have set a reset token expiry"
    );

    let sent_emails = email_svc.sent_emails();
    assert_eq!(sent_emails.len(), 1, "should send one reset email");
    assert_eq!(sent_emails[0].to, "dave@example.com");
    assert_eq!(sent_emails[0].subject, "Reset your password");
    assert!(
        sent_emails[0]
            .html_body
            .contains(&format!("reset-password/{reset_token}")),
        "reset email should include the exact reset token in the Svelte route path"
    );
    assert!(
        !sent_emails[0].html_body.contains("reset-password?token="),
        "reset email must not use the obsolete query-param route"
    );
    assert!(sent_emails[0]
        .text_body
        .contains(&format!("reset-password/{reset_token}")));
}

#[tokio::test]
async fn forgot_password_for_unknown_email_returns_200() {
    // Must not reveal whether email exists
    let repo = common::mock_repo();
    let email_svc = Arc::new(MockEmailService::new());
    let app = common::build_test_app_with_email(repo, email_svc.clone());

    let req = json_post(
        "/auth/forgot-password",
        serde_json::json!({ "email": "nobody@example.com" }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    assert_eq!(
        json["message"],
        "if an account exists with that email, a password reset link has been sent"
    );
    assert!(
        email_svc.sent_emails().is_empty(),
        "unknown email should not send any reset email"
    );
}

// ===========================================================================
// POST /auth/reset-password
// ===========================================================================

#[tokio::test]
async fn reset_password_with_valid_token_succeeds() {
    let repo = common::mock_repo();

    // Register
    let app = common::test_app_with_repo(repo.clone());
    let reg_req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "Eve",
            "email": "eve@example.com",
            "password": "oldpassword123"
        }),
    );
    app.oneshot(reg_req).await.unwrap();

    // Trigger forgot-password
    let app2 = common::test_app_with_repo(repo.clone());
    let forgot_req = json_post(
        "/auth/forgot-password",
        serde_json::json!({ "email": "eve@example.com" }),
    );
    app2.oneshot(forgot_req).await.unwrap();

    // Get the reset token
    let customer = repo
        .find_by_email("eve@example.com")
        .await
        .unwrap()
        .unwrap();
    let reset_token = customer.password_reset_token.unwrap();

    // Reset password
    let app3 = common::test_app_with_repo(repo.clone());
    let req = json_post(
        "/auth/reset-password",
        serde_json::json!({
            "token": reset_token,
            "new_password": "newpassword456"
        }),
    );
    let resp = app3.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    assert_eq!(json["message"], "password has been reset");

    // Verify can login with new password
    let app4 = common::test_app_with_repo(repo);
    let login_req = json_post(
        "/auth/login",
        serde_json::json!({
            "email": "eve@example.com",
            "password": "newpassword456"
        }),
    );
    let login_resp = app4.oneshot(login_req).await.unwrap();
    assert_eq!(login_resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn reset_password_invalid_token_returns_400() {
    let app = common::test_app();

    let req = json_post(
        "/auth/reset-password",
        serde_json::json!({
            "token": "bad-token",
            "new_password": "newpassword456"
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "invalid or expired reset token");
}

#[tokio::test]
async fn reset_password_with_expired_token_returns_400() {
    let repo = common::mock_repo();
    let customer = repo.seed("Test", "test@example.com");

    // Set an expired reset token
    let expired_time = chrono::Utc::now() - chrono::Duration::hours(1);
    repo.set_password_reset_token(customer.id, "expired-reset-token", expired_time)
        .await
        .unwrap();

    let app = common::test_app_with_repo(repo);
    let req = json_post(
        "/auth/reset-password",
        serde_json::json!({
            "token": "expired-reset-token",
            "new_password": "newpassword456"
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "invalid or expired reset token");
}

#[tokio::test]
async fn reset_password_short_password_returns_400() {
    let app = common::test_app();

    let req = json_post(
        "/auth/reset-password",
        serde_json::json!({
            "token": "some-token",
            "new_password": "short"
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "password must be at least 8 characters");
}

#[tokio::test]
async fn reset_password_token_consumed_after_use() {
    let repo = common::mock_repo();

    // Register
    let app = common::test_app_with_repo(repo.clone());
    let reg_req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "Frank",
            "email": "frank@example.com",
            "password": "oldpassword123"
        }),
    );
    app.oneshot(reg_req).await.unwrap();

    // Trigger forgot-password
    let app2 = common::test_app_with_repo(repo.clone());
    let forgot_req = json_post(
        "/auth/forgot-password",
        serde_json::json!({ "email": "frank@example.com" }),
    );
    app2.oneshot(forgot_req).await.unwrap();

    // Get the reset token
    let customer = repo
        .find_by_email("frank@example.com")
        .await
        .unwrap()
        .unwrap();
    let reset_token = customer.password_reset_token.unwrap();

    // Reset password once
    let app3 = common::test_app_with_repo(repo.clone());
    let req = json_post(
        "/auth/reset-password",
        serde_json::json!({
            "token": &reset_token,
            "new_password": "newpassword456"
        }),
    );
    let resp = app3.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // Try to use the same token again — should fail
    let app4 = common::test_app_with_repo(repo);
    let req2 = json_post(
        "/auth/reset-password",
        serde_json::json!({
            "token": &reset_token,
            "new_password": "anotherpassword789"
        }),
    );
    let resp2 = app4.oneshot(req2).await.unwrap();
    assert_eq!(resp2.status(), StatusCode::BAD_REQUEST);
}

// ===========================================================================
// Additional coverage: register edge cases
// ===========================================================================

#[tokio::test]
async fn register_trims_whitespace_from_name() {
    let repo = common::mock_repo();
    let app = common::test_app_with_repo(repo.clone());

    let req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "  Alice  ",
            "email": "alice@example.com",
            "password": "strongpassword123"
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);

    // Verify stored name is trimmed
    let customer = repo
        .find_by_email("alice@example.com")
        .await
        .unwrap()
        .expect("should find customer");
    assert_eq!(customer.name, "Alice");
}

#[tokio::test]
async fn register_sets_email_verify_token() {
    let repo = common::mock_repo();
    let app = common::test_app_with_repo(repo.clone());

    let req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "Alice",
            "email": "alice@example.com",
            "password": "strongpassword123"
        }),
    );
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);

    let customer = repo
        .find_by_email("alice@example.com")
        .await
        .unwrap()
        .expect("should find customer");

    assert!(
        customer.email_verify_token.is_some(),
        "registration should set an email verify token"
    );
    assert!(
        customer.email_verify_expires_at.is_some(),
        "registration should set verify token expiry"
    );
    assert!(
        customer.email_verified_at.is_none(),
        "new user should not be verified yet"
    );
}

#[tokio::test]
async fn register_password_hash_is_argon2() {
    let repo = common::mock_repo();
    let app = common::test_app_with_repo(repo.clone());

    let req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "Alice",
            "email": "alice@example.com",
            "password": "strongpassword123"
        }),
    );
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);

    let customer = repo
        .find_by_email("alice@example.com")
        .await
        .unwrap()
        .expect("should find customer");

    let hash = customer
        .password_hash
        .as_ref()
        .expect("should have password hash");
    assert!(
        hash.starts_with("$argon2"),
        "password hash should be argon2 format, got: {}",
        &hash[..hash.len().min(20)]
    );
}

// ===========================================================================
// Additional coverage: login edge cases
// ===========================================================================

#[tokio::test]
async fn login_normalizes_email_to_lowercase() {
    let repo = common::mock_repo();

    // Register with lowercase email
    let app = common::test_app_with_repo(repo.clone());
    let reg_req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "Bob",
            "email": "bob@example.com",
            "password": "correcthorsebattery"
        }),
    );
    app.oneshot(reg_req).await.unwrap();

    // Login with uppercase email
    let app2 = common::test_app_with_repo(repo);
    let login_req = json_post(
        "/auth/login",
        serde_json::json!({
            "email": "BOB@Example.COM",
            "password": "correcthorsebattery"
        }),
    );
    let login_resp = app2.oneshot(login_req).await.unwrap();
    assert_eq!(login_resp.status(), StatusCode::OK);

    let json = body_json(login_resp).await;
    assert!(json["token"].as_str().is_some());
}

// ===========================================================================
// Additional coverage: forgot-password edge cases
// ===========================================================================

#[tokio::test]
async fn forgot_password_deleted_customer_does_not_set_token() {
    let repo = common::mock_repo();
    let customer = repo.seed_deleted("Deleted", "deleted@example.com");
    let app = common::test_app_with_repo(repo.clone());

    let req = json_post(
        "/auth/forgot-password",
        serde_json::json!({ "email": "deleted@example.com" }),
    );
    let resp = app.oneshot(req).await.unwrap();
    // Always returns 200 to prevent email enumeration
    assert_eq!(resp.status(), StatusCode::OK);

    // But should NOT have set a reset token for the deleted customer
    let updated = repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .expect("should still find customer");
    assert!(
        updated.password_reset_token.is_none(),
        "deleted customer should not get a reset token"
    );
}

#[tokio::test]
async fn forgot_password_normalizes_email_to_lowercase() {
    let repo = common::mock_repo();

    // Register user
    let app = common::test_app_with_repo(repo.clone());
    let reg_req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "Dave",
            "email": "dave@example.com",
            "password": "strongpassword123"
        }),
    );
    app.oneshot(reg_req).await.unwrap();

    // Forgot password with uppercase email
    let app2 = common::test_app_with_repo(repo.clone());
    let req = json_post(
        "/auth/forgot-password",
        serde_json::json!({ "email": "DAVE@Example.COM" }),
    );
    let resp = app2.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // Verify a reset token was still set despite case difference
    let customer = repo
        .find_by_email("dave@example.com")
        .await
        .unwrap()
        .unwrap();
    assert!(
        customer.password_reset_token.is_some(),
        "should find customer and set reset token despite email case difference"
    );
}

// ===========================================================================
// Additional coverage: reset-password — old password invalidated
// ===========================================================================

#[tokio::test]
async fn reset_password_invalidates_old_password() {
    let repo = common::mock_repo();

    // Register
    let app = common::test_app_with_repo(repo.clone());
    let reg_req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "Grace",
            "email": "grace@example.com",
            "password": "oldpassword123"
        }),
    );
    app.oneshot(reg_req).await.unwrap();

    // Trigger forgot-password
    let app2 = common::test_app_with_repo(repo.clone());
    let forgot_req = json_post(
        "/auth/forgot-password",
        serde_json::json!({ "email": "grace@example.com" }),
    );
    app2.oneshot(forgot_req).await.unwrap();

    // Get the reset token
    let customer = repo
        .find_by_email("grace@example.com")
        .await
        .unwrap()
        .unwrap();
    let reset_token = customer.password_reset_token.unwrap();

    // Reset password
    let app3 = common::test_app_with_repo(repo.clone());
    let req = json_post(
        "/auth/reset-password",
        serde_json::json!({
            "token": reset_token,
            "new_password": "newpassword456"
        }),
    );
    let resp = app3.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // Attempt login with OLD password — should fail
    let app4 = common::test_app_with_repo(repo);
    let login_req = json_post(
        "/auth/login",
        serde_json::json!({
            "email": "grace@example.com",
            "password": "oldpassword123"
        }),
    );
    let login_resp = app4.oneshot(login_req).await.unwrap();
    assert_eq!(login_resp.status(), StatusCode::BAD_REQUEST);

    let json = body_json(login_resp).await;
    assert_eq!(json["error"], "invalid email or password");
}

// ===========================================================================
// Additional coverage: sensitive fields not leaked in JSON serialization
// ===========================================================================

#[tokio::test]
async fn customer_serialization_omits_sensitive_fields() {
    let now = chrono::Utc::now();
    let customer = api::models::Customer {
        id: uuid::Uuid::new_v4(),
        name: "Alice".to_string(),
        email: "alice@example.com".to_string(),
        stripe_customer_id: None,
        status: "active".to_string(),
        deleted_at: None,
        billing_plan: "free".to_string(),
        quota_warning_sent_at: None,
        created_at: now,
        updated_at: now,
        password_hash: Some("$argon2id$secret_hash".to_string()),
        email_verified_at: Some(now),
        email_verify_token: Some("verify-token-123".to_string()),
        email_verify_expires_at: Some(now),
        resend_verification_sent_at: None,
        password_reset_token: Some("reset-token-456".to_string()),
        password_reset_expires_at: Some(now),
        last_accessed_at: None,
        overdue_invoice_count: 0,
        object_storage_egress_carryforward_cents: rust_decimal::Decimal::new(37, 2),
    };

    let json = serde_json::to_value(&customer).unwrap();

    // These fields must NOT appear in serialized output
    assert!(
        json.get("password_hash").is_none(),
        "password_hash must not be serialized"
    );
    assert!(
        json.get("email_verify_token").is_none(),
        "email_verify_token must not be serialized"
    );
    assert!(
        json.get("email_verify_expires_at").is_none(),
        "email_verify_expires_at must not be serialized"
    );
    assert!(
        json.get("password_reset_token").is_none(),
        "password_reset_token must not be serialized"
    );
    assert!(
        json.get("password_reset_expires_at").is_none(),
        "password_reset_expires_at must not be serialized"
    );
    assert!(
        json.get("object_storage_egress_carryforward_cents")
            .is_none(),
        "carryforward_cents must not be serialized"
    );

    // These fields SHOULD appear
    assert!(json.get("id").is_some());
    assert!(json.get("name").is_some());
    assert!(json.get("email").is_some());
    assert!(json.get("email_verified_at").is_some());
}

// ===========================================================================
// Deleted-customer edge cases: verify-email and reset-password
// ===========================================================================

#[tokio::test]
async fn verify_email_deleted_customer_returns_400() {
    let repo = common::mock_repo();

    // Register a customer (sets verify token)
    let app = common::test_app_with_repo(repo.clone());
    let reg_req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "Helen",
            "email": "helen@example.com",
            "password": "strongpassword123"
        }),
    );
    app.oneshot(reg_req).await.unwrap();

    // Grab the verify token before deleting
    let customer = repo
        .find_by_email("helen@example.com")
        .await
        .unwrap()
        .unwrap();
    let verify_token = customer.email_verify_token.clone().unwrap();

    // Soft-delete the customer
    repo.soft_delete(customer.id).await.unwrap();

    // Attempt to verify — should fail because customer is deleted
    let app2 = common::test_app_with_repo(repo.clone());
    let req = json_post(
        "/auth/verify-email",
        serde_json::json!({ "token": verify_token }),
    );
    let resp = app2.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "invalid or expired verification token");
}

#[tokio::test]
async fn reset_password_deleted_customer_returns_400() {
    let repo = common::mock_repo();

    // Register
    let app = common::test_app_with_repo(repo.clone());
    let reg_req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "Ivan",
            "email": "ivan@example.com",
            "password": "strongpassword123"
        }),
    );
    app.oneshot(reg_req).await.unwrap();

    // Trigger forgot-password (sets reset token)
    let app2 = common::test_app_with_repo(repo.clone());
    let forgot_req = json_post(
        "/auth/forgot-password",
        serde_json::json!({ "email": "ivan@example.com" }),
    );
    app2.oneshot(forgot_req).await.unwrap();

    // Grab the reset token before deleting
    let customer = repo
        .find_by_email("ivan@example.com")
        .await
        .unwrap()
        .unwrap();
    let reset_token = customer.password_reset_token.clone().unwrap();

    // Soft-delete the customer
    repo.soft_delete(customer.id).await.unwrap();

    // Attempt to reset password — should fail because customer is deleted
    let app3 = common::test_app_with_repo(repo);
    let req = json_post(
        "/auth/reset-password",
        serde_json::json!({
            "token": reset_token,
            "new_password": "newpassword456"
        }),
    );
    let resp = app3.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "invalid or expired reset token");
}

// ===========================================================================
// Email validation edge cases
// ===========================================================================

#[tokio::test]
async fn register_rejects_domain_starting_with_dot() {
    let app = common::test_app();

    let req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "Test",
            "email": "user@.example.com",
            "password": "strongpassword123"
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "invalid email format");
}

#[tokio::test]
async fn register_rejects_domain_ending_with_dot() {
    let app = common::test_app();

    let req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "Test",
            "email": "user@example.com.",
            "password": "strongpassword123"
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "invalid email format");
}

// ---------------------------------------------------------------------------
// Input validation — max lengths (security hardening)
// ---------------------------------------------------------------------------

/// Argon2 processes the full password input. Without a max length cap, an attacker
/// can submit a multi-megabyte password to waste server CPU.
#[tokio::test]
async fn register_rejects_password_exceeding_max_length() {
    let app = common::test_app();
    let long_password = "a".repeat(129);

    let req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "Test",
            "email": "test@example.com",
            "password": long_password
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let json = body_json(resp).await;
    let err = json["error"].as_str().unwrap();
    assert!(
        err.contains("128"),
        "error should mention the max length limit"
    );
}

/// Password at exactly 128 chars should be accepted (boundary test).
#[tokio::test]
async fn register_accepts_password_at_max_length() {
    let app = common::test_app();
    let password = "a".repeat(128);

    let req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "Test",
            "email": "maxpw@example.com",
            "password": password
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
}

/// Names longer than 128 chars should be rejected.
#[tokio::test]
async fn register_rejects_name_exceeding_max_length() {
    let app = common::test_app();
    let long_name = "a".repeat(129);

    let req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": long_name,
            "email": "test@example.com",
            "password": "strongpassword123"
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

/// Emails longer than 254 chars should be rejected (RFC 5321 limit).
#[tokio::test]
async fn register_rejects_email_exceeding_max_length() {
    let app = common::test_app();
    // Build a valid-looking but too-long email
    let local_part = "a".repeat(245);
    let long_email = format!("{local_part}@example.com");
    assert!(long_email.len() > 254);

    let req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "Test",
            "email": long_email,
            "password": "strongpassword123"
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

/// Login should reject oversized passwords early (no valid hash can match >128 chars).
#[tokio::test]
async fn login_rejects_password_exceeding_max_length() {
    let app = common::test_app();
    let long_password = "a".repeat(129);

    let req = json_post(
        "/auth/login",
        serde_json::json!({
            "email": "test@example.com",
            "password": long_password
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn reset_password_rejects_password_exceeding_max_length() {
    let app = common::test_app();
    let long_password = "a".repeat(129);

    let req = json_post(
        "/auth/reset-password",
        serde_json::json!({
            "token": "some-reset-token",
            "new_password": long_password
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

// ===========================================================================
// Signup sends verification email (Task 3)
// ===========================================================================

#[tokio::test]
async fn signup_sends_verification_email() {
    let repo = common::mock_repo();
    let email_svc = Arc::new(MockEmailService::new());
    let app = common::build_test_app_with_email(repo.clone(), email_svc.clone());

    let req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "Alice",
            "email": "alice@example.com",
            "password": "strongpassword123"
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);

    let customer = repo
        .find_by_email("alice@example.com")
        .await
        .unwrap()
        .unwrap();
    let verify_token = customer.email_verify_token.unwrap();

    let emails = email_svc.sent_emails();
    assert_eq!(
        emails.len(),
        1,
        "should send exactly one verification email"
    );
    assert_eq!(emails[0].to, "alice@example.com");
    assert_eq!(emails[0].subject, "Verify your email");
    assert!(
        emails[0]
            .html_body
            .contains(&format!("verify-email/{verify_token}")),
        "email body should contain the stored verification token in the Svelte route path"
    );
    assert!(
        !emails[0].html_body.contains("verify-email?token="),
        "verification email must not use the obsolete query-param route"
    );
    assert!(emails[0]
        .text_body
        .contains(&format!("verify-email/{verify_token}")));
}

#[tokio::test]
async fn signup_creates_unverified_customer() {
    let repo = common::mock_repo();
    let app = common::test_app_with_repo(repo.clone());

    let req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "Bob",
            "email": "bob@example.com",
            "password": "strongpassword123"
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);

    let json = body_json(resp).await;
    let customer_id: uuid::Uuid = json["customer_id"].as_str().unwrap().parse().unwrap();

    let customer = repo.find_by_id(customer_id).await.unwrap().unwrap();
    assert!(
        customer.email_verified_at.is_none(),
        "newly registered customer should be unverified"
    );
    assert!(
        customer.email_verify_token.is_some(),
        "newly registered customer should have a verification token"
    );
    assert!(
        customer.stripe_customer_id.is_none(),
        "newly registered customer should not have stripe_customer_id before email verification"
    );
}

#[tokio::test]
async fn resend_verification_email_for_unverified_customer() {
    let repo = common::mock_repo();
    let email_svc = Arc::new(MockEmailService::new());
    let app = common::build_test_app_with_email(repo.clone(), email_svc.clone());

    let reg_req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "Retry",
            "email": "retry@example.com",
            "password": "strongpassword123"
        }),
    );
    let reg_resp = app.clone().oneshot(reg_req).await.unwrap();
    assert_eq!(reg_resp.status(), StatusCode::CREATED);
    let reg_json = body_json(reg_resp).await;
    let jwt = reg_json["token"].as_str().unwrap().to_string();

    let before = repo
        .find_by_email("retry@example.com")
        .await
        .unwrap()
        .unwrap();
    let original_token = before.email_verify_token.clone().unwrap();

    let resend_req = post_bearer_empty("/auth/resend-verification", &jwt);
    let resend_resp = app.clone().oneshot(resend_req).await.unwrap();
    assert_eq!(resend_resp.status(), StatusCode::OK);
    let resend_json = body_json(resend_resp).await;
    assert_eq!(resend_json["message"], "verification email sent");

    let after = repo
        .find_by_email("retry@example.com")
        .await
        .unwrap()
        .unwrap();
    assert!(after.email_verified_at.is_none());
    assert!(after.email_verify_token.is_some());
    assert_ne!(
        after.email_verify_token.as_deref(),
        Some(original_token.as_str()),
        "resend should rotate verification token"
    );

    let emails = email_svc.sent_emails();
    assert_eq!(emails.len(), 2, "signup + resend should emit two emails");
    assert_eq!(emails[1].to, "retry@example.com");
    assert_eq!(emails[1].subject, "Verify your email");
    let new_token = after.email_verify_token.unwrap();
    assert!(
        emails[1]
            .html_body
            .contains(&format!("verify-email/{new_token}")),
        "resend email should include the rotated token in the Svelte route path"
    );
    assert!(
        !emails[1].html_body.contains("verify-email?token="),
        "resend email must not use the obsolete query-param route"
    );
    assert!(
        !emails[1]
            .html_body
            .contains(&format!("verify-email/{original_token}")),
        "resend email must not include the old token"
    );
    assert!(emails[1]
        .text_body
        .contains(&format!("verify-email/{new_token}")));

    let second_resend_req = post_bearer_empty("/auth/resend-verification", &jwt);
    let second_resend_resp = app.oneshot(second_resend_req).await.unwrap();
    assert_eq!(second_resend_resp.status(), StatusCode::TOO_MANY_REQUESTS);
    let retry_after_header = second_resend_resp
        .headers()
        .get("retry-after")
        .and_then(|value| value.to_str().ok())
        .expect("429 response should include Retry-After header")
        .parse::<u64>()
        .expect("Retry-After header should be a positive integer");
    assert!(
        (1..=60).contains(&retry_after_header),
        "Retry-After should reflect the remaining cooldown window"
    );
    let second_resend_json = body_json(second_resend_resp).await;
    assert_eq!(
        second_resend_json["error"],
        "verification email recently sent; retry later"
    );

    let after_second_attempt = repo
        .find_by_email("retry@example.com")
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        after_second_attempt.email_verify_token.as_deref(),
        Some(new_token.as_str()),
        "cooldown response must keep the most recently issued token unchanged"
    );

    let emails = email_svc.sent_emails();
    assert_eq!(
        emails.len(),
        2,
        "cooldown-blocked resend must not emit another verification email"
    );
}

#[tokio::test]
async fn resend_verification_verified_account_returns_400() {
    let repo = common::mock_repo();
    let customer = repo.seed_verified_free_customer("Verified", "verified@example.com");
    let app = common::test_app_with_repo(repo);
    let jwt = common::create_test_jwt(customer.id);

    let resend_req = post_bearer_empty("/auth/resend-verification", &jwt);
    let resend_resp = app.oneshot(resend_req).await.unwrap();
    assert_eq!(resend_resp.status(), StatusCode::BAD_REQUEST);
    let resend_json = body_json(resend_resp).await;
    assert_eq!(resend_json["error"], "email already verified");
}

#[tokio::test]
async fn resend_verification_missing_auth_returns_401() {
    let app = common::test_app();
    let resend_req = Request::builder()
        .method("POST")
        .uri("/auth/resend-verification")
        .body(Body::empty())
        .unwrap();

    let resend_resp = app.oneshot(resend_req).await.unwrap();
    assert_eq!(resend_resp.status(), StatusCode::UNAUTHORIZED);
    let resend_json = body_json(resend_resp).await;
    assert_eq!(resend_json["error"], "missing authorization header");
}

#[tokio::test]
async fn resend_verification_invalid_auth_returns_401() {
    let repo = common::mock_repo();
    let customer = repo.seed("Invalid Auth", "invalidauth@example.com");
    let app = common::test_app_with_repo(repo);
    let jwt = common::create_jwt_with_secret(customer.id, "wrong-secret");

    let resend_req = post_bearer_empty("/auth/resend-verification", &jwt);
    let resend_resp = app.oneshot(resend_req).await.unwrap();
    assert_eq!(resend_resp.status(), StatusCode::UNAUTHORIZED);
    let resend_json = body_json(resend_resp).await;
    assert_eq!(resend_json["error"], "invalid or expired token");
}

#[tokio::test]
async fn resend_verification_suspended_account_returns_403() {
    let repo = common::mock_repo();
    let customer = repo.seed("Suspended", "suspended@example.com");
    repo.suspend(customer.id)
        .await
        .expect("suspend fixture customer");
    let app = common::test_app_with_repo(repo);
    let jwt = common::create_test_jwt(customer.id);

    let resend_req = post_bearer_empty("/auth/resend-verification", &jwt);
    let resend_resp = app.oneshot(resend_req).await.unwrap();
    assert_eq!(resend_resp.status(), StatusCode::FORBIDDEN);
    let resend_json = body_json(resend_resp).await;
    assert_eq!(resend_json["error"], "forbidden");
}

#[tokio::test]
async fn resend_verification_returns_503_when_email_delivery_fails() {
    let repo = common::mock_repo();
    let app = common::build_test_app_with_email(repo, Arc::new(AlwaysFailEmailService));

    let reg_req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "RetryFail",
            "email": "retryfail@example.com",
            "password": "strongpassword123"
        }),
    );
    let reg_resp = app.clone().oneshot(reg_req).await.unwrap();
    assert_eq!(reg_resp.status(), StatusCode::CREATED);
    let reg_json = body_json(reg_resp).await;
    let jwt = reg_json["token"].as_str().unwrap().to_string();

    let resend_req = post_bearer_empty("/auth/resend-verification", &jwt);
    let resend_resp = app.oneshot(resend_req).await.unwrap();
    assert_eq!(resend_resp.status(), StatusCode::SERVICE_UNAVAILABLE);
    let resend_json = body_json(resend_resp).await;
    assert_eq!(
        resend_json["error"],
        "verification email temporarily unavailable"
    );
}

#[tokio::test]
async fn resend_verification_503_keeps_last_deliverable_token_and_allows_immediate_retry() {
    let repo = common::mock_repo();
    let app = common::build_test_app_with_email(
        repo.clone(),
        Arc::new(FailSecondVerificationEmailService::default()),
    );

    let reg_req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "RetryRecover",
            "email": "retryrecover@example.com",
            "password": "strongpassword123"
        }),
    );
    let reg_resp = app.clone().oneshot(reg_req).await.unwrap();
    assert_eq!(reg_resp.status(), StatusCode::CREATED);
    let reg_json = body_json(reg_resp).await;
    let jwt = reg_json["token"].as_str().unwrap().to_string();

    let before_failed_resend = repo
        .find_by_email("retryrecover@example.com")
        .await
        .unwrap()
        .unwrap();
    let last_deliverable_token = before_failed_resend
        .email_verify_token
        .clone()
        .expect("signup should set a verification token");
    assert!(
        before_failed_resend.resend_verification_sent_at.is_none(),
        "signup should not pre-fill resend cooldown"
    );

    let failed_resend_req = post_bearer_empty("/auth/resend-verification", &jwt);
    let failed_resend_resp = app.clone().oneshot(failed_resend_req).await.unwrap();
    assert_eq!(failed_resend_resp.status(), StatusCode::SERVICE_UNAVAILABLE);

    let after_failed_resend = repo
        .find_by_email("retryrecover@example.com")
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        after_failed_resend.email_verify_token.as_deref(),
        Some(last_deliverable_token.as_str()),
        "503 resend must preserve the last deliverable token"
    );
    assert!(
        after_failed_resend.resend_verification_sent_at.is_none(),
        "503 resend must not consume resend cooldown"
    );

    let recovered_resend_req = post_bearer_empty("/auth/resend-verification", &jwt);
    let recovered_resend_resp = app.clone().oneshot(recovered_resend_req).await.unwrap();
    assert_eq!(recovered_resend_resp.status(), StatusCode::OK);

    let after_recovery = repo
        .find_by_email("retryrecover@example.com")
        .await
        .unwrap()
        .unwrap();
    assert_ne!(
        after_recovery.email_verify_token.as_deref(),
        Some(last_deliverable_token.as_str()),
        "successful retry should rotate token after delivery recovers"
    );
    assert!(
        after_recovery.resend_verification_sent_at.is_some(),
        "successful resend should start cooldown"
    );
}

#[tokio::test]
async fn resend_verification_rollback_failure_returns_500_instead_of_retryable_503() {
    let repo = common::mock_repo();
    let app = common::build_test_app_with_email(
        repo.clone(),
        Arc::new(FailSecondVerificationEmailService::default()),
    );

    let reg_req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "RollbackFailure",
            "email": "rollbackfailure@example.com",
            "password": "strongpassword123"
        }),
    );
    let reg_resp = app.clone().oneshot(reg_req).await.unwrap();
    assert_eq!(reg_resp.status(), StatusCode::CREATED);
    let reg_json = body_json(reg_resp).await;
    let jwt = reg_json["token"].as_str().unwrap().to_string();

    repo.fail_next_resend_rollback_with_false();

    let resend_req = post_bearer_empty("/auth/resend-verification", &jwt);
    let resend_resp = app.oneshot(resend_req).await.unwrap();
    assert_eq!(resend_resp.status(), StatusCode::INTERNAL_SERVER_ERROR);

    let resend_json = body_json(resend_resp).await;
    assert_eq!(resend_json["error"], "internal server error");
}

#[tokio::test]
async fn resend_verification_rollback_error_returns_500_instead_of_retryable_503() {
    let repo = common::mock_repo();
    let app = common::build_test_app_with_email(
        repo.clone(),
        Arc::new(FailSecondVerificationEmailService::default()),
    );

    let reg_req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "RollbackError",
            "email": "rollbackerror@example.com",
            "password": "strongpassword123"
        }),
    );
    let reg_resp = app.clone().oneshot(reg_req).await.unwrap();
    assert_eq!(reg_resp.status(), StatusCode::CREATED);
    let reg_json = body_json(reg_resp).await;
    let jwt = reg_json["token"].as_str().unwrap().to_string();

    repo.fail_next_resend_rollback_with_error("injected rollback error");

    let resend_req = post_bearer_empty("/auth/resend-verification", &jwt);
    let resend_resp = app.oneshot(resend_req).await.unwrap();
    assert_eq!(resend_resp.status(), StatusCode::INTERNAL_SERVER_ERROR);

    let resend_json = body_json(resend_resp).await;
    assert_eq!(resend_json["error"], "internal server error");
}

// ===========================================================================
// Email delivery failure — best-effort tests
// ===========================================================================

#[tokio::test]
async fn register_returns_201_when_email_delivery_fails() {
    let repo = common::mock_repo();
    let app = common::build_test_app_with_email(repo.clone(), Arc::new(AlwaysFailEmailService));

    let req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "EmailFail",
            "email": "emailfail@example.com",
            "password": "strongpassword123"
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::CREATED,
        "registration must succeed even when verification email delivery fails"
    );

    let json = body_json(resp).await;
    assert!(
        json["customer_id"].as_str().is_some(),
        "response should contain customer_id"
    );

    let customer = repo
        .find_by_email("emailfail@example.com")
        .await
        .unwrap()
        .expect("customer should exist despite email failure");
    assert!(
        customer.email_verify_token.is_some(),
        "verify token should be set even if email delivery failed"
    );
}

#[tokio::test]
async fn forgot_password_returns_200_when_email_delivery_fails() {
    let repo = common::mock_repo();

    // First register a customer (with working email service)
    let reg_app = common::test_app_with_repo(repo.clone());
    let reg_req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "ResetFail",
            "email": "resetfail@example.com",
            "password": "strongpassword123"
        }),
    );
    reg_app.oneshot(reg_req).await.unwrap();

    // Now try forgot-password with failing email service
    let app = common::build_test_app_with_email(repo.clone(), Arc::new(AlwaysFailEmailService));
    let req = json_post(
        "/auth/forgot-password",
        serde_json::json!({ "email": "resetfail@example.com" }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::OK,
        "forgot-password must return 200 even when email delivery fails"
    );

    let json = body_json(resp).await;
    assert_eq!(
        json["message"],
        "if an account exists with that email, a password reset link has been sent"
    );

    let customer = repo
        .find_by_email("resetfail@example.com")
        .await
        .unwrap()
        .unwrap();
    assert!(
        customer.password_reset_token.is_some(),
        "reset token should be set even if email delivery failed"
    );
}
