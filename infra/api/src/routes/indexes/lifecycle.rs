use super::shared_vm::create_index_on_shared_vm;
use super::*;

async fn resolve_cold_since(
    state: &AppState,
    cold_snapshot_id: Option<Uuid>,
) -> Result<Option<String>, ApiError> {
    let Some(snapshot_id) = cold_snapshot_id else {
        return Ok(None);
    };

    let snapshot = state.cold_snapshot_repo.get(snapshot_id).await?;
    Ok(snapshot
        .and_then(|s| s.completed_at)
        .map(|ts| ts.to_rfc3339()))
}

fn map_replica_error(error: ReplicaError) -> ApiError {
    match error {
        ReplicaError::IndexNotFound | ReplicaError::ReplicaNotFound => {
            ApiError::NotFound(error.to_string())
        }
        ReplicaError::RegionNotAvailable(_)
        | ReplicaError::SameRegionAsPrimary
        | ReplicaError::NoCapacityInRegion(_)
        | ReplicaError::NoPrimaryVm => ApiError::BadRequest(error.to_string()),
        ReplicaError::LimitReached(_) | ReplicaError::AlreadyExistsInRegion(_) => {
            ApiError::Conflict(error.to_string())
        }
        ReplicaError::Repo(message) => ApiError::Internal(message),
    }
}

#[utoipa::path(
    post,
    path = "/indexes",
    tag = "Indexes",
    request_body = CreateIndexRequest,
    responses(
        (status = 201, description = "Index created", body = IndexResponse),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 403, description = "Forbidden", body = ErrorResponse),
        (status = 409, description = "Index already exists", body = ErrorResponse),
    )
)]
pub async fn create_index(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Json(req): Json<CreateIndexRequest>,
) -> Result<impl IntoResponse, ApiError> {
    let customer = state
        .customer_repo
        .find_by_id(auth.customer_id)
        .await?
        .ok_or_else(|| ApiError::NotFound("customer not found".into()))?;
    if customer.email_verified_at.is_none() {
        return Err(ApiError::Forbidden("email_not_verified".into()));
    }

    validate_index_name(&req.name)?;

    if state
        .region_config
        .get_available_region(&req.region)
        .is_none()
    {
        let region_ids = state.region_config.available_region_ids();
        return Err(ApiError::BadRequest(format!(
            "invalid region: must be one of {:?}",
            region_ids
        )));
    }

    if let Some(throttled) =
        super::enforce_write_rate_limit(&state, auth.customer_id, &req.name).await?
    {
        return Ok(throttled);
    }

    let count = state
        .tenant_repo
        .count_by_customer(auth.customer_id)
        .await?;
    if customer.billing_plan_enum() == BillingPlan::Free {
        let free_tier_max_indexes = state.free_tier_limits.max_indexes as i64;
        if count >= free_tier_max_indexes {
            return Ok((
                StatusCode::FORBIDDEN,
                Json(serde_json::json!({
                    "error": "quota_exceeded",
                    "limit": "max_indexes",
                    "upgrade_url": "/billing/upgrade",
                })),
            )
                .into_response());
        }
    }

    let max_indexes = super::resolve_customer_quota(&state, auth.customer_id)
        .await?
        .max_indexes as i64;
    if count >= max_indexes {
        return Err(ApiError::BadRequest(format!(
            "index limit reached (max {max_indexes})"
        )));
    }

    create_index_on_shared_vm(&state, auth.customer_id, &req.name, &req.region).await
}

/// GET /indexes — list all indexes for the authenticated customer
#[utoipa::path(
    get,
    path = "/indexes",
    tag = "Indexes",
    responses(
        (status = 200, description = "List of indexes", body = Vec<IndexResponse>),
        (status = 401, description = "Authentication required", body = ErrorResponse),
    )
)]
pub async fn list_indexes(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
) -> Result<impl IntoResponse, ApiError> {
    let summaries = state.tenant_repo.find_by_customer(auth.customer_id).await?;

    let mut responses = Vec::with_capacity(summaries.len());
    for s in summaries {
        let cold_since = resolve_cold_since(&state, s.cold_snapshot_id).await?;
        responses.push(IndexResponse {
            name: s.tenant_id,
            region: s.region,
            endpoint: s.flapjack_url,
            entries: 0,
            data_size_bytes: 0,
            status: s.health_status,
            tier: s.tier,
            last_accessed_at: s.last_accessed_at.map(|ts| ts.to_rfc3339()),
            cold_since,
            created_at: s.created_at.to_rfc3339(),
        });
    }

    Ok(Json(responses))
}

