mod common;

use api::errors::ApiError;
use api::middleware::{RequestSpan, ResponseLogger, UuidRequestId};
use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use serde_json::Value;
use std::io;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;
use tower::ServiceExt;
use tower_http::catch_panic::CatchPanicLayer;
use tower_http::cors::CorsLayer;
use tower_http::request_id::{PropagateRequestIdLayer, SetRequestIdLayer};
use tower_http::trace::{OnResponse, TraceLayer};
use tracing_subscriber::prelude::*;

#[derive(Clone)]
struct BufWriter(Arc<Mutex<Vec<u8>>>);

impl io::Write for BufWriter {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for BufWriter {
    type Writer = Self;

    fn make_writer(&'a self) -> Self::Writer {
        self.clone()
    }
}

fn parse_json_lines(buf: &[u8]) -> Vec<Value> {
    let output = String::from_utf8_lossy(buf);
    output
        .lines()
        .map(|line| {
            serde_json::from_str::<Value>(line).expect("each log line should be valid JSON")
        })
        .collect()
}

fn event_message(event: &Value) -> Option<&str> {
    event
        .get("fields")
        .and_then(|fields| fields.get("message"))
        .and_then(Value::as_str)
        .or_else(|| event.get("message").and_then(Value::as_str))
}

fn find_request_completed_event(events: &[Value]) -> Option<&Value> {
    events
        .iter()
        .find(|event| event_message(event) == Some("request completed"))
}

fn find_request_completed_event_for_path<'a>(events: &'a [Value], path: &str) -> Option<&'a Value> {
    events.iter().rfind(|event| {
        event_message(event) == Some("request completed")
            && extract_event_field(event, "path") == Some(path)
    })
}

fn extract_event_field<'a>(event: &'a Value, field: &str) -> Option<&'a str> {
    fn extract_from_span<'a>(span: &'a Value, field: &str) -> Option<&'a str> {
        span.get(field).and_then(Value::as_str).or_else(|| {
            span.get("fields")
                .and_then(|fields| fields.get(field))
                .and_then(Value::as_str)
        })
    }

    event
        .get("spans")
        .and_then(Value::as_array)
        .and_then(|spans| {
            spans
                .iter()
                .find(|span| span.get("name").and_then(Value::as_str) == Some("request"))
                .or_else(|| {
                    spans
                        .iter()
                        .find(|span| extract_from_span(span, field).is_some())
                })
        })
        .and_then(|span| extract_from_span(span, field))
        .or_else(|| {
            event
                .get("span")
                .and_then(|span| extract_from_span(span, field))
        })
        .or_else(|| {
            event
                .get("fields")
                .and_then(|fields| fields.get(field))
                .and_then(Value::as_str)
        })
        .or_else(|| event.get(field).and_then(Value::as_str))
}

fn extract_event_u64_field(event: &Value, field: &str) -> Option<u64> {
    event
        .get("fields")
        .and_then(|fields| fields.get(field))
        .and_then(Value::as_u64)
        .or_else(|| event.get(field).and_then(Value::as_u64))
}

fn tracing_test_lock() -> std::sync::MutexGuard<'static, ()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Test 1: When no x-request-id header is provided, the middleware should generate one
/// and include it in the response.
#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn request_id_generated_when_not_provided() {
    let _guard = tracing_test_lock();
    let app = common::test_app();

    let req = Request::builder()
        .uri("/health")
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let request_id = resp.headers().get("x-request-id");
    assert!(
        request_id.is_some(),
        "response should contain x-request-id header"
    );

    let id_str = request_id.unwrap().to_str().unwrap();
    uuid::Uuid::parse_str(id_str).expect("x-request-id should be a valid UUID");
}

/// Test 2: When x-request-id is already provided, it should be preserved (not overwritten).
#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn request_id_preserved_when_provided_in_header() {
    let _guard = tracing_test_lock();
    let app = common::test_app();
    let custom_id = "custom-request-id-abc123";

    let req = Request::builder()
        .uri("/health")
        .header("x-request-id", custom_id)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let request_id = resp
        .headers()
        .get("x-request-id")
        .unwrap()
        .to_str()
        .unwrap();
    assert_eq!(request_id, custom_id);
}

