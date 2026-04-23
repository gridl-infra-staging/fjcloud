mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use tower::ServiceExt;

// ---------------------------------------------------------------------------
// tenant-map
// ---------------------------------------------------------------------------

#[tokio::test]
async fn tenant_map_requires_internal_key() {
    let app = common::test_app();

    let req = Request::builder()
        .uri("/internal/tenant-map")
        .body(Body::empty())
        .expect("request should build");

    let resp = app.oneshot(req).await.expect("request should succeed");

    assert_eq!(
        resp.status(),
        StatusCode::UNAUTHORIZED,
        "GET /internal/tenant-map without x-internal-key should return 401"
    );
}

#[tokio::test]
async fn tenant_map_rejects_when_internal_auth_not_configured() {
    let mut state = common::test_state();
    state.internal_auth_token = None;
    let app = api::router::build_router(state);

    let req = Request::builder()
        .uri("/internal/tenant-map")
        .header("x-internal-key", common::TEST_INTERNAL_AUTH_TOKEN)
        .body(Body::empty())
        .expect("request should build");

    let resp = app.oneshot(req).await.expect("request should succeed");

    assert_eq!(
        resp.status(),
        StatusCode::UNAUTHORIZED,
        "GET /internal/tenant-map should return 401 when INTERNAL_AUTH_TOKEN is unset"
    );
}

#[tokio::test]
async fn tenant_map_rejects_wrong_key() {
    let app = common::test_app();

    let req = Request::builder()
        .uri("/internal/tenant-map")
        .header("x-internal-key", "wrong-key")
        .body(Body::empty())
        .expect("request should build");

    let resp = app.oneshot(req).await.expect("request should succeed");

    assert_eq!(
        resp.status(),
        StatusCode::UNAUTHORIZED,
        "GET /internal/tenant-map with wrong key should return 401"
    );
}

#[tokio::test]
async fn tenant_map_accepts_valid_key() {
    let app = common::test_app();

    let req = Request::builder()
        .uri("/internal/tenant-map")
        .header("x-internal-key", common::TEST_INTERNAL_AUTH_TOKEN)
        .body(Body::empty())
        .expect("request should build");

    let resp = app.oneshot(req).await.expect("request should succeed");

    assert_eq!(
        resp.status(),
        StatusCode::OK,
        "GET /internal/tenant-map with valid key should return 200"
    );
}

// ---------------------------------------------------------------------------
// cold-storage-usage
// ---------------------------------------------------------------------------

#[tokio::test]
async fn cold_storage_usage_requires_internal_key() {
    let app = common::test_app();

    let req = Request::builder()
        .uri("/internal/cold-storage-usage")
        .body(Body::empty())
        .expect("request should build");

    let resp = app.oneshot(req).await.expect("request should succeed");

    assert_eq!(
        resp.status(),
        StatusCode::UNAUTHORIZED,
        "GET /internal/cold-storage-usage without x-internal-key should return 401"
    );
}

#[tokio::test]
async fn cold_storage_usage_rejects_wrong_key() {
    let app = common::test_app();

    let req = Request::builder()
        .uri("/internal/cold-storage-usage")
        .header("x-internal-key", "wrong-key")
        .body(Body::empty())
        .expect("request should build");

    let resp = app.oneshot(req).await.expect("request should succeed");

    assert_eq!(
        resp.status(),
        StatusCode::UNAUTHORIZED,
        "GET /internal/cold-storage-usage with wrong key should return 401"
    );
}

#[tokio::test]
async fn cold_storage_usage_accepts_valid_key() {
    let app = common::test_app();

    let req = Request::builder()
        .uri("/internal/cold-storage-usage")
        .header("x-internal-key", common::TEST_INTERNAL_AUTH_TOKEN)
        .body(Body::empty())
        .expect("request should build");

    let resp = app.oneshot(req).await.expect("request should succeed");

    assert_eq!(
        resp.status(),
        StatusCode::OK,
        "GET /internal/cold-storage-usage with valid key should return 200"
    );
}

// ---------------------------------------------------------------------------
// regions
// ---------------------------------------------------------------------------

#[tokio::test]
async fn regions_requires_internal_key() {
    let app = common::test_app();

    let req = Request::builder()
        .uri("/internal/regions")
        .body(Body::empty())
        .expect("request should build");

    let resp = app.oneshot(req).await.expect("request should succeed");

    assert_eq!(
        resp.status(),
        StatusCode::UNAUTHORIZED,
        "GET /internal/regions without x-internal-key should return 401"
    );
}

#[tokio::test]
async fn regions_rejects_wrong_key() {
    let app = common::test_app();

    let req = Request::builder()
        .uri("/internal/regions")
        .header("x-internal-key", "wrong-key")
        .body(Body::empty())
        .expect("request should build");

    let resp = app.oneshot(req).await.expect("request should succeed");

    assert_eq!(
        resp.status(),
        StatusCode::UNAUTHORIZED,
        "GET /internal/regions with wrong key should return 401"
    );
}

#[tokio::test]
async fn regions_accepts_valid_key() {
    let app = common::test_app();

    let req = Request::builder()
        .uri("/internal/regions")
        .header("x-internal-key", common::TEST_INTERNAL_AUTH_TOKEN)
        .body(Body::empty())
        .expect("request should build");

    let resp = app.oneshot(req).await.expect("request should succeed");

    assert_eq!(
        resp.status(),
        StatusCode::OK,
        "GET /internal/regions with valid key should return 200"
    );
}
