use chrono::{DateTime, Utc};
use sqlx::{Postgres, Transaction};
use uuid::Uuid;

use super::{
    support::{
        catalog_lifecycle_target_lock_name, is_stale_customer_generation_error, merged_summary,
        repo_error, state_from_job, validate_transition,
    },
    PgAlgoliaImportJobRepo,
};
use crate::models::algolia_import_job::{
    AlgoliaImportDestinationKind, AlgoliaImportErrorCode, AlgoliaImportJob, AlgoliaImportJobRow,
    AlgoliaImportJobStatus, AlgoliaImportSummary,
};
use crate::repos::advisory_lock::{acquire_in_process_named_lock, is_connection_error};
use crate::repos::algolia_import_job_repo::{
    AlgoliaImportCancelDispatch, AlgoliaImportCancelOutcome, AlgoliaImportJobAdmissionError,
    AlgoliaImportResumeDispatch, AlgoliaImportResumeOutcome, AlgoliaImportTransitionDisposition,
    AlgoliaLifecycleError, CatalogLifecycleTargetGuard, CatalogLifecycleTargetGuardState,
    CatalogLifecycleTargetIdentity,
};
use crate::repos::error::RepoError;

/// Internal refusal produced by the shared cancel/resume transition core, before
/// it is projected onto either the id-only `RepoError` contract (engine-facing)
/// or the customer-scoped [`AlgoliaLifecycleError`] boundary (HTTP-facing). This
/// keeps the transition rules in one place while the two entrypoints differ only
/// in how a refusal is surfaced.
enum LifecycleTransitionError {
    Refused(AlgoliaImportErrorCode),
    Repository(RepoError),
}

impl From<RepoError> for LifecycleTransitionError {
    fn from(error: RepoError) -> Self {
        LifecycleTransitionError::Repository(error)
    }
}

impl From<LifecycleTransitionError> for RepoError {
    fn from(error: LifecycleTransitionError) -> Self {
        match error {
            LifecycleTransitionError::Refused(code) => RepoError::Conflict(code.as_str().into()),
            LifecycleTransitionError::Repository(error) => error,
        }
    }
}

impl From<LifecycleTransitionError> for AlgoliaLifecycleError {
    fn from(error: LifecycleTransitionError) -> Self {
        match error {
            LifecycleTransitionError::Refused(code) => AlgoliaLifecycleError::Refused(code),
            LifecycleTransitionError::Repository(error) => AlgoliaLifecycleError::Repository(error),
        }
    }
}

fn stale_customer_lifecycle_error(
    error: RepoError,
    refusal_code: AlgoliaImportErrorCode,
) -> AlgoliaLifecycleError {
    if is_stale_customer_generation_error(&error) {
        AlgoliaLifecycleError::Refused(refusal_code)
    } else {
        error.into()
    }
}

impl PgAlgoliaImportJobRepo {
    pub async fn assert_guarded_target_identity(
        &self,
        guard: &mut CatalogLifecycleTargetGuard,
        expected_identity: Option<&CatalogLifecycleTargetIdentity>,
    ) -> Result<(), RepoError> {
        match &mut guard.state {
            CatalogLifecycleTargetGuardState::Fenced { tx } => self
                .assert_catalog_target_identity(
                    tx,
                    guard.customer_id,
                    &guard.logical_target,
                    expected_identity,
                )
                .await
                .map_err(RepoError::from),
            CatalogLifecycleTargetGuardState::InProcess { .. } => Ok(()),
        }
    }

    pub async fn commit_guarded_target_mutation(
        &self,
        guard: CatalogLifecycleTargetGuard,
    ) -> Result<(), RepoError> {
        match guard.state {
            CatalogLifecycleTargetGuardState::Fenced { tx } => {
                tx.commit().await.map_err(repo_error)
            }
            CatalogLifecycleTargetGuardState::InProcess { .. } => Ok(()),
        }
    }

