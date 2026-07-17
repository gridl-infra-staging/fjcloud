use axum::extract::rejection::JsonRejection;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::Deserialize;
use serde_json::json;

use crate::errors::ApiError;

const EXPECTED_STATUS: u16 = 500;
const EXPECTED_EVENT_TYPE: &str = "browser_runtime";
const EXPECTED_BACKEND_CORRELATION: &str = "absent";
const SUPPORT_REFERENCE_PREFIX: &str = "web-";
const SUPPORT_REFERENCE_HEX_LEN: usize = 12;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BrowserRuntimeReport {
    pub path: String,
    pub status: u16,
    pub scope: String,
    pub event_type: String,
    pub support_reference: String,
    pub backend_correlation: String,
}

pub async fn report_browser_error(
    report: Result<Json<BrowserRuntimeReport>, JsonRejection>,
) -> Response {
    let Json(report) = match report {
        Ok(report) => report,
        Err(rejection) => return browser_runtime_report_rejection_response(rejection),
    };

    if let Err(error) = validate_browser_runtime_report(&report) {
        return error.into_response();
    }

    tracing::Span::none().in_scope(|| {
        tracing::info!(
            path = %report.path,
            scope = %report.scope,
            support_reference = %report.support_reference,
            status = report.status,
            event_type = %report.event_type,
            backend_correlation = %report.backend_correlation,
            "browser runtime error reported"
        );
    });

    StatusCode::ACCEPTED.into_response()
}

fn browser_runtime_report_rejection_response(rejection: JsonRejection) -> Response {
    if rejection.status() == StatusCode::PAYLOAD_TOO_LARGE {
        return (
            StatusCode::PAYLOAD_TOO_LARGE,
            Json(json!({ "error": "browser runtime report too large" })),
        )
            .into_response();
    }

    invalid_browser_runtime_report().into_response()
}

fn invalid_browser_runtime_report() -> ApiError {
    ApiError::BadRequest("invalid browser runtime report".to_string())
}

fn validate_browser_runtime_report(report: &BrowserRuntimeReport) -> Result<(), ApiError> {
    if !is_valid_support_reference(&report.support_reference) {
        return Err(invalid_browser_runtime_report());
    }

    if !is_valid_browser_path(&report.path) {
        return Err(invalid_browser_runtime_report());
    }

    if !matches!(report.scope.as_str(), "public" | "dashboard") {
        return Err(invalid_browser_runtime_report());
    }

    if report.status != EXPECTED_STATUS {
        return Err(invalid_browser_runtime_report());
    }

    if report.event_type != EXPECTED_EVENT_TYPE {
        return Err(invalid_browser_runtime_report());
    }

    if report.backend_correlation != EXPECTED_BACKEND_CORRELATION {
        return Err(invalid_browser_runtime_report());
    }

    Ok(())
}

fn is_valid_support_reference(value: &str) -> bool {
    if !value.starts_with(SUPPORT_REFERENCE_PREFIX) {
        return false;
    }

    let suffix = &value[SUPPORT_REFERENCE_PREFIX.len()..];
    if suffix.len() != SUPPORT_REFERENCE_HEX_LEN {
        return false;
    }

    suffix
        .as_bytes()
        .iter()
        .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

fn is_valid_browser_path(path: &str) -> bool {
    if path.is_empty() || !path.starts_with('/') || path.starts_with("//") {
        return false;
    }

    if path.contains('?') || path.contains('#') || path.contains("://") {
        return false;
    }

    !path.chars().any(|ch| ch == '\\' || ch.is_control())
}
