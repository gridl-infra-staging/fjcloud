#![allow(clippy::await_holding_lock)]

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use std::io;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;
use tower::ServiceExt;
use tracing_subscriber::prelude::*;

const BROWSER_ERRORS_PATH: &str = "/browser-errors";
const SENSITIVE_SENTINELS: [&str; 3] = [
    "token=secret",
    "redirect=http://localhost:5432",
    "req-backend-123",
];

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

fn tracing_test_lock() -> std::sync::MutexGuard<'static, ()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn install_sink_subscriber() -> tracing::dispatcher::DefaultGuard {
    let subscriber =
        tracing_subscriber::registry().with(tracing_subscriber::fmt::layer().with_writer(io::sink));
    tracing::subscriber::set_default(subscriber)
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

fn extract_event_field<'a>(event: &'a Value, field: &str) -> Option<&'a str> {
    fn extract_from_span<'a>(span: &'a Value, field: &str) -> Option<&'a str> {
        span.get(field).and_then(Value::as_str).or_else(|| {
            span.get("fields")
                .and_then(|fields| fields.get(field))
                .and_then(Value::as_str)
        })
    }

    event
        .get("fields")
        .and_then(|fields| fields.get(field))
        .and_then(Value::as_str)
        .or_else(|| event.get(field).and_then(Value::as_str))
        .or_else(|| {
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
        })
        .or_else(|| {
            event
                .get("span")
                .and_then(|span| extract_from_span(span, field))
        })
}

fn extract_event_u64_field(event: &Value, field: &str) -> Option<u64> {
    event
        .get("fields")
        .and_then(|fields| fields.get(field))
        .and_then(Value::as_u64)
        .or_else(|| event.get(field).and_then(Value::as_u64))
}

fn valid_browser_runtime_payload() -> Value {
    json!({
        "support_reference": "web-a1b2c3d4e5f6",
        "path": "/status",
        "scope": "public",
        "status": 500,
        "event_type": "browser_runtime",
        "backend_correlation": "absent"
    })
}

struct InvalidBrowserReportCase {
    name: &'static str,
    payload: Value,
    expected_status: StatusCode,
}

fn invalid_browser_report_case(
    name: &'static str,
    mut mutate_payload: impl FnMut(&mut Value),
    expected_status: StatusCode,
) -> InvalidBrowserReportCase {
    let mut payload = valid_browser_runtime_payload();
    mutate_payload(&mut payload);

    InvalidBrowserReportCase {
        name,
        payload,
        expected_status,
    }
}

fn invalid_browser_report_cases() -> Vec<InvalidBrowserReportCase> {
    vec![
        invalid_browser_report_case(
            "support_reference must match web-[a-f0-9]{12}",
            |payload| payload["support_reference"] = json!("web-a1b2c3d4e5fZ"),
            StatusCode::BAD_REQUEST,
        ),
        invalid_browser_report_case(
            "path must not contain query delimiters",
            |payload| payload["path"] = json!("/status?token=secret"),
            StatusCode::BAD_REQUEST,
        ),
        invalid_browser_report_case(
            "path must not contain fragment delimiters",
            |payload| payload["path"] = json!("/status#redirect=http://localhost:5432"),
            StatusCode::BAD_REQUEST,
        ),
        invalid_browser_report_case(
            "path must be a relative path, not an absolute URL",
            |payload| payload["path"] = json!("https://localhost/status"),
            StatusCode::BAD_REQUEST,
        ),
        invalid_browser_report_case(
            "scope must be one of the browser runtime scopes",
            |payload| payload["scope"] = json!("internal"),
            StatusCode::BAD_REQUEST,
        ),
        invalid_browser_report_case(
            "status must remain 500",
            |payload| payload["status"] = json!(400),
            StatusCode::BAD_REQUEST,
        ),
        invalid_browser_report_case(
            "event_type must be browser_runtime",
            |payload| payload["event_type"] = json!("runtime_error"),
            StatusCode::BAD_REQUEST,
        ),
        invalid_browser_report_case(
            "backend_correlation must be absent",
            |payload| payload["backend_correlation"] = json!("req-backend-123"),
            StatusCode::BAD_REQUEST,
        ),
        invalid_browser_report_case(
            "unknown raw message field should be rejected",
            |payload| payload["message"] = json!("token=secret"),
            StatusCode::BAD_REQUEST,
        ),
        invalid_browser_report_case(
            "unknown raw stack field should be rejected",
            |payload| payload["stack"] = json!("redirect=http://localhost:5432"),
            StatusCode::BAD_REQUEST,
        ),
        invalid_browser_report_case(
            "status with wrong JSON type should be rejected",
            |payload| payload["status"] = json!("500"),
            StatusCode::BAD_REQUEST,
        ),
        invalid_browser_report_case(
            "missing required field should be rejected",
            |payload| {
                payload.as_object_mut().unwrap().remove("support_reference");
            },
            StatusCode::BAD_REQUEST,
        ),
    ]
}

