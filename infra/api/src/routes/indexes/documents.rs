use super::*;
use crate::models::IngestQuotaWarningMetric;
use std::collections::HashMap;

const BYTES_PER_MIB: u64 = 1024 * 1024;

fn projected_batch_ingest(body: &serde_json::Value) -> (u64, u64) {
    let mut projected_records = 0_u64;
    let mut projected_bytes = 0_u64;

    let requests = body
        .get("requests")
        .and_then(serde_json::Value::as_array)
        .cloned()
        .unwrap_or_default();

    for op in requests {
        let action = op
            .get("action")
            .and_then(serde_json::Value::as_str)
            .unwrap_or_default();
        if action == "deleteObject" {
            continue;
        }

        projected_records = projected_records.saturating_add(1);
        let body_size = op
            .get("body")
            .and_then(|operation_body| serde_json::to_vec(operation_body).ok())
            .map(|bytes| bytes.len() as u64)
            .unwrap_or(0);
        projected_bytes = projected_bytes.saturating_add(body_size);
    }

    (projected_records, projected_bytes)
}

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

async fn check_free_tier_ingest_caps(
    state: &AppState,
    customer_id: Uuid,
    incoming_doc_count: u64,
    incoming_bytes: u64,
) -> Result<(), ApiError> {
    let customer = state
        .customer_repo
        .find_by_id(customer_id)
        .await?
        .ok_or_else(|| ApiError::NotFound("customer not found".into()))?;

    if customer.billing_plan_enum() != BillingPlan::Free {
        return Ok(());
    }

    let summary = state.usage_repo.summary_for(customer_id, 1).await?;

    let max_records = state.free_tier_limits.max_records;
    let projected_records = summary.avg_document_count as u64 + incoming_doc_count;
    if projected_records > max_records {
        return Err(ApiError::ForbiddenJson(serde_json::json!({
            "error": "quota_exceeded",
            "limit": "max_records",
        })));
    }

    let max_storage_bytes = state
        .free_tier_limits
        .max_storage_mb
        .saturating_mul(BYTES_PER_MIB);
    let current_storage_bytes = (summary.avg_storage_gb * 1024.0 * 1024.0 * 1024.0) as u64;
    let projected_storage_bytes = current_storage_bytes.saturating_add(incoming_bytes);
    if projected_storage_bytes > max_storage_bytes {
        return Err(ApiError::ForbiddenJson(serde_json::json!({
            "error": "quota_exceeded",
            "limit": "max_storage_mb",
        })));
    }

    let now = Utc::now();
    let records_percent_used = if max_records == 0 {
        100.0
    } else {
        (projected_records as f64 / max_records as f64) * 100.0
    };
    if records_percent_used >= 80.0
        && state
            .customer_repo
            .claim_ingest_quota_warning_for_month(
                customer_id,
                IngestQuotaWarningMetric::Records,
                now.year(),
                now.month(),
            )
            .await?
    {
        let email_service = state.email_service.clone();
        let customer_id = customer.id;
        let customer_email = customer.email.clone();
        tokio::spawn(async move {
            if let Err(e) = email_service
                .send_quota_warning_email(
                    &customer_email,
                    "max_records",
                    records_percent_used,
                    projected_records,
                    max_records,
                )
                .await
            {
                tracing::warn!(
                    customer_id = %customer_id,
                    error = %e,
                    "failed to send ingest records quota warning email"
                );
            }
        });
    }

    let max_storage_mb = state.free_tier_limits.max_storage_mb;
    let projected_storage_mb = projected_storage_bytes / BYTES_PER_MIB;
    let storage_percent_used = if max_storage_bytes == 0 {
        100.0
    } else {
        (projected_storage_bytes as f64 / max_storage_bytes as f64) * 100.0
    };
    if storage_percent_used >= 80.0
        && state
            .customer_repo
            .claim_ingest_quota_warning_for_month(
                customer_id,
                IngestQuotaWarningMetric::StorageMb,
                now.year(),
                now.month(),
            )
            .await?
    {
        let email_service = state.email_service.clone();
        let customer_id = customer.id;
        let customer_email = customer.email.clone();
        tokio::spawn(async move {
            if let Err(e) = email_service
                .send_quota_warning_email(
                    &customer_email,
                    "max_storage_mb",
                    storage_percent_used,
                    projected_storage_mb,
                    max_storage_mb,
                )
                .await
            {
                tracing::warn!(
                    customer_id = %customer_id,
                    error = %e,
                    "failed to send ingest storage quota warning email"
                );
            }
        });
    }

    Ok(())
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
        (status = 403, description = "Quota exceeded (free tier)", body = serde_json::Value),
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
    let (add_count, projected_bytes) = projected_batch_ingest(&body);
    check_free_tier_ingest_caps(&state, auth.customer_id, add_count, projected_bytes).await?;

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