/// `GET /indexes/{name}` — retrieve details and live stats for a single index.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Fetches the index summary from the catalog, then resolves the flapjack
/// target to query live `entries` and `data_size_bytes` from the engine.
/// If the target is not yet ready (still provisioning), stats default to 0.
/// Cold indexes still return metadata but stats will be 0.
#[utoipa::path(
    get,
    path = "/indexes/{name}",
    tag = "Indexes",
    params(("name" = String, Path, description = "Index name")),
    responses(
        (status = 200, description = "Index details", body = IndexResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
    )
)]
pub async fn get_index(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
) -> Result<impl IntoResponse, ApiError> {
    let summary = state
        .tenant_repo
        .find_by_name(auth.customer_id, &name)
        .await?
        .ok_or_else(|| ApiError::NotFound(format!("index '{name}' not found")))?;
    let cold_since = resolve_cold_since(&state, summary.cold_snapshot_id).await?;

    let target =
        super::resolve_flapjack_target(&state, auth.customer_id, &name, summary.deployment_id)
            .await?;

    let (entries, data_size_bytes) = if let Some(target) = target.as_ref() {
        match state
            .flapjack_proxy
            .get_index_stats(
                &target.flapjack_url,
                &target.node_id,
                &target.region,
                &target.flapjack_uid,
            )
            .await
        {
            Ok(stats) => (stats.entries, stats.data_size),
            Err(_) => (0, 0),
        }
    } else {
        (0, 0)
    };

    Ok(Json(IndexResponse {
        name: summary.tenant_id,
        region: summary.region,
        endpoint: target
            .as_ref()
            .map(|t| t.flapjack_url.clone())
            .or(summary.flapjack_url.clone()),
        entries,
        data_size_bytes,
        status: summary.health_status,
        tier: summary.tier,
        last_accessed_at: summary.last_accessed_at.map(|ts| ts.to_rfc3339()),
        cold_since,
        created_at: summary.created_at.to_rfc3339(),
    }))
}

/// `DELETE /indexes/{name}` — permanently delete an index and its data.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Requires `confirm: true` in the request body. Enforces write rate limit,
/// resolves the flapjack target, deletes the index in the engine first, and
/// only then removes the catalog row — so a backend failure leaves the
/// catalog intact (fail closed).
#[utoipa::path(
    delete,
    path = "/indexes/{name}",
    tag = "Indexes",
    params(("name" = String, Path, description = "Index name")),
    request_body = DeleteIndexRequest,
    responses(
        (status = 204, description = "Index deleted"),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
    )
)]
pub async fn delete_index(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
    Json(req): Json<DeleteIndexRequest>,
) -> Result<impl IntoResponse, ApiError> {
    if !req.confirm {
        return Err(ApiError::BadRequest(
            "must set confirm: true to delete an index".into(),
        ));
    }

    let summary = state
        .tenant_repo
        .find_by_name(auth.customer_id, &name)
        .await?
        .ok_or_else(|| ApiError::NotFound(format!("index '{name}' not found")))?;

    if let Some(throttled) =
        super::enforce_write_rate_limit(&state, auth.customer_id, &name).await?
    {
        return Ok(throttled);
    }

    // Resolve the flapjack target before catalog deletion so we can fail closed
    // if backend deletion does not complete.
    let target =
        super::resolve_flapjack_target(&state, auth.customer_id, &name, summary.deployment_id)
            .await?;

    if let Some(target) = target {
        state
            .flapjack_proxy
            .delete_index(
                &target.flapjack_url,
                &target.node_id,
                &target.region,
                &target.flapjack_uid,
            )
            .await?;
    }

    state.tenant_repo.delete(auth.customer_id, &name).await?;

    Ok(StatusCode::NO_CONTENT.into_response())
}

/// Returns an error response for cold/restoring indexes, or `None` for active ones.
pub(crate) async fn check_cold_tier(
    state: &AppState,
    customer_id: Uuid,
    index_name: &str,
) -> Result<Option<Response>, ApiError> {
    let tenant = state.tenant_repo.find_raw(customer_id, index_name).await?;
    let Some(tenant) = tenant else {
        return Ok(None);
    };

    match tenant.tier.as_str() {
        "cold" => Ok(Some(
            (
                StatusCode::GONE,
                Json(serde_json::json!({
                    "error": "index_cold",
                    "message": format!(
                        "Index is in cold storage. Call POST /indexes/{}/restore to restore it.",
                        index_name
                    ),
                    "restore_url": format!("/indexes/{}/restore", index_name)
                })),
            )
                .into_response(),
        )),
        "restoring" => {
            let mut response = (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(serde_json::json!({
                    "error": "index_restoring",
                    "message": "Index is being restored from cold storage.",
                    "poll_url": format!("/indexes/{}/restore-status", index_name)
                })),
            )
                .into_response();
            response
                .headers_mut()
                .insert(header::RETRY_AFTER, header::HeaderValue::from_static("30"));
            Ok(Some(response))
        }
        _ => Ok(None),
    }
}

