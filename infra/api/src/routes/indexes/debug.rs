use super::*;

pub const SEARCH_PREVIEW_RESULT_OPENED_EVENT: &str = "search_preview_result_opened";

#[derive(Debug, Deserialize, utoipa::ToSchema)]
#[serde(rename_all = "camelCase")]
pub struct PreviewEventRequest {
    pub event_name: String,
    #[serde(rename = "objectID")]
    pub object_id: String,
    pub position: u32,
    #[serde(rename = "queryID")]
    pub query_id: String,
    pub timestamp: i64,
    pub user_token: String,
}

/// `POST /indexes/{name}/events` — submit one query-correlated preview click.
///
/// The route derives the tenant-scoped engine index and intentionally exposes
/// no generic event forwarding surface to dashboard callers.
#[utoipa::path(
    post,
    path = "/indexes/{name}/events",
    tag = "Debug",
    params(("name" = String, Path, description = "Index name")),
    request_body = PreviewEventRequest,
    responses(
        (status = 200, description = "Event accepted", body = serde_json::Value),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = ErrorResponse),
    )
)]
pub async fn post_preview_event(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
    Json(request): Json<PreviewEventRequest>,
) -> Result<impl IntoResponse, ApiError> {
    if request.event_name != SEARCH_PREVIEW_RESULT_OPENED_EVENT {
        return Err(ApiError::BadRequest(
            "unsupported preview event name".into(),
        ));
    }
    if request.object_id.trim().is_empty()
        || request.query_id.trim().is_empty()
        || request.user_token.trim().is_empty()
        || request.position == 0
        || request.timestamp <= 0
    {
        return Err(ApiError::BadRequest(
            "preview event correlation fields must be non-empty and positive".into(),
        ));
    }

    let (_, target) = super::resolve_ready_index_target(
        &state,
        auth.customer_id,
        &name,
        super::IndexNotReadyBehavior::ServiceUnavailable,
    )
    .await?;

    let event = serde_json::json!({
        "events": [{
            "eventType": "click",
            "eventName": SEARCH_PREVIEW_RESULT_OPENED_EVENT,
            "index": target.flapjack_uid,
            "userToken": request.user_token,
            "queryID": request.query_id,
            "objectIDs": [request.object_id],
            "positions": [request.position],
            "timestamp": request.timestamp,
        }]
    });
    let result = state
        .flapjack_proxy
        .post_preview_event(&target.flapjack_url, &target.node_id, &target.region, event)
        .await?;

    Ok(Json(result))
}

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
