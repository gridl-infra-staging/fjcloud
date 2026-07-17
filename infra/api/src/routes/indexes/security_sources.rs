use super::*;
use crate::validation::validate_path_value_for_encoding;

/// GET /indexes/:name/security/sources
#[utoipa::path(
    get,
    path = "/indexes/{name}/security/sources",
    tag = "Security",
    params(("name" = String, Path, description = "Index name")),
    responses(
        (status = 200, description = "Security sources list", body = serde_json::Value),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
    )
)]
pub async fn get_security_sources(
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
        .get_security_sources(&target.flapjack_url, &target.node_id, &target.region)
        .await?;

    Ok(Json(result))
}

/// POST /indexes/:name/security/sources
#[utoipa::path(
    post,
    path = "/indexes/{name}/security/sources",
    tag = "Security",
    params(("name" = String, Path, description = "Index name")),
    responses(
        (status = 200, description = "Security source appended", body = serde_json::Value),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
    )
)]
pub async fn append_security_source(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
    Json(body): Json<serde_json::Value>,
) -> Result<impl IntoResponse, ApiError> {
    if !body.is_object() {
        return Err(ApiError::BadRequest(
            "security source must be a JSON object".into(),
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
        .append_security_source(&target.flapjack_url, &target.node_id, &target.region, body)
        .await?;

    Ok(Json(result))
}

/// DELETE /indexes/:name/security/sources/:source
#[utoipa::path(
    delete,
    path = "/indexes/{name}/security/sources/{source}",
    tag = "Security",
    params(
        ("name" = String, Path, description = "Index name"),
        ("source" = String, Path, description = "Security source identifier"),
    ),
    responses(
        (status = 200, description = "Security source deleted", body = serde_json::Value),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = ErrorResponse),
        (status = 404, description = "Index or source not found", body = ErrorResponse),
    )
)]
pub async fn delete_security_source(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path((name, source)): Path<(String, String)>,
) -> Result<impl IntoResponse, ApiError> {
    validate_path_value_for_encoding("source", &source)?;

    let (_, target) = super::resolve_ready_index_target(
        &state,
        auth.customer_id,
        &name,
        super::IndexNotReadyBehavior::ServiceUnavailable,
    )
    .await?;

    let result = state
        .flapjack_proxy
        .delete_security_source(
            &target.flapjack_url,
            &target.node_id,
            &target.region,
            &source,
        )
        .await?;

    Ok(Json(result))
}
