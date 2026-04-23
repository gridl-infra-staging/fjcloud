//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar25_am_3_customer_multitenant_multiregion_coverage/fjcloud_dev/infra/api/src/routes/indexes/documents.rs.
use super::*;
use std::collections::HashMap;

#[derive(Debug, Deserialize, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BatchDocumentsRequest {
    pub requests: Vec<BatchDocumentOperation>,
}

#[derive(Debug, Deserialize, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BatchDocumentOperation {
    pub action: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub index_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[schema(value_type = Option<Object>)]
    pub body: Option<HashMap<String, serde_json::Value>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub create_if_not_exists: Option<bool>,
}

#[derive(Debug, Deserialize, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BrowseDocumentsRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub query: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub filters: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hits_per_page: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attributes_to_retrieve: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub params: Option<String>,
}

fn serialize_request_body<T: Serialize>(
    request: &T,
    request_name: &str,
) -> Result<serde_json::Value, ApiError> {
    serde_json::to_value(request).map_err(|err| {
        ApiError::Internal(format!(
            "failed to serialize {request_name} request body: {err}"
        ))
    })
}

/// `POST /indexes/{name}/batch` — execute a batch of document operations.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Rejects cold/restoring indexes (503). Each operation in `requests`
/// specifies an `action` (e.g. addObject, updateObject, deleteObject)
/// with an optional `body`. The entire batch is forwarded to flapjack as
/// a single request; partial failures are reflected in the response array.
#[utoipa::path(
    post,
    path = "/indexes/{name}/batch",
    tag = "Documents",
    params(("name" = String, Path, description = "Index name")),
    request_body = BatchDocumentsRequest,
    responses(
        (status = 200, description = "Batch operation results", body = serde_json::Value),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
    )
)]
pub async fn batch_documents(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
    Json(body): Json<BatchDocumentsRequest>,
) -> Result<impl IntoResponse, ApiError> {
    let (_, target) = super::resolve_ready_index_target(
        &state,
        auth.customer_id,
        &name,
        super::IndexNotReadyBehavior::ServiceUnavailable,
    )
    .await?;

    let body = serialize_request_body(&body, "batch documents")?;

    let result = state
        .flapjack_proxy
        .batch_documents(
            &target.flapjack_url,
            &target.node_id,
            &target.region,
            &target.flapjack_uid,
            body,
        )
        .await?;

    Ok(Json(result))
}

/// `POST /indexes/{name}/browse` — paginated document browsing.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Rejects cold/restoring indexes (503). Supports cursor-based pagination,
/// optional query filtering, and attribute projection. The entire request
/// is serialized and forwarded to flapjack; the response includes a
/// cursor for fetching the next page.
#[utoipa::path(
    post,
    path = "/indexes/{name}/browse",
    tag = "Documents",
    params(("name" = String, Path, description = "Index name")),
    request_body = BrowseDocumentsRequest,
    responses(
        (status = 200, description = "Browse results with cursor", body = serde_json::Value),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
    )
)]
pub async fn browse_documents(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
    Json(body): Json<BrowseDocumentsRequest>,
) -> Result<impl IntoResponse, ApiError> {
    let (_, target) = super::resolve_ready_index_target(
        &state,
        auth.customer_id,
        &name,
        super::IndexNotReadyBehavior::ServiceUnavailable,
    )
    .await?;

    let body = serialize_request_body(&body, "browse documents")?;

    let result = state
        .flapjack_proxy
        .browse_documents(
            &target.flapjack_url,
            &target.node_id,
            &target.region,
            &target.flapjack_uid,
            body,
        )
        .await?;

    Ok(Json(result))
}

/// `GET /indexes/{name}/objects/{object_id}` — retrieve a single document.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Validates `object_id` path segment, rejects cold/restoring indexes (503),
/// then fetches the document from flapjack by its tenant-scoped UID.
#[utoipa::path(
    get,
    path = "/indexes/{name}/objects/{object_id}",
    tag = "Documents",
    params(
        ("name" = String, Path, description = "Index name"),
        ("object_id" = String, Path, description = "Document object ID"),
    ),
    responses(
        (status = 200, description = "Document contents", body = serde_json::Value),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = ErrorResponse),
        (status = 404, description = "Index or document not found", body = ErrorResponse),
    )
)]
pub async fn get_document(
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
        .get_document(
            &target.flapjack_url,
            &target.node_id,
            &target.region,
            &target.flapjack_uid,
            &object_id,
        )
        .await?;

    Ok(Json(result))
}

/// `DELETE /indexes/{name}/objects/{object_id}` — delete a single document.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Validates `object_id` path segment, rejects cold/restoring indexes (503),
/// then deletes the document from flapjack by its tenant-scoped UID.
#[utoipa::path(
    delete,
    path = "/indexes/{name}/objects/{object_id}",
    tag = "Documents",
    params(
        ("name" = String, Path, description = "Index name"),
        ("object_id" = String, Path, description = "Document object ID"),
    ),
    responses(
        (status = 200, description = "Document deleted", body = serde_json::Value),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = ErrorResponse),
        (status = 404, description = "Index or document not found", body = ErrorResponse),
    )
)]
pub async fn delete_document(
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
        .delete_document(
            &target.flapjack_url,
            &target.node_id,
            &target.region,
            &target.flapjack_uid,
            &object_id,
        )
        .await?;

    Ok(Json(result))
}
