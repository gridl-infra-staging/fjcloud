use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration as StdDuration;

use async_trait::async_trait;
use chrono::{DateTime, Duration, Utc};
use uuid::Uuid;

use crate::models::algolia_import_job::{AlgoliaImportErrorCode, AlgoliaImportJobState};
use crate::repos::{
    AlgoliaImportEngineAckOutcome, AlgoliaImportJobRepo, AlgoliaImportReconciliationClaim,
    AlgoliaImportReconciliationLease, AlgoliaImportReconciliationWriteOutcome,
    AlgoliaImportTerminalFinalizationAuthority, AlgoliaImportTerminalFinalizationOutcome,
    RepoError, VmInventoryRepo,
};
use crate::services::alerting::{Alert, AlertService, AlertSeverity};

use super::{
    AlgoliaImportEngineOperation, AlgoliaImportObservationCursor, AlgoliaImportService,
    AlgoliaImportStatusObservation, EngineTarget,
};

const DEFAULT_RECONCILIATION_BATCH_SIZE: i64 = 4;
const DEFAULT_RECONCILIATION_INTERVAL: StdDuration = StdDuration::from_secs(30);
const DEFAULT_RECONCILIATION_LEASE_DURATION: Duration = Duration::minutes(5);

#[derive(Debug, Clone, Copy)]
pub(crate) struct AlgoliaImportReconciliationConfig {
    pub(crate) interval: StdDuration,
    pub(crate) lease_duration: Duration,
    pub(crate) batch_size: i64,
}

impl Default for AlgoliaImportReconciliationConfig {
    fn default() -> Self {
        Self {
            interval: DEFAULT_RECONCILIATION_INTERVAL,
            lease_duration: DEFAULT_RECONCILIATION_LEASE_DURATION,
            batch_size: DEFAULT_RECONCILIATION_BATCH_SIZE,
        }
    }
}

#[async_trait]
pub(crate) trait AlgoliaImportReconciliationStore: Send + Sync {
    async fn claim_reconciliation_jobs(
        &self,
        now: DateTime<Utc>,
        lease_expires_at: DateTime<Utc>,
        limit: i64,
    ) -> Result<Vec<AlgoliaImportReconciliationClaim>, RepoError>;

    async fn record_reconciliation_observation(
        &self,
        lease: &AlgoliaImportReconciliationLease,
        observed_at: DateTime<Utc>,
        state: AlgoliaImportJobState,
    ) -> Result<AlgoliaImportReconciliationWriteOutcome, RepoError>;

    async fn finalize_terminal_observation(
        &self,
        authority: AlgoliaImportTerminalFinalizationAuthority,
        fact: crate::models::algolia_import_job::AlgoliaImportTerminalFact,
    ) -> Result<AlgoliaImportTerminalFinalizationOutcome, RepoError>;

    async fn mark_engine_acknowledged(
        &self,
        id: Uuid,
    ) -> Result<AlgoliaImportEngineAckOutcome, RepoError>;
}

#[async_trait]
impl<T> AlgoliaImportReconciliationStore for T
where
    T: AlgoliaImportJobRepo + Send + Sync,
{
    async fn claim_reconciliation_jobs(
        &self,
        now: DateTime<Utc>,
        lease_expires_at: DateTime<Utc>,
        limit: i64,
    ) -> Result<Vec<AlgoliaImportReconciliationClaim>, RepoError> {
        AlgoliaImportJobRepo::claim_reconciliation_jobs(self, now, lease_expires_at, limit).await
    }

    async fn record_reconciliation_observation(
        &self,
        lease: &AlgoliaImportReconciliationLease,
        observed_at: DateTime<Utc>,
        state: AlgoliaImportJobState,
    ) -> Result<AlgoliaImportReconciliationWriteOutcome, RepoError> {
        AlgoliaImportJobRepo::record_reconciliation_observation(self, lease, observed_at, state)
            .await
    }

    async fn finalize_terminal_observation(
        &self,
        authority: AlgoliaImportTerminalFinalizationAuthority,
        fact: crate::models::algolia_import_job::AlgoliaImportTerminalFact,
    ) -> Result<AlgoliaImportTerminalFinalizationOutcome, RepoError> {
        AlgoliaImportJobRepo::finalize_terminal_observation(self, authority, fact).await
    }

    async fn mark_engine_acknowledged(
        &self,
        id: Uuid,
    ) -> Result<AlgoliaImportEngineAckOutcome, RepoError> {
        AlgoliaImportJobRepo::mark_engine_acknowledged(self, id).await
    }
}

pub(crate) struct AlgoliaImportReconciliationRuntime<S> {
    store: Arc<S>,
    vm_repo: Arc<dyn VmInventoryRepo + Send + Sync>,
    alert_service: Arc<dyn AlertService>,
    config: AlgoliaImportReconciliationConfig,
}

