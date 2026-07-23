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
    AlgoliaImportPublicationDisposition, AlgoliaImportSummary,
};
use crate::models::vm_inventory::{NewVmInventory, VmInventory};
use crate::repos::{
    AlgoliaImportReconciliationClaim, AlgoliaImportReconciliationLease,
    AlgoliaImportReconciliationWriteOutcome, RepoError, VmDecommissionResult, VmInventoryRepo,
    VmRetirementAssessment,
};
use crate::secrets::mock::MockNodeSecretManager;
use crate::secrets::NodeSecretManager;
use crate::services::alerting::MockAlertService;
use crate::services::flapjack_proxy::{
    FlapjackHttpClient, FlapjackHttpRequest, FlapjackHttpResponse, FlapjackProxy, ProxyError,
};

use super::reconciliation::AlgoliaImportReconciliationStore;
use super::{
    AlgoliaImportReconciliationConfig, AlgoliaImportReconciliationRuntime, AlgoliaImportService,
};

const ENGINE_JOB_ID: &str = "9f11d0a0-4443-44d4-b6c6-1ed71dbeb0fb";

struct FakeReconciliationStore {
    job: Mutex<AlgoliaImportJob>,
    writes: Mutex<Vec<AlgoliaImportJobState>>,
    claim_calls: Mutex<usize>,
}

impl FakeReconciliationStore {
    fn new(job: AlgoliaImportJob) -> Self {
        Self {
            job: Mutex::new(job),
            writes: Mutex::new(Vec::new()),
            claim_calls: Mutex::new(0),
        }
    }

    fn writes(&self) -> Vec<AlgoliaImportJobState> {
        self.writes.lock().unwrap().clone()
    }

    fn claim_calls(&self) -> usize {
        *self.claim_calls.lock().unwrap()
    }

