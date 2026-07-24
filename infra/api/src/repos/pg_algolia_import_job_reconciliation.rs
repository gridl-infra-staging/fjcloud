use chrono::{DateTime, Utc};
use sqlx::{Postgres, Transaction};
use uuid::Uuid;

use super::{
    support::{repo_error, state_from_job, validate_transition},
    PgAlgoliaImportJobRepo,
};
use crate::models::algolia_import_job::{
    AlgoliaImportDestinationKind, AlgoliaImportDispatchIntentState, AlgoliaImportEngineAckState,
    AlgoliaImportErrorCode, AlgoliaImportJob, AlgoliaImportJobRow, AlgoliaImportJobState,
    AlgoliaImportJobStatus, AlgoliaImportPublicationDisposition, AlgoliaImportSummary,
    AlgoliaImportTerminalFact,
};
use crate::models::vm_inventory::VmInventory;
use crate::repos::algolia_import_job_repo::{
    AlgoliaImportEngineAbsenceProof, AlgoliaImportReconciliationClaim,
    AlgoliaImportReconciliationLease, AlgoliaImportReconciliationWriteOutcome,
    AlgoliaImportTerminalFinalizationAuthority, AlgoliaImportTerminalFinalizationOutcome,
    CatalogLifecycleTargetIdentity,
};
use crate::repos::error::RepoError;
use crate::repos::{PgDeploymentRepo, PgTenantRepo};

const MAX_RECONCILIATION_CLAIM_BATCH: i64 = 100;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum TerminalCatalogEffect {
    Unchanged,
    PublishCreatePlacement,
    PublishReplacementPlacement,
}

pub(super) fn terminal_catalog_effect(
    destination_kind: AlgoliaImportDestinationKind,
    publication_disposition: AlgoliaImportPublicationDisposition,
) -> TerminalCatalogEffect {
    match (destination_kind, publication_disposition) {
        (AlgoliaImportDestinationKind::Create, AlgoliaImportPublicationDisposition::Promoted) => {
            TerminalCatalogEffect::PublishCreatePlacement
        }
        (AlgoliaImportDestinationKind::Replace, AlgoliaImportPublicationDisposition::Promoted) => {
            TerminalCatalogEffect::PublishReplacementPlacement
        }
        _ => TerminalCatalogEffect::Unchanged,
    }
}

