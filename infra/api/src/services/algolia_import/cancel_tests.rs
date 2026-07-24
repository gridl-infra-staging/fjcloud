use std::sync::Mutex;

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use serde_json::json;
use uuid::Uuid;

use crate::models::algolia_import_job::{
    AlgoliaImportDispatchIntentState, AlgoliaImportEngineAckState, AlgoliaImportErrorCode,
    AlgoliaImportJob, AlgoliaImportJobState, AlgoliaImportJobStatus, AlgoliaImportSummary,
    AlgoliaImportTerminalFact, NewAlgoliaImportJob, NewAlgoliaReplaceImportJob,
};
use crate::repos::{
    AlgoliaImportCancelDispatch, AlgoliaImportCancelOutcome, AlgoliaImportDispatchAdmission,
    AlgoliaImportDispatchAdmissionOutcome, AlgoliaImportDispatchGuard,
    AlgoliaImportDispatchReplayIdentity, AlgoliaImportEngineAckOutcome,
    AlgoliaImportJobAdmissionError, AlgoliaImportJobListCursor, AlgoliaImportJobListPage,
    AlgoliaImportJobRepo, AlgoliaImportReconciliationClaim, AlgoliaImportReconciliationLease,
    AlgoliaImportReconciliationWriteOutcome, AlgoliaImportResumeDeadlineClaim,
    AlgoliaImportResumeOutcome, AlgoliaImportTerminalFinalizationAuthority,
    AlgoliaImportTerminalFinalizationOutcome, AlgoliaImportTransitionDisposition,
    AlgoliaLifecycleError, CatalogLifecycleTargetGuard, CatalogLifecycleTargetIdentity,
    DestinationEligibilityError, DestinationEligibilitySnapshot, RepoError,
};
use crate::services::alerting::MockAlertService;

use super::reconciliation_test_support::{harness, job, ENGINE_JOB_ID};

#[derive(Clone)]
struct RecordedFinalization {
    authority: AlgoliaImportTerminalFinalizationAuthority,
    fact: AlgoliaImportTerminalFact,
}

struct FinalizingCancelRepo {
    finalizations: Mutex<Vec<RecordedFinalization>>,
    terminal_outcome: Mutex<AlgoliaImportTerminalFinalizationOutcome>,
}

impl FinalizingCancelRepo {
    fn new(terminal_outcome: AlgoliaImportTerminalFinalizationOutcome) -> Self {
        Self {
            finalizations: Mutex::new(Vec::new()),
            terminal_outcome: Mutex::new(terminal_outcome),
        }
    }

    fn finalizations(&self) -> Vec<RecordedFinalization> {
        self.finalizations.lock().unwrap().clone()
    }
}

#[async_trait]
impl AlgoliaImportJobRepo for FinalizingCancelRepo {
    async fn finalize_terminal_observation(
        &self,
        authority: AlgoliaImportTerminalFinalizationAuthority,
        fact: AlgoliaImportTerminalFact,
    ) -> Result<AlgoliaImportTerminalFinalizationOutcome, RepoError> {
        self.finalizations
            .lock()
            .unwrap()
            .push(RecordedFinalization { authority, fact });
        Ok(self.terminal_outcome.lock().unwrap().clone())
    }

    async fn update_persisted_state(
        &self,
        _id: Uuid,
        _state: AlgoliaImportJobState,
    ) -> Result<AlgoliaImportJob, RepoError> {
        panic!("terminal cancel response must not use running-state persistence")
    }

    async fn create(
        &self,
        _job: NewAlgoliaImportJob,
    ) -> Result<AlgoliaImportJob, AlgoliaImportJobAdmissionError> {
        panic!("cancel test does not create jobs")
    }

    async fn create_replace(
        &self,
        _job: NewAlgoliaReplaceImportJob,
    ) -> Result<AlgoliaImportJob, AlgoliaImportJobAdmissionError> {
        panic!("cancel test does not create replace jobs")
    }

    async fn admit_dispatch(
        &self,
        _admission: AlgoliaImportDispatchAdmission,
    ) -> Result<AlgoliaImportDispatchAdmissionOutcome, AlgoliaImportJobAdmissionError> {
        panic!("cancel test does not admit dispatch")
    }