/// Test 3: Each request gets a unique request ID in the response.
#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn request_id_appears_in_response() {
    let _guard = tracing_test_lock();
    let app1 = common::test_app();
    let req1 = Request::builder()
        .uri("/health")
        .body(Body::empty())
        .unwrap();
    let resp1 = app1.oneshot(req1).await.unwrap();
    let id1 = resp1
        .headers()
        .get("x-request-id")
        .expect("should have x-request-id")
        .to_str()
        .unwrap()
        .to_string();

    let app2 = common::test_app();
    let req2 = Request::builder()
        .uri("/health")
        .body(Body::empty())
        .unwrap();
    let resp2 = app2.oneshot(req2).await.unwrap();
    let id2 = resp2
        .headers()
        .get("x-request-id")
        .expect("should have x-request-id")
        .to_str()
        .unwrap()
        .to_string();

    assert_ne!(id1, id2, "different requests should get different IDs");
}

/// Test 4: Structured logging produces valid JSON output.
#[tokio::test]
async fn json_log_output_is_valid_json() {
    let _guard = tracing_test_lock();
    let buf = Arc::new(Mutex::new(Vec::new()));
    let writer = BufWriter(buf.clone());

    let subscriber = tracing_subscriber::fmt()
        .json()
        .with_writer(writer)
        .finish();

    tracing::subscriber::with_default(subscriber, || {
        tracing::info!(key = "value", "structured logging test message");
    });

    let output = buf.lock().unwrap().clone();
    let parsed_lines = parse_json_lines(&output);
    assert!(!parsed_lines.is_empty(), "should have produced log output");

    for parsed in parsed_lines {
        assert!(
            parsed.get("level").is_some(),
            "JSON log should contain level field"
        );
    }
}

/// Test 5: A panic in a handler returns 500 (not a connection drop) thanks to CatchPanicLayer.
#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn panic_in_handler_returns_500() {
    use axum::routing::get;
    let _guard = tracing_test_lock();

    let app = axum::Router::new()
        .route(
            "/panic",
            get(|| async {
                panic!("intentional test panic");
                #[allow(unreachable_code)]
                "never"
            }),
        )
        .layer(tower_http::catch_panic::CatchPanicLayer::new());

    let req = Request::builder()
        .uri("/panic")
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::INTERNAL_SERVER_ERROR);
}

/// Test 6: Request-completed log includes tenant_id extracted from JWT.
///
/// Uses `registry() + layer()` rather than `fmt().json().finish()` to ensure
/// span recording is always enabled — avoids rare flakes when the test runner
/// has other tracing subscribers active on the same thread pool.
#[test]
fn request_completed_log_includes_tenant_id_from_jwt() {
    let _guard = tracing_test_lock();
    let customer_id = uuid::Uuid::new_v4();
    let token = common::create_test_jwt(customer_id);
    let request_id = "req-123";
    let buf = Arc::new(Mutex::new(Vec::new()));
    let writer = BufWriter(buf.clone());

    let subscriber = tracing_subscriber::registry().with(
        tracing_subscriber::fmt::layer()
            .json()
            .with_writer(writer)
            .with_current_span(true)
            .with_span_list(true),
    );

    let req = Request::builder()
        .uri("/account")
        .header("x-request-id", request_id)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();

    let response = axum::http::Response::builder()
        .status(StatusCode::OK)
        .body(Body::empty())
        .unwrap();

    tracing::subscriber::with_default(subscriber, || {
        let mut request_span = RequestSpan::new(Arc::<str>::from(common::TEST_JWT_SECRET));
        let span = tower_http::trace::MakeSpan::make_span(&mut request_span, &req);
        let _enter = span.enter();
        ResponseLogger.on_response(&response, Duration::from_millis(5), &span);
    });

    let output = buf.lock().unwrap().clone();
    assert!(
        !output.is_empty(),
        "expected trace output but captured none for /account request"
    );
    let events = parse_json_lines(&output);
    let messages: Vec<String> = events
        .iter()
        .filter_map(|event| {
            event
                .get("fields")
                .and_then(|fields| fields.get("message"))
                .and_then(Value::as_str)
                .or_else(|| event.get("message").and_then(Value::as_str))
                .map(str::to_string)
        })
        .collect();
    let request_completed = find_request_completed_event(&events).unwrap_or_else(|| {
        panic!(
            "expected a request completed event in logs; observed messages: {:?}",
            messages
        )
    });

    let tenant_id = extract_event_field(request_completed, "tenant_id").unwrap_or_else(|| {
        panic!(
            "tenant_id should be present in request completed event; event={}",
            serde_json::to_string_pretty(request_completed)
                .unwrap_or_else(|_| request_completed.to_string())
        )
    });
    assert_eq!(tenant_id, customer_id.to_string());
    assert_eq!(
        extract_event_field(request_completed, "request_id")
            .expect("request_id should be present in request completed event"),
        request_id
    );
}

