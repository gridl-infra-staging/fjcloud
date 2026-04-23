//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar25_am_3_customer_multitenant_multiregion_coverage/fjcloud_dev/infra/api/src/routes/indexes/rules.rs.
use super::*;

#[derive(Debug, Deserialize, utoipa::ToSchema)]
#[serde(rename_all = "camelCase")]
pub struct RulesSearchRequest {
    #[serde(default)]
    pub query: String,
    #[serde(default)]
    pub page: usize,
    #[serde(default = "default_hits_per_page")]
    pub hits_per_page: usize,
}

/// `POST /indexes/{name}/rules/search` — search ranking rules.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Rejects cold/restoring indexes (503). Forwards `query`, `page`, and
/// `hits_per_page` to flapjack's rules search endpoint using the
/// tenant-scoped UID.
#[utoipa::path(
    post,
    path = "/indexes/{name}/rules/search",
    tag = "Configuration",
    params(("name" = String, Path, description = "Index name")),
    request_body = RulesSearchRequest,
    responses(
        (status = 200, description = "Rules search results", body = serde_json::Value),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
    )
)]
pub async fn search_rules(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
    Json(req): Json<RulesSearchRequest>,
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
        .search_rules(
            &target.flapjack_url,
            &target.node_id,
            &target.region,
            &target.flapjack_uid,
            &req.query,
            req.page,
            req.hits_per_page,
        )
        .await?;

    Ok(Json(result))
}

/// `GET /indexes/{name}/rules/{object_id}` — retrieve a single rule.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Validates `object_id` path segment, rejects cold/restoring indexes (503),
/// then fetches the rule from flapjack by its tenant-scoped UID.
#[utoipa::path(
    get,
    path = "/indexes/{name}/rules/{object_id}",
    tag = "Configuration",
    params(
        ("name" = String, Path, description = "Index name"),
        ("object_id" = String, Path, description = "Rule object ID"),
    ),
    responses(
        (status = 200, description = "Rule details", body = serde_json::Value),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = ErrorResponse),
        (status = 404, description = "Index or rule not found", body = ErrorResponse),
    )
)]
pub async fn get_rule(
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
        .get_rule(
            &target.flapjack_url,
            &target.node_id,
            &target.region,
            &target.flapjack_uid,
            &object_id,
        )
        .await?;

    Ok(Json(result))
}

/// `PUT /indexes/{name}/rules/{object_id}` — create or update a rule.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Validates `object_id` path segment, rejects cold/restoring indexes (503),
/// then upserts the rule in flapjack with the provided JSON body.
#[utoipa::path(
    put,
    path = "/indexes/{name}/rules/{object_id}",
    tag = "Configuration",
    params(
        ("name" = String, Path, description = "Index name"),
        ("object_id" = String, Path, description = "Rule object ID"),
    ),
    responses(
        (status = 200, description = "Rule saved", body = serde_json::Value),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
    )
)]
pub async fn save_rule(
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
        .save_rule(
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

/// `DELETE /indexes/{name}/rules/{object_id}` — delete a rule.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Validates `object_id` path segment, rejects cold/restoring indexes (503),
/// then deletes the rule from flapjack by its tenant-scoped UID.
#[utoipa::path(
    delete,
    path = "/indexes/{name}/rules/{object_id}",
    tag = "Configuration",
    params(
        ("name" = String, Path, description = "Index name"),
        ("object_id" = String, Path, description = "Rule object ID"),
    ),
    responses(
        (status = 200, description = "Rule deleted", body = serde_json::Value),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = ErrorResponse),
        (status = 404, description = "Index or rule not found", body = ErrorResponse),
    )
)]
pub async fn delete_rule(
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
        .delete_rule(
            &target.flapjack_url,
            &target.node_id,
            &target.region,
            &target.flapjack_uid,
            &object_id,
        )
        .await?;

    Ok(Json(result))
}
