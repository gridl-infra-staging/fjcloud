#[path = "pg_algolia_import_job_dispatch.rs"]
mod dispatch;
#[path = "pg_algolia_import_job_lifecycle.rs"]
mod lifecycle;
#[path = "pg_algolia_import_job_reconciliation.rs"]
mod reconciliation;
#[path = "pg_algolia_import_job_reservation.rs"]
mod reservation;
#[path = "pg_algolia_import_job_support.rs"]
mod support;
#[cfg(test)]
#[path = "pg_algolia_import_job_repo_tests.rs"]
mod tests;

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use sqlx::{PgPool, Postgres, Transaction};
use uuid::Uuid;

use crate::models::algolia_import_job::{
    AlgoliaImportEngineAckState, AlgoliaImportErrorCode, AlgoliaImportJob, AlgoliaImportJobRow,
    AlgoliaImportJobState, AlgoliaImportSummary, NewAlgoliaImportJob, NewAlgoliaReplaceImportJob,
};
use crate::repos::algolia_import_job_repo::{
    AlgoliaImportCancelOutcome, AlgoliaImportDispatchAdmission,
    AlgoliaImportDispatchAdmissionOutcome, AlgoliaImportDispatchGuard,
    AlgoliaImportEngineAckOutcome, AlgoliaImportJobAdmissionError, AlgoliaImportJobListCursor,
    AlgoliaImportJobListPage, AlgoliaImportJobRepo, AlgoliaImportReconciliationClaim,
    AlgoliaImportReconciliationLease, AlgoliaImportReconciliationWriteOutcome,
    AlgoliaImportResumeDeadlineClaim, AlgoliaImportResumeOutcome, AlgoliaLifecycleError,
    CatalogLifecycleTargetGuard, CatalogLifecycleTargetIdentity, DestinationEligibilityError,
    DestinationEligibilitySnapshot,
};
use crate::repos::error::{is_unique_violation, RepoError};
use reconciliation::{persist_job_state, validate_state_write};
use support::{
    active_reservation_predicate, customer_generation_admission_error, persisted_replay_is_allowed,
    repo_error, ActiveReservationRow, AlgoliaImportResumeDeadlineClaimRow, ReservationPlan,
    VmCapacityRow, DEFAULT_ACTIVE_CUSTOMER_IMPORT_BYTES_LIMIT,
    DEFAULT_ACTIVE_CUSTOMER_IMPORT_JOB_LIMIT, DEFAULT_ACTIVE_NODE_IMPORT_JOB_LIMIT,
    DEFAULT_ACTIVE_NODE_TRANSIENT_BYTES_LIMIT, DEFAULT_INDEX_LIMIT, DEFAULT_STORAGE_LIMIT_BYTES,
};

const FIND_BY_IDEMPOTENCY_KEY_SQL: &str = "SELECT * FROM algolia_import_jobs
     WHERE customer_id=$1 AND idempotency_key=$2 AND erased_at IS NULL";

#[derive(sqlx::FromRow)]
struct ErasedTombstoneAckRow {
    id: Uuid,
    engine_ack_state: String,
    cleanup_phase: String,
    tombstone_compacted_at: Option<DateTime<Utc>>,
}

impl ErasedTombstoneAckRow {
    fn outcome(&self) -> AlgoliaImportEngineAckOutcome {
        AlgoliaImportEngineAckOutcome {
            id: self.id,
            engine_ack_state: parse_engine_ack_state(&self.engine_ack_state),
        }
    }
}

#[derive(Clone)]
pub struct PgAlgoliaImportJobRepo {
    pool: PgPool,
}

