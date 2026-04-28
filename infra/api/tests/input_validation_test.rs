mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use rust_decimal_macros::dec;
use std::sync::Arc;
use tower::ServiceExt;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn json_post(uri: &str, body: serde_json::Value) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(uri)
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap()
}

fn authed_json_post(uri: &str, body: serde_json::Value, token: &str) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(uri)
        .header("content-type", "application/json")
        .header("authorization", format!("Bearer {token}"))
        .body(Body::from(body.to_string()))
        .unwrap()
}

fn authed_json_patch(uri: &str, body: serde_json::Value, token: &str) -> Request<Body> {
    Request::builder()
        .method("PATCH")
        .uri(uri)
        .header("content-type", "application/json")
        .header("authorization", format!("Bearer {token}"))
        .body(Body::from(body.to_string()))
        .unwrap()
}

fn admin_json_post(uri: &str, body: serde_json::Value) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(uri)
        .header("content-type", "application/json")
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::from(body.to_string()))
        .unwrap()
}

fn admin_json_put(uri: &str, body: serde_json::Value) -> Request<Body> {
    Request::builder()
        .method("PUT")
        .uri(uri)
        .header("content-type", "application/json")
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::from(body.to_string()))
        .unwrap()
}

async fn error_message(resp: axum::response::Response) -> String {
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let body: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    body["error"].as_str().unwrap_or_default().to_string()
}

fn sample_rate_card() -> api::models::RateCardRow {
    api::models::RateCardRow {
        id: uuid::Uuid::new_v4(),
        name: "launch-2026".to_string(),
        effective_from: chrono::Utc::now(),
        effective_until: None,
        storage_rate_per_mb_month: dec!(0.200000),
        region_multipliers: serde_json::json!({"eu-west-1": "1.3"}),
        minimum_spend_cents: 500,
        shared_minimum_spend_cents: 200,
        cold_storage_rate_per_gb_month: dec!(0.020000),
        object_storage_rate_per_gb_month: dec!(0.024000),
        object_storage_egress_rate_per_gb: dec!(0.010000),
        created_at: chrono::Utc::now(),
    }
}

// ===========================================================================
// POST /auth/register — password max length, name max length, email max length
// ===========================================================================

