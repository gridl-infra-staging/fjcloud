//! Index suggestions route handlers.
use super::*;

/// `GET /indexes/{name}/suggestions` — retrieve query suggestions config.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Rejects cold/restoring indexes (503). Returns the current query
/// suggestions configuration from flapjack.
#[utoipa::path(
    get,
    path = "/indexes/{name}/suggestions",
    tag = "Suggestions",
    params(("name" = String, Path, description = "Index name")),
    responses(
        (status = 200, description = "Query suggestions configuration", body = serde_json::Value),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
    )
)]
pub async fn get_qs_config(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
) -> Result<impl IntoResponse, ApiError> {
    let (_, target) = super::resolve_ready_index_target(
        &state,
        auth.customer_id,
        &name,
        super::IndexNotReadyBehavior::ServiceUnavailable,
    )
    .await?;

    let result = state
        .flapjack_proxy
        .get_qs_config(
            &target.flapjack_url,
            &target.node_id,
            &target.region,
            &target.flapjack_uid,
        )
        .await?;

    Ok(Json(result))
}

/// `PUT /indexes/{name}/suggestions` — create or update query suggestions config.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Rejects cold/restoring indexes (503). Upserts the query suggestions
/// configuration in flapjack with the provided JSON body.
#[utoipa::path(
    put,
    path = "/indexes/{name}/suggestions",
    tag = "Suggestions",
    params(("name" = String, Path, description = "Index name")),
    responses(
        (status = 200, description = "Configuration saved", body = serde_json::Value),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = ErrorResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
    )
)]
pub async fn save_qs_config(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
    Json(body): Json<serde_json::Value>,
) -> Result<impl IntoResponse, ApiError> {
    let (_, target) = super::resolve_ready_index_target(
        &state,
        auth.customer_id,
        &name,
        super::IndexNotReadyBehavior::ServiceUnavailable,
    )
    .await?;

    let result = state
        .flapjack_proxy
        .upsert_qs_config(
            &target.flapjack_url,
            &target.node_id,
            &target.region,
            &target.flapjack_uid,
            body,
        )
        .await?;

    Ok(Json(result))
}

/// `DELETE /indexes/{name}/suggestions` — delete query suggestions config.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Rejects cold/restoring indexes (503). Removes the query suggestions
/// configuration from flapjack for this index.
#[utoipa::path(
    delete,
    path = "/indexes/{name}/suggestions",
    tag = "Suggestions",
    params(("name" = String, Path, description = "Index name")),
    responses(
        (status = 200, description = "Configuration deleted", body = serde_json::Value),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
    )
)]
pub async fn delete_qs_config(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
) -> Result<impl IntoResponse, ApiError> {
    let (_, target) = super::resolve_ready_index_target(
        &state,
        auth.customer_id,
        &name,
        super::IndexNotReadyBehavior::ServiceUnavailable,
    )
    .await?;

    let result = state
        .flapjack_proxy
        .delete_qs_config(
            &target.flapjack_url,
            &target.node_id,
            &target.region,
            &target.flapjack_uid,
        )
        .await?;

    Ok(Json(result))
}

/// `GET /indexes/{name}/suggestions/status` — query suggestions build status.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Rejects cold/restoring indexes (503). Returns the current build status
/// of the query suggestions model from flapjack.
#[utoipa::path(
    get,
    path = "/indexes/{name}/suggestions/status",
    tag = "Suggestions",
    params(("name" = String, Path, description = "Index name")),
    responses(
        (status = 200, description = "Query suggestions build status", body = serde_json::Value),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
    )
)]
pub async fn get_qs_status(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
) -> Result<impl IntoResponse, ApiError> {
    let (_, target) = super::resolve_ready_index_target(
        &state,
        auth.customer_id,
        &name,
        super::IndexNotReadyBehavior::ServiceUnavailable,
    )
    .await?;

    let result = state
        .flapjack_proxy
        .get_qs_status(
            &target.flapjack_url,
            &target.node_id,
            &target.region,
            &target.flapjack_uid,
        )
        .await?;

    Ok(Json(result))
}
