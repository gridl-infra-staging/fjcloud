#![allow(clippy::await_holding_lock)]

mod common;
mod storage_s3_auth_support;
#[allow(dead_code)]
#[path = "common/storage_s3_signed_router_harness.rs"]
mod storage_s3_signed_router_harness;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use serde_json::json;
use std::sync::{Arc, Mutex, OnceLock};
use tower::ServiceExt;

use api::router::{
    build_router, build_router_with_auth_rate_config, build_router_with_cors,
    build_router_with_rate_config, RateLimitConfig,
};
use storage_s3_signed_router_harness::{setup_signed_s3_router, setup_signed_s3_router_with_rps};

fn security_env_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

struct EnvVarGuard {
    key: &'static str,
    previous: Option<String>,
}

const TRUST_PROXY_HEADERS_FOR_RATE_LIMIT_ENV: &str = "TRUST_PROXY_HEADERS_FOR_RATE_LIMIT";

impl EnvVarGuard {
    fn set(key: &'static str, value: &str) -> Self {
        let previous = std::env::var(key).ok();
        std::env::set_var(key, value);
        Self { key, previous }
    }
}

impl Drop for EnvVarGuard {
    fn drop(&mut self) {
        match &self.previous {
            Some(value) => std::env::set_var(self.key, value),
            None => std::env::remove_var(self.key),
        }
    }
}

fn json_post(uri: &str, body: serde_json::Value, ip: &str) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(uri)
        .header("content-type", "application/json")
        .header("x-forwarded-for", ip)
        .body(Body::from(body.to_string()))
        .unwrap()
}

fn pricing_compare_workload() -> serde_json::Value {
    json!({
        "document_count": 100_000,
        "avg_document_size_bytes": 2048,
        "search_requests_per_month": 1_000_000,
        "write_operations_per_month": 50_000,
        "sort_directions": 2,
        "num_indexes": 1,
        "high_availability": false
    })
}

/// Test 1: CORS should allow explicitly configured origins.
#[tokio::test]
async fn cors_allows_configured_origin() {
    let app = build_router_with_cors(common::test_state(), Some("https://portal.example.com"));

    let req = Request::builder()
        .uri("/health")
        .header("origin", "https://portal.example.com")
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let allow_origin = resp
        .headers()
        .get("access-control-allow-origin")
        .expect("configured origin should be allowed");
    assert_eq!(allow_origin, "https://portal.example.com");

    let allow_credentials = resp
        .headers()
        .get("access-control-allow-credentials")
        .expect("CORS credentials should be enabled");
    assert_eq!(allow_credentials, "true");
}

/// Test 2: CORS should reject origins that are not configured.
#[tokio::test]
async fn cors_rejects_unknown_origin() {
    let app = build_router_with_cors(common::test_state(), Some("https://portal.example.com"));

    let req = Request::builder()
        .uri("/health")
        .header("origin", "https://evil.example.com")
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    assert!(
        resp.headers().get("access-control-allow-origin").is_none(),
        "unknown origin must not receive CORS allow header"
    );
}

/// Test 2b: default CORS settings should allow localhost dev origin.
#[tokio::test]
async fn cors_defaults_allow_localhost_origin() {
    let app = build_router_with_cors(common::test_state(), None);

    let req = Request::builder()
        .uri("/health")
        .header("origin", "http://localhost:5173")
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    assert_eq!(
        resp.headers().get("access-control-allow-origin"),
        Some(&axum::http::HeaderValue::from_static(
            "http://localhost:5173",
        )),
        "default CORS allow-list should include localhost dev origin"
    );
}

/// Test 2c: S3 auth failures should still include security headers from outer middleware.
#[tokio::test]
async fn s3_auth_failures_include_security_headers() {
    let harness = setup_signed_s3_router().await;
    let req = Request::builder()
        .method("GET")
        .uri("/")
        .body(Body::empty())
        .unwrap();

    let resp = harness.router.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    assert!(resp.headers().get("strict-transport-security").is_some());
    assert!(resp.headers().get("x-content-type-options").is_some());
    assert!(resp.headers().get("x-frame-options").is_some());
}

