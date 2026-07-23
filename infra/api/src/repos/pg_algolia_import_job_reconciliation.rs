use chrono::{DateTime, Utc};
use sqlx::{Postgres, Transaction};
use uuid::Uuid;

use super::{
    support::{repo_error, validate_transition},
    PgAlgoliaImportJobRepo,
};
use crate::models::algolia_import_job::{
    AlgoliaImportEngineAckState, AlgoliaImportErrorCode, AlgoliaImportJob, AlgoliaImportJobRow,
    AlgoliaImportJobState,
};
use crate::repos::algolia_import_job_repo::{
    AlgoliaImportReconciliationClaim, AlgoliaImportReconciliationLease,
    AlgoliaImportReconciliationWriteOutcome,
};
use crate::repos::error::RepoError;

const MAX_RECONCILIATION_CLAIM_BATCH: i64 = 100;

pub(super) fn validate_state_write(
    current: &AlgoliaImportJob,
    state: &AlgoliaImportJobState,
) -> Result<(), RepoError> {
    if current.engine_ack_state == AlgoliaImportEngineAckState::NotApplicable {
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
    validate_transition(current, state)
}

pub(super) async fn persist_job_state(
    tx: &mut Transaction<'_, Postgres>,
    id: Uuid,
    state: &AlgoliaImportJobState,
    release_worker_lease: bool,
) -> Result<AlgoliaImportJob, RepoError> {
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
    sqlx::query_as::<_, AlgoliaImportJobRow>(
        "UPDATE algolia_import_jobs SET status=$2, publication_disposition=$3,
         engine_ack_state=$4, lifecycle_generation=$5, retryable=$6,
         resume_intent_generation=$7, documents_expected=$8, documents_imported=$9,
         documents_rejected=$10, settings_applied=$11, settings_unsupported=$12,
         synonyms_expected=$13, synonyms_imported=$14, synonyms_rejected=$15,
         rules_expected=$16, rules_imported=$17, rules_rejected=$18, warnings=$19,
         error_code=$20, error_message=$21, updated_at=NOW(),
         resume_checkpoint=$22, resume_status_observed_at=$23,
         resume_deadline=$24, resumable=$25, resume_count=$26,
         worker_claimed_at=CASE WHEN $27 THEN NULL ELSE worker_claimed_at END,
         worker_lease_expires_at=CASE WHEN $27 THEN NULL ELSE worker_lease_expires_at END
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
    .bind(release_worker_lease)
    .fetch_one(&mut **tx)
    .await
    .map_err(repo_error)
    .map(AlgoliaImportJob::from)
}

impl PgAlgoliaImportJobRepo {
    pub(super) async fn claim_reconciliation_jobs_inner(
        &self,
        now: DateTime<Utc>,
        lease_expires_at: DateTime<Utc>,
        limit: i64,
    ) -> Result<Vec<AlgoliaImportReconciliationClaim>, RepoError> {
        if limit <= 0 {
            return Ok(Vec::new());
        }
        if lease_expires_at <= now {
            return Err(RepoError::Conflict(
                "reconciliation lease must expire after claim time".into(),
            ));
        }
        let rows = sqlx::query_as::<_, AlgoliaImportJobRow>(
            "WITH candidates AS (
                 SELECT job.id
                 FROM algolia_import_jobs AS job
                 JOIN customers AS customer ON customer.id = job.customer_id
                 WHERE job.erased_at IS NULL
                   AND customer.status = 'active'
                   AND customer.lifecycle_generation = job.lifecycle_generation
                   AND job.engine_ack_state = 'pending'
                   AND job.dispatch_intent_state IN ('ambiguous', 'committed')
                   AND job.engine_job_id IS NOT NULL
                   AND (job.worker_lease_expires_at IS NULL
                        OR job.worker_lease_expires_at <= $1)
                 ORDER BY job.updated_at, job.id
                 LIMIT $3
                 FOR UPDATE OF customer, job SKIP LOCKED
             )
             UPDATE algolia_import_jobs AS job
             SET worker_claimed_at = $1, worker_lease_expires_at = $2
             FROM candidates
             WHERE job.id = candidates.id
             RETURNING job.*",
        )
        .bind(now)
        .bind(lease_expires_at)
        .bind(limit.min(MAX_RECONCILIATION_CLAIM_BATCH))
        .fetch_all(&self.pool)
        .await
        .map_err(repo_error)?;

        let mut claims = rows
            .into_iter()
            .map(AlgoliaImportJob::from)
            .map(AlgoliaImportReconciliationClaim::try_from)
            .collect::<Result<Vec<_>, _>>()?;
        claims.sort_by_key(|claim| (claim.job.updated_at, claim.job.id));
        Ok(claims)
    }

    pub(super) async fn record_reconciliation_observation_inner(
        &self,
        lease: &AlgoliaImportReconciliationLease,
        observed_at: DateTime<Utc>,
        state: AlgoliaImportJobState,
    ) -> Result<AlgoliaImportReconciliationWriteOutcome, RepoError> {
        if lease.expires_at <= observed_at {
            return Ok(AlgoliaImportReconciliationWriteOutcome::LeaseLost);
        }
        let mut tx = self.pool.begin().await.map_err(repo_error)?;
        let current = sqlx::query_as::<_, AlgoliaImportJobRow>(
            "SELECT job.*
             FROM algolia_import_jobs AS job
             JOIN customers AS customer ON customer.id = job.customer_id
             WHERE job.id = $1
               AND job.erased_at IS NULL
               AND customer.status = 'active'
               AND customer.lifecycle_generation = job.lifecycle_generation
               AND job.lifecycle_generation = $2
               AND job.worker_claimed_at = $3
               AND job.worker_lease_expires_at = $4
               AND job.worker_lease_expires_at > $5
             FOR UPDATE OF customer, job",
        )
        .bind(lease.job_id)
        .bind(lease.lifecycle_generation)
        .bind(lease.claimed_at)
        .bind(lease.expires_at)
        .bind(observed_at)
        .fetch_optional(&mut *tx)
        .await
        .map_err(repo_error)?
        .map(AlgoliaImportJob::from);
        let Some(current) = current else {
            return Ok(AlgoliaImportReconciliationWriteOutcome::LeaseLost);
        };

        validate_state_write(&current, &state)?;
        let unavailable_state_changed = (current.error_code
            == Some(AlgoliaImportErrorCode::BackendUnavailable))
            != (state.error_code == Some(AlgoliaImportErrorCode::BackendUnavailable));
        persist_job_state(&mut tx, lease.job_id, &state, true).await?;
        tx.commit().await.map_err(repo_error)?;
        Ok(AlgoliaImportReconciliationWriteOutcome::Applied {
            unavailable_state_changed,
        })
    }
}

impl TryFrom<AlgoliaImportJob> for AlgoliaImportReconciliationClaim {
    type Error = RepoError;

    fn try_from(job: AlgoliaImportJob) -> Result<Self, Self::Error> {
        let claimed_at = job.worker_claimed_at.ok_or_else(|| {
            RepoError::Conflict("reconciliation claim is missing its claim timestamp".into())
        })?;
        let expires_at = job.worker_lease_expires_at.ok_or_else(|| {
            RepoError::Conflict("reconciliation claim is missing its lease expiry".into())
        })?;
        Ok(Self {
            lease: AlgoliaImportReconciliationLease {
                job_id: job.id,
                lifecycle_generation: job.lifecycle_generation,
                claimed_at,
                expires_at,
            },
            job,
        })
    }
}
