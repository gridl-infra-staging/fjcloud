mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use axum::routing::get;
use axum::Router;
use http_body_util::BodyExt;
use tower::ServiceExt;
use uuid::Uuid;

use api::auth::{AdminAuth, AuthenticatedTenant};
use api::repos::CustomerRepo;

// ---------------------------------------------------------------------------
// Test-only handlers (never in production code)
// ---------------------------------------------------------------------------

async fn me(tenant: AuthenticatedTenant) -> String {
    tenant.customer_id.to_string()
}

async fn admin_ok(_: AdminAuth) -> &'static str {
    "admin"
}

// ---------------------------------------------------------------------------
// Helper: build a test router with the given routes
// ---------------------------------------------------------------------------

fn tenant_router() -> Router {
    tenant_router_with_repo(common::mock_repo())
}

fn tenant_router_with_repo(repo: std::sync::Arc<common::MockCustomerRepo>) -> Router {
    let state = common::test_state_with_repo(repo);
    Router::new().route("/me", get(me)).with_state(state)
}

fn admin_router() -> Router {
    let state = common::test_state();
    Router::new()
        .route("/admin-check", get(admin_ok))
        .with_state(state)
}

// ---------------------------------------------------------------------------
// Helper: extract JSON body
// ---------------------------------------------------------------------------

async fn body_json(resp: axum::response::Response) -> serde_json::Value {
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

// ===========================================================================
// Tenant JWT extractor tests
// ===========================================================================

#[tokio::test]
async fn tenant_valid_jwt_returns_customer_id() {
    let repo = common::mock_repo();
    let customer = repo.seed("Acme", "acme@example.com");
    let token = common::create_test_jwt(customer.id);

    let req = Request::builder()
        .uri("/me")
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();

    let resp = tenant_router_with_repo(repo).oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let body_str = String::from_utf8(body.to_vec()).unwrap();
    assert_eq!(body_str, customer.id.to_string());
}

#[tokio::test]
async fn tenant_missing_auth_header_returns_401() {
    let req = Request::builder().uri("/me").body(Body::empty()).unwrap();

    let resp = tenant_router().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "missing authorization header");
}

#[tokio::test]
async fn tenant_non_bearer_scheme_returns_401() {
    let req = Request::builder()
        .uri("/me")
        .header("authorization", "Basic dXNlcjpwYXNz")
        .body(Body::empty())
        .unwrap();

    let resp = tenant_router().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "missing authorization header");
}

#[tokio::test]
async fn tenant_malformed_token_returns_401() {
    let req = Request::builder()
        .uri("/me")
        .header("authorization", "Bearer not-a-real-jwt")
        .body(Body::empty())
        .unwrap();

    let resp = tenant_router().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "invalid or expired token");
}

#[tokio::test]
async fn tenant_expired_token_returns_401() {
    let customer_id = Uuid::new_v4();
    let token = common::create_expired_jwt(customer_id);

    let req = Request::builder()
        .uri("/me")
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();

    let resp = tenant_router().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "invalid or expired token");
}

#[tokio::test]
async fn tenant_wrong_secret_returns_401() {
    let customer_id = Uuid::new_v4();
    let token = common::create_jwt_with_secret(customer_id, "wrong-secret");

    let req = Request::builder()
        .uri("/me")
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();

    let resp = tenant_router().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "invalid or expired token");
}

#[tokio::test]
async fn tenant_non_uuid_sub_returns_401() {
    // Create a JWT with a non-UUID sub claim
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as usize;

    let claims = api::auth::Claims {
        sub: "not-a-uuid".to_string(),
        exp: now + 3600,
        iat: now,
    };

    let token = jsonwebtoken::encode(
        &jsonwebtoken::Header::default(),
        &claims,
        &jsonwebtoken::EncodingKey::from_secret(common::TEST_JWT_SECRET.as_bytes()),
    )
    .unwrap();

    let req = Request::builder()
        .uri("/me")
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();

    let resp = tenant_router().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "invalid or expired token");
}

#[tokio::test]
async fn tenant_suspended_customer_returns_403() {
    let repo = common::mock_repo();
    let customer = repo.seed("Suspended", "suspended@example.com");
    repo.suspend(customer.id).await.unwrap();
    let token = common::create_test_jwt(customer.id);

    let req = Request::builder()
        .uri("/me")
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();

    let resp = tenant_router_with_repo(repo).oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "forbidden");
}

#[tokio::test]
async fn tenant_deleted_customer_returns_401() {
    let repo = common::mock_repo();
    let customer = repo.seed_deleted("Deleted", "deleted@example.com");
    let token = common::create_test_jwt(customer.id);

    let req = Request::builder()
        .uri("/me")
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();

    let resp = tenant_router_with_repo(repo).oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "invalid or expired token");
}

