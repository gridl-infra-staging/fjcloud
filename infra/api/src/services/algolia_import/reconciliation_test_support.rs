//! Test support for Algolia import reconciliation and adjacent workflows.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::Duration as StdDuration;

use async_trait::async_trait;
use chrono::{DateTime, Duration, Utc};
use serde_json::json;
use uuid::Uuid;

use crate::models::algolia_import_job::{
    AlgoliaImportDestinationKind, AlgoliaImportDispatchIntentState, AlgoliaImportEngineAckState,
    AlgoliaImportErrorCode, AlgoliaImportJob, AlgoliaImportJobState, AlgoliaImportJobStatus,
    AlgoliaImportPublicationDisposition, AlgoliaImportSummary, AlgoliaImportTerminalFact,
};
use crate::models::vm_inventory::{NewVmInventory, VmInventory};
use crate::repos::{
    AlgoliaImportEngineAckOutcome, AlgoliaImportReconciliationClaim,
    AlgoliaImportReconciliationLease, AlgoliaImportReconciliationWriteOutcome,
    AlgoliaImportTerminalFinalizationAuthority, AlgoliaImportTerminalFinalizationOutcome,
    RepoError, VmDecommissionResult, VmInventoryRepo, VmRetirementAssessment,
};
use crate::secrets::mock::MockNodeSecretManager;
use crate::secrets::NodeSecretManager;
use crate::services::flapjack_proxy::{
    FlapjackHttpClient, FlapjackHttpRequest, FlapjackHttpResponse, FlapjackProxy, ProxyError,
};

use super::reconciliation::AlgoliaImportReconciliationStore;
use super::{AlgoliaImportReconciliationConfig, AlgoliaImportService};

pub(super) const ENGINE_JOB_ID: &str = "9f11d0a0-4443-44d4-b6c6-1ed71dbeb0fb";

pub(super) struct FakeReconciliationStore {
    job: Mutex<AlgoliaImportJob>,
    writes: Mutex<Vec<AlgoliaImportJobState>>,
    finalizations: Mutex<Vec<RecordedTerminalFinalization>>,
    acknowledgements: Mutex<Vec<Uuid>>,
    terminal_outcomes: Mutex<VecDeque<AlgoliaImportTerminalFinalizationOutcome>>,
    claim_calls: Mutex<usize>,
}

#[derive(Clone)]
pub(super) struct RecordedTerminalFinalization {
    pub(super) authority: AlgoliaImportTerminalFinalizationAuthority,
    pub(super) fact: AlgoliaImportTerminalFact,
}

impl FakeReconciliationStore {
    pub(super) fn new(job: AlgoliaImportJob) -> Self {
        Self {
            job: Mutex::new(job),
            writes: Mutex::new(Vec::new()),
            finalizations: Mutex::new(Vec::new()),
            acknowledgements: Mutex::new(Vec::new()),
            terminal_outcomes: Mutex::new(VecDeque::new()),
            claim_calls: Mutex::new(0),
        }
    }

    pub(super) fn with_terminal_outcomes(
        job: AlgoliaImportJob,
        outcomes: Vec<AlgoliaImportTerminalFinalizationOutcome>,
    ) -> Self {
        Self {
            job: Mutex::new(job),
            writes: Mutex::new(Vec::new()),
            finalizations: Mutex::new(Vec::new()),
            acknowledgements: Mutex::new(Vec::new()),
            terminal_outcomes: Mutex::new(outcomes.into()),
            claim_calls: Mutex::new(0),
        }
    }

    pub(super) fn writes(&self) -> Vec<AlgoliaImportJobState> {
        self.writes.lock().unwrap().clone()
    }

    pub(super) fn finalizations(&self) -> Vec<RecordedTerminalFinalization> {
        self.finalizations.lock().unwrap().clone()
    }

    pub(super) fn acknowledgements(&self) -> Vec<Uuid> {
        self.acknowledgements.lock().unwrap().clone()
    }

    pub(super) fn claim_calls(&self) -> usize {
        *self.claim_calls.lock().unwrap()
    }

    pub(super) fn current_job(&self) -> AlgoliaImportJob {
        self.job.lock().unwrap().clone()
    }
}

#[async_trait]
impl AlgoliaImportReconciliationStore for FakeReconciliationStore {
    async fn claim_reconciliation_jobs(
        &self,
        now: DateTime<Utc>,
        lease_expires_at: DateTime<Utc>,
        limit: i64,
    ) -> Result<Vec<AlgoliaImportReconciliationClaim>, RepoError> {
        *self.claim_calls.lock().unwrap() += 1;
        if limit <= 0 {
            return Ok(Vec::new());
        }
        let mut job = self.job.lock().unwrap().clone();
        job.worker_claimed_at = Some(now);
        job.worker_lease_expires_at = Some(lease_expires_at);
        Ok(vec![AlgoliaImportReconciliationClaim {
            lease: AlgoliaImportReconciliationLease {
                job_id: job.id,
                lifecycle_generation: job.lifecycle_generation,
                claimed_at: now,
                expires_at: lease_expires_at,
            },
            job,
        }])
    }

