use std::fmt;

use axum::body::Bytes;
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::IntoResponse;
use axum::Json;
use chrono::Utc;
use serde::ser::{SerializeStruct, Serializer};
use serde::{Deserialize, Serialize};
use utoipa::ToSchema;

use crate::auth::AuthenticatedTenant;
use crate::errors::ApiError;
use crate::models::algolia_import_job::{
    AlgoliaImportDestinationKind, AlgoliaImportJob, SourceImportProvider,
};
use crate::models::AlgoliaImportErrorCode;
use crate::repos::{
    AlgoliaImportDispatchReplayIdentity, AlgoliaImportTransitionDisposition, AlgoliaLifecycleError,
    PgSourceMigrationJobRepo, SourceMigrationJobRepo,
};
use crate::services::algolia_import::{
    AlgoliaImportAdmissionError, AlgoliaImportAdmissionRequest, AlgoliaImportCancelContext,
};
use crate::services::algolia_source::AlgoliaSourceInspectRequest;
use crate::state::AppState;

use super::retained_jobs::{
    ensure_job_matches_requested_provider, public_algolia_import_job, PublicAlgoliaImportJob,
};
use super::{
    job_not_found, map_algolia_source_error, map_create_admission_error, map_job_admission_error,
    migration_backend_unavailable, migration_code_error, migration_error, migration_unavailable,
    require_json_content_type, serde_offending_field, validate_adapter_source_provider,
    MigrationJobPath, MigrationSourcePath, REDACTED_CREDENTIAL,
};

#[derive(Deserialize, ToSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CreateAlgoliaImportJobRequest {
    pub(super) mode: AlgoliaImportDestinationKind,
    pub(super) app_id: String,
    pub(super) api_key: String,
    pub(super) source_name: String,
    pub(super) target: CreateAlgoliaImportJobTargetRequest,
}

impl fmt::Debug for CreateAlgoliaImportJobRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CreateAlgoliaImportJobRequest")
            .field("mode", &self.mode)
            .field("app_id", &REDACTED_CREDENTIAL)
            .field("api_key", &REDACTED_CREDENTIAL)
            .field("source_name", &REDACTED_CREDENTIAL)
            .field("target", &self.target)
            .finish()
    }
}

/// Redacting serializer. `Serialize` exists only to satisfy the documentation union's
/// bounds; `ToSchema` reads the serde attributes above, not this impl, so the published
/// schema is unaffected while no serde emission can leak a credential.
impl Serialize for CreateAlgoliaImportJobRequest {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut request = serializer.serialize_struct("CreateAlgoliaImportJobRequest", 5)?;
        request.serialize_field("mode", &self.mode)?;
        request.serialize_field("appId", REDACTED_CREDENTIAL)?;
        request.serialize_field("apiKey", REDACTED_CREDENTIAL)?;
        request.serialize_field("sourceName", REDACTED_CREDENTIAL)?;
        request.serialize_field("target", &self.target)?;
        request.end()
    }
}

#[derive(Deserialize, ToSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CreateMeilisearchImportJobRequest {
    pub(super) mode: AlgoliaImportDestinationKind,
    pub(super) endpoint: String,
    pub(super) api_key: String,
    pub(super) source_index: String,
    pub(super) target: CreateAlgoliaImportJobTargetRequest,
}

impl fmt::Debug for CreateMeilisearchImportJobRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CreateMeilisearchImportJobRequest")
            .field("mode", &self.mode)
            .field("endpoint", &REDACTED_CREDENTIAL)
            .field("api_key", &REDACTED_CREDENTIAL)
            .field("source_index", &REDACTED_CREDENTIAL)
            .field("target", &self.target)
            .finish()
    }
}

impl Serialize for CreateMeilisearchImportJobRequest {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut request = serializer.serialize_struct("CreateMeilisearchImportJobRequest", 5)?;
        request.serialize_field("mode", &self.mode)?;
        request.serialize_field("endpoint", REDACTED_CREDENTIAL)?;
        request.serialize_field("apiKey", REDACTED_CREDENTIAL)?;
        request.serialize_field("sourceIndex", REDACTED_CREDENTIAL)?;
        request.serialize_field("target", &self.target)?;
        request.end()
    }
}