/// `POST /indexes/{name}/keys` — create a scoped flapjack API key for an index.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Validates `description` (non-empty, length-capped) and `acl` entries
/// against `VALID_ACLS`. Rejects cold/restoring indexes, enforces write
/// rate limit, then delegates to `flapjack_proxy.create_search_key` with
/// the tenant-scoped UID. The returned key is the only time the full
/// secret is visible.
#[utoipa::path(
    post,
    path = "/indexes/{name}/keys",
    tag = "Index Keys",
    params(("name" = String, Path, description = "Index name")),
    request_body = CreateKeyRequest,
    responses(
        (status = 201, description = "API key created", body = serde_json::Value),
        (status = 400, description = "Bad request", body = crate::errors::ErrorResponse),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = crate::errors::ErrorResponse),
        (status = 503, description = "Index is restoring", body = crate::errors::ErrorResponse),
        (status = 404, description = "Index not found", body = crate::errors::ErrorResponse),
        (status = 429, description = "Rate limit exceeded", body = serde_json::Value),
    )
)]
pub async fn create_key(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
    Json(req): Json<CreateKeyRequest>,
) -> Result<impl IntoResponse, ApiError> {
    let description = req.description.trim();
    if description.is_empty() {
        return Err(ApiError::BadRequest("description must not be empty".into()));
    }
    validate_length("description", description, MAX_DESCRIPTION_LEN)?;

    if req.acl.len() > MAX_ACL_ENTRIES {
        return Err(ApiError::BadRequest(format!(
            "acl must have at most {MAX_ACL_ENTRIES} entries"
        )));
    }

    if req.acl.is_empty() {
        return Err(ApiError::BadRequest("acl must not be empty".into()));
    }

    for acl in &req.acl {
        if !VALID_ACLS.contains(&acl.as_str()) {
            return Err(ApiError::BadRequest(format!(
                "invalid acl '{}': must be one of {:?}",
                acl, VALID_ACLS
            )));
        }
    }

    let summary = super::find_active_index_summary(&state, auth.customer_id, &name).await?;

    if let Some(throttled) =
        super::enforce_write_rate_limit(&state, auth.customer_id, &name).await?
    {
        return Ok(throttled);
    }

    let target =
        super::resolve_flapjack_target(&state, auth.customer_id, &name, summary.deployment_id)
            .await?
            .ok_or_else(|| ApiError::BadRequest("endpoint not ready yet".into()))?;

    let acl_refs: Vec<&str> = req.acl.iter().map(|s| s.as_str()).collect();
    let indexes = [target.flapjack_uid.as_str()];

    let key = state
        .flapjack_proxy
        .create_search_key(
            &target.flapjack_url,
            &target.node_id,
            &target.region,
            &indexes,
            &acl_refs,
            description,
        )
        .await?;

    Ok((StatusCode::CREATED, Json(key)).into_response())
}

/// POST /indexes/:name/replicas — create a read replica in another region
#[utoipa::path(
    post,
    path = "/indexes/{name}/replicas",
    tag = "Indexes",
    params(("name" = String, Path, description = "Index name")),
    request_body = CreateReplicaRequest,
    responses(
        (status = 201, description = "Replica created", body = crate::models::index_replica::CustomerIndexReplicaSummary),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
    )
)]
pub async fn create_replica(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
    Json(req): Json<CreateReplicaRequest>,
) -> Result<impl IntoResponse, ApiError> {
    let created = state
        .replica_service
        .create_replica(auth.customer_id, &name, &req.region)
        .await
        .map_err(map_replica_error)?;

    let summaries = state
        .replica_service
        .list_replicas(auth.customer_id, &name)
        .await
        .map_err(map_replica_error)?;
    let summary = summaries
        .into_iter()
        .find(|r| r.id == created.id)
        .ok_or_else(|| ApiError::Internal("replica created but summary missing".to_string()))?;

    Ok((StatusCode::CREATED, Json(summary.to_customer_summary())))
}

/// GET /indexes/:name/replicas — list read replicas for an index
#[utoipa::path(
    get,
    path = "/indexes/{name}/replicas",
    tag = "Indexes",
    params(("name" = String, Path, description = "Index name")),
    responses(
        (status = 200, description = "List of replicas", body = [crate::models::index_replica::CustomerIndexReplicaSummary]),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
    )
)]
pub async fn list_replicas(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
) -> Result<impl IntoResponse, ApiError> {
    let summaries = state
        .replica_service
        .list_replicas(auth.customer_id, &name)
        .await
        .map_err(map_replica_error)?;
    let customer_summaries: Vec<_> = summaries.iter().map(|s| s.to_customer_summary()).collect();
    Ok(Json(customer_summaries))
}

