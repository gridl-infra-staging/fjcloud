mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use tower::ServiceExt;

#[tokio::test]
async fn metrics_requires_internal_key_header() {
    let app = common::test_app();

    let req = Request::builder()
        .uri("/internal/metrics")
        .body(Body::empty())
        .expect("request should build");

    let resp = app.oneshot(req).await.expect("request should succeed");

    assert_eq!(
        resp.status(),
        StatusCode::UNAUTHORIZED,
        "GET /internal/metrics should require X-Internal-Key"
    );
}

#[tokio::test]
async fn metrics_with_valid_internal_key_returns_prometheus_text() {
    let app = common::test_app();

    let warmup_req = Request::builder()
        .uri("/health")
        .body(Body::empty())
        .expect("request should build");
    let warmup_resp = app
        .clone()
        .oneshot(warmup_req)
        .await
        .expect("warmup request should succeed");
    assert_eq!(warmup_resp.status(), StatusCode::OK);

    let req = Request::builder()
        .uri("/internal/metrics")
        .header("x-internal-key", common::TEST_INTERNAL_AUTH_TOKEN)
        .body(Body::empty())
        .expect("request should build");

    let resp = app.oneshot(req).await.expect("request should succeed");

    assert_eq!(resp.status(), StatusCode::OK);
    assert_eq!(
        resp.headers()
            .get("content-type")
            .and_then(|v| v.to_str().ok()),
        Some("text/plain; version=0.0.4; charset=utf-8")
    );

    let body = resp
        .into_body()
        .collect()
        .await
        .expect("body should collect")
        .to_bytes();
    let text = std::str::from_utf8(&body).expect("body should be UTF-8");
    assert!(
        text.contains("fjcloud_http_requests_total"),
        "metrics body should contain request counter\n{text}"
    );
}

#[tokio::test]
async fn metrics_reflects_health_requests_count() {
    let app = common::test_app();

    for _ in 0..3 {
        let health_req = Request::builder()
            .uri("/health")
            .body(Body::empty())
            .expect("request should build");
        let health_resp = app
            .clone()
            .oneshot(health_req)
            .await
            .expect("health request should succeed");
        assert_eq!(health_resp.status(), StatusCode::OK);
    }

    let metrics_req = Request::builder()
        .uri("/internal/metrics")
        .header("x-internal-key", common::TEST_INTERNAL_AUTH_TOKEN)
        .body(Body::empty())
        .expect("request should build");

    let metrics_resp = app
        .oneshot(metrics_req)
        .await
        .expect("metrics request should succeed");
    assert_eq!(metrics_resp.status(), StatusCode::OK);

    let body = metrics_resp
        .into_body()
        .collect()
        .await
        .expect("body should collect")
        .to_bytes();
    let text = std::str::from_utf8(&body).expect("body should be UTF-8");

    assert!(
        text.contains(r#"fjcloud_http_requests_total{method="GET",path="/health",status="200"} 3"#),
        "expected /health counter value in metrics output\n{text}"
    );
}