#[derive(Deserialize, ToSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CreateTypesenseImportJobRequest {
    pub(super) mode: AlgoliaImportDestinationKind,
    pub(super) node: String,
    pub(super) api_key: String,
    pub(super) source_index: String,
    pub(super) target: CreateAlgoliaImportJobTargetRequest,
}

impl fmt::Debug for CreateTypesenseImportJobRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CreateTypesenseImportJobRequest")
            .field("mode", &self.mode)
            .field("node", &REDACTED_CREDENTIAL)
            .field("api_key", &REDACTED_CREDENTIAL)
            .field("source_index", &REDACTED_CREDENTIAL)
            .field("target", &self.target)
            .finish()
    }
}

impl Serialize for CreateTypesenseImportJobRequest {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut request = serializer.serialize_struct("CreateTypesenseImportJobRequest", 5)?;
        request.serialize_field("mode", &self.mode)?;
        request.serialize_field("node", REDACTED_CREDENTIAL)?;
        request.serialize_field("apiKey", REDACTED_CREDENTIAL)?;
        request.serialize_field("sourceIndex", REDACTED_CREDENTIAL)?;
        request.serialize_field("target", &self.target)?;
        request.end()
    }
}

#[derive(Deserialize, ToSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct CreateAlgoliaImportJobTargetRequest {
    pub(super) eligibility_token: String,
}

impl fmt::Debug for CreateAlgoliaImportJobTargetRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CreateAlgoliaImportJobTargetRequest")
            .field("eligibility_token", &REDACTED_CREDENTIAL)
            .finish()
    }
}

impl Serialize for CreateAlgoliaImportJobTargetRequest {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut target = serializer.serialize_struct("CreateAlgoliaImportJobTargetRequest", 1)?;
        target.serialize_field("eligibilityToken", REDACTED_CREDENTIAL)?;
        target.end()
    }
}

/// Documentation-only union; runtime deserialization remains provider-selected in the handler.
#[derive(Serialize, ToSchema)]
#[serde(untagged)]
pub enum CreateSourceImportJobRequest {
    Algolia(CreateAlgoliaImportJobRequest),
    Meilisearch(CreateMeilisearchImportJobRequest),
    Typesense(CreateTypesenseImportJobRequest),
}

struct CreateImportJobAdmissionRequest {
    mode: AlgoliaImportDestinationKind,
    source_connection_id: String,
    api_key: String,
    source_name: String,
    target: CreateAlgoliaImportJobTargetRequest,
}

impl From<CreateAlgoliaImportJobRequest> for CreateImportJobAdmissionRequest {
    fn from(request: CreateAlgoliaImportJobRequest) -> Self {
        Self {
            mode: request.mode,
            source_connection_id: request.app_id,
            api_key: request.api_key,
            source_name: request.source_name,
            target: request.target,
        }
    }
}

impl From<CreateMeilisearchImportJobRequest> for CreateImportJobAdmissionRequest {
    fn from(request: CreateMeilisearchImportJobRequest) -> Self {
        Self {
            mode: request.mode,
            source_connection_id: request.endpoint,
            api_key: request.api_key,
            source_name: request.source_index,
            target: request.target,
        }
    }
}

impl From<CreateTypesenseImportJobRequest> for CreateImportJobAdmissionRequest {
    fn from(request: CreateTypesenseImportJobRequest) -> Self {
        Self {
            mode: request.mode,
            source_connection_id: request.node,
            api_key: request.api_key,
            source_name: request.source_index,
            target: request.target,
        }
    }
}

#[derive(Debug, Deserialize, ToSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CancelAlgoliaImportJobRequest {}

#[derive(Deserialize, ToSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ResumeAlgoliaImportJobRequest {
    api_key: String,
}

impl fmt::Debug for ResumeAlgoliaImportJobRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ResumeAlgoliaImportJobRequest")
            .field("api_key", &"[REDACTED]")
            .finish()
    }
}

