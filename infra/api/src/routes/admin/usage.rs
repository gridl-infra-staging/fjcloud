use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;
use chrono::NaiveDate;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::auth::AdminAuth;
use crate::errors::ApiError;
use crate::helpers::require_active_customer;
use crate::repos::usage_repo::{AdminUsageMutation, DailyUsageWrite};
use crate::routes::usage::{default_month, parse_month, UsageQuery};
use crate::state::AppState;
use crate::usage::aggregate_monthly;

const MAX_DAILY_USAGE_ENTRIES_PER_REQUEST: usize = 31;
const MAX_USAGE_REGION_LENGTH: usize = 128;

#[derive(Debug, Deserialize)]
pub struct AdminDailyUsageEntry {
    pub date: NaiveDate,
    pub region: String,
    pub search_requests: i64,
    pub write_operations: i64,
    pub storage_bytes_avg: i64,
    pub documents_count_avg: i64,
}

#[derive(Debug, Deserialize)]
pub struct SeedDailyUsageRequest {
    pub entries: Vec<AdminDailyUsageEntry>,
}

#[derive(Debug, Serialize)]
pub struct SeedDailyUsageResponse {
    pub seeded_rows: u64,
}

#[derive(Debug, Deserialize)]
pub struct DeleteDailyUsageRequest {
    pub month: String,
    pub region: String,
}

fn validate_region(region: &str) -> Result<(), ApiError> {
    if region.trim().is_empty() || region.len() > MAX_USAGE_REGION_LENGTH {
        return Err(ApiError::BadRequest(format!(
            "region must contain 1-{MAX_USAGE_REGION_LENGTH} characters"
        )));
    }
    Ok(())
}

fn validated_usage_writes(
    request: SeedDailyUsageRequest,
) -> Result<Vec<DailyUsageWrite>, ApiError> {
    if request.entries.is_empty() || request.entries.len() > MAX_DAILY_USAGE_ENTRIES_PER_REQUEST {
        return Err(ApiError::BadRequest(format!(
            "entries must contain 1-{MAX_DAILY_USAGE_ENTRIES_PER_REQUEST} daily rows"
        )));
    }

    request
        .entries
        .into_iter()
        .map(|entry| {
            validate_region(&entry.region)?;
            if [
                entry.search_requests,
                entry.write_operations,
                entry.storage_bytes_avg,
                entry.documents_count_avg,
            ]
            .into_iter()
            .any(|value| value < 0)
            {
                return Err(ApiError::BadRequest(
                    "daily usage values must be non-negative".into(),
                ));
            }
            Ok(DailyUsageWrite {
                date: entry.date,
                region: entry.region,
                search_requests: entry.search_requests,
                write_operations: entry.write_operations,
                storage_bytes_avg: entry.storage_bytes_avg,
                documents_count_avg: entry.documents_count_avg,
            })
        })
        .collect()
}

/// `GET /admin/tenants/{id}/usage` — retrieve aggregated monthly usage for a customer.
///
/// **Auth:** `AdminAuth`.
/// Requires the customer to be active. Parses the `month` query param
/// (YYYY-MM, defaults to current month), fetches daily usage rows, and
/// returns the aggregated monthly summary.
pub async fn get_tenant_usage(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Path(customer_id): Path<Uuid>,
    Query(query): Query<UsageQuery>,
) -> Result<impl IntoResponse, ApiError> {
    require_active_customer(state.customer_repo.as_ref(), customer_id).await?;

    let month = query.month.unwrap_or_else(default_month);
    let (start_date, end_date) = parse_month(&month)?;

    let rows = state
        .usage_repo
        .get_daily_usage(customer_id, start_date, end_date)
        .await?;

    let summary = aggregate_monthly(&rows, &month);
    Ok(Json(summary))
}

/// `POST /admin/tenants/{id}/usage` — atomically upsert daily usage rows.
pub async fn seed_tenant_usage(
    auth: AdminAuth,
    State(state): State<AppState>,
    Path(customer_id): Path<Uuid>,
    Json(request): Json<SeedDailyUsageRequest>,
) -> Result<impl IntoResponse, ApiError> {
    require_active_customer(state.customer_repo.as_ref(), customer_id).await?;
    let entries = validated_usage_writes(request)?;
    let mutation = AdminUsageMutation {
        operator_id: auth.operator_id,
        customer_id,
    };
    let seeded_rows = state
        .usage_repo
        .upsert_daily_usage(mutation, &entries)
        .await?;

    Ok((
        StatusCode::CREATED,
        Json(SeedDailyUsageResponse { seeded_rows }),
    ))
}

/// `DELETE /admin/tenants/{id}/usage` — delete one region's usage for a month.
pub async fn delete_tenant_usage(
    auth: AdminAuth,
    State(state): State<AppState>,
    Path(customer_id): Path<Uuid>,
    Json(request): Json<DeleteDailyUsageRequest>,
) -> Result<impl IntoResponse, ApiError> {
    require_active_customer(state.customer_repo.as_ref(), customer_id).await?;
    validate_region(&request.region)?;
    let (start_date, end_date) = parse_month(&request.month)?;
    let mutation = AdminUsageMutation {
        operator_id: auth.operator_id,
        customer_id,
    };
    state
        .usage_repo
        .delete_daily_usage(
            mutation,
            start_date,
            end_date,
            &request.month,
            &request.region,
        )
        .await?;

    Ok(StatusCode::NO_CONTENT)
}