struct TerminalStatePatch {
    state: AlgoliaImportJobState,
    terminal_at: DateTime<Utc>,
    destination_deployment_id: Option<Uuid>,
}

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
    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) async fn finalize_authenticated_engine_absence(
        &self,
        proof: AlgoliaImportEngineAbsenceProof,
    ) -> Result<AlgoliaImportTerminalFinalizationOutcome, RepoError> {
        let mut tx = self.pool.begin().await.map_err(repo_error)?;
        let current = match self
            .lock_generation_fenced_target_job(&mut tx, proof.job_id())
            .await
        {
            Ok(current) if current.lifecycle_generation == proof.lifecycle_generation() => current,
            Ok(_) | Err(RepoError::NotFound) | Err(RepoError::Conflict(_)) => {
                return Ok(AlgoliaImportTerminalFinalizationOutcome::FenceLost);
            }
            Err(error) => return Err(error),
        };
        if let Some(replay) = exact_seal_replay(&current, proof.terminal_at()) {
            tx.commit().await.map_err(repo_error)?;
            return Ok(replay);
        }
        if current.status != AlgoliaImportJobStatus::Cancelling
            || current.dispatch_intent_state == AlgoliaImportDispatchIntentState::Absent
            || current.engine_job_id.is_some()
        {
            return Ok(AlgoliaImportTerminalFinalizationOutcome::Rejected(
                "engine absence proof requires cancelling non-absent dispatch without engine id"
                    .into(),
            ));
        }
        let mut state = state_from_job(&current)?;
        state.status = AlgoliaImportJobStatus::Interrupted;
        state.publication_disposition = AlgoliaImportPublicationDisposition::NotStarted;
        state.engine_ack_state = AlgoliaImportEngineAckState::SealAcknowledged;
        state.retryable = false;
        state.resume_mirror = None;
        state.resumable = false;
        state.summary = AlgoliaImportSummary::default();
        state.error_code = Some(AlgoliaImportErrorCode::Interrupted);
        state.error_message = None;
        validate_transition(&current, &state)?;
        let updated = persist_terminal_state(
            &mut tx,
            current.id,
            &TerminalStatePatch {
                state,
                terminal_at: proof.terminal_at(),
                destination_deployment_id: current.destination_deployment_id,
            },
        )
        .await?;
        tx.commit().await.map_err(repo_error)?;
        Ok(AlgoliaImportTerminalFinalizationOutcome::Applied(updated))
    }

    pub(super) async fn finalize_no_dispatch_failure_inner(
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
        let current = self.lock_generation_fenced_target_job(&mut tx, id).await?;
        if current.dispatch_intent_state != AlgoliaImportDispatchIntentState::Absent
            || current.engine_job_id.is_some()
        {
            return Err(RepoError::Conflict(
                "job lacks absent dispatch-intent proof".into(),
            ));
        }
        let mut state = state_from_job(&current)?;
        state.status = AlgoliaImportJobStatus::Failed;
        state.publication_disposition = AlgoliaImportPublicationDisposition::NotStarted;
        state.engine_ack_state = AlgoliaImportEngineAckState::NotApplicable;
        state.retryable = false;
        state.resume_mirror = None;
        state.resumable = false;
        state.error_code = Some(error_code);
        state.error_message = error_message.map(str::to_owned);
        validate_transition(&current, &state)?;
        let updated = persist_terminal_state(
            &mut tx,
            current.id,
            &TerminalStatePatch {
                state,
                terminal_at: Utc::now(),
                destination_deployment_id: current.destination_deployment_id,
            },
        )
        .await?;
        tx.commit().await.map_err(repo_error)?;
        Ok(updated)
    }

    pub(super) async fn finalize_terminal_observation_inner(
        &self,
        authority: AlgoliaImportTerminalFinalizationAuthority,
        fact: AlgoliaImportTerminalFact,
    ) -> Result<AlgoliaImportTerminalFinalizationOutcome, RepoError> {
        if fact.status == crate::models::algolia_import_job::AlgoliaImportJobStatus::Interrupted
            && fact.publication_disposition == AlgoliaImportPublicationDisposition::NotStarted
        {
            return Ok(AlgoliaImportTerminalFinalizationOutcome::Rejected(
                "engine-linked terminal fact cannot be interrupted+not_started".into(),
            ));
        }

        let mut tx = self.pool.begin().await.map_err(repo_error)?;
        let current = match lock_terminal_authority(self, &mut tx, &authority).await? {
            Some(current) => current,
            None => return Ok(AlgoliaImportTerminalFinalizationOutcome::FenceLost),
        };
        if current.engine_job_id != Some(fact.engine_job_id) {
            return Ok(AlgoliaImportTerminalFinalizationOutcome::FenceLost);
        }
        if let Some(replay) = exact_terminal_replay(&current, &fact) {
            tx.commit().await.map_err(repo_error)?;
            return Ok(replay);
        }
        // A resumable engine observation is not a real terminal: the job still
        // owns a resume opportunity and must stay pending, reserved, and
        // alerting. Without this guard a Failed(resumable)->Failed transition
        // reads as an in-place update and would wrongly finalize the row and
        // release its reservation.
        if current.resumable {
            return Ok(AlgoliaImportTerminalFinalizationOutcome::Rejected(
                "resumable engine observation is not a finalizable terminal".into(),
            ));
        }
        if current
            .status
            .is_finally_terminal(current.resumable, current.publication_disposition)
        {
            return Ok(AlgoliaImportTerminalFinalizationOutcome::Rejected(
                "terminal replay conflicts with persisted terminal truth".into(),
            ));
        }

        let mut state = state_from_job(&current)?;
        state.status = fact.status;
        state.publication_disposition = fact.publication_disposition;
        state.engine_ack_state = AlgoliaImportEngineAckState::OutboxPending;
        state.retryable = false;
        state.resume_mirror = None;
        state.resumable = false;
        state.summary = fact.summary.clone();
        state.error_code = fact.error_code;
        state.error_message = fact.error_message.clone();
        validate_transition(&current, &state)?;
        let destination_deployment_id =
            match apply_terminal_catalog_effect(self, &mut tx, &current, &fact).await {
                Ok(destination_deployment_id) => destination_deployment_id,
                Err(TerminalCatalogError::Rejected(reason)) => {
                    return Ok(AlgoliaImportTerminalFinalizationOutcome::Rejected(reason));
                }
                Err(TerminalCatalogError::Repository(error)) => return Err(error),
            };

        let updated = persist_terminal_state(
            &mut tx,
            current.id,
            &TerminalStatePatch {
                state,
                terminal_at: fact.terminal_at,
                destination_deployment_id,
            },
        )
        .await?;
        tx.commit().await.map_err(repo_error)?;
        Ok(AlgoliaImportTerminalFinalizationOutcome::Applied(updated))
    }

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

