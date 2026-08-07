use std::collections::HashMap;

use sqlx::PgPool;
use uuid::Uuid;
use zeroize::Zeroizing;

use crate::models::algolia_import_job::{
    AlgoliaImportCreatePlacement, AlgoliaImportDestinationKind, AlgoliaImportJob,
    AlgoliaImportJobState, AlgoliaImportSource, AlgoliaImportTargetBinding, NewAlgoliaImportJob,
    NewAlgoliaReplaceImportJob,
};
use crate::models::AlgoliaImportErrorCode;
use crate::repos::{
    AlgoliaImportDispatchAdmission, AlgoliaImportDispatchAdmissionOutcome,
    AlgoliaImportDispatchReplayIdentity, AlgoliaImportJobAdmissionError, AlgoliaImportJobRepo,
    PgAlgoliaImportJobRepo, RepoError, VmInventoryRepo,
};
use crate::services::alerting::{Alert, AlertService, AlertSeverity};
use crate::services::algolia_source::AlgoliaSourceError;
use crate::services::flapjack_proxy::{FlapjackEngineRequirements, FlapjackRuntimeIdentityReason};

use super::{
    AlgoliaImportEngineOperation, AlgoliaImportService, AlgoliaImportSubmitRequest, EngineTarget,
};

impl AlgoliaImportService {
    pub(crate) fn classify_engine_compatibility(
        reason: FlapjackRuntimeIdentityReason,
    ) -> Result<(), AlgoliaImportErrorCode> {
        match reason {
            FlapjackRuntimeIdentityReason::Match => Ok(()),
            FlapjackRuntimeIdentityReason::RuntimeUnreachable => {
                Err(AlgoliaImportErrorCode::BackendUnavailable)
            }
            // VersionUnparseable joins the upgrade-required group rather than
            // BackendUnavailable: the engine is reachable and answering, but its
            // identity cannot be established, which is an operator fix (correct
            // the pin, or run an engine that reports a real release version) and
            // not something a retry will resolve.
            FlapjackRuntimeIdentityReason::VersionMismatch
            | FlapjackRuntimeIdentityReason::VersionUnparseable
            | FlapjackRuntimeIdentityReason::RevisionMismatch
            | FlapjackRuntimeIdentityReason::BuildIdMismatch
            | FlapjackRuntimeIdentityReason::ChecksumMismatch
            | FlapjackRuntimeIdentityReason::DirtyLocalBuild
            | FlapjackRuntimeIdentityReason::MissingCapability
            | FlapjackRuntimeIdentityReason::LegacyMalformedHealth => {
                Err(AlgoliaImportErrorCode::EngineUpgradeRequired)
            }
        }
    }

    pub async fn ensure_engine_compatible(
        &self,
        flapjack_url: &str,
    ) -> Result<(), AlgoliaImportErrorCode> {
        let requirements = FlapjackEngineRequirements::from_env().map_err(|error| {
            tracing::warn!(
                error = %error,
                "Algolia import admission requires complete expected engine identity configuration"
            );
            AlgoliaImportErrorCode::EngineUpgradeRequired
        })?;
        self.check_engine_admission_compatibility(flapjack_url, &requirements)
            .await
    }

    pub(crate) async fn check_engine_admission_compatibility(
        &self,
        flapjack_url: &str,
        requirements: &FlapjackEngineRequirements,
    ) -> Result<(), AlgoliaImportErrorCode> {
        let result = self
            .proxy
            .check_engine_compatibility(flapjack_url, requirements)
            .await;
        let decision = Self::classify_engine_compatibility(result.reason);
        if decision.is_err() {
            // The floor is logged alongside the reason because `version_mismatch`
            // alone does not tell an operator what fjcloud actually required, and
            // an unactionable rejection is what previously got worked around
            // rather than fixed. It is a MINIMUM: an engine newer than it is
            // accepted, so a mismatch here always means the engine is too old.
            tracing::warn!(
                reason = result.reason.as_str(),
                minimum_engine_version = requirements
                    .expected_version
                    .as_deref()
                    .unwrap_or("<unset>"),
                "selected shared VM engine is incompatible with Algolia import admission"
            );
        }
        decision
    }

    pub async fn admit_inspected_and_submit(
        &self,
        request: AlgoliaImportAdmissionRequest,
        source: AlgoliaImportSource,
        pool: &PgPool,
        vm_repo: &(dyn VmInventoryRepo + Send + Sync),
        alert_service: &(dyn AlertService + Send + Sync),
    ) -> Result<AlgoliaImportAdmissionOutcome, AlgoliaImportAdmissionError> {
        let job_repo = PgAlgoliaImportJobRepo::new(pool.clone());
        self.admit_inspected_and_submit_with_repo(
            request,
            source,
            &job_repo,
            vm_repo,
            alert_service,
        )
        .await
    }

