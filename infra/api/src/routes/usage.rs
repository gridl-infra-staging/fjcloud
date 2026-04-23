//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/routes/usage.rs.
use axum::extract::{Query, State};
use axum::response::IntoResponse;
use axum::Json;
use chrono::{Datelike, NaiveDate, Utc};
use serde::Deserialize;

use crate::auth::AuthenticatedTenant;
use crate::errors::ApiError;
use crate::state::AppState;
use crate::usage::{aggregate_monthly, DailyUsageEntry};

#[derive(Debug, Deserialize, utoipa::IntoParams)]
pub struct UsageQuery {
    /// Billing month in YYYY-MM format (defaults to current month).
    pub month: Option<String>,
}

/// Parse a "YYYY-MM" string into (first_day, last_day) of that month.
pub fn parse_month(month: &str) -> Result<(NaiveDate, NaiveDate), ApiError> {
    let parts: Vec<&str> = month.split('-').collect();
    if parts.len() != 2 {
        return Err(ApiError::BadRequest(
            "invalid month format, expected YYYY-MM".into(),
        ));
    }

    let year: i32 = parts[0]
        .parse()
        .map_err(|_| ApiError::BadRequest("invalid month format, expected YYYY-MM".into()))?;
    let month_num: u32 = parts[1]
        .parse()
        .map_err(|_| ApiError::BadRequest("invalid month format, expected YYYY-MM".into()))?;

    let start = NaiveDate::from_ymd_opt(year, month_num, 1)
        .ok_or_else(|| ApiError::BadRequest("invalid month format, expected YYYY-MM".into()))?;

    // Last day of month: go to next month day 1, subtract 1 day
    let end = if month_num == 12 {
        NaiveDate::from_ymd_opt(year + 1, 1, 1)
    } else {
        NaiveDate::from_ymd_opt(year, month_num + 1, 1)
    }
    .ok_or_else(|| ApiError::BadRequest("invalid month format, expected YYYY-MM".into()))?
    .pred_opt()
    .ok_or_else(|| ApiError::BadRequest("invalid month format, expected YYYY-MM".into()))?;

    Ok((start, end))
}

/// Default month string from current UTC time.
pub fn default_month() -> String {
    let now = Utc::now();
    format!("{:04}-{:02}", now.year(), now.month())
}

/// GET /usage — monthly usage summary for the authenticated tenant.
#[utoipa::path(
    get,
    path = "/usage",
    tag = "Usage",
    params(UsageQuery),
    responses(
        (status = 200, description = "Monthly usage summary", body = crate::usage::UsageSummaryResponse),
        (status = 400, description = "Bad request", body = crate::errors::ErrorResponse),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
    )
)]
pub async fn get_usage(
    tenant: AuthenticatedTenant,
    State(state): State<AppState>,
    Query(query): Query<UsageQuery>,
) -> Result<impl IntoResponse, ApiError> {
    let month = query.month.unwrap_or_else(default_month);
    let (start_date, end_date) = parse_month(&month)?;

    let rows = state
        .usage_repo
        .get_daily_usage(tenant.customer_id, start_date, end_date)
        .await?;

    let summary = aggregate_monthly(&rows, &month);
    Ok(Json(summary))
}

/// GET /usage/daily — daily usage entries for the authenticated tenant.
#[utoipa::path(
    get,
    path = "/usage/daily",
    tag = "Usage",
    params(UsageQuery),
    responses(
        (status = 200, description = "Daily usage entries", body = Vec<crate::usage::DailyUsageEntry>),
        (status = 400, description = "Bad request", body = crate::errors::ErrorResponse),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
    )
)]
pub async fn get_usage_daily(
    tenant: AuthenticatedTenant,
    State(state): State<AppState>,
    Query(query): Query<UsageQuery>,
) -> Result<impl IntoResponse, ApiError> {
    let month = query.month.unwrap_or_else(default_month);
    let (start_date, end_date) = parse_month(&month)?;

    let rows = state
        .usage_repo
        .get_daily_usage(tenant.customer_id, start_date, end_date)
        .await?;

    let entries: Vec<DailyUsageEntry> = rows.iter().map(DailyUsageEntry::from_row).collect();
    Ok(Json(entries))
}
