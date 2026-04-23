//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar25_am_3_customer_multitenant_multiregion_coverage/fjcloud_dev/infra/api/src/routes/indexes/synonyms.rs.
use super::*;

#[derive(Debug, Deserialize, utoipa::ToSchema)]
#[serde(rename_all = "camelCase")]
pub struct SynonymsSearchRequest {
    #[serde(default)]
    pub query: String,
    #[serde(rename = "type")]
    pub synonym_type: Option<String>,
    #[serde(default)]
    pub page: usize,
    #[serde(default = "default_hits_per_page")]
    pub hits_per_page: usize,
}

/// `POST /indexes/{name}/synonyms/search` — search synonym entries.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Rejects cold/restoring indexes (503). Forwards `query`, optional
/// `synonym_type` filter, `page`, and `hits_per_page` to flapjack's
/// synonyms search endpoint using the tenant-scoped UID.
#[utoipa::path(
    post,
    path = "/indexes/{name}/synonyms/search",
    tag = "Configuration",
    params(("name" = String, Path, description = "Index name")),
    request_body = SynonymsSearchRequest,
    responses(
        (status = 200, description = "Synonyms search results", body = serde_json::Value),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
    )
)]
pub async fn search_synonyms(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
    Json(req): Json<SynonymsSearchRequest>,
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
        .search_synonyms(
            &target.flapjack_url,
            &target.node_id,
            &target.region,
            &target.flapjack_uid,
            &req.query,
            req.synonym_type.as_deref(),
            req.page,
            req.hits_per_page,
        )
        .await?;

    Ok(Json(result))
}

/// `GET /indexes/{name}/synonyms/{object_id}` — retrieve a single synonym.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Validates `object_id` path segment, rejects cold/restoring indexes (503),
/// then fetches the synonym from flapjack by its tenant-scoped UID.
#[utoipa::path(
    get,
    path = "/indexes/{name}/synonyms/{object_id}",
    tag = "Configuration",
    params(
        ("name" = String, Path, description = "Index name"),
        ("object_id" = String, Path, description = "Synonym object ID"),
    ),
    responses(
        (status = 200, description = "Synonym details", body = serde_json::Value),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = ErrorResponse),
        (status = 404, description = "Index or synonym not found", body = ErrorResponse),
    )
)]
pub async fn get_synonym(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path((name, object_id)): Path<(String, String)>,
) -> Result<impl IntoResponse, ApiError> {
    validate_path_segment("object_id", &object_id)?;

    let (_, target) = super::resolve_ready_index_target(
        &state,
        auth.customer_id,
        &name,
        super::IndexNotReadyBehavior::ServiceUnavailable,
    )
    .await?;

    let result = state
        .flapjack_proxy
        .get_synonym(
            &target.flapjack_url,
            &target.node_id,
            &target.region,
            &target.flapjack_uid,
            &object_id,
        )
        .await?;

    Ok(Json(result))
}

/// `PUT /indexes/{name}/synonyms/{object_id}` — create or update a synonym.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Validates `object_id` path segment, rejects cold/restoring indexes (503),
/// then upserts the synonym in flapjack with the provided JSON body.
#[utoipa::path(
    put,
    path = "/indexes/{name}/synonyms/{object_id}",
    tag = "Configuration",
    params(
        ("name" = String, Path, description = "Index name"),
        ("object_id" = String, Path, description = "Synonym object ID"),
    ),
    responses(
        (status = 200, description = "Synonym saved", body = serde_json::Value),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
    )
)]
pub async fn save_synonym(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path((name, object_id)): Path<(String, String)>,
    Json(body): Json<serde_json::Value>,
) -> Result<impl IntoResponse, ApiError> {
    validate_path_segment("object_id", &object_id)?;

    let (_, target) = super::resolve_ready_index_target(
        &state,
        auth.customer_id,
        &name,
        super::IndexNotReadyBehavior::ServiceUnavailable,
    )
    .await?;

    let result = state
        .flapjack_proxy
        .save_synonym(
            &target.flapjack_url,
            &target.node_id,
            &target.region,
            &target.flapjack_uid,
            &object_id,
            body,
        )
        .await?;

    Ok(Json(result))
}

/// `DELETE /indexes/{name}/synonyms/{object_id}` — delete a synonym.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Validates `object_id` path segment, rejects cold/restoring indexes (503),
/// then deletes the synonym from flapjack by its tenant-scoped UID.
#[utoipa::path(
    delete,
    path = "/indexes/{name}/synonyms/{object_id}",
    tag = "Configuration",
    params(
        ("name" = String, Path, description = "Index name"),
        ("object_id" = String, Path, description = "Synonym object ID"),
    ),
    responses(
        (status = 200, description = "Synonym deleted", body = serde_json::Value),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = ErrorResponse),
        (status = 404, description = "Index or synonym not found", body = ErrorResponse),
    )
)]
pub async fn delete_synonym(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path((name, object_id)): Path<(String, String)>,
) -> Result<impl IntoResponse, ApiError> {
    validate_path_segment("object_id", &object_id)?;

    let (_, target) = super::resolve_ready_index_target(
        &state,
        auth.customer_id,
        &name,
        super::IndexNotReadyBehavior::ServiceUnavailable,
    )
    .await?;

    let result = state
        .flapjack_proxy
        .delete_synonym(
            &target.flapjack_url,
            &target.node_id,
            &target.region,
            &target.flapjack_uid,
            &object_id,
        )
        .await?;

    Ok(Json(result))
}
