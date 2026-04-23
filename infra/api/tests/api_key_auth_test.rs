mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use axum::routing::get;
use axum::Router;
use http_body_util::BodyExt;
use sha2::{Digest, Sha256};
use std::sync::Arc;
use tower::ServiceExt;

use api::auth::api_key::ApiKeyAuth;
use api::errors::ApiError;

const TEST_KEY: &str = "fj_live_0123456789abcdef0123456789abcdef";
const TEST_KEY_PREFIX: &str = "fj_live_01234567";

fn hash_key(key: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(key.as_bytes());
    hex::encode(hasher.finalize())
}

async fn test_handler(auth: ApiKeyAuth) -> String {
    serde_json::json!({
        "customer_id": auth.customer_id,
        "key_id": auth.key_id,
        "scopes": auth.scopes,
    })
    .to_string()
}

async fn scoped_handler(auth: ApiKeyAuth) -> Result<String, ApiError> {
    auth.require_scope("read")?;
    Ok(format!("ok: {}", auth.customer_id))
}

fn build_test_app(
    customer_repo: Arc<common::MockCustomerRepo>,
    api_key_repo: Arc<common::MockApiKeyRepo>,
) -> Router {
    let state = common::test_state_with_api_key_repo(customer_repo, api_key_repo);
    Router::new()
        .route("/test", get(test_handler))
        .route("/scoped", get(scoped_handler))
        .with_state(state)
}

