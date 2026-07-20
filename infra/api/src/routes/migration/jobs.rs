use std::fmt;

use axum::extract::{Path, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::IntoResponse;
use axum::Json;
use chrono::Utc;
use serde::{Deserialize, Serialize};
use utoipa::ToSchema;

use crate::auth::AuthenticatedTenant;
use crate::errors::ApiError;
use crate::models::algolia_import_job::{
    AlgoliaImportDestinationKind, AlgoliaImportJob, NewAlgoliaImportJob, NewAlgoliaReplaceImportJob,
};
use crate::models::AlgoliaImportErrorCode;
use crate::repos::{
    clamp_algolia_import_job_list_limit, AlgoliaImportJobListCursor, AlgoliaImportJobRepo,
    AlgoliaImportTransitionDisposition, AlgoliaLifecycleError, PgAlgoliaImportJobRepo,
};
use crate::services::algolia_source::AlgoliaSourceInspectRequest;
use crate::state::AppState;

use super::{
    map_algolia_source_error, map_create_admission_error, map_job_admission_error,
    migration_backend_unavailable, migration_code_error, migration_error, migration_unavailable,
    sign_list_cursor, verify_list_cursor,
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
            .field("app_id", &"[REDACTED]")
            .field("api_key", &"[REDACTED]")
            .field("source_name", &self.source_name)
            .field("target", &self.target)
            .finish()
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
            .field("eligibility_token", &"[REDACTED]")
            .finish()
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

#[derive(Debug, Serialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub struct PublicAlgoliaImportJob {
    id: uuid::Uuid,
    status: crate::models::algolia_import_job::AlgoliaImportJobStatus,
    mode: AlgoliaImportDestinationKind,
    destination: PublicAlgoliaImportDestination,
    source: PublicAlgoliaImportSource,
    summary: crate::models::algolia_import_job::AlgoliaImportSummary,
    /// Free-form warning payload carried verbatim from the job row.
    #[schema(value_type = Object)]
    warnings: serde_json::Value,
    error: Option<PublicAlgoliaImportError>,
    cancel_requested_at: Option<String>,
    resume_provenance: Option<String>,
    resume_deadline: Option<String>,
    resumable: bool,
    resume_count: i64,
    publication_disposition: crate::models::algolia_import_job::AlgoliaImportPublicationDisposition,
    created_at: String,
    updated_at: String,
}

#[derive(Debug, Serialize, ToSchema)]
#[serde(rename_all = "camelCase")]
struct PublicAlgoliaImportDestination {
    kind: AlgoliaImportDestinationKind,
    target: String,
    region: String,
}

#[derive(Debug, Serialize, ToSchema)]
#[serde(rename_all = "camelCase")]
struct PublicAlgoliaImportSource {
    app_id: String,
    name: String,
}

#[derive(Debug, Serialize, ToSchema)]
#[serde(rename_all = "camelCase")]
struct PublicAlgoliaImportError {
    code: AlgoliaImportErrorCode,
    message: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ListAlgoliaImportJobsQuery {
    limit: Option<i64>,
    cursor: Option<String>,
}

#[derive(Debug, Serialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub struct PublicAlgoliaImportJobPage {
    jobs: Vec<PublicAlgoliaImportJob>,
    /// Opaque signed cursor for the next page, or null when the last page has
    /// been returned.
    next_cursor: Option<String>,
}

#[utoipa::path(
    post,
    path = "/migration/algolia/jobs",
    tag = "Migration",
    request_body = CreateAlgoliaImportJobRequest,
    responses(
        (status = 202, description = "Import job accepted (also returned for an idempotent replay); Location header carries the retained job path", body = PublicAlgoliaImportJob),
        (status = 400, description = "Invalid credentials, missing source, or tampered/stale eligibility envelope", body = crate::errors::MigrationErrorResponse),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
        (status = 403, description = "Source key lacks the required ACL or the replace target is not owned", body = crate::errors::MigrationErrorResponse),
        (status = 409, description = "Destination conflict or a changed request under an existing idempotency key", body = crate::errors::MigrationErrorResponse),
        (status = 503, description = "Migration admission disabled or repository backpressured", body = crate::errors::MigrationErrorResponse),
    )
)]
pub async fn create_algolia_import_job(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<CreateAlgoliaImportJobRequest>,
) -> Result<impl IntoResponse, ApiError> {
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
    let binding = super::verify_target_envelope(&state, &auth, &request)?;
    let source = state
        .algolia_source_service
        .inspect_source(AlgoliaSourceInspectRequest {
            app_id: request.app_id,
            api_key: request.api_key,
            source_name: request.source_name,
        })
        .await
        .map_err(map_algolia_source_error)?;
    let job = match binding.mode() {
        AlgoliaImportDestinationKind::Create => {
            let job =
                NewAlgoliaImportJob::create_from_target_binding(binding, source, idempotency_key)
                    .map_err(|code| migration_code_error(StatusCode::BAD_REQUEST, code))?;
            crate::routes::indexes::lifecycle::create_algolia_import_job(&state, job)
                .await
                .map_err(map_create_admission_error)?
        }
        AlgoliaImportDestinationKind::Replace => {
            let job =
                NewAlgoliaReplaceImportJob::from_target_binding(binding, source, idempotency_key)
                    .map_err(|code| migration_code_error(StatusCode::BAD_REQUEST, code))?;
            PgAlgoliaImportJobRepo::new(state.pool.clone())
                .create_replace(job)
                .await
                .map_err(map_job_admission_error)?
        }
    };
    let body = public_algolia_import_job(job);
    let location = format!("/migration/algolia/jobs/{}", body.id);
    Ok((
        StatusCode::ACCEPTED,
        [(axum::http::header::LOCATION, location)],
        Json(body),
    ))
}