impl<S> AlgoliaImportReconciliationRuntime<S> {
    pub(crate) fn new(
        store: Arc<S>,
        vm_repo: Arc<dyn VmInventoryRepo + Send + Sync>,
        alert_service: Arc<dyn AlertService>,
        config: AlgoliaImportReconciliationConfig,
    ) -> Self {
        Self {
            store,
            vm_repo,
            alert_service,
            config,
        }
    }
}

#[derive(Debug, Default)]
pub(crate) struct AlgoliaImportReconcileOnceReport {
    pub(crate) claimed: usize,
    pub(crate) persisted: usize,
    pub(crate) lease_lost: usize,
    pub(crate) terminal_finalized: usize,
    pub(crate) terminal_already_applied: usize,
    pub(crate) terminal_rejected: usize,
}

enum ClaimObservation {
    Persisted,
    LeaseLost,
    TerminalFinalized,
    TerminalAlreadyApplied,
    TerminalRejected,
}

impl AlgoliaImportService {
    pub(crate) async fn reconcile_once<S>(
        &self,
        runtime: &AlgoliaImportReconciliationRuntime<S>,
        now: DateTime<Utc>,
    ) -> Result<AlgoliaImportReconcileOnceReport, RepoError>
    where
        S: AlgoliaImportReconciliationStore,
    {
        let claims = runtime
            .store
            .claim_reconciliation_jobs(
                now,
                now + runtime.config.lease_duration,
                runtime.config.batch_size,
            )
            .await?;
        let mut report = AlgoliaImportReconcileOnceReport {
            claimed: claims.len(),
            ..Default::default()
        };
        for claim in claims {
            match self.reconcile_claim(runtime, claim, now).await? {
                ClaimObservation::Persisted => report.persisted += 1,
                ClaimObservation::LeaseLost => report.lease_lost += 1,
                ClaimObservation::TerminalFinalized => report.terminal_finalized += 1,
                ClaimObservation::TerminalAlreadyApplied => report.terminal_already_applied += 1,
                ClaimObservation::TerminalRejected => report.terminal_rejected += 1,
            }
        }
        Ok(report)
    }

    pub(crate) async fn run_reconciliation_loop<S>(
        &self,
        runtime: AlgoliaImportReconciliationRuntime<S>,
        mut shutdown: tokio::sync::watch::Receiver<bool>,
    ) where
        S: AlgoliaImportReconciliationStore,
    {
        if *shutdown.borrow() {
            return;
        }
        loop {
            match self.reconcile_once(&runtime, Utc::now()).await {
                Ok(report) => {
                    tracing::debug!(
                        claimed = report.claimed,
                        persisted = report.persisted,
                        lease_lost = report.lease_lost,
                        terminal_finalized = report.terminal_finalized,
                        terminal_already_applied = report.terminal_already_applied,
                        terminal_rejected = report.terminal_rejected,
                        "Algolia import reconciliation pass completed"
                    );
                }
                Err(error) => {
                    tracing::error!(%error, "Algolia import reconciliation pass failed");
                }
            }
            tokio::select! {
                changed = shutdown.changed() => {
                    if changed.is_err() || *shutdown.borrow() {
                        return;
                    }
                }
                _ = tokio::time::sleep(runtime.config.interval) => {}
            }
        }
    }

    async fn reconcile_claim<S>(
        &self,
        runtime: &AlgoliaImportReconciliationRuntime<S>,
        claim: AlgoliaImportReconciliationClaim,
        observed_at: DateTime<Utc>,
    ) -> Result<ClaimObservation, RepoError>
    where
        S: AlgoliaImportReconciliationStore,
    {
        if claim.job.engine_ack_state
            == crate::models::algolia_import_job::AlgoliaImportEngineAckState::OutboxPending
        {
            return self
                .deliver_terminal_ack(runtime, &claim.job, Some((&claim.lease, observed_at)))
                .await;
        }
        let response = match self
            .status_for_claim(runtime.vm_repo.as_ref(), &claim)
            .await
        {
            Ok(response) => response,
            Err(error) => {
                let classification =
                    Self::classify_engine_error(AlgoliaImportEngineOperation::Status, &error);
                return self
                    .persist_unavailable(runtime, claim, observed_at, classification.code)
                    .await;
            }
        };
        let cursor = AlgoliaImportObservationCursor::new(
            claim
                .job
                .engine_job_id
                .expect("reconciliation claims are engine-linked"),
            claim.job.destination_kind,
            claim.job.status,
            claim.job.summary.clone(),
        );
        match Self::map_status_observation(&cursor, response) {
            Ok(AlgoliaImportStatusObservation::Running(observation)) => {
                let mut state = AlgoliaImportJobState::try_from(&claim.job)
                    .map_err(|message| RepoError::Conflict(message.into()))?;
                state.status = observation.status;
                state.summary = observation.summary;
                if state.error_code == Some(AlgoliaImportErrorCode::BackendUnavailable) {
                    state.error_code = None;
                    state.error_message = None;
                    state.retryable = false;
                }
                self.persist_observation(runtime, claim, observed_at, state, false)
                    .await
            }
            Ok(AlgoliaImportStatusObservation::Terminal(fact)) => {
                self.finalize_reconciliation_terminal(runtime, claim, fact)
                    .await
            }
            Err(_) => {
                self.persist_unavailable(
                    runtime,
                    claim,
                    observed_at,
                    AlgoliaImportErrorCode::BackendUnavailable,
                )
                .await
            }
        }
    }