    async fn find_active_dispatch_replay(
        &self,
        _customer_id: Uuid,
        _idempotency_key: &str,
        _identity: &AlgoliaImportDispatchReplayIdentity,
    ) -> Result<Option<AlgoliaImportJob>, AlgoliaImportJobAdmissionError> {
        panic!("cancel test does not read dispatch replay")
    }

    async fn get(&self, _id: Uuid) -> Result<Option<AlgoliaImportJob>, RepoError> {
        panic!("cancel test does not get jobs")
    }

    async fn get_for_customer(
        &self,
        _customer_id: Uuid,
        _id: Uuid,
    ) -> Result<Option<AlgoliaImportJob>, RepoError> {
        panic!("cancel test does not get customer jobs")
    }

    async fn list_for_customer(
        &self,
        _customer_id: Uuid,
        _after: Option<AlgoliaImportJobListCursor>,
        _limit: i64,
    ) -> Result<AlgoliaImportJobListPage, RepoError> {
        panic!("cancel test does not list jobs")
    }

    async fn snapshot_replace_target_eligibility(
        &self,
        _customer_id: Uuid,
        _logical_target: &str,
    ) -> Result<DestinationEligibilitySnapshot, DestinationEligibilityError> {
        panic!("cancel test does not snapshot replace targets")
    }

    async fn find_by_idempotency_key(
        &self,
        _customer_id: Uuid,
        _key: &str,
    ) -> Result<Option<AlgoliaImportJob>, RepoError> {
        panic!("cancel test does not read idempotency")
    }

    async fn record_dispatch_intent_committed(
        &self,
        _id: Uuid,
        _engine_job_id: Uuid,
    ) -> Result<AlgoliaImportJob, RepoError> {
        panic!("cancel test does not record dispatch")
    }

    async fn acquire_dispatch_guard(
        &self,
        _id: Uuid,
    ) -> Result<AlgoliaImportDispatchGuard, RepoError> {
        panic!("cancel test does not acquire dispatch guards")
    }

    async fn release_dispatch_guard(
        &self,
        _guard: AlgoliaImportDispatchGuard,
    ) -> Result<(), RepoError> {
        panic!("cancel test does not release dispatch guards")
    }

    async fn record_no_dispatch_failure(
        &self,
        _id: Uuid,
        _error_code: AlgoliaImportErrorCode,
        _error_message: Option<&str>,
    ) -> Result<AlgoliaImportJob, RepoError> {
        panic!("cancel test does not record no-dispatch failures")
    }

    async fn request_cancel(&self, _id: Uuid) -> Result<AlgoliaImportCancelOutcome, RepoError> {
        panic!("cancel test does not request cancel")
    }

    async fn prepare_resume(&self, _id: Uuid) -> Result<AlgoliaImportResumeOutcome, RepoError> {
        panic!("cancel test does not prepare resume")
    }

    async fn request_cancel_for_customer(
        &self,
        _customer_id: Uuid,
        _id: Uuid,
    ) -> Result<AlgoliaImportCancelOutcome, AlgoliaLifecycleError> {
        panic!("cancel test does not request customer cancel")
    }

    async fn prepare_resume_for_customer(
        &self,
        _customer_id: Uuid,
        _id: Uuid,
        _now: DateTime<Utc>,
    ) -> Result<AlgoliaImportResumeOutcome, AlgoliaLifecycleError> {
        panic!("cancel test does not prepare customer resume")
    }

    async fn record_resume_accepted(
        &self,
        _id: Uuid,
        _generation: i64,
        _summary: AlgoliaImportSummary,
    ) -> Result<AlgoliaImportJob, RepoError> {
        panic!("cancel test does not record resume acceptance")
    }

    async fn mark_engine_acknowledged(
        &self,
        _id: Uuid,
    ) -> Result<AlgoliaImportEngineAckOutcome, RepoError> {
        panic!("cancel test does not mark ACK")
    }

