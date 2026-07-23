use super::algolia_import_engine::ensure_algolia_import_engine_compatible;
use super::shared_vm::{create_index_on_shared_vm, reserve_shared_vm_destination};
use super::*;
use crate::models::algolia_import_job::{
    AlgoliaImportCreatePlacement, AlgoliaImportDestinationKind,
};
use crate::models::{AlgoliaImportErrorCode, AlgoliaImportJob, NewAlgoliaImportJob};
use crate::repos::{
    AlgoliaImportJobAdmissionError, AlgoliaImportJobRepo, PgAlgoliaImportJobRepo, RepoError,
};
use crate::services::engine_index_identity_observer::{
    record_physical_caller, PhysicalCallerObservation,
};
use crate::services::flapjack_node::FLAPJACK_APP_ID_VALUE;
use crate::services::flapjack_proxy::ProxyError;

pub(crate) enum IndexAdmissionError {
    Api(ApiError),
    FreeTierMaxIndexes,
}

#[derive(Debug)]
pub enum AlgoliaCreateAdmissionError {
    Route(ApiError),
    Job(AlgoliaImportJobAdmissionError),
}

impl From<ApiError> for AlgoliaCreateAdmissionError {
    fn from(error: ApiError) -> Self {
        Self::Route(error)
    }
}

impl From<AlgoliaImportJobAdmissionError> for AlgoliaCreateAdmissionError {
    fn from(error: AlgoliaImportJobAdmissionError) -> Self {
        Self::Job(error)
    }
}

impl From<ApiError> for IndexAdmissionError {
    fn from(error: ApiError) -> Self {
        Self::Api(error)
    }
}

pub(crate) async fn admit_new_index_destination(
    state: &AppState,
    customer_id: Uuid,
    index_name: &str,
    region: &str,
) -> Result<AdmittedIndexDestination, IndexAdmissionError> {
    let customer = state
        .customer_repo
        .find_by_id(customer_id)
        .await
        .map_err(ApiError::from)?
        .ok_or_else(|| ApiError::NotFound("customer not found".into()))?;
    if customer.email_verified_at.is_none() {
        return Err(ApiError::Forbidden("email_not_verified".into()).into());
    }

    validate_index_name(index_name)?;

    if state.region_config.get_available_region(region).is_none() {
        let region_ids = state.region_config.available_region_ids();
        return Err(ApiError::BadRequest(format!(
            "invalid region: must be one of {:?}",
            region_ids
        ))
        .into());
    }

    let count = state
        .tenant_repo
        .count_by_customer(customer_id)
        .await
        .map_err(ApiError::from)?;
    if customer.billing_plan_enum() == BillingPlan::Free {
        let free_tier_max_indexes = state.free_tier_limits.max_indexes as i64;
        if count >= free_tier_max_indexes {
            return Err(IndexAdmissionError::FreeTierMaxIndexes);
        }
    }

    let max_indexes = super::resolve_customer_quota(state, customer_id)
        .await?
        .max_indexes as i64;
    if count >= max_indexes {
        return Err(
            ApiError::BadRequest(format!("index limit reached (max {max_indexes})")).into(),
        );
    }

    Ok(AdmittedIndexDestination::new(
        customer_id,
        index_name,
        region,
    ))
}

/// Admit and persist an Algolia create reservation without publishing a tenant row.
pub async fn create_algolia_import_job(
    state: &AppState,
    job: NewAlgoliaImportJob,
) -> Result<AlgoliaImportJob, AlgoliaCreateAdmissionError> {
    let customer_id = job.customer_id();
    let logical_target = job.destination().logical_target().to_string();
    let region = job.destination().region().to_string();
    if job.destination().kind() != AlgoliaImportDestinationKind::Create {
        return Err(ApiError::BadRequest(
            "Algolia create admission requires a create destination".into(),
        )
        .into());
    }

    let prepared =
        prepare_algolia_create_target(state, customer_id, &logical_target, &region).await?;
    let admitted_job = job
        .with_create_placement(prepared.vm_id, prepared.physical_uid)
        .map_err(|message| ApiError::BadRequest(message.into()))?;

    PgAlgoliaImportJobRepo::new(state.pool.clone())
        .create(admitted_job)
        .await
        .map_err(Into::into)
}