#[tokio::test]
async fn register_rejects_password_over_128_chars() {
    let app = common::test_app();
    let long_password = "a".repeat(129);

    let req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "Alice",
            "email": "alice@example.com",
            "password": long_password
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn register_rejects_name_over_128_chars() {
    let app = common::test_app();
    let long_name = "a".repeat(129);

    let req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": long_name,
            "email": "alice@example.com",
            "password": "strongpassword123"
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn register_rejects_email_over_254_chars() {
    let app = common::test_app();
    // 250 chars + @example.com = well over 254
    let long_email = format!("{}@example.com", "a".repeat(250));

    let req = json_post(
        "/auth/register",
        serde_json::json!({
            "name": "Alice",
            "email": long_email,
            "password": "strongpassword123"
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

// ===========================================================================
// POST /auth/reset-password — password max length
// ===========================================================================

#[tokio::test]
async fn reset_password_rejects_password_over_128_chars() {
    let repo = Arc::new(common::MockCustomerRepo::new());
    let customer = repo.seed("Alice", "alice@example.com");
    let reset_token = "deadbeef".repeat(8);
    use api::repos::CustomerRepo;
    repo.set_password_reset_token(
        customer.id,
        &reset_token,
        chrono::Utc::now() + chrono::Duration::hours(1),
    )
    .await
    .unwrap();
    let app = common::test_app_with_repo(repo);
    let long_password = "a".repeat(129);

    let req = json_post(
        "/auth/reset-password",
        serde_json::json!({
            "token": reset_token,
            "new_password": long_password
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    assert!(error_message(resp).await.contains("at most 128"));
}

// ===========================================================================
// PATCH /account — name max length
// ===========================================================================

#[tokio::test]
async fn update_profile_rejects_name_over_128_chars() {
    let repo = Arc::new(common::MockCustomerRepo::new());
    let customer = repo.seed("Alice", "alice@example.com");
    let token = common::create_test_jwt(customer.id);
    let app = common::test_app_with_repo(repo);

    let long_name = "a".repeat(129);
    let req = authed_json_patch("/account", serde_json::json!({ "name": long_name }), &token);

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

// ===========================================================================
// POST /account/change-password — password max length
// ===========================================================================

#[tokio::test]
async fn change_password_rejects_new_password_over_128_chars() {
    let repo = Arc::new(common::MockCustomerRepo::new());
    use api::password::hash_password;
    use api::repos::CustomerRepo;
    let customer = repo
        .create_with_password(
            "Alice",
            "alice@example.com",
            &hash_password("strongpassword123").unwrap(),
        )
        .await
        .unwrap();
    let token = common::create_test_jwt(customer.id);
    let app = common::test_app_with_repo(repo);

    let long_password = "a".repeat(129);
    let req = authed_json_post(
        "/account/change-password",
        serde_json::json!({
            "current_password": "strongpassword123",
            "new_password": long_password
        }),
        &token,
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    assert!(error_message(resp).await.contains("at most 128"));
}

// ===========================================================================
// POST /api-keys — name max length, empty name, empty scopes, too many scopes
// ===========================================================================

#[tokio::test]
async fn create_api_key_rejects_name_over_128_chars() {
    let repo = Arc::new(common::MockCustomerRepo::new());
    let customer = repo.seed("Alice", "alice@example.com");
    let token = common::create_test_jwt(customer.id);
    let app = common::test_app_with_repo(repo);

    let long_name = "a".repeat(129);
    let req = authed_json_post(
        "/api-keys",
        serde_json::json!({
            "name": long_name,
            "scopes": ["read"]
        }),
        &token,
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn create_api_key_rejects_empty_name() {
    let repo = Arc::new(common::MockCustomerRepo::new());
    let customer = repo.seed("Alice", "alice@example.com");
    let token = common::create_test_jwt(customer.id);
    let app = common::test_app_with_repo(repo);

    let req = authed_json_post(
        "/api-keys",
        serde_json::json!({
            "name": "",
            "scopes": ["read"]
        }),
        &token,
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn create_api_key_rejects_empty_scopes() {
    let repo = Arc::new(common::MockCustomerRepo::new());
    let customer = repo.seed("Alice", "alice@example.com");
    let token = common::create_test_jwt(customer.id);
    let app = common::test_app_with_repo(repo);

    let req = authed_json_post(
        "/api-keys",
        serde_json::json!({
            "name": "my-key",
            "scopes": []
        }),
        &token,
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn create_api_key_rejects_too_many_scopes() {
    let repo = Arc::new(common::MockCustomerRepo::new());
    let customer = repo.seed("Alice", "alice@example.com");
    let token = common::create_test_jwt(customer.id);
    let app = common::test_app_with_repo(repo);

    let scopes: Vec<String> = (0..21).map(|i| format!("scope_{i}")).collect();
    let req = authed_json_post(
        "/api-keys",
        serde_json::json!({
            "name": "my-key",
            "scopes": scopes
        }),
        &token,
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

// ===========================================================================
// POST /admin/tenants — email validation, name max length, empty name
// ===========================================================================

#[tokio::test]
async fn admin_broadcast_requires_html_or_text_body() {
    let app = common::test_app();

    let req = admin_json_post(
        "/admin/broadcast",
        serde_json::json!({
            "subject": "maintenance-notice",
            "dry_run": true
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let msg = error_message(resp).await;
    assert!(
        msg.contains("requires html_body or text_body"),
        "expected body validation error, got: {msg}"
    );
}

#[tokio::test]
async fn admin_create_tenant_rejects_invalid_email() {
    let app = common::test_app();

    let req = admin_json_post(
        "/admin/tenants",
        serde_json::json!({
            "name": "Acme Corp",
            "email": "not-an-email"
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn admin_create_tenant_rejects_name_over_128_chars() {
    let app = common::test_app();
    let long_name = "a".repeat(129);

    let req = admin_json_post(
        "/admin/tenants",
        serde_json::json!({
            "name": long_name,
            "email": "acme@example.com"
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn admin_create_tenant_rejects_empty_name() {
    let app = common::test_app();

    let req = admin_json_post(
        "/admin/tenants",
        serde_json::json!({
            "name": "",
            "email": "acme@example.com"
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn admin_update_tenant_rejects_name_over_128_chars() {
    let repo = Arc::new(common::MockCustomerRepo::new());
    let customer = repo.seed("OldName", "old@example.com");
    let app = common::test_app_with_repo(repo);

    let long_name = "a".repeat(129);
    let req = admin_json_put(
        &format!("/admin/tenants/{}", customer.id),
        serde_json::json!({ "name": long_name }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn admin_update_tenant_rejects_invalid_email() {
    let repo = Arc::new(common::MockCustomerRepo::new());
    let customer = repo.seed("Acme", "old@example.com");
    let app = common::test_app_with_repo(repo);

    let req = admin_json_put(
        &format!("/admin/tenants/{}", customer.id),
        serde_json::json!({ "email": "invalid-email" }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

// ===========================================================================
// PUT /admin/tenants/:id/rate-card — negative decimals, negative spend
// ===========================================================================

#[tokio::test]
async fn rate_override_rejects_negative_decimal() {
    let customer_repo = Arc::new(common::MockCustomerRepo::new());
    let rate_card_repo = Arc::new(common::MockRateCardRepo::new());
    let customer = customer_repo.seed("Acme", "acme@example.com");

    rate_card_repo.seed_active_card(sample_rate_card());

    let app = common::test_app_full(
        customer_repo,
        Arc::new(common::MockDeploymentRepo::new()),
        Arc::new(common::MockUsageRepo::new()),
        rate_card_repo,
    );

    let req = admin_json_put(
        &format!("/admin/tenants/{}/rate-card", customer.id),
        serde_json::json!({
            "storage_rate_per_mb_month": "-0.50"
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn rate_override_rejects_negative_minimum_spend() {
    let customer_repo = Arc::new(common::MockCustomerRepo::new());
    let rate_card_repo = Arc::new(common::MockRateCardRepo::new());
    let customer = customer_repo.seed("Acme", "acme@example.com");

    rate_card_repo.seed_active_card(sample_rate_card());

    let app = common::test_app_full(
        customer_repo,
        Arc::new(common::MockDeploymentRepo::new()),
        Arc::new(common::MockUsageRepo::new()),
        rate_card_repo,
    );

    let req = admin_json_put(
        &format!("/admin/tenants/{}/rate-card", customer.id),
        serde_json::json!({
            "minimum_spend_cents": -100
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn rate_override_rejects_negative_shared_minimum_spend() {
    let customer_repo = Arc::new(common::MockCustomerRepo::new());
    let rate_card_repo = Arc::new(common::MockRateCardRepo::new());
    let customer = customer_repo.seed("Acme", "acme@example.com");

    rate_card_repo.seed_active_card(sample_rate_card());

    let app = common::test_app_full(
        customer_repo,
        Arc::new(common::MockDeploymentRepo::new()),
        Arc::new(common::MockUsageRepo::new()),
        rate_card_repo,
    );

    let req = admin_json_put(
        &format!("/admin/tenants/{}/rate-card", customer.id),
        serde_json::json!({
            "shared_minimum_spend_cents": -100
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn rate_override_rejects_invalid_region_multipliers() {
    let customer_repo = Arc::new(common::MockCustomerRepo::new());
    let rate_card_repo = Arc::new(common::MockRateCardRepo::new());
    let customer = customer_repo.seed("Acme", "acme@example.com");

    rate_card_repo.seed_active_card(sample_rate_card());

    let app = common::test_app_full(
        customer_repo,
        Arc::new(common::MockDeploymentRepo::new()),
        Arc::new(common::MockUsageRepo::new()),
        rate_card_repo,
    );

    let req = admin_json_put(
        &format!("/admin/tenants/{}/rate-card", customer.id),
        serde_json::json!({
            "region_multipliers": ["eu-west-1"]
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn rate_override_rejects_negative_region_multipliers() {
    let customer_repo = Arc::new(common::MockCustomerRepo::new());
    let rate_card_repo = Arc::new(common::MockRateCardRepo::new());
    let customer = customer_repo.seed("Acme", "acme@example.com");

    rate_card_repo.seed_active_card(sample_rate_card());

    let app = common::test_app_full(
        customer_repo,
        Arc::new(common::MockDeploymentRepo::new()),
        Arc::new(common::MockUsageRepo::new()),
        rate_card_repo,
    );

    let req = admin_json_put(
        &format!("/admin/tenants/{}/rate-card", customer.id),
        serde_json::json!({
            "region_multipliers": { "eu-west-1": "-0.5" }
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

// ===========================================================================
// POST /indexes/:name/keys — description max length, ACL array limit
// POST /indexes/:name/search — query max length
// ===========================================================================

#[tokio::test]
async fn create_index_key_rejects_description_over_1000_chars() {
    let customer_repo = Arc::new(common::MockCustomerRepo::new());
    let deployment_repo = Arc::new(common::MockDeploymentRepo::new());
    let tenant_repo = Arc::new(common::MockTenantRepo::new());
    let customer = customer_repo.seed("Alice", "alice@example.com");
    let token = common::create_test_jwt(customer.id);

    // Seed a running deployment
    let deployment = deployment_repo.seed_provisioned(
        customer.id,
        "node-a1",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("http://127.0.0.1:9999"),
    );

    // Register deployment in tenant_repo so find_by_name works
    tenant_repo.seed_deployment(
        deployment.id,
        "us-east-1",
        Some("http://127.0.0.1:9999"),
        "healthy",
        "running",
    );

    // Create the index in the tenant repo (via trait method)
    use api::repos::tenant_repo::TenantRepo;
    tenant_repo
        .create(customer.id, "my-index", deployment.id)
        .await
        .unwrap();

    let app = common::test_app_with_indexes(
        customer_repo,
        deployment_repo,
        tenant_repo,
        common::mock_flapjack_proxy(),
    );

    let long_description = "a".repeat(1001);
    let req = authed_json_post(
        "/indexes/my-index/keys",
        serde_json::json!({
            "description": long_description,
            "acl": ["search"]
        }),
        &token,
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn create_index_key_rejects_empty_description() {
    let customer_repo = Arc::new(common::MockCustomerRepo::new());
    let deployment_repo = Arc::new(common::MockDeploymentRepo::new());
    let tenant_repo = Arc::new(common::MockTenantRepo::new());
    let customer = customer_repo.seed("Alice", "alice@example.com");
    let token = common::create_test_jwt(customer.id);

    let deployment = deployment_repo.seed_provisioned(
        customer.id,
        "node-a1",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("http://127.0.0.1:9999"),
    );
    tenant_repo.seed_deployment(
        deployment.id,
        "us-east-1",
        Some("http://127.0.0.1:9999"),
        "healthy",
        "running",
    );
    use api::repos::tenant_repo::TenantRepo;
    tenant_repo
        .create(customer.id, "my-index", deployment.id)
        .await
        .unwrap();

    let app = common::test_app_with_indexes(
        customer_repo,
        deployment_repo,
        tenant_repo,
        common::mock_flapjack_proxy(),
    );

    let req = authed_json_post(
        "/indexes/my-index/keys",
        serde_json::json!({
            "description": "",
            "acl": ["search"]
        }),
        &token,
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let msg = error_message(resp).await;
    assert!(
        msg.contains("description must not be empty"),
        "expected 'description must not be empty', got: {msg}"
    );
}

#[tokio::test]
async fn create_index_key_rejects_whitespace_only_description() {
    let customer_repo = Arc::new(common::MockCustomerRepo::new());
    let deployment_repo = Arc::new(common::MockDeploymentRepo::new());
    let tenant_repo = Arc::new(common::MockTenantRepo::new());
    let customer = customer_repo.seed("Alice", "alice@example.com");
    let token = common::create_test_jwt(customer.id);

    let deployment = deployment_repo.seed_provisioned(
        customer.id,
        "node-a1",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("http://127.0.0.1:9999"),
    );
    tenant_repo.seed_deployment(
        deployment.id,
        "us-east-1",
        Some("http://127.0.0.1:9999"),
        "healthy",
        "running",
    );
    use api::repos::tenant_repo::TenantRepo;
    tenant_repo
        .create(customer.id, "my-index", deployment.id)
        .await
        .unwrap();

    let app = common::test_app_with_indexes(
        customer_repo,
        deployment_repo,
        tenant_repo,
        common::mock_flapjack_proxy(),
    );

    let req = authed_json_post(
        "/indexes/my-index/keys",
        serde_json::json!({
            "description": "   ",
            "acl": ["search"]
        }),
        &token,
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let msg = error_message(resp).await;
    assert!(
        msg.contains("description must not be empty"),
        "expected 'description must not be empty', got: {msg}"
    );
}

#[tokio::test]
async fn create_index_key_rejects_too_many_acls() {
    let customer_repo = Arc::new(common::MockCustomerRepo::new());
    let deployment_repo = Arc::new(common::MockDeploymentRepo::new());
    let tenant_repo = Arc::new(common::MockTenantRepo::new());
    let customer = customer_repo.seed("Alice", "alice@example.com");
    let token = common::create_test_jwt(customer.id);

    let deployment = deployment_repo.seed_provisioned(
        customer.id,
        "node-a1",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("http://127.0.0.1:9999"),
    );
    tenant_repo.seed_deployment(
        deployment.id,
        "us-east-1",
        Some("http://127.0.0.1:9999"),
        "healthy",
        "running",
    );
    use api::repos::tenant_repo::TenantRepo;
    tenant_repo
        .create(customer.id, "my-index", deployment.id)
        .await
        .unwrap();

    let app = common::test_app_with_indexes(
        customer_repo,
        deployment_repo,
        tenant_repo,
        common::mock_flapjack_proxy(),
    );

    // 11 ACLs exceeds limit of 10
    let acls: Vec<&str> = (0..11).map(|_| "search").collect();
    let req = authed_json_post(
        "/indexes/my-index/keys",
        serde_json::json!({
            "description": "test",
            "acl": acls
        }),
        &token,
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn test_search_rejects_query_over_1000_chars() {
    let customer_repo = Arc::new(common::MockCustomerRepo::new());
    let deployment_repo = Arc::new(common::MockDeploymentRepo::new());
    let tenant_repo = Arc::new(common::MockTenantRepo::new());
    let customer = customer_repo.seed("Alice", "alice@example.com");
    let token = common::create_test_jwt(customer.id);

    let deployment = deployment_repo.seed_provisioned(
        customer.id,
        "node-a1",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("http://127.0.0.1:9999"),
    );
    tenant_repo.seed_deployment(
        deployment.id,
        "us-east-1",
        Some("http://127.0.0.1:9999"),
        "healthy",
        "running",
    );
    use api::repos::tenant_repo::TenantRepo;
    tenant_repo
        .create(customer.id, "my-index", deployment.id)
        .await
        .unwrap();

    let app = common::test_app_with_indexes(
        customer_repo,
        deployment_repo,
        tenant_repo,
        common::mock_flapjack_proxy(),
    );

    let long_query = "a".repeat(1001);
    let req = authed_json_post(
        "/indexes/my-index/search",
        serde_json::json!({ "query": long_query }),
        &token,
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

// ===========================================================================
// POST /api-keys — management scope validation
// ===========================================================================

#[tokio::test]
async fn create_api_key_rejects_invalid_scope() {
    let customer_repo = Arc::new(common::MockCustomerRepo::new());
    let customer = customer_repo.seed("User", "user@example.com");
    let token = common::create_test_jwt(customer.id);
    let api_key_repo = common::mock_api_key_repo();
    let mut state = common::test_state_with_repo(customer_repo);
    state.api_key_repo = api_key_repo;
    let app = api::router::build_router(state);

    let req = authed_json_post(
        "/api-keys",
        serde_json::json!({
            "name": "Bad Scope Key",
            "scopes": ["search", "typo_scope"]
        }),
        &token,
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::BAD_REQUEST,
        "invalid scope should be rejected at creation"
    );
    let msg = error_message(resp).await;
    assert!(
        msg.contains("typo_scope"),
        "error message should mention the invalid scope, got: {msg}"
    );
}

#[tokio::test]
async fn create_api_key_accepts_valid_scopes() {
    let customer_repo = Arc::new(common::MockCustomerRepo::new());
    let customer = customer_repo.seed("User", "user@example.com");
    let token = common::create_test_jwt(customer.id);
    let api_key_repo = common::mock_api_key_repo();
    let mut state = common::test_state_with_repo(customer_repo);
    state.api_key_repo = api_key_repo;
    let app = api::router::build_router(state);

    let req = authed_json_post(
        "/api-keys",
        serde_json::json!({
            "name": "Good Key",
            "scopes": ["search", "indexes:read", "billing:read"]
        }),
        &token,
    );

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
}