async fn body_json(resp: axum::response::Response) -> serde_json::Value {
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

// ---- Tests (RED phase — these should fail until ApiKeyAuth is implemented) ----

#[tokio::test]
async fn valid_key_authenticates() {
    let customer_repo = common::mock_repo();
    let api_key_repo = common::mock_api_key_repo();

    let customer = customer_repo.seed("Acme Corp", "acme@example.com");
    let key_hash = hash_key(TEST_KEY);
    let seeded = api_key_repo.seed(
        customer.id,
        "prod-key",
        &key_hash,
        TEST_KEY_PREFIX,
        vec!["read".into(), "write".into()],
    );

    let app = build_test_app(customer_repo, api_key_repo);

    let resp = app
        .oneshot(
            Request::get("/test")
                .header("authorization", format!("Bearer {TEST_KEY}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["customer_id"], customer.id.to_string());
    assert_eq!(body["key_id"], seeded.id.to_string());
    assert_eq!(body["scopes"], serde_json::json!(["read", "write"]));
}

#[tokio::test]
async fn missing_auth_header_returns_401() {
    let app = build_test_app(common::mock_repo(), common::mock_api_key_repo());

    let resp = app
        .oneshot(Request::get("/test").body(Body::empty()).unwrap())
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn invalid_key_returns_401() {
    let app = build_test_app(common::mock_repo(), common::mock_api_key_repo());

    let resp = app
        .oneshot(
            Request::get("/test")
                .header(
                    "authorization",
                    "Bearer fj_live_ffffffffffffffffffffffffffffffff",
                )
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn revoked_key_returns_401() {
    let customer_repo = common::mock_repo();
    let api_key_repo = common::mock_api_key_repo();

    let customer = customer_repo.seed("Acme Corp", "acme@example.com");
    let key_hash = hash_key(TEST_KEY);
    let seeded = api_key_repo.seed(
        customer.id,
        "prod-key",
        &key_hash,
        TEST_KEY_PREFIX,
        vec!["read".into()],
    );

    // Revoke the key
    use api::repos::api_key_repo::ApiKeyRepo;
    api_key_repo.revoke(seeded.id).await.unwrap();

    let app = build_test_app(customer_repo, api_key_repo);

    let resp = app
        .oneshot(
            Request::get("/test")
                .header("authorization", format!("Bearer {TEST_KEY}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn wrong_hash_returns_401() {
    let customer_repo = common::mock_repo();
    let api_key_repo = common::mock_api_key_repo();

    let customer = customer_repo.seed("Acme Corp", "acme@example.com");
    // Seed with a DIFFERENT hash than what TEST_KEY produces
    api_key_repo.seed(
        customer.id,
        "prod-key",
        "badhash_not_a_real_sha256_value_at_all_aaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        TEST_KEY_PREFIX,
        vec!["read".into()],
    );

    let app = build_test_app(customer_repo, api_key_repo);

    let resp = app
        .oneshot(
            Request::get("/test")
                .header("authorization", format!("Bearer {TEST_KEY}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn suspended_customer_returns_403() {
    let customer_repo = common::mock_repo();
    let api_key_repo = common::mock_api_key_repo();

    let customer = customer_repo.seed("Acme Corp", "acme@example.com");
    let key_hash = hash_key(TEST_KEY);
    api_key_repo.seed(
        customer.id,
        "prod-key",
        &key_hash,
        TEST_KEY_PREFIX,
        vec!["read".into()],
    );

    // Suspend the customer
    use api::repos::CustomerRepo;
    customer_repo.suspend(customer.id).await.unwrap();

    let app = build_test_app(customer_repo, api_key_repo);

    let resp = app
        .oneshot(
            Request::get("/test")
                .header("authorization", format!("Bearer {TEST_KEY}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn scope_check_passes() {
    let customer_repo = common::mock_repo();
    let api_key_repo = common::mock_api_key_repo();

    let customer = customer_repo.seed("Acme Corp", "acme@example.com");
    let key_hash = hash_key(TEST_KEY);
    api_key_repo.seed(
        customer.id,
        "prod-key",
        &key_hash,
        TEST_KEY_PREFIX,
        vec!["read".into(), "write".into()],
    );

    let app = build_test_app(customer_repo, api_key_repo);

    // The /scoped endpoint requires "read" scope — this key has it
    let resp = app
        .oneshot(
            Request::get("/scoped")
                .header("authorization", format!("Bearer {TEST_KEY}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn scope_check_fails_returns_403() {
    let customer_repo = common::mock_repo();
    let api_key_repo = common::mock_api_key_repo();

    let customer = customer_repo.seed("Acme Corp", "acme@example.com");
    let key_hash = hash_key(TEST_KEY);
    // Key only has "write" scope, not "read"
    api_key_repo.seed(
        customer.id,
        "prod-key",
        &key_hash,
        TEST_KEY_PREFIX,
        vec!["write".into()],
    );

    let app = build_test_app(customer_repo, api_key_repo);

    // The /scoped endpoint requires "read" scope — this key doesn't have it
    let resp = app
        .oneshot(
            Request::get("/scoped")
                .header("authorization", format!("Bearer {TEST_KEY}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn last_used_at_updated() {
    let customer_repo = common::mock_repo();
    let api_key_repo = common::mock_api_key_repo();

    let customer = customer_repo.seed("Acme Corp", "acme@example.com");
    let key_hash = hash_key(TEST_KEY);
    let seeded = api_key_repo.seed(
        customer.id,
        "prod-key",
        &key_hash,
        TEST_KEY_PREFIX,
        vec!["read".into()],
    );

    // Verify initially null
    assert!(seeded.last_used_at.is_none());

    let app = build_test_app(customer_repo, api_key_repo.clone());

    let resp = app
        .oneshot(
            Request::get("/test")
                .header("authorization", format!("Bearer {TEST_KEY}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);

    // Give the fire-and-forget task a moment to complete
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;

    // Check that last_used_at was updated
    use api::repos::api_key_repo::ApiKeyRepo;
    let updated = api_key_repo.find_by_id(seeded.id).await.unwrap().unwrap();
    assert!(updated.last_used_at.is_some());
}

#[tokio::test]
async fn deleted_customer_returns_401() {
    let customer_repo = common::mock_repo();
    let api_key_repo = common::mock_api_key_repo();

    let customer = customer_repo.seed_deleted("Gone Corp", "gone@example.com");
    let key_hash = hash_key(TEST_KEY);
    api_key_repo.seed(
        customer.id,
        "prod-key",
        &key_hash,
        TEST_KEY_PREFIX,
        vec!["read".into()],
    );

    let app = build_test_app(customer_repo, api_key_repo);

    let resp = app
        .oneshot(
            Request::get("/test")
                .header("authorization", format!("Bearer {TEST_KEY}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn non_fj_live_prefix_returns_401() {
    let app = build_test_app(common::mock_repo(), common::mock_api_key_repo());

    let resp = app
        .oneshot(
            Request::get("/test")
                .header("authorization", "Bearer sk_test_1234567890abcdef")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

// --- gridl_live_ dual-accept tests ---

const GRIDL_KEY: &str = "gridl_live_0123456789abcdef0123456789abcdef";
const GRIDL_KEY_PREFIX: &str = "gridl_live_01234";

#[tokio::test]
async fn gridl_live_key_authenticates() {
    let customer_repo = common::mock_repo();
    let api_key_repo = common::mock_api_key_repo();

    let customer = customer_repo.seed("Flapjack Cloud Corp", "customer@example.com");
    let key_hash = hash_key(GRIDL_KEY);
    let seeded = api_key_repo.seed(
        customer.id,
        "gridl-key",
        &key_hash,
        GRIDL_KEY_PREFIX,
        vec!["read".into(), "search".into()],
    );

    let app = build_test_app(customer_repo, api_key_repo);

    let resp = app
        .oneshot(
            Request::get("/test")
                .header("authorization", format!("Bearer {GRIDL_KEY}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["customer_id"], customer.id.to_string());
    assert_eq!(body["key_id"], seeded.id.to_string());
}

#[tokio::test]
async fn legacy_fj_live_key_still_authenticates() {
    // Existing fj_live_ keys must continue to work during transition
    let customer_repo = common::mock_repo();
    let api_key_repo = common::mock_api_key_repo();

    let customer = customer_repo.seed("Legacy Corp", "legacy@example.com");
    let key_hash = hash_key(TEST_KEY);
    api_key_repo.seed(
        customer.id,
        "legacy-key",
        &key_hash,
        TEST_KEY_PREFIX,
        vec!["read".into()],
    );

    let app = build_test_app(customer_repo, api_key_repo);

    let resp = app
        .oneshot(
            Request::get("/test")
                .header("authorization", format!("Bearer {TEST_KEY}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn unrecognized_prefix_returns_401() {
    let app = build_test_app(common::mock_repo(), common::mock_api_key_repo());

    let resp = app
        .oneshot(
            Request::get("/test")
                .header(
                    "authorization",
                    "Bearer unknown_live_0123456789abcdef0123456789abcdef",
                )
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn short_key_returns_401() {
    let app = build_test_app(common::mock_repo(), common::mock_api_key_repo());

    // Key starts with fj_live_ but is too short for prefix extraction
    let resp = app
        .oneshot(
            Request::get("/test")
                .header("authorization", "Bearer fj_live_short")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}
