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
    AlgoliaImportDispatchAdmission, AlgoliaImportJobRepo, AlgoliaImportReconciliationWork,
    CustomerHardDeleteKind, CustomerHardDeleteOutcome, CustomerRepo, PgAlgoliaImportJobRepo,
    PgCustomerRepo, PgVmInventoryRepo,
};
use crate::secrets::mock::MockNodeSecretManager;
use crate::secrets::NodeSecretManager;
use crate::services::alerting::MockAlertService;
use crate::services::flapjack_proxy::{
    FlapjackHttpClient, FlapjackHttpRequest, FlapjackHttpResponse, FlapjackProxy, ProxyError,
    SensitiveFlapjackHttpRequest,
};

use super::reconciliation::{
    AlgoliaImportReconciliationConfig, AlgoliaImportReconciliationRuntime,
};
use super::AlgoliaImportService;

// Crate-internal SQL tests reuse the same isolated-schema harness as integration tests.
#[allow(clippy::duplicate_mod)]
#[path = "../../../tests/common/support/pg_schema_harness.rs"]
mod pg_schema_harness;

#[allow(clippy::type_complexity)]
#[path = "reconciliation_privacy_scrub_postgres_tests.rs"]
mod privacy_scrub_postgres_tests;

use pg_schema_harness::{
    connect_and_migrate, connect_and_migrate_through, insert_active_customer,
    migrate_through_version, postgres_timestamp,
};

const NODE_HOSTNAME: &str = "node-1";
const REGION: &str = "us-east-1";
const LOGICAL_TARGET_PII_CANARY: &str = "privacy_scrub_target_canary";
const SOURCE_NAME_PII_CANARY: &str = "privacy_scrub_source_canary";

#[derive(Clone, Debug, PartialEq)]
struct CapturedScrubRequest {
    method: reqwest::Method,
    url: String,
    authenticated: bool,
    json_body: serde_json::Value,
}

struct QueueHttpClient {
    responses: Mutex<VecDeque<Result<FlapjackHttpResponse, ProxyError>>>,
    requests: Mutex<Vec<FlapjackHttpRequest>>,
    scrub_requests: Mutex<Vec<CapturedScrubRequest>>,
}

#[async_trait]
impl FlapjackHttpClient for QueueHttpClient {
    async fn send(&self, request: FlapjackHttpRequest) -> Result<FlapjackHttpResponse, ProxyError> {
        if request.url.ends_with("/1/migrations/privacy-scrub") {
            self.scrub_requests
                .lock()
                .unwrap()
                .push(CapturedScrubRequest {
                    method: request.method.clone(),
                    url: request.url.clone(),
                    authenticated: !request.api_key.is_empty(),
                    json_body: request
                        .json_body
                        .clone()
                        .expect("privacy scrub request must carry JSON"),
                });
        }
        self.requests.lock().unwrap().push(request);
        self.responses
            .lock()
            .unwrap()
            .pop_front()
            .expect("test response must be configured")
    }