impl PgAlgoliaImportJobRepo {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// Exposes the canonical reservation predicate to cross-boundary contract tests.
    #[doc(hidden)]
    pub fn active_reservation_predicate_for_contract_tests() -> &'static str {
        active_reservation_predicate()
    }

    fn idempotency_conflict() -> AlgoliaImportJobAdmissionError {
        AlgoliaImportJobAdmissionError::Refused(AlgoliaImportErrorCode::DestinationConflict)
    }

    async fn mark_erased_tombstone_engine_acknowledged(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        id: Uuid,
    ) -> Result<AlgoliaImportEngineAckOutcome, RepoError> {
        let current = sqlx::query_as::<_, ErasedTombstoneAckRow>(
            "SELECT id, engine_ack_state, cleanup_phase, tombstone_compacted_at
             FROM algolia_import_jobs
             WHERE id = $1 AND erased_at IS NOT NULL
             FOR UPDATE",
        )
        .bind(id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(repo_error)?
        .ok_or(RepoError::NotFound)?;

        if current.engine_ack_state == "acknowledged" && current.tombstone_compacted_at.is_some() {
            return Ok(current.outcome());
        }
        if current.cleanup_phase != "exact_target_absent"
            || current.engine_ack_state != "outbox_pending"
            || current.tombstone_compacted_at.is_some()
        {
            return Err(RepoError::Conflict(
                "erased tombstone acknowledgement requires proven exact-target absence".into(),
            ));
        }

        sqlx::query_as::<_, ErasedTombstoneAckRow>(
            "UPDATE algolia_import_jobs
             SET engine_ack_state = 'acknowledged',
                 tombstone_compacted_at = NOW()
             WHERE id = $1
               AND erased_at IS NOT NULL
               AND cleanup_phase = 'exact_target_absent'
               AND engine_ack_state = 'outbox_pending'
               AND tombstone_compacted_at IS NULL
             RETURNING id, engine_ack_state, cleanup_phase, tombstone_compacted_at",
        )
        .bind(id)
        .fetch_one(&mut **tx)
        .await
        .map_err(repo_error)
        .map(|row| row.outcome())
    }

    async fn resolve_existing_replay(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        job: &NewAlgoliaImportJob,
        lifecycle_generation: i64,
    ) -> Result<Option<AlgoliaImportJob>, AlgoliaImportJobAdmissionError> {
        let existing = sqlx::query_as::<_, AlgoliaImportJobRow>(FIND_BY_IDEMPOTENCY_KEY_SQL)
            .bind(job.customer_id())
            .bind(job.idempotency_key())
            .fetch_optional(&mut **tx)
            .await
            .map_err(repo_error)?
            .map(AlgoliaImportJob::from);
        match existing {
            Some(existing)
                if existing.lifecycle_generation == lifecycle_generation
                    && persisted_replay_is_allowed(&existing, job) =>
            {
                Ok(Some(existing))
            }
            Some(_) => Err(Self::idempotency_conflict()),
            None => Ok(None),
        }
    }

    async fn resolve_active_customer_replay(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        job: &NewAlgoliaImportJob,
    ) -> Result<Option<AlgoliaImportJob>, AlgoliaImportJobAdmissionError> {
        let lifecycle_generation = self
            .lock_active_customer_generation(tx, job.customer_id())
            .await
            .map_err(customer_generation_admission_error)?;
        self.resolve_existing_replay(tx, job, lifecycle_generation)
            .await
    }

    async fn resolve_replay_after_unique_violation(
        &self,
        job: &NewAlgoliaImportJob,
    ) -> Result<AlgoliaImportJob, AlgoliaImportJobAdmissionError> {
        let mut tx = self.pool.begin().await.map_err(repo_error)?;
        let replay = self.resolve_active_customer_replay(&mut tx, job).await;
        match replay {
            Ok(Some(replay)) => {
                tx.commit().await.map_err(repo_error)?;
                Ok(replay)
            }
            Ok(None) => {
                let active_target_conflict = self
                    .reject_active_target_reservation(
                        &mut tx,
                        job.customer_id(),
                        job.destination().logical_target(),
                    )
                    .await;
                tx.rollback().await.map_err(repo_error)?;
                match active_target_conflict {
                    Err(error) => Err(error),
                    Ok(()) => Err(Self::idempotency_conflict()),
                }
            }
            Err(error) => {
                tx.rollback().await.map_err(repo_error)?;
                Err(error)
            }
        }
    }
}