#[utoipa::path(
    post,
    path = "/migration/{source_provider}/jobs",
    operation_id = "create_algolia_import_job",
    tag = "Migration",
    params(
        ("source_provider" = SourceImportProvider, Path, description = "Source migration provider"),
    ),
    request_body = CreateSourceImportJobRequest,
    responses(
        (status = 202, description = "Import job accepted (also returned for an idempotent replay); Location header carries the retained job path", body = PublicAlgoliaImportJob),
        (status = 400, description = "Invalid credentials, missing source, or tampered/stale eligibility envelope", body = crate::errors::MigrationErrorResponse),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
        (status = 403, description = "Source key lacks the required ACL or the replace target is not owned", body = crate::errors::MigrationErrorResponse),
        (status = 409, description = "Destination conflict or a changed request under an existing idempotency key", body = crate::errors::MigrationErrorResponse),
        (status = 415, description = "Request body must use a JSON media type", body = crate::errors::MigrationErrorResponse),
        (status = 503, description = "Migration admission disabled or repository backpressured", body = crate::errors::MigrationErrorResponse),
    )
)]
/// Creates a retained import job for the validated migration provider.
pub async fn create_import_job(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(path): Path<MigrationSourcePath>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<impl IntoResponse, ApiError> {
    let source_provider = validate_adapter_source_provider(path.source_provider.as_deref())?;
    require_json_content_type(&headers)?;
    // Opaque extraction preserves labelled handler errors instead of Axum 422 responses.
    let request = deserialize_create_import_job_request(source_provider, &body)?;
    if !state.algolia_migration_enabled {
        return Err(migration_unavailable());
    }
    if request.api_key.is_empty() {
        return Err(migration_error(
            StatusCode::BAD_REQUEST,
            "invalid_algolia_credentials",
            AlgoliaImportErrorCode::InvalidCredentials,
        ));
    }
    let idempotency_key = headers
        .get("idempotency-key")
        .and_then(|value| value.to_str().ok())
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            migration_error(
                StatusCode::BAD_REQUEST,
                "idempotency_key_required",
                AlgoliaImportErrorCode::DestinationChanged,
            )
        })?
        .to_string();
    let target_binding = super::verify_target_envelope(
        &state,
        &auth,
        request.mode,
        &request.target.eligibility_token,
    )?;
    // Return an exact idempotent replay from persisted state before running any
    // fresh create-target placement/compatibility admission or credential-bearing
    // source inspection, so a retained job replays unchanged under later drift.
    let replay_identity = AlgoliaImportDispatchReplayIdentity {
        app_id: request.source_connection_id.clone(),
        source_name: request.source_name.clone(),
        kind: target_binding.mode(),
        logical_target: target_binding.logical_target().to_string(),
        region: target_binding.region().to_string(),
    };
    if let Some(existing) = state
        .algolia_import_service
        .find_dispatch_replay(
            &state.pool,
            target_binding.customer_id(),
            &idempotency_key,
            &replay_identity,
        )
        .await
        .map_err(map_submit_admission_error)?
    {
        let body = public_algolia_import_job(existing);
        let location = retained_job_path(source_provider, body.id);
        return Ok((
            StatusCode::ACCEPTED,
            [(axum::http::header::LOCATION, location)],
            Json(body),
        ));
    }
    let inspected_source = state
        .algolia_source_service
        .inspect_source(AlgoliaSourceInspectRequest {
            app_id: request.source_connection_id.clone(),
            api_key: zeroize::Zeroizing::new(request.api_key.clone()),
            source_name: request.source_name.clone(),
        })
        .await
        .map_err(map_algolia_source_error)?;
    let create_target = match target_binding.mode() {
        AlgoliaImportDestinationKind::Create => Some(
            crate::routes::indexes::lifecycle::prepare_algolia_create_target(
                &state,
                target_binding.customer_id(),
                target_binding.logical_target(),
                target_binding.region(),
            )
            .await
            .map_err(map_create_admission_error)?,
        ),
        AlgoliaImportDestinationKind::Replace => None,
    };
    let outcome = state
        .algolia_import_service
        .admit_inspected_and_submit(
            AlgoliaImportAdmissionRequest::new(
                target_binding,
                create_target,
                request.source_connection_id,
                request.api_key,
                request.source_name,
                idempotency_key,
            ),
            inspected_source,
            &state.pool,
            state.vm_inventory_repo.as_ref(),
            state.alert_service.as_ref(),
        )
        .await
        .map_err(map_submit_admission_error)?;
    let job = outcome.into_job();
    let body = public_algolia_import_job(job);
    let location = retained_job_path(source_provider, body.id);
    Ok((
        StatusCode::ACCEPTED,
        [(axum::http::header::LOCATION, location)],
        Json(body),
    ))
}