    /// Credential-free replay probe for the route: returns the retained job when
    /// this request is an exact idempotent replay of an active-customer job, so
    /// the route can return it before running fresh create-target placement or
    /// engine-compatibility admission. `Ok(None)` means "not conclusively a
    /// replay" and the caller proceeds with the normal admission path.
    pub async fn find_dispatch_replay(
        &self,
        pool: &PgPool,
        customer_id: Uuid,
        idempotency_key: &str,
        identity: &AlgoliaImportDispatchReplayIdentity,
    ) -> Result<Option<AlgoliaImportJob>, AlgoliaImportAdmissionError> {
        let job_repo = PgAlgoliaImportJobRepo::new(pool.clone());
        job_repo
            .find_active_dispatch_replay(customer_id, idempotency_key, identity)
            .await
            .map_err(AlgoliaImportAdmissionError::Admission)
    }

    /// Pre-inspected credential-submit seam over an explicit repository. Kept
    /// public so failure-injection tests can force a repository outcome after
    /// source inspection without duplicating admission or submission logic.
    pub async fn admit_inspected_and_submit_with_repo(
        &self,
        request: AlgoliaImportAdmissionRequest,
        source: AlgoliaImportSource,
        job_repo: &(dyn AlgoliaImportJobRepo + Send + Sync),
        vm_repo: &(dyn VmInventoryRepo + Send + Sync),
        alert_service: &(dyn AlertService + Send + Sync),
    ) -> Result<AlgoliaImportAdmissionOutcome, AlgoliaImportAdmissionError> {
        let outcome = Self::admit_inspected_job(&request, job_repo, source).await?;
        self.submit_admitted_job(request, job_repo, vm_repo, alert_service, outcome)
            .await
    }

    async fn submit_admitted_job(
        &self,
        request: AlgoliaImportAdmissionRequest,
        job_repo: &(dyn AlgoliaImportJobRepo + Send + Sync),
        vm_repo: &(dyn VmInventoryRepo + Send + Sync),
        alert_service: &(dyn AlertService + Send + Sync),
        outcome: AlgoliaImportDispatchAdmissionOutcome,
    ) -> Result<AlgoliaImportAdmissionOutcome, AlgoliaImportAdmissionError> {
        let job = match outcome {
            AlgoliaImportDispatchAdmissionOutcome::Replay(job) => {
                return Ok(AlgoliaImportAdmissionOutcome::Replay(job));
            }
            AlgoliaImportDispatchAdmissionOutcome::New(job) => job,
        };

        let target = match self.resolve_engine_target(&job, vm_repo).await {
            Ok(target) => target,
            Err(code) => {
                self.persist_admission_refusal(job_repo, alert_service, &job, code)
                    .await?;
                return Err(AlgoliaImportAdmissionError::Refused(code));
            }
        };
        if let Err(code) = self.ensure_engine_compatible(&target.flapjack_url).await {
            self.persist_admission_refusal(job_repo, alert_service, &job, code)
                .await?;
            return Err(AlgoliaImportAdmissionError::Refused(code));
        };
        let guard = match job_repo.acquire_dispatch_guard(job.id).await {
            Ok(guard) => guard,
            Err(_) => {
                self.alert_submit_retained(alert_service, &job, "dispatch_guard_refused")
                    .await;
                return Ok(AlgoliaImportAdmissionOutcome::New(job));
            }
        };
        let submit_request = request.submit_request(&job)?;
        let submit_result = self.submit(target, submit_request).await;
        let release_result = job_repo.release_dispatch_guard(guard).await;
        if release_result.is_err() {
            self.alert_submit_retained(alert_service, &job, "dispatch_guard_release_failed")
                .await;
            return Ok(AlgoliaImportAdmissionOutcome::New(job));
        }
        let engine_job_id = match submit_result {
            Ok(response) => response.job_id,
            Err(error) => {
                let classification =
                    Self::classify_engine_error(AlgoliaImportEngineOperation::Submit, &error);
                if matches!(error, super::AlgoliaImportEngineError::Engine { .. }) {
                    self.persist_admission_refusal(
                        job_repo,
                        alert_service,
                        &job,
                        classification.code,
                    )
                    .await?;
                    return Err(AlgoliaImportAdmissionError::Refused(classification.code));
                }
                self.alert_submit_retained(alert_service, &job, classification.code.as_str())
                    .await;
                return Ok(AlgoliaImportAdmissionOutcome::New(job));
            }
        };
        match job_repo
            .record_dispatch_intent_committed(job.id, engine_job_id)
            .await
        {
            Ok(job) => Ok(AlgoliaImportAdmissionOutcome::New(job)),
            Err(_) => {
                self.alert_submit_retained(alert_service, &job, "dispatch_linkage_failed")
                    .await;
                Ok(AlgoliaImportAdmissionOutcome::New(job))
            }
        }
    }