    async fn send_sensitive(
        &self,
        request: SensitiveFlapjackHttpRequest<'_>,
    ) -> Result<FlapjackHttpResponse, ProxyError> {
        self.scrub_requests
            .lock()
            .unwrap()
            .push(CapturedScrubRequest {
                method: request.method,
                url: request.url.to_string(),
                authenticated: !request.api_key.is_empty(),
                json_body: serde_json::from_str(request.json_body)
                    .expect("privacy scrub request must carry valid JSON"),
            });
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
        scrub_requests: Mutex::new(Vec::new()),
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
        AlgoliaImportCreateDestination::new(LOGICAL_TARGET_PII_CANARY, REGION),
        AlgoliaImportSource::from_final_key_metadata(
            "AB12CD34EF",
            SOURCE_NAME_PII_CANARY,
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
            "exportProgress": {"completed": 20, "total": 20},
            "settingsApplied": true,
            "synonymsImported": {"imported": 0},
            "rulesImported": {"imported": 0},
            "warnings": []
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

async fn soft_delete_customer(pool: &PgPool, customer_id: Uuid) {
    assert!(
        PgCustomerRepo::new(pool.clone())
            .soft_delete(customer_id)
            .await
            .expect("soft-delete customer"),
        "customer fixture should be active before soft-delete"
    );
}

async fn hard_erase_customer(
    pool: &PgPool,
    customer_id: Uuid,
) -> Vec<crate::models::AlgoliaSealScrubWork> {
    soft_delete_customer(pool, customer_id).await;
    match PgCustomerRepo::new(pool.clone())
        .hard_delete(customer_id, CustomerHardDeleteKind::PrivacyErasure)
        .await
        .expect("hard-erase customer")
    {
        CustomerHardDeleteOutcome::Erased { seal_scrub_work } => seal_scrub_work,
        other => panic!("hard erase must return scrub work, got {other:?}"),
    }
}

async fn serialized_import_job_row_by_erasure_handle(
    pool: &PgPool,
    erasure_handle: Uuid,
) -> serde_json::Value {
    sqlx::query_scalar(
        "SELECT to_jsonb(algolia_import_jobs.*)
         FROM algolia_import_jobs WHERE erasure_handle = $1",
    )
    .bind(erasure_handle)
    .fetch_one(pool)
    .await
    .expect("serialize retained import job tombstone by erasure handle")
}

async fn active_reservation_count_for_erasure_handle(pool: &PgPool, erasure_handle: Uuid) -> i64 {
    sqlx::query_scalar(&format!(
        "SELECT COUNT(*)::BIGINT
         FROM algolia_import_jobs
         WHERE erasure_handle = $1 AND {}",
        PgAlgoliaImportJobRepo::active_reservation_predicate_for_contract_tests()
    ))
    .bind(erasure_handle)
    .fetch_one(pool)
    .await
    .expect("count active erased-row reservations")
}

#[tokio::test]
async fn postgres_reconciliation_claims_erased_tombstone_scrub_work_once_with_stable_opaque_handle()
{
    let Some(db) = connect_and_migrate("algolia_reconcile_erased_scrub_claim").await else {
        return;
    };
    let vm_id = seed_active_vm(&db.pool).await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());

    let eligible_customer = Uuid::new_v4();
    insert_active_customer(&db.pool, eligible_customer, 1).await;
    let eligible_engine_job_id = Uuid::new_v4();
    let eligible = prepare_running_create_job(
        &repo,
        &db.pool,
        eligible_customer,
        vm_id,
        eligible_engine_job_id,
        "red-eligible-erased-scrub",
    )
    .await;
    let scrub_work = hard_erase_customer(&db.pool, eligible_customer).await;
    assert_eq!(scrub_work.len(), 1);
    let erasure_handle = scrub_work[0].erasure_handle;
    assert_eq!(scrub_work[0].engine_job_id, Some(eligible_engine_job_id));
    assert_eq!(scrub_work[0].destination_vm_id, Some(vm_id));

    let tombstone_before_claim =
        serialized_import_job_row_by_erasure_handle(&db.pool, erasure_handle).await;
    assert_eq!(tombstone_before_claim["id"], json!(eligible.id.to_string()));
    assert_eq!(
        tombstone_before_claim["customer_id"],
        serde_json::Value::Null
    );
    assert_eq!(
        tombstone_before_claim["source_name"],
        serde_json::Value::Null
    );
    assert_eq!(
        tombstone_before_claim["logical_target"],
        serde_json::Value::Null
    );
    assert_eq!(
        active_reservation_count_for_erasure_handle(&db.pool, erasure_handle).await,
        0,
        "erased rows must not recreate the customer-target active reservation"
    );

    let now = postgres_timestamp(Utc::now());
    let ineligible_customer = Uuid::new_v4();
    insert_active_customer(&db.pool, ineligible_customer, 1).await;
    let ineligible = prepare_running_create_job(
        &repo,
        &db.pool,
        ineligible_customer,
        vm_id,
        Uuid::new_v4(),
        "red-ineligible-public-control",
    )
    .await;
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET status = 'completed',
             publication_disposition = 'promoted',
             engine_ack_state = 'acknowledged',
             terminal_at = $2,
             worker_claimed_at = NULL,
             worker_lease_expires_at = NULL
         WHERE id = $1",
    )
    .bind(ineligible.id)
    .bind(now - Duration::seconds(30))
    .execute(&db.pool)
    .await
    .expect("mark public control already compacted");

    let compacted_customer = Uuid::new_v4();
    insert_active_customer(&db.pool, compacted_customer, 1).await;
    let compacted = prepare_running_create_job(
        &repo,
        &db.pool,
        compacted_customer,
        vm_id,
        Uuid::new_v4(),
        "red-already-compacted-erased-control",
    )
    .await;
    let compacted_work = hard_erase_customer(&db.pool, compacted_customer).await;
    assert_eq!(compacted_work.len(), 1);
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET cleanup_phase = 'exact_target_absent',
             engine_ack_state = 'acknowledged',
             tombstone_compacted_at = $2
         WHERE id = $1",
    )
    .bind(compacted.id)
    .bind(now - Duration::seconds(20))
    .execute(&db.pool)
    .await
    .expect("mark erased control already compacted");