    fn current_job(&self) -> AlgoliaImportJob {
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
}

pub(super) struct FixedVmRepo {
    pub(super) vm: Option<VmInventory>,
}

#[async_trait]
impl VmInventoryRepo for FixedVmRepo {
    async fn list_active(&self, _region: Option<&str>) -> Result<Vec<VmInventory>, RepoError> {
        Ok(self.vm.clone().into_iter().collect())
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
    responses: Mutex<VecDeque<Result<FlapjackHttpResponse, ProxyError>>>,
    requests: Mutex<Vec<FlapjackHttpRequest>>,
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

fn config() -> AlgoliaImportReconciliationConfig {
    AlgoliaImportReconciliationConfig {
        interval: StdDuration::from_millis(1),
        lease_duration: Duration::minutes(5),
        batch_size: 4,
    }
}

#[tokio::test]
async fn reconcile_once_persists_monotonic_running_progress_and_clears_only_unavailable() {
    let now = Utc::now();
    let vm_id = Uuid::new_v4();
    let store = Arc::new(FakeReconciliationStore::new(job(now, vm_id)));
    let alert_service = Arc::new(MockAlertService::new());
    let runtime = AlgoliaImportReconciliationRuntime::new(
        store.clone(),
        Arc::new(FixedVmRepo {
            vm: Some(vm(now, vm_id)),
        }),
        alert_service.clone(),
        config(),
    );
    let (service, http, _) = harness(vec![response(
        200,
        json!({
            "jobId": ENGINE_JOB_ID,
            "phase": "staging",
            "disposition": "running",
            "createdAt": "2026-07-22T00:00:00Z",
            "updatedAt": "2026-07-22T00:00:01Z",
            "exportProgress": {"completed": 12, "total": 20}
        }),
    )])
    .await;

    let report = service.reconcile_once(&runtime, now).await.unwrap();

    assert_eq!(report.claimed, 1);
    assert_eq!(report.persisted, 1);
    assert!(report.terminal_handoffs.is_empty());
    let writes = store.writes();
    assert_eq!(writes.len(), 1);
    assert_eq!(writes[0].status, AlgoliaImportJobStatus::Verifying);
    assert_eq!(writes[0].summary.documents_imported, 12);
    assert_eq!(writes[0].error_code, None);
    assert!(!writes[0].retryable);
    assert_eq!(alert_service.alert_count(), 0);
    let requests = http.requests.lock().unwrap();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        format!("https://node-1.example/1/migrations/algolia/{ENGINE_JOB_ID}")
    );
    assert_eq!(requests[0].json_body, None);
}

#[tokio::test]
async fn reconcile_once_deduplicates_retained_unavailable_alerts_from_persisted_state() {
    let now = Utc::now();
    let vm_id = Uuid::new_v4();
    let mut retained = job(now, vm_id);
    retained.error_code = None;
    retained.retryable = false;
    let store = Arc::new(FakeReconciliationStore::new(retained));
    let alert_service = Arc::new(MockAlertService::new());
    let runtime = AlgoliaImportReconciliationRuntime::new(
        store.clone(),
        Arc::new(FixedVmRepo {
            vm: Some(vm(now, vm_id)),
        }),
        alert_service.clone(),
        config(),
    );
    let not_found = || response(404, json!({"code": "migration_job_not_found"}));
    let (service, _, _) = harness(vec![not_found(), not_found()]).await;

    service.reconcile_once(&runtime, now).await.unwrap();
    service
        .reconcile_once(&runtime, now + Duration::seconds(1))
        .await
        .unwrap();

    let writes = store.writes();
    assert_eq!(writes.len(), 2);
    assert!(writes.iter().all(|state| {
        state.error_code == Some(AlgoliaImportErrorCode::BackendUnavailable) && state.retryable
    }));
    assert_eq!(alert_service.alert_count(), 1);
    let alert = &alert_service.recorded_alerts()[0];
    let serialized = serde_json::to_string(alert).unwrap();
    assert!(!serialized.contains("private-physical-uid"));
}

#[tokio::test]
async fn reconcile_once_returns_terminal_handoff_without_consuming_the_lease() {
    let now = Utc::now();
    let vm_id = Uuid::new_v4();
    let mut retained = job(now, vm_id);
    retained.status = AlgoliaImportJobStatus::Promoting;
    retained.error_code = None;
    retained.retryable = false;
    let store = Arc::new(FakeReconciliationStore::new(retained));
    let runtime = AlgoliaImportReconciliationRuntime::new(
        store.clone(),
        Arc::new(FixedVmRepo {
            vm: Some(vm(now, vm_id)),
        }),
        Arc::new(MockAlertService::new()),
        config(),
    );
    let (service, _, _) = harness(vec![response(
        200,
        json!({
            "jobId": ENGINE_JOB_ID,
            "phase": "activating",
            "disposition": "succeeded",
            "createdAt": "2026-07-22T00:00:00Z",
            "updatedAt": "2026-07-22T00:00:01Z",
            "terminalAt": "2026-07-22T00:00:02Z",
            "exportProgress": {"completed": 20, "total": 20}
        }),
    )])
    .await;

    let report = service.reconcile_once(&runtime, now).await.unwrap();

    assert_eq!(report.claimed, 1);
    assert_eq!(report.persisted, 0);
    assert_eq!(report.terminal_handoffs.len(), 1);
    assert_eq!(
        report.terminal_handoffs[0].status,
        AlgoliaImportJobStatus::Completed
    );
    assert_eq!(
        report.terminal_handoffs[0].publication_disposition,
        AlgoliaImportPublicationDisposition::Promoted
    );
    assert!(store.writes().is_empty());
}

#[tokio::test]
async fn reconcile_once_retains_cancel_intent_across_loss_restart_and_promotion_race() {
    let now = Utc::now();
    let vm_id = Uuid::new_v4();
    let mut cancelling = job(now, vm_id);
    cancelling.status = AlgoliaImportJobStatus::Cancelling;
    cancelling.cancel_requested_at = Some(now - Duration::seconds(1));
    let original_cancel_requested_at = cancelling.cancel_requested_at;
    let store = Arc::new(FakeReconciliationStore::new(cancelling));
    let alert_service = Arc::new(MockAlertService::new());
    let runtime = AlgoliaImportReconciliationRuntime::new(
        store.clone(),
        Arc::new(FixedVmRepo {
            vm: Some(vm(now, vm_id)),
        }),
        alert_service.clone(),
        config(),
    );
    let (service, http, _) = harness(vec![
        response(404, json!({"code": "migration_job_not_found"})),
        response(
            200,
            json!({
                "jobId": ENGINE_JOB_ID,
                "phase": "staging",
                "disposition": "running",
                "createdAt": "2026-07-22T00:00:00Z",
                "updatedAt": "2026-07-22T00:00:01Z",
                "exportProgress": {"completed": 12, "total": 20}
            }),
        ),
        response(
            200,
            json!({
                "jobId": ENGINE_JOB_ID,
                "phase": "activating",
                "disposition": "succeeded",
                "createdAt": "2026-07-22T00:00:00Z",
                "updatedAt": "2026-07-22T00:00:02Z",
                "terminalAt": "2026-07-22T00:00:02Z",
                "exportProgress": {"completed": 20, "total": 20}
            }),
        ),
    ])
    .await;

    let lost = service.reconcile_once(&runtime, now).await.unwrap();
    assert_eq!(lost.persisted, 1);
    assert!(lost.terminal_handoffs.is_empty());
    assert_eq!(
        store.current_job().status,
        AlgoliaImportJobStatus::Cancelling
    );

    let restarted = service
        .reconcile_once(
            &runtime,
            now + config().lease_duration + Duration::seconds(1),
        )
        .await
        .unwrap();
    assert_eq!(restarted.persisted, 1);
    assert!(restarted.terminal_handoffs.is_empty());
    let restarted_job = store.current_job();
    assert_eq!(restarted_job.status, AlgoliaImportJobStatus::Cancelling);
    assert_eq!(restarted_job.summary.documents_imported, 12);
    assert_eq!(restarted_job.error_code, None);
    assert_eq!(
        restarted_job.cancel_requested_at,
        original_cancel_requested_at
    );

    let promoted = service
        .reconcile_once(
            &runtime,
            now + config().lease_duration * 2 + Duration::seconds(2),
        )
        .await
        .unwrap();
    assert_eq!(promoted.persisted, 0);
    assert_eq!(promoted.terminal_handoffs.len(), 1);
    assert_eq!(
        promoted.terminal_handoffs[0].status,
        AlgoliaImportJobStatus::Completed
    );
    assert_eq!(
        promoted.terminal_handoffs[0].publication_disposition,
        AlgoliaImportPublicationDisposition::Promoted
    );
    assert_eq!(
        store.current_job().status,
        AlgoliaImportJobStatus::Cancelling
    );
    assert_eq!(
        store.current_job().cancel_requested_at,
        original_cancel_requested_at
    );
    assert_eq!(store.writes().len(), 2);
    assert_eq!(store.claim_calls(), 3);
    let requests = http.requests.lock().unwrap();
    assert_eq!(requests.len(), 3);
    assert!(requests.iter().all(|request| {
        request.method == reqwest::Method::GET
            && request.json_body.is_none()
            && request.url.ends_with(ENGINE_JOB_ID)
    }));
}

#[tokio::test]
async fn reconciliation_loop_honors_an_already_requested_shutdown_without_claiming() {
    let now = Utc::now();
    let vm_id = Uuid::new_v4();
    let store = Arc::new(FakeReconciliationStore::new(job(now, vm_id)));
    let runtime = AlgoliaImportReconciliationRuntime::new(
        store.clone(),
        Arc::new(FixedVmRepo { vm: None }),
        Arc::new(MockAlertService::new()),
        config(),
    );
    let (service, _, _) = harness(Vec::new()).await;
    let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(true);

    service.run_reconciliation_loop(runtime, shutdown_rx).await;

    assert_eq!(store.claim_calls(), 0);
    drop(shutdown_tx);
}