/// DELETE /indexes/:name/replicas/:replica_id — remove a read replica
#[utoipa::path(
    delete,
    path = "/indexes/{name}/replicas/{replica_id}",
    tag = "Indexes",
    params(
        ("name" = String, Path, description = "Index name"),
        ("replica_id" = Uuid, Path, description = "Replica ID"),
    ),
    responses(
        (status = 204, description = "Replica deleted"),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 404, description = "Replica not found", body = ErrorResponse),
    )
)]
pub async fn delete_replica(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path((name, replica_id)): Path<(String, Uuid)>,
) -> Result<impl IntoResponse, ApiError> {
    let summaries = state
        .replica_service
        .list_replicas(auth.customer_id, &name)
        .await
        .map_err(map_replica_error)?;
    if !summaries.iter().any(|r| r.id == replica_id) {
        return Err(ApiError::NotFound(format!(
            "replica {replica_id} not found for index {name}"
        )));
    }

    state
        .replica_service
        .remove_replica(auth.customer_id, replica_id)
        .await
        .map_err(map_replica_error)?;

    Ok(StatusCode::NO_CONTENT)
}

/// POST /indexes/:name/restore — initiate restore of a cold index
#[utoipa::path(
    post,
    path = "/indexes/{name}/restore",
    tag = "Indexes",
    params(("name" = String, Path, description = "Index name")),
    responses(
        (status = 202, description = "Restore initiated", body = serde_json::Value),
        (status = 400, description = "Index is not in cold storage", body = ErrorResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
        (status = 429, description = "Maximum concurrent restores reached", body = serde_json::Value),
    )
)]
pub async fn restore_index(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
) -> Result<impl IntoResponse, ApiError> {
    let restore_service = state
        .restore_service
        .as_ref()
        .ok_or_else(|| ApiError::Internal("restore service not configured".into()))?
        .clone();

    match restore_service
        .initiate_restore(auth.customer_id, &name)
        .await
    {
        Ok(response) => {
            if response.created_new_job {
                let restore_task_service = restore_service.clone();
                let job_id = response.job_id;
                tokio::spawn(async move {
                    restore_task_service.execute_restore(job_id).await;
                });
            }

            Ok((
                StatusCode::ACCEPTED,
                Json(serde_json::json!({
                    "restore_job_id": response.job_id,
                    "status": response.status,
                    "poll_url": format!("/indexes/{}/restore-status", name)
                })),
            )
                .into_response())
        }
        Err(crate::services::restore::RestoreError::NotCold) => {
            Err(ApiError::BadRequest("index is not in cold storage".into()))
        }
        Err(crate::services::restore::RestoreError::NotFound) => {
            Err(ApiError::NotFound(format!("index '{name}' not found")))
        }
        Err(crate::services::restore::RestoreError::AtLimit) => {
            let mut response = (
                StatusCode::TOO_MANY_REQUESTS,
                Json(serde_json::json!({
                    "error": "restore_capacity_reached",
                    "message": "Maximum concurrent restores reached. Try again later."
                })),
            )
                .into_response();
            response
                .headers_mut()
                .insert(header::RETRY_AFTER, header::HeaderValue::from_static("60"));
            Ok(response)
        }
        Err(e) => Err(ApiError::Internal(e.to_string())),
    }
}

/// GET /indexes/:name/restore-status — poll restore status
#[utoipa::path(
    get,
    path = "/indexes/{name}/restore-status",
    tag = "Indexes",
    params(("name" = String, Path, description = "Index name")),
    responses(
        (status = 200, description = "Restore status", body = serde_json::Value),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 404, description = "Index not found or no restore job", body = ErrorResponse),
    )
)]
pub async fn restore_status(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
) -> Result<impl IntoResponse, ApiError> {
    let restore_service = state
        .restore_service
        .as_ref()
        .ok_or_else(|| ApiError::Internal("restore service not configured".into()))?;

    match restore_service
        .get_restore_status(auth.customer_id, &name)
        .await
    {
        Ok(Some(status)) => Ok(Json(serde_json::json!({
            "restore_job_id": status.job.id,
            "status": status.job.status,
            "started_at": status.job.started_at,
            "completed_at": status.job.completed_at,
            "estimated_completion_at": status.estimated_completion_at,
            "error": status.job.error
        }))),
        Ok(None) => Err(ApiError::NotFound(
            "no active restore for this index".into(),
        )),
        Err(e) => Err(ApiError::Internal(e.to_string())),
    }
}
