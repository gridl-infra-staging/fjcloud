//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/middleware/metrics.rs.
use std::sync::Arc;
use std::time::Instant;

use axum::{
    extract::{MatchedPath, Request, State},
    middleware::Next,
    response::Response,
};

use crate::services::metrics::MetricsCollector;

/// Axum middleware that records request count and duration metrics.
///
/// Reads `MatchedPath` from request extensions (set by the Router after routing)
/// to normalize paths like `/indexes/foo` → `/indexes/:name`. Falls back to the
/// raw URI path for unmatched routes (404s).
///
/// Use with `axum::middleware::from_fn_with_state`.
pub async fn metrics_middleware(
    State(collector): State<Arc<MetricsCollector>>,
    request: Request,
    next: Next,
) -> Response {
    let start = Instant::now();
    let method = request.method().to_string();

    // MatchedPath is set by the Router after routing. For matched routes, this
    // gives the template (e.g. "/indexes/{name}"). For 404s it's absent.
    let matched_path = request
        .extensions()
        .get::<MatchedPath>()
        .map(|mp| mp.as_str().to_string());
    let fallback_path = request.uri().path().to_string();

    let response = next.run(request).await;

    let path = matched_path.unwrap_or(fallback_path);
    let status = response.status().as_u16();
    collector.record_request(&method, &path, status, start.elapsed());

    response
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::{middleware, routing::get, Router};
    use tower::ServiceExt;

    use crate::services::metrics::MetricsCollector;

    async fn ok_handler() -> &'static str {
        "ok"
    }

    fn test_app(collector: Arc<MetricsCollector>) -> Router {
        Router::new()
            .route("/health", get(ok_handler))
            .route("/indexes/:name", get(ok_handler))
            .layer(middleware::from_fn_with_state(
                collector,
                metrics_middleware,
            ))
    }

    /// Verifies that a single request increments the request counter to 1
    /// and records a histogram observation for request duration.
    #[tokio::test]
    async fn request_increments_counter_and_observes_histogram() {
        let collector = Arc::new(MetricsCollector::new());
        let app = test_app(collector.clone());

        let response = app
            .oneshot(
                Request::builder()
                    .uri("/health")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), 200);

        let text = collector.render();
        assert!(
            text.contains(
                r#"fjcloud_http_requests_total{method="GET",path="/health",status="200"} 1"#
            ),
            "counter should be 1 after one request. Got:\n{text}"
        );
        assert!(
            text.contains("fjcloud_http_request_duration_seconds"),
            "histogram should have an observation"
        );
    }

    /// Verifies that `/indexes/my-specific-index` is recorded under the
    /// `/indexes/:name` route template, not the literal URI path.
    #[tokio::test]
    async fn records_matched_path_template_not_literal() {
        let collector = Arc::new(MetricsCollector::new());
        let app = test_app(collector.clone());

        let response = app
            .oneshot(
                Request::builder()
                    .uri("/indexes/my-specific-index")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), 200);

        let text = collector.render();
        // Should use the template path, NOT the literal "/indexes/my-specific-index"
        assert!(
            text.contains(r#"path="/indexes/{name}""#) || text.contains(r#"path="/indexes/:name""#),
            "should record template path, not literal. Got:\n{text}"
        );
        assert!(
            !text.contains(r#"path="/indexes/my-specific-index""#),
            "should NOT record literal path"
        );
    }

    /// Verifies that unmatched routes (404s) record the literal URI path
    /// since no route template is available.
    #[tokio::test]
    async fn unmatched_route_records_literal_uri_path() {
        let collector = Arc::new(MetricsCollector::new());
        let app = test_app(collector.clone());

        let response = app
            .oneshot(
                Request::builder()
                    .uri("/nonexistent/route")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), 404);

        let text = collector.render();
        assert!(
            text.contains(r#"path="/nonexistent/route""#),
            "404 should record literal URI path. Got:\n{text}"
        );
        assert!(text.contains(r#"status="404""#), "should record 404 status");
    }
}
