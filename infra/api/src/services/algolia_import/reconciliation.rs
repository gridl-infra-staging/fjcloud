use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration as StdDuration;

use async_trait::async_trait;
use chrono::{DateTime, Duration, Utc};

use crate::models::algolia_import_job::{AlgoliaImportErrorCode, AlgoliaImportJobState};
use crate::repos::{
    AlgoliaImportJobRepo, AlgoliaImportReconciliationClaim, AlgoliaImportReconciliationLease,
    AlgoliaImportReconciliationWriteOutcome, RepoError, VmInventoryRepo,
};
use crate::services::alerting::{Alert, AlertService, AlertSeverity};

use super::{
    AlgoliaImportEngineOperation, AlgoliaImportObservationCursor, AlgoliaImportService,
    AlgoliaImportStatusObservation, AlgoliaImportTerminalHandoff, EngineTarget,
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
    pub(crate) terminal_handoffs: Vec<AlgoliaImportTerminalHandoff>,
}

enum ClaimObservation {
    Persisted,
    LeaseLost,
    Terminal(AlgoliaImportTerminalHandoff),
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
                ClaimObservation::Terminal(handoff) => report.terminal_handoffs.push(handoff),
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
                        terminal_handoffs = report.terminal_handoffs.len(),
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
            Ok(AlgoliaImportStatusObservation::Terminal(handoff)) => {
                Ok(ClaimObservation::Terminal(handoff))
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
}