    let lease_expires_at = now + Duration::minutes(5);
    let claims = repo
        .claim_reconciliation_jobs(now, lease_expires_at, 10)
        .await
        .expect("claim erased scrub work through the public reconciliation seam");

    assert_eq!(
        claims.len(),
        1,
        "Stage 2 must expose exactly one opaque erased-tombstone scrub claim; current production code returns no erased claim because it filters job.erased_at IS NULL and joins customers"
    );
    assert_eq!(claims[0].job.id, eligible.id);
    assert_eq!(claims[0].job.engine_job_id, Some(eligible_engine_job_id));
    assert_eq!(
        claims[0].job.destination_vm_id,
        Some(vm_id),
        "Stage 2 must return an opaque AlgoliaSealScrubWork-equivalent claim keyed by erasure_handle={erasure_handle}, not a repopulated public AlgoliaImportJob"
    );
    let AlgoliaImportReconciliationWork::ErasedTombstone(claimed_scrub_work) = &claims[0].work
    else {
        panic!("erased tombstone row must produce erased scrub work");
    };
    assert_eq!(claimed_scrub_work.erasure_handle, erasure_handle);
    let claimed_lease: (Option<DateTime<Utc>>, Option<DateTime<Utc>>) = sqlx::query_as(
        "SELECT worker_claimed_at, worker_lease_expires_at
         FROM algolia_import_jobs
         WHERE id = $1",
    )
    .bind(eligible.id)
    .fetch_one(&db.pool)
    .await
    .expect("read claimed erased scrub lease");
    assert_eq!(claimed_lease, (Some(now), Some(lease_expires_at)));
    assert_eq!(
        repo.claim_reconciliation_jobs(now + Duration::seconds(1), lease_expires_at, 10)
            .await
            .expect("live lease prevents a concurrent erased scrub claim")
            .len(),
        0,
        "a live erased scrub lease must prevent duplicate worker claims"
    );
    let lease_after_duplicate: (Option<DateTime<Utc>>, Option<DateTime<Utc>>) = sqlx::query_as(
        "SELECT worker_claimed_at, worker_lease_expires_at
         FROM algolia_import_jobs
         WHERE id = $1",
    )
    .bind(eligible.id)
    .fetch_one(&db.pool)
    .await
    .expect("read lease after duplicate exclusion");
    assert_eq!(
        lease_after_duplicate, claimed_lease,
        "duplicate exclusion must not mutate the original live lease"
    );
    let takeover_at = lease_expires_at + Duration::seconds(1);
    let takeover_expires_at = takeover_at + Duration::minutes(5);
    let takeover = repo
        .claim_reconciliation_jobs(takeover_at, takeover_expires_at, 10)
        .await
        .expect("expired erased scrub lease is claimable");
    assert_eq!(takeover.len(), 1);
    assert_eq!(takeover[0].job.id, eligible.id);
    let AlgoliaImportReconciliationWork::ErasedTombstone(replayed_scrub_work) = &takeover[0].work
    else {
        panic!("expired erased tombstone lease must replay erased scrub work");
    };
    assert_eq!(
        replayed_scrub_work.erasure_handle, erasure_handle,
        "expired lease replay must preserve the identical opaque handle"
    );
    let takeover_lease: (Option<DateTime<Utc>>, Option<DateTime<Utc>>) = sqlx::query_as(
        "SELECT worker_claimed_at, worker_lease_expires_at
         FROM algolia_import_jobs
         WHERE id = $1",
    )
    .bind(eligible.id)
    .fetch_one(&db.pool)
    .await
    .expect("read takeover erased scrub lease");
    assert_eq!(
        takeover_lease,
        (Some(takeover_at), Some(takeover_expires_at))
    );
}