fn deserialize_create_import_job_request(
    source_provider: SourceImportProvider,
    body: &[u8],
) -> Result<CreateImportJobAdmissionRequest, ApiError> {
    match source_provider {
        SourceImportProvider::Algolia => {
            serde_json::from_slice::<CreateAlgoliaImportJobRequest>(body)
                .map(CreateImportJobAdmissionRequest::from)
        }
        SourceImportProvider::Meilisearch => {
            serde_json::from_slice::<CreateMeilisearchImportJobRequest>(body)
                .map(CreateImportJobAdmissionRequest::from)
        }
        SourceImportProvider::Typesense => {
            serde_json::from_slice::<CreateTypesenseImportJobRequest>(body)
                .map(CreateImportJobAdmissionRequest::from)
        }
    }
    .map_err(|error| map_create_request_deserialize_error(source_provider, error))
}

fn map_create_request_deserialize_error(
    source_provider: SourceImportProvider,
    error: serde_json::Error,
) -> ApiError {
    let message = match serde_offending_field(&error) {
        Some(field) => format!(
            "invalid {} create request: field `{field}` is incompatible",
            source_provider.as_str()
        ),
        None => format!(
            "invalid {} create request: request body is incompatible",
            source_provider.as_str()
        ),
    };
    migration_error(
        StatusCode::BAD_REQUEST,
        message,
        AlgoliaImportErrorCode::IncompatibleData,
    )
}

fn retained_job_path(source_provider: SourceImportProvider, job_id: uuid::Uuid) -> String {
    format!("/migration/{}/jobs/{job_id}", source_provider.as_str())
}

fn map_submit_admission_error(error: AlgoliaImportAdmissionError) -> ApiError {
    match error {
        AlgoliaImportAdmissionError::Source(error) => map_algolia_source_error(error),
        AlgoliaImportAdmissionError::Admission(error) => map_job_admission_error(error),
        AlgoliaImportAdmissionError::Refused(AlgoliaImportErrorCode::BackendUnavailable) => {
            super::migration_backpressure()
        }
        AlgoliaImportAdmissionError::Refused(code) => {
            migration_code_error(StatusCode::BAD_REQUEST, code)
        }
        AlgoliaImportAdmissionError::PreparedCreateTargetMissing => {
            ApiError::Internal("prepared create target missing".into())
        }
        AlgoliaImportAdmissionError::AuthenticatedReplaceTargetMissing => {
            ApiError::Internal("authenticated replace target missing".into())
        }
        AlgoliaImportAdmissionError::Repository(error) => ApiError::from(error),
    }
}