    async fn status_for_claim(
        &self,
        vm_repo: &(dyn VmInventoryRepo + Send + Sync),
        claim: &AlgoliaImportReconciliationClaim,
    ) -> Result<super::AsyncMigrationStatusResponse, super::AlgoliaImportEngineError> {
        let vm_id = claim.job.destination_vm_id.ok_or_else(|| {
            super::AlgoliaImportEngineError::Transport(
                "persisted destination VM is unavailable".to_string(),
            )
        })?;
        let vm = vm_repo
            .get(vm_id)
            .await
            .map_err(|_| {
                super::AlgoliaImportEngineError::Transport(
                    "persisted destination VM is unavailable".to_string(),
                )
            })?
            .filter(|vm| vm.region == claim.job.destination_region)
            .ok_or_else(|| {
                super::AlgoliaImportEngineError::Transport(
                    "persisted destination VM is unavailable".to_string(),
                )
            })?;
        let engine_job_id = claim.job.engine_job_id.ok_or_else(|| {
            super::AlgoliaImportEngineError::Transport(
                "persisted engine migration identity is unavailable".to_string(),
            )
        })?;
        let node_secret_id = vm.node_secret_id().to_string();
        self.status(
            EngineTarget::new(vm.flapjack_url, node_secret_id, vm.region),
            &engine_job_id.to_string(),
        )
        .await
    }

    async fn persist_unavailable<S>(
        &self,
        runtime: &AlgoliaImportReconciliationRuntime<S>,
        claim: AlgoliaImportReconciliationClaim,
        observed_at: DateTime<Utc>,
        code: AlgoliaImportErrorCode,
    ) -> Result<ClaimObservation, RepoError>
    where
        S: AlgoliaImportReconciliationStore,
    {
        let mut state = AlgoliaImportJobState::try_from(&claim.job)
            .map_err(|message| RepoError::Conflict(message.into()))?;
        state.error_code = Some(code);
        state.error_message = None;
        state.retryable = true;
        self.persist_observation(runtime, claim, observed_at, state, true)
            .await
    }

    async fn persist_observation<S>(
        &self,
        runtime: &AlgoliaImportReconciliationRuntime<S>,
        claim: AlgoliaImportReconciliationClaim,
        observed_at: DateTime<Utc>,
        state: AlgoliaImportJobState,
        alert_if_changed: bool,
    ) -> Result<ClaimObservation, RepoError>
    where
        S: AlgoliaImportReconciliationStore,
    {
        match runtime
            .store
            .record_reconciliation_observation(&claim.lease, observed_at, state)
            .await?
        {
            AlgoliaImportReconciliationWriteOutcome::LeaseLost => Ok(ClaimObservation::LeaseLost),
            AlgoliaImportReconciliationWriteOutcome::Applied {
                unavailable_state_changed,
                ..
            } => {
                if alert_if_changed && unavailable_state_changed {
                    Self::alert_reconciliation_unavailable(runtime.alert_service.as_ref(), &claim)
                        .await;
                }
                Ok(ClaimObservation::Persisted)
            }
        }
    }

    async fn finalize_reconciliation_terminal<S>(
        &self,
        runtime: &AlgoliaImportReconciliationRuntime<S>,
        claim: AlgoliaImportReconciliationClaim,
        fact: crate::models::algolia_import_job::AlgoliaImportTerminalFact,
    ) -> Result<ClaimObservation, RepoError>
    where
        S: AlgoliaImportReconciliationStore,
    {
        match runtime
            .store
            .finalize_terminal_observation(
                AlgoliaImportTerminalFinalizationAuthority::ReconciliationLease(claim.lease),
                fact,
            )
            .await?
        {
            AlgoliaImportTerminalFinalizationOutcome::Applied(job) => {
                self.deliver_terminal_ack(runtime, &job, None).await
            }
            AlgoliaImportTerminalFinalizationOutcome::AlreadyApplied(job) => {
                self.deliver_terminal_ack(runtime, &job, None).await?;
                Ok(ClaimObservation::TerminalAlreadyApplied)
            }
            AlgoliaImportTerminalFinalizationOutcome::FenceLost => Ok(ClaimObservation::LeaseLost),
            AlgoliaImportTerminalFinalizationOutcome::Rejected(reason) => {
                Self::alert_terminal_finalization_rejected(
                    runtime.alert_service.as_ref(),
                    &claim.job,
                    reason,
                )
                .await;
                Ok(ClaimObservation::TerminalRejected)
            }
        }
    }