/// Test 2d: signed S3 requests should be rate-limited and include retry + SlowDown body.
#[tokio::test]
async fn s3_rate_limit_enforces_retry_after_and_slowdown_payload() {
    let harness = setup_signed_s3_router_with_rps(1).await;

    let first_req = storage_s3_signed_router_harness::signed_s3_request(
        "GET",
        "/",
        &harness.access_key,
        &harness.secret_key,
        vec![],
    );
    let first_resp = harness.router.clone().oneshot(first_req).await.unwrap();
    assert_eq!(first_resp.status(), StatusCode::OK);

    let second_req = storage_s3_signed_router_harness::signed_s3_request(
        "GET",
        "/",
        &harness.access_key,
        &harness.secret_key,
        vec![],
    );
    let second_resp = harness.router.clone().oneshot(second_req).await.unwrap();
    assert_eq!(second_resp.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert!(
        second_resp.headers().get("retry-after").is_some(),
        "S3 SlowDown responses should include retry-after"
    );
    assert!(second_resp
        .headers()
        .get("strict-transport-security")
        .is_some());

    let body_bytes = second_resp
        .into_body()
        .collect()
        .await
        .expect("response body should collect")
        .to_bytes();
    let body_text = String::from_utf8(body_bytes.to_vec()).expect("xml response should be utf8");
    assert!(body_text.contains("<Code>SlowDown</Code>"));
}

/// Test 3: auth endpoints should return 429 when per-IP threshold is exceeded.
#[tokio::test]
async fn auth_rate_limit_returns_429_after_threshold() {
    let _lock = security_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let _auth_rate_limit = EnvVarGuard::set("AUTH_RATE_LIMIT_RPM", "2");

    let app = build_router(common::test_state());
    let ip = "203.0.113.10";

    let req1 = json_post(
        "/auth/forgot-password",
        json!({ "email": "alice@example.com" }),
        ip,
    );
    let req2 = json_post(
        "/auth/forgot-password",
        json!({ "email": "alice@example.com" }),
        ip,
    );
    let req3 = json_post(
        "/auth/forgot-password",
        json!({ "email": "alice@example.com" }),
        ip,
    );

    let resp1 = app.clone().oneshot(req1).await.unwrap();
    let resp2 = app.clone().oneshot(req2).await.unwrap();
    let resp3 = app.oneshot(req3).await.unwrap();

    assert_eq!(resp1.status(), StatusCode::OK);
    assert_eq!(resp2.status(), StatusCode::OK);
    assert_eq!(resp3.status(), StatusCode::TOO_MANY_REQUESTS);
}

/// Test 4: 429 auth responses should include retry-after header.
#[tokio::test]
async fn auth_rate_limit_sets_retry_after_header() {
    let _lock = security_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let _auth_rate_limit = EnvVarGuard::set("AUTH_RATE_LIMIT_RPM", "1");

    let app = build_router(common::test_state());
    let ip = "203.0.113.11";

    let first = app
        .clone()
        .oneshot(json_post(
            "/auth/login",
            json!({
                "email": "nope@example.com",
                "password": "wrong-password"
            }),
            ip,
        ))
        .await
        .unwrap();
    assert_eq!(first.status(), StatusCode::BAD_REQUEST);

    let second = app
        .oneshot(json_post(
            "/auth/login",
            json!({
                "email": "nope@example.com",
                "password": "wrong-password"
            }),
            ip,
        ))
        .await
        .unwrap();
    assert_eq!(second.status(), StatusCode::TOO_MANY_REQUESTS);
    assert!(
        second.headers().get("retry-after").is_some(),
        "rate-limited auth response should include retry-after header"
    );
}

/// Test 5: public pricing comparison should also be rate-limited per-IP.
#[tokio::test]
async fn pricing_compare_rate_limit_returns_429_after_threshold() {
    let _lock = security_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let app = build_router_with_auth_rate_config(
        common::test_state(),
        1,
        std::time::Duration::from_secs(60),
    );
    let ip = "203.0.113.12";

    let resp1 = app
        .clone()
        .oneshot(json_post(
            "/pricing/compare",
            pricing_compare_workload(),
            ip,
        ))
        .await
        .unwrap();
    assert_eq!(resp1.status(), StatusCode::OK);

    let resp2 = app
        .oneshot(json_post(
            "/pricing/compare",
            pricing_compare_workload(),
            ip,
        ))
        .await
        .unwrap();
    assert_eq!(
        resp2.status(),
        StatusCode::TOO_MANY_REQUESTS,
        "public pricing compare should not allow unlimited anonymous requests from one IP"
    );
}

/// Test 6: Rate limit should reset after the window expires — requests are allowed again.
#[tokio::test]
async fn auth_rate_limit_resets_after_window() {
    let app = build_router_with_auth_rate_config(
        common::test_state(),
        1,                                     // 1 request per window
        std::time::Duration::from_millis(200), // 200ms window
    );

    let ip = "203.0.113.20";

    // First request succeeds
    let resp1 = app
        .clone()
        .oneshot(json_post(
            "/auth/forgot-password",
            json!({ "email": "a@example.com" }),
            ip,
        ))
        .await
        .unwrap();
    assert_eq!(resp1.status(), StatusCode::OK);

    // Second request within window is blocked
    let resp2 = app
        .clone()
        .oneshot(json_post(
            "/auth/forgot-password",
            json!({ "email": "b@example.com" }),
            ip,
        ))
        .await
        .unwrap();
    assert_eq!(resp2.status(), StatusCode::TOO_MANY_REQUESTS);

    // Wait for window to expire
    tokio::time::sleep(std::time::Duration::from_millis(250)).await;

    // Third request after window expires should succeed
    let resp3 = app
        .oneshot(json_post(
            "/auth/forgot-password",
            json!({ "email": "c@example.com" }),
            ip,
        ))
        .await
        .unwrap();
    assert_eq!(
        resp3.status(),
        StatusCode::OK,
        "rate limit should reset after window expires"
    );
}

/// Test 7: Invalid zero-RPM config should be clamped to a safe minimum (1 RPM), not panic.
#[tokio::test]
async fn auth_rate_limit_zero_rpm_is_clamped_to_one() {
    let _lock = security_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let app = build_router_with_auth_rate_config(
        common::test_state(),
        0, // invalid config
        std::time::Duration::from_secs(60),
    );

    let ip = "203.0.113.29";
    let resp1 = app
        .clone()
        .oneshot(json_post(
            "/auth/forgot-password",
            json!({ "email": "a@example.com" }),
            ip,
        ))
        .await
        .unwrap();
    assert_eq!(
        resp1.status(),
        StatusCode::OK,
        "invalid zero-RPM config should be clamped to 1 RPM (first request allowed)"
    );

    let resp2 = app
        .oneshot(json_post(
            "/auth/forgot-password",
            json!({ "email": "b@example.com" }),
            ip,
        ))
        .await
        .unwrap();
    assert_eq!(
        resp2.status(),
        StatusCode::TOO_MANY_REQUESTS,
        "second request in window should be rate-limited after clamping to 1 RPM"
    );
}

/// Test 8: Different IPs should have independent rate limits.
#[tokio::test]
async fn auth_rate_limit_is_per_ip() {
    let _lock = security_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let _trust_proxy = EnvVarGuard::set(TRUST_PROXY_HEADERS_FOR_RATE_LIMIT_ENV, "1");

    let app = build_router_with_auth_rate_config(
        common::test_state(),
        1, // 1 request per window
        std::time::Duration::from_secs(60),
    );

    let ip_a = "203.0.113.30";
    let ip_b = "203.0.113.31";

    // IP A makes a request (succeeds)
    let resp_a1 = app
        .clone()
        .oneshot(json_post(
            "/auth/forgot-password",
            json!({ "email": "a@example.com" }),
            ip_a,
        ))
        .await
        .unwrap();
    assert_eq!(resp_a1.status(), StatusCode::OK);

    // IP A is now rate-limited
    let resp_a2 = app
        .clone()
        .oneshot(json_post(
            "/auth/forgot-password",
            json!({ "email": "a@example.com" }),
            ip_a,
        ))
        .await
        .unwrap();
    assert_eq!(resp_a2.status(), StatusCode::TOO_MANY_REQUESTS);

    // IP B should still be allowed (independent rate limit)
    let resp_b1 = app
        .oneshot(json_post(
            "/auth/forgot-password",
            json!({ "email": "b@example.com" }),
            ip_b,
        ))
        .await
        .unwrap();
    assert_eq!(
        resp_b1.status(),
        StatusCode::OK,
        "different IPs should have independent rate limits"
    );
}

/// Test 9: Rate limiter uses the LAST IP from X-Forwarded-For (rightmost),
/// not the first. Reverse proxies (ALB, nginx) append the real client IP at the end.
/// The first entries can be spoofed by the client to bypass rate limiting.
#[tokio::test]
async fn auth_rate_limit_uses_last_forwarded_ip() {
    let _lock = security_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let _trust_proxy = EnvVarGuard::set(TRUST_PROXY_HEADERS_FOR_RATE_LIMIT_ENV, "1");

    let app = build_router_with_auth_rate_config(
        common::test_state(),
        1, // 1 request per window
        std::time::Duration::from_secs(60),
    );

    let real_ip = "203.0.113.50";

    // Request 1: single IP — rate limit applied to "203.0.113.50"
    let resp1 = app
        .clone()
        .oneshot(json_post(
            "/auth/forgot-password",
            json!({ "email": "a@example.com" }),
            real_ip,
        ))
        .await
        .unwrap();
    assert_eq!(resp1.status(), StatusCode::OK);

    // Request 2: attacker sends spoofed first IP but real IP is still last.
    // Header: "spoofed_ip, real_ip" — should rate-limit on real_ip.
    let req2 = Request::builder()
        .method("POST")
        .uri("/auth/forgot-password")
        .header("content-type", "application/json")
        .header("x-forwarded-for", format!("10.0.0.1, {real_ip}"))
        .body(Body::from(json!({ "email": "b@example.com" }).to_string()))
        .unwrap();

    let resp2 = app.clone().oneshot(req2).await.unwrap();
    assert_eq!(
        resp2.status(),
        StatusCode::TOO_MANY_REQUESTS,
        "spoofed first IP should not bypass rate limit — real IP (last) is rate-limited"
    );

    // Request 3: completely different real IP at the end — should be allowed
    let req3 = Request::builder()
        .method("POST")
        .uri("/auth/forgot-password")
        .header("content-type", "application/json")
        .header("x-forwarded-for", "10.0.0.1, 203.0.113.99")
        .body(Body::from(json!({ "email": "c@example.com" }).to_string()))
        .unwrap();

    let resp3 = app.oneshot(req3).await.unwrap();
    assert_eq!(
        resp3.status(),
        StatusCode::OK,
        "different real IP (last in XFF) should have its own rate limit bucket"
    );
}

/// Test 10: If X-Forwarded-For is absent, rate limiting should use X-Real-IP.
#[tokio::test]
async fn auth_rate_limit_uses_x_real_ip_when_forwarded_header_missing() {
    let _lock = security_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let _trust_proxy = EnvVarGuard::set(TRUST_PROXY_HEADERS_FOR_RATE_LIMIT_ENV, "1");

    let app = build_router_with_auth_rate_config(
        common::test_state(),
        1, // 1 request per window
        std::time::Duration::from_secs(60),
    );

    let req1 = Request::builder()
        .method("POST")
        .uri("/auth/forgot-password")
        .header("content-type", "application/json")
        .header("x-real-ip", "198.51.100.20")
        .body(Body::from(json!({ "email": "a@example.com" }).to_string()))
        .unwrap();
    let resp1 = app.clone().oneshot(req1).await.unwrap();
    assert_eq!(resp1.status(), StatusCode::OK);

    let req2 = Request::builder()
        .method("POST")
        .uri("/auth/forgot-password")
        .header("content-type", "application/json")
        .header("x-real-ip", "198.51.100.20")
        .body(Body::from(json!({ "email": "b@example.com" }).to_string()))
        .unwrap();
    let resp2 = app.clone().oneshot(req2).await.unwrap();
    assert_eq!(
        resp2.status(),
        StatusCode::TOO_MANY_REQUESTS,
        "same X-Real-IP should hit the same rate limit bucket"
    );

    let req3 = Request::builder()
        .method("POST")
        .uri("/auth/forgot-password")
        .header("content-type", "application/json")
        .header("x-real-ip", "198.51.100.21")
        .body(Body::from(json!({ "email": "c@example.com" }).to_string()))
        .unwrap();
    let resp3 = app.oneshot(req3).await.unwrap();
    assert_eq!(
        resp3.status(),
        StatusCode::OK,
        "different X-Real-IP should use a different rate limit bucket"
    );
}

/// Test 11: If no IP headers are present, requests should share the "unknown" bucket.
#[tokio::test]
async fn auth_rate_limit_falls_back_to_unknown_when_no_ip_headers() {
    let app = build_router_with_auth_rate_config(
        common::test_state(),
        1, // 1 request per window
        std::time::Duration::from_secs(60),
    );

    let req1 = Request::builder()
        .method("POST")
        .uri("/auth/forgot-password")
        .header("content-type", "application/json")
        .body(Body::from(json!({ "email": "a@example.com" }).to_string()))
        .unwrap();
    let resp1 = app.clone().oneshot(req1).await.unwrap();
    assert_eq!(resp1.status(), StatusCode::OK);

    let req2 = Request::builder()
        .method("POST")
        .uri("/auth/forgot-password")
        .header("content-type", "application/json")
        .body(Body::from(json!({ "email": "b@example.com" }).to_string()))
        .unwrap();
    let resp2 = app.oneshot(req2).await.unwrap();
    assert_eq!(
        resp2.status(),
        StatusCode::TOO_MANY_REQUESTS,
        "missing IP headers should fall back to shared unknown rate limit bucket"
    );
}

// ---------------------------------------------------------------------------
// Per-tenant rate limiting tests
// ---------------------------------------------------------------------------

fn authed_get(uri: &str, customer_id: uuid::Uuid) -> Request<Body> {
    let jwt = common::create_jwt_with_secret(customer_id, common::TEST_JWT_SECRET);
    Request::builder()
        .method("GET")
        .uri(uri)
        .header("authorization", format!("Bearer {jwt}"))
        .body(Body::empty())
        .unwrap()
}

fn tenant_rate_limited_app(
    customer_repo: Arc<common::MockCustomerRepo>,
    tenant_rpm: u32,
) -> axum::Router {
    let state = common::test_state_with_repo(customer_repo);
    build_router_with_rate_config(
        state,
        RateLimitConfig {
            auth_rpm: 100,
            auth_window: std::time::Duration::from_secs(60),
            tenant_rpm: Some(tenant_rpm),
            tenant_window: std::time::Duration::from_secs(60),
            admin_rpm: None,
            admin_window: std::time::Duration::from_secs(60),
        },
    )
}

/// Test 12: tenant API endpoints should return 429 when per-tenant threshold is exceeded.
#[tokio::test]
async fn tenant_rate_limit_returns_429_after_threshold() {
    let repo = Arc::new(common::MockCustomerRepo::new());
    let customer = repo.seed("Tenant A", "a@example.com");
    let app = tenant_rate_limited_app(repo, 2);

    let resp1 = app
        .clone()
        .oneshot(authed_get("/account", customer.id))
        .await
        .unwrap();
    assert_eq!(resp1.status(), StatusCode::OK);

    let resp2 = app
        .clone()
        .oneshot(authed_get("/account", customer.id))
        .await
        .unwrap();
    assert_eq!(resp2.status(), StatusCode::OK);

    let resp3 = app
        .clone()
        .oneshot(authed_get("/account", customer.id))
        .await
        .unwrap();
    assert_eq!(
        resp3.status(),
        StatusCode::TOO_MANY_REQUESTS,
        "third request should be rate-limited after 2 RPM per-tenant limit"
    );
}

/// Test 13: 429 tenant responses should include retry-after header.
#[tokio::test]
async fn tenant_rate_limit_sets_retry_after_header() {
    let repo = Arc::new(common::MockCustomerRepo::new());
    let customer = repo.seed("Tenant B", "b@example.com");
    let app = tenant_rate_limited_app(repo, 1);

    let resp1 = app
        .clone()
        .oneshot(authed_get("/account", customer.id))
        .await
        .unwrap();
    assert_eq!(resp1.status(), StatusCode::OK);

    let resp2 = app
        .clone()
        .oneshot(authed_get("/account", customer.id))
        .await
        .unwrap();
    assert_eq!(resp2.status(), StatusCode::TOO_MANY_REQUESTS);
    assert!(
        resp2.headers().get("retry-after").is_some(),
        "rate-limited tenant response should include retry-after header"
    );
}

/// Test 14: different tenants should have independent rate limits.
#[tokio::test]
async fn tenant_rate_limit_is_per_tenant() {
    let repo = Arc::new(common::MockCustomerRepo::new());
    let tenant_a = repo.seed("Tenant A", "a@example.com");
    let tenant_b = repo.seed("Tenant B", "b@example.com");
    let app = tenant_rate_limited_app(repo, 1);

    // Tenant A hits the limit
    let resp_a1 = app
        .clone()
        .oneshot(authed_get("/account", tenant_a.id))
        .await
        .unwrap();
    assert_eq!(resp_a1.status(), StatusCode::OK);

    let resp_a2 = app
        .clone()
        .oneshot(authed_get("/account", tenant_a.id))
        .await
        .unwrap();
    assert_eq!(resp_a2.status(), StatusCode::TOO_MANY_REQUESTS);

    // Tenant B should still be allowed (independent rate limit)
    let resp_b1 = app
        .clone()
        .oneshot(authed_get("/account", tenant_b.id))
        .await
        .unwrap();
    assert_eq!(
        resp_b1.status(),
        StatusCode::OK,
        "different tenants should have independent rate limits"
    );
}

/// Test 15: unauthenticated requests to tenant endpoints should not be rate-limited
/// (they'll get 401 from the auth extractor, not 429).
#[tokio::test]
async fn tenant_rate_limit_skips_unauthenticated_requests() {
    let repo = Arc::new(common::MockCustomerRepo::new());
    let app = tenant_rate_limited_app(repo, 1);

    // No auth header — should get 401, not 429
    let req = Request::builder()
        .method("GET")
        .uri("/billing/estimate")
        .body(Body::empty())
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::UNAUTHORIZED,
        "unauthenticated requests should get 401, not 429"
    );
}

