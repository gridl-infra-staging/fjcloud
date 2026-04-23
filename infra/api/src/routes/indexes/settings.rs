//! Index settings route handlers.
use super::*;

/// `GET /indexes/{name}/settings` — retrieve index settings.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Uses `IndexNotReadyBehavior::BadRequest` (returns 400 instead of 503
/// when the index is not yet placed). Fetches the full settings object
/// from flapjack.
#[utoipa::path(
    get,
    path = "/indexes/{name}/settings",
    tag = "Configuration",
    params(("name" = String, Path, description = "Index name")),
    responses(
        (status = 200, description = "Index settings (JSON from search engine)", body = serde_json::Value),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
    )
)]
pub async fn get_settings(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
) -> Result<impl IntoResponse, ApiError> {
    let (_, target) = super::resolve_ready_index_target(
        &state,
        auth.customer_id,
        &name,
        super::IndexNotReadyBehavior::BadRequest,
    )
    .await?;

    let settings = state
        .flapjack_proxy
        .get_index_settings(
            &target.flapjack_url,
            &target.node_id,
            &target.region,
            &target.flapjack_uid,
        )
        .await?;

    Ok(Json(settings))
}

/// `PUT /indexes/{name}/settings` — update index settings.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Validates that the body is a JSON object (rejects arrays, strings, etc.),
/// rejects cold/restoring indexes (503), then forwards the settings
/// object to flapjack.
#[utoipa::path(
    put,
    path = "/indexes/{name}/settings",
    tag = "Configuration",
    params(("name" = String, Path, description = "Index name")),
    responses(
        (status = 200, description = "Settings updated", body = serde_json::Value),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
    )
)]
pub async fn update_settings(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
    Json(body): Json<serde_json::Value>,
) -> Result<impl IntoResponse, ApiError> {
    if !body.is_object() {
        return Err(ApiError::BadRequest(
            "settings must be a JSON object".into(),
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
        .update_index_settings(
            &target.flapjack_url,
            &target.node_id,
            &target.region,
            &target.flapjack_uid,
            body,
        )
        .await?;

    Ok(Json(result))
}