    async fn deliver_terminal_ack<S>(
        &self,
        runtime: &AlgoliaImportReconciliationRuntime<S>,
        job: &crate::models::algolia_import_job::AlgoliaImportJob,
        retained_ack_claim: Option<(&AlgoliaImportReconciliationLease, DateTime<Utc>)>,
    ) -> Result<ClaimObservation, RepoError>
    where
        S: AlgoliaImportReconciliationStore,
    {
        if job.engine_ack_state
            == crate::models::algolia_import_job::AlgoliaImportEngineAckState::Acknowledged
        {
            return Ok(ClaimObservation::TerminalFinalized);
        }
        let engine_job_id = job.engine_job_id.ok_or_else(|| {
            RepoError::Conflict("terminal engine acknowledgement requires engine identity".into())
        })?;
        let target = match self
            .resolve_engine_target(job, runtime.vm_repo.as_ref())
            .await
        {
            Ok(target) => target,
            Err(error_code) => {
                tracing::warn!(
                    job_id = %job.id,
                    reason = error_code.as_str(),
                    "Algolia import terminal ACK target is unavailable"
                );
                return Self::release_retained_ack_claim(runtime, job, retained_ack_claim).await;
            }
        };
        if let Err(error) = self.acknowledge(target, &engine_job_id.to_string()).await {
            tracing::warn!(
                job_id = %job.id,
                %error,
                "Algolia import terminal ACK delivery failed; retained outbox will retry"
            );
            return Self::release_retained_ack_claim(runtime, job, retained_ack_claim).await;
        }
        runtime.store.mark_engine_acknowledged(job.id).await?;
        Ok(ClaimObservation::TerminalFinalized)
    }

    async fn release_retained_ack_claim<S>(
        runtime: &AlgoliaImportReconciliationRuntime<S>,
        job: &crate::models::algolia_import_job::AlgoliaImportJob,
        retained_ack_claim: Option<(&AlgoliaImportReconciliationLease, DateTime<Utc>)>,
    ) -> Result<ClaimObservation, RepoError>
    where
        S: AlgoliaImportReconciliationStore,
    {
        let Some((lease, observed_at)) = retained_ack_claim else {
            return Ok(ClaimObservation::TerminalFinalized);
        };
        let state = AlgoliaImportJobState::try_from(job)
            .map_err(|message| RepoError::Conflict(message.into()))?;
        match runtime
            .store
            .record_reconciliation_observation(lease, observed_at, state)
            .await?
        {
            AlgoliaImportReconciliationWriteOutcome::LeaseLost => Ok(ClaimObservation::LeaseLost),
            AlgoliaImportReconciliationWriteOutcome::Applied { .. } => {
                Ok(ClaimObservation::TerminalFinalized)
            }
        }
    }

    async fn alert_reconciliation_unavailable(
        alert_service: &(dyn AlertService + Send + Sync),
        claim: &AlgoliaImportReconciliationClaim,
    ) {
        let metadata = HashMap::from([
            ("job_id".to_string(), claim.job.id.to_string()),
            (
                "cloud_job_id".to_string(),
                claim.job.cloud_job_id.to_string(),
            ),
            (
                "reason".to_string(),
                AlgoliaImportErrorCode::BackendUnavailable
                    .as_str()
                    .to_string(),
            ),
        ]);
        let _ = alert_service
            .send_alert(Alert {
                severity: AlertSeverity::Warning,
                title: "Algolia import status unavailable".to_string(),
                message: "A retained Algolia import could not be reconciled".to_string(),
                metadata,
            })
            .await;
    }

    async fn alert_terminal_finalization_rejected(
        alert_service: &(dyn AlertService + Send + Sync),
        job: &crate::models::algolia_import_job::AlgoliaImportJob,
        reason: String,
    ) {
        let metadata = HashMap::from([
            ("job_id".to_string(), job.id.to_string()),
            ("cloud_job_id".to_string(), job.cloud_job_id.to_string()),
            ("reason".to_string(), reason),
        ]);
        let _ = alert_service
            .send_alert(Alert {
                severity: AlertSeverity::Critical,
                title: "Algolia import terminal finalization rejected".to_string(),
                message: "Algolia import terminal observation failed closed".to_string(),
                metadata,
            })
            .await;
    }
}