#[tokio::test]
async fn tenant_unknown_customer_returns_401() {
    // JWT with a valid UUID that has no matching customer in the repo
    let token = common::create_test_jwt(Uuid::new_v4());

    let req = Request::builder()
        .uri("/me")
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();

    let resp = tenant_router().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "invalid or expired token");
}

// ===========================================================================
// Admin API key extractor tests
// ===========================================================================

#[tokio::test]
async fn admin_valid_key_returns_200() {
    let req = Request::builder()
        .uri("/admin-check")
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = admin_router().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn admin_missing_key_returns_401() {
    let req = Request::builder()
        .uri("/admin-check")
        .body(Body::empty())
        .unwrap();

    let resp = admin_router().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "missing admin key");
}

#[tokio::test]
async fn admin_wrong_key_returns_401() {
    let req = Request::builder()
        .uri("/admin-check")
        .header("x-admin-key", "wrong-key")
        .body(Body::empty())
        .unwrap();

    let resp = admin_router().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "invalid admin key");
}

// ===========================================================================
// Token issuance endpoint tests (POST /admin/tokens)
// ===========================================================================

#[tokio::test]
async fn token_issue_valid_request_returns_200() {
    let app = common::test_app();
    let customer_id = Uuid::new_v4();

    let req = Request::builder()
        .method("POST")
        .uri("/admin/tokens")
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({"customer_id": customer_id}).to_string(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    let token = json["token"].as_str().expect("response should have token");
    let expires_at_str = json["expires_at"]
        .as_str()
        .expect("response should have expires_at string");

    // Verify expires_at is a valid ISO 8601 / RFC 3339 timestamp
    chrono::DateTime::parse_from_rfc3339(expires_at_str)
        .expect("expires_at should be valid RFC 3339");

    // Decode the returned token and verify claims
    let token_data = jsonwebtoken::decode::<api::auth::Claims>(
        token,
        &jsonwebtoken::DecodingKey::from_secret(common::TEST_JWT_SECRET.as_bytes()),
        &jsonwebtoken::Validation::default(),
    )
    .expect("returned token should be valid");

    assert_eq!(token_data.claims.sub, customer_id.to_string());

    // Default expiry should be 86400 seconds (24 hours)
    let duration = token_data.claims.exp - token_data.claims.iat;
    assert!(
        (86398..=86402).contains(&duration),
        "expected ~86400s default duration, got {duration}"
    );
}

#[tokio::test]
async fn token_issue_custom_expiry() {
    let app = common::test_app();
    let customer_id = Uuid::new_v4();

    let req = Request::builder()
        .method("POST")
        .uri("/admin/tokens")
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({"customer_id": customer_id, "expires_in_secs": 7200}).to_string(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    let token = json["token"].as_str().unwrap();

    let token_data = jsonwebtoken::decode::<api::auth::Claims>(
        token,
        &jsonwebtoken::DecodingKey::from_secret(common::TEST_JWT_SECRET.as_bytes()),
        &jsonwebtoken::Validation::default(),
    )
    .unwrap();

    let duration = token_data.claims.exp - token_data.claims.iat;
    // Within ±2 seconds tolerance
    assert!(
        (7198..=7202).contains(&duration),
        "expected ~7200s duration, got {duration}"
    );
}

#[tokio::test]
async fn token_issue_missing_admin_key_returns_401() {
    let app = common::test_app();
    let customer_id = Uuid::new_v4();

    let req = Request::builder()
        .method("POST")
        .uri("/admin/tokens")
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({"customer_id": customer_id}).to_string(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn token_issue_invalid_json_syntax_returns_400() {
    let app = common::test_app();

    let req = Request::builder()
        .method("POST")
        .uri("/admin/tokens")
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from("not valid json"))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    // axum 0.7 returns 400 Bad Request for JSON syntax errors
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn token_issue_wrong_schema_returns_422() {
    let app = common::test_app();

    let req = Request::builder()
        .method("POST")
        .uri("/admin/tokens")
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({"wrong_field": "value"}).to_string(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    // axum 0.7 returns 422 Unprocessable Entity for valid JSON with wrong schema
    assert_eq!(resp.status(), StatusCode::UNPROCESSABLE_ENTITY);
}

// ===========================================================================
// CORS preflight test
// ===========================================================================

#[tokio::test]
async fn cors_preflight_returns_allow_origin() {
    let app = common::test_app();

    let req = Request::builder()
        .method("OPTIONS")
        .uri("/health")
        .header("origin", "http://localhost:5173")
        .header("access-control-request-method", "GET")
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let allow_origin = resp
        .headers()
        .get("access-control-allow-origin")
        .expect("should have access-control-allow-origin header");
    assert_eq!(allow_origin, "http://localhost:5173");
}