    async fn record_reconciliation_observation(
        &self,
        _lease: &AlgoliaImportReconciliationLease,
        _observed_at: DateTime<Utc>,
        state: AlgoliaImportJobState,
    ) -> Result<AlgoliaImportReconciliationWriteOutcome, RepoError> {
        let mut job = self.job.lock().unwrap();
        let unavailable_state_changed = (job.error_code
            == Some(AlgoliaImportErrorCode::BackendUnavailable))
            != (state.error_code == Some(AlgoliaImportErrorCode::BackendUnavailable));
        job.status = state.status;
        job.summary = state.summary.clone();
        job.retryable = state.retryable;
        job.error_code = state.error_code;
        job.error_message.clone_from(&state.error_message);
        job.worker_claimed_at = None;
        job.worker_lease_expires_at = None;
        self.writes.lock().unwrap().push(state);
        Ok(AlgoliaImportReconciliationWriteOutcome::Applied {
            unavailable_state_changed,
        })
    }

    async fn finalize_terminal_observation(
        &self,
        authority: AlgoliaImportTerminalFinalizationAuthority,
        fact: AlgoliaImportTerminalFact,
    ) -> Result<AlgoliaImportTerminalFinalizationOutcome, RepoError> {
        self.finalizations
            .lock()
            .unwrap()
            .push(RecordedTerminalFinalization {
                authority,
                fact: fact.clone(),
            });
        if let Some(outcome) = self.terminal_outcomes.lock().unwrap().pop_front() {
            return Ok(outcome);
        }
        let mut job = self.job.lock().unwrap();
        job.status = fact.status;
        job.publication_disposition = fact.publication_disposition;
        job.summary = fact.summary.clone();
        job.error_code = fact.error_code;
        job.error_message.clone_from(&fact.error_message);
        job.engine_ack_state = AlgoliaImportEngineAckState::OutboxPending;
        job.terminal_at = Some(fact.terminal_at);
        job.worker_claimed_at = None;
        job.worker_lease_expires_at = None;
        Ok(AlgoliaImportTerminalFinalizationOutcome::Applied(
            job.clone(),
        ))
    }

    async fn mark_engine_acknowledged(
        &self,
        id: Uuid,
    ) -> Result<AlgoliaImportEngineAckOutcome, RepoError> {
        self.acknowledgements.lock().unwrap().push(id);
        let mut job = self.job.lock().unwrap();
        job.engine_ack_state = AlgoliaImportEngineAckState::Acknowledged;
        Ok(AlgoliaImportEngineAckOutcome {
            id,
            engine_ack_state: job.engine_ack_state,
        })
    }
}

pub(super) struct FixedVmRepo {
    pub(super) vm: Option<VmInventory>,
}

#[async_trait]
impl VmInventoryRepo for FixedVmRepo {
    async fn list_active(&self, _region: Option<&str>) -> Result<Vec<VmInventory>, RepoError> {
        Ok(self.vm.clone().into_iter().collect())
    }

    async fn list_non_decommissioned(&self) -> Result<Vec<VmInventory>, RepoError> {
        Ok(self
            .vm
            .clone()
            .filter(|vm| vm.status != "decommissioned")
            .into_iter()
            .collect())
    }

    async fn get(&self, id: Uuid) -> Result<Option<VmInventory>, RepoError> {
        Ok(self.vm.clone().filter(|vm| vm.id == id))
    }

    async fn create(&self, _vm: NewVmInventory) -> Result<VmInventory, RepoError> {
        panic!("reconciliation never creates VM inventory")
    }

    async fn update_load(&self, _id: Uuid, _load: serde_json::Value) -> Result<(), RepoError> {
        panic!("reconciliation never updates VM load")
    }

    async fn set_status(&self, _id: Uuid, _status: &str) -> Result<(), RepoError> {
        panic!("reconciliation never changes VM status")
    }

    async fn retirement_blockers(
        &self,
        _id: Uuid,
        _expected_hostname: &str,
    ) -> Result<VmRetirementAssessment, RepoError> {
        panic!("reconciliation never assesses VM retirement")
    }

    async fn decommission_if_unreferenced(
        &self,
        _id: Uuid,
        _expected_hostname: &str,
    ) -> Result<VmDecommissionResult, RepoError> {
        panic!("reconciliation never decommissions VMs")
    }