/// Test 7: ResponseLogger emits at the correct log level based on HTTP status code.
/// 2xx/3xx → INFO, 4xx → WARN, 5xx → ERROR.
#[test]
fn response_logger_emits_correct_log_level_for_status_codes() {
    let _guard = tracing_test_lock();
    let cases = vec![
        (200u16, "INFO"),
        (201, "INFO"),
        (301, "INFO"),
        (400, "WARN"),
        (401, "WARN"),
        (404, "WARN"),
        (500, "ERROR"),
        (502, "ERROR"),
    ];

    for (status_code, expected_level) in cases {
        let buf = Arc::new(Mutex::new(Vec::new()));
        let writer = BufWriter(buf.clone());

        let subscriber = tracing_subscriber::registry().with(
            tracing_subscriber::fmt::layer()
                .json()
                .with_writer(writer)
                .with_current_span(true)
                .with_span_list(true),
        );

        let response = axum::http::Response::builder()
            .status(status_code)
            .body(Body::empty())
            .unwrap();

        tracing::subscriber::with_default(subscriber, || {
            let span = tracing::info_span!(
                "request",
                request_id = "test",
                method = "GET",
                path = "/test",
                tenant_id = "-"
            );
            let _enter = span.enter();
            ResponseLogger.on_response(&response, Duration::from_millis(1), &span);
        });

        let output = buf.lock().unwrap().clone();
        let events = parse_json_lines(&output);
        assert!(
            !events.is_empty(),
            "expected log output for status {status_code}"
        );

        let completed = find_request_completed_event(&events)
            .unwrap_or_else(|| panic!("expected request completed event for status {status_code}"));
        let level = completed
            .get("level")
            .and_then(Value::as_str)
            .unwrap_or_else(|| panic!("missing level field for status {status_code}"));
        assert_eq!(
            level, expected_level,
            "status {status_code} should log at {expected_level} but got {level}"
        );
    }
}

/// Test 8: ResponseLogger should attach logs to the provided span even when
/// the caller does not manually enter the span first.
#[test]
fn response_logger_uses_provided_span_without_manual_enter() {
    let _guard = tracing_test_lock();
    let customer_id = uuid::Uuid::new_v4();
    let token = common::create_test_jwt(customer_id);
    let request_id = "req-no-manual-enter";
    let buf = Arc::new(Mutex::new(Vec::new()));
    let writer = BufWriter(buf.clone());

    let subscriber = tracing_subscriber::registry().with(
        tracing_subscriber::fmt::layer()
            .json()
            .with_writer(writer)
            .with_current_span(true)
            .with_span_list(true),
    );

    let req = Request::builder()
        .uri("/account")
        .header("x-request-id", request_id)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();
    let response = axum::http::Response::builder()
        .status(StatusCode::OK)
        .body(Body::empty())
        .unwrap();

    tracing::subscriber::with_default(subscriber, || {
        let mut request_span = RequestSpan::new(Arc::<str>::from(common::TEST_JWT_SECRET));
        let span = tower_http::trace::MakeSpan::make_span(&mut request_span, &req);
        // Intentionally DO NOT enter the span here.
        ResponseLogger.on_response(&response, Duration::from_millis(1), &span);
    });

    let output = buf.lock().unwrap().clone();
    assert!(
        !output.is_empty(),
        "expected trace output but captured none for /account request"
    );
    let events = parse_json_lines(&output);
    let request_completed = find_request_completed_event(&events)
        .expect("expected request completed event when ResponseLogger runs");

    assert_eq!(
        extract_event_field(request_completed, "request_id")
            .expect("request_id should be present in request completed event"),
        request_id
    );
    assert_eq!(
        extract_event_field(request_completed, "tenant_id")
            .expect("tenant_id should be present in request completed event"),
        customer_id.to_string()
    );
}

