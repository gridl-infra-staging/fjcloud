use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::Duration as StdDuration;

use async_trait::async_trait;
use chrono::{DateTime, Duration, Utc};
use serde_json::json;
use sqlx::PgPool;
use uuid::Uuid;

use crate::models::algolia_import_job::{
    AlgoliaImportCreateDestination, AlgoliaImportEngineAckState, AlgoliaImportJob,
    AlgoliaImportJobState, AlgoliaImportJobStatus, AlgoliaImportSource,
    AlgoliaImportSourceMetadata, NewAlgoliaImportJob,
};
use crate::repos::{
    AlgoliaImportDispatchAdmission, AlgoliaImportJobRepo, PgAlgoliaImportJobRepo, PgVmInventoryRepo,
};
use crate::secrets::mock::MockNodeSecretManager;
use crate::secrets::NodeSecretManager;
use crate::services::alerting::MockAlertService;
use crate::services::flapjack_proxy::{
    FlapjackHttpClient, FlapjackHttpRequest, FlapjackHttpResponse, FlapjackProxy, ProxyError,
};

use super::reconciliation::{
    AlgoliaImportReconciliationConfig, AlgoliaImportReconciliationRuntime,
};
use super::AlgoliaImportService;

// Crate-internal SQL tests reuse the same isolated-schema harness as integration tests.
#[allow(clippy::duplicate_mod)]
#[path = "../../../tests/common/support/pg_schema_harness.rs"]
mod pg_schema_harness;

use pg_schema_harness::{connect_and_migrate, insert_active_customer, postgres_timestamp};

const NODE_HOSTNAME: &str = "node-1";
const REGION: &str = "us-east-1";

struct QueueHttpClient {
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

async fn service_harness(
    responses: Vec<Result<FlapjackHttpResponse, ProxyError>>,
) -> (AlgoliaImportService, Arc<QueueHttpClient>) {
    let http = Arc::new(QueueHttpClient {
        responses: Mutex::new(responses.into()),
        requests: Mutex::new(Vec::new()),
    });
    let secrets = Arc::new(MockNodeSecretManager::new());
    secrets
        .create_node_api_key(NODE_HOSTNAME, REGION)
        .await
        .expect("seed node API key");
    let proxy = Arc::new(FlapjackProxy::with_http_client(
        http.clone(),
        secrets.clone(),
    ));
    (AlgoliaImportService::new(proxy), http)
}

fn new_job(customer_id: Uuid, key: &str) -> NewAlgoliaImportJob {
    NewAlgoliaImportJob::create(
        customer_id,
        AlgoliaImportCreateDestination::new("products", REGION),
        AlgoliaImportSource::from_final_key_metadata(
            "AB12CD34EF",
            "Products",
            AlgoliaImportSourceMetadata::new(Some(12_345), Some(1_000), format!("revision-{key}")),
        ),
        key,
    )
}

async fn seed_active_vm(pool: &PgPool) -> Uuid {
    let vm_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO vm_inventory
         (id, region, provider, hostname, flapjack_url, status, capacity, current_load)
         VALUES ($1, $2, 'aws', $3, $4, 'active', $5::jsonb, $6::jsonb)",
    )
    .bind(vm_id)
    .bind(REGION)
    .bind(NODE_HOSTNAME)
    .bind("https://node-1.example")
    .bind(json!({ "disk_bytes": 10_000_000_000_i64 }))
    .bind(json!({ "disk_bytes": 0_i64 }))
    .execute(pool)
    .await
    .expect("seed active VM");
    vm_id
}

async fn attach_create_placement(pool: &PgPool, job: &AlgoliaImportJob, vm_id: Uuid) {
    let physical_uid =
        crate::services::flapjack_node::flapjack_index_uid(job.customer_id, &job.logical_target);
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET destination_vm_id = $2, physical_uid = $3, routing_identity = $3
         WHERE id = $1",
    )
    .bind(job.id)
    .bind(vm_id)
    .bind(physical_uid)
    .execute(pool)
    .await
    .expect("attach create placement fixture");
}

