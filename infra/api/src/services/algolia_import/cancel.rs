use std::collections::HashMap;

use sqlx::PgPool;
use uuid::Uuid;

use crate::models::algolia_import_job::{AlgoliaImportJob, AlgoliaImportJobState};
use crate::models::AlgoliaImportErrorCode;
use crate::repos::{
    AlgoliaImportCancelOutcome, AlgoliaImportJobRepo, AlgoliaImportTerminalFinalizationAuthority,
    AlgoliaImportTerminalFinalizationOutcome, AlgoliaLifecycleError, PgAlgoliaImportJobRepo,
    RepoError, VmInventoryRepo,
};
use crate::services::alerting::{Alert, AlertService, AlertSeverity};

use super::{AlgoliaImportEngineOperation, AlgoliaImportService};

pub(crate) struct AlgoliaImportCancelResult {
    pub outcome: AlgoliaImportCancelOutcome,
    pub terminal_finalization: Option<AlgoliaImportTerminalFinalizationOutcome>,
}

impl From<AlgoliaImportCancelOutcome> for AlgoliaImportCancelResult {
    fn from(outcome: AlgoliaImportCancelOutcome) -> Self {
        Self {
            outcome,
            terminal_finalization: None,
        }
    }
}

pub(crate) struct AlgoliaImportCancelContext<'a> {
    pub pool: &'a PgPool,
    pub vm_repo: &'a (dyn VmInventoryRepo + Send + Sync),
    pub alert_service: &'a (dyn AlertService + Send + Sync),
    pub customer_id: Uuid,
    pub job_id: Uuid,
}

impl AlgoliaImportService {
    pub(crate) async fn cancel_for_customer(
        &self,
        context: AlgoliaImportCancelContext<'_>,
    ) -> Result<AlgoliaImportCancelResult, AlgoliaLifecycleError> {
        let job_repo = PgAlgoliaImportJobRepo::new(context.pool.clone());
        let outcome = job_repo
            .request_cancel_for_customer(context.customer_id, context.job_id)
            .await?;
        let Some(dispatch) = outcome.dispatch.as_ref() else {
            return Ok(outcome.into());
        };

        let target = match self
            .resolve_engine_target(&outcome.job, context.vm_repo)
            .await
        {
            Ok(target) => target,
            Err(_) => {
                return self
                    .retain_cancel_error(
                        &job_repo,
                        context.alert_service,
                        outcome,
                        AlgoliaImportErrorCode::BackendUnavailable,
                        true,
                    )
                    .await
                    .map(Into::into);
            }
        };
        let cancel_result = self
            .cancel(target, &dispatch.engine_job_id.to_string())
            .await;
        let response = match cancel_result {
            Ok(response) => response,
            Err(error) => {
                let classification =
                    Self::classify_engine_error(AlgoliaImportEngineOperation::Cancel, &error);
                return self
                    .retain_cancel_error(
                        &job_repo,
                        context.alert_service,
                        outcome,
                        classification.code,
                        classification.retryable,
                    )
                    .await
                    .map(Into::into);
            }
        };
        self.consume_cancel_observation(&job_repo, context.alert_service, outcome, response)
            .await
    }