/// Test 9: Panic responses still carry request IDs when all request middleware is present.
#[tokio::test(flavor = "current_thread")]
#[allow(clippy::await_holding_lock)]
async fn panic_response_includes_request_id_with_full_middleware_stack() {
    use axum::routing::get;
    let _guard = tracing_test_lock();

    let app = axum::Router::new()
        .route(
            "/panic",
            get(|| async {
                panic!("intentional test panic");
                #[allow(unreachable_code)]
                "never"
            }),
        )
        .layer(CatchPanicLayer::new())
        .layer(CorsLayer::permissive())
        .layer(
            TraceLayer::new_for_http()
                .make_span_with(RequestSpan::new(Arc::<str>::from(common::TEST_JWT_SECRET)))
                .on_response(ResponseLogger),
        )
        .layer(PropagateRequestIdLayer::x_request_id())
        .layer(SetRequestIdLayer::x_request_id(UuidRequestId));

    let req = Request::builder()
        .uri("/panic")
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::INTERNAL_SERVER_ERROR);
    assert!(
        resp.headers().get("x-request-id").is_some(),
        "panic responses should still include x-request-id"
    );
}

/// Test 10: Full router middleware-stack request-completed logs include
/// method/path/status/duration fields together.
#[test]
fn request_completed_log_includes_method_path_status_and_duration_from_full_stack() {
    use axum::routing::get;

    let _guard = tracing_test_lock();
    let buf = Arc::new(Mutex::new(Vec::new()));
    let writer = BufWriter(buf.clone());
    let subscriber = tracing_subscriber::registry().with(
        tracing_subscriber::fmt::layer()
            .json()
            .with_writer(writer)
            .with_current_span(true)
            .with_span_list(true),
    );

    tracing::subscriber::with_default(subscriber, || {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("current-thread runtime should build");

        runtime.block_on(async {
            let app = axum::Router::new()
                .route("/ok", get(|| async { "ok" }))
                .layer(CatchPanicLayer::new())
                .layer(CorsLayer::permissive())
                .layer(
                    TraceLayer::new_for_http()
                        .make_span_with(RequestSpan::new(Arc::<str>::from(common::TEST_JWT_SECRET)))
                        .on_response(ResponseLogger),
                )
                .layer(PropagateRequestIdLayer::x_request_id())
                .layer(SetRequestIdLayer::x_request_id(UuidRequestId));
            let req = Request::builder()
                .uri("/ok")
                .header("x-request-id", "req-full-stack")
                .body(Body::empty())
                .unwrap();

            let resp = app.oneshot(req).await.unwrap();
            assert_eq!(resp.status(), StatusCode::OK);
        });
    });

    let output = buf.lock().unwrap().clone();
    assert!(
        !output.is_empty(),
        "expected trace output but captured none for /ok request"
    );
    let events = parse_json_lines(&output);
    let request_completed = find_request_completed_event(&events)
        .expect("expected request completed event for /ok request");

    assert_eq!(
        extract_event_field(request_completed, "method")
            .expect("method should be present in request completed event"),
        "GET"
    );
    assert_eq!(
        extract_event_field(request_completed, "path")
            .expect("path should be present in request completed event"),
        "/ok"
    );
    assert_eq!(
        extract_event_u64_field(request_completed, "status")
            .expect("status should be present in request completed event"),
        200
    );
    let duration_ms = extract_event_u64_field(request_completed, "duration_ms")
        .expect("duration_ms should be present in request completed event");
    assert!(
        duration_ms < 10_000,
        "duration_ms for a local /ok request should stay below 10s, got {duration_ms}"
    );
}