    /// Shared cancel transition over an already row-locked `current` job within
    /// `tx`. Sole owner of the cancel rule set; both the id-only and the
    /// customer-scoped entrypoints call it after locking so the rules are never
    /// duplicated. Does not commit; the caller owns the transaction boundary.
    async fn apply_cancel_locked(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        current: AlgoliaImportJob,
    ) -> Result<AlgoliaImportCancelOutcome, LifecycleTransitionError> {
        if matches!(
            current.status,
            AlgoliaImportJobStatus::Cancelling | AlgoliaImportJobStatus::Cancelled
        ) {
            return Ok(AlgoliaImportCancelOutcome {
                job: current,
                dispatch: None,
                disposition: AlgoliaImportTransitionDisposition::Replayed,
            });
        }
        if current
            .status
            .is_finally_terminal(current.resumable, current.publication_disposition)
        {
            return Err(LifecycleTransitionError::Refused(
                AlgoliaImportErrorCode::CancelNotPermitted,
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
        .bind(current.id)
        .fetch_one(&mut **tx)
        .await
        .map_err(repo_error)
        .map(AlgoliaImportJob::from)?;

        let dispatch = updated
            .engine_job_id
            .is_some()
            .then_some(AlgoliaImportCancelDispatch {
                job_id: updated.cloud_job_id,
            });
        Ok(AlgoliaImportCancelOutcome {
            job: updated,
            dispatch,
            disposition: AlgoliaImportTransitionDisposition::Accepted,
        })
    }

    /// Shared resume transition over an already row-locked `current` job within
    /// `tx`. Sole owner of the resume rule set (idempotent replay, non-resumable
    /// refusal, generation bump). The elapsed-deadline gate is enforced by the
    /// customer-scoped caller before this runs, so a `Resuming` replay (which has
    /// no deadline) still returns cleanly. Does not commit.
    async fn apply_resume_locked(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        current: AlgoliaImportJob,
    ) -> Result<AlgoliaImportResumeOutcome, LifecycleTransitionError> {
        if current.status == AlgoliaImportJobStatus::Resuming {
            return Ok(AlgoliaImportResumeOutcome {
                generation: current.resume_intent_generation,
                expected_attempt: current.resume_count + 1,
                job: current,
                dispatch: None,
                disposition: AlgoliaImportTransitionDisposition::Replayed,
            });
        }
        if !current.resumable {
            return Err(LifecycleTransitionError::Refused(
                AlgoliaImportErrorCode::NotResumable,
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
        .bind(current.id)
        .bind(generation)
        .fetch_one(&mut **tx)
        .await
        .map_err(repo_error)
        .map(AlgoliaImportJob::from)?;

        Ok(AlgoliaImportResumeOutcome {
            generation,
            expected_attempt,
            dispatch: Some(AlgoliaImportResumeDispatch {
                job_id: updated.cloud_job_id,
                generation,
                expected_attempt,
            }),
            job: updated,
            disposition: AlgoliaImportTransitionDisposition::Accepted,
        })
    }

    pub(super) async fn request_cancel_inner(
        &self,
        id: Uuid,
    ) -> Result<AlgoliaImportCancelOutcome, RepoError> {
        let mut tx = self.pool.begin().await.map_err(repo_error)?;
        let current = self.lock_generation_fenced_target_job(&mut tx, id).await?;
        let outcome = self
            .apply_cancel_locked(&mut tx, current)
            .await
            .map_err(RepoError::from)?;
        tx.commit().await.map_err(repo_error)?;
        Ok(outcome)
    }

    pub(super) async fn request_cancel_for_customer_inner(
        &self,
        customer_id: Uuid,
        id: Uuid,
    ) -> Result<AlgoliaImportCancelOutcome, AlgoliaLifecycleError> {
        let mut tx = self.pool.begin().await.map_err(repo_error)?;
        let current = self
            .lock_generation_fenced_target_job_for_customer(&mut tx, customer_id, id)
            .await
            .map_err(|error| {
                stale_customer_lifecycle_error(error, AlgoliaImportErrorCode::CancelNotPermitted)
            })?;
        let outcome = self.apply_cancel_locked(&mut tx, current).await?;
        tx.commit().await.map_err(repo_error)?;
        Ok(outcome)
    }

    pub(super) async fn prepare_resume_inner(
        &self,
        id: Uuid,
    ) -> Result<AlgoliaImportResumeOutcome, RepoError> {
        let mut tx = self.pool.begin().await.map_err(repo_error)?;
        let current = self.lock_generation_fenced_target_job(&mut tx, id).await?;
        let outcome = self
            .apply_resume_locked(&mut tx, current)
            .await
            .map_err(RepoError::from)?;
        tx.commit().await.map_err(repo_error)?;
        Ok(outcome)
    }

    pub(super) async fn prepare_resume_for_customer_inner(
        &self,
        customer_id: Uuid,
        id: Uuid,
        now: DateTime<Utc>,
    ) -> Result<AlgoliaImportResumeOutcome, AlgoliaLifecycleError> {
        let mut tx = self.pool.begin().await.map_err(repo_error)?;
        let current = self
            .lock_generation_fenced_target_job_for_customer(&mut tx, customer_id, id)
            .await
            .map_err(|error| {
                stale_customer_lifecycle_error(error, AlgoliaImportErrorCode::NotResumable)
            })?;
        // A resumable job whose resume window has already closed is no longer
        // resumable; the deadline is gated on the locked row before any mutation.
        // A `Resuming` replay clears its deadline, so this never blocks a replay.
        if let Some(deadline) = current.resume_deadline {
            if deadline <= now {
                return Err(AlgoliaLifecycleError::Refused(
                    AlgoliaImportErrorCode::NotResumable,
                ));
            }
        }
        if current.status != AlgoliaImportJobStatus::Resuming
            && current.destination_kind == AlgoliaImportDestinationKind::Replace
        {
            self.validate_resume_replace_target_ready(&mut tx, &current)
                .await
                .map_err(|error| match error {
                    AlgoliaImportJobAdmissionError::Refused(_) => {
                        AlgoliaLifecycleError::Refused(AlgoliaImportErrorCode::BackendUnavailable)
                    }
                    AlgoliaImportJobAdmissionError::Repository(error) => {
                        AlgoliaLifecycleError::Repository(error)
                    }
                })?;
        }
        let outcome = self.apply_resume_locked(&mut tx, current).await?;
        tx.commit().await.map_err(repo_error)?;
        Ok(outcome)
    }

    pub(super) async fn record_resume_accepted_inner(
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

    pub(super) async fn begin_lifecycle_target_guard_inner(
        &self,
        customer_id: Uuid,
        logical_target: &str,
    ) -> Result<CatalogLifecycleTargetGuard, RepoError> {
        let mut tx = match self.pool.begin().await {
            Ok(tx) => tx,
            Err(error) if is_connection_error(&error) => {
                // This fallback serializes only the current API process. During a
                // real database outage, downstream writes using this pool normally
                // fail too; if PostgreSQL recovers mid-mutation, separate API
                // processes can still race because this is not PostgreSQL fencing.
                let lock_name = catalog_lifecycle_target_lock_name(customer_id, logical_target);
                let guard = acquire_in_process_named_lock(&lock_name).await;
                return Ok(CatalogLifecycleTargetGuard {
                    state: CatalogLifecycleTargetGuardState::InProcess { _guard: guard },
                    customer_id,
                    logical_target: logical_target.to_string(),
                    lifecycle_generation: 0,
                });
            }
            Err(error) => return Err(repo_error(error)),
        };
        if let Err(error) = self
            .acquire_catalog_target_advisory_lock(&mut tx, customer_id, logical_target)
            .await
        {
            tx.rollback().await.map_err(repo_error)?;
            return Err(RepoError::from(error));
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
            return Err(RepoError::from(error));
        }
        Ok(CatalogLifecycleTargetGuard {
            state: CatalogLifecycleTargetGuardState::Fenced { tx },
            customer_id,
            logical_target: logical_target.to_string(),
            lifecycle_generation,
        })
    }

    pub(super) async fn commit_lifecycle_target_guard_inner(
        &self,
        guard: CatalogLifecycleTargetGuard,
        expected_identity: Option<&CatalogLifecycleTargetIdentity>,
    ) -> Result<(), RepoError> {
        let mut guard = guard;
        match &mut guard.state {
            CatalogLifecycleTargetGuardState::Fenced { tx } => {
                self.assert_catalog_target_identity(
                    tx,
                    guard.customer_id,
                    &guard.logical_target,
                    expected_identity,
                )
                .await
                .map_err(RepoError::from)?;
            }
            CatalogLifecycleTargetGuardState::InProcess { .. } => {}
        }
        self.commit_guarded_target_mutation(guard).await
    }
}