fn parse_engine_ack_state(value: &str) -> AlgoliaImportEngineAckState {
    match value {
        "pending" => AlgoliaImportEngineAckState::Pending,
        "not_applicable" => AlgoliaImportEngineAckState::NotApplicable,
        "seal_acknowledged" => AlgoliaImportEngineAckState::SealAcknowledged,
        "outbox_pending" => AlgoliaImportEngineAckState::OutboxPending,
        "acknowledged" => AlgoliaImportEngineAckState::Acknowledged,
        _ => unreachable!("algolia_import_jobs engine ACK CHECK rejected {value}"),
    }
}

#[async_trait]
impl AlgoliaImportJobRepo for PgAlgoliaImportJobRepo {
    async fn create(
        &self,
        job: NewAlgoliaImportJob,
    ) -> Result<AlgoliaImportJob, AlgoliaImportJobAdmissionError> {
        let mut tx = self.pool.begin().await.map_err(repo_error)?;
        if let Err(error) = self
            .acquire_catalog_target_advisory_lock(&mut tx, job.customer_id(), job.tenant_id())
            .await
        {
            tx.rollback().await.map_err(repo_error)?;
            return Err(error);
        }
        match self.resolve_active_customer_replay(&mut tx, &job).await {
            Ok(Some(existing)) => {
                tx.commit().await.map_err(repo_error)?;
                return Ok(existing);
            }
            Ok(None) => {}
            Err(error) => {
                tx.rollback().await.map_err(repo_error)?;
                return Err(error);
            }
        }
        let reservation = self.build_reservation_plan(&mut tx, &job).await?;
        if let Err(error) = self
            .assert_catalog_target_identity(&mut tx, job.customer_id(), job.tenant_id(), None)
            .await
        {
            tx.rollback().await.map_err(repo_error)?;
            return Err(error);
        }
        let result = self
            .insert_with_reservation(&mut tx, &job, &reservation)
            .await;

        match result {
            Ok(job) => {
                tx.commit().await.map_err(repo_error)?;
                Ok(job)
            }
            Err(error) if is_unique_violation(&error) => {
                tx.rollback().await.map_err(repo_error)?;
                self.resolve_replay_after_unique_violation(&job).await
            }
            Err(error) => Err(repo_error(error).into()),
        }
    }

    async fn create_replace(
        &self,
        job: NewAlgoliaReplaceImportJob,
    ) -> Result<AlgoliaImportJob, AlgoliaImportJobAdmissionError> {
        let mut tx = self.pool.begin().await.map_err(repo_error)?;
        if let Err(error) = self
            .acquire_catalog_target_advisory_lock(&mut tx, job.customer_id(), job.logical_target())
            .await
        {
            tx.rollback().await.map_err(repo_error)?;
            return Err(error);
        }
        let target = match self
            .authenticate_replace_target(&mut tx, job.customer_id(), job.logical_target())
            .await
        {
            Ok(target) => target,
            Err(RepoError::NotFound) => {
                tx.rollback().await.map_err(repo_error)?;
                return Err(AlgoliaImportJobAdmissionError::Refused(
                    AlgoliaImportErrorCode::DestinationChanged,
                ));
            }
            Err(error) => {
                tx.rollback().await.map_err(repo_error)?;
                return Err(error.into());
            }
        };
        let destination = target.destination(job.customer_id());
        let authenticated_job = job.into_authenticated_job(destination);
        match self
            .resolve_active_customer_replay(&mut tx, &authenticated_job)
            .await
        {
            Ok(Some(existing)) => {
                tx.commit().await.map_err(repo_error)?;
                return Ok(existing);
            }
            Ok(None) => {}
            Err(error) => {
                tx.rollback().await.map_err(repo_error)?;
                return Err(error);
            }
        }
        target.validate()?;
        let reservation = self
            .build_reservation_plan(&mut tx, &authenticated_job)
            .await?;
        let result = self
            .insert_with_reservation(&mut tx, &authenticated_job, &reservation)
            .await;
        match result {
            Ok(job) => {
                tx.commit().await.map_err(repo_error)?;
                Ok(job)
            }
            Err(error) if is_unique_violation(&error) => {
                tx.rollback().await.map_err(repo_error)?;
                self.resolve_replay_after_unique_violation(&authenticated_job)
                    .await
            }
            Err(error) => Err(repo_error(error).into()),
        }
    }