async fn prepare_running_create_job(
    repo: &PgAlgoliaImportJobRepo,
    pool: &PgPool,
    customer_id: Uuid,
    vm_id: Uuid,
    engine_job_id: Uuid,
    key: &str,
) -> AlgoliaImportJob {
    let admitted = repo
        .admit_dispatch(AlgoliaImportDispatchAdmission::Create(new_job(
            customer_id,
            key,
        )))
        .await
        .expect("admit create dispatch")
        .into_job();
    attach_create_placement(pool, &admitted, vm_id).await;
    let mut job = repo
        .record_dispatch_intent_committed(admitted.id, engine_job_id)
        .await
        .expect("commit engine dispatch intent");
    for status in [
        AlgoliaImportJobStatus::ValidatingSource,
        AlgoliaImportJobStatus::CopyingConfiguration,
        AlgoliaImportJobStatus::CopyingDocuments,
        AlgoliaImportJobStatus::Verifying,
        AlgoliaImportJobStatus::Promoting,
    ] {
        let mut state = AlgoliaImportJobState::try_from(&job).expect("fixture state");
        state.status = status;
        job = repo
            .update_persisted_state(job.id, state)
            .await
            .expect("advance import job state");
    }
    job
}

fn config() -> AlgoliaImportReconciliationConfig {
    AlgoliaImportReconciliationConfig {
        interval: StdDuration::from_millis(1),
        lease_duration: Duration::minutes(5),
        batch_size: 1,
    }
}

fn terminal_response(
    engine_job_id: Uuid,
    terminal_at: DateTime<Utc>,
) -> Result<FlapjackHttpResponse, ProxyError> {
    Ok(FlapjackHttpResponse {
        status: 200,
        body: json!({
            "jobId": engine_job_id,
            "phase": "activating",
            "disposition": "succeeded",
            "createdAt": "2026-07-22T00:00:00Z",
            "updatedAt": terminal_at,
            "terminalAt": terminal_at,
            "exportProgress": {"completed": 20, "total": 20}
        })
        .to_string(),
        request_api_key: String::new(),
    })
}

fn empty_response(status: u16) -> Result<FlapjackHttpResponse, ProxyError> {
    Ok(FlapjackHttpResponse {
        status,
        body: "{}".to_string(),
        request_api_key: String::new(),
    })
}

async fn has_active_reservation(pool: &PgPool, job_id: Uuid) -> bool {
    sqlx::query_scalar(&format!(
        "SELECT EXISTS(
            SELECT 1 FROM algolia_import_jobs
            WHERE id = $1 AND {}
         )",
        PgAlgoliaImportJobRepo::active_reservation_predicate_for_contract_tests()
    ))
    .bind(job_id)
    .fetch_one(pool)
    .await
    .expect("evaluate active reservation predicate")
}