pub(super) fn public_algolia_import_job(job: AlgoliaImportJob) -> PublicAlgoliaImportJob {
    PublicAlgoliaImportJob {
        id: job.id,
        status: job.status,
        mode: job.destination_kind,
        destination: PublicAlgoliaImportDestination {
            kind: job.destination_kind,
            target: job.logical_target,
            region: job.destination_region,
        },
        source: PublicAlgoliaImportSource {
            app_id: job.algolia_app_id,
            name: job.source_name,
        },
        summary: job.summary,
        warnings: job.warnings,
        error: job.error_code.map(|code| PublicAlgoliaImportError {
            code,
            message: job.error_message,
        }),
        cancel_requested_at: job.cancel_requested_at.map(|value| value.to_rfc3339()),
        resume_provenance: job
            .resume_checkpoint
            .as_ref()
            .map(|_| "engine_checkpoint".to_string()),
        resume_deadline: job.resume_deadline.map(|value| value.to_rfc3339()),
        resumable: job.resumable,
        resume_count: job.resume_count,
        publication_disposition: job.publication_disposition,
        created_at: job.created_at.to_rfc3339(),
        updated_at: job.updated_at.to_rfc3339(),
    }
}

/// Tenant-scoped retained list. Reads are never gated by the migration
/// exposure flag or backpressure — only admission is.
#[utoipa::path(
    get,
    path = "/migration/algolia/jobs",
    tag = "Migration",
    params(
        ("limit" = Option<i64>, Query, description = "Page size; clamped to a default of 50 and a maximum of 200"),
        ("cursor" = Option<String>, Query, description = "Opaque signed keyset cursor returned as `nextCursor` by a previous page"),
    ),
    responses(
        (status = 200, description = "One newest-first page of the caller's retained import jobs", body = PublicAlgoliaImportJobPage),
        (status = 400, description = "Tampered, expired, or cross-customer list cursor", body = crate::errors::ErrorResponse),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
    )
)]
pub async fn list_algolia_import_jobs(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Query(query): Query<ListAlgoliaImportJobsQuery>,
) -> Result<Json<PublicAlgoliaImportJobPage>, ApiError> {
    let limit = clamp_algolia_import_job_list_limit(query.limit);
    let after = match query.cursor.as_deref() {
        Some(token) => Some(verify_list_cursor(&state, &auth, token)?),
        None => None,
    };
    let page = PgAlgoliaImportJobRepo::new(state.pool.clone())
        .list_for_customer(auth.customer_id, after, limit)
        .await
        .map_err(ApiError::from)?;
    // Mint a cursor only when the repository's lookahead proved another row
    // exists; an exact-full final page must not point at an empty next page.
    let next_cursor = if page.has_more {
        match page.jobs.last() {
            Some(last) => Some(sign_list_cursor(
                &state,
                auth.customer_id,
                AlgoliaImportJobListCursor {
                    created_at: last.created_at,
                    id: last.id,
                },
            )?),
            None => None,
        }
    } else {
        None
    };
    Ok(Json(PublicAlgoliaImportJobPage {
        jobs: page
            .jobs
            .into_iter()
            .map(public_algolia_import_job)
            .collect(),
        next_cursor,
    }))
}

/// Tenant-scoped retained get. Returns an identical `404` for both a missing id
/// and one owned by another customer, so ownership is not observable.
#[utoipa::path(
    get,
    path = "/migration/algolia/jobs/{id}",
    tag = "Migration",
    params(
        ("id" = uuid::Uuid, Path, description = "Retained import job id owned by the calling customer"),
    ),
    responses(
        (status = 200, description = "The requested retained import job", body = PublicAlgoliaImportJob),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
        (status = 404, description = "No such job, or the job is owned by another customer (indistinguishable)", body = crate::errors::ErrorResponse),
    )
)]
pub async fn get_algolia_import_job(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(id): Path<uuid::Uuid>,
) -> Result<Json<PublicAlgoliaImportJob>, ApiError> {
    let job = PgAlgoliaImportJobRepo::new(state.pool.clone())
        .get_for_customer(auth.customer_id, id)
        .await
        .map_err(ApiError::from)?
        .ok_or_else(|| ApiError::NotFound("algolia_import_job_not_found".into()))?;
    Ok(Json(public_algolia_import_job(job)))
}