    async fn admit_dispatch(
        &self,
        admission: AlgoliaImportDispatchAdmission,
    ) -> Result<AlgoliaImportDispatchAdmissionOutcome, AlgoliaImportJobAdmissionError> {
        match admission {
            AlgoliaImportDispatchAdmission::Create(job) => self.admit_create_dispatch(job).await,
            AlgoliaImportDispatchAdmission::Replace(job) => self.admit_replace_dispatch(job).await,
        }
    }

    async fn get(&self, id: Uuid) -> Result<Option<AlgoliaImportJob>, RepoError> {
        sqlx::query_as::<_, AlgoliaImportJobRow>(
            "SELECT * FROM algolia_import_jobs WHERE id=$1 AND erased_at IS NULL",
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await
        .map_err(repo_error)
        .map(|row| row.map(Into::into))
    }

    async fn get_for_customer(
        &self,
        customer_id: Uuid,
        id: Uuid,
    ) -> Result<Option<AlgoliaImportJob>, RepoError> {
        sqlx::query_as::<_, AlgoliaImportJobRow>(
            "SELECT * FROM algolia_import_jobs
             WHERE id = $1 AND customer_id = $2 AND erased_at IS NULL",
        )
        .bind(id)
        .bind(customer_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(repo_error)
        .map(|row| row.map(Into::into))
    }

    async fn list_for_customer(
        &self,
        customer_id: Uuid,
        after: Option<AlgoliaImportJobListCursor>,
        limit: i64,
    ) -> Result<AlgoliaImportJobListPage, RepoError> {
        let (after_created_at, after_id) = match after {
            Some(cursor) => (Some(cursor.created_at), Some(cursor.id)),
            None => (None, None),
        };
        // Fetch one row beyond the requested page. Its presence is the only
        // proof another page exists; equality of `len` and `limit` is not.
        let lookahead_limit = limit.saturating_add(1);
        let mut jobs: Vec<AlgoliaImportJob> = sqlx::query_as::<_, AlgoliaImportJobRow>(
            "SELECT * FROM algolia_import_jobs
             WHERE customer_id = $1
               AND erased_at IS NULL
               AND ($2::timestamptz IS NULL
                    OR (created_at, id) < ($2::timestamptz, $3::uuid))
             ORDER BY created_at DESC, id DESC
             LIMIT $4",
        )
        .bind(customer_id)
        .bind(after_created_at)
        .bind(after_id)
        .bind(lookahead_limit)
        .fetch_all(&self.pool)
        .await
        .map_err(repo_error)
        .map(|rows| rows.into_iter().map(Into::into).collect())?;
        let has_more = jobs.len() as i64 > limit;
        if has_more {
            jobs.truncate(limit.max(0) as usize);
        }
        Ok(AlgoliaImportJobListPage { jobs, has_more })
    }

    async fn snapshot_replace_target_eligibility(
        &self,
        customer_id: Uuid,
        logical_target: &str,
    ) -> Result<DestinationEligibilitySnapshot, DestinationEligibilityError> {
        self.snapshot_replace_target_eligibility_inner(customer_id, logical_target)
            .await
    }

    async fn find_by_idempotency_key(
        &self,
        customer_id: Uuid,
        key: &str,
    ) -> Result<Option<AlgoliaImportJob>, RepoError> {
        sqlx::query_as::<_, AlgoliaImportJobRow>(FIND_BY_IDEMPOTENCY_KEY_SQL)
            .bind(customer_id)
            .bind(key)
            .fetch_optional(&self.pool)
            .await
            .map_err(repo_error)
            .map(|row| row.map(Into::into))
    }

    async fn find_active_dispatch_replay(
        &self,
        customer_id: Uuid,
        idempotency_key: &str,
        identity: &crate::repos::AlgoliaImportDispatchReplayIdentity,
    ) -> Result<Option<AlgoliaImportJob>, AlgoliaImportJobAdmissionError> {
        let mut tx = self.pool.begin().await.map_err(repo_error)?;
        // Fence on the live customer generation first so a replay against a
        // deleted or lifecycle-advanced customer is refused (DestinationChanged)
        // before any credential-bearing work — never presented as a replay.
        let generation = self
            .lock_active_customer_generation(&mut tx, customer_id)
            .await
            .map_err(customer_generation_admission_error)?;
        let existing = sqlx::query_as::<_, AlgoliaImportJobRow>(FIND_BY_IDEMPOTENCY_KEY_SQL)
            .bind(customer_id)
            .bind(idempotency_key)
            .fetch_optional(&mut *tx)
            .await
            .map_err(repo_error)?
            .map(AlgoliaImportJob::from);
        tx.rollback().await.map_err(repo_error)?;
        Ok(match existing {
            Some(job) if job.lifecycle_generation == generation && identity.matches(&job) => {
                Some(job)
            }
            _ => None,
        })
    }

    async fn update_persisted_state(
        &self,
        id: Uuid,
        state: AlgoliaImportJobState,
    ) -> Result<AlgoliaImportJob, RepoError> {
        let mut tx = self.pool.begin().await.map_err(repo_error)?;
        let current = self.lock_generation_fenced_target_job(&mut tx, id).await?;
        validate_state_write(&current, &state)?;
        let updated = persist_job_state(&mut tx, id, &state, false).await?;
        tx.commit().await.map_err(repo_error)?;
        Ok(updated)
    }

    async fn record_dispatch_intent_committed(
        &self,
        id: Uuid,
        engine_job_id: Uuid,
    ) -> Result<AlgoliaImportJob, RepoError> {
        self.record_dispatch_intent_committed_inner(id, engine_job_id)
            .await
    }

    async fn acquire_dispatch_guard(
        &self,
        id: Uuid,
    ) -> Result<AlgoliaImportDispatchGuard, RepoError> {
        self.acquire_dispatch_guard_inner(id).await
    }

    async fn release_dispatch_guard(
        &self,
        guard: AlgoliaImportDispatchGuard,
    ) -> Result<(), RepoError> {
        guard.tx.commit().await.map_err(repo_error)
    }

    async fn record_no_dispatch_failure(
        &self,
        id: Uuid,
        error_code: AlgoliaImportErrorCode,
        error_message: Option<&str>,
    ) -> Result<AlgoliaImportJob, RepoError> {
        if error_code == AlgoliaImportErrorCode::Interrupted {
            return Err(RepoError::Conflict(
                "no-dispatch failure cannot use the engine interruption code".into(),
            ));
        }
        let mut tx = self.pool.begin().await.map_err(repo_error)?;
        self.lock_generation_fenced_target_job(&mut tx, id).await?;
        let result = sqlx::query(
            "UPDATE algolia_import_jobs
             SET status='failed', publication_disposition='not_started',
                 dispatch_intent_state='absent', engine_ack_state='not_applicable',
                 error_code=$2, error_message=$3, retryable=FALSE,
                 worker_claimed_at=NULL, worker_lease_expires_at=NULL, updated_at=NOW()
             WHERE id=$1 AND dispatch_intent_state='absent' AND engine_job_id IS NULL",
        )
        .bind(id)
        .bind(error_code.as_str())
        .bind(error_message)
        .execute(&mut *tx)
        .await
        .map_err(repo_error)?;
        if result.rows_affected() == 0 {
            return Err(RepoError::Conflict(
                "job lacks absent dispatch-intent proof".into(),
            ));
        }
        let updated = sqlx::query_as::<_, AlgoliaImportJobRow>(
            "SELECT * FROM algolia_import_jobs WHERE id = $1",
        )
        .bind(id)
        .fetch_one(&mut *tx)
        .await
        .map_err(repo_error)
        .map(AlgoliaImportJob::from)?;
        tx.commit().await.map_err(repo_error)?;
        Ok(updated)
    }

    async fn request_cancel(&self, id: Uuid) -> Result<AlgoliaImportCancelOutcome, RepoError> {
        self.request_cancel_inner(id).await
    }

    async fn request_cancel_for_customer(
        &self,
        customer_id: Uuid,
        id: Uuid,
    ) -> Result<AlgoliaImportCancelOutcome, AlgoliaLifecycleError> {
        self.request_cancel_for_customer_inner(customer_id, id)
            .await
    }

    async fn prepare_resume(&self, id: Uuid) -> Result<AlgoliaImportResumeOutcome, RepoError> {
        self.prepare_resume_inner(id).await
    }

    async fn prepare_resume_for_customer(
        &self,
        customer_id: Uuid,
        id: Uuid,
        now: DateTime<Utc>,
    ) -> Result<AlgoliaImportResumeOutcome, AlgoliaLifecycleError> {
        self.prepare_resume_for_customer_inner(customer_id, id, now)
            .await
    }

    async fn record_resume_accepted(
        &self,
        id: Uuid,
        generation: i64,
        summary: AlgoliaImportSummary,
    ) -> Result<AlgoliaImportJob, RepoError> {
        self.record_resume_accepted_inner(id, generation, summary)
            .await
    }

    async fn mark_engine_acknowledged(
        &self,
        id: Uuid,
    ) -> Result<AlgoliaImportEngineAckOutcome, RepoError> {
        let mut tx = self.pool.begin().await.map_err(repo_error)?;
        let current = match self.lock_generation_fenced_target_job(&mut tx, id).await {
            Ok(current) => current,
            Err(RepoError::NotFound) => {
                let acknowledged = self
                    .mark_erased_tombstone_engine_acknowledged(&mut tx, id)
                    .await?;
                tx.commit().await.map_err(repo_error)?;
                return Ok(acknowledged);
            }
            Err(error) => return Err(error),
        };
        if current.engine_ack_state == AlgoliaImportEngineAckState::Acknowledged {
            tx.commit().await.map_err(repo_error)?;
            return Ok(current.into());
        }
        if current.engine_ack_state != AlgoliaImportEngineAckState::OutboxPending
            || current.terminal_at.is_none()
        {
            return Err(RepoError::Conflict(
                "engine acknowledgement requires retained terminal outbox work".into(),
            ));
        }

        let acknowledged = sqlx::query_as::<_, AlgoliaImportJobRow>(
            "UPDATE algolia_import_jobs
             SET engine_ack_state = 'acknowledged', updated_at = NOW()
             WHERE id = $1
             RETURNING *",
        )
        .bind(id)
        .fetch_one(&mut *tx)
        .await
        .map_err(repo_error)
        .map(AlgoliaImportJob::from)
        .map(AlgoliaImportEngineAckOutcome::from)?;
        tx.commit().await.map_err(repo_error)?;
        Ok(acknowledged)
    }

    async fn gc_retained_terminal_history(
        &self,
        now: DateTime<Utc>,
        limit: i64,
    ) -> Result<Vec<Uuid>, RepoError> {
        if limit <= 0 {
            return Ok(Vec::new());
        }
        let mut deleted = sqlx::query_scalar::<_, Uuid>(
            "WITH candidates AS (
                 SELECT job.id
                 FROM algolia_import_jobs AS job
                 JOIN customers AS customer ON customer.id = job.customer_id
                 WHERE job.erased_at IS NULL
                   AND customer.status = 'active'
                   AND customer.lifecycle_generation = job.lifecycle_generation
                   AND job.terminal_at <= $1 - INTERVAL '90 days'
                   AND job.engine_ack_state IN (
                       'not_applicable', 'seal_acknowledged', 'acknowledged'
                   )
                   AND job.publication_disposition <> 'unknown'
                   AND job.resumable = FALSE
                   AND job.status IN (
                       'cancelled', 'completed', 'completed_with_warnings', 'failed', 'interrupted'
                   )
                 ORDER BY job.terminal_at, job.id
                 LIMIT $2
                 FOR UPDATE OF customer, job SKIP LOCKED
             ), deleted AS (
                 DELETE FROM algolia_import_jobs AS job
                 USING candidates
                 WHERE job.id = candidates.id
                 RETURNING job.id
             )
             SELECT id FROM deleted ORDER BY id",
        )
        .bind(now)
        .bind(limit)
        .fetch_all(&self.pool)
        .await
        .map_err(repo_error)?;
        deleted.sort_unstable();
        Ok(deleted)
    }

    async fn claim_reconciliation_jobs(
        &self,
        now: DateTime<Utc>,
        lease_expires_at: DateTime<Utc>,
        limit: i64,
    ) -> Result<Vec<AlgoliaImportReconciliationClaim>, RepoError> {
        self.claim_reconciliation_jobs_inner(now, lease_expires_at, limit)
            .await
    }

    async fn record_reconciliation_observation(
        &self,
        lease: &AlgoliaImportReconciliationLease,
        observed_at: DateTime<Utc>,
        state: AlgoliaImportJobState,
    ) -> Result<AlgoliaImportReconciliationWriteOutcome, RepoError> {
        self.record_reconciliation_observation_inner(lease, observed_at, state)
            .await
    }

    async fn claim_elapsed_resume_deadlines(
        &self,
        now: DateTime<Utc>,
        lease_expires_at: DateTime<Utc>,
        limit: i64,
    ) -> Result<Vec<AlgoliaImportResumeDeadlineClaim>, RepoError> {
        if limit <= 0 {
            return Ok(Vec::new());
        }
        if lease_expires_at <= now {
            return Err(RepoError::Conflict(
                "resume deadline claim lease must expire after claim time".into(),
            ));
        }

        let mut rows = sqlx::query_as::<_, AlgoliaImportResumeDeadlineClaimRow>(
            "WITH candidates AS (
                 SELECT job.id
                 FROM algolia_import_jobs AS job
                 JOIN customers AS customer ON customer.id = job.customer_id
                 WHERE job.resumable = TRUE
                   AND job.erased_at IS NULL
                   AND customer.status = 'active'
                   AND customer.lifecycle_generation = job.lifecycle_generation
                   AND job.resume_deadline <= $1
                   AND (job.worker_lease_expires_at IS NULL OR job.worker_lease_expires_at <= $1)
                   AND job.status IN ('failed', 'interrupted')
                   AND job.engine_ack_state = 'pending'
                   AND job.publication_disposition = 'unchanged'
                   AND job.dispatch_intent_state IN ('committed', 'ambiguous')
                   AND job.engine_job_id IS NOT NULL
                 ORDER BY job.resume_deadline ASC, job.id ASC
                 LIMIT $3
                 FOR UPDATE OF customer, job SKIP LOCKED
             )
             UPDATE algolia_import_jobs AS job
             SET worker_claimed_at = $1, worker_lease_expires_at = $2
             FROM candidates
             WHERE job.id = candidates.id
             RETURNING job.id AS job_id, job.cloud_job_id, job.engine_job_id,
                       job.resume_intent_generation, job.resume_count, job.resume_deadline,
                       job.worker_claimed_at, job.worker_lease_expires_at",
        )
        .bind(now)
        .bind(lease_expires_at)
        .bind(limit)
        .fetch_all(&self.pool)
        .await
        .map_err(repo_error)?;
        rows.sort_by_key(|row| (row.resume_deadline, row.job_id));
        Ok(rows.into_iter().map(Into::into).collect())
    }

    async fn begin_lifecycle_target_guard(
        &self,
        customer_id: Uuid,
        logical_target: &str,
    ) -> Result<CatalogLifecycleTargetGuard, RepoError> {
        self.begin_lifecycle_target_guard_inner(customer_id, logical_target)
            .await
    }

    async fn commit_lifecycle_target_guard(
        &self,
        guard: CatalogLifecycleTargetGuard,
        expected_identity: Option<&CatalogLifecycleTargetIdentity>,
    ) -> Result<(), RepoError> {
        self.commit_lifecycle_target_guard_inner(guard, expected_identity)
            .await
    }
}