    async fn find_dispatch_replay_in_repo(
        request: &AlgoliaImportAdmissionRequest,
        job_repo: &(dyn AlgoliaImportJobRepo + Send + Sync),
    ) -> Result<Option<AlgoliaImportJob>, AlgoliaImportAdmissionError> {
        job_repo
            .find_active_dispatch_replay(
                request.customer_id(),
                &request.idempotency_key,
                &request.replay_identity(),
            )
            .await
            .map_err(AlgoliaImportAdmissionError::Admission)
    }

    async fn admit_new_inspected_job(
        request: &AlgoliaImportAdmissionRequest,
        job_repo: &(dyn AlgoliaImportJobRepo + Send + Sync),
        source: AlgoliaImportSource,
    ) -> Result<AlgoliaImportDispatchAdmissionOutcome, AlgoliaImportAdmissionError> {
        let admission = request.dispatch_admission(source)?;
        job_repo
            .admit_dispatch(admission)
            .await
            .map_err(AlgoliaImportAdmissionError::Admission)
    }

    async fn admit_inspected_job(
        request: &AlgoliaImportAdmissionRequest,
        job_repo: &(dyn AlgoliaImportJobRepo + Send + Sync),
        source: AlgoliaImportSource,
    ) -> Result<AlgoliaImportDispatchAdmissionOutcome, AlgoliaImportAdmissionError> {
        if let Some(existing) = Self::find_dispatch_replay_in_repo(request, job_repo).await? {
            return Ok(AlgoliaImportDispatchAdmissionOutcome::Replay(existing));
        }
        Self::admit_new_inspected_job(request, job_repo, source).await
    }

    pub(crate) async fn resolve_engine_target(
        &self,
        job: &AlgoliaImportJob,
        vm_repo: &(dyn VmInventoryRepo + Send + Sync),
    ) -> Result<EngineTarget, AlgoliaImportErrorCode> {
        let vm_id = job
            .destination_vm_id
            .ok_or(AlgoliaImportErrorCode::DestinationChanged)?;
        let vm = vm_repo
            .get(vm_id)
            .await
            .map_err(|_| AlgoliaImportErrorCode::BackendUnavailable)?
            .ok_or(AlgoliaImportErrorCode::DestinationChanged)?;
        if vm.region != job.destination_region {
            return Err(AlgoliaImportErrorCode::DestinationChanged);
        }
        if vm.status != "active"
            || vm.flapjack_url.trim().is_empty()
            || vm.node_secret_id().trim().is_empty()
        {
            return Err(AlgoliaImportErrorCode::BackendUnavailable);
        }
        Ok(EngineTarget::new(
            vm.flapjack_url.clone(),
            vm.node_secret_id().to_string(),
            vm.region,
        ))
    }

    async fn persist_admission_refusal(
        &self,
        job_repo: &(dyn AlgoliaImportJobRepo + Send + Sync),
        alert_service: &(dyn AlertService + Send + Sync),
        job: &AlgoliaImportJob,
        code: AlgoliaImportErrorCode,
    ) -> Result<(), AlgoliaImportAdmissionError> {
        let retryable = code == AlgoliaImportErrorCode::BackendUnavailable;
        let changed = job.error_code != Some(code) || job.retryable != retryable;
        let mut state = AlgoliaImportJobState::try_from(job).map_err(|message| {
            AlgoliaImportAdmissionError::Repository(RepoError::Other(message.to_string()))
        })?;
        state.error_code = Some(code);
        state.error_message = None;
        state.retryable = retryable;
        let retained = job_repo
            .update_persisted_state(job.id, state)
            .await
            .map_err(AlgoliaImportAdmissionError::Repository)?;
        if changed {
            self.alert_submit_retained(alert_service, &retained, code.as_str())
                .await;
        }
        Ok(())
    }

    async fn alert_submit_retained(
        &self,
        alert_service: &(dyn AlertService + Send + Sync),
        job: &AlgoliaImportJob,
        reason: &str,
    ) {
        let mut metadata = HashMap::new();
        metadata.insert("job_id".to_string(), job.id.to_string());
        metadata.insert("cloud_job_id".to_string(), job.cloud_job_id.to_string());
        metadata.insert("reason".to_string(), reason.to_string());
        let _ = alert_service
            .send_alert(Alert {
                severity: AlertSeverity::Warning,
                title: "Algolia import submit retained ambiguous job".to_string(),
                message: "Algolia import submit did not reach committed linkage".to_string(),
                metadata,
            })
            .await;
    }
}

