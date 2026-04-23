//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar25_am_3_customer_multitenant_multiregion_coverage/fjcloud_dev/infra/api/src/routes/indexes/chat.rs.
use super::*;

/// `POST /indexes/{name}/chat` — non-streaming chat over an index.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Validates the body is a JSON object, rejects streaming requests
/// (`stream: true` or `Accept: text/event-stream` header). Rejects
/// cold/restoring indexes (503). Forwards the chat body to flapjack
/// and returns the response.
#[utoipa::path(
    post,
    path = "/indexes/{name}/chat",
    tag = "Chat",
    params(("name" = String, Path, description = "Index name")),
    responses(
        (status = 200, description = "Chat response", body = serde_json::Value),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
    )
)]
pub async fn chat(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
    headers: axum::http::HeaderMap,
    Json(body): Json<serde_json::Value>,
) -> Result<impl IntoResponse, ApiError> {
    if !body.is_object() {
        return Err(ApiError::BadRequest(
            "chat request must be a JSON object".into(),
        ));
    }

    let stream_requested = body
        .get("stream")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);
    let accepts_event_stream = headers
        .get(axum::http::header::ACCEPT)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| value.to_ascii_lowercase().contains("text/event-stream"));

    if stream_requested || accepts_event_stream {
        return Err(ApiError::BadRequest(
            "streaming chat is not supported in fjcloud".into(),
        ));
    }

    let (_, target) = super::resolve_ready_index_target(
        &state,
        auth.customer_id,
        &name,
        super::IndexNotReadyBehavior::ServiceUnavailable,
    )
    .await?;

    let result = state
        .flapjack_proxy
        .chat(
            &target.flapjack_url,
            &target.node_id,
            &target.region,
            &target.flapjack_uid,
            body,
        )
        .await?;

    Ok(Json(result))
}