// ---------------------------------------------------------------------------
// Admin rate limiting tests
// ---------------------------------------------------------------------------

fn admin_get(uri: &str, ip: &str) -> Request<Body> {
    Request::builder()
        .method("GET")
        .uri(uri)
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .header("x-forwarded-for", ip)
        .body(Body::empty())
        .unwrap()
}

fn admin_rate_limited_app(admin_rpm: u32) -> axum::Router {
    let state = common::test_state();
    build_router_with_rate_config(
        state,
        RateLimitConfig {
            auth_rpm: 100,
            auth_window: std::time::Duration::from_secs(60),
            tenant_rpm: None,
            tenant_window: std::time::Duration::from_secs(60),
            admin_rpm: Some(admin_rpm),
            admin_window: std::time::Duration::from_secs(60),
        },
    )
}

/// Test 15: admin endpoints should return 429 when per-IP threshold is exceeded.
#[tokio::test]
async fn admin_rate_limit_returns_429_after_threshold() {
    let _lock = security_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let app = admin_rate_limited_app(2);
    let ip = "10.0.0.1";

    let resp1 = app
        .clone()
        .oneshot(admin_get("/admin/fleet", ip))
        .await
        .unwrap();
    assert_eq!(resp1.status(), StatusCode::OK);

    let resp2 = app
        .clone()
        .oneshot(admin_get("/admin/fleet", ip))
        .await
        .unwrap();
    assert_eq!(resp2.status(), StatusCode::OK);

    let resp3 = app
        .clone()
        .oneshot(admin_get("/admin/fleet", ip))
        .await
        .unwrap();
    assert_eq!(
        resp3.status(),
        StatusCode::TOO_MANY_REQUESTS,
        "third admin request should be rate-limited after 2 RPM per-IP limit"
    );
}