pub struct AlgoliaImportAdmissionRequest {
    pub target_binding: AlgoliaImportTargetBinding,
    pub create_target: Option<AlgoliaImportCreatePlacement>,
    pub app_id: String,
    pub api_key: Zeroizing<String>,
    pub source_name: String,
    pub idempotency_key: String,
}

impl AlgoliaImportAdmissionRequest {
    pub fn new(
        target_binding: AlgoliaImportTargetBinding,
        create_target: Option<AlgoliaImportCreatePlacement>,
        app_id: String,
        api_key: String,
        source_name: String,
        idempotency_key: String,
    ) -> Self {
        Self {
            target_binding,
            create_target,
            app_id,
            api_key: Zeroizing::new(api_key),
            source_name,
            idempotency_key,
        }
    }

    fn customer_id(&self) -> Uuid {
        self.target_binding.customer_id()
    }

    /// Credential-free identity used to recognise an exact idempotent replay
    /// without inspecting the source. Never carries the temporary API key.
    fn replay_identity(&self) -> AlgoliaImportDispatchReplayIdentity {
        AlgoliaImportDispatchReplayIdentity {
            app_id: self.app_id.clone(),
            source_name: self.source_name.clone(),
            kind: self.target_binding.mode(),
            logical_target: self.target_binding.logical_target().to_string(),
            region: self.target_binding.region().to_string(),
        }
    }

    fn dispatch_admission(
        &self,
        source: AlgoliaImportSource,
    ) -> Result<AlgoliaImportDispatchAdmission, AlgoliaImportAdmissionError> {
        match self.target_binding.mode() {
            AlgoliaImportDestinationKind::Create => {
                let prepared = self
                    .create_target
                    .clone()
                    .ok_or(AlgoliaImportAdmissionError::PreparedCreateTargetMissing)?;
                let job = NewAlgoliaImportJob::create_from_target_binding(
                    self.target_binding.clone(),
                    source,
                    self.idempotency_key.clone(),
                )
                .map_err(AlgoliaImportAdmissionError::Refused)?
                .with_create_placement(prepared.vm_id, prepared.physical_uid)
                .map_err(|_| AlgoliaImportAdmissionError::PreparedCreateTargetMissing)?;
                Ok(AlgoliaImportDispatchAdmission::Create(job))
            }
            AlgoliaImportDestinationKind::Replace => {
                let job = NewAlgoliaReplaceImportJob::from_target_binding(
                    self.target_binding.clone(),
                    source,
                    self.idempotency_key.clone(),
                )
                .map_err(AlgoliaImportAdmissionError::Refused)?;
                Ok(AlgoliaImportDispatchAdmission::Replace(job))
            }
        }
    }

    pub(crate) fn submit_request(
        &self,
        job: &AlgoliaImportJob,
    ) -> Result<AlgoliaImportSubmitRequest, AlgoliaImportAdmissionError> {
        let target_index = match job.destination_kind {
            AlgoliaImportDestinationKind::Create => job
                .physical_uid
                .clone()
                .ok_or(AlgoliaImportAdmissionError::PreparedCreateTargetMissing)?,
            AlgoliaImportDestinationKind::Replace => job
                .physical_uid
                .clone()
                .ok_or(AlgoliaImportAdmissionError::AuthenticatedReplaceTargetMissing)?,
        };
        Ok(AlgoliaImportSubmitRequest::new(
            self.app_id.clone(),
            // Hand the credential to the submit request as a zeroizing clone so
            // it is never widened into an ordinary `String`.
            self.api_key.clone(),
            self.source_name.clone(),
            Some(target_index),
            job.destination_kind == AlgoliaImportDestinationKind::Replace,
        ))
    }
}

#[derive(Debug, Clone)]
pub enum AlgoliaImportAdmissionOutcome {
    New(AlgoliaImportJob),
    Replay(AlgoliaImportJob),
}

impl AlgoliaImportAdmissionOutcome {
    pub fn into_job(self) -> AlgoliaImportJob {
        match self {
            Self::New(job) | Self::Replay(job) => job,
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum AlgoliaImportAdmissionError {
    #[error(transparent)]
    Source(AlgoliaSourceError),
    #[error(transparent)]
    Admission(AlgoliaImportJobAdmissionError),
    #[error("Algolia import admission refused: {}", .0.as_str())]
    Refused(AlgoliaImportErrorCode),
    #[error("prepared create target is missing")]
    PreparedCreateTargetMissing,
    #[error("authenticated replace target is missing")]
    AuthenticatedReplaceTargetMissing,
    #[error(transparent)]
    Repository(RepoError),
}
