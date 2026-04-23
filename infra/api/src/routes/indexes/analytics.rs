//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar25_am_3_customer_multitenant_multiregion_coverage/fjcloud_dev/infra/api/src/routes/indexes/analytics.rs.
use super::*;

fn parse_analytics_date(value: &str, field: &str) -> Result<NaiveDate, ApiError> {
    if value.len() != 10 {
        return Err(ApiError::BadRequest(format!(
            "{field} must be in YYYY-MM-DD format"
        )));
    }

    NaiveDate::parse_from_str(value, "%Y-%m-%d")
        .map_err(|_| ApiError::BadRequest(format!("{field} must be in YYYY-MM-DD format")))
}

/// Build a sanitized analytics query string from raw request parameters.
///
/// Strips the server-controlled `index` parameter, validates `startDate`
/// and `endDate` (YYYY-MM-DD format, end ≥ start, max 90-day span) when
/// `require_date_range` is true, and clamps `limit` to
/// `MAX_ANALYTICS_LIMIT` (1000).
fn validate_and_build_analytics_query(
    raw_query: Option<&str>,
    require_date_range: bool,
) -> Result<String, ApiError> {
    let mut params = parse_query_pairs(raw_query);
    params.retain(|(key, _)| key != "index");

    let start_date = params
        .iter()
        .find(|(key, _)| key == "startDate")
        .map(|(_, value)| value.as_str());
    let end_date = params
        .iter()
        .find(|(key, _)| key == "endDate")
        .map(|(_, value)| value.as_str());

    if require_date_range {
        let start_raw = start_date
            .ok_or_else(|| ApiError::BadRequest("startDate must be in YYYY-MM-DD format".into()))?;
        let end_raw = end_date
            .ok_or_else(|| ApiError::BadRequest("endDate must be in YYYY-MM-DD format".into()))?;

        let start = parse_analytics_date(start_raw, "startDate")?;
        let end = parse_analytics_date(end_raw, "endDate")?;

        if end < start {
            return Err(ApiError::BadRequest(
                "endDate must be on or after startDate".into(),
            ));
        }

        let range_days_inclusive = (end - start).num_days() + 1;
        if range_days_inclusive > MAX_ANALYTICS_DAYS {
            return Err(ApiError::BadRequest(format!(
                "date range must not exceed {MAX_ANALYTICS_DAYS} days"
            )));
        }
    }

    for (key, value) in &mut params {
        if key == "limit" {
            let parsed = value
                .parse::<u32>()
                .map_err(|_| ApiError::BadRequest("limit must be an integer".into()))?;
            *value = parsed.min(MAX_ANALYTICS_LIMIT).to_string();
        }
    }

    Ok(encode_query_pairs(&params))
}

/// Resolve the flapjack target and forward an analytics request.
///
/// Rejects cold/restoring indexes (503), validates the query string via
/// [`validate_and_build_analytics_query`], then delegates to
/// `flapjack_proxy.get_analytics` with the given `endpoint` suffix.
async fn proxy_analytics_endpoint(
    state: &AppState,
    customer_id: Uuid,
    index_name: &str,
    endpoint: &str,
    raw_query: Option<&str>,
    require_date_range: bool,
) -> Result<serde_json::Value, ApiError> {
    let (_, target) = super::resolve_ready_index_target(
        state,
        customer_id,
        index_name,
        super::IndexNotReadyBehavior::ServiceUnavailable,
    )
    .await?;

    let query_params = validate_and_build_analytics_query(raw_query, require_date_range)?;

    state
        .flapjack_proxy
        .get_analytics(
            &target.flapjack_url,
            &target.node_id,
            &target.region,
            endpoint,
            &target.flapjack_uid,
            &query_params,
        )
        .await
        .map_err(ApiError::from)
}