/// Test 11: Full API router generates an x-request-id and logs that same value
/// in the request-completed event for correlation.
#[test]
fn generated_request_id_matches_request_completed_log_in_full_router() {
    let _guard = tracing_test_lock();
    let buf = Arc::new(Mutex::new(Vec::new()));
    let writer = BufWriter(buf.clone());
    let subscriber = tracing_subscriber::registry().with(
        tracing_subscriber::fmt::layer()
            .json()
            .with_writer(writer)
            .with_current_span(true)
            .with_span_list(true),
    );
    let mut response_request_id: Option<String> = None;

    tracing::subscriber::with_default(subscriber, || {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("current-thread runtime should build");

        runtime.block_on(async {
            let app = common::test_app();
            let req = Request::builder()
                .uri("/health")
                .body(Body::empty())
                .unwrap();

            let resp = app.oneshot(req).await.unwrap();
            assert_eq!(resp.status(), StatusCode::OK);

            let request_id = resp
                .headers()
                .get("x-request-id")
                .expect("response should contain x-request-id header")
                .to_str()
                .expect("x-request-id should be valid UTF-8")
                .to_string();
            uuid::Uuid::parse_str(&request_id).expect("x-request-id should be a valid UUID");
            response_request_id = Some(request_id);
        });
    });

    let response_request_id = response_request_id
        .expect("response x-request-id should be captured for correlation assertion");
    let output = buf.lock().unwrap().clone();
    let events = parse_json_lines(&output);
    let request_completed = find_request_completed_event_for_path(&events, "/health")
        .expect("expected a request completed event for /health request");
    let logged_request_id = extract_event_field(request_completed, "request_id")
        .expect("request completed event should contain request_id");

    assert_eq!(
        logged_request_id, response_request_id,
        "generated x-request-id in response header should match logged request_id"
    );
}

/// Test 12: A caller-provided x-request-id survives both response propagation
/// and full-stack request-completed structured logging.
#[test]
fn caller_request_id_preserved_in_response_and_request_completed_log_full_router() {
    let _guard = tracing_test_lock();
    let caller_request_id = "caller-request-id-abc123";
    let buf = Arc::new(Mutex::new(Vec::new()));
    let writer = BufWriter(buf.clone());
    let subscriber = tracing_subscriber::registry().with(
        tracing_subscriber::fmt::layer()
            .json()
            .with_writer(writer)
            .with_current_span(true)
            .with_span_list(true),
    );

    tracing::subscriber::with_default(subscriber, || {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("current-thread runtime should build");

        runtime.block_on(async {
            let app = common::test_app();
            let req = Request::builder()
                .uri("/health")
                .header("x-request-id", caller_request_id)
                .body(Body::empty())
                .unwrap();

            let resp = app.oneshot(req).await.unwrap();
            assert_eq!(resp.status(), StatusCode::OK);
            assert_eq!(
                resp.headers()
                    .get("x-request-id")
                    .expect("response should contain x-request-id header")
                    .to_str()
                    .expect("x-request-id should be valid UTF-8"),
                caller_request_id
            );
        });
    });

    let output = buf.lock().unwrap().clone();
    let events = parse_json_lines(&output);
    let request_completed = find_request_completed_event_for_path(&events, "/health")
        .expect("expected a request completed event for /health request");

    assert_eq!(
        extract_event_field(request_completed, "request_id")
            .expect("request completed event should contain request_id"),
        caller_request_id
    );
}

/// Test 13: Internal API errors stay masked while preserving the caller request id
/// when running through the same request-id/logging middleware stack.
#[tokio::test(flavor = "current_thread")]
#[allow(clippy::await_holding_lock)]
async fn internal_error_body_masked_and_request_id_preserved_with_full_middleware_stack() {
    use axum::routing::get;

    let _guard = tracing_test_lock();
    let caller_request_id = "req-privacy-mask-123";

    let app = axum::Router::new()
        .route(
            "/internal-error",
            get(|| async {
                Err::<(), ApiError>(ApiError::Internal(
                    "db password leaked in error details".to_string(),
                ))
            }),
        )
        .layer(CatchPanicLayer::new())
        .layer(CorsLayer::permissive())
        .layer(
            TraceLayer::new_for_http()
                .make_span_with(RequestSpan::new(Arc::<str>::from(common::TEST_JWT_SECRET)))
                .on_response(ResponseLogger),
        )
        .layer(PropagateRequestIdLayer::x_request_id())
        .layer(SetRequestIdLayer::x_request_id(UuidRequestId));

    let req = Request::builder()
        .uri("/internal-error")
        .header("x-request-id", caller_request_id)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::INTERNAL_SERVER_ERROR);
    assert_eq!(
        resp.headers()
            .get("x-request-id")
            .expect("response should contain x-request-id header")
            .to_str()
            .expect("x-request-id should be valid UTF-8"),
        caller_request_id
    );

    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let json_body: Value = serde_json::from_slice(&body).expect("response body should be JSON");
    assert_eq!(
        json_body,
        serde_json::json!({"error": "internal server error"})
    );
}