enum TerminalCatalogError {
    Rejected(String),
    Repository(RepoError),
}

impl TerminalCatalogError {
    fn rejected(message: impl Into<String>) -> Self {
        Self::Rejected(message.into())
    }

    fn from_catalog_repo(error: RepoError) -> Self {
        match error {
            RepoError::Conflict(message) => Self::Rejected(message),
            RepoError::NotFound => Self::Rejected("destination_changed".into()),
            RepoError::Other(message) => Self::Repository(RepoError::Other(message)),
        }
    }
}

async fn apply_terminal_catalog_effect(
    repo: &PgAlgoliaImportJobRepo,
    tx: &mut Transaction<'_, Postgres>,
    current: &AlgoliaImportJob,
    fact: &AlgoliaImportTerminalFact,
) -> Result<Option<Uuid>, TerminalCatalogError> {
    match terminal_catalog_effect(current.destination_kind, fact.publication_disposition) {
        TerminalCatalogEffect::Unchanged => Ok(current.destination_deployment_id),
        TerminalCatalogEffect::PublishCreatePlacement => {
            publish_create_catalog_placement(tx, current).await
        }
        TerminalCatalogEffect::PublishReplacementPlacement => {
            verify_replacement_catalog_placement(repo, tx, current).await
        }
    }
}

async fn persist_terminal_state(
    tx: &mut Transaction<'_, Postgres>,
    id: Uuid,
    patch: &TerminalStatePatch,
) -> Result<AlgoliaImportJob, RepoError> {
    let summary = &patch.state.summary;
    sqlx::query_as::<_, AlgoliaImportJobRow>(
        "UPDATE algolia_import_jobs SET status=$2, publication_disposition=$3,
         engine_ack_state=$4, retryable=FALSE,
         resume_checkpoint=NULL, resume_status_observed_at=NULL,
         resume_deadline=NULL, resumable=FALSE,
         documents_expected=$5, documents_imported=$6, documents_rejected=$7,
         settings_applied=$8, settings_unsupported=$9,
         synonyms_expected=$10, synonyms_imported=$11, synonyms_rejected=$12,
         rules_expected=$13, rules_imported=$14, rules_rejected=$15,
         error_code=$16, error_message=$17, terminal_at=$18,
         destination_deployment_id=$19,
         worker_claimed_at=NULL, worker_lease_expires_at=NULL, updated_at=NOW()
         WHERE id=$1
         RETURNING *",
    )
    .bind(id)
    .bind(patch.state.status.as_str())
    .bind(patch.state.publication_disposition.as_str())
    .bind(patch.state.engine_ack_state.as_str())
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
    .bind(patch.state.error_code.map(AlgoliaImportErrorCode::as_str))
    .bind(&patch.state.error_message)
    .bind(patch.terminal_at)
    .bind(patch.destination_deployment_id)
    .fetch_one(&mut **tx)
    .await
    .map_err(repo_error)
    .map(AlgoliaImportJob::from)
}

