use std::fmt;

use axum::body::Bytes;
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::IntoResponse;
use axum::Json;
use chrono::Utc;
use serde::{Deserialize, Serialize};
use utoipa::ToSchema;

use crate::auth::AuthenticatedTenant;
use crate::errors::ApiError;
use crate::models::algolia_import_job::{
    AlgoliaImportDestinationKind, AlgoliaImportJob, AlgoliaImportSource,
    AlgoliaImportSourceMetadata, SourceImportProvider,
};
use crate::models::AlgoliaImportErrorCode;
use crate::repos::{
    AlgoliaImportDispatchReplayIdentity, AlgoliaImportTransitionDisposition, AlgoliaLifecycleError,
    PgSourceMigrationJobRepo, SourceMigrationJobRepo,
};
use crate::services::algolia_import::{
    AlgoliaImportAdmissionError, AlgoliaImportAdmissionRequest, AlgoliaImportAdmissionSource,
    AlgoliaImportCancelContext,
};
use crate::services::algolia_source::AlgoliaSourceInspectRequest;
use crate::state::AppState;

use super::create_request::{
    CreateAlgoliaImportJobRequest, CreateAlgoliaImportJobTargetRequest,
    CreateImportJobSourceRevisionRequest, CreateMeilisearchImportJobRequest,
    CreateSourceImportJobRequest, CreateTypesenseImportJobRequest,
};
use super::retained_jobs::{
    ensure_job_matches_requested_provider, public_algolia_import_job, PublicAlgoliaImportJob,
};
use super::{
    job_not_found, map_algolia_source_error, map_create_admission_error, map_job_admission_error,
    migration_backend_unavailable, migration_code_error, migration_error, migration_unavailable,
    require_json_content_type, serde_offending_field, validate_adapter_source_provider,
    MigrationJobPath, MigrationSourcePath,
};

/// Serialized shape of a hosted `list-indexes` credential envelope. A struct
/// rather than a `json!` map so the emitted field order is fixed by the
/// declaration and cannot drift with map ordering.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct HostedDiscoveryCredentials<'a> {
    #[serde(skip_serializing_if = "Option::is_none")]
    endpoint: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    node: Option<&'a str>,
    api_key: &'a str,
}

struct CreateImportJobAdmissionRequest {
    source_provider: SourceImportProvider,
    mode: AlgoliaImportDestinationKind,
    source_connection_id: String,
    api_key: String,
    source_name: String,
    source_revision: Option<CreateImportJobSourceRevisionRequest>,
    target: CreateAlgoliaImportJobTargetRequest,
}

impl From<CreateAlgoliaImportJobRequest> for CreateImportJobAdmissionRequest {
    fn from(request: CreateAlgoliaImportJobRequest) -> Self {
        Self {
            source_provider: SourceImportProvider::Algolia,
            mode: request.mode,
            source_connection_id: request.app_id,
            api_key: request.api_key,
            source_name: request.source_name,
            source_revision: request.source_revision,
            target: request.target,
        }
    }
}

impl From<CreateMeilisearchImportJobRequest> for CreateImportJobAdmissionRequest {
    fn from(request: CreateMeilisearchImportJobRequest) -> Self {
        Self {
            source_provider: SourceImportProvider::Meilisearch,
            mode: request.mode,
            source_connection_id: request.endpoint,
            api_key: request.api_key,
            source_name: request.source_index,
            source_revision: request.source_revision,
            target: request.target,
        }
    }
}

impl From<CreateTypesenseImportJobRequest> for CreateImportJobAdmissionRequest {
    fn from(request: CreateTypesenseImportJobRequest) -> Self {
        Self {
            source_provider: SourceImportProvider::Typesense,
            mode: request.mode,
            source_connection_id: request.node,
            api_key: request.api_key,
            source_name: request.source_index,
            source_revision: request.source_revision,
            target: request.target,
        }
    }
}

impl CreateImportJobAdmissionRequest {
    fn source_requires_inspection(&self) -> bool {
        self.source_provider == SourceImportProvider::Algolia
    }

    /// Credential envelope for a create-time discovery re-read, byte-shaped like
    /// the picker's own `list-indexes` body so both reads observe the same
    /// source through the same engine adapter.
    ///
    /// Algolia is deliberately absent: its create path already inspects the live
    /// source through the Algolia source service, and its discovery `entries`
    /// statistic comes from a different upstream API than that inspection, so
    /// the two counts are not comparable and a mismatch would not prove drift.
    fn hosted_discovery_credentials(&self) -> Option<String> {
        hosted_discovery_credentials(
            self.source_provider,
            &self.source_connection_id,
            &self.api_key,
        )
    }

    fn hosted_source(&self) -> AlgoliaImportSource {
        AlgoliaImportSource::from_final_key_metadata(
            self.source_connection_id.clone(),
            self.source_name.clone(),
            AlgoliaImportSourceMetadata::new(None, None, self.source_provider.as_str()),
        )
    }
}