#[utoipa::path(
    post,
    path = "/migration/algolia/jobs/{id}/cancel",
    tag = "Migration",
    params(
        ("id" = uuid::Uuid, Path, description = "Retained import job id owned by the calling customer"),
    ),
    request_body = CancelAlgoliaImportJobRequest,
    responses(
        (status = 202, description = "Cancel accepted", body = PublicAlgoliaImportJob),
        (status = 200, description = "Cancel request was already recorded", body = PublicAlgoliaImportJob),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
        (status = 404, description = "No such job, or the job is owned by another customer (indistinguishable)", body = crate::errors::ErrorResponse),
        (status = 409, description = "Job state cannot be cancelled", body = crate::errors::MigrationErrorResponse),
    )
)]
pub async fn cancel_algolia_import_job(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(id): Path<uuid::Uuid>,
    Json(_request): Json<CancelAlgoliaImportJobRequest>,
) -> Result<impl IntoResponse, ApiError> {
    let outcome = PgAlgoliaImportJobRepo::new(state.pool.clone())
        .request_cancel_for_customer(auth.customer_id, id)
        .await
        .map_err(map_cancel_lifecycle_error)?;
    Ok((
        transition_status(outcome.disposition),
        Json(public_algolia_import_job(outcome.job)),
    ))
}

#[utoipa::path(
    post,
    path = "/migration/algolia/jobs/{id}/resume",
    tag = "Migration",
    params(
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
pub async fn resume_algolia_import_job(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(id): Path<uuid::Uuid>,
    Json(request): Json<ResumeAlgoliaImportJobRequest>,
) -> Result<impl IntoResponse, ApiError> {
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
    let repo = PgAlgoliaImportJobRepo::new(state.pool.clone());
    let retained = repo
        .get_for_customer(auth.customer_id, id)
        .await
        .map_err(ApiError::from)?
        .ok_or_else(job_not_found)?;
    validate_resume_candidate(&retained)
        .map_err(|code| migration_code_error(StatusCode::CONFLICT, code))?;
    state
        .algolia_source_service
        .inspect_source(AlgoliaSourceInspectRequest {
            app_id: retained.algolia_app_id,
            api_key: request.api_key,
            source_name: retained.source_name,
        })
        .await
        .map_err(map_algolia_source_error)?;
    let outcome = repo
        .prepare_resume_for_customer(auth.customer_id, id, Utc::now())
        .await
        .map_err(map_resume_lifecycle_error)?;
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

fn job_not_found() -> ApiError {
    ApiError::NotFound("algolia_import_job_not_found".into())
}

fn map_cancel_lifecycle_error(error: AlgoliaLifecycleError) -> ApiError {
    map_lifecycle_error(error, StatusCode::CONFLICT)
}

fn map_resume_lifecycle_error(error: AlgoliaLifecycleError) -> ApiError {
    map_lifecycle_error(error, StatusCode::CONFLICT)
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
    use chrono::TimeZone;
    use serde_json::json;

    use crate::models::algolia_import_job::{
        AlgoliaImportDispatchIntentState, AlgoliaImportEngineAckState, AlgoliaImportJobStatus,
        AlgoliaImportPublicationDisposition, AlgoliaImportSummary,
    };

    #[test]
    fn public_algolia_import_job_serializes_lifecycle_fields() {
        let serialized =
            serde_json::to_value(public_algolia_import_job(import_job_with_lifecycle_fields()))
                .unwrap();

        assert_eq!(
            serialized["summary"],
            json!({
                "documentsExpected": 17,
                "documentsImported": 13,
                "documentsRejected": 4,
                "settingsApplied": 1,
                "settingsUnsupported": 2,
                "synonymsExpected": 5,
                "synonymsImported": 3,
                "synonymsRejected": 2,
                "rulesExpected": 7,
                "rulesImported": 6,
                "rulesRejected": 1
            })
        );
        assert_eq!(
            serialized["cancelRequestedAt"],
            json!("2026-07-18T10:02:00+00:00")
        );
        assert!(serialized.get("resumeCheckpoint").is_none());
        assert_eq!(
            serialized["resumeDeadline"],
            json!("2026-07-18T11:02:00+00:00")
        );
        assert_eq!(serialized["resumeProvenance"], json!("engine_checkpoint"));
        assert_eq!(serialized["resumable"], json!(true));
        assert_eq!(serialized["resumeCount"], json!(2));
        assert_eq!(serialized["publicationDisposition"], json!("unchanged"));
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
            warnings: json!({"skippedReplicas": []}),
            error_code: None,
            error_message: None,
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