#[tokio::test]
async fn postgres_reconciliation_acknowledges_before_and_after_worker_restart() {
    let Some(db) = connect_and_migrate("algolia_reconcile_restart_ack").await else {
        return;
    };
    let vm_id = seed_active_vm(&db.pool).await;

    let immediate_customer = Uuid::new_v4();
    insert_active_customer(&db.pool, immediate_customer, 1).await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let immediate_engine_job_id = Uuid::new_v4();
    let immediate = prepare_running_create_job(
        &repo,
        &db.pool,
        immediate_customer,
        vm_id,
        immediate_engine_job_id,
        "ack-before-restart",
    )
    .await;
    let terminal_at = postgres_timestamp(Utc::now());
    let runtime = AlgoliaImportReconciliationRuntime::new(
        Arc::new(PgAlgoliaImportJobRepo::new(db.pool.clone())),
        Arc::new(PgVmInventoryRepo::new(db.pool.clone())),
        Arc::new(MockAlertService::new()),
        config(),
    );
    let (service, http) = service_harness(vec![
        terminal_response(immediate_engine_job_id, terminal_at),
        empty_response(204),
    ])
    .await;

    let report = service
        .reconcile_once(&runtime, terminal_at + Duration::seconds(1))
        .await
        .expect("reconcile and acknowledge before restart");

    assert_eq!(report.terminal_finalized, 1);
    let immediate_after = repo
        .get(immediate.id)
        .await
        .expect("read immediate ACK job")
        .expect("immediate ACK job retained");
    assert_eq!(
        immediate_after.engine_ack_state,
        AlgoliaImportEngineAckState::Acknowledged
    );
    assert!(!has_active_reservation(&db.pool, immediate.id).await);
    {
        let requests = http.requests.lock().unwrap();
        assert_eq!(requests.len(), 2);
        assert_eq!(requests[0].method, reqwest::Method::GET);
        assert_eq!(requests[1].method, reqwest::Method::POST);
        assert!(requests[1].url.ends_with("/acknowledge"));
    }

    let restarted_customer = Uuid::new_v4();
    insert_active_customer(&db.pool, restarted_customer, 1).await;
    let restarted_engine_job_id = Uuid::new_v4();
    let restarted = prepare_running_create_job(
        &repo,
        &db.pool,
        restarted_customer,
        vm_id,
        restarted_engine_job_id,
        "ack-after-restart",
    )
    .await;
    let restart_terminal_at = terminal_at + Duration::seconds(10);
    let (failing_service, failing_http) = service_harness(vec![
        terminal_response(restarted_engine_job_id, restart_terminal_at),
        empty_response(503),
    ])
    .await;
    let failing_runtime = AlgoliaImportReconciliationRuntime::new(
        Arc::new(PgAlgoliaImportJobRepo::new(db.pool.clone())),
        Arc::new(PgVmInventoryRepo::new(db.pool.clone())),
        Arc::new(MockAlertService::new()),
        config(),
    );

    let failed_ack = failing_service
        .reconcile_once(&failing_runtime, restart_terminal_at + Duration::seconds(1))
        .await
        .expect("terminal commit survives ACK delivery failure");

    assert_eq!(failed_ack.terminal_finalized, 1);
    let retained_outbox = repo
        .get(restarted.id)
        .await
        .expect("read retained outbox job")
        .expect("retained outbox job exists");
    assert_eq!(
        retained_outbox.engine_ack_state,
        AlgoliaImportEngineAckState::OutboxPending
    );
    assert_eq!(retained_outbox.terminal_at, Some(restart_terminal_at));
    assert!(has_active_reservation(&db.pool, restarted.id).await);
    {
        let failed_requests = failing_http.requests.lock().unwrap();
        assert_eq!(failed_requests.len(), 2);
        assert_eq!(failed_requests[1].method, reqwest::Method::POST);
        assert!(failed_requests[1].url.ends_with("/acknowledge"));
    }

    let (failed_retry_service, failed_retry_http) =
        service_harness(vec![empty_response(503)]).await;
    let failed_retry_runtime = AlgoliaImportReconciliationRuntime::new(
        Arc::new(PgAlgoliaImportJobRepo::new(db.pool.clone())),
        Arc::new(PgVmInventoryRepo::new(db.pool.clone())),
        Arc::new(MockAlertService::new()),
        config(),
    );
    let failed_retry_at = restart_terminal_at + Duration::seconds(3);

    let failed_retry = failed_retry_service
        .reconcile_once(&failed_retry_runtime, failed_retry_at)
        .await
        .expect("retained acknowledgement retry should remain recoverable");

    assert_eq!(failed_retry.claimed, 1);
    assert_eq!(failed_retry.terminal_finalized, 1);
    let released_after_failed_retry = repo
        .get(restarted.id)
        .await
        .expect("read job after failed retained acknowledgement")
        .expect("job remains after failed retained acknowledgement");
    assert!(
        released_after_failed_retry.worker_claimed_at.is_none(),
        "a failed retained acknowledgement must release its worker claim"
    );
    assert!(
        released_after_failed_retry
            .worker_lease_expires_at
            .is_none(),
        "a failed retained acknowledgement must release its worker lease"
    );
    {
        let failed_retry_requests = failed_retry_http.requests.lock().unwrap();
        assert_eq!(failed_retry_requests.len(), 1);
        assert_eq!(failed_retry_requests[0].method, reqwest::Method::POST);
        assert!(failed_retry_requests[0].url.ends_with("/acknowledge"));
    }

    let (fresh_service, fresh_http) = service_harness(vec![empty_response(204)]).await;
    let fresh_runtime = AlgoliaImportReconciliationRuntime::new(
        Arc::new(PgAlgoliaImportJobRepo::new(db.pool.clone())),
        Arc::new(PgVmInventoryRepo::new(db.pool.clone())),
        Arc::new(MockAlertService::new()),
        config(),
    );

    let recovered = fresh_service
        .reconcile_once(&fresh_runtime, failed_retry_at + Duration::seconds(1))
        .await
        .expect("fresh worker retries retained ACK outbox");

    assert_eq!(recovered.claimed, 1);
    assert_eq!(recovered.terminal_finalized, 1);
    let acknowledged = repo
        .get(restarted.id)
        .await
        .expect("read recovered ACK job")
        .expect("recovered ACK job retained");
    assert_eq!(
        acknowledged.engine_ack_state,
        AlgoliaImportEngineAckState::Acknowledged
    );
    assert_eq!(acknowledged.terminal_at, Some(restart_terminal_at));
    assert!(!has_active_reservation(&db.pool, restarted.id).await);
    let recovered_requests = fresh_http.requests.lock().unwrap();
    assert_eq!(recovered_requests.len(), 1);
    assert_eq!(recovered_requests[0].method, reqwest::Method::POST);
    assert!(recovered_requests[0].url.ends_with("/acknowledge"));
}