    pub(super) async fn consume_cancel_observation(
        &self,
        job_repo: &(dyn AlgoliaImportJobRepo + Send + Sync),
        alert_service: &(dyn AlertService + Send + Sync),
        mut outcome: AlgoliaImportCancelOutcome,
        response: super::AsyncMigrationStatusResponse,
    ) -> Result<AlgoliaImportCancelResult, AlgoliaLifecycleError> {
        let cursor = super::AlgoliaImportObservationCursor::new(
            outcome
                .job
                .engine_job_id
                .expect("cancel dispatch is always engine-linked"),
            outcome.job.destination_kind,
            outcome.job.status,
            outcome.job.summary.clone(),
        );
        match Self::map_status_observation(&cursor, response) {
            Ok(super::AlgoliaImportStatusObservation::Running(observation)) => {
                let mut state = AlgoliaImportJobState::try_from(&outcome.job)
                    .map_err(|message| lifecycle_repository_error(message.to_string()))?;
                state.status = observation.status;
                state.summary = observation.summary;
                if state.error_code == Some(AlgoliaImportErrorCode::BackendUnavailable) {
                    state.error_code = None;
                    state.error_message = None;
                    state.retryable = false;
                }
                outcome.job = job_repo
                    .update_persisted_state(outcome.job.id, state)
                    .await
                    .map_err(AlgoliaLifecycleError::Repository)?;
                Ok(outcome.into())
            }
            Ok(super::AlgoliaImportStatusObservation::Terminal(fact)) => {
                let engine_job_id = outcome
                    .job
                    .engine_job_id
                    .expect("cancel dispatch is always engine-linked");
                let finalization = job_repo
                    .finalize_terminal_observation(
                        AlgoliaImportTerminalFinalizationAuthority::ImmediateCancel {
                            job_id: outcome.job.id,
                            lifecycle_generation: outcome.job.lifecycle_generation,
                            engine_job_id,
                        },
                        fact,
                    )
                    .await
                    .map_err(AlgoliaLifecycleError::Repository)?;
                match &finalization {
                    AlgoliaImportTerminalFinalizationOutcome::Applied(job)
                    | AlgoliaImportTerminalFinalizationOutcome::AlreadyApplied(job) => {
                        outcome.job = job.clone();
                    }
                    AlgoliaImportTerminalFinalizationOutcome::FenceLost => {}
                    AlgoliaImportTerminalFinalizationOutcome::Rejected(reason) => {
                        Self::alert_cancel_terminal_rejected(
                            alert_service,
                            &outcome.job,
                            reason.clone(),
                        )
                        .await;
                    }
                }
                Ok(AlgoliaImportCancelResult {
                    outcome,
                    terminal_finalization: Some(finalization),
                })
            }
            Err(_) => self
                .retain_cancel_error(
                    job_repo,
                    alert_service,
                    outcome,
                    AlgoliaImportErrorCode::BackendUnavailable,
                    true,
                )
                .await
                .map(Into::into),
        }
    }

    async fn retain_cancel_error(
        &self,
        job_repo: &(dyn AlgoliaImportJobRepo + Send + Sync),
        alert_service: &(dyn AlertService + Send + Sync),
        mut outcome: AlgoliaImportCancelOutcome,
        code: AlgoliaImportErrorCode,
        retryable: bool,
    ) -> Result<AlgoliaImportCancelOutcome, AlgoliaLifecycleError> {
        let changed = outcome.job.error_code != Some(code) || outcome.job.retryable != retryable;
        let mut state = AlgoliaImportJobState::try_from(&outcome.job)
            .map_err(|message| lifecycle_repository_error(message.to_string()))?;
        state.error_code = Some(code);
        state.error_message = None;
        state.retryable = retryable;
        outcome.job = job_repo
            .update_persisted_state(outcome.job.id, state)
            .await
            .map_err(AlgoliaLifecycleError::Repository)?;
        if retryable && changed {
            Self::alert_cancel_retained(alert_service, &outcome.job, code).await;
        }
        Ok(outcome)
    }

    async fn alert_cancel_retained(
        alert_service: &(dyn AlertService + Send + Sync),
        job: &AlgoliaImportJob,
        reason: AlgoliaImportErrorCode,
    ) {
        let metadata = HashMap::from([
            ("job_id".to_string(), job.id.to_string()),
            ("cloud_job_id".to_string(), job.cloud_job_id.to_string()),
            ("reason".to_string(), reason.as_str().to_string()),
        ]);
        let _ = alert_service
            .send_alert(Alert {
                severity: AlertSeverity::Warning,
                title: "Algolia import cancel retained ambiguous job".to_string(),
                message: "Algolia import cancel outcome requires reconciliation".to_string(),
                metadata,
            })
            .await;
    }

    async fn alert_cancel_terminal_rejected(
        alert_service: &(dyn AlertService + Send + Sync),
        job: &AlgoliaImportJob,
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
                title: "Algolia import cancel terminal finalization rejected".to_string(),
                message: "Algolia import cancel terminal observation failed closed".to_string(),
                metadata,
            })
            .await;
    }
}

fn lifecycle_repository_error(message: String) -> AlgoliaLifecycleError {
    AlgoliaLifecycleError::Repository(RepoError::Other(message))
}