/// Test 16: admin 429 responses should include retry-after header.
#[tokio::test]
async fn admin_rate_limit_sets_retry_after_header() {
    let app = admin_rate_limited_app(1);
    let ip = "10.0.0.2";

    let resp1 = app
        .clone()
        .oneshot(admin_get("/admin/fleet", ip))
        .await
        .unwrap();
    assert_eq!(resp1.status(), StatusCode::OK);

    let resp2 = app
        .clone()
        .oneshot(admin_get("/admin/fleet", ip))
        .await
        .unwrap();
    assert_eq!(resp2.status(), StatusCode::TOO_MANY_REQUESTS);
    assert!(
        resp2.headers().get("retry-after").is_some(),
        "rate-limited admin response should include retry-after header"
    );
}

/// Test 17: different admin IPs should have independent rate limits.
#[tokio::test]
async fn admin_rate_limit_is_per_ip() {
    let _lock = security_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let _trust_proxy = EnvVarGuard::set(TRUST_PROXY_HEADERS_FOR_RATE_LIMIT_ENV, "1");

    let app = admin_rate_limited_app(1);
    let ip_a = "10.0.0.10";
    let ip_b = "10.0.0.11";

    // IP A hits the limit
    let resp_a1 = app
        .clone()
        .oneshot(admin_get("/admin/fleet", ip_a))
        .await
        .unwrap();
    assert_eq!(resp_a1.status(), StatusCode::OK);

    let resp_a2 = app
        .clone()
        .oneshot(admin_get("/admin/fleet", ip_a))
        .await
        .unwrap();
    assert_eq!(resp_a2.status(), StatusCode::TOO_MANY_REQUESTS);

    // IP B should still be allowed
    let resp_b1 = app
        .clone()
        .oneshot(admin_get("/admin/fleet", ip_b))
        .await
        .unwrap();
    assert_eq!(
        resp_b1.status(),
        StatusCode::OK,
        "different admin IPs should have independent rate limits"
    );
}