/// GET /indexes/:name/analytics/searches — top searches in date range.
#[utoipa::path(
    get,
    path = "/indexes/{name}/analytics/searches",
    tag = "Analytics",
    params(("name" = String, Path, description = "Index name")),
    responses(
        (status = 200, description = "Top searches in date range", body = serde_json::Value),
        (status = 400, description = "Bad request", body = crate::errors::ErrorResponse),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = crate::errors::ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = crate::errors::ErrorResponse),
        (status = 404, description = "Index not found", body = crate::errors::ErrorResponse),
    )
)]
pub async fn get_analytics_searches(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
    RawQuery(raw_query): RawQuery,
) -> Result<impl IntoResponse, ApiError> {
    let result = proxy_analytics_endpoint(
        &state,
        auth.customer_id,
        &name,
        "searches",
        raw_query.as_deref(),
        true,
    )
    .await?;

    Ok(Json(result))
}

/// GET /indexes/:name/analytics/searches/count — total searches + daily counts.
#[utoipa::path(
    get,
    path = "/indexes/{name}/analytics/searches/count",
    tag = "Analytics",
    params(("name" = String, Path, description = "Index name")),
    responses(
        (status = 200, description = "Total searches and daily counts", body = serde_json::Value),
        (status = 400, description = "Bad request", body = crate::errors::ErrorResponse),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = crate::errors::ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = crate::errors::ErrorResponse),
        (status = 404, description = "Index not found", body = crate::errors::ErrorResponse),
    )
)]
pub async fn get_analytics_searches_count(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
    RawQuery(raw_query): RawQuery,
) -> Result<impl IntoResponse, ApiError> {
    let result = proxy_analytics_endpoint(
        &state,
        auth.customer_id,
        &name,
        "searches/count",
        raw_query.as_deref(),
        true,
    )
    .await?;

    Ok(Json(result))
}

/// GET /indexes/:name/analytics/searches/noResults — top no-result queries.
#[utoipa::path(
    get,
    path = "/indexes/{name}/analytics/searches/noResults",
    tag = "Analytics",
    params(("name" = String, Path, description = "Index name")),
    responses(
        (status = 200, description = "Top no-result queries", body = serde_json::Value),
        (status = 400, description = "Bad request", body = crate::errors::ErrorResponse),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = crate::errors::ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = crate::errors::ErrorResponse),
        (status = 404, description = "Index not found", body = crate::errors::ErrorResponse),
    )
)]
pub async fn get_analytics_no_results(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
    RawQuery(raw_query): RawQuery,
) -> Result<impl IntoResponse, ApiError> {
    let result = proxy_analytics_endpoint(
        &state,
        auth.customer_id,
        &name,
        "searches/noResults",
        raw_query.as_deref(),
        true,
    )
    .await?;

    Ok(Json(result))
}

/// GET /indexes/:name/analytics/searches/noResultRate — no-result rate over time.
#[utoipa::path(
    get,
    path = "/indexes/{name}/analytics/searches/noResultRate",
    tag = "Analytics",
    params(("name" = String, Path, description = "Index name")),
    responses(
        (status = 200, description = "No-result rate over time", body = serde_json::Value),
        (status = 400, description = "Bad request", body = crate::errors::ErrorResponse),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = crate::errors::ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = crate::errors::ErrorResponse),
        (status = 404, description = "Index not found", body = crate::errors::ErrorResponse),
    )
)]
pub async fn get_analytics_no_result_rate(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
    RawQuery(raw_query): RawQuery,
) -> Result<impl IntoResponse, ApiError> {
    let result = proxy_analytics_endpoint(
        &state,
        auth.customer_id,
        &name,
        "searches/noResultRate",
        raw_query.as_deref(),
        true,
    )
    .await?;

    Ok(Json(result))
}

/// GET /indexes/:name/analytics/status — analytics status for index.
#[utoipa::path(
    get,
    path = "/indexes/{name}/analytics/status",
    tag = "Analytics",
    params(("name" = String, Path, description = "Index name")),
    responses(
        (status = 200, description = "Analytics status for index", body = serde_json::Value),
        (status = 400, description = "Bad request", body = crate::errors::ErrorResponse),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = crate::errors::ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = crate::errors::ErrorResponse),
        (status = 404, description = "Index not found", body = crate::errors::ErrorResponse),
    )
)]
pub async fn get_analytics_status(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
    RawQuery(raw_query): RawQuery,
) -> Result<impl IntoResponse, ApiError> {
    let result = proxy_analytics_endpoint(
        &state,
        auth.customer_id,
        &name,
        "status",
        raw_query.as_deref(),
        false,
    )
    .await?;

    Ok(Json(result))
}
