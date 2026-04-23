//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar25_am_3_customer_multitenant_multiregion_coverage/fjcloud_dev/infra/api/src/routes/indexes/debug.rs.
use super::*;

/// Strip `index` (server-controlled) from customer-supplied query, pass rest through.
fn build_debug_events_query(raw_query: Option<&str>) -> String {
    let mut params = parse_query_pairs(raw_query);
    params.retain(|(key, _)| key != "index");
    encode_query_pairs(&params)
}

/// `GET /indexes/{name}/events/debug` — retrieve debug events for an index.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Rejects cold/restoring indexes (503). Strips the server-controlled
/// `index` query parameter, passes remaining query params through to
/// flapjack's debug events endpoint.
#[utoipa::path(
    get,
    path = "/indexes/{name}/events/debug",
    tag = "Debug",
    params(("name" = String, Path, description = "Index name")),
    responses(
        (status = 200, description = "Debug events", body = serde_json::Value),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = crate::errors::ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = crate::errors::ErrorResponse),
        (status = 404, description = "Index not found", body = crate::errors::ErrorResponse),
    )
)]
pub async fn get_debug_events(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
    RawQuery(raw_query): RawQuery,
) -> Result<impl IntoResponse, ApiError> {
    let (_, target) = super::resolve_ready_index_target(
        &state,
        auth.customer_id,
        &name,
        super::IndexNotReadyBehavior::ServiceUnavailable,
    )
    .await?;

    let query_params = build_debug_events_query(raw_query.as_deref());

    let result = state
        .flapjack_proxy
        .get_debug_events(
            &target.flapjack_url,
            &target.node_id,
            &target.region,
            &target.flapjack_uid,
            &query_params,
        )
        .await?;

    Ok(Json(result))
}
