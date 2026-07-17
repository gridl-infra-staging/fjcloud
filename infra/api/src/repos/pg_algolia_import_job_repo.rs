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
    AlgoliaImportDispatchIntentState, AlgoliaImportErrorCode, AlgoliaImportJob,
    AlgoliaImportJobRow, AlgoliaImportJobState, AlgoliaImportJobStatus, AlgoliaImportSummary,
    NewAlgoliaImportJob, NewAlgoliaReplaceImportJob,
};
use crate::repos::algolia_import_job_repo::{
    AlgoliaImportCancelDispatch, AlgoliaImportCancelOutcome, AlgoliaImportJobRepo,
    AlgoliaImportResumeDeadlineClaim, AlgoliaImportResumeDispatch, AlgoliaImportResumeOutcome,
    CatalogLifecycleTargetGuard, CatalogLifecycleTargetIdentity,
};
use crate::repos::error::{is_unique_violation, RepoError};
use support::{
    active_reservation_predicate, merged_summary, persisted_replay_is_allowed, repo_error,
    state_from_job, validate_transition, ActiveReservationRow, AlgoliaImportResumeDeadlineClaimRow,
    ReservationPlan, VmCapacityRow, DEFAULT_ACTIVE_CUSTOMER_IMPORT_BYTES_LIMIT,
    DEFAULT_ACTIVE_CUSTOMER_IMPORT_JOB_LIMIT, DEFAULT_ACTIVE_NODE_IMPORT_JOB_LIMIT,
    DEFAULT_ACTIVE_NODE_TRANSIENT_BYTES_LIMIT, DEFAULT_INDEX_LIMIT, DEFAULT_STORAGE_LIMIT_BYTES,
};

const FIND_BY_IDEMPOTENCY_KEY_SQL: &str = "SELECT * FROM algolia_import_jobs
     WHERE customer_id=$1 AND idempotency_key=$2 AND erased_at IS NULL";

#[derive(Clone)]
pub struct PgAlgoliaImportJobRepo {
    pool: PgPool,
}

impl PgAlgoliaImportJobRepo {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    pub async fn assert_guarded_target_identity(
        &self,
        guard: &mut CatalogLifecycleTargetGuard,
        expected_identity: Option<&CatalogLifecycleTargetIdentity>,
    ) -> Result<(), RepoError> {
        self.assert_catalog_target_identity(
            &mut guard.tx,
            guard.customer_id,
            &guard.logical_target,
            expected_identity,
        )
        .await
    }

    pub async fn commit_guarded_target_mutation(
        &self,
        guard: CatalogLifecycleTargetGuard,
    ) -> Result<(), RepoError> {
        guard.tx.commit().await.map_err(repo_error)
    }

    fn idempotency_conflict(job: &NewAlgoliaImportJob) -> RepoError {
        RepoError::Conflict(format!(
            "Algolia import job already exists for customer {} and idempotency key '{}' with a different canonical fingerprint",
            job.customer_id(),
            job.idempotency_key()
        ))
    }

    async fn resolve_existing_replay(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        job: &NewAlgoliaImportJob,
        lifecycle_generation: i64,
    ) -> Result<Option<AlgoliaImportJob>, RepoError> {
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
            Some(_) => Err(Self::idempotency_conflict(job)),
            None => Ok(None),
        }
    }

    async fn resolve_active_customer_replay(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        job: &NewAlgoliaImportJob,
    ) -> Result<Option<AlgoliaImportJob>, RepoError> {
        let lifecycle_generation = self
            .lock_active_customer_generation(tx, job.customer_id())
            .await?;
        self.resolve_existing_replay(tx, job, lifecycle_generation)
            .await
    }

    async fn resolve_replay_after_unique_violation(
        &self,
        job: &NewAlgoliaImportJob,
    ) -> Result<AlgoliaImportJob, RepoError> {
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
                    Err(RepoError::Conflict(message)) => Err(RepoError::Conflict(message)),
                    Err(error) => Err(error),
                    Ok(()) => Err(Self::idempotency_conflict(job)),
                }
            }
            Err(error) => {
                tx.rollback().await.map_err(repo_error)?;
                Err(error)
            }
        }
    }
}

