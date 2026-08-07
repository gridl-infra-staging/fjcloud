//! Opaque erased-tombstone reconciliation helpers.

use chrono::{DateTime, Utc};
use sqlx::{Postgres, Transaction};
use uuid::Uuid;

use super::{support::repo_error, PgAlgoliaImportJobRepo};
use crate::models::algolia_import_job::{
    AlgoliaImportDestinationKind, AlgoliaImportDispatchIntentState, AlgoliaImportEngineAckState,
    AlgoliaImportJob, AlgoliaImportJobStatus, AlgoliaImportPublicationDisposition,
    AlgoliaImportSummary, SourceImportProvider,
};
use crate::models::{AlgoliaImportTombstoneCleanupPhase, AlgoliaSealScrubWork};
use crate::repos::algolia_import_job_repo::{
    AlgoliaImportReconciliationClaim, AlgoliaImportReconciliationLease,
    AlgoliaImportReconciliationWork,
};
use crate::repos::error::RepoError;

const ERASURE_TOMBSTONE_LIFECYCLE_GENERATION: i64 = 0;
const ERASURE_TOMBSTONE_PLACEHOLDER: &str = "erased";

pub(super) const CLAIM_RECONCILIATION_JOBS_SQL: &str = "
    WITH public_candidates AS (
        SELECT job.id, job.updated_at, FALSE AS erased,
               CASE WHEN job.engine_ack_state = 'pending' THEN 0 ELSE 1 END AS lane_priority
        FROM algolia_import_jobs AS job
        JOIN customers AS customer ON customer.id = job.customer_id
        WHERE (
            job.erased_at IS NULL
            AND customer.status = 'active'
            AND customer.lifecycle_generation = job.lifecycle_generation
            AND (
                (
                    job.engine_ack_state = 'pending'
                    AND job.dispatch_intent_state IN ('ambiguous', 'committed')
                    AND job.engine_job_id IS NOT NULL
                )
                OR (
                    job.engine_ack_state = 'outbox_pending'
                    AND job.dispatch_intent_state = 'committed'
                    AND job.engine_job_id IS NOT NULL
                    AND job.terminal_at IS NOT NULL
                )
            )
        )
        AND (job.worker_lease_expires_at IS NULL
             OR job.worker_lease_expires_at <= $1)
        ORDER BY lane_priority, job.updated_at, job.id
        LIMIT $3
        FOR UPDATE OF job SKIP LOCKED
    ),
    erased_candidates AS (
        SELECT job.id, job.updated_at, TRUE AS erased, 0 AS lane_priority
        FROM algolia_import_jobs AS job
        WHERE job.erased_at IS NOT NULL
          AND job.erasure_handle IS NOT NULL
          AND job.tombstone_compacted_at IS NULL
          AND job.cleanup_phase = 'exact_target_absence_required'
          AND job.engine_ack_state = 'pending'
          AND job.destination_vm_id IS NOT NULL
          AND job.engine_job_id IS NOT NULL
          AND (job.worker_lease_expires_at IS NULL
               OR job.worker_lease_expires_at <= $1)
        ORDER BY job.updated_at, job.id
        LIMIT $3
        FOR UPDATE OF job SKIP LOCKED
    ),
    ranked_candidates AS (
        SELECT id, erased, updated_at, lane_priority,
               ROW_NUMBER() OVER (
                   PARTITION BY erased ORDER BY lane_priority, updated_at, id
               ) AS lane_position
        FROM (
            SELECT * FROM public_candidates
            UNION ALL
            SELECT * FROM erased_candidates
        ) AS candidate_pool
    ),
    candidates AS (
        SELECT id
        FROM ranked_candidates
        ORDER BY lane_position, updated_at, id
        LIMIT $3
    )
    UPDATE algolia_import_jobs AS job
    SET worker_claimed_at = $1, worker_lease_expires_at = $2
    FROM candidates
    WHERE job.id = candidates.id
    RETURNING job.id, job.erased_at IS NOT NULL AS erased";

