use super::*;

const VALID_DICTIONARY_NAMES: &[&str] = &["stopwords", "plurals", "compounds"];

fn validate_dictionary_name(name: &str) -> Result<(), ApiError> {
    if !VALID_DICTIONARY_NAMES.contains(&name) {
        return Err(ApiError::BadRequest(format!(
            "invalid dictionary name '{name}'; must be one of: stopwords, plurals, compounds"
        )));
    }
    Ok(())
}

/// GET /indexes/:name/dictionaries/languages — list available languages.
#[utoipa::path(
    get,
    path = "/indexes/{name}/dictionaries/languages",
    tag = "Configuration",
    params(("name" = String, Path, description = "Index name")),
    responses(
        (status = 200, description = "Available dictionary languages", body = serde_json::Value),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
    )
)]
pub async fn get_dictionary_languages(
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
        .get_dictionary_languages(&target.flapjack_url, &target.node_id, &target.region)
        .await?;

    Ok(Json(result))
}

/// POST /indexes/:name/dictionaries/:dictionary_name/search — search dictionary entries.
#[utoipa::path(
    post,
    path = "/indexes/{name}/dictionaries/{dictionary_name}/search",
    tag = "Configuration",
    params(
        ("name" = String, Path, description = "Index name"),
        ("dictionary_name" = String, Path, description = "Dictionary name (stopwords, plurals, compounds)"),
    ),
    responses(
        (status = 200, description = "Dictionary search results", body = serde_json::Value),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
    )
)]
pub async fn search_dictionary_entries(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path((name, dictionary_name)): Path<(String, String)>,
    Json(body): Json<serde_json::Value>,
) -> Result<impl IntoResponse, ApiError> {
    validate_dictionary_name(&dictionary_name)?;

    let (_, target) = super::resolve_ready_index_target(
        &state,
        auth.customer_id,
        &name,
        super::IndexNotReadyBehavior::ServiceUnavailable,
    )
    .await?;

    let result = state
        .flapjack_proxy
        .search_dictionary_entries(
            &target.flapjack_url,
            &target.node_id,
            &target.region,
            &dictionary_name,
            body,
        )
        .await?;

    Ok(Json(result))
}

/// POST /indexes/:name/dictionaries/:dictionary_name/batch — batch add/delete entries.
#[utoipa::path(
    post,
    path = "/indexes/{name}/dictionaries/{dictionary_name}/batch",
    tag = "Configuration",
    params(
        ("name" = String, Path, description = "Index name"),
        ("dictionary_name" = String, Path, description = "Dictionary name (stopwords, plurals, compounds)"),
    ),
    responses(
        (status = 200, description = "Batch operation results", body = serde_json::Value),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
    )
)]
pub async fn batch_dictionary_entries(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path((name, dictionary_name)): Path<(String, String)>,
    Json(body): Json<serde_json::Value>,
) -> Result<impl IntoResponse, ApiError> {
    validate_dictionary_name(&dictionary_name)?;

    let (_, target) = super::resolve_ready_index_target(
        &state,
        auth.customer_id,
        &name,
        super::IndexNotReadyBehavior::ServiceUnavailable,
    )
    .await?;

    let result = state
        .flapjack_proxy
        .batch_dictionary_entries(
            &target.flapjack_url,
            &target.node_id,
            &target.region,
            &dictionary_name,
            body,
        )
        .await?;

    Ok(Json(result))
}

/// GET /indexes/:name/dictionaries/settings — get dictionary settings.
#[utoipa::path(
    get,
    path = "/indexes/{name}/dictionaries/settings",
    tag = "Configuration",
    params(("name" = String, Path, description = "Index name")),
    responses(
        (status = 200, description = "Dictionary settings", body = serde_json::Value),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
    )
)]
pub async fn get_dictionary_settings(
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
        .get_dictionary_settings(&target.flapjack_url, &target.node_id, &target.region)
        .await?;

    Ok(Json(result))
}

/// PUT /indexes/:name/dictionaries/settings — save dictionary settings.
#[utoipa::path(
    put,
    path = "/indexes/{name}/dictionaries/settings",
    tag = "Configuration",
    params(("name" = String, Path, description = "Index name")),
    responses(
        (status = 200, description = "Dictionary settings saved", body = serde_json::Value),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
    )
)]
pub async fn save_dictionary_settings(
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
        .save_dictionary_settings(&target.flapjack_url, &target.node_id, &target.region, body)
        .await?;

    Ok(Json(result))
}