fn hosted_discovery_credentials(
    source_provider: SourceImportProvider,
    source_connection_id: &str,
    api_key: &str,
) -> Option<String> {
    let credentials = match source_provider {
        SourceImportProvider::Algolia => return None,
        SourceImportProvider::Meilisearch => HostedDiscoveryCredentials {
            endpoint: Some(source_connection_id),
            node: None,
            api_key,
        },
        SourceImportProvider::Typesense => HostedDiscoveryCredentials {
            endpoint: None,
            node: Some(source_connection_id),
            api_key,
        },
    };
    Some(
        serde_json::to_string(&credentials)
            .expect("hosted discovery credentials contain only serializable strings"),
    )
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
    let mut request = deserialize_create_import_job_request(source_provider, &body)?;
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
    if request.source_provider != SourceImportProvider::Algolia {
        request.source_connection_id =
            super::source::validate_hosted_source_origin(&request.source_connection_id)?;
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
        source_provider: request.source_provider,
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
    // Prove the chosen source still matches what the picker showed before any
    // placement is reserved. Refusing here rather than after admission is what
    // keeps a drifted source from spending destination capacity or leaving a
    // retained job behind: the customer is answered at the point of choice,
    // where re-reading the source is the next thing they can do.
    ensure_hosted_source_revision_unchanged(&state, &request).await?;
    let inspected_source = if request.source_requires_inspection() {
        state
            .algolia_source_service
            .inspect_source(AlgoliaSourceInspectRequest {
                app_id: request.source_connection_id.clone(),
                api_key: zeroize::Zeroizing::new(request.api_key.clone()),
                source_name: request.source_name.clone(),
            })
            .await
            .map_err(map_algolia_source_error)?
    } else {
        request.hosted_source()
    };
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
                AlgoliaImportAdmissionSource::new(
                    request.source_provider,
                    request.source_connection_id,
                    request.api_key,
                    request.source_name,
                ),
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

/// Compare the revision the picker pinned against a fresh read of the same
/// hosted discovery surface.
///
/// A request that pinned nothing is not evaluated: the picker never showed the
/// customer a count to be stale against, so there is no baseline to refuse on.
/// Once a baseline exists, anything that is not an equal, determinate count is
/// drift — a different count, a source that vanished, or an adapter that can no
/// longer report the count it reported at discovery. Failing closed here is
/// what keeps the guard able to fail: an indeterminate re-read must not read as
/// "the source held still".
async fn ensure_hosted_source_revision_unchanged(
    state: &AppState,
    request: &CreateImportJobAdmissionRequest,
) -> Result<(), ApiError> {
    let (Some(pinned), Some(credentials)) = (
        request.source_revision.as_ref(),
        request.hosted_discovery_credentials(),
    ) else {
        return Ok(());
    };
    let observed = super::source::read_hosted_source_revision(
        state,
        request.source_provider,
        &credentials,
        &request.source_name,
    )
    .await?;
    if observed.as_ref().is_some_and(|revision| {
        revision.document_count == pinned.document_count
            && match (&pinned.revision, &revision.revision) {
                (Some(pinned_revision), Some(observed_revision)) => {
                    pinned_revision == observed_revision
                }
                // Only providers that never carry a content revision may fall
                // back to the timestamp. Typesense always has a computable
                // export hash, so a missing one is a failed read, not "this
                // source has no revision" — and released Typesense discovery
                // reports `updatedAt: null`, so a nullable-timestamp match
                // would otherwise admit a same-count content mutation whenever
                // both hash reads failed.
                (None, None) => {
                    request.source_provider != SourceImportProvider::Typesense
                        && revision.updated_at == pinned.updated_at
                }
                _ => false,
            }
    }) {
        return Ok(());
    }
    tracing::info!(
        source_provider = request.source_provider.as_str(),
        pinned_document_count = pinned.document_count,
        pinned_updated_at = ?pinned.updated_at,
        observed_document_count = ?observed.as_ref().map(|revision| revision.document_count),
        observed_updated_at = ?observed.as_ref().and_then(|revision| revision.updated_at.as_ref()),
        observed_revision = ?observed.as_ref().and_then(|revision| revision.revision.as_ref()),
        "hosted migration source changed between discovery and create"
    );
    Err(migration_code_error(
        StatusCode::BAD_REQUEST,
        AlgoliaImportErrorCode::SourceChanged,
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
    validate_resume_source_access(&state, &retained, request.api_key).await?;
    let outcome = repo
        .prepare_resume_for_customer(auth.customer_id, id, Utc::now())
        .await
        .map_err(|error| map_lifecycle_error(error, StatusCode::CONFLICT))?;
    Ok((
        transition_status(outcome.disposition),
        Json(public_algolia_import_job(outcome.job)),
    ))
}

async fn validate_resume_source_access(
    state: &AppState,
    retained: &AlgoliaImportJob,
    api_key: String,
) -> Result<(), ApiError> {
    if retained.source_provider == SourceImportProvider::Algolia {
        state
            .algolia_source_service
            .inspect_source(AlgoliaSourceInspectRequest {
                app_id: retained.algolia_app_id.clone(),
                api_key: zeroize::Zeroizing::new(api_key),
                source_name: retained.source_name.clone(),
            })
            .await
            .map_err(map_algolia_source_error)?;
        return Ok(());
    }

    let source_connection_id =
        super::source::validate_hosted_source_origin(&retained.algolia_app_id)?;
    let credentials =
        hosted_discovery_credentials(retained.source_provider, &source_connection_id, &api_key)
            .expect("hosted providers always have hosted discovery credentials");
    super::source::read_hosted_source_revision(
        state,
        retained.source_provider,
        &credentials,
        &retained.source_name,
    )
    .await?
    .ok_or_else(|| {
        migration_code_error(
            StatusCode::BAD_REQUEST,
            AlgoliaImportErrorCode::SourceNotFound,
        )
    })?;
    Ok(())
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
            engine_unavailable_since: None,
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