async fn publish_create_catalog_placement(
    tx: &mut Transaction<'_, Postgres>,
    current: &AlgoliaImportJob,
) -> Result<Option<Uuid>, TerminalCatalogError> {
    if current.destination_deployment_id.is_some() {
        return Err(TerminalCatalogError::rejected(
            "create finalization cannot overwrite an existing deployment placement",
        ));
    }
    let vm = lock_create_destination_vm(tx, current).await?;
    let deployment = PgDeploymentRepo::create_running_shared_deployment_tx(
        tx,
        current.customer_id,
        &current.destination_region,
        &vm,
    )
    .await
    .map_err(TerminalCatalogError::from_catalog_repo)?;
    let intent = PgTenantRepo::create_lifecycle_intent_tx(
        tx,
        current.customer_id,
        &current.logical_target,
        deployment.id,
        "provisioning",
    )
    .await
    .map_err(TerminalCatalogError::from_catalog_repo)?;
    let expected_identity = CatalogLifecycleTargetIdentity {
        deployment_id: intent.deployment_id,
        vm_id: None,
        tier: "provisioning".to_string(),
        cold_snapshot_id: None,
        service_type: "flapjack".to_string(),
    };
    PgTenantRepo::publish_lifecycle_placement_tx(
        tx,
        current.customer_id,
        &current.logical_target,
        &expected_identity,
        Some(vm.id),
    )
    .await
    .map_err(TerminalCatalogError::from_catalog_repo)?;
    Ok(Some(deployment.id))
}

async fn verify_replacement_catalog_placement(
    repo: &PgAlgoliaImportJobRepo,
    tx: &mut Transaction<'_, Postgres>,
    current: &AlgoliaImportJob,
) -> Result<Option<Uuid>, TerminalCatalogError> {
    let deployment_id = current.destination_deployment_id.ok_or_else(|| {
        TerminalCatalogError::rejected("replacement finalization is missing deployment identity")
    })?;
    let vm_id = current.destination_vm_id.ok_or_else(|| {
        TerminalCatalogError::rejected("replacement finalization is missing VM identity")
    })?;
    let expected_physical_uid = crate::services::flapjack_node::flapjack_index_uid(
        current.customer_id,
        &current.logical_target,
    );
    if current.physical_uid.as_deref() != Some(expected_physical_uid.as_str())
        || current.routing_identity.as_deref() != Some(expected_physical_uid.as_str())
    {
        return Err(TerminalCatalogError::rejected("destination_changed"));
    }
    repo.assert_catalog_target_identity(
        tx,
        current.customer_id,
        &current.logical_target,
        Some(&CatalogLifecycleTargetIdentity {
            deployment_id,
            vm_id: Some(vm_id),
            tier: "active".to_string(),
            cold_snapshot_id: None,
            service_type: "flapjack".to_string(),
        }),
    )
    .await
    .map_err(|error| TerminalCatalogError::Rejected(error.to_string()))?;
    let expected_identity = CatalogLifecycleTargetIdentity {
        deployment_id,
        vm_id: Some(vm_id),
        tier: "active".to_string(),
        cold_snapshot_id: None,
        service_type: "flapjack".to_string(),
    };
    PgTenantRepo::publish_lifecycle_placement_tx(
        tx,
        current.customer_id,
        &current.logical_target,
        &expected_identity,
        Some(vm_id),
    )
    .await
    .map_err(TerminalCatalogError::from_catalog_repo)?;
    Ok(Some(deployment_id))
}

async fn lock_create_destination_vm(
    tx: &mut Transaction<'_, Postgres>,
    current: &AlgoliaImportJob,
) -> Result<VmInventory, TerminalCatalogError> {
    let vm_id = current.destination_vm_id.ok_or_else(|| {
        TerminalCatalogError::rejected("create finalization is missing VM identity")
    })?;
    let physical_uid = current.physical_uid.as_deref().ok_or_else(|| {
        TerminalCatalogError::rejected("create finalization is missing physical UID")
    })?;
    if current.routing_identity.as_deref() != Some(physical_uid) {
        return Err(TerminalCatalogError::rejected("destination_changed"));
    }
    let vm =
        sqlx::query_as::<_, VmInventory>("SELECT * FROM vm_inventory WHERE id = $1 FOR UPDATE")
            .bind(vm_id)
            .fetch_optional(&mut **tx)
            .await
            .map_err(repo_error)
            .map_err(TerminalCatalogError::Repository)?
            .ok_or_else(|| TerminalCatalogError::rejected("destination_changed"))?;
    if vm.region != current.destination_region
        || vm.status != "active"
        || vm.flapjack_url.is_empty()
    {
        return Err(TerminalCatalogError::rejected("destination_changed"));
    }
    Ok(vm)
}

