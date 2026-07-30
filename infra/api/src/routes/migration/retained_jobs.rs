//! Retained migration job read surface and public projection.

use axum::extract::{Path, Query, State};
use axum::Json;
use serde::{Deserialize, Serialize};
use utoipa::ToSchema;

use crate::auth::AuthenticatedTenant;
use crate::errors::ApiError;
use crate::models::algolia_import_job::{
    validate_algolia_import_warnings, AlgoliaImportDestinationKind, AlgoliaImportJob,
    AlgoliaImportWarning, SourceImportProvider,
};
use crate::models::AlgoliaImportErrorCode;
use crate::repos::{
    clamp_algolia_import_job_list_limit, AlgoliaImportJobListCursor, PgSourceMigrationJobRepo,
    SourceMigrationJobRepo,
};
use crate::state::AppState;

use super::{
    job_not_found, sign_list_cursor, validate_source_provider, verify_list_cursor,
    MigrationJobPath, MigrationSourcePath,
};

#[derive(Debug, Serialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub struct PublicAlgoliaImportJob {
    pub(super) id: uuid::Uuid,
    source_provider: SourceImportProvider,
    status: crate::models::algolia_import_job::AlgoliaImportJobStatus,
    mode: AlgoliaImportDestinationKind,
    destination: PublicAlgoliaImportDestination,
    source: PublicAlgoliaImportSource,
    summary: crate::models::algolia_import_job::AlgoliaImportSummary,
    terminal_outcome_observed: bool,
    warnings: Vec<AlgoliaImportWarning>,
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
    name: String,
}