fn json_post(uri: &str, body: Value, ip: &str) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(uri)
        .header("content-type", "application/json")
        .header("x-forwarded-for", ip)
        .body(Body::from(body.to_string()))
        .unwrap()
}

async fn body_text(resp: axum::response::Response) -> String {
    let bytes = resp
        .into_body()
        .collect()
        .await
        .expect("response body should collect")
        .to_bytes();
    String::from_utf8_lossy(&bytes).to_string()
}

#[tokio::test(flavor = "current_thread")]
async fn browser_error_report_accepts_valid_payload_and_logs_sanitized_fields() {
    let _guard = tracing_test_lock();

    let state = common::TestStateBuilder::new().build();
    let app = api::router::build_router_with_auth_rate_config(state, 100, Duration::from_secs(60));

    let buf = Arc::new(Mutex::new(Vec::new()));
    let writer = BufWriter(buf.clone());
    let subscriber = tracing_subscriber::registry().with(
        tracing_subscriber::fmt::layer()
            .json()
            .with_writer(writer)
            .with_current_span(true)
            .with_span_list(true),
    );

    let _subscriber_guard = tracing::subscriber::set_default(subscriber);

    let response = app
        .oneshot(json_post(
            BROWSER_ERRORS_PATH,
            valid_browser_runtime_payload(),
            "203.0.113.80",
        ))
        .await
        .expect("request should return a response");

    assert_eq!(
        response.status(),
        StatusCode::ACCEPTED,
        "valid browser runtime reports should be accepted"
    );

    let output = buf.lock().unwrap().clone();
    assert!(
        !output.is_empty(),
        "expected structured log output for browser runtime report"
    );

    let events = parse_json_lines(&output);
    let browser_events: Vec<&Value> = events
        .iter()
        .filter(|event| event_message(event) == Some("browser runtime error reported"))
        .collect();
    let completed_request_events: Vec<&Value> = events
        .iter()
        .filter(|event| event_message(event) == Some("request completed"))
        .collect();

    assert_eq!(
        browser_events.len(),
        1,
        "expected exactly one browser runtime handler log event"
    );
    assert_eq!(
        completed_request_events.len(),
        1,
        "expected exactly one request completed log event"
    );

    let handler_event = browser_events[0];
    let completed_request_event = completed_request_events[0];

    assert_eq!(extract_event_field(handler_event, "path"), Some("/status"));
    assert_eq!(extract_event_field(handler_event, "scope"), Some("public"));
    assert_eq!(
        extract_event_field(handler_event, "support_reference"),
        Some("web-a1b2c3d4e5f6")
    );
    assert_eq!(extract_event_u64_field(handler_event, "status"), Some(500));
    assert_eq!(
        extract_event_field(handler_event, "event_type"),
        Some("browser_runtime")
    );
    assert_eq!(
        extract_event_field(handler_event, "backend_correlation"),
        Some("absent")
    );
    assert_eq!(
        extract_event_field(completed_request_event, "path"),
        Some(BROWSER_ERRORS_PATH),
        "request logging span path should remain the API route path"
    );

    for forbidden_name in [
        "backend_request_id",
        "backendRequestId",
        "req-backend",
        "stack",
        "filename",
    ] {
        assert!(
            extract_event_field(handler_event, forbidden_name).is_none(),
            "handler log should not include forbidden field: {forbidden_name}"
        );
    }

    let handler_event_json = serde_json::to_string(handler_event).unwrap_or_default();
    for forbidden_snippet in ["localhost", "token=", "secret", "redirect"] {
        assert!(
            !handler_event_json.contains(forbidden_snippet),
            "handler log should not contain forbidden snippet: {forbidden_snippet}"
        );
    }
}