pub(crate) async fn prepare_algolia_create_target(
    state: &AppState,
    customer_id: Uuid,
    logical_target: &str,
    region: &str,
) -> Result<AlgoliaImportCreatePlacement, AlgoliaCreateAdmissionError> {
    let destination = admit_new_index_destination(state, customer_id, logical_target, region)
        .await
        .map_err(map_algolia_admission_error)?;
    if state.region_config.provider_for_region(region) != Some("aws") {
        return Err(ApiError::BadRequest(
            crate::models::AlgoliaImportErrorCode::MigrationProviderUnsupported
                .as_str()
                .into(),
        )
        .into());
    }
    let selected_vm = reserve_shared_vm_destination(state, &destination).await?;
    ensure_algolia_import_engine_compatible(state, selected_vm.flapjack_url())
        .await
        .map_err(map_algolia_create_job_error)?;
    Ok(AlgoliaImportCreatePlacement {
        vm_id: selected_vm.vm_id(),
        physical_uid: destination.flapjack_uid(),
    })
}

fn map_algolia_create_job_error(error: AlgoliaImportJobAdmissionError) -> ApiError {
    match error {
        AlgoliaImportJobAdmissionError::Refused(code) => map_algolia_create_refusal(code),
        AlgoliaImportJobAdmissionError::Repository(error) => ApiError::from(error),
    }
}

fn map_algolia_create_refusal(code: AlgoliaImportErrorCode) -> ApiError {
    match code {
        AlgoliaImportErrorCode::BackendUnavailable => {
            ApiError::ServiceUnavailable(code.as_str().into())
        }
        other => ApiError::BadRequest(other.as_str().into()),
    }
}

fn map_algolia_admission_error(error: IndexAdmissionError) -> ApiError {
    match error {
        IndexAdmissionError::Api(error) => error,
        IndexAdmissionError::FreeTierMaxIndexes => {
            ApiError::Forbidden("quota_exceeded: max_indexes".into())
        }
    }
}

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

/// Create an index in the requested region for the authenticated customer.
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
    let destination =
        match admit_new_index_destination(&state, auth.customer_id, &req.name, &req.region).await {
            Ok(destination) => destination,
            Err(IndexAdmissionError::Api(error)) => return Err(error),
            Err(IndexAdmissionError::FreeTierMaxIndexes) => {
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
        };

    if let Some(throttled) =
        super::enforce_write_rate_limit(&state, auth.customer_id, &destination.index_name).await?
    {
        return Ok(throttled);
    }

    create_index_on_shared_vm(&state, destination).await
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
        responses.push(index_response_from_summary(s, cold_since));
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

    let (entries, data_size_bytes, status) = if let Some(target) = target.as_ref() {
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
            // Live stats prove that this specific index is reachable. This is
            // stronger than deployment health metadata, which is permanently
            // `unknown` for shared indexes routed through vm_inventory.
            Ok(stats) => (stats.entries, stats.data_size, "ready".to_string()),
            Err(_) => (0, 0, summary.health_status.clone()),
        }
    } else {
        (0, 0, summary.health_status.clone())
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
        status,
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

    if let Some(throttled) =
        super::enforce_write_rate_limit(&state, auth.customer_id, &name).await?
    {
        return Ok(throttled);
    }

    let plan = state
        .index_lifecycle_lease
        .guarded_locked_mutation(auth.customer_id, &name, || async {
            resolve_shared_vm_delete_plan(&state, auth.customer_id, &name).await
        })
        .await
        .map_err(|error| map_delete_plan_error(error, &name))?;

    state.discovery_service.invalidate(auth.customer_id, &name);

    if let Some(target) = &plan.target {
        match state
            .flapjack_proxy
            .delete_index_with_auth_observation(
                &target.flapjack_url,
                &target.node_id,
                &target.region,
                &target.flapjack_uid,
            )
            .await
        {
            Ok(auth_header_value) => {
                let upstream_path = format!("/1/indexes/{}", target.flapjack_uid);
                record_physical_caller(
                    "routes.indexes.lifecycle.delete_index",
                    PhysicalCallerObservation {
                        physical_uid: &target.flapjack_uid,
                        logical_uid: &name,
                        node_secret_id: &target.node_id,
                        auth_secret_id: &target.node_id,
                        auth_header_value: &auth_header_value,
                        upstream_path: &upstream_path,
                        application_id: FLAPJACK_APP_ID_VALUE,
                        http_status: 204,
                    },
                );
            }
            // Downstream 404 and unreachable both mean no confirmed engine data
            // remains reachable to delete, so catalog cleanup stays idempotent.
            Err(ProxyError::FlapjackError { status: 404, .. })
            | Err(ProxyError::Unreachable(_)) => {}
            Err(error) => {
                if let Err(restore_error) =
                    rollback_shared_vm_delete_intent(&state, auth.customer_id, &name, &plan).await
                {
                    tracing::warn!(
                        customer_id = %auth.customer_id,
                        index_name = %name,
                        error = %restore_error,
                        "failed to restore delete lifecycle intent after remote failure"
                    );
                }
                return Err(error.into());
            }
        }
    }

    state
        .tenant_repo
        .remove_lifecycle_intent(auth.customer_id, &name, &plan.deleting_identity)
        .await?;
    state.discovery_service.invalidate(auth.customer_id, &name);

    Ok(StatusCode::NO_CONTENT.into_response())
}