#[utoipa::path(
    post,
    path = "/migration/{source_provider}/jobs/{id}/cancel",
    operation_id = "cancel_algolia_import_job",
    tag = "Migration",
    params(
        ("source_provider" = SourceImportProvider, Path, description = "Source migration provider"),
        ("id" = uuid::Uuid, Path, description = "Retained import job id owned by the calling customer"),
    ),
    request_body = CancelAlgoliaImportJobRequest,
    responses(
        (status = 202, description = "Cancel accepted", body = PublicAlgoliaImportJob),
        (status = 200, description = "Cancel request was already recorded", body = PublicAlgoliaImportJob),
        (status = 400, description = "Unsupported source provider (source_provider_unsupported)", body = crate::errors::MigrationErrorResponse),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
        (status = 404, description = "No such job, or the job is owned by another customer (indistinguishable)", body = crate::errors::ErrorResponse),
        (status = 409, description = "Job state cannot be cancelled", body = crate::errors::MigrationErrorResponse),
    )
)]
/// Cancels a retained import job for the validated migration provider.
pub async fn cancel_import_job(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(path): Path<MigrationJobPath>,
    Json(_request): Json<CancelAlgoliaImportJobRequest>,
) -> Result<impl IntoResponse, ApiError> {
    let requested_provider = validate_adapter_source_provider(path.source_provider.as_deref())?;
    let id = path.id;
    let repo = PgSourceMigrationJobRepo::new(state.pool.clone());
    let retained = repo
        .get_for_customer(auth.customer_id, id)
        .await
        .map_err(ApiError::from)?
        .ok_or_else(job_not_found)?;
    ensure_job_matches_requested_provider(&retained, requested_provider)?;
    let result = state
        .algolia_import_service
        .cancel_for_customer(AlgoliaImportCancelContext {
            pool: &state.pool,
            vm_repo: state.vm_inventory_repo.as_ref(),
            alert_service: state.alert_service.as_ref(),
            customer_id: auth.customer_id,
            job_id: id,
        })
        .await
        .map_err(|error| map_lifecycle_error(error, StatusCode::CONFLICT))?;
    if matches!(
        result.terminal_finalization.as_ref(),
        Some(crate::repos::AlgoliaImportTerminalFinalizationOutcome::FenceLost)
    ) {
        tracing::debug!(
            job_id = %id,
            "Algolia cancel terminal finalization lost its authority fence"
        );
    }
    let outcome = result.outcome;
    Ok((
        transition_status(outcome.disposition),
        Json(public_algolia_import_job(outcome.job)),
    ))
}

#[utoipa::path(
    post,
    path = "/migration/{source_provider}/jobs/{id}/resume",
    operation_id = "resume_algolia_import_job",
    tag = "Migration",
    params(
        ("source_provider" = SourceImportProvider, Path, description = "Source migration provider"),
        ("id" = uuid::Uuid, Path, description = "Retained import job id owned by the calling customer"),
    ),
    request_body = ResumeAlgoliaImportJobRequest,
    responses(
        (status = 202, description = "Resume accepted", body = PublicAlgoliaImportJob),
        (status = 200, description = "Resume request was already recorded", body = PublicAlgoliaImportJob),
        (status = 400, description = "Invalid credentials or source no longer exists", body = crate::errors::MigrationErrorResponse),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
        (status = 403, description = "Source key lacks the required ACL", body = crate::errors::MigrationErrorResponse),
        (status = 404, description = "No such job, or the job is owned by another customer (indistinguishable)", body = crate::errors::ErrorResponse),
        (status = 409, description = "Job state cannot be resumed", body = crate::errors::MigrationErrorResponse),
        (status = 503, description = "Migration resume disabled or repository backpressured", body = crate::errors::MigrationErrorResponse),
    )
)]
/// Resumes a retained import job for the validated migration provider.
pub async fn resume_import_job(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(path): Path<MigrationJobPath>,
    Json(request): Json<ResumeAlgoliaImportJobRequest>,
) -> Result<impl IntoResponse, ApiError> {
    let requested_provider = validate_adapter_source_provider(path.source_provider.as_deref())?;
    let id = path.id;
    if !state.algolia_migration_enabled {
        return Err(migration_backend_unavailable(
            AlgoliaImportErrorCode::BackendUnavailable.as_str(),
        ));
    }
    if request.api_key.is_empty() {
        return Err(migration_error(
            StatusCode::BAD_REQUEST,
            "invalid_algolia_credentials",
            AlgoliaImportErrorCode::InvalidCredentials,
        ));
    }
    let repo = PgSourceMigrationJobRepo::new(state.pool.clone());
    let retained = repo
        .get_for_customer(auth.customer_id, id)
        .await
        .map_err(ApiError::from)?
        .ok_or_else(job_not_found)?;
    ensure_job_matches_requested_provider(&retained, requested_provider)?;
    validate_resume_candidate(&retained)
        .map_err(|code| migration_code_error(StatusCode::CONFLICT, code))?;
    state
        .algolia_source_service
        .inspect_source(AlgoliaSourceInspectRequest {
            app_id: retained.algolia_app_id,
            api_key: zeroize::Zeroizing::new(request.api_key),
            source_name: retained.source_name,
        })
        .await
        .map_err(map_algolia_source_error)?;
    let outcome = repo
        .prepare_resume_for_customer(auth.customer_id, id, Utc::now())
        .await
        .map_err(|error| map_lifecycle_error(error, StatusCode::CONFLICT))?;
    Ok((
        transition_status(outcome.disposition),
        Json(public_algolia_import_job(outcome.job)),
    ))
}