// ---------------------------------------------------------------------------
// Path segment injection tests (proxy URL safety)
// ---------------------------------------------------------------------------

fn authed_request(
    method: &str,
    uri: &str,
    customer_id: uuid::Uuid,
    body: Option<serde_json::Value>,
) -> Request<Body> {
    let jwt = common::create_jwt_with_secret(customer_id, common::TEST_JWT_SECRET);
    let builder = Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {jwt}"))
        .header("content-type", "application/json");
    match body {
        Some(b) => builder.body(Body::from(b.to_string())).unwrap(),
        None => builder.body(Body::empty()).unwrap(),
    }
}

/// Test 18: rule object_id with path traversal characters should be rejected.
#[tokio::test]
async fn rule_object_id_rejects_path_traversal() {
    let repo = Arc::new(common::MockCustomerRepo::new());
    let customer = repo.seed("Tenant X", "x@example.com");
    let state = common::test_state_with_repo(repo);
    let app = build_router_with_rate_config(
        state,
        RateLimitConfig {
            auth_rpm: 100,
            auth_window: std::time::Duration::from_secs(60),
            tenant_rpm: None,
            tenant_window: std::time::Duration::from_secs(60),
            admin_rpm: None,
            admin_window: std::time::Duration::from_secs(60),
        },
    );

    // Percent-encoded path traversal: %2F = /
    // The URL path /indexes/test/rules/..%2F..%2Fadmin would match the route with
    // object_id = "../../admin" after percent-decoding. This must be rejected.
    let resp = app
        .clone()
        .oneshot(authed_request(
            "GET",
            "/indexes/test/rules/..%2F..%2Fadmin",
            customer.id,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::BAD_REQUEST,
        "object_id containing path traversal (/) must be rejected as 400"
    );
}

/// Test 19: rule object_id with query injection should be rejected.
#[tokio::test]
async fn rule_object_id_rejects_query_injection() {
    let repo = Arc::new(common::MockCustomerRepo::new());
    let customer = repo.seed("Tenant Y", "y@example.com");
    let state = common::test_state_with_repo(repo);
    let app = build_router_with_rate_config(
        state,
        RateLimitConfig {
            auth_rpm: 100,
            auth_window: std::time::Duration::from_secs(60),
            tenant_rpm: None,
            tenant_window: std::time::Duration::from_secs(60),
            admin_rpm: None,
            admin_window: std::time::Duration::from_secs(60),
        },
    );

    let resp = app
        .clone()
        .oneshot(authed_request(
            "GET",
            "/indexes/test/rules/foo%3Fevil%3Dtrue",
            customer.id,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::BAD_REQUEST,
        "object_id containing '?' must be rejected as 400"
    );
}

/// Test 20: experiment id with path traversal should be rejected.
#[tokio::test]
async fn experiment_id_rejects_path_traversal() {
    let repo = Arc::new(common::MockCustomerRepo::new());
    let customer = repo.seed("Tenant Z", "z@example.com");
    let state = common::test_state_with_repo(repo);
    let app = build_router_with_rate_config(
        state,
        RateLimitConfig {
            auth_rpm: 100,
            auth_window: std::time::Duration::from_secs(60),
            tenant_rpm: None,
            tenant_window: std::time::Duration::from_secs(60),
            admin_rpm: None,
            admin_window: std::time::Duration::from_secs(60),
        },
    );

    let resp = app
        .clone()
        .oneshot(authed_request(
            "GET",
            "/indexes/test/experiments/..%2F..%2F1%2Findexes",
            customer.id,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::BAD_REQUEST,
        "experiment_id containing path traversal (/) must be rejected as 400"
    );
}

// ---------------------------------------------------------------------------
// Public pricing route boundary tests
// ---------------------------------------------------------------------------

fn pricing_post(body: serde_json::Value) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri("/pricing/compare")
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap()
}

fn valid_workload() -> serde_json::Value {
    json!({
        "document_count": 100_000,
        "avg_document_size_bytes": 2048,
        "search_requests_per_month": 1_000_000,
        "write_operations_per_month": 50_000,
        "sort_directions": 2,
        "num_indexes": 1,
        "high_availability": false
    })
}

/// Test 21: /pricing/compare must be accessible without any auth headers.
#[tokio::test]
async fn pricing_compare_is_public_no_auth_required() {
    let app = build_router(common::test_state());

    let resp = app.oneshot(pricing_post(valid_workload())).await.unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::OK,
        "/pricing/compare must be accessible without authentication"
    );
}

/// Test 22: /pricing/compare must not be affected by tenant rate limiting.
#[tokio::test]
async fn pricing_compare_not_affected_by_tenant_rate_limit() {
    let repo = Arc::new(common::MockCustomerRepo::new());
    let app = tenant_rate_limited_app(repo, 1);

    // Send two requests — both should succeed even with 1 RPM tenant limit
    let resp1 = app
        .clone()
        .oneshot(pricing_post(valid_workload()))
        .await
        .unwrap();
    assert_eq!(resp1.status(), StatusCode::OK);

    let resp2 = app.oneshot(pricing_post(valid_workload())).await.unwrap();
    assert_eq!(
        resp2.status(),
        StatusCode::OK,
        "public pricing route should not be affected by tenant rate limiting"
    );
}

/// Test 23: /pricing/compare must not leak internal error details.
#[tokio::test]
async fn pricing_compare_validation_error_does_not_leak_internals() {
    let app = build_router(common::test_state());

    let mut workload = valid_workload();
    workload["document_count"] = json!(-1);

    let resp = app.oneshot(pricing_post(workload)).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let body: serde_json::Value = serde_json::from_slice(&bytes).unwrap();

    // Error must be a user-facing validation message, not a stack trace or internal detail
    let error_msg = body["error"].as_str().unwrap();
    assert!(
        error_msg.contains("document_count"),
        "validation error should name the invalid field"
    );
    assert!(
        !error_msg.contains("panic") && !error_msg.contains("thread"),
        "error message must not contain internal debug information"
    );
}

/// Test 24: GET /pricing/compare should return 405 (method not allowed).
#[tokio::test]
async fn pricing_compare_rejects_get_method() {
    let app = build_router(common::test_state());

    let req = Request::builder()
        .method("GET")
        .uri("/pricing/compare")
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::METHOD_NOT_ALLOWED,
        "GET on /pricing/compare should return 405"
    );
}
