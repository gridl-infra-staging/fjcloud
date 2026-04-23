//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/routes/admin/usage.rs.
use axum::extract::{Path, Query, State};
use axum::response::IntoResponse;
use axum::Json;
use uuid::Uuid;

use crate::auth::AdminAuth;
use crate::errors::ApiError;
use crate::helpers::require_active_customer;
use crate::routes::usage::{default_month, parse_month, UsageQuery};
use crate::state::AppState;
use crate::usage::aggregate_monthly;

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