    async fn gc_retained_terminal_history(
        &self,
        _now: DateTime<Utc>,
        _limit: i64,
    ) -> Result<Vec<Uuid>, RepoError> {
        panic!("cancel test does not GC")
    }

    async fn claim_reconciliation_jobs(
        &self,
        _now: DateTime<Utc>,
        _lease_expires_at: DateTime<Utc>,
        _limit: i64,
    ) -> Result<Vec<AlgoliaImportReconciliationClaim>, RepoError> {
        panic!("cancel test does not claim reconciliation")
    }

    async fn record_reconciliation_observation(
        &self,
        _lease: &AlgoliaImportReconciliationLease,
        _observed_at: DateTime<Utc>,
        _state: AlgoliaImportJobState,
    ) -> Result<AlgoliaImportReconciliationWriteOutcome, RepoError> {
        panic!("cancel test does not record reconciliation observations")
    }

    async fn claim_elapsed_resume_deadlines(
        &self,
        _now: DateTime<Utc>,
        _lease_expires_at: DateTime<Utc>,
        _limit: i64,
    ) -> Result<Vec<AlgoliaImportResumeDeadlineClaim>, RepoError> {
        panic!("cancel test does not claim resume deadlines")
    }

    async fn begin_lifecycle_target_guard(
        &self,
        _customer_id: Uuid,
        _logical_target: &str,
    ) -> Result<CatalogLifecycleTargetGuard, RepoError> {
        panic!("cancel test does not begin lifecycle guards")
    }

    async fn commit_lifecycle_target_guard(
        &self,
        _guard: CatalogLifecycleTargetGuard,
        _expected_identity: Option<&CatalogLifecycleTargetIdentity>,
    ) -> Result<(), RepoError> {
        panic!("cancel test does not commit lifecycle guards")
    }
}

#[tokio::test]
async fn terminal_cancel_response_uses_single_finalizer_with_immediate_authority() {
    let now = Utc::now();
    let job = cancelling_job(now);
    let outcome = AlgoliaImportCancelOutcome {
        dispatch: Some(AlgoliaImportCancelDispatch {
            engine_job_id: Uuid::parse_str(ENGINE_JOB_ID).unwrap(),
        }),
        disposition: AlgoliaImportTransitionDisposition::Accepted,
        job: job.clone(),
    };
    let response = serde_json::from_value(json!({
        "jobId": ENGINE_JOB_ID,
        "phase": "activating",
        "disposition": "cancelled",
        "createdAt": "2026-07-22T00:00:00Z",
        "updatedAt": "2026-07-22T00:00:01Z",
        "terminalAt": "2026-07-22T00:00:02Z",
        "exportProgress": {"completed": 12, "total": 20}
    }))
    .unwrap();
    let repo = FinalizingCancelRepo::new(AlgoliaImportTerminalFinalizationOutcome::Applied(
        cancelling_job(Utc::now()),
    ));
    let alert_service = MockAlertService::new();
    let (service, _, _) = harness(Vec::new()).await;

    let result = service
        .consume_cancel_observation(&repo, &alert_service, outcome, response)
        .await
        .unwrap();

    assert!(matches!(
        result.terminal_finalization,
        Some(AlgoliaImportTerminalFinalizationOutcome::Applied(_))
    ));
    assert_eq!(alert_service.alert_count(), 0);
    let finalizations = repo.finalizations();
    assert_eq!(finalizations.len(), 1);
    let recorded = &finalizations[0];
    assert_eq!(
        recorded.fact.engine_job_id,
        Uuid::parse_str(ENGINE_JOB_ID).unwrap()
    );
    assert_eq!(recorded.fact.status, AlgoliaImportJobStatus::Cancelled);
    assert_eq!(
        recorded.fact.terminal_at,
        "2026-07-22T00:00:02Z".parse::<DateTime<Utc>>().unwrap()
    );
    let AlgoliaImportTerminalFinalizationAuthority::ImmediateCancel {
        job_id,
        lifecycle_generation,
        engine_job_id,
    } = &recorded.authority
    else {
        panic!("cancel must finalize with immediate-cancel authority");
    };
    assert_eq!(*job_id, job.id);
    assert_eq!(*lifecycle_generation, job.lifecycle_generation);
    assert_eq!(*engine_job_id, Uuid::parse_str(ENGINE_JOB_ID).unwrap());
}

