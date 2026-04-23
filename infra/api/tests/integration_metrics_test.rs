// Integration metrics smoke test — validates Prometheus endpoint shape.
//
// This test is skipped when INTEGRATION env var is not set.
// Run with: INTEGRATION=1 cargo test -p api --test integration_metrics_test -- --test-threads=1

#[path = "common/integration_helpers.rs"]
mod integration_helpers;

use integration_helpers::{api_base, http_client};

integration_test!(
    integration_metrics_endpoint_returns_prometheus_format,
    async {
        let client = http_client();
        let base = api_base();

        for _ in 0..3 {
            let health = client
                .get(format!("{base}/health"))
                .send()
                .await
                .expect("health request failed");
            assert_eq!(
                health.status().as_u16(),
                200,
                "GET /health should return 200"
            );
        }

        let internal_key = std::env::var("INTEGRATION_INTERNAL_AUTH_TOKEN")
            .unwrap_or_else(|_| "integration-test-internal-key".to_string());

        let metrics = client
            .get(format!("{base}/internal/metrics"))
            .header("X-Internal-Key", internal_key)
            .send()
            .await
            .expect("metrics request failed");

        assert_eq!(
            metrics.status().as_u16(),
            200,
            "GET /internal/metrics should return 200"
        );

        let content_type = metrics
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or_default();
        assert!(
            content_type.starts_with("text/plain"),
            "metrics content-type should be text/plain, got: {content_type}"
        );

        let body = metrics
            .text()
            .await
            .expect("metrics body should be readable");
        assert!(
            body.contains("fjcloud_http_requests_total"),
            "metrics body should contain request counter"
        );
    }
);