#[tokio::test]
async fn browser_error_report_rejects_invalid_payloads_without_echoing_sensitive_values() {
    let _guard = tracing_test_lock();
    let _subscriber_guard = install_sink_subscriber();

    let state = common::TestStateBuilder::new().build();
    let app = api::router::build_router_with_auth_rate_config(state, 100, Duration::from_secs(60));

    for (idx, case) in invalid_browser_report_cases().into_iter().enumerate() {
        let client_ip = format!("203.0.113.{}", 120 + idx);
        let response = app
            .clone()
            .oneshot(json_post(BROWSER_ERRORS_PATH, case.payload, &client_ip))
            .await
            .expect("request should return a response");

        let actual_status = response.status();
        let response_body = body_text(response).await;

        assert_eq!(
            actual_status, case.expected_status,
            "{}: expected {}, got {actual_status}",
            case.name, case.expected_status
        );

        for sentinel in SENSITIVE_SENTINELS {
            assert!(
                !response_body.contains(sentinel),
                "{}: response body should not echo sensitive sentinel {sentinel}",
                case.name
            );
        }
    }
}

#[tokio::test]
async fn browser_error_report_rejects_oversized_payload() {
    let _guard = tracing_test_lock();
    let _subscriber_guard = install_sink_subscriber();

    let state = common::TestStateBuilder::new().build();
    let app = api::router::build_router_with_auth_rate_config(state, 100, Duration::from_secs(60));

    let mut payload = valid_browser_runtime_payload();
    payload["path"] = json!(format!("/{}", "a".repeat(5_000)));

    let response = app
        .oneshot(json_post(BROWSER_ERRORS_PATH, payload, "203.0.113.150"))
        .await
        .expect("request should return a response");
    let response_status = response.status();
    let response_body = body_text(response).await;

    assert_eq!(
        response_status,
        StatusCode::PAYLOAD_TOO_LARGE,
        "oversized browser-runtime payloads should be rejected with 413"
    );
    for sentinel in SENSITIVE_SENTINELS {
        assert!(
            !response_body.contains(sentinel),
            "oversized body rejection should not echo sensitive sentinel {sentinel}"
        );
    }
}

#[tokio::test]
async fn browser_error_report_rejects_malformed_json_without_echoing_sensitive_values() {
    let _guard = tracing_test_lock();
    let _subscriber_guard = install_sink_subscriber();

    let state = common::TestStateBuilder::new().build();
    let app = api::router::build_router_with_auth_rate_config(state, 100, Duration::from_secs(60));

    let malformed_body =
        r#"{"support_reference":"web-a1b2c3d4e5f6","path":"/status?token=secret","scope":"public""#;
    let response = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(BROWSER_ERRORS_PATH)
                .header("content-type", "application/json")
                .header("x-forwarded-for", "203.0.113.151")
                .body(Body::from(malformed_body))
                .unwrap(),
        )
        .await
        .expect("request should return a response");
    let response_status = response.status();
    let response_body = body_text(response).await;

    assert_eq!(
        response_status,
        StatusCode::BAD_REQUEST,
        "malformed browser-runtime JSON should be rejected with a safe 400"
    );
    for sentinel in SENSITIVE_SENTINELS {
        assert!(
            !response_body.contains(sentinel),
            "malformed JSON rejection should not echo sensitive sentinel {sentinel}"
        );
    }
}

#[tokio::test]
async fn browser_error_report_is_public_but_auth_rate_limited() {
    let _guard = tracing_test_lock();
    let _subscriber_guard = install_sink_subscriber();

    let state = common::TestStateBuilder::new().build();
    let app = api::router::build_router_with_auth_rate_config(state, 1, Duration::from_secs(60));

    let client_ip = "203.0.113.180";

    let first_response = app
        .clone()
        .oneshot(json_post(
            BROWSER_ERRORS_PATH,
            valid_browser_runtime_payload(),
            client_ip,
        ))
        .await
        .expect("first request should return a response");
    assert_eq!(
        first_response.status(),
        StatusCode::ACCEPTED,
        "first unauthenticated browser report should be accepted"
    );

    let second_response = app
        .oneshot(json_post(
            BROWSER_ERRORS_PATH,
            valid_browser_runtime_payload(),
            client_ip,
        ))
        .await
        .expect("second request should return a response");
    assert_eq!(
        second_response.status(),
        StatusCode::TOO_MANY_REQUESTS,
        "second report in the same auth-rate window should be throttled"
    );
    assert!(
        second_response.headers().get("retry-after").is_some(),
        "429 responses should include retry-after"
    );
}