#[async_trait]
impl AlgoliaImportJobRepo for PgAlgoliaImportJobRepo {
    async fn create(&self, job: NewAlgoliaImportJob) -> Result<AlgoliaImportJob, RepoError> {
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
            Err(error) => Err(repo_error(error)),
        }
    }

    async fn create_replace(
        &self,
        job: NewAlgoliaReplaceImportJob,
    ) -> Result<AlgoliaImportJob, RepoError> {
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
                return Err(RepoError::Conflict(
                    AlgoliaImportErrorCode::DestinationChanged.as_str().into(),
                ));
            }
            Err(error) => {
                tx.rollback().await.map_err(repo_error)?;
                return Err(error);
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
            Err(error) => Err(repo_error(error)),
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

    async fn update_persisted_state(
        &self,
        id: Uuid,
        state: AlgoliaImportJobState,
    ) -> Result<AlgoliaImportJob, RepoError> {
        let mut tx = self.pool.begin().await.map_err(repo_error)?;
        let current = self.lock_generation_fenced_target_job(&mut tx, id).await?;
        if current.engine_ack_state == crate::models::AlgoliaImportEngineAckState::NotApplicable {
            return Err(RepoError::Conflict(
                "state update targets an immutable no-dispatch terminal job".into(),
            ));
        }
        if state.dispatch_intent_state != current.dispatch_intent_state
            || state.engine_job_id != current.engine_job_id
        {
            return Err(RepoError::Conflict(
                "state update cannot change dispatch intent or engine identity".into(),
            ));
        }
        if state.lifecycle_generation != current.lifecycle_generation {
            return Err(RepoError::Conflict(
                "state update cannot change customer lifecycle generation".into(),
            ));
        }
        validate_transition(&current, &state)?;
        let summary = &state.summary;
        let resume_checkpoint = state
            .resume_mirror
            .as_ref()
            .map(|mirror| mirror.checkpoint());
        let resume_status_observed_at = state
            .resume_mirror
            .as_ref()
            .map(|mirror| mirror.status_observed_at());
        let resume_deadline = state.resume_mirror.as_ref().map(|mirror| mirror.deadline());
        let updated = sqlx::query_as::<_, AlgoliaImportJobRow>(
            "UPDATE algolia_import_jobs SET status=$2, publication_disposition=$3,
             engine_ack_state=$4, lifecycle_generation=$5, retryable=$6,
             resume_intent_generation=$7, documents_expected=$8, documents_imported=$9,
             documents_rejected=$10, settings_applied=$11, settings_unsupported=$12,
             synonyms_expected=$13, synonyms_imported=$14, synonyms_rejected=$15,
             rules_expected=$16, rules_imported=$17, rules_rejected=$18, warnings=$19,
             error_code=$20, error_message=$21, updated_at=NOW(),
             resume_checkpoint=$22, resume_status_observed_at=$23,
             resume_deadline=$24, resumable=$25, resume_count=$26
             WHERE id=$1
             RETURNING *",
        )
        .bind(id)
        .bind(state.status.as_str())
        .bind(state.publication_disposition.as_str())
        .bind(state.engine_ack_state.as_str())
        .bind(state.lifecycle_generation)
        .bind(state.retryable)
        .bind(state.resume_intent_generation)
        .bind(summary.documents_expected)
        .bind(summary.documents_imported)
        .bind(summary.documents_rejected)
        .bind(summary.settings_applied)
        .bind(summary.settings_unsupported)
        .bind(summary.synonyms_expected)
        .bind(summary.synonyms_imported)
        .bind(summary.synonyms_rejected)
        .bind(summary.rules_expected)
        .bind(summary.rules_imported)
        .bind(summary.rules_rejected)
        .bind(&state.warnings)
        .bind(state.error_code.map(AlgoliaImportErrorCode::as_str))
        .bind(&state.error_message)
        .bind(resume_checkpoint)
        .bind(resume_status_observed_at)
        .bind(resume_deadline)
        .bind(state.resumable)
        .bind(state.resume_count)
        .fetch_one(&mut *tx)
        .await
        .map_err(repo_error)
        .map(AlgoliaImportJob::from)?;
        tx.commit().await.map_err(repo_error)?;
        Ok(updated)
    }

    async fn record_dispatch_intent_committed(
        &self,
        id: Uuid,
        engine_job_id: Uuid,
    ) -> Result<AlgoliaImportJob, RepoError> {
        let mut tx = self.pool.begin().await.map_err(repo_error)?;
        let current = self.lock_generation_fenced_target_job(&mut tx, id).await?;

        sqlx::query(
            "SELECT 1 FROM algolia_import_environment_contract
             WHERE singleton = TRUE
             FOR UPDATE",
        )
        .execute(&mut *tx)
        .await
        .map_err(repo_error)?;

        if current.dispatch_intent_state == AlgoliaImportDispatchIntentState::Committed {
            if current.engine_job_id == Some(engine_job_id) {
                tx.commit().await.map_err(repo_error)?;
                return Ok(current);
            }
            return Err(RepoError::Conflict(
                "dispatch intent already committed for a different engine job".into(),
            ));
        }
        if current.dispatch_intent_state != AlgoliaImportDispatchIntentState::Absent
            || current.engine_job_id.is_some()
        {
            return Err(RepoError::Conflict(
                "dispatch intent cannot be committed from the current job proof".into(),
            ));
        }
        if current
            .status
            .is_finally_terminal(current.resumable, current.publication_disposition)
        {
            return Err(RepoError::Conflict(
                "finally terminal Algolia import job cannot record dispatch intent".into(),
            ));
        }

        sqlx::query(
            "UPDATE algolia_import_environment_contract
             SET rollback_epoch='migration_aware_required'
             WHERE singleton = TRUE",
        )
        .execute(&mut *tx)
        .await
        .map_err(repo_error)?;

        let updated = sqlx::query_as::<_, AlgoliaImportJobRow>(
            "UPDATE algolia_import_jobs
             SET dispatch_intent_state='committed', engine_job_id=$2, updated_at=NOW()
             WHERE id=$1
             RETURNING *",
        )
        .bind(id)
        .bind(engine_job_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(repo_error)
        .map(AlgoliaImportJob::from)?;
        tx.commit().await.map_err(repo_error)?;
        Ok(updated)
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
            "UPDATE algolia_import_jobs SET status='failed', dispatch_intent_state='absent',
             engine_ack_state='not_applicable', error_code=$2, error_message=$3,
             retryable=FALSE, updated_at=NOW()
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
        let mut tx = self.pool.begin().await.map_err(repo_error)?;
        let current = self.lock_generation_fenced_target_job(&mut tx, id).await?;

        if matches!(
            current.status,
            AlgoliaImportJobStatus::Cancelling | AlgoliaImportJobStatus::Cancelled
        ) {
            tx.commit().await.map_err(repo_error)?;
            return Ok(AlgoliaImportCancelOutcome {
                job: current,
                dispatch: None,
            });
        }
        if current
            .status
            .is_finally_terminal(current.resumable, current.publication_disposition)
        {
            return Err(RepoError::Conflict(
                "finally terminal Algolia import job cannot be cancelled".into(),
            ));
        }

        let mut next = state_from_job(&current)?;
        next.status = AlgoliaImportJobStatus::Cancelling;
        validate_transition(&current, &next)?;

        let updated = sqlx::query_as::<_, AlgoliaImportJobRow>(
            "UPDATE algolia_import_jobs
             SET status='cancelling', cancel_requested_at=COALESCE(cancel_requested_at, NOW()),
                 updated_at=NOW()
             WHERE id=$1
             RETURNING *",
        )
        .bind(id)
        .fetch_one(&mut *tx)
        .await
        .map_err(repo_error)
        .map(AlgoliaImportJob::from)?;
        tx.commit().await.map_err(repo_error)?;

        let dispatch = updated
            .engine_job_id
            .is_some()
            .then_some(AlgoliaImportCancelDispatch {
                job_id: updated.cloud_job_id,
            });
        Ok(AlgoliaImportCancelOutcome {
            job: updated,
            dispatch,
        })
    }

    async fn prepare_resume(&self, id: Uuid) -> Result<AlgoliaImportResumeOutcome, RepoError> {
        let mut tx = self.pool.begin().await.map_err(repo_error)?;
        let current = self.lock_generation_fenced_target_job(&mut tx, id).await?;

        if current.status == AlgoliaImportJobStatus::Resuming {
            tx.commit().await.map_err(repo_error)?;
            return Ok(AlgoliaImportResumeOutcome {
                generation: current.resume_intent_generation,
                expected_attempt: current.resume_count + 1,
                job: current,
                dispatch: None,
            });
        }
        if !current.resumable {
            return Err(RepoError::Conflict(
                AlgoliaImportErrorCode::NotResumable.as_str().into(),
            ));
        }

        let generation = current.resume_intent_generation + 1;
        let expected_attempt = current.resume_count + 1;
        let mut next = state_from_job(&current)?;
        next.status = AlgoliaImportJobStatus::Resuming;
        next.resume_intent_generation = generation;
        next.resumable = false;
        next.resume_mirror = None;
        next.error_code = None;
        next.error_message = None;
        validate_transition(&current, &next)?;

        let updated = sqlx::query_as::<_, AlgoliaImportJobRow>(
            "UPDATE algolia_import_jobs
             SET status='resuming', resume_intent_generation=$2, resumable=FALSE,
                 resume_checkpoint=NULL, resume_status_observed_at=NULL, resume_deadline=NULL,
                 error_code=NULL, error_message=NULL, updated_at=NOW()
             WHERE id=$1
             RETURNING *",
        )
        .bind(id)
        .bind(generation)
        .fetch_one(&mut *tx)
        .await
        .map_err(repo_error)
        .map(AlgoliaImportJob::from)?;
        tx.commit().await.map_err(repo_error)?;

        Ok(AlgoliaImportResumeOutcome {
            generation,
            expected_attempt,
            dispatch: Some(AlgoliaImportResumeDispatch {
                job_id: updated.cloud_job_id,
                generation,
                expected_attempt,
            }),
            job: updated,
        })
    }

    async fn record_resume_accepted(
        &self,
        id: Uuid,
        generation: i64,
        summary: AlgoliaImportSummary,
    ) -> Result<AlgoliaImportJob, RepoError> {
        let mut tx = self.pool.begin().await.map_err(repo_error)?;
        let current = self.lock_generation_fenced_target_job(&mut tx, id).await?;

        if generation != current.resume_intent_generation {
            return Err(RepoError::Conflict(
                "resume observation generation is stale".into(),
            ));
        }
        if current.status == AlgoliaImportJobStatus::CopyingDocuments {
            tx.commit().await.map_err(repo_error)?;
            return Ok(current);
        }
        if current.status != AlgoliaImportJobStatus::Resuming {
            return Err(RepoError::Conflict(
                "resume observation requires a resuming job".into(),
            ));
        }

        let merged = merged_summary(&current.summary, summary);
        let mut next = state_from_job(&current)?;
        next.status = AlgoliaImportJobStatus::CopyingDocuments;
        next.resume_count += 1;
        next.resumable = false;
        next.resume_mirror = None;
        next.summary = merged.clone();
        next.error_code = None;
        next.error_message = None;
        validate_transition(&current, &next)?;

        let updated = sqlx::query_as::<_, AlgoliaImportJobRow>(
            "UPDATE algolia_import_jobs
             SET status='copying_documents', resume_count=resume_count + 1,
                 resume_checkpoint=NULL, resume_status_observed_at=NULL, resume_deadline=NULL,
                 resumable=FALSE, documents_expected=$2, documents_imported=$3,
                 documents_rejected=$4, settings_applied=$5, settings_unsupported=$6,
                 synonyms_expected=$7, synonyms_imported=$8, synonyms_rejected=$9,
                 rules_expected=$10, rules_imported=$11, rules_rejected=$12,
                 error_code=NULL, error_message=NULL, updated_at=NOW()
             WHERE id=$1
             RETURNING *",
        )
        .bind(id)
        .bind(merged.documents_expected)
        .bind(merged.documents_imported)
        .bind(merged.documents_rejected)
        .bind(merged.settings_applied)
        .bind(merged.settings_unsupported)
        .bind(merged.synonyms_expected)
        .bind(merged.synonyms_imported)
        .bind(merged.synonyms_rejected)
        .bind(merged.rules_expected)
        .bind(merged.rules_imported)
        .bind(merged.rules_rejected)
        .fetch_one(&mut *tx)
        .await
        .map_err(repo_error)
        .map(AlgoliaImportJob::from)?;
        tx.commit().await.map_err(repo_error)?;
        Ok(updated)
    }

    async fn mark_engine_acknowledged(&self, id: Uuid) -> Result<AlgoliaImportJob, RepoError> {
        let mut tx = self.pool.begin().await.map_err(repo_error)?;
        let current = self.lock_generation_fenced_target_job(&mut tx, id).await?;
        if current.engine_ack_state == crate::models::AlgoliaImportEngineAckState::Acknowledged {
            tx.commit().await.map_err(repo_error)?;
            return Ok(current);
        }
        if current.engine_ack_state != crate::models::AlgoliaImportEngineAckState::OutboxPending
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
        .map(AlgoliaImportJob::from)?;
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
        let mut tx = self.pool.begin().await.map_err(repo_error)?;
        if let Err(error) = self
            .acquire_catalog_target_advisory_lock(&mut tx, customer_id, logical_target)
            .await
        {
            tx.rollback().await.map_err(repo_error)?;
            return Err(error);
        }
        let lifecycle_generation = match self
            .read_active_customer_generation(&mut tx, customer_id)
            .await
        {
            Ok(lifecycle_generation) => lifecycle_generation,
            Err(error) => {
                tx.rollback().await.map_err(repo_error)?;
                return Err(error);
            }
        };
        if let Err(error) = self
            .reject_active_target_reservation(&mut tx, customer_id, logical_target)
            .await
        {
            tx.rollback().await.map_err(repo_error)?;
            return Err(error);
        }
        Ok(CatalogLifecycleTargetGuard {
            tx,
            customer_id,
            logical_target: logical_target.to_string(),
            lifecycle_generation,
        })
    }

    async fn commit_lifecycle_target_guard(
        &self,
        guard: CatalogLifecycleTargetGuard,
        expected_identity: Option<&CatalogLifecycleTargetIdentity>,
    ) -> Result<(), RepoError> {
        let mut guard = guard;
        self.assert_catalog_target_identity(
            &mut guard.tx,
            guard.customer_id,
            &guard.logical_target,
            expected_identity,
        )
        .await?;
        guard.tx.commit().await.map_err(repo_error)
    }
}