    async fn find_by_hostname(&self, _hostname: &str) -> Result<Option<VmInventory>, RepoError> {
        panic!("reconciliation resolves only the persisted VM id")
    }
}

pub(super) struct QueueHttpClient {
    pub(super) requests: Mutex<Vec<FlapjackHttpRequest>>,
    responses: Mutex<VecDeque<Result<FlapjackHttpResponse, ProxyError>>>,
}

#[async_trait]
impl FlapjackHttpClient for QueueHttpClient {
    async fn send(&self, request: FlapjackHttpRequest) -> Result<FlapjackHttpResponse, ProxyError> {
        self.requests.lock().unwrap().push(request);
        self.responses
            .lock()
            .unwrap()
            .pop_front()
            .expect("test response must be configured")
    }
}

pub(super) fn job(now: DateTime<Utc>, vm_id: Uuid) -> AlgoliaImportJob {
    AlgoliaImportJob {
        id: Uuid::new_v4(),
        customer_id: Uuid::new_v4(),
        tenant_id: "products_next".to_string(),
        algolia_app_id: "app-id".to_string(),
        destination_kind: AlgoliaImportDestinationKind::Create,
        logical_target: "products_next".to_string(),
        destination_region: "us-east-1".to_string(),
        destination_deployment_id: None,
        destination_vm_id: Some(vm_id),
        physical_uid: Some("private-physical-uid".to_string()),
        source_name: "products".to_string(),
        cloud_job_id: Uuid::new_v4(),
        engine_job_id: Some(Uuid::parse_str(ENGINE_JOB_ID).unwrap()),
        dispatch_intent_state: AlgoliaImportDispatchIntentState::Committed,
        lifecycle_generation: 3,
        idempotency_key: "reconcile-once".to_string(),
        canonical_fingerprint: "fingerprint".to_string(),
        routing_identity: Some("routing".to_string()),
        source_size_bytes: 1024,
        reserved_index_count: 1,
        reserved_customer_storage_bytes: 1024,
        reserved_node_transient_bytes: 1024,
        retryable: true,
        worker_claimed_at: None,
        worker_lease_expires_at: None,
        cancel_requested_at: None,
        resume_intent_generation: 0,
        resume_checkpoint: None,
        resume_deadline: None,
        resume_status_observed_at: None,
        resumable: false,
        resume_count: 0,
        summary: AlgoliaImportSummary {
            documents_expected: 20,
            documents_imported: 10,
            ..Default::default()
        },
        warnings: json!([]),
        error_code: Some(AlgoliaImportErrorCode::BackendUnavailable),
        error_message: None,
        status: AlgoliaImportJobStatus::CopyingDocuments,
        publication_disposition: AlgoliaImportPublicationDisposition::Unchanged,
        engine_ack_state: AlgoliaImportEngineAckState::Pending,
        terminal_at: None,
        created_at: now,
        updated_at: now,
    }
}

pub(super) fn vm(now: DateTime<Utc>, id: Uuid) -> VmInventory {
    VmInventory {
        id,
        region: "us-east-1".to_string(),
        provider: "aws".to_string(),
        hostname: "node-1".to_string(),
        flapjack_url: "https://node-1.example".to_string(),
        capacity: json!({}),
        current_load: json!({}),
        load_scraped_at: Some(now),
        status: "active".to_string(),
        created_at: now,
        updated_at: now,
    }
}

pub(super) fn response(
    status: u16,
    body: serde_json::Value,
) -> Result<FlapjackHttpResponse, ProxyError> {
    Ok(FlapjackHttpResponse {
        status,
        body: body.to_string(),
        request_api_key: String::new(),
    })
}

pub(super) async fn harness(
    responses: Vec<Result<FlapjackHttpResponse, ProxyError>>,
) -> (
    AlgoliaImportService,
    Arc<QueueHttpClient>,
    Arc<MockNodeSecretManager>,
) {
    let http = Arc::new(QueueHttpClient {
        responses: Mutex::new(responses.into()),
        requests: Mutex::new(Vec::new()),
    });
    let secrets = Arc::new(MockNodeSecretManager::new());
    secrets
        .create_node_api_key("node-1", "us-east-1")
        .await
        .unwrap();
    let proxy = Arc::new(FlapjackProxy::with_http_client(
        http.clone(),
        secrets.clone(),
    ));
    (AlgoliaImportService::new(proxy), http, secrets)
}

pub(super) fn config() -> AlgoliaImportReconciliationConfig {
    AlgoliaImportReconciliationConfig {
        interval: StdDuration::from_millis(1),
        lease_duration: Duration::minutes(5),
        batch_size: 4,
    }
}