#[derive(Debug, Serialize, ToSchema)]
#[serde(rename_all = "camelCase")]
struct PublicAlgoliaImportError {
    code: AlgoliaImportErrorCode,
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

fn job_matches_requested_provider(
    job: &AlgoliaImportJob,
    requested_provider: SourceImportProvider,
) -> bool {
    job.source_provider == requested_provider
}

pub(super) fn ensure_job_matches_requested_provider(
    job: &AlgoliaImportJob,
    requested_provider: SourceImportProvider,
) -> Result<(), ApiError> {
    if job_matches_requested_provider(job, requested_provider) {
        return Ok(());
    }
    Err(job_not_found())
}

async fn list_jobs_for_requested_provider(
    repo: &PgSourceMigrationJobRepo,
    customer_id: uuid::Uuid,
    requested_provider: SourceImportProvider,
    mut after: Option<AlgoliaImportJobListCursor>,
    limit: i64,
) -> Result<(Vec<AlgoliaImportJob>, Option<AlgoliaImportJobListCursor>), crate::repos::RepoError> {
    let limit = usize::try_from(limit.max(0)).unwrap_or(0);
    if limit == 0 {
        return Ok((Vec::new(), None));
    }

    let mut jobs = Vec::with_capacity(limit);
    let mut last_matching_cursor = None;
    loop {
        let page = repo
            .list_for_customer(customer_id, after, limit as i64)
            .await?;
        if page.jobs.is_empty() {
            return Ok((jobs, None));
        }

        for job in page.jobs {
            after = Some(AlgoliaImportJobListCursor {
                created_at: job.created_at,
                id: job.id,
            });

            if !job_matches_requested_provider(&job, requested_provider) {
                continue;
            }
            if jobs.len() == limit {
                return Ok((jobs, last_matching_cursor));
            }

            last_matching_cursor = after;
            jobs.push(job);
        }

        if !page.has_more {
            return Ok((jobs, None));
        }
    }
}

pub(super) fn public_algolia_import_job(job: AlgoliaImportJob) -> PublicAlgoliaImportJob {
    let warnings = if validate_algolia_import_warnings(&job.warnings).is_ok() {
        job.warnings
    } else {
        Vec::new()
    };
    PublicAlgoliaImportJob {
        id: job.id,
        source_provider: job.source_provider,
        status: job.status,
        mode: job.destination_kind,
        destination: PublicAlgoliaImportDestination {
            kind: job.destination_kind,
            target: job.logical_target,
            region: job.destination_region,
        },
        source: PublicAlgoliaImportSource {
            name: job.source_name,
        },
        summary: job.summary,
        terminal_outcome_observed: job.terminal_outcome_observed,
        warnings,
        error: job.error_code.map(|code| PublicAlgoliaImportError { code }),
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
/// exposure flag or backpressure - only admission is.
#[utoipa::path(
    get,
    path = "/migration/algolia/jobs",
    operation_id = "list_algolia_import_jobs",
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
pub async fn list_import_jobs(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(path): Path<MigrationSourcePath>,
    Query(query): Query<ListAlgoliaImportJobsQuery>,
) -> Result<Json<PublicAlgoliaImportJobPage>, ApiError> {
    let requested_provider = validate_source_provider(path.source_provider.as_deref())?;
    let limit = clamp_algolia_import_job_list_limit(query.limit);
    let after = match query.cursor.as_deref() {
        Some(token) => Some(verify_list_cursor(&state, &auth, token)?),
        None => None,
    };
    let repo = PgSourceMigrationJobRepo::new(state.pool.clone());
    let (jobs, next_after) =
        list_jobs_for_requested_provider(&repo, auth.customer_id, requested_provider, after, limit)
            .await
            .map_err(ApiError::from)?;
    let next_cursor = if let Some(cursor) = next_after {
        Some(sign_list_cursor(&state, auth.customer_id, cursor)?)
    } else {
        None
    };
    Ok(Json(PublicAlgoliaImportJobPage {
        jobs: jobs.into_iter().map(public_algolia_import_job).collect(),
        next_cursor,
    }))
}

/// Tenant-scoped retained get. Returns an identical `404` for both a missing id
/// and one owned by another customer, so ownership is not observable.
#[utoipa::path(
    get,
    path = "/migration/algolia/jobs/{id}",
    operation_id = "get_algolia_import_job",
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
pub async fn get_import_job(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(path): Path<MigrationJobPath>,
) -> Result<Json<PublicAlgoliaImportJob>, ApiError> {
    let requested_provider = validate_source_provider(path.source_provider.as_deref())?;
    let job = PgSourceMigrationJobRepo::new(state.pool.clone())
        .get_for_customer(auth.customer_id, path.id)
        .await
        .map_err(ApiError::from)?
        .ok_or_else(job_not_found)?;
    ensure_job_matches_requested_provider(&job, requested_provider)?;
    Ok(Json(public_algolia_import_job(job)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{TimeZone, Utc};
    use serde_json::json;

    use crate::models::algolia_import_job::{
        AlgoliaImportDispatchIntentState, AlgoliaImportEngineAckState, AlgoliaImportJobStatus,
        AlgoliaImportPublicationDisposition, AlgoliaImportSummary,
        MAX_ALGOLIA_IMPORT_WARNING_MESSAGE_BYTES,
    };

    #[test]
    fn public_algolia_import_job_serializes_lifecycle_fields() {
        let serialized =
            serde_json::to_value(public_algolia_import_job(import_job_with_lifecycle_fields()))
                .unwrap();

        assert_eq!(serialized["source"], json!({ "name": "source_products" }));
        assert_eq!(
            serialized["error"],
            json!({ "code": "backend_unavailable" })
        );
        assert_eq!(serialized["terminalOutcomeObserved"], json!(true));
        assert_eq!(
            serialized["warnings"],
            json!([{
                "code": "unsupported_synonym_type",
                "message": "Skipped one synonym",
                "resource": "synonyms",
                "pageIndex": 2,
                "itemIndex": 5,
                "jsonPath": "$.synonyms[5]"
            }])
        );
        assert!(serialized["source"].get("appId").is_none());
        assert!(serialized["error"].get("message").is_none());
        assert!(serialized.get("rawProducerPayload").is_none());
        assert!(serialized.get("algoliaAppId").is_none());
        assert!(serialized.get("sourceApiKey").is_none());
        assert!(serialized.get("upstreamBody").is_none());
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

    fn assert_public_job_serializes_source_provider(source_provider: &str) {
        let mut job = import_job_with_lifecycle_fields();
        job.source_provider = SourceImportProvider::parse(source_provider).unwrap_or_else(|error| {
            panic!("closed source provider {source_provider:?} must construct a public job: {error}")
        });

        let serialized = serde_json::to_value(public_algolia_import_job(job)).unwrap();

        assert_eq!(
            serialized["sourceProvider"],
            json!(source_provider),
            "public job JSON must expose the exact durable source-provider discriminator"
        );
    }

    #[test]
    fn source_import_provider_public_job_serializes_algolia() {
        assert_public_job_serializes_source_provider("algolia");
    }

    #[test]
    fn source_import_provider_public_job_serializes_meilisearch() {
        assert_public_job_serializes_source_provider("meilisearch");
    }

    #[test]
    fn source_import_provider_public_job_serializes_typesense() {
        assert_public_job_serializes_source_provider("typesense");
    }

    #[test]
    fn ensure_job_matches_requested_provider_accepts_matching_provider() {
        let job = import_job_with_lifecycle_fields();

        assert!(ensure_job_matches_requested_provider(&job, SourceImportProvider::Algolia).is_ok());
    }

    #[test]
    fn ensure_job_matches_requested_provider_hides_mismatched_provider() {
        let mut job = import_job_with_lifecycle_fields();
        job.source_provider = SourceImportProvider::Typesense;

        assert!(matches!(
            ensure_job_matches_requested_provider(&job, SourceImportProvider::Algolia),
            Err(ApiError::NotFound(message)) if message == "algolia_import_job_not_found"
        ));
    }

    #[test]
    fn public_algolia_import_job_distinguishes_absent_from_all_zero_terminal_outcome() {
        let mut absent = import_job_with_lifecycle_fields();
        absent.terminal_outcome_observed = false;
        absent.summary = AlgoliaImportSummary::default();
        absent.warnings = Vec::new();
        let absent = serde_json::to_value(public_algolia_import_job(absent)).unwrap();

        let mut observed = import_job_with_lifecycle_fields();
        observed.terminal_outcome_observed = true;
        observed.summary = AlgoliaImportSummary::default();
        observed.warnings = Vec::new();
        let observed = serde_json::to_value(public_algolia_import_job(observed)).unwrap();

        assert_eq!(absent["summary"], observed["summary"]);
        assert_eq!(absent["terminalOutcomeObserved"], json!(false));
        assert_eq!(observed["terminalOutcomeObserved"], json!(true));
        assert_eq!(observed["summary"]["settingsApplied"], json!(0));
        assert_eq!(observed["summary"]["synonymsImported"], json!(0));
        assert_eq!(observed["summary"]["rulesImported"], json!(0));
        assert_eq!(observed["warnings"], json!([]));
    }

    #[test]
    fn public_algolia_import_job_omits_out_of_bounds_warnings() {
        let mut job = import_job_with_lifecycle_fields();
        job.warnings[0].message = "x".repeat(MAX_ALGOLIA_IMPORT_WARNING_MESSAGE_BYTES + 1);

        let serialized = serde_json::to_value(public_algolia_import_job(job)).unwrap();

        assert_eq!(serialized["warnings"], json!([]));
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