#[derive(sqlx::FromRow)]
struct ErasedTombstoneClaimRow {
    id: Uuid,
    erasure_handle: Uuid,
    engine_job_id: Option<Uuid>,
    destination_vm_id: Option<Uuid>,
    cleanup_phase: String,
    publication_disposition: String,
    engine_ack_state: String,
    worker_claimed_at: DateTime<Utc>,
    worker_lease_expires_at: DateTime<Utc>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

impl PgAlgoliaImportJobRepo {
    pub(super) async fn claim_erased_tombstone_jobs(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        claimed_ids: &[Uuid],
    ) -> Result<Vec<AlgoliaImportReconciliationClaim>, RepoError> {
        let rows = sqlx::query_as::<_, ErasedTombstoneClaimRow>(
            "SELECT job.id, job.erasure_handle, job.engine_job_id, job.destination_vm_id,
                    job.cleanup_phase, job.publication_disposition, job.engine_ack_state,
                    job.worker_claimed_at, job.worker_lease_expires_at,
                    job.created_at, job.updated_at
             FROM algolia_import_jobs AS job
             WHERE job.id = ANY($1)
               AND job.erased_at IS NOT NULL
               AND job.erasure_handle IS NOT NULL
               AND job.tombstone_compacted_at IS NULL
               AND job.cleanup_phase = 'exact_target_absence_required'
               AND job.engine_ack_state = 'pending'
               AND job.destination_vm_id IS NOT NULL
               AND job.engine_job_id IS NOT NULL",
        )
        .bind(claimed_ids)
        .fetch_all(&mut **tx)
        .await
        .map_err(repo_error)?;

        rows.into_iter()
            .map(AlgoliaImportReconciliationClaim::try_from)
            .collect()
    }
}

impl TryFrom<ErasedTombstoneClaimRow> for AlgoliaImportReconciliationClaim {
    type Error = RepoError;

    fn try_from(row: ErasedTombstoneClaimRow) -> Result<Self, Self::Error> {
        let cleanup_phase = parse_tombstone_cleanup_phase(&row.cleanup_phase)?;
        let publication_disposition =
            parse_tombstone_publication_disposition(&row.publication_disposition)?;
        let engine_ack_state = parse_tombstone_engine_ack_state(&row.engine_ack_state)?;
        let scrub_work = AlgoliaSealScrubWork {
            erasure_handle: row.erasure_handle,
            engine_job_id: row.engine_job_id,
            destination_vm_id: row.destination_vm_id,
            cleanup_phase,
            publication_disposition,
            engine_ack_state,
        };
        Ok(Self {
            lease: AlgoliaImportReconciliationLease {
                job_id: row.id,
                lifecycle_generation: ERASURE_TOMBSTONE_LIFECYCLE_GENERATION,
                claimed_at: row.worker_claimed_at,
                expires_at: row.worker_lease_expires_at,
            },
            job: erased_tombstone_claim_job(&row, publication_disposition, engine_ack_state),
            work: AlgoliaImportReconciliationWork::ErasedTombstone(scrub_work),
        })
    }
}

/// Release a failed erased-tombstone scrub attempt back to the reconciliation
/// queue. Bumping `updated_at` rotates the tombstone behind everything the
/// claim query has not served yet, which is what the import path already gets
/// for free from `persist_job_state`.
pub(super) async fn defer_erased_tombstone_retry(
    pool: &sqlx::PgPool,
    id: Uuid,
    retry_after: DateTime<Utc>,
) -> Result<(), RepoError> {
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET updated_at = $2, worker_claimed_at = NULL, worker_lease_expires_at = NULL
         WHERE id = $1 AND erased_at IS NOT NULL AND tombstone_compacted_at IS NULL",
    )
    .bind(id)
    .bind(retry_after)
    .execute(pool)
    .await
    .map_err(repo_error)?;
    Ok(())
}