#[tokio::test]
async fn terminal_cancel_response_alerts_rejected_finalization() {
    let now = Utc::now();
    let job = cancelling_job(now);
    let outcome = AlgoliaImportCancelOutcome {
        dispatch: Some(AlgoliaImportCancelDispatch {
            engine_job_id: Uuid::parse_str(ENGINE_JOB_ID).unwrap(),
        }),
        disposition: AlgoliaImportTransitionDisposition::Accepted,
        job: job.clone(),
    };
    let response = serde_json::from_value(json!({
        "jobId": ENGINE_JOB_ID,
        "phase": "activating",
        "disposition": "cancelled",
        "createdAt": "2026-07-22T00:00:00Z",
        "updatedAt": "2026-07-22T00:00:01Z",
        "terminalAt": "2026-07-22T00:00:02Z",
        "exportProgress": {"completed": 12, "total": 20}
    }))
    .unwrap();
    let repo = FinalizingCancelRepo::new(AlgoliaImportTerminalFinalizationOutcome::Rejected(
        "destination_changed".to_string(),
    ));
    let alert_service = MockAlertService::new();
    let (service, _, _) = harness(Vec::new()).await;

    let result = service
        .consume_cancel_observation(&repo, &alert_service, outcome, response)
        .await
        .unwrap();

    assert!(matches!(
        result.terminal_finalization,
        Some(AlgoliaImportTerminalFinalizationOutcome::Rejected(_))
    ));
    assert_eq!(result.outcome.job.id, job.id);
    assert_eq!(alert_service.alert_count(), 1);
    let alert = &alert_service.recorded_alerts()[0];
    assert_eq!(
        alert.title,
        "Algolia import cancel terminal finalization rejected"
    );
    assert_eq!(
        alert.severity,
        crate::services::alerting::AlertSeverity::Critical
    );
    assert_eq!(alert.metadata["reason"], "destination_changed");
}

#[tokio::test]
async fn terminal_cancel_response_does_not_alert_lost_fence() {
    let now = Utc::now();
    let job = cancelling_job(now);
    let outcome = AlgoliaImportCancelOutcome {
        dispatch: Some(AlgoliaImportCancelDispatch {
            engine_job_id: Uuid::parse_str(ENGINE_JOB_ID).unwrap(),
        }),
        disposition: AlgoliaImportTransitionDisposition::Accepted,
        job: job.clone(),
    };
    let response = serde_json::from_value(json!({
        "jobId": ENGINE_JOB_ID,
        "phase": "activating",
        "disposition": "cancelled",
        "createdAt": "2026-07-22T00:00:00Z",
        "updatedAt": "2026-07-22T00:00:01Z",
        "terminalAt": "2026-07-22T00:00:02Z",
        "exportProgress": {"completed": 12, "total": 20}
    }))
    .unwrap();
    let repo = FinalizingCancelRepo::new(AlgoliaImportTerminalFinalizationOutcome::FenceLost);
    let alert_service = MockAlertService::new();
    let (service, _, _) = harness(Vec::new()).await;

    let result = service
        .consume_cancel_observation(&repo, &alert_service, outcome, response)
        .await
        .unwrap();

    assert!(matches!(
        result.terminal_finalization,
        Some(AlgoliaImportTerminalFinalizationOutcome::FenceLost)
    ));
    assert_eq!(result.outcome.job.id, job.id);
    assert_eq!(alert_service.alert_count(), 0);
}

fn cancelling_job(now: DateTime<Utc>) -> AlgoliaImportJob {
    let mut job = job(now, Uuid::new_v4());
    job.status = AlgoliaImportJobStatus::Cancelling;
    job.cancel_requested_at = Some(now);
    job.dispatch_intent_state = AlgoliaImportDispatchIntentState::Committed;
    job.engine_ack_state = AlgoliaImportEngineAckState::Pending;
    job.engine_job_id = Some(Uuid::parse_str(ENGINE_JOB_ID).unwrap());
    job
}