#[tokio::test]
async fn postgres_reconciliation_orders_older_erased_tombstone_with_full_public_batch() {
    let Some(db) = connect_and_migrate("algolia_reconcile_erased_scrub_fairness").await else {
        return;
    };
    let vm_id = seed_active_vm(&db.pool).await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let claim_at = postgres_timestamp(Utc::now());

    let erased_customer = Uuid::new_v4();
    insert_active_customer(&db.pool, erased_customer, 1).await;
    let erased = prepare_running_create_job(
        &repo,
        &db.pool,
        erased_customer,
        vm_id,
        Uuid::new_v4(),
        "older-erased-fairness",
    )
    .await;
    let scrub_work = hard_erase_customer(&db.pool, erased_customer).await;
    let erased_updated_at = claim_at - Duration::minutes(5);
    sqlx::query("UPDATE algolia_import_jobs SET updated_at = $2 WHERE id = $1")
        .bind(erased.id)
        .bind(erased_updated_at)
        .execute(&db.pool)
        .await
        .expect("backdate erased fairness specimen");

    let mut public_ids = Vec::new();
    for ordinal in 0..2 {
        let customer_id = Uuid::new_v4();
        insert_active_customer(&db.pool, customer_id, 1).await;
        let job = prepare_running_create_job(
            &repo,
            &db.pool,
            customer_id,
            vm_id,
            Uuid::new_v4(),
            &format!("newer-public-fairness-{ordinal}"),
        )
        .await;
        sqlx::query("UPDATE algolia_import_jobs SET updated_at = $2 WHERE id = $1")
            .bind(job.id)
            .bind(claim_at - Duration::minutes(4 - ordinal))
            .execute(&db.pool)
            .await
            .expect("order public fairness specimen");
        public_ids.push(job.id);
    }

    let lease_expires_at = claim_at + Duration::minutes(5);
    let claims = repo
        .claim_reconciliation_jobs(claim_at, lease_expires_at, 2)
        .await
        .expect("claim one globally ordered bounded reconciliation batch");
    let claimed_ids: Vec<_> = claims.iter().map(|claim| claim.job.id).collect();
    assert_eq!(
        claimed_ids,
        vec![erased.id, public_ids[0]],
        "an older unsent tombstone must not be starved by a full newer public-job batch"
    );
    assert!(matches!(
        claims[0].work,
        AlgoliaImportReconciliationWork::ErasedTombstone(_)
    ));
    assert!(matches!(
        claims[1].work,
        AlgoliaImportReconciliationWork::Import
    ));

    let erased_lease: (Option<DateTime<Utc>>, Option<DateTime<Utc>>) = sqlx::query_as(
        "SELECT worker_claimed_at, worker_lease_expires_at
         FROM algolia_import_jobs
         WHERE id = $1",
    )
    .bind(erased.id)
    .fetch_one(&db.pool)
    .await
    .expect("read fairly claimed erased lease");
    assert_eq!(erased_lease, (Some(claim_at), Some(lease_expires_at)));
    assert_eq!(scrub_work.len(), 1);
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