fn transition_status(disposition: AlgoliaImportTransitionDisposition) -> StatusCode {
    match disposition {
        AlgoliaImportTransitionDisposition::Accepted => StatusCode::ACCEPTED,
        AlgoliaImportTransitionDisposition::Replayed => StatusCode::OK,
    }
}

fn validate_resume_candidate(job: &AlgoliaImportJob) -> Result<(), AlgoliaImportErrorCode> {
    if job.resumable
        || job.status == crate::models::algolia_import_job::AlgoliaImportJobStatus::Resuming
    {
        return Ok(());
    }
    Err(AlgoliaImportErrorCode::NotResumable)
}

fn map_lifecycle_error(error: AlgoliaLifecycleError, refusal_status: StatusCode) -> ApiError {
    match error {
        AlgoliaLifecycleError::NotFound => job_not_found(),
        AlgoliaLifecycleError::Refused(AlgoliaImportErrorCode::BackendUnavailable) => {
            migration_backend_unavailable(AlgoliaImportErrorCode::BackendUnavailable.as_str())
        }
        AlgoliaLifecycleError::Refused(code) => migration_code_error(refusal_status, code),
        AlgoliaLifecycleError::Repository(error) => ApiError::from(error),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{TimeZone, Utc};

    use crate::models::algolia_import_job::{
        AlgoliaImportDispatchIntentState, AlgoliaImportEngineAckState, AlgoliaImportJobStatus,
        AlgoliaImportPublicationDisposition, AlgoliaImportSummary, AlgoliaImportWarning,
        SourceImportProvider,
    };

    #[test]
    fn retained_job_path_uses_the_requested_source_provider() {
        let job_id = uuid::Uuid::from_u128(42);

        assert_eq!(
            retained_job_path(SourceImportProvider::Algolia, job_id),
            format!("/migration/algolia/jobs/{job_id}")
        );
        assert_eq!(
            retained_job_path(SourceImportProvider::Meilisearch, job_id),
            format!("/migration/meilisearch/jobs/{job_id}")
        );
        assert_eq!(
            retained_job_path(SourceImportProvider::Typesense, job_id),
            format!("/migration/typesense/jobs/{job_id}")
        );
    }

    #[test]
    fn json_content_type_accepts_json_media_types_and_rejects_every_other_shape() {
        for media_type in [
            "application/json",
            "APPLICATION/JSON; charset=utf-8",
            "application/vnd.fjcloud+json",
        ] {
            let mut headers = HeaderMap::new();
            headers.insert(
                axum::http::header::CONTENT_TYPE,
                axum::http::HeaderValue::from_static(media_type),
            );
            assert!(require_json_content_type(&headers).is_ok(), "{media_type}");
        }
        for media_type in [
            "text/plain",
            "text/json",
            "application/xml",
            "application/+json",
            "application/ +json",
        ] {
            let mut headers = HeaderMap::new();
            headers.insert(
                axum::http::header::CONTENT_TYPE,
                axum::http::HeaderValue::from_static(media_type),
            );
            assert!(require_json_content_type(&headers).is_err(), "{media_type}");
        }
        assert!(require_json_content_type(&HeaderMap::new()).is_err());

        let mut duplicate_content_type = HeaderMap::new();
        duplicate_content_type.append(
            axum::http::header::CONTENT_TYPE,
            axum::http::HeaderValue::from_static("application/json"),
        );
        duplicate_content_type.append(
            axum::http::header::CONTENT_TYPE,
            axum::http::HeaderValue::from_static("text/plain"),
        );
        assert!(require_json_content_type(&duplicate_content_type).is_err());
    }

    #[test]
    fn validate_resume_candidate_rejects_non_resumable_jobs() {
        let mut job = import_job_with_lifecycle_fields();
        job.resumable = false;

        assert_eq!(
            validate_resume_candidate(&job),
            Err(AlgoliaImportErrorCode::NotResumable)
        );
    }

    #[test]
    fn validate_resume_candidate_accepts_resuming_replays() {
        let mut job = import_job_with_lifecycle_fields();
        job.status = AlgoliaImportJobStatus::Resuming;
        job.resumable = false;

        assert_eq!(validate_resume_candidate(&job), Ok(()));
    }

    fn import_job_with_lifecycle_fields() -> AlgoliaImportJob {
        let created_at = Utc.with_ymd_and_hms(2026, 7, 18, 10, 0, 0).unwrap();
        let updated_at = Utc.with_ymd_and_hms(2026, 7, 18, 10, 5, 0).unwrap();
        let cancel_requested_at = Utc.with_ymd_and_hms(2026, 7, 18, 10, 2, 0).unwrap();
        let resume_deadline = Utc.with_ymd_and_hms(2026, 7, 18, 11, 2, 0).unwrap();
        AlgoliaImportJob {
            id: uuid::Uuid::from_u128(1),
            source_provider: SourceImportProvider::Algolia,
            customer_id: uuid::Uuid::from_u128(2),
            tenant_id: "tenant".to_string(),
            algolia_app_id: "APP123".to_string(),
            destination_kind: AlgoliaImportDestinationKind::Create,
            logical_target: "fj_products".to_string(),
            destination_region: "us-east-1".to_string(),
            destination_deployment_id: None,
            destination_vm_id: None,
            physical_uid: None,
            source_name: "source_products".to_string(),
            cloud_job_id: uuid::Uuid::from_u128(3),
            engine_job_id: Some(uuid::Uuid::from_u128(4)),
            dispatch_intent_state: AlgoliaImportDispatchIntentState::Committed,
            lifecycle_generation: 1,
            idempotency_key: "idempotency-key".to_string(),
            canonical_fingerprint: "fingerprint".to_string(),
            routing_identity: None,
            source_size_bytes: 100,
            reserved_index_count: 1,
            reserved_customer_storage_bytes: 200,
            reserved_node_transient_bytes: 300,
            retryable: true,
            worker_claimed_at: None,
            worker_lease_expires_at: None,
            cancel_requested_at: Some(cancel_requested_at),
            resume_intent_generation: 2,
            resume_checkpoint: Some("engine-checkpoint".to_string()),
            resume_deadline: Some(resume_deadline),
            resume_status_observed_at: Some(updated_at),
            resumable: true,
            resume_count: 2,
            summary: summary_fixture(),
            terminal_outcome_observed: true,
            warnings: vec![AlgoliaImportWarning {
                code: "unsupported_synonym_type".to_string(),
                message: "Skipped one synonym".to_string(),
                resource: "synonyms".to_string(),
                page_index: Some(2),
                item_index: Some(5),
                json_path: "$.synonyms[5]".to_string(),
            }],
            error_code: Some(AlgoliaImportErrorCode::BackendUnavailable),
            error_message: Some("raw producer error".to_string()),
            status: AlgoliaImportJobStatus::Failed,
            publication_disposition: AlgoliaImportPublicationDisposition::Unchanged,
            engine_ack_state: AlgoliaImportEngineAckState::Pending,
            terminal_at: None,
            created_at,
            updated_at,
        }
    }

    fn summary_fixture() -> AlgoliaImportSummary {
        AlgoliaImportSummary {
            documents_expected: 17,
            documents_imported: 13,
            documents_rejected: 4,
            settings_applied: 1,
            settings_unsupported: 2,
            synonyms_expected: 5,
            synonyms_imported: 3,
            synonyms_rejected: 2,
            rules_expected: 7,
            rules_imported: 6,
            rules_rejected: 1,
        }
    }
}