struct SharedVmDeletePlan {
    deleting_identity: crate::repos::CatalogLifecycleTargetIdentity,
    original_vm_id: Option<Uuid>,
    target: Option<ResolvedFlapjackTarget>,
}

async fn resolve_shared_vm_delete_plan(
    state: &AppState,
    customer_id: Uuid,
    index_name: &str,
) -> Result<SharedVmDeletePlan, RepoError> {
    let tenant = state
        .tenant_repo
        .find_raw(customer_id, index_name)
        .await?
        .ok_or(RepoError::NotFound)?;
    let original_identity = super::catalog_identity_from_tenant(&tenant);
    let deleting_tenant = match tenant.tier.as_str() {
        "active" => {
            state
                .tenant_repo
                .publish_delete_lifecycle_intent(customer_id, index_name, &original_identity)
                .await?
        }
        "deleting" if is_compatible_shared_vm_delete_intent(&tenant) => tenant,
        _ => return Err(RepoError::Conflict("destination_changed".into())),
    };
    let deleting_identity = super::catalog_identity_from_tenant(&deleting_tenant);
    let target =
        resolve_shared_vm_delete_target(state, customer_id, index_name, &deleting_tenant).await?;

    Ok(SharedVmDeletePlan {
        deleting_identity,
        original_vm_id: original_identity.vm_id,
        target,
    })
}

fn is_compatible_shared_vm_delete_intent(tenant: &crate::models::tenant::CustomerTenant) -> bool {
    tenant.tier == "deleting"
        && tenant.vm_id.is_some()
        && tenant.cold_snapshot_id.is_none()
        && tenant.service_type == "flapjack"
}

async fn resolve_shared_vm_delete_target(
    state: &AppState,
    customer_id: Uuid,
    index_name: &str,
    tenant: &crate::models::tenant::CustomerTenant,
) -> Result<Option<ResolvedFlapjackTarget>, RepoError> {
    let Some(vm_id) = tenant.vm_id else {
        return Ok(None);
    };
    let deployment = match state
        .deployment_repo
        .find_by_id(tenant.deployment_id)
        .await?
    {
        Some(deployment) => deployment,
        None => return Ok(None),
    };
    if deployment.customer_id != customer_id || deployment.status == "terminated" {
        return Err(RepoError::Conflict("destination_changed".into()));
    }
    let vm = match state.vm_inventory_repo.get(vm_id).await? {
        Some(vm) => vm,
        None => return Ok(None),
    };
    if vm.status != "active" {
        return Err(RepoError::Conflict("destination_changed".into()));
    }
    let node_id = super::resolve_shared_vm_proxy_node_id(state, &vm, &deployment).await;

    Ok(Some(ResolvedFlapjackTarget {
        vm_id,
        flapjack_url: vm.flapjack_url,
        node_id,
        region: deployment.region,
        flapjack_uid: super::flapjack_index_uid(customer_id, index_name),
    }))
}

async fn rollback_shared_vm_delete_intent(
    state: &AppState,
    customer_id: Uuid,
    index_name: &str,
    plan: &SharedVmDeletePlan,
) -> Result<(), RepoError> {
    state
        .tenant_repo
        .publish_lifecycle_placement(
            customer_id,
            index_name,
            &plan.deleting_identity,
            plan.original_vm_id,
        )
        .await?;
    state.discovery_service.invalidate(customer_id, index_name);
    Ok(())
}

fn map_delete_plan_error(error: RepoError, index_name: &str) -> ApiError {
    match error {
        RepoError::NotFound => ApiError::NotFound(format!("index '{index_name}' not found")),
        other => other.into(),
    }
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
