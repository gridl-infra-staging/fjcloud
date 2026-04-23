//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/routes/admin/alerts.rs.
use axum::extract::{Query, State};
use axum::response::IntoResponse;
use axum::Json;
use serde::Deserialize;

use crate::auth::AdminAuth;
use crate::errors::ApiError;
use crate::helpers;
use crate::services::alerting::AlertSeverity;
use crate::state::AppState;

const DEFAULT_ALERT_LIMIT: i64 = 100;
const MAX_ALERT_LIMIT: i64 = 500;

#[derive(Debug, Deserialize)]
pub struct ListAlertsQuery {
    pub limit: Option<i64>,
    pub severity: Option<String>,
}

fn parse_severity_filter(raw: Option<&str>) -> Result<Option<AlertSeverity>, ApiError> {
    let Some(value) = raw.map(str::trim).filter(|value| !value.is_empty()) else {
        return Ok(None);
    };

    match value {
        "info" => Ok(Some(AlertSeverity::Info)),
        "warning" => Ok(Some(AlertSeverity::Warning)),
        "critical" => Ok(Some(AlertSeverity::Critical)),
        _ => Err(ApiError::BadRequest(
            "severity must be one of: info, warning, critical".to_string(),
        )),
    }
}

/// `GET /admin/alerts` — list recent alerts with optional severity filter.
///
/// **Auth:** `AdminAuth`.
/// Accepts `severity` (info, warning, critical) and `limit` (default 100,
/// max 500). When a severity filter is provided, fetches up to `MAX_ALERT_LIMIT`
/// and filters in-memory before applying the requested limit.
pub async fn list_alerts(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Query(query): Query<ListAlertsQuery>,
) -> Result<impl IntoResponse, ApiError> {
    let limit = helpers::parse_limit(query.limit, DEFAULT_ALERT_LIMIT, MAX_ALERT_LIMIT)?;
    let severity_filter = parse_severity_filter(query.severity.as_deref())?;

    // If a severity filter is provided, fetch up to the endpoint max and then
    // filter in-memory so we can still cap output by the requested limit.
    let fetch_limit = if severity_filter.is_some() {
        MAX_ALERT_LIMIT
    } else {
        limit
    };

    let mut alerts = state
        .alert_service
        .get_recent_alerts(fetch_limit)
        .await
        .map_err(|e| ApiError::Internal(format!("failed to fetch alerts: {e}")))?;

    if let Some(severity) = severity_filter {
        alerts.retain(|alert| alert.severity == severity);
        alerts.truncate(limit as usize);
    }

    Ok(Json(alerts))
}