async fn lock_terminal_authority(
    repo: &PgAlgoliaImportJobRepo,
    tx: &mut Transaction<'_, Postgres>,
    authority: &AlgoliaImportTerminalFinalizationAuthority,
) -> Result<Option<AlgoliaImportJob>, RepoError> {
    match authority {
        AlgoliaImportTerminalFinalizationAuthority::ReconciliationLease(lease) => {
            let current = sqlx::query_as::<_, AlgoliaImportJobRow>(
                "SELECT job.*
                 FROM algolia_import_jobs AS job
                 JOIN customers AS customer ON customer.id = job.customer_id
                 WHERE job.id = $1
                   AND job.erased_at IS NULL
                   AND customer.status = 'active'
                   AND customer.lifecycle_generation = job.lifecycle_generation
                   AND job.lifecycle_generation = $2
                 FOR UPDATE OF customer, job",
            )
            .bind(lease.job_id)
            .bind(lease.lifecycle_generation)
            .fetch_optional(&mut **tx)
            .await
            .map_err(repo_error)
            .map(|row| row.map(AlgoliaImportJob::from))?;
            let Some(current) = current else {
                return Ok(None);
            };
            let lease_matches = current.worker_claimed_at == Some(lease.claimed_at)
                && current.worker_lease_expires_at == Some(lease.expires_at);
            if lease_matches
                || current
                    .status
                    .is_finally_terminal(current.resumable, current.publication_disposition)
            {
                Ok(Some(current))
            } else {
                Ok(None)
            }
        }
        AlgoliaImportTerminalFinalizationAuthority::ImmediateCancel {
            job_id,
            lifecycle_generation,
            engine_job_id,
        } => {
            let current = match repo.lock_generation_fenced_target_job(tx, *job_id).await {
                Ok(current) => current,
                Err(RepoError::NotFound) | Err(RepoError::Conflict(_)) => return Ok(None),
                Err(error) => return Err(error),
            };
            if current.lifecycle_generation == *lifecycle_generation
                && current.engine_job_id == Some(*engine_job_id)
            {
                Ok(Some(current))
            } else {
                Ok(None)
            }
        }
    }
}

#[cfg_attr(not(test), allow(dead_code))]
fn exact_seal_replay(
    current: &AlgoliaImportJob,
    terminal_at: DateTime<Utc>,
) -> Option<AlgoliaImportTerminalFinalizationOutcome> {
    if !current
        .status
        .is_finally_terminal(current.resumable, current.publication_disposition)
    {
        return None;
    }
    if current.status == AlgoliaImportJobStatus::Interrupted
        && current.publication_disposition == AlgoliaImportPublicationDisposition::NotStarted
        && current.engine_ack_state == AlgoliaImportEngineAckState::SealAcknowledged
        && current.dispatch_intent_state != AlgoliaImportDispatchIntentState::Absent
        && current.engine_job_id.is_none()
        && current.terminal_at == Some(terminal_at)
    {
        Some(AlgoliaImportTerminalFinalizationOutcome::AlreadyApplied(
            current.clone(),
        ))
    } else {
        Some(AlgoliaImportTerminalFinalizationOutcome::Rejected(
            "terminal replay conflicts with persisted terminal truth".into(),
        ))
    }
}

fn exact_terminal_replay(
    current: &AlgoliaImportJob,
    fact: &AlgoliaImportTerminalFact,
) -> Option<AlgoliaImportTerminalFinalizationOutcome> {
    if !current
        .status
        .is_finally_terminal(current.resumable, current.publication_disposition)
    {
        return None;
    }
    if current.status == fact.status
        && current.publication_disposition == fact.publication_disposition
        && current.summary == fact.summary
        && current.error_code == fact.error_code
        && current.error_message == fact.error_message
        && current.terminal_at == Some(fact.terminal_at)
        && matches!(
            current.engine_ack_state,
            AlgoliaImportEngineAckState::OutboxPending | AlgoliaImportEngineAckState::Acknowledged
        )
    {
        Some(AlgoliaImportTerminalFinalizationOutcome::AlreadyApplied(
            current.clone(),
        ))
    } else {
        Some(AlgoliaImportTerminalFinalizationOutcome::Rejected(
            "terminal replay conflicts with persisted terminal truth".into(),
        ))
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
