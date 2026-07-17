use super::*;
use crate::validation::validate_path_value_for_encoding;

/// GET /indexes/:name/personalization/strategy
#[utoipa::path(
    get,
    path = "/indexes/{name}/personalization/strategy",
    tag = "Personalization",
    params(("name" = String, Path, description = "Index name")),
    responses(
        (status = 200, description = "Personalization strategy", body = serde_json::Value),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
    )
)]
pub async fn get_personalization_strategy(
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
        .get_personalization_strategy(&target.flapjack_url, &target.node_id, &target.region)
        .await?;

    Ok(Json(result))
}

/// PUT /indexes/:name/personalization/strategy
#[utoipa::path(
    put,
    path = "/indexes/{name}/personalization/strategy",
    tag = "Personalization",
    params(("name" = String, Path, description = "Index name")),
    responses(
        (status = 200, description = "Strategy saved", body = serde_json::Value),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
    )
)]
pub async fn save_personalization_strategy(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
    Json(body): Json<serde_json::Value>,
) -> Result<impl IntoResponse, ApiError> {
    if !body.is_object() {
        return Err(ApiError::BadRequest(
            "personalization strategy must be a JSON object".into(),
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
        .save_personalization_strategy(&target.flapjack_url, &target.node_id, &target.region, body)
        .await?;

    Ok(Json(result))
}

/// DELETE /indexes/:name/personalization/strategy
#[utoipa::path(
    delete,
    path = "/indexes/{name}/personalization/strategy",
    tag = "Personalization",
    params(("name" = String, Path, description = "Index name")),
    responses(
        (status = 200, description = "Strategy deleted", body = serde_json::Value),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
    )
)]
pub async fn delete_personalization_strategy(
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
        .delete_personalization_strategy(&target.flapjack_url, &target.node_id, &target.region)
        .await?;

    Ok(Json(result))
}

/// GET /indexes/:name/personalization/profiles/:user_token
#[utoipa::path(
    get,
    path = "/indexes/{name}/personalization/profiles/{user_token}",
    tag = "Personalization",
    params(
        ("name" = String, Path, description = "Index name"),
        ("user_token" = String, Path, description = "User token"),
    ),
    responses(
        (status = 200, description = "User personalization profile", body = serde_json::Value),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
    )
)]
pub async fn get_personalization_profile(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path((name, user_token)): Path<(String, String)>,
) -> Result<impl IntoResponse, ApiError> {
    validate_path_value_for_encoding("user_token", &user_token)?;

    let (_, target) = super::resolve_ready_index_target(
        &state,
        auth.customer_id,
        &name,
        super::IndexNotReadyBehavior::ServiceUnavailable,
    )
    .await?;

    let result = state
        .flapjack_proxy
        .get_personalization_profile(
            &target.flapjack_url,
            &target.node_id,
            &target.region,
            &user_token,
        )
        .await?;

    Ok(Json(result))
}

/// DELETE /indexes/:name/personalization/profiles/:user_token
#[utoipa::path(
    delete,
    path = "/indexes/{name}/personalization/profiles/{user_token}",
    tag = "Personalization",
    params(
        ("name" = String, Path, description = "Index name"),
        ("user_token" = String, Path, description = "User token"),
    ),
    responses(
        (status = 200, description = "Profile deleted", body = serde_json::Value),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
    )
)]
pub async fn delete_personalization_profile(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path((name, user_token)): Path<(String, String)>,
) -> Result<impl IntoResponse, ApiError> {
    validate_path_value_for_encoding("user_token", &user_token)?;

    let (_, target) = super::resolve_ready_index_target(
        &state,
        auth.customer_id,
        &name,
        super::IndexNotReadyBehavior::ServiceUnavailable,
    )
    .await?;

    let result = state
        .flapjack_proxy
        .delete_personalization_profile(
            &target.flapjack_url,
            &target.node_id,
            &target.region,
            &user_token,
        )
        .await?;

    Ok(Json(result))
}