fn erased_tombstone_claim_job(
    row: &ErasedTombstoneClaimRow,
    publication_disposition: AlgoliaImportPublicationDisposition,
    engine_ack_state: AlgoliaImportEngineAckState,
) -> AlgoliaImportJob {
    AlgoliaImportJob {
        id: row.id,
        source_provider: SourceImportProvider::Algolia,
        customer_id: Uuid::nil(),
        tenant_id: ERASURE_TOMBSTONE_PLACEHOLDER.to_string(),
        algolia_app_id: ERASURE_TOMBSTONE_PLACEHOLDER.to_string(),
        destination_kind: AlgoliaImportDestinationKind::Create,
        logical_target: ERASURE_TOMBSTONE_PLACEHOLDER.to_string(),
        destination_region: ERASURE_TOMBSTONE_PLACEHOLDER.to_string(),
        destination_deployment_id: None,
        destination_vm_id: row.destination_vm_id,
        physical_uid: None,
        source_name: ERASURE_TOMBSTONE_PLACEHOLDER.to_string(),
        cloud_job_id: Uuid::nil(),
        engine_job_id: row.engine_job_id,
        dispatch_intent_state: AlgoliaImportDispatchIntentState::Committed,
        lifecycle_generation: ERASURE_TOMBSTONE_LIFECYCLE_GENERATION,
        idempotency_key: ERASURE_TOMBSTONE_PLACEHOLDER.to_string(),
        canonical_fingerprint: ERASURE_TOMBSTONE_PLACEHOLDER.to_string(),
        routing_identity: None,
        source_size_bytes: 0,
        reserved_index_count: 0,
        reserved_customer_storage_bytes: 0,
        reserved_node_transient_bytes: 0,
        retryable: false,
        engine_unavailable_since: None,
        worker_claimed_at: Some(row.worker_claimed_at),
        worker_lease_expires_at: Some(row.worker_lease_expires_at),
        cancel_requested_at: None,
        resume_intent_generation: 0,
        resume_checkpoint: None,
        resume_deadline: None,
        resume_status_observed_at: None,
        resumable: false,
        resume_count: 0,
        summary: AlgoliaImportSummary::default(),
        terminal_outcome_observed: false,
        warnings: Vec::new(),
        error_code: None,
        error_message: None,
        status: AlgoliaImportJobStatus::Queued,
        publication_disposition,
        engine_ack_state,
        terminal_at: None,
        created_at: row.created_at,
        updated_at: row.updated_at,
    }
}

fn parse_tombstone_cleanup_phase(
    value: &str,
) -> Result<AlgoliaImportTombstoneCleanupPhase, RepoError> {
    match value {
        "engine_disposition_required" => {
            Ok(AlgoliaImportTombstoneCleanupPhase::EngineDispositionRequired)
        }
        "exact_target_absence_required" => {
            Ok(AlgoliaImportTombstoneCleanupPhase::ExactTargetAbsenceRequired)
        }
        "exact_target_absent" => Ok(AlgoliaImportTombstoneCleanupPhase::ExactTargetAbsent),
        other => Err(RepoError::Other(format!(
            "invalid erased tombstone cleanup phase: {other}"
        ))),
    }
}

fn parse_tombstone_publication_disposition(
    value: &str,
) -> Result<AlgoliaImportPublicationDisposition, RepoError> {
    match value {
        "not_started" => Ok(AlgoliaImportPublicationDisposition::NotStarted),
        "unchanged" => Ok(AlgoliaImportPublicationDisposition::Unchanged),
        "promoted" => Ok(AlgoliaImportPublicationDisposition::Promoted),
        "unknown" => Ok(AlgoliaImportPublicationDisposition::Unknown),
        other => Err(RepoError::Other(format!(
            "invalid erased tombstone publication disposition: {other}"
        ))),
    }
}

fn parse_tombstone_engine_ack_state(value: &str) -> Result<AlgoliaImportEngineAckState, RepoError> {
    match value {
        "pending" => Ok(AlgoliaImportEngineAckState::Pending),
        "not_applicable" => Ok(AlgoliaImportEngineAckState::NotApplicable),
        "seal_acknowledged" => Ok(AlgoliaImportEngineAckState::SealAcknowledged),
        "outbox_pending" => Ok(AlgoliaImportEngineAckState::OutboxPending),
        "acknowledged" => Ok(AlgoliaImportEngineAckState::Acknowledged),
        other => Err(RepoError::Other(format!(
            "invalid erased tombstone engine ACK state: {other}"
        ))),
    }
}
