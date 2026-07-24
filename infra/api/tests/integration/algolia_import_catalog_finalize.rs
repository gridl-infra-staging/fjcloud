use api::models::algolia_import_job::{
    AlgoliaImportDispatchIntentState, AlgoliaImportEngineAckState, AlgoliaImportErrorCode,
    AlgoliaImportJob, AlgoliaImportJobState, AlgoliaImportJobStatus,
    AlgoliaImportPublicationDisposition, AlgoliaImportSummary, AlgoliaImportTerminalFact,
    EngineResumeMirror,
};
use api::repos::{
    AlgoliaImportEngineAckOutcome, AlgoliaImportJobAdmissionError, AlgoliaImportJobRepo,
    AlgoliaImportReconciliationLease, AlgoliaImportReconciliationWriteOutcome,
    AlgoliaImportTerminalFinalizationAuthority, AlgoliaImportTerminalFinalizationOutcome,
    CatalogLifecycleTargetIdentity, CustomerRepo, PgAlgoliaImportJobRepo, PgCustomerRepo,
    PgDeploymentRepo, PgTenantRepo, PgVmInventoryRepo, RepoError, TenantRepo,
};
use api::router::build_router;
use api::secrets::mock::MockNodeSecretManager;
use api::secrets::NodeSecretManager;
use api::services::flapjack_proxy::FlapjackProxy;
use api::services::tenant_quota::FreeTierLimits;
use axum::body::Body;
use axum::http::{Method, Request, StatusCode};
use chrono::{DateTime, Duration, Utc};
use serde_json::json;
use sqlx::{PgPool, Postgres, Transaction};
use std::fmt::Debug;
use std::sync::Arc;
use tokio::task::JoinHandle;
use tower::ServiceExt;
use uuid::Uuid;

use crate::common::algolia_import_job_test_support::{
    admit_create_dispatch, admit_replace_dispatch, new_create_job, new_job, replace_job,
    seed_replace_target,
};
use crate::common::catalog_live_binding::CatalogLiveBinding;
use crate::common::support::pg_schema_harness::{
    connect_and_migrate, insert_active_customer, pool_in_schema, postgres_timestamp, DbHarness,
};

async fn connect_and_migrate_required(schema_prefix: &str) -> DbHarness {
    connect_and_migrate(schema_prefix).await.unwrap_or_else(|| {
        panic!("DATABASE_URL must be set for Stage 4 PostgreSQL catalog finalization tests")
    })
}

async fn catalog_router(
    pool: &PgPool,
    deployment_node_id: &str,
) -> (
    axum::Router,
    Arc<crate::common::flapjack_proxy_test_support::MockFlapjackHttpClient>,
) {
    let http_client =
        Arc::new(crate::common::flapjack_proxy_test_support::MockFlapjackHttpClient::default());
    let node_secret_manager = Arc::new(MockNodeSecretManager::new());
    node_secret_manager
        .create_node_api_key(deployment_node_id, "us-east-1")
        .await
        .expect("seed finalized deployment API key");
    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client(
        http_client.clone(),
        node_secret_manager,
    ));
    let mut state = crate::common::TestStateBuilder::new()
        .with_pool(pool.clone())
        .with_flapjack_proxy(flapjack_proxy)
        .build();
    state.customer_repo = Arc::new(PgCustomerRepo::new(pool.clone()));
    state.deployment_repo = Arc::new(PgDeploymentRepo::new(pool.clone()));
    state.tenant_repo = Arc::new(PgTenantRepo::new(pool.clone()));
    state.vm_inventory_repo = Arc::new(PgVmInventoryRepo::new(pool.clone()));
    (build_router(state), http_client)
}

async fn tenant_map_entries(pool: &PgPool) -> Vec<api::routes::internal::TenantMapEntry> {
    let mut state = crate::common::TestStateBuilder::new()
        .with_pool(pool.clone())
        .build();
    state.deployment_repo = Arc::new(PgDeploymentRepo::new(pool.clone()));
    state.tenant_repo = Arc::new(PgTenantRepo::new(pool.clone()));
    state.vm_inventory_repo = Arc::new(PgVmInventoryRepo::new(pool.clone()));
    let axum::Json(entries) = api::routes::internal::tenant_map(axum::extract::State(state))
        .await
        .expect("load internal tenant map");
    entries
}

async fn finalized_catalog_identity(
    pool: &PgPool,
    customer_id: Uuid,
    deployment_id: Uuid,
    vm_id: Uuid,
) -> (api::models::tenant::CustomerTenantSummary, String) {
    let tenant_repo = PgTenantRepo::new(pool.clone());
    let mut summaries = tenant_repo
        .find_by_customer(customer_id)
        .await
        .expect("list finalized catalog");
    assert_eq!(summaries.len(), 1);
    let summary = summaries.remove(0);
    assert_eq!(summary.customer_id, customer_id);
    assert_eq!(summary.tenant_id, "products");
    assert_eq!(summary.deployment_id, deployment_id);
    assert_eq!(summary.region, "us-east-1");
    assert_eq!(summary.tier, "active");
    let raw = tenant_repo
        .find_raw(customer_id, "products")
        .await
        .expect("read finalized raw catalog")
        .expect("finalized catalog row exists");
    assert_eq!(raw.vm_id, Some(vm_id));
    assert_eq!(raw.deployment_id, deployment_id);

    let node_id = sqlx::query_scalar("SELECT node_id FROM customer_deployments WHERE id = $1")
        .bind(deployment_id)
        .fetch_one(pool)
        .await
        .expect("read finalized deployment node");
    (summary, node_id)
}

async fn authenticated_get_json(
    app: &axum::Router,
    uri: &str,
    jwt: &str,
) -> (StatusCode, serde_json::Value) {
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(uri)
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .expect("build authenticated GET request"),
        )
        .await
        .expect("authenticated GET response");
    crate::common::indexes_route_test_support::response_json(response).await
}

async fn authenticated_post_json(
    app: &axum::Router,
    uri: &str,
    jwt: &str,
    body: serde_json::Value,
) -> (StatusCode, serde_json::Value) {
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri(uri)
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from(body.to_string()))
                .expect("build authenticated POST request"),
        )
        .await
        .expect("authenticated POST response");
    crate::common::indexes_route_test_support::response_json(response).await
}

fn assert_catalog_list_body(
    status: StatusCode,
    body: &serde_json::Value,
    summary: &api::models::tenant::CustomerTenantSummary,
    physical_uid: &str,
) {
    let list_body = body;
    let list_status = status;
    assert_eq!(list_status, StatusCode::OK);
    assert_eq!(list_body.as_array().map(Vec::len), Some(1));
    assert_eq!(list_body[0]["name"], "products");
    assert_eq!(list_body[0]["region"], "us-east-1");
    assert_eq!(list_body[0]["tier"], "active");
    assert_eq!(list_body[0]["created_at"], summary.created_at.to_rfc3339());
    assert!(!list_body.to_string().contains(physical_uid));
    assert!(list_body[0].get("physical_uid").is_none());
    assert!(list_body[0].get("routing_identity").is_none());
}

fn queue_catalog_stats(
    http_client: &crate::common::flapjack_proxy_test_support::MockFlapjackHttpClient,
    physical_uid: &str,
) {
    http_client.push_json_response(
        200,
        json!({
            "items": [
                {
                    "name": "foreign_physical_uid",
                    "entries": 999,
                    "dataSize": 999999,
                    "fileSize": 999999,
                    "createdAt": "2026-07-23T00:00:00Z",
                    "updatedAt": "2026-07-23T00:00:01Z"
                },
                {
                    "name": physical_uid,
                    "entries": 19,
                    "dataSize": 2048,
                    "fileSize": 4096,
                    "createdAt": "2026-07-23T00:00:00Z",
                    "updatedAt": "2026-07-23T00:00:01Z"
                }
            ],
            "nbPages": 1
        }),
    );
}

fn assert_catalog_get_body(
    get_status: StatusCode,
    get_body: &serde_json::Value,
    created_at: DateTime<Utc>,
    physical_uid: &str,
) {
    assert_eq!(get_status, StatusCode::OK);
    assert_eq!(get_body["name"], "products");
    assert_eq!(get_body["region"], "us-east-1");
    assert_eq!(get_body["entries"], 19);
    assert_eq!(get_body["data_size_bytes"], 2048);
    assert_eq!(get_body["status"], "ready");
    assert_eq!(get_body["created_at"], created_at.to_rfc3339());
    assert!(!get_body.to_string().contains(physical_uid));
    assert!(get_body.get("physical_uid").is_none());
    assert!(get_body.get("routing_identity").is_none());
}

async fn assert_published_catalog_routes(
    pool: &PgPool,
    customer_id: Uuid,
    deployment_id: Uuid,
    vm_id: Uuid,
    physical_uid: &str,
) {
    let (summary, deployment_node_id) =
        finalized_catalog_identity(pool, customer_id, deployment_id, vm_id).await;
    assert_published_tenant_map(pool, customer_id, vm_id, &summary).await;

    let (app, http_client) = catalog_router(pool, &deployment_node_id).await;
    assert_owner_catalog_routes(&app, &http_client, customer_id, &summary, physical_uid).await;
    let sensitive_routing_values = [
        physical_uid.to_string(),
        vm_id.to_string(),
        deployment_id.to_string(),
        customer_id.to_string(),
        summary.flapjack_url.clone().unwrap_or_default(),
        deployment_node_id,
    ];
    assert_foreign_catalog_routes(pool, &app, &sensitive_routing_values).await;
    assert_catalog_proxy_requests(&http_client, &summary, physical_uid);
}

async fn assert_published_tenant_map(
    pool: &PgPool,
    customer_id: Uuid,
    vm_id: Uuid,
    summary: &api::models::tenant::CustomerTenantSummary,
) {
    let entries = tenant_map_entries(pool).await;
    assert_eq!(entries.len(), 1);
    let entry = &entries[0];
    assert_eq!(entry.tenant_id, "products");
    assert_eq!(entry.customer_id, customer_id);
    assert_eq!(
        entry.flapjack_uid,
        api::services::flapjack_node::flapjack_index_uid(customer_id, "products")
    );
    assert_eq!(entry.vm_id, Some(vm_id));
    assert_eq!(entry.flapjack_url, summary.flapjack_url);
    assert_eq!(entry.tier, "active");
    assert_eq!(entry.created_at, summary.created_at);
}

async fn assert_owner_catalog_routes(
    app: &axum::Router,
    http_client: &crate::common::flapjack_proxy_test_support::MockFlapjackHttpClient,
    customer_id: Uuid,
    summary: &api::models::tenant::CustomerTenantSummary,
    physical_uid: &str,
) {
    let jwt = crate::common::create_test_jwt(customer_id);
    let (list_status, list_body) = authenticated_get_json(app, "/indexes", &jwt).await;
    assert_catalog_list_body(list_status, &list_body, summary, physical_uid);

    queue_catalog_stats(http_client, physical_uid);
    let (get_status, get_body) = authenticated_get_json(app, "/indexes/products", &jwt).await;
    assert_catalog_get_body(get_status, &get_body, summary.created_at, physical_uid);

    let search_result = json!({
        "hits": [{"objectID": "one", "title": "Imported product"}],
        "nbHits": 1,
        "page": 0,
        "nbPages": 1
    });
    http_client.push_json_response(200, search_result.clone());
    let (search_status, search_body) = authenticated_post_json(
        app,
        "/indexes/products/search",
        &jwt,
        json!({"query": "imported"}),
    )
    .await;
    assert_eq!(search_status, StatusCode::OK);
    assert_eq!(search_body, search_result);

    http_client.push_text_response(
        200,
        &format!(
            "flapjack_documents_count{{index=\"{physical_uid}\"}} 17\n\
             flapjack_documents_count{{index=\"foreign\"}} 999\n\
             flapjack_storage_bytes{{index=\"{physical_uid}\"}} 2048\n\
             flapjack_search_requests_total{{index=\"{physical_uid}\"}} 23\n\
             flapjack_documents_indexed_total{{index=\"{physical_uid}\"}} 11\n"
        ),
    );
    let (metrics_status, metrics_body) =
        authenticated_get_json(app, "/indexes/products/metrics", &jwt).await;
    assert_eq!(metrics_status, StatusCode::OK);
    assert_eq!(metrics_body["index"], "products");
    assert_eq!(metrics_body["documents_count"], 17);
    assert_eq!(metrics_body["storage_bytes"], 2048);
    assert_eq!(metrics_body["search_requests_total"], 23);
    assert_eq!(metrics_body["write_operations_total"], 11);
    assert!(!metrics_body.to_string().contains(physical_uid));
}

async fn assert_foreign_catalog_routes(
    pool: &PgPool,
    app: &axum::Router,
    sensitive_routing_values: &[String],
) {
    let foreign_customer_id = Uuid::new_v4();
    insert_active_customer(pool, foreign_customer_id, 2).await;
    let foreign_jwt = crate::common::create_test_jwt(foreign_customer_id);
    let foreign_get = authenticated_get_json(app, "/indexes/products", &foreign_jwt).await;
    let foreign_search = authenticated_post_json(
        app,
        "/indexes/products/search",
        &foreign_jwt,
        json!({"query": "imported"}),
    )
    .await;
    let foreign_metrics =
        authenticated_get_json(app, "/indexes/products/metrics", &foreign_jwt).await;
    for (status, body) in [&foreign_get, &foreign_search, &foreign_metrics] {
        assert_eq!(*status, StatusCode::NOT_FOUND);
        assert_eq!(*body, json!({"error": "index 'products' not found"}));
    }
    let foreign_text = format!("{:?}", [foreign_get, foreign_search, foreign_metrics]);
    for sensitive in sensitive_routing_values {
        assert!(
            !foreign_text.contains(sensitive),
            "foreign catalog response leaked sentinel {sensitive:?}: {foreign_text}"
        );
    }
}

fn assert_catalog_proxy_requests(
    http_client: &crate::common::flapjack_proxy_test_support::MockFlapjackHttpClient,
    summary: &api::models::tenant::CustomerTenantSummary,
    physical_uid: &str,
) {
    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 3);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[1].url,
        format!(
            "{}/1/indexes/{physical_uid}/query",
            summary.flapjack_url.as_deref().unwrap()
        )
    );
    assert_eq!(requests[1].json_body, Some(json!({"query": "imported"})));
    assert_eq!(
        requests[2].url,
        format!("{}/metrics", summary.flapjack_url.as_deref().unwrap())
    );
}

async fn seed_active_vm(pool: &PgPool, region: &str) -> Uuid {
    let vm_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO vm_inventory
         (id, region, provider, hostname, flapjack_url, status, capacity, current_load)
         VALUES ($1, $2, 'aws', $3, $4, 'active', $5::jsonb, $6::jsonb)",
    )
    .bind(vm_id)
    .bind(region)
    .bind(format!("vm-{vm_id}"))
    .bind(format!("https://{vm_id}.invalid"))
    .bind(json!({ "disk_bytes": 10_000_000_000_i64 }))
    .bind(json!({ "disk_bytes": 0_i64 }))
    .execute(pool)
    .await
    .expect("seed active VM");
    vm_id
}

async fn attach_create_placement(pool: &PgPool, job: &AlgoliaImportJob, vm_id: Uuid) -> String {
    let physical_uid =
        api::services::flapjack_node::flapjack_index_uid(job.customer_id, &job.logical_target);
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET destination_vm_id = $2, physical_uid = $3, routing_identity = $3
         WHERE id = $1",
    )
    .bind(job.id)
    .bind(vm_id)
    .bind(&physical_uid)
    .execute(pool)
    .await
    .expect("attach prepared create placement fixture");
    physical_uid
}

async fn commit_and_advance(
    repo: &PgAlgoliaImportJobRepo,
    mut job: AlgoliaImportJob,
    target_status: AlgoliaImportJobStatus,
) -> AlgoliaImportJob {
    let engine_job_id = Uuid::new_v4();
    job = repo
        .record_dispatch_intent_committed(job.id, engine_job_id)
        .await
        .expect("commit engine job id");
    for status in [
        AlgoliaImportJobStatus::ValidatingSource,
        AlgoliaImportJobStatus::CopyingConfiguration,
        AlgoliaImportJobStatus::CopyingDocuments,
        AlgoliaImportJobStatus::Verifying,
        AlgoliaImportJobStatus::Promoting,
    ] {
        let mut state = AlgoliaImportJobState::try_from(&job).expect("fixture state");
        state.status = status;
        state.engine_job_id = Some(engine_job_id);
        job = repo
            .update_persisted_state(job.id, state)
            .await
            .expect("advance import job state");
        if status == target_status {
            return job;
        }
    }
    panic!("unsupported target status {target_status:?}");
}

async fn claim_for_finalization(
    repo: &PgAlgoliaImportJobRepo,
    job_id: Uuid,
) -> api::repos::AlgoliaImportReconciliationClaim {
    let now = postgres_timestamp(Utc::now());
    repo.claim_reconciliation_jobs(now, now + Duration::minutes(5), 10)
        .await
        .expect("claim reconciliation jobs")
        .into_iter()
        .find(|claim| claim.job.id == job_id)
        .expect("claim finalization job")
}

/// Reconciliation-recovery entry point: which job ids a fresh worker would pick up
/// on its next claim sweep. Recovery resumes exactly the retained rows this returns.
async fn reconciliation_claim_ids(repo: &PgAlgoliaImportJobRepo) -> Vec<Uuid> {
    let now = postgres_timestamp(Utc::now());
    repo.claim_reconciliation_jobs(now, now + Duration::minutes(5), 50)
        .await
        .expect("claim reconciliation jobs")
        .into_iter()
        .map(|claim| claim.job.id)
        .collect()
}

async fn make_resumable_failed_job(
    repo: &PgAlgoliaImportJobRepo,
    job: AlgoliaImportJob,
    observed_at: DateTime<Utc>,
) -> AlgoliaImportJob {
    let running = commit_and_advance(repo, job, AlgoliaImportJobStatus::CopyingDocuments).await;
    let mut state = AlgoliaImportJobState::try_from(&running).expect("fixture state");
    state.status = AlgoliaImportJobStatus::Failed;
    state.publication_disposition = AlgoliaImportPublicationDisposition::Unchanged;
    state.retryable = true;
    state.resumable = true;
    state.resume_mirror = Some(
        EngineResumeMirror::new(
            "checkpoint-token".to_string(),
            observed_at,
            observed_at + Duration::hours(1),
        )
        .expect("valid resume mirror"),
    );
    state.error_code = Some(AlgoliaImportErrorCode::BackendUnavailable);
    repo.update_persisted_state(running.id, state)
        .await
        .expect("persist resumable failed fixture")
}

fn terminal_fact(
    engine_job_id: Uuid,
    status: AlgoliaImportJobStatus,
    disposition: AlgoliaImportPublicationDisposition,
    terminal_at: DateTime<Utc>,
) -> AlgoliaImportTerminalFact {
    AlgoliaImportTerminalFact::new(
        engine_job_id,
        status,
        disposition,
        AlgoliaImportSummary {
            documents_expected: 10,
            documents_imported: 10,
            ..Default::default()
        },
        terminal_at,
        (status == AlgoliaImportJobStatus::Failed).then_some(AlgoliaImportErrorCode::Internal),
        None,
    )
    .expect("terminal fact fixture")
}

fn terminal_error_code(status: AlgoliaImportJobStatus) -> Option<AlgoliaImportErrorCode> {
    match status {
        AlgoliaImportJobStatus::Failed => Some(AlgoliaImportErrorCode::Internal),
        AlgoliaImportJobStatus::Interrupted => Some(AlgoliaImportErrorCode::Interrupted),
        _ => None,
    }
}

fn matrix_terminal_fact(
    engine_job_id: Uuid,
    status: AlgoliaImportJobStatus,
    disposition: AlgoliaImportPublicationDisposition,
    terminal_at: DateTime<Utc>,
) -> AlgoliaImportTerminalFact {
    AlgoliaImportTerminalFact::new(
        engine_job_id,
        status,
        disposition,
        AlgoliaImportSummary {
            documents_expected: 20,
            documents_imported: 18,
            documents_rejected: 2,
            settings_applied: 3,
            ..Default::default()
        },
        terminal_at,
        terminal_error_code(status),
        terminal_error_code(status).map(|code| format!("sanitized {}", code.as_str())),
    )
    .expect("matrix terminal fact fixture")
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

async fn active_reservation_candidate(
    pool: &PgPool,
    status: AlgoliaImportJobStatus,
    disposition: AlgoliaImportPublicationDisposition,
    ack_state: AlgoliaImportEngineAckState,
    resumable: bool,
) -> bool {
    sqlx::query_scalar(&format!(
        "SELECT ({})
         FROM (SELECT NULL::timestamptz AS erased_at,
                      $1::text AS status,
                      $2::text AS publication_disposition,
                      $3::text AS engine_ack_state,
                      'committed'::text AS dispatch_intent_state,
                      gen_random_uuid() AS engine_job_id,
                      $4::boolean AS resumable) AS candidate",
        PgAlgoliaImportJobRepo::active_reservation_predicate_for_contract_tests()
    ))
    .bind(status.as_str())
    .bind(disposition.as_str())
    .bind(ack_state.as_str())
    .bind(resumable)
    .fetch_one(pool)
    .await
    .expect("evaluate active reservation predicate candidate")
}

fn assert_ack_conflict(result: Result<AlgoliaImportEngineAckOutcome, RepoError>, context: &str) {
    match result {
        Err(RepoError::Conflict(message)) => {
            assert_eq!(
                message, "engine acknowledgement requires retained terminal outbox work",
                "{context}"
            );
        }
        Ok(outcome) => panic!("{context}: unexpectedly acknowledged {outcome:?}"),
        Err(other) => panic!("{context}: expected ACK conflict, got {other:?}"),
    }
}

fn assert_any_ack_conflict(
    result: Result<AlgoliaImportEngineAckOutcome, RepoError>,
    context: &str,
) {
    match result {
        Err(RepoError::Conflict(_)) => {}
        Ok(outcome) => panic!("{context}: unexpectedly acknowledged {outcome:?}"),
        Err(other) => panic!("{context}: expected ACK conflict, got {other:?}"),
    }
}

async fn catalog_row_count(pool: &PgPool, customer_id: Uuid) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM customer_tenants WHERE customer_id = $1")
        .bind(customer_id)
        .fetch_one(pool)
        .await
        .expect("count customer tenant rows")
}

async fn deployment_row_count(pool: &PgPool, customer_id: Uuid) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM customer_deployments WHERE customer_id = $1")
        .bind(customer_id)
        .fetch_one(pool)
        .await
        .expect("count customer deployment rows")
}

async fn assert_catalog_counts(pool: &PgPool, customer_id: Uuid, expected: i64, context: &str) {
    assert_eq!(
        catalog_row_count(pool, customer_id).await,
        expected,
        "{context}: catalog row count"
    );
    assert_eq!(
        deployment_row_count(pool, customer_id).await,
        expected,
        "{context}: deployment row count"
    );
}

fn assert_engine_terminal_truth(
    finalized: &AlgoliaImportJob,
    status: AlgoliaImportJobStatus,
    disposition: AlgoliaImportPublicationDisposition,
    terminal_at: DateTime<Utc>,
) {
    assert_eq!(finalized.status, status);
    assert_eq!(finalized.publication_disposition, disposition);
    assert_eq!(
        finalized.engine_ack_state,
        AlgoliaImportEngineAckState::OutboxPending
    );
    assert_eq!(
        finalized.dispatch_intent_state,
        AlgoliaImportDispatchIntentState::Committed
    );
    assert_eq!(finalized.terminal_at, Some(terminal_at));
    assert!(!finalized.retryable);
    assert!(!finalized.resumable);
    assert_eq!(finalized.resume_checkpoint, None);
    assert_eq!(finalized.resume_status_observed_at, None);
    assert_eq!(finalized.resume_deadline, None);
    assert_eq!(finalized.worker_claimed_at, None);
    assert_eq!(finalized.worker_lease_expires_at, None);
    assert_eq!(finalized.error_code, terminal_error_code(status));
}

fn assert_terminal_snapshot(actual: &AlgoliaImportJob, expected: &AlgoliaImportJob, context: &str) {
    assert_eq!(actual.status, expected.status, "{context}: status");
    assert_eq!(
        actual.publication_disposition, expected.publication_disposition,
        "{context}: publication_disposition"
    );
    assert_eq!(
        actual.engine_ack_state, expected.engine_ack_state,
        "{context}: engine_ack_state"
    );
    assert_eq!(
        actual.terminal_at, expected.terminal_at,
        "{context}: terminal_at"
    );
    assert_eq!(
        actual.destination_deployment_id, expected.destination_deployment_id,
        "{context}: destination_deployment_id"
    );
    assert_eq!(actual.summary, expected.summary, "{context}: summary");
    assert_eq!(
        actual.error_code, expected.error_code,
        "{context}: error_code"
    );
    assert_eq!(
        actual.error_message, expected.error_message,
        "{context}: error_message"
    );
}

#[derive(Clone, Copy)]
enum FinalizationRaceImportKind {
    Create,
    Replace,
}

impl FinalizationRaceImportKind {
    fn label(self) -> &'static str {
        match self {
            Self::Create => "create",
            Self::Replace => "replace",
        }
    }

    fn expected_initial_catalog_rows(self) -> i64 {
        match self {
            Self::Create => 0,
            Self::Replace => 1,
        }
    }
}

async fn seed_promoting_race_job(
    repo: &PgAlgoliaImportJobRepo,
    pool: &PgPool,
    customer_id: Uuid,
    kind: FinalizationRaceImportKind,
    key: &str,
) -> AlgoliaImportJob {
    match kind {
        FinalizationRaceImportKind::Create => {
            let vm_id = seed_active_vm(pool, "us-east-1").await;
            let created = admit_create_dispatch(repo, new_job(customer_id, key)).await;
            attach_create_placement(pool, &created, vm_id).await;
            commit_and_advance(repo, created, AlgoliaImportJobStatus::Promoting).await
        }
        FinalizationRaceImportKind::Replace => {
            seed_replace_target(pool, customer_id, "products").await;
            let created =
                admit_replace_dispatch(repo, replace_job(customer_id, "products", key)).await;
            commit_and_advance(repo, created, AlgoliaImportJobStatus::Promoting).await
        }
    }
}

fn stale_reconciliation_lease(job: &AlgoliaImportJob) -> AlgoliaImportReconciliationLease {
    let claimed_at = postgres_timestamp(Utc::now());
    AlgoliaImportReconciliationLease {
        job_id: job.id,
        lifecycle_generation: job.lifecycle_generation,
        claimed_at,
        expires_at: claimed_at + Duration::minutes(5),
    }
}

async fn assert_customer_soft_deleted_generation(
    pool: &PgPool,
    customer_id: Uuid,
    generation: i64,
    context: &str,
) {
    let row: (String, i64) =
        sqlx::query_as("SELECT status, lifecycle_generation FROM customers WHERE id = $1")
            .bind(customer_id)
            .fetch_one(pool)
            .await
            .expect("read customer lifecycle row");
    assert_eq!(row.0, "deleted", "{context}: customer status");
    assert_eq!(
        row.1,
        generation + 1,
        "{context}: customer generation fence"
    );
}

async fn assert_claim_excludes_job(repo: &PgAlgoliaImportJobRepo, job_id: Uuid, context: &str) {
    assert!(
        !reconciliation_claim_ids(repo).await.contains(&job_id),
        "{context}: soft-deleted stale generation must be absent from reconciliation claims"
    );
}

fn assert_unfinalized_snapshot_unchanged(
    before: &AlgoliaImportJob,
    after: &AlgoliaImportJob,
    context: &str,
) {
    assert_eq!(after.status, before.status, "{context}: status");
    assert_eq!(
        after.publication_disposition, before.publication_disposition,
        "{context}: publication disposition"
    );
    assert_eq!(
        after.engine_ack_state, before.engine_ack_state,
        "{context}: ACK state"
    );
    assert_eq!(after.terminal_at, None, "{context}: terminal_at");
    assert_eq!(
        after.destination_deployment_id, before.destination_deployment_id,
        "{context}: destination deployment"
    );
    assert_eq!(
        after.worker_claimed_at, before.worker_claimed_at,
        "{context}: worker claim timestamp"
    );
    assert_eq!(
        after.worker_lease_expires_at, before.worker_lease_expires_at,
        "{context}: worker lease expiry"
    );
    assert_eq!(after.updated_at, before.updated_at, "{context}: updated_at");
}

async fn finalize_promoted_terminal(
    repo: &PgAlgoliaImportJobRepo,
    job: &AlgoliaImportJob,
    lease: AlgoliaImportReconciliationLease,
) -> AlgoliaImportJob {
    let outcome = repo
        .finalize_terminal_observation(
            AlgoliaImportTerminalFinalizationAuthority::ReconciliationLease(lease),
            terminal_fact(
                job.engine_job_id.expect("engine-linked race fixture"),
                AlgoliaImportJobStatus::Completed,
                AlgoliaImportPublicationDisposition::Promoted,
                postgres_timestamp(Utc::now()),
            ),
        )
        .await
        .expect("finalize promoted terminal observation");
    let AlgoliaImportTerminalFinalizationOutcome::Applied(finalized) = outcome else {
        panic!("expected promoted terminal finalization to apply");
    };
    finalized
}

async fn repo_pool_for_overlap(db: &DbHarness) -> PgPool {
    pool_in_schema(&db.schema, 3).await
}

async fn assert_task_is_waiting<T: Debug>(handle: &mut JoinHandle<T>, context: &str) {
    match tokio::time::timeout(std::time::Duration::from_millis(100), &mut *handle).await {
        Err(_) => {}
        Ok(result) => {
            panic!("{context}: competing operation completed before lock release: {result:?}")
        }
    }
}

async fn join_overlap_task<T>(handle: JoinHandle<T>, context: &str) -> T {
    tokio::time::timeout(std::time::Duration::from_secs(3), handle)
        .await
        .unwrap_or_else(|_| {
            panic!("{context}: competing operation did not finish after lock release")
        })
        .unwrap_or_else(|error| panic!("{context}: competing task failed: {error}"))
}

async fn hold_customer_lifecycle_boundary<'a>(
    pool: &'a PgPool,
    customer_id: Uuid,
) -> Transaction<'a, Postgres> {
    let mut tx = pool.begin().await.expect("begin lifecycle boundary holder");
    sqlx::query_scalar::<_, String>("SELECT status FROM customers WHERE id = $1 FOR UPDATE")
        .bind(customer_id)
        .fetch_one(&mut *tx)
        .await
        .expect("lock customer lifecycle row");
    tx
}

#[tokio::test]
async fn soft_delete_before_claim_fences_create_and_replace_terminal_finalization() {
    let db = connect_and_migrate_required("algolia_catalog_soft_delete_before_claim").await;
    let import_repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer_repo = PgCustomerRepo::new(db.pool.clone());

    for kind in [
        FinalizationRaceImportKind::Create,
        FinalizationRaceImportKind::Replace,
    ] {
        let customer_id = Uuid::new_v4();
        insert_active_customer(&db.pool, customer_id, 1).await;
        let running = seed_promoting_race_job(
            &import_repo,
            &db.pool,
            customer_id,
            kind,
            &format!("soft-delete-before-{}", kind.label()),
        )
        .await;
        assert_catalog_counts(
            &db.pool,
            customer_id,
            kind.expected_initial_catalog_rows(),
            kind.label(),
        )
        .await;

        assert!(
            customer_repo
                .soft_delete(customer_id)
                .await
                .expect("soft delete customer before claim"),
            "{}: soft delete changes the active customer row",
            kind.label()
        );
        assert_customer_soft_deleted_generation(
            &db.pool,
            customer_id,
            running.lifecycle_generation,
            kind.label(),
        )
        .await;
        assert_claim_excludes_job(&import_repo, running.id, kind.label()).await;

        let outcome = import_repo
            .finalize_terminal_observation(
                AlgoliaImportTerminalFinalizationAuthority::ReconciliationLease(
                    stale_reconciliation_lease(&running),
                ),
                terminal_fact(
                    running.engine_job_id.expect("engine-linked race fixture"),
                    AlgoliaImportJobStatus::Completed,
                    AlgoliaImportPublicationDisposition::Promoted,
                    postgres_timestamp(Utc::now()),
                ),
            )
            .await
            .expect("stale finalization is typed");
        assert!(matches!(
            outcome,
            AlgoliaImportTerminalFinalizationOutcome::FenceLost
        ));

        let retained = import_repo
            .get(running.id)
            .await
            .expect("read retained import")
            .expect("soft delete retains import evidence");
        assert_unfinalized_snapshot_unchanged(&running, &retained, kind.label());
        assert_catalog_counts(
            &db.pool,
            customer_id,
            kind.expected_initial_catalog_rows(),
            kind.label(),
        )
        .await;
        assert!(has_active_reservation(&db.pool, retained.id).await);
    }
}

#[tokio::test]
async fn soft_delete_after_claim_fences_stale_create_and_replace_terminal_finalization() {
    let db = connect_and_migrate_required("algolia_catalog_soft_delete_after_claim").await;
    let import_repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer_repo = PgCustomerRepo::new(db.pool.clone());

    for kind in [
        FinalizationRaceImportKind::Create,
        FinalizationRaceImportKind::Replace,
    ] {
        let customer_id = Uuid::new_v4();
        insert_active_customer(&db.pool, customer_id, 1).await;
        let running = seed_promoting_race_job(
            &import_repo,
            &db.pool,
            customer_id,
            kind,
            &format!("soft-delete-after-claim-{}", kind.label()),
        )
        .await;
        let claim = claim_for_finalization(&import_repo, running.id).await;
        let claimed = import_repo
            .get(running.id)
            .await
            .expect("read claimed import")
            .expect("claimed import retained");

        assert!(
            customer_repo
                .soft_delete(customer_id)
                .await
                .expect("soft delete customer after claim"),
            "{}: soft delete changes the active customer row",
            kind.label()
        );
        assert_customer_soft_deleted_generation(
            &db.pool,
            customer_id,
            running.lifecycle_generation,
            kind.label(),
        )
        .await;
        assert_claim_excludes_job(&import_repo, running.id, kind.label()).await;

        let outcome = import_repo
            .finalize_terminal_observation(
                AlgoliaImportTerminalFinalizationAuthority::ReconciliationLease(claim.lease),
                terminal_fact(
                    running.engine_job_id.expect("engine-linked race fixture"),
                    AlgoliaImportJobStatus::Completed,
                    AlgoliaImportPublicationDisposition::Promoted,
                    postgres_timestamp(Utc::now()),
                ),
            )
            .await
            .expect("stale claimed finalization is typed");
        assert!(matches!(
            outcome,
            AlgoliaImportTerminalFinalizationOutcome::FenceLost
        ));

        let retained = import_repo
            .get(running.id)
            .await
            .expect("read retained import")
            .expect("soft delete retains import evidence");
        assert_unfinalized_snapshot_unchanged(&claimed, &retained, kind.label());
        assert_catalog_counts(
            &db.pool,
            customer_id,
            kind.expected_initial_catalog_rows(),
            kind.label(),
        )
        .await;
        assert!(has_active_reservation(&db.pool, retained.id).await);
    }
}

#[tokio::test]
async fn overlapping_soft_delete_winner_fences_waiting_terminal_finalization() {
    let db = connect_and_migrate_required("algolia_catalog_overlap_delete_final").await;
    let setup_repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let lock_pool = repo_pool_for_overlap(&db).await;
    let soft_delete_pool = repo_pool_for_overlap(&db).await;
    let finalizer_pool = repo_pool_for_overlap(&db).await;

    for kind in [
        FinalizationRaceImportKind::Create,
        FinalizationRaceImportKind::Replace,
    ] {
        let customer_id = Uuid::new_v4();
        insert_active_customer(&db.pool, customer_id, 1).await;
        let running = seed_promoting_race_job(
            &setup_repo,
            &db.pool,
            customer_id,
            kind,
            &format!("overlap-delete-final-{}", kind.label()),
        )
        .await;
        let claim = claim_for_finalization(&setup_repo, running.id).await;
        let claimed = setup_repo
            .get(running.id)
            .await
            .expect("read claimed import")
            .expect("claimed import retained");
        let lifecycle_boundary = hold_customer_lifecycle_boundary(&lock_pool, customer_id).await;
        let customer_repo = PgCustomerRepo::new(soft_delete_pool.clone());
        let mut soft_delete =
            tokio::spawn(async move { customer_repo.soft_delete(customer_id).await });
        assert_task_is_waiting(
            &mut soft_delete,
            "soft delete winner must wait at the lifecycle boundary",
        )
        .await;
        let fact = terminal_fact(
            running.engine_job_id.expect("engine-linked race fixture"),
            AlgoliaImportJobStatus::Completed,
            AlgoliaImportPublicationDisposition::Promoted,
            postgres_timestamp(Utc::now()),
        );
        let finalizer_repo = PgAlgoliaImportJobRepo::new(finalizer_pool.clone());
        let mut finalizer = tokio::spawn(async move {
            finalizer_repo
                .finalize_terminal_observation(
                    AlgoliaImportTerminalFinalizationAuthority::ReconciliationLease(claim.lease),
                    fact,
                )
                .await
        });

        assert_task_is_waiting(
            &mut finalizer,
            "terminal finalizer loser must wait at the lifecycle boundary",
        )
        .await;
        lifecycle_boundary
            .commit()
            .await
            .expect("release customer lifecycle boundary");
        assert!(
            join_overlap_task(soft_delete, "soft delete winner")
                .await
                .expect("soft delete winner result"),
            "{}: public soft delete must commit",
            kind.label()
        );

        let outcome = join_overlap_task(finalizer, "terminal finalizer loser")
            .await
            .expect("stale finalizer returns typed outcome");
        assert!(matches!(
            outcome,
            AlgoliaImportTerminalFinalizationOutcome::FenceLost
        ));
        let retained = setup_repo
            .get(running.id)
            .await
            .expect("read retained import")
            .expect("soft delete retains import evidence");
        assert_unfinalized_snapshot_unchanged(&claimed, &retained, kind.label());
        assert_catalog_counts(
            &db.pool,
            customer_id,
            kind.expected_initial_catalog_rows(),
            kind.label(),
        )
        .await;
        assert!(has_active_reservation(&db.pool, retained.id).await);
    }
}

#[tokio::test]
async fn overlapping_terminal_finalization_winner_publishes_before_waiting_soft_delete() {
    let db = connect_and_migrate_required("algolia_catalog_overlap_final_delete").await;
    let setup_repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let lock_pool = repo_pool_for_overlap(&db).await;
    let finalizer_pool = repo_pool_for_overlap(&db).await;
    let soft_delete_pool = repo_pool_for_overlap(&db).await;

    for kind in [
        FinalizationRaceImportKind::Create,
        FinalizationRaceImportKind::Replace,
    ] {
        let customer_id = Uuid::new_v4();
        insert_active_customer(&db.pool, customer_id, 1).await;
        let running = seed_promoting_race_job(
            &setup_repo,
            &db.pool,
            customer_id,
            kind,
            &format!("overlap-final-delete-{}", kind.label()),
        )
        .await;
        let claim = claim_for_finalization(&setup_repo, running.id).await;
        let lifecycle_boundary = hold_customer_lifecycle_boundary(&lock_pool, customer_id).await;
        let fact = terminal_fact(
            running.engine_job_id.expect("engine-linked race fixture"),
            AlgoliaImportJobStatus::Completed,
            AlgoliaImportPublicationDisposition::Promoted,
            postgres_timestamp(Utc::now()),
        );
        let finalizer_repo = PgAlgoliaImportJobRepo::new(finalizer_pool.clone());
        let authority =
            AlgoliaImportTerminalFinalizationAuthority::ReconciliationLease(claim.lease);
        let winner_fact = fact.clone();
        let mut finalizer = tokio::spawn(async move {
            finalizer_repo
                .finalize_terminal_observation(authority, winner_fact)
                .await
        });
        assert_task_is_waiting(
            &mut finalizer,
            "terminal finalization winner must wait at the lifecycle boundary",
        )
        .await;
        let customer_repo = PgCustomerRepo::new(soft_delete_pool.clone());
        let mut soft_delete =
            tokio::spawn(async move { customer_repo.soft_delete(customer_id).await });

        assert_task_is_waiting(
            &mut soft_delete,
            "soft delete loser must wait at the lifecycle boundary",
        )
        .await;
        lifecycle_boundary
            .commit()
            .await
            .expect("release customer lifecycle boundary");
        let finalization = join_overlap_task(finalizer, "terminal finalization winner")
            .await
            .expect("terminal finalization winner result");
        let AlgoliaImportTerminalFinalizationOutcome::Applied(finalized) = finalization else {
            panic!("{}: public terminal finalization must apply", kind.label());
        };
        assert_engine_terminal_truth(
            &finalized,
            AlgoliaImportJobStatus::Completed,
            AlgoliaImportPublicationDisposition::Promoted,
            fact.terminal_at,
        );

        assert!(
            join_overlap_task(soft_delete, "soft delete loser")
                .await
                .expect("soft delete after finalization"),
            "{}: soft delete applies after terminal truth commits",
            kind.label()
        );
        let retained = setup_repo
            .get(running.id)
            .await
            .expect("read retained import")
            .expect("soft delete retains terminal import evidence");
        assert_eq!(retained.status, AlgoliaImportJobStatus::Completed);
        assert_eq!(
            retained.publication_disposition,
            AlgoliaImportPublicationDisposition::Promoted
        );
        assert_eq!(
            retained.engine_ack_state,
            AlgoliaImportEngineAckState::OutboxPending
        );
        assert_eq!(retained.terminal_at, Some(fact.terminal_at));
        assert_catalog_counts(&db.pool, customer_id, 1, kind.label()).await;
        assert_customer_soft_deleted_generation(
            &db.pool,
            customer_id,
            running.lifecycle_generation,
            kind.label(),
        )
        .await;
        assert_any_ack_conflict(
            setup_repo.mark_engine_acknowledged(retained.id).await,
            "soft-deleted terminal winner remains ACK fenced",
        );
        assert!(has_active_reservation(&db.pool, retained.id).await);
    }
}

#[tokio::test]
async fn overlapping_soft_delete_winner_fences_waiting_engine_ack() {
    let db = connect_and_migrate_required("algolia_catalog_overlap_delete_ack").await;
    let setup_repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let lock_pool = repo_pool_for_overlap(&db).await;
    let soft_delete_pool = repo_pool_for_overlap(&db).await;
    let ack_pool = repo_pool_for_overlap(&db).await;
    let ack_repo = PgAlgoliaImportJobRepo::new(ack_pool.clone());

    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 1).await;
    let running = seed_promoting_race_job(
        &setup_repo,
        &db.pool,
        customer_id,
        FinalizationRaceImportKind::Create,
        "overlap-delete-ack",
    )
    .await;
    let claim = claim_for_finalization(&setup_repo, running.id).await;
    let finalized = finalize_promoted_terminal(&setup_repo, &running, claim.lease).await;
    let lifecycle_boundary = hold_customer_lifecycle_boundary(&lock_pool, customer_id).await;
    let customer_repo = PgCustomerRepo::new(soft_delete_pool.clone());
    let mut soft_delete = tokio::spawn(async move { customer_repo.soft_delete(customer_id).await });
    assert_task_is_waiting(
        &mut soft_delete,
        "soft delete winner must wait at the lifecycle boundary",
    )
    .await;
    let mut ack =
        tokio::spawn(async move { ack_repo.mark_engine_acknowledged(finalized.id).await });

    assert_task_is_waiting(&mut ack, "ACK loser must wait at the lifecycle boundary").await;
    lifecycle_boundary
        .commit()
        .await
        .expect("release customer lifecycle boundary");
    assert!(
        join_overlap_task(soft_delete, "soft delete winner")
            .await
            .expect("soft delete winner result"),
        "public soft delete must commit"
    );

    assert_any_ack_conflict(
        join_overlap_task(ack, "ACK loser").await,
        "soft delete winner fences waiting ACK",
    );
    let retained = setup_repo
        .get(running.id)
        .await
        .expect("read retained import")
        .expect("soft delete retains terminal import evidence");
    assert_eq!(
        retained.engine_ack_state,
        AlgoliaImportEngineAckState::OutboxPending
    );
    assert!(has_active_reservation(&db.pool, retained.id).await);
}

#[tokio::test]
async fn overlapping_engine_ack_winner_releases_before_waiting_soft_delete() {
    let db = connect_and_migrate_required("algolia_catalog_overlap_ack_delete").await;
    let setup_repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let lock_pool = repo_pool_for_overlap(&db).await;
    let ack_pool = repo_pool_for_overlap(&db).await;
    let soft_delete_pool = repo_pool_for_overlap(&db).await;
    let customer_repo = PgCustomerRepo::new(soft_delete_pool.clone());

    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 1).await;
    let running = seed_promoting_race_job(
        &setup_repo,
        &db.pool,
        customer_id,
        FinalizationRaceImportKind::Create,
        "overlap-ack-delete",
    )
    .await;
    let claim = claim_for_finalization(&setup_repo, running.id).await;
    let finalized = finalize_promoted_terminal(&setup_repo, &running, claim.lease).await;
    let lifecycle_boundary = hold_customer_lifecycle_boundary(&lock_pool, customer_id).await;
    let ack_repo = PgAlgoliaImportJobRepo::new(ack_pool.clone());
    let finalized_id = finalized.id;
    let mut ack =
        tokio::spawn(async move { ack_repo.mark_engine_acknowledged(finalized_id).await });
    assert_task_is_waiting(&mut ack, "ACK winner must wait at the lifecycle boundary").await;
    let mut soft_delete = tokio::spawn(async move { customer_repo.soft_delete(customer_id).await });

    assert_task_is_waiting(
        &mut soft_delete,
        "soft delete loser must wait at the lifecycle boundary",
    )
    .await;
    lifecycle_boundary
        .commit()
        .await
        .expect("release customer lifecycle boundary");
    let acknowledged = join_overlap_task(ack, "ACK winner")
        .await
        .expect("ACK winner result");
    assert_eq!(acknowledged.id, finalized.id);
    assert_eq!(
        acknowledged.engine_ack_state,
        AlgoliaImportEngineAckState::Acknowledged
    );

    assert!(
        join_overlap_task(soft_delete, "soft delete after ACK")
            .await
            .expect("soft delete after ACK"),
        "soft delete applies after ACK truth commits"
    );
    let retained = setup_repo
        .get(running.id)
        .await
        .expect("read retained import")
        .expect("soft delete retains ACKed import evidence");
    assert_eq!(
        retained.engine_ack_state,
        AlgoliaImportEngineAckState::Acknowledged
    );
    assert!(!has_active_reservation(&db.pool, retained.id).await);
    assert_catalog_counts(&db.pool, customer_id, 1, "ACK winner").await;
}

#[tokio::test]
async fn soft_delete_after_promoted_finalization_retains_catalog_truth_and_fences_ack() {
    let db = connect_and_migrate_required("algolia_catalog_soft_delete_after_final").await;
    let import_repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer_repo = PgCustomerRepo::new(db.pool.clone());

    for kind in [
        FinalizationRaceImportKind::Create,
        FinalizationRaceImportKind::Replace,
    ] {
        let customer_id = Uuid::new_v4();
        insert_active_customer(&db.pool, customer_id, 1).await;
        let running = seed_promoting_race_job(
            &import_repo,
            &db.pool,
            customer_id,
            kind,
            &format!("soft-delete-after-final-{}", kind.label()),
        )
        .await;
        let claim = claim_for_finalization(&import_repo, running.id).await;
        let finalized = finalize_promoted_terminal(&import_repo, &running, claim.lease).await;
        assert_eq!(
            finalized.engine_ack_state,
            AlgoliaImportEngineAckState::OutboxPending
        );
        assert_eq!(catalog_row_count(&db.pool, customer_id).await, 1);
        assert_eq!(deployment_row_count(&db.pool, customer_id).await, 1);
        assert!(has_active_reservation(&db.pool, finalized.id).await);

        assert!(
            customer_repo
                .soft_delete(customer_id)
                .await
                .expect("soft delete customer after finalization"),
            "{}: soft delete changes the active customer row",
            kind.label()
        );
        assert_customer_soft_deleted_generation(
            &db.pool,
            customer_id,
            running.lifecycle_generation,
            kind.label(),
        )
        .await;
        assert_claim_excludes_job(&import_repo, running.id, kind.label()).await;
        assert_any_ack_conflict(
            import_repo.mark_engine_acknowledged(finalized.id).await,
            "soft-deleted public terminal rows remain ACK fenced",
        );

        let retained = import_repo
            .get(finalized.id)
            .await
            .expect("read retained import")
            .expect("soft delete retains terminal import evidence");
        assert_terminal_snapshot(&retained, &finalized, kind.label());
        assert_eq!(catalog_row_count(&db.pool, customer_id).await, 1);
        assert_eq!(deployment_row_count(&db.pool, customer_id).await, 1);
        assert!(has_active_reservation(&db.pool, retained.id).await);
    }
}

#[tokio::test]
async fn soft_delete_after_ack_retains_released_terminal_truth_without_reopening_reservation() {
    let db = connect_and_migrate_required("algolia_catalog_soft_delete_after_ack").await;
    let import_repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer_repo = PgCustomerRepo::new(db.pool.clone());

    for kind in [
        FinalizationRaceImportKind::Create,
        FinalizationRaceImportKind::Replace,
    ] {
        let customer_id = Uuid::new_v4();
        insert_active_customer(&db.pool, customer_id, 1).await;
        let running = seed_promoting_race_job(
            &import_repo,
            &db.pool,
            customer_id,
            kind,
            &format!("soft-delete-after-ack-{}", kind.label()),
        )
        .await;
        let claim = claim_for_finalization(&import_repo, running.id).await;
        let finalized = finalize_promoted_terminal(&import_repo, &running, claim.lease).await;
        let ack = import_repo
            .mark_engine_acknowledged(finalized.id)
            .await
            .expect("acknowledge promoted terminal before soft delete");
        assert_eq!(
            ack.engine_ack_state,
            AlgoliaImportEngineAckState::Acknowledged
        );
        assert!(!has_active_reservation(&db.pool, finalized.id).await);

        assert!(
            customer_repo
                .soft_delete(customer_id)
                .await
                .expect("soft delete customer after ACK"),
            "{}: soft delete changes the active customer row",
            kind.label()
        );
        assert_customer_soft_deleted_generation(
            &db.pool,
            customer_id,
            running.lifecycle_generation,
            kind.label(),
        )
        .await;
        assert_claim_excludes_job(&import_repo, running.id, kind.label()).await;

        let retained = import_repo
            .get(finalized.id)
            .await
            .expect("read retained import")
            .expect("soft delete retains acknowledged import evidence");
        assert_eq!(
            retained.engine_ack_state,
            AlgoliaImportEngineAckState::Acknowledged
        );
        assert_eq!(retained.terminal_at, finalized.terminal_at);
        assert_eq!(
            retained.destination_deployment_id,
            finalized.destination_deployment_id
        );
        assert_eq!(catalog_row_count(&db.pool, customer_id).await, 1);
        assert_eq!(deployment_row_count(&db.pool, customer_id).await, 1);
        assert!(!has_active_reservation(&db.pool, retained.id).await);
    }
}

#[tokio::test]
async fn engine_linked_terminal_matrix_sets_outbox_pending_and_catalog_effects() {
    let db = connect_and_migrate_required("algolia_catalog_matrix").await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let cases = [
        (
            "completed",
            AlgoliaImportJobStatus::Completed,
            AlgoliaImportPublicationDisposition::Promoted,
            true,
        ),
        (
            "completed-warnings",
            AlgoliaImportJobStatus::CompletedWithWarnings,
            AlgoliaImportPublicationDisposition::Promoted,
            true,
        ),
        (
            "cancelled",
            AlgoliaImportJobStatus::Cancelled,
            AlgoliaImportPublicationDisposition::Unchanged,
            false,
        ),
        (
            "failed-unchanged",
            AlgoliaImportJobStatus::Failed,
            AlgoliaImportPublicationDisposition::Unchanged,
            false,
        ),
        (
            "failed-not-started",
            AlgoliaImportJobStatus::Failed,
            AlgoliaImportPublicationDisposition::NotStarted,
            false,
        ),
        (
            "interrupted-unchanged",
            AlgoliaImportJobStatus::Interrupted,
            AlgoliaImportPublicationDisposition::Unchanged,
            false,
        ),
    ];

    for (key, status, disposition, publishes_catalog) in cases {
        let customer_id = Uuid::new_v4();
        insert_active_customer(&db.pool, customer_id, 1).await;
        let vm_id = seed_active_vm(&db.pool, "us-east-1").await;
        let created = admit_create_dispatch(&repo, new_job(customer_id, key)).await;
        let physical_uid = attach_create_placement(&db.pool, &created, vm_id).await;
        let running = commit_and_advance(&repo, created, AlgoliaImportJobStatus::Promoting).await;
        let current = if status == AlgoliaImportJobStatus::Cancelled {
            repo.request_cancel(running.id)
                .await
                .expect("request cancel")
                .job
        } else {
            running
        };
        let claim = claim_for_finalization(&repo, current.id).await;
        let terminal_at = postgres_timestamp(Utc::now());

        let outcome = repo
            .finalize_terminal_observation(
                AlgoliaImportTerminalFinalizationAuthority::ReconciliationLease(claim.lease),
                matrix_terminal_fact(
                    current.engine_job_id.unwrap(),
                    status,
                    disposition,
                    terminal_at,
                ),
            )
            .await
            .expect("finalize matrix terminal observation");
        let AlgoliaImportTerminalFinalizationOutcome::Applied(finalized) = outcome else {
            panic!("expected Applied for {key}");
        };

        assert_engine_terminal_truth(&finalized, status, disposition, terminal_at);
        assert_eq!(finalized.destination_vm_id, Some(vm_id));
        assert_eq!(
            finalized.physical_uid.as_deref(),
            Some(physical_uid.as_str())
        );
        assert!(
            has_active_reservation(&db.pool, finalized.id).await,
            "engine terminal {key} remains reserved until confirmed ACK"
        );
        let ack = repo
            .mark_engine_acknowledged(finalized.id)
            .await
            .unwrap_or_else(|error| panic!("acknowledge finalized engine terminal {key}: {error}"));
        assert_eq!(
            ack.engine_ack_state,
            AlgoliaImportEngineAckState::Acknowledged
        );
        assert!(
            !has_active_reservation(&db.pool, finalized.id).await,
            "engine terminal {key} releases only after confirmed ACK"
        );
        assert_eq!(
            catalog_row_count(&db.pool, customer_id).await,
            i64::from(publishes_catalog)
        );
        assert_eq!(
            deployment_row_count(&db.pool, customer_id).await,
            i64::from(publishes_catalog)
        );
        assert_eq!(
            finalized.destination_deployment_id.is_some(),
            publishes_catalog,
            "create catalog deployment effect mismatch for {key}"
        );
    }
}

#[tokio::test]
async fn terminal_matrix_races_preserve_durable_truth_and_catalog_rows() {
    let db = connect_and_migrate_required("algolia_catalog_terminal_races").await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let cases = [
        (
            "completed",
            AlgoliaImportJobStatus::Completed,
            AlgoliaImportPublicationDisposition::Promoted,
            1_i64,
        ),
        (
            "completed-warnings",
            AlgoliaImportJobStatus::CompletedWithWarnings,
            AlgoliaImportPublicationDisposition::Promoted,
            1_i64,
        ),
        (
            "cancelled",
            AlgoliaImportJobStatus::Cancelled,
            AlgoliaImportPublicationDisposition::Unchanged,
            0_i64,
        ),
        (
            "failed-unchanged",
            AlgoliaImportJobStatus::Failed,
            AlgoliaImportPublicationDisposition::Unchanged,
            0_i64,
        ),
        (
            "failed-not-started",
            AlgoliaImportJobStatus::Failed,
            AlgoliaImportPublicationDisposition::NotStarted,
            0_i64,
        ),
        (
            "interrupted-unchanged",
            AlgoliaImportJobStatus::Interrupted,
            AlgoliaImportPublicationDisposition::Unchanged,
            0_i64,
        ),
    ];

    for (key, status, disposition, expected_catalog_rows) in cases {
        let customer_id = Uuid::new_v4();
        insert_active_customer(&db.pool, customer_id, 1).await;
        let vm_id = seed_active_vm(&db.pool, "us-east-1").await;
        let created = admit_create_dispatch(&repo, new_job(customer_id, key)).await;
        attach_create_placement(&db.pool, &created, vm_id).await;
        let running = commit_and_advance(&repo, created, AlgoliaImportJobStatus::Promoting).await;
        let current = if status == AlgoliaImportJobStatus::Cancelled {
            repo.request_cancel(running.id)
                .await
                .expect("request cancel")
                .job
        } else {
            running
        };
        let claim = claim_for_finalization(&repo, current.id).await;
        assert_ack_conflict(
            repo.mark_engine_acknowledged(current.id).await,
            "ACK must not precede terminal commit",
        );

        let terminal_at = postgres_timestamp(Utc::now());
        let fact = matrix_terminal_fact(
            current.engine_job_id.unwrap(),
            status,
            disposition,
            terminal_at,
        );
        let outcome = repo
            .finalize_terminal_observation(
                AlgoliaImportTerminalFinalizationAuthority::ReconciliationLease(claim.lease),
                fact.clone(),
            )
            .await
            .expect("finalize terminal observation");
        let AlgoliaImportTerminalFinalizationOutcome::Applied(finalized) = outcome else {
            panic!("expected Applied terminal finalization for {key}");
        };
        assert_engine_terminal_truth(&finalized, status, disposition, terminal_at);
        assert_catalog_counts(&db.pool, customer_id, expected_catalog_rows, key).await;

        let mut stale_running_state =
            AlgoliaImportJobState::try_from(&claim.job).expect("fixture state");
        stale_running_state.status = AlgoliaImportJobStatus::CopyingDocuments;
        stale_running_state.summary.documents_imported = 1;
        let stale_poll = repo
            .record_reconciliation_observation(
                &claim.lease,
                claim.lease.claimed_at + Duration::seconds(1),
                stale_running_state,
            )
            .await
            .expect("stale running observation is fenced");
        assert!(matches!(
            stale_poll,
            AlgoliaImportReconciliationWriteOutcome::LeaseLost
        ));
        let after_poll = repo
            .get(finalized.id)
            .await
            .expect("read after stale poll")
            .expect("terminal job retained");
        assert_terminal_snapshot(&after_poll, &finalized, key);
        assert_catalog_counts(&db.pool, customer_id, expected_catalog_rows, key).await;

        let duplicate = repo
            .finalize_terminal_observation(
                AlgoliaImportTerminalFinalizationAuthority::ReconciliationLease(claim.lease),
                fact.clone(),
            )
            .await
            .expect("duplicate terminal finalizer is typed");
        let AlgoliaImportTerminalFinalizationOutcome::AlreadyApplied(replayed) = duplicate else {
            panic!("duplicate exact finalizer must be AlreadyApplied for {key}");
        };
        assert_terminal_snapshot(&replayed, &finalized, key);
        assert_catalog_counts(&db.pool, customer_id, expected_catalog_rows, key).await;

        let stale_generation = repo
            .finalize_terminal_observation(
                AlgoliaImportTerminalFinalizationAuthority::ReconciliationLease(
                    AlgoliaImportReconciliationLease {
                        lifecycle_generation: claim.lease.lifecycle_generation + 1,
                        ..claim.lease
                    },
                ),
                fact,
            )
            .await
            .expect("stale-generation duplicate terminal finalizer is typed");
        assert!(matches!(
            stale_generation,
            AlgoliaImportTerminalFinalizationOutcome::FenceLost
        ));
        let after_stale_generation = repo
            .get(finalized.id)
            .await
            .expect("read after stale-generation duplicate")
            .expect("terminal job retained");
        assert_terminal_snapshot(&after_stale_generation, &finalized, key);
        assert_catalog_counts(&db.pool, customer_id, expected_catalog_rows, key).await;
    }
}

#[tokio::test]
async fn engine_linked_interrupted_not_started_is_rejected_without_mutation() {
    let db = connect_and_migrate_required("algolia_catalog_interrupted_ns").await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 1).await;
    let vm_id = seed_active_vm(&db.pool, "us-east-1").await;
    let created = admit_create_dispatch(&repo, new_job(customer_id, "interrupted-ns")).await;
    attach_create_placement(&db.pool, &created, vm_id).await;
    let running = commit_and_advance(&repo, created, AlgoliaImportJobStatus::Promoting).await;
    let claim = claim_for_finalization(&repo, running.id).await;

    let outcome = repo
        .finalize_terminal_observation(
            AlgoliaImportTerminalFinalizationAuthority::ReconciliationLease(claim.lease),
            matrix_terminal_fact(
                running.engine_job_id.unwrap(),
                AlgoliaImportJobStatus::Interrupted,
                AlgoliaImportPublicationDisposition::NotStarted,
                postgres_timestamp(Utc::now()),
            ),
        )
        .await
        .expect("engine-linked interrupted+not_started returns a typed rejection");

    assert!(matches!(
        outcome,
        AlgoliaImportTerminalFinalizationOutcome::Rejected(_)
    ));
    let retained = repo
        .get(running.id)
        .await
        .expect("read retained job")
        .expect("job remains retained");
    assert_eq!(retained.status, AlgoliaImportJobStatus::Promoting);
    assert_eq!(
        retained.engine_ack_state,
        AlgoliaImportEngineAckState::Pending
    );
    assert_eq!(retained.terminal_at, None);
    assert_eq!(catalog_row_count(&db.pool, customer_id).await, 0);
    assert_eq!(deployment_row_count(&db.pool, customer_id).await, 0);
    assert!(has_active_reservation(&db.pool, retained.id).await);
}

#[tokio::test]
async fn local_absent_dispatch_failure_sets_not_applicable_without_ack_or_reservation() {
    let db = connect_and_migrate_required("algolia_catalog_local_absent").await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 1).await;
    let created = repo
        .create(new_job(customer_id, "local-absent-catalog"))
        .await
        .expect("create local absent-dispatch fixture");

    let failed = repo
        .record_no_dispatch_failure(
            created.id,
            AlgoliaImportErrorCode::InvalidCredentials,
            Some("sanitized local rejection"),
        )
        .await
        .expect("record local absent-dispatch failure");

    assert_eq!(failed.status, AlgoliaImportJobStatus::Failed);
    assert_eq!(
        failed.publication_disposition,
        AlgoliaImportPublicationDisposition::NotStarted
    );
    assert_eq!(
        failed.engine_ack_state,
        AlgoliaImportEngineAckState::NotApplicable
    );
    assert_eq!(
        failed.dispatch_intent_state,
        AlgoliaImportDispatchIntentState::Absent
    );
    assert_eq!(failed.engine_job_id, None);
    assert!(failed.terminal_at.is_some());
    assert!(!failed.retryable);
    assert!(!failed.resumable);
    assert_eq!(failed.worker_claimed_at, None);
    assert_eq!(failed.worker_lease_expires_at, None);
    assert!(!has_active_reservation(&db.pool, failed.id).await);
    assert_eq!(catalog_row_count(&db.pool, customer_id).await, 0);
    assert_eq!(deployment_row_count(&db.pool, customer_id).await, 0);
}

#[tokio::test]
async fn missing_ack_target_returns_conflict_without_releasing_unrelated_reservation() {
    let db = connect_and_migrate_required("algolia_catalog_missing_ack").await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 1).await;
    let unrelated = admit_create_dispatch(&repo, new_job(customer_id, "missing-ack-control")).await;

    match repo.mark_engine_acknowledged(Uuid::new_v4()).await {
        Err(RepoError::Conflict(message)) => {
            assert_eq!(message, "engine acknowledgement target is not retained")
        }
        Err(other) => panic!("missing ACK target must return a typed conflict, got {other:?}"),
        Ok(outcome) => panic!("missing ACK target unexpectedly acknowledged: {outcome:?}"),
    }

    assert!(has_active_reservation(&db.pool, unrelated.id).await);
    assert_eq!(catalog_row_count(&db.pool, customer_id).await, 0);
    assert_eq!(deployment_row_count(&db.pool, customer_id).await, 0);
}

#[tokio::test]
async fn non_terminal_and_defensive_release_controls_remain_reserved() {
    let db = connect_and_migrate_required("algolia_catalog_release_controls").await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());

    let pending_customer = Uuid::new_v4();
    insert_active_customer(&db.pool, pending_customer, 1).await;
    let pending_vm_id = seed_active_vm(&db.pool, "us-east-1").await;
    let pending_created =
        admit_create_dispatch(&repo, new_job(pending_customer, "pending-control")).await;
    attach_create_placement(&db.pool, &pending_created, pending_vm_id).await;
    let pending = commit_and_advance(
        &repo,
        pending_created,
        AlgoliaImportJobStatus::CopyingDocuments,
    )
    .await;
    assert!(has_active_reservation(&db.pool, pending.id).await);
    assert_ack_conflict(
        repo.mark_engine_acknowledged(pending.id).await,
        "pending running job must not be ACK-releasable",
    );

    let cancelling_customer = Uuid::new_v4();
    insert_active_customer(&db.pool, cancelling_customer, 1).await;
    let cancelling_vm_id = seed_active_vm(&db.pool, "us-east-1").await;
    let cancelling_created =
        admit_create_dispatch(&repo, new_job(cancelling_customer, "cancelling-control")).await;
    attach_create_placement(&db.pool, &cancelling_created, cancelling_vm_id).await;
    let cancelling_running = commit_and_advance(
        &repo,
        cancelling_created,
        AlgoliaImportJobStatus::CopyingDocuments,
    )
    .await;
    let cancelling = repo
        .request_cancel(cancelling_running.id)
        .await
        .expect("request cancel for reservation control")
        .job;
    assert_eq!(cancelling.status, AlgoliaImportJobStatus::Cancelling);
    assert!(has_active_reservation(&db.pool, cancelling.id).await);
    assert_ack_conflict(
        repo.mark_engine_acknowledged(cancelling.id).await,
        "cancelling job must not be ACK-releasable before terminal observation",
    );

    let stale_customer = Uuid::new_v4();
    insert_active_customer(&db.pool, stale_customer, 1).await;
    let stale_vm_id = seed_active_vm(&db.pool, "us-east-1").await;
    let stale_created =
        admit_create_dispatch(&repo, new_job(stale_customer, "stale-generation-control")).await;
    attach_create_placement(&db.pool, &stale_created, stale_vm_id).await;
    let stale = commit_and_advance(
        &repo,
        stale_created,
        AlgoliaImportJobStatus::CopyingDocuments,
    )
    .await;
    sqlx::query("UPDATE customers SET lifecycle_generation = lifecycle_generation + 1 WHERE id=$1")
        .bind(stale.customer_id)
        .execute(&db.pool)
        .await
        .expect("make customer generation stale without editing terminal state");
    assert!(
        has_active_reservation(&db.pool, stale.id).await,
        "stale-generation rows do not satisfy any terminal release arm"
    );
    assert_any_ack_conflict(
        repo.mark_engine_acknowledged(stale.id).await,
        "stale-generation running job must not be ACK-releasable",
    );

    for (status, disposition, ack_state) in [
        (
            AlgoliaImportJobStatus::Completed,
            AlgoliaImportPublicationDisposition::Unknown,
            AlgoliaImportEngineAckState::Acknowledged,
        ),
        (
            AlgoliaImportJobStatus::Failed,
            AlgoliaImportPublicationDisposition::Unchanged,
            AlgoliaImportEngineAckState::OutboxPending,
        ),
    ] {
        assert!(
            active_reservation_candidate(&db.pool, status, disposition, ack_state, false).await,
            "{status:?}+{disposition:?}+{ack_state:?} must stay reserved"
        );
    }
    assert!(
        active_reservation_candidate(
            &db.pool,
            AlgoliaImportJobStatus::Failed,
            AlgoliaImportPublicationDisposition::Unchanged,
            AlgoliaImportEngineAckState::Acknowledged,
            true,
        )
        .await,
        "resumable terminal-shaped rows must stay reserved"
    );
}

#[tokio::test]
async fn resumable_engine_failure_is_rejected_without_catalog_or_ack_mutation() {
    let db = connect_and_migrate_required("algolia_catalog_resumable_reject").await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 1).await;
    seed_replace_target(&db.pool, customer_id, "products").await;
    let created = admit_replace_dispatch(
        &repo,
        replace_job(customer_id, "products", "resumable-reject"),
    )
    .await;
    let observed_at = postgres_timestamp(Utc::now());
    let resumable = make_resumable_failed_job(&repo, created, observed_at).await;
    let claim = claim_for_finalization(&repo, resumable.id).await;

    let outcome = repo
        .finalize_terminal_observation(
            AlgoliaImportTerminalFinalizationAuthority::ReconciliationLease(claim.lease),
            matrix_terminal_fact(
                resumable.engine_job_id.unwrap(),
                AlgoliaImportJobStatus::Failed,
                AlgoliaImportPublicationDisposition::Unchanged,
                observed_at + Duration::seconds(1),
            ),
        )
        .await
        .expect("finalizer returns typed rejection");

    assert!(matches!(
        outcome,
        AlgoliaImportTerminalFinalizationOutcome::Rejected(_)
    ));
    let retained = repo
        .get(resumable.id)
        .await
        .expect("read retained resumable job")
        .expect("resumable job remains retained");
    assert_eq!(retained.status, AlgoliaImportJobStatus::Failed);
    assert_eq!(
        retained.engine_ack_state,
        AlgoliaImportEngineAckState::Pending
    );
    assert!(retained.resumable);
    assert_eq!(retained.terminal_at, None);
    assert_eq!(
        retained.destination_deployment_id,
        resumable.destination_deployment_id
    );
    assert_eq!(catalog_row_count(&db.pool, customer_id).await, 1);
    assert_eq!(deployment_row_count(&db.pool, customer_id).await, 1);
    assert!(has_active_reservation(&db.pool, retained.id).await);
}

#[tokio::test]
async fn terminal_finalization_replay_and_fences_are_typed_and_no_write() {
    let db = connect_and_migrate_required("algolia_catalog_replay_fence").await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 1).await;
    let vm_id = seed_active_vm(&db.pool, "us-east-1").await;
    let created = admit_create_dispatch(&repo, new_job(customer_id, "replay-fence")).await;
    attach_create_placement(&db.pool, &created, vm_id).await;
    let running = commit_and_advance(&repo, created, AlgoliaImportJobStatus::Promoting).await;
    let claim = claim_for_finalization(&repo, running.id).await;
    let terminal_at = postgres_timestamp(Utc::now());
    let fact = matrix_terminal_fact(
        running.engine_job_id.unwrap(),
        AlgoliaImportJobStatus::Completed,
        AlgoliaImportPublicationDisposition::Promoted,
        terminal_at,
    );
    let authority = AlgoliaImportTerminalFinalizationAuthority::ReconciliationLease(claim.lease);

    let first = repo
        .finalize_terminal_observation(authority.clone(), fact.clone())
        .await
        .expect("first finalization applies");
    let AlgoliaImportTerminalFinalizationOutcome::Applied(applied) = first else {
        panic!("expected first finalization to apply");
    };
    let first_updated_at = applied.updated_at;
    let first_deployment_id = applied.destination_deployment_id;

    let replay = repo
        .finalize_terminal_observation(authority.clone(), fact.clone())
        .await
        .expect("exact replay is typed");
    let AlgoliaImportTerminalFinalizationOutcome::AlreadyApplied(replayed) = replay else {
        panic!("expected exact replay to be AlreadyApplied");
    };
    assert_eq!(replayed.terminal_at, Some(terminal_at));
    assert_eq!(replayed.updated_at, first_updated_at);
    assert_eq!(replayed.destination_deployment_id, first_deployment_id);
    assert_eq!(deployment_row_count(&db.pool, customer_id).await, 1);
    assert_eq!(catalog_row_count(&db.pool, customer_id).await, 1);

    let conflicting = repo
        .finalize_terminal_observation(
            authority.clone(),
            matrix_terminal_fact(
                running.engine_job_id.unwrap(),
                AlgoliaImportJobStatus::CompletedWithWarnings,
                AlgoliaImportPublicationDisposition::Promoted,
                terminal_at,
            ),
        )
        .await
        .expect("conflicting replay is typed");
    assert!(matches!(
        conflicting,
        AlgoliaImportTerminalFinalizationOutcome::Rejected(_)
    ));

    let stale_authority = AlgoliaImportTerminalFinalizationAuthority::ReconciliationLease(
        api::repos::AlgoliaImportReconciliationLease {
            lifecycle_generation: claim.lease.lifecycle_generation + 1,
            ..claim.lease
        },
    );
    let stale = repo
        .finalize_terminal_observation(stale_authority, fact)
        .await
        .expect("stale generation is typed");
    assert!(matches!(
        stale,
        AlgoliaImportTerminalFinalizationOutcome::FenceLost
    ));
}

#[tokio::test]
async fn stale_engine_identity_and_lease_return_fence_lost_without_mutation() {
    let db = connect_and_migrate_required("algolia_catalog_stale_fences").await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 1).await;
    let vm_id = seed_active_vm(&db.pool, "us-east-1").await;
    let created = admit_create_dispatch(&repo, new_job(customer_id, "stale-fences")).await;
    let physical_uid = attach_create_placement(&db.pool, &created, vm_id).await;
    let running = commit_and_advance(&repo, created, AlgoliaImportJobStatus::Promoting).await;
    let claim = claim_for_finalization(&repo, running.id).await;
    let terminal_at = postgres_timestamp(Utc::now());
    let claimed_before_engine_fence = claim.job.clone();

    let stale_engine_identity = repo
        .finalize_terminal_observation(
            AlgoliaImportTerminalFinalizationAuthority::ReconciliationLease(claim.lease),
            matrix_terminal_fact(
                Uuid::new_v4(),
                AlgoliaImportJobStatus::Completed,
                AlgoliaImportPublicationDisposition::Promoted,
                terminal_at,
            ),
        )
        .await
        .expect("stale engine identity is typed");
    assert!(matches!(
        stale_engine_identity,
        AlgoliaImportTerminalFinalizationOutcome::FenceLost
    ));
    let retained_after_engine_fence = repo
        .get(running.id)
        .await
        .expect("read retained job")
        .expect("job remains retained");
    assert_unfinalized_create_job(&retained_after_engine_fence, vm_id, physical_uid.as_str());
    assert_fence_lost_preserved_job_row(&claimed_before_engine_fence, &retained_after_engine_fence);
    assert_eq!(catalog_row_count(&db.pool, customer_id).await, 0);
    assert_eq!(deployment_row_count(&db.pool, customer_id).await, 0);

    let claimed_before_lease_fence = retained_after_engine_fence.clone();
    let stale_lease = repo
        .finalize_terminal_observation(
            AlgoliaImportTerminalFinalizationAuthority::ReconciliationLease(
                api::repos::AlgoliaImportReconciliationLease {
                    claimed_at: claim.lease.claimed_at + Duration::seconds(1),
                    ..claim.lease
                },
            ),
            matrix_terminal_fact(
                running.engine_job_id.unwrap(),
                AlgoliaImportJobStatus::Completed,
                AlgoliaImportPublicationDisposition::Promoted,
                terminal_at,
            ),
        )
        .await
        .expect("stale lease is typed");
    assert!(matches!(
        stale_lease,
        AlgoliaImportTerminalFinalizationOutcome::FenceLost
    ));
    let retained_after_lease_fence = repo
        .get(running.id)
        .await
        .expect("read retained job")
        .expect("job remains retained");
    assert_unfinalized_create_job(&retained_after_lease_fence, vm_id, physical_uid.as_str());
    assert_fence_lost_preserved_job_row(&claimed_before_lease_fence, &retained_after_lease_fence);
    assert_eq!(catalog_row_count(&db.pool, customer_id).await, 0);
    assert_eq!(deployment_row_count(&db.pool, customer_id).await, 0);
}

#[tokio::test]
async fn create_promoted_finalization_publishes_one_active_catalog_row() {
    let db = connect_and_migrate_required("algolia_catalog_create_final").await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let tenant_repo = PgTenantRepo::new(db.pool.clone());
    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 1).await;
    let vm_id = seed_active_vm(&db.pool, "us-east-1").await;
    let created = admit_create_dispatch(&repo, new_job(customer_id, "create-promoted")).await;
    let physical_uid = attach_create_placement(&db.pool, &created, vm_id).await;
    assert_eq!(tenant_repo.count_by_customer(customer_id).await.unwrap(), 0);
    assert_eq!(
        tenant_repo
            .count_logical_index_slots(customer_id)
            .await
            .unwrap(),
        1
    );
    let running = commit_and_advance(&repo, created, AlgoliaImportJobStatus::Promoting).await;
    let claim = claim_for_finalization(&repo, running.id).await;
    let terminal_at = postgres_timestamp(Utc::now());

    let outcome = repo
        .finalize_terminal_observation(
            AlgoliaImportTerminalFinalizationAuthority::ReconciliationLease(claim.lease),
            terminal_fact(
                running.engine_job_id.unwrap(),
                AlgoliaImportJobStatus::Completed,
                AlgoliaImportPublicationDisposition::Promoted,
                terminal_at,
            ),
        )
        .await
        .expect("finalize terminal observation");
    let AlgoliaImportTerminalFinalizationOutcome::Applied(finalized) = outcome else {
        panic!("expected Applied finalization");
    };

    assert_eq!(
        finalized.engine_ack_state,
        AlgoliaImportEngineAckState::OutboxPending
    );
    assert_eq!(finalized.terminal_at, Some(terminal_at));
    assert_eq!(finalized.destination_vm_id, Some(vm_id));
    assert_eq!(
        finalized.physical_uid.as_deref(),
        Some(physical_uid.as_str())
    );
    let deployment_id = finalized
        .destination_deployment_id
        .expect("create finalization persists deployment id");
    let catalog: (Uuid, Option<Uuid>, String, String, String, String) = sqlx::query_as(
        "SELECT ct.deployment_id, ct.vm_id, ct.tier, ct.service_type,
                cd.status, cd.provider_vm_id
         FROM customer_tenants ct
         JOIN customer_deployments cd ON cd.id = ct.deployment_id
         WHERE ct.customer_id = $1 AND ct.tenant_id = 'products'",
    )
    .bind(customer_id)
    .fetch_one(&db.pool)
    .await
    .expect("read published catalog row");
    assert_eq!(catalog.0, deployment_id);
    assert_eq!(catalog.1, Some(vm_id));
    assert_eq!(catalog.2, "active");
    assert_eq!(catalog.3, "flapjack");
    assert_eq!(catalog.4, "running");
    assert_eq!(catalog.5, vm_id.to_string());
    assert_published_catalog_routes(&db.pool, customer_id, deployment_id, vm_id, &physical_uid)
        .await;
    assert_eq!(tenant_repo.count_by_customer(customer_id).await.unwrap(), 1);
    assert_eq!(
        tenant_repo
            .count_logical_index_slots(customer_id)
            .await
            .unwrap(),
        1
    );

    let acknowledged = repo
        .mark_engine_acknowledged(finalized.id)
        .await
        .expect("acknowledge published import");
    assert_eq!(
        acknowledged.engine_ack_state,
        AlgoliaImportEngineAckState::Acknowledged
    );
    assert_eq!(tenant_repo.count_by_customer(customer_id).await.unwrap(), 1);
    assert_eq!(
        tenant_repo
            .count_logical_index_slots(customer_id)
            .await
            .unwrap(),
        1
    );
}

#[tokio::test]
async fn active_create_reservation_blocks_ordinary_index_admission_at_the_limit() {
    let db = connect_and_migrate_required("algolia_catalog_ordinary_quota").await;
    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 1).await;
    sqlx::query("UPDATE customers SET email_verified_at = NOW() WHERE id = $1")
        .bind(customer_id)
        .execute(&db.pool)
        .await
        .expect("verify quota-test customer");

    PgAlgoliaImportJobRepo::new(db.pool.clone())
        .create(new_job(customer_id, "ordinary-quota-blocker"))
        .await
        .expect("reserve the only logical index slot");

    let limits = FreeTierLimits {
        max_indexes: 1,
        ..FreeTierLimits::default()
    };
    let mut state = crate::common::TestStateBuilder::new()
        .with_pool(db.pool.clone())
        .with_free_tier_limits(limits)
        .build();
    state.customer_repo = Arc::new(PgCustomerRepo::new(db.pool.clone()));
    state.tenant_repo = Arc::new(PgTenantRepo::new(db.pool.clone()));
    let app = build_router(state);
    let jwt = crate::common::create_test_jwt(customer_id);

    let response = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/indexes")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(
                    json!({"name": "ordinary-index", "region": "us-east-1"}).to_string(),
                ))
                .expect("build ordinary index request"),
        )
        .await
        .expect("ordinary index route response");
    let (status, body) = crate::common::indexes_route_test_support::response_json(response).await;

    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(
        body,
        json!({
            "error": "quota_exceeded",
            "limit": "max_indexes",
            "upgrade_url": "/billing/upgrade"
        })
    );
}

#[tokio::test]
async fn create_import_quota_handoff_counts_one_slot_before_and_after_ack() {
    let db = connect_and_migrate_required("algolia_catalog_import_quota").await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let tenant_repo = PgTenantRepo::new(db.pool.clone());
    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 1).await;
    seed_replace_target(&db.pool, customer_id, "existing-products").await;
    sqlx::query(
        "UPDATE customer_tenants
         SET resource_quota = '{\"max_indexes\": 2}'::jsonb
         WHERE customer_id = $1",
    )
    .bind(customer_id)
    .execute(&db.pool)
    .await
    .expect("set two-index quota");

    let vm_id = seed_active_vm(&db.pool, "us-east-1").await;
    let created = admit_create_dispatch(
        &repo,
        new_create_job(customer_id, "imported-products", "quota-handoff"),
    )
    .await;
    let physical_uid = attach_create_placement(&db.pool, &created, vm_id).await;
    assert_eq!(tenant_repo.count_by_customer(customer_id).await.unwrap(), 1);
    assert_eq!(
        tenant_repo
            .count_logical_index_slots(customer_id)
            .await
            .unwrap(),
        2
    );

    assert_quota_refusal(
        repo.create(new_create_job(
            customer_id,
            "third-products",
            "quota-before-finalization",
        ))
        .await,
    );
    repo.create_replace(replace_job(
        customer_id,
        "existing-products",
        "zero-delta-replacement",
    ))
    .await
    .expect("replacement has zero index-count delta");

    let running = commit_and_advance(&repo, created, AlgoliaImportJobStatus::Promoting).await;
    let claim = claim_for_finalization(&repo, running.id).await;
    let outcome = repo
        .finalize_terminal_observation(
            AlgoliaImportTerminalFinalizationAuthority::ReconciliationLease(claim.lease),
            terminal_fact(
                running.engine_job_id.unwrap(),
                AlgoliaImportJobStatus::Completed,
                AlgoliaImportPublicationDisposition::Promoted,
                postgres_timestamp(Utc::now()),
            ),
        )
        .await
        .expect("finalize quota handoff");
    let AlgoliaImportTerminalFinalizationOutcome::Applied(finalized) = outcome else {
        panic!("expected applied quota handoff finalization");
    };
    assert_eq!(
        finalized.physical_uid.as_deref(),
        Some(physical_uid.as_str())
    );
    assert_eq!(tenant_repo.count_by_customer(customer_id).await.unwrap(), 2);
    assert_eq!(
        tenant_repo
            .count_logical_index_slots(customer_id)
            .await
            .unwrap(),
        2
    );
    assert_quota_refusal(
        repo.create(new_create_job(
            customer_id,
            "third-products",
            "quota-before-ack",
        ))
        .await,
    );

    repo.mark_engine_acknowledged(finalized.id)
        .await
        .expect("acknowledge quota handoff");
    assert_eq!(tenant_repo.count_by_customer(customer_id).await.unwrap(), 2);
    assert_eq!(
        tenant_repo
            .count_logical_index_slots(customer_id)
            .await
            .unwrap(),
        2
    );
    assert_quota_refusal(
        repo.create(new_create_job(
            customer_id,
            "third-products",
            "quota-after-ack",
        ))
        .await,
    );
}

fn assert_quota_refusal(result: Result<AlgoliaImportJob, AlgoliaImportJobAdmissionError>) {
    assert!(matches!(
        result,
        Err(AlgoliaImportJobAdmissionError::Refused(
            AlgoliaImportErrorCode::QuotaExceeded
        ))
    ));
}

#[tokio::test]
async fn cancelled_finalization_leaves_create_catalog_unpublished() {
    let db = connect_and_migrate_required("algolia_catalog_cancel_final").await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 1).await;
    let vm_id = seed_active_vm(&db.pool, "us-east-1").await;
    let created = admit_create_dispatch(&repo, new_job(customer_id, "create-cancelled")).await;
    attach_create_placement(&db.pool, &created, vm_id).await;
    let running =
        commit_and_advance(&repo, created, AlgoliaImportJobStatus::CopyingDocuments).await;
    let cancelling = repo
        .request_cancel(running.id)
        .await
        .expect("request cancel")
        .job;
    let claim = claim_for_finalization(&repo, cancelling.id).await;
    let terminal_at = postgres_timestamp(Utc::now());

    let outcome = repo
        .finalize_terminal_observation(
            AlgoliaImportTerminalFinalizationAuthority::ReconciliationLease(claim.lease),
            terminal_fact(
                cancelling.engine_job_id.unwrap(),
                AlgoliaImportJobStatus::Cancelled,
                AlgoliaImportPublicationDisposition::Unchanged,
                terminal_at,
            ),
        )
        .await
        .expect("finalize cancel observation");
    let AlgoliaImportTerminalFinalizationOutcome::Applied(finalized) = outcome else {
        panic!("expected Applied finalization");
    };

    assert_eq!(finalized.destination_deployment_id, None);
    assert_eq!(finalized.terminal_at, Some(terminal_at));
    let tenant_count: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM customer_tenants WHERE customer_id = $1")
            .bind(customer_id)
            .fetch_one(&db.pool)
            .await
            .expect("count tenant rows");
    let deployment_count: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM customer_deployments WHERE customer_id = $1")
            .bind(customer_id)
            .fetch_one(&db.pool)
            .await
            .expect("count deployment rows");
    assert_eq!(tenant_count, 0);
    assert_eq!(deployment_count, 0);
    assert!(tenant_map_entries(&db.pool).await.is_empty());
}

fn assert_unfinalized_create_job(job: &AlgoliaImportJob, vm_id: Uuid, physical_uid: &str) {
    assert_eq!(job.status, AlgoliaImportJobStatus::Promoting);
    // A running create job has never published, so its disposition stays
    // not_started until a terminal fact promotes/cancels/fails it. A lost fence
    // performs no write, so the retained disposition remains not_started.
    assert_eq!(
        job.publication_disposition,
        AlgoliaImportPublicationDisposition::NotStarted
    );
    assert_eq!(job.engine_ack_state, AlgoliaImportEngineAckState::Pending);
    assert_eq!(job.destination_vm_id, Some(vm_id));
    assert_eq!(job.physical_uid.as_deref(), Some(physical_uid));
    assert_eq!(job.destination_deployment_id, None);
    assert_eq!(job.terminal_at, None);
}

fn assert_fence_lost_preserved_job_row(before: &AlgoliaImportJob, after: &AlgoliaImportJob) {
    assert_eq!(after.worker_claimed_at, before.worker_claimed_at);
    assert_eq!(
        after.worker_lease_expires_at,
        before.worker_lease_expires_at
    );
    assert_eq!(after.updated_at, before.updated_at);
}

#[tokio::test]
async fn replacement_promoted_finalization_preserves_one_active_catalog_row() {
    let db = connect_and_migrate_required("algolia_catalog_replace_success").await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let tenant_repo = PgTenantRepo::new(db.pool.clone());
    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 1).await;
    seed_replace_target(&db.pool, customer_id, "products").await;
    let (deployment_id, vm_id, created_at): (Uuid, Uuid, DateTime<Utc>) = sqlx::query_as(
        "SELECT deployment_id, vm_id, created_at
         FROM customer_tenants
         WHERE customer_id = $1 AND tenant_id = 'products'",
    )
    .bind(customer_id)
    .fetch_one(&db.pool)
    .await
    .expect("read replacement target identity");
    let physical_uid = api::services::flapjack_node::flapjack_index_uid(customer_id, "products");

    let created = admit_replace_dispatch(
        &repo,
        replace_job(customer_id, "products", "replace-success"),
    )
    .await;
    assert_eq!(tenant_repo.count_by_customer(customer_id).await.unwrap(), 1);
    assert_eq!(
        tenant_repo
            .count_logical_index_slots(customer_id)
            .await
            .unwrap(),
        1
    );
    let running = commit_and_advance(&repo, created, AlgoliaImportJobStatus::Promoting).await;
    let claim = claim_for_finalization(&repo, running.id).await;
    let outcome = repo
        .finalize_terminal_observation(
            AlgoliaImportTerminalFinalizationAuthority::ReconciliationLease(claim.lease),
            terminal_fact(
                running.engine_job_id.unwrap(),
                AlgoliaImportJobStatus::Completed,
                AlgoliaImportPublicationDisposition::Promoted,
                postgres_timestamp(Utc::now()),
            ),
        )
        .await
        .expect("finalize replacement");
    let AlgoliaImportTerminalFinalizationOutcome::Applied(finalized) = outcome else {
        panic!("expected applied replacement finalization");
    };

    assert_eq!(finalized.destination_deployment_id, Some(deployment_id));
    assert_eq!(finalized.destination_vm_id, Some(vm_id));
    assert_eq!(
        finalized.physical_uid.as_deref(),
        Some(physical_uid.as_str())
    );
    assert_published_catalog_routes(&db.pool, customer_id, deployment_id, vm_id, &physical_uid)
        .await;
    let retained_created_at: DateTime<Utc> = sqlx::query_scalar(
        "SELECT created_at
         FROM customer_tenants
         WHERE customer_id = $1 AND tenant_id = 'products'",
    )
    .bind(customer_id)
    .fetch_one(&db.pool)
    .await
    .expect("read retained replacement catalog timestamp");
    assert_eq!(retained_created_at, created_at);
    assert_eq!(tenant_repo.count_by_customer(customer_id).await.unwrap(), 1);
    assert_eq!(
        tenant_repo
            .count_logical_index_slots(customer_id)
            .await
            .unwrap(),
        1
    );
    assert_eq!(deployment_row_count(&db.pool, customer_id).await, 1);
}

#[tokio::test]
async fn replacement_promoted_finalization_requires_current_routing_identity() {
    let db = connect_and_migrate_required("algolia_catalog_replace_final").await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 1).await;
    seed_replace_target(&db.pool, customer_id, "products").await;
    let created = admit_replace_dispatch(
        &repo,
        replace_job(customer_id, "products", "replace-promoted"),
    )
    .await;
    let running = commit_and_advance(&repo, created, AlgoliaImportJobStatus::Promoting).await;
    let claim = claim_for_finalization(&repo, running.id).await;
    sqlx::query("UPDATE customer_tenants SET vm_id = NULL WHERE customer_id = $1")
        .bind(customer_id)
        .execute(&db.pool)
        .await
        .expect("introduce routing drift");

    let outcome = repo
        .finalize_terminal_observation(
            AlgoliaImportTerminalFinalizationAuthority::ReconciliationLease(claim.lease),
            terminal_fact(
                running.engine_job_id.unwrap(),
                AlgoliaImportJobStatus::Completed,
                AlgoliaImportPublicationDisposition::Promoted,
                postgres_timestamp(Utc::now()),
            ),
        )
        .await
        .expect("finalizer returns typed rejection");

    assert!(matches!(
        outcome,
        AlgoliaImportTerminalFinalizationOutcome::Rejected(_)
    ));
    let retained = repo
        .get(running.id)
        .await
        .expect("read retained job")
        .expect("job remains retained");
    assert_eq!(retained.status, AlgoliaImportJobStatus::Promoting);
    assert_eq!(
        retained.engine_ack_state,
        AlgoliaImportEngineAckState::Pending
    );
    assert_eq!(retained.terminal_at, None);
}

/// Catalog lifecycle writes against a target are excluded for exactly as long as
/// a terminal import job still holds the canonical reservation. Terminal public /
/// catalog truth is committed first and the reservation only releases once the
/// confirmed engine ACK flips the row to `acknowledged`; the lifecycle guard opens
/// off the same `active_reservation_predicate`, so it must refuse before the ACK
/// and become eligible only after it. Everything is driven through the production
/// finalize + ACK owners, never SQL-seeded terminal state.
#[tokio::test]
async fn catalog_lifecycle_write_is_excluded_until_terminal_ack_releases_reservation() {
    let live_binding = CatalogLiveBinding::begin().await;
    let db = connect_and_migrate_required("algolia_catalog_lifecycle_exclusion").await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 1).await;
    let vm_id = seed_active_vm(&db.pool, "us-east-1").await;
    let created = admit_create_dispatch(&repo, new_job(customer_id, "lifecycle-exclusion")).await;
    attach_create_placement(&db.pool, &created, vm_id).await;
    let running = commit_and_advance(&repo, created, AlgoliaImportJobStatus::Promoting).await;
    let claim = claim_for_finalization(&repo, running.id).await;
    let terminal_at = postgres_timestamp(Utc::now());

    let outcome = repo
        .finalize_terminal_observation(
            AlgoliaImportTerminalFinalizationAuthority::ReconciliationLease(claim.lease),
            terminal_fact(
                running.engine_job_id.unwrap(),
                AlgoliaImportJobStatus::Completed,
                AlgoliaImportPublicationDisposition::Promoted,
                terminal_at,
            ),
        )
        .await
        .expect("finalize terminal observation");
    let AlgoliaImportTerminalFinalizationOutcome::Applied(finalized) = outcome else {
        panic!("expected Applied finalization");
    };
    let deployment_id = finalized
        .destination_deployment_id
        .expect("create finalization persists the published deployment id");

    // Terminal public/catalog truth is durable, but the engine ACK is still
    // outbox_pending, so the reservation is still held.
    assert_eq!(
        finalized.engine_ack_state,
        AlgoliaImportEngineAckState::OutboxPending
    );
    assert!(has_active_reservation(&db.pool, finalized.id).await);

    // A catalog lifecycle write against the same target must be excluded while the
    // terminal reservation is unacknowledged — the guard opens off the canonical
    // predicate and refuses with a destination conflict.
    match repo
        .begin_lifecycle_target_guard(customer_id, "products")
        .await
    {
        Err(RepoError::Conflict(message)) => assert_eq!(message, "destination_conflict"),
        Ok(_) => panic!("lifecycle write must be excluded before ACK release"),
        Err(other) => panic!("expected destination_conflict refusal, got {other:?}"),
    }

    // Confirming the engine ACK flips the row to acknowledged and releases the
    // canonical reservation.
    let ack = repo
        .mark_engine_acknowledged(finalized.id)
        .await
        .expect("acknowledge terminal engine outbox");
    assert_eq!(
        ack.engine_ack_state,
        AlgoliaImportEngineAckState::Acknowledged
    );
    assert!(!has_active_reservation(&db.pool, finalized.id).await);

    // The lifecycle write is now eligible: the guard opens against the released
    // target, validates the published identity, and commits a real mutation
    // boundary.
    let guard = repo
        .begin_lifecycle_target_guard(customer_id, "products")
        .await
        .expect("lifecycle write becomes eligible after ACK release");
    let identity = CatalogLifecycleTargetIdentity {
        deployment_id,
        vm_id: Some(vm_id),
        tier: "active".to_string(),
        cold_snapshot_id: None,
        service_type: "flapjack".to_string(),
    };
    repo.commit_lifecycle_target_guard(guard, Some(&identity))
        .await
        .expect("committed lifecycle guard against released target");
    if let Some(binding) = live_binding {
        binding.finish().await;
    }
}

/// Finalizes one create job to an engine-linked `completed+promoted` terminal
/// through the production reconciliation-lease path, persisting the engine's
/// `terminalAt` verbatim so retention-boundary tests never seed terminal SQL.
async fn finalize_engine_completed_terminal(
    repo: &PgAlgoliaImportJobRepo,
    pool: &PgPool,
    customer_id: Uuid,
    key: &str,
    terminal_at: DateTime<Utc>,
) -> AlgoliaImportJob {
    let vm_id = seed_active_vm(pool, "us-east-1").await;
    let created = admit_create_dispatch(repo, new_job(customer_id, key)).await;
    attach_create_placement(pool, &created, vm_id).await;
    let running = commit_and_advance(repo, created, AlgoliaImportJobStatus::Promoting).await;
    let claim = claim_for_finalization(repo, running.id).await;
    let outcome = repo
        .finalize_terminal_observation(
            AlgoliaImportTerminalFinalizationAuthority::ReconciliationLease(claim.lease),
            terminal_fact(
                running.engine_job_id.unwrap(),
                AlgoliaImportJobStatus::Completed,
                AlgoliaImportPublicationDisposition::Promoted,
                terminal_at,
            ),
        )
        .await
        .expect("finalize engine completed terminal");
    let AlgoliaImportTerminalFinalizationOutcome::Applied(job) = outcome else {
        panic!("expected Applied finalization for {key}");
    };
    job
}

/// Retention GC only removes production-finalized rows once their terminal_at
/// crosses the exact 90-day boundary, and only for released ACK classes.
/// Driving every row through `finalize_terminal_observation` /
/// `record_no_dispatch_failure` (no SQL-seeded terminal state) also proves the
/// `gc_retained_terminal_history` statement executes end to end.
#[tokio::test]
async fn gc_retains_before_boundary_and_deletes_released_history_at_ninety_days() {
    let db = connect_and_migrate_required("algolia_catalog_gc").await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());

    // Fixed engine terminal_at anchor so the 90-day math is deterministic.
    let anchor = postgres_timestamp(Utc::now() - Duration::days(200));

    // acknowledged engine terminal — eligible once released past 90 days.
    let acked_customer = Uuid::new_v4();
    insert_active_customer(&db.pool, acked_customer, 1).await;
    let acked =
        finalize_engine_completed_terminal(&repo, &db.pool, acked_customer, "gc-acked", anchor)
            .await;
    repo.mark_engine_acknowledged(acked.id)
        .await
        .expect("acknowledge engine terminal before GC");

    // outbox_pending engine terminal (finalized, never acknowledged) — retained.
    let pending_customer = Uuid::new_v4();
    insert_active_customer(&db.pool, pending_customer, 1).await;
    let pending =
        finalize_engine_completed_terminal(&repo, &db.pool, pending_customer, "gc-pending", anchor)
            .await;

    // resumable failed job (never terminal, no terminal_at) — retained.
    let resumable_customer = Uuid::new_v4();
    insert_active_customer(&db.pool, resumable_customer, 1).await;
    seed_replace_target(&db.pool, resumable_customer, "products").await;
    let resumable_created = admit_replace_dispatch(
        &repo,
        replace_job(resumable_customer, "products", "gc-resumable"),
    )
    .await;
    let resumable = make_resumable_failed_job(&repo, resumable_created, anchor).await;

    // not_applicable local absent-dispatch failure — released, terminal_at = decision time.
    let na_customer = Uuid::new_v4();
    insert_active_customer(&db.pool, na_customer, 1).await;
    let na_created = repo
        .create(new_job(na_customer, "gc-not-applicable"))
        .await
        .expect("create local absent-dispatch fixture");
    let not_applicable = repo
        .record_no_dispatch_failure(
            na_created.id,
            AlgoliaImportErrorCode::InvalidCredentials,
            Some("sanitized local rejection"),
        )
        .await
        .expect("record local absent-dispatch failure");
    let na_terminal_at = not_applicable
        .terminal_at
        .expect("local absent-dispatch failure sets terminal_at");

    // One second before the boundary: nothing anchored is eligible yet.
    let just_before = anchor + Duration::days(90) - Duration::seconds(1);
    let deleted = repo
        .gc_retained_terminal_history(just_before, 100)
        .await
        .expect("gc executes at 89d23h59m59s boundary");
    assert!(
        !deleted.contains(&acked.id),
        "acknowledged terminal retained at 89d23h59m59s"
    );

    // Exactly 90 days after the anchor: the acknowledged terminal is eligible,
    // while outbox_pending and resumable=true controls remain retained.
    let at_boundary = anchor + Duration::days(90);
    let deleted = repo
        .gc_retained_terminal_history(at_boundary, 100)
        .await
        .expect("gc executes at exact 90-day boundary");
    assert!(
        deleted.contains(&acked.id),
        "acknowledged terminal deleted at 90 days"
    );
    assert!(
        !deleted.contains(&pending.id),
        "outbox_pending terminal retained"
    );
    assert!(
        !deleted.contains(&resumable.id),
        "resumable=true job retained"
    );
    assert!(
        !deleted.contains(&not_applicable.id),
        "not_applicable retained until its own decision time crosses 90 days"
    );
    assert!(
        repo.get(acked.id)
            .await
            .expect("read acked job after GC")
            .is_none(),
        "acknowledged row physically deleted"
    );
    assert!(
        repo.get(pending.id)
            .await
            .expect("read pending job after GC")
            .is_some(),
        "outbox_pending row survives GC"
    );

    // not_applicable becomes eligible only 90 days after its own terminal_at.
    let na_boundary = na_terminal_at + Duration::days(90);
    let deleted = repo
        .gc_retained_terminal_history(na_boundary, 100)
        .await
        .expect("gc executes at not_applicable boundary");
    assert!(
        deleted.contains(&not_applicable.id),
        "not_applicable deleted at its own 90-day boundary"
    );
    assert!(
        repo.get(resumable.id)
            .await
            .expect("read resumable job after GC")
            .is_some(),
        "resumable=true job still retained after not_applicable GC"
    );
}

/// Crash-boundary recovery contract. A worker can die at any point around dispatch,
/// validation, terminal commit, and ACK. At every boundary the retained DB state
/// must be recoverable through the production owners — with no partial write, no
/// lost reservation, and no premature release — and a subsequent claim / finalize /
/// ACK must resume from exactly that retained state. Every row is produced through
/// the production repo path (`record_no_dispatch_failure`, `claim_reconciliation_jobs`,
/// `finalize_terminal_observation`, `mark_engine_acknowledged`); no terminal state is
/// SQL-seeded. Service-level ACK send-failure (503) retry across a full worker
/// restart is proven end-to-end by the crate-internal `reconcile_once` restart test
/// `postgres_reconciliation_acknowledges_before_and_after_worker_restart`.
#[tokio::test]
async fn crash_boundaries_recover_from_retained_db_state() {
    let db = connect_and_migrate_required("algolia_catalog_crash_boundaries").await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());

    // Boundary 1: invalid credentials rejected before any dispatch intent. The local
    // no-dispatch failure seals a not_applicable terminal that holds no reservation
    // and is never reclaimable — recovery correctly ignores it (nothing to resume).
    let creds_customer = Uuid::new_v4();
    insert_active_customer(&db.pool, creds_customer, 1).await;
    let creds_created = repo
        .create(new_job(creds_customer, "crash-invalid-credentials"))
        .await
        .expect("create local absent-dispatch fixture");
    let sealed = repo
        .record_no_dispatch_failure(
            creds_created.id,
            AlgoliaImportErrorCode::InvalidCredentials,
            Some("sanitized invalid credentials"),
        )
        .await
        .expect("seal invalid-credentials no-dispatch failure");
    assert_eq!(sealed.status, AlgoliaImportJobStatus::Failed);
    assert_eq!(
        sealed.engine_ack_state,
        AlgoliaImportEngineAckState::NotApplicable
    );
    assert!(sealed.terminal_at.is_some());
    assert!(!has_active_reservation(&db.pool, sealed.id).await);
    assert!(
        !reconciliation_claim_ids(&repo).await.contains(&sealed.id),
        "not_applicable terminal is not reclaimable by recovery"
    );

    // Boundary 2: crash during source validation. A committed-intent job advanced
    // only to ValidatingSource retains a reserved, reclaimable running row with no
    // terminal truth; recovery re-claims it and finalizes from the engine terminal
    // (a validation crash surfaces as a Failed terminal, the only terminal reachable
    // from ValidatingSource).
    let validating_customer = Uuid::new_v4();
    insert_active_customer(&db.pool, validating_customer, 1).await;
    let validating_vm = seed_active_vm(&db.pool, "us-east-1").await;
    let validating_created =
        admit_create_dispatch(&repo, new_job(validating_customer, "crash-validating")).await;
    attach_create_placement(&db.pool, &validating_created, validating_vm).await;
    let validating = commit_and_advance(
        &repo,
        validating_created,
        AlgoliaImportJobStatus::ValidatingSource,
    )
    .await;
    assert_eq!(validating.terminal_at, None);
    assert_eq!(
        validating.engine_ack_state,
        AlgoliaImportEngineAckState::Pending
    );
    assert!(has_active_reservation(&db.pool, validating.id).await);
    let validating_claim = claim_for_finalization(&repo, validating.id).await;
    let validating_terminal_at = postgres_timestamp(Utc::now());
    let AlgoliaImportTerminalFinalizationOutcome::Applied(validating_final) = repo
        .finalize_terminal_observation(
            AlgoliaImportTerminalFinalizationAuthority::ReconciliationLease(validating_claim.lease),
            terminal_fact(
                validating.engine_job_id.unwrap(),
                AlgoliaImportJobStatus::Failed,
                AlgoliaImportPublicationDisposition::Unchanged,
                validating_terminal_at,
            ),
        )
        .await
        .expect("recovery finalizes crashed-in-validation job")
    else {
        panic!("expected recovery to finalize the validation-crash job");
    };
    assert_eq!(validating_final.terminal_at, Some(validating_terminal_at));
    assert_eq!(
        validating_final.engine_ack_state,
        AlgoliaImportEngineAckState::OutboxPending
    );

    // Boundary 3: crash after committed dispatch intent but before terminal
    // observation. The job is further along (Promoting) yet still has no terminal_at;
    // recovery re-claims and finalizes it identically.
    let promoting_customer = Uuid::new_v4();
    insert_active_customer(&db.pool, promoting_customer, 1).await;
    let promoting_vm = seed_active_vm(&db.pool, "us-east-1").await;
    let promoting_created =
        admit_create_dispatch(&repo, new_job(promoting_customer, "crash-committed-intent")).await;
    let promoting_uid = attach_create_placement(&db.pool, &promoting_created, promoting_vm).await;
    let promoting =
        commit_and_advance(&repo, promoting_created, AlgoliaImportJobStatus::Promoting).await;
    assert_eq!(promoting.terminal_at, None);
    assert!(has_active_reservation(&db.pool, promoting.id).await);
    let promoting_claim = claim_for_finalization(&repo, promoting.id).await;

    // Boundary 4: transaction failure before the terminal update. Destination routing
    // drifts after the claim, so the finalize does real in-transaction work (locks the
    // VM) then rejects and rolls back: no terminal is persisted, the reservation is
    // retained, and no catalog row is published. Repairing the drift and re-finalizing
    // on the same lease recovers cleanly.
    sqlx::query("UPDATE algolia_import_jobs SET routing_identity = 'crash-drift' WHERE id = $1")
        .bind(promoting.id)
        .execute(&db.pool)
        .await
        .expect("introduce destination routing drift");
    let promoting_terminal_at = postgres_timestamp(Utc::now());
    let rejected = repo
        .finalize_terminal_observation(
            AlgoliaImportTerminalFinalizationAuthority::ReconciliationLease(promoting_claim.lease),
            terminal_fact(
                promoting.engine_job_id.unwrap(),
                AlgoliaImportJobStatus::Completed,
                AlgoliaImportPublicationDisposition::Promoted,
                promoting_terminal_at,
            ),
        )
        .await
        .expect("drifted finalize returns a typed rejection");
    assert!(matches!(
        rejected,
        AlgoliaImportTerminalFinalizationOutcome::Rejected(_)
    ));
    let after_rollback = repo
        .get(promoting.id)
        .await
        .expect("read job after rolled-back finalize")
        .expect("job retained after rollback");
    assert_eq!(
        after_rollback.terminal_at, None,
        "rolled-back finalize persists no terminal truth"
    );
    assert_eq!(
        after_rollback.engine_ack_state,
        AlgoliaImportEngineAckState::Pending
    );
    assert!(has_active_reservation(&db.pool, promoting.id).await);
    assert_eq!(catalog_row_count(&db.pool, promoting_customer).await, 0);
    assert_eq!(deployment_row_count(&db.pool, promoting_customer).await, 0);

    sqlx::query("UPDATE algolia_import_jobs SET routing_identity = $2 WHERE id = $1")
        .bind(promoting.id)
        .bind(&promoting_uid)
        .execute(&db.pool)
        .await
        .expect("repair destination routing drift");
    let AlgoliaImportTerminalFinalizationOutcome::Applied(promoting_final) = repo
        .finalize_terminal_observation(
            AlgoliaImportTerminalFinalizationAuthority::ReconciliationLease(promoting_claim.lease),
            terminal_fact(
                promoting.engine_job_id.unwrap(),
                AlgoliaImportJobStatus::Completed,
                AlgoliaImportPublicationDisposition::Promoted,
                promoting_terminal_at,
            ),
        )
        .await
        .expect("recovery finalizes after routing repair")
    else {
        panic!("expected recovery to finalize after routing repair");
    };
    assert_eq!(promoting_final.terminal_at, Some(promoting_terminal_at));
    assert_eq!(catalog_row_count(&db.pool, promoting_customer).await, 1);
    assert_eq!(deployment_row_count(&db.pool, promoting_customer).await, 1);

    // Boundary 5: transaction failure (crash) after the terminal update commits but
    // before the engine ACK is delivered. Terminal public/catalog truth is durable
    // and the reservation is still held; recovery delivers the retained ACK, which is
    // the only step that releases the reservation.
    assert_eq!(
        promoting_final.engine_ack_state,
        AlgoliaImportEngineAckState::OutboxPending
    );
    assert!(
        has_active_reservation(&db.pool, promoting_final.id).await,
        "durable terminal stays reserved until ACK is delivered"
    );
    let acknowledged = repo
        .mark_engine_acknowledged(promoting_final.id)
        .await
        .expect("recovery delivers retained terminal ACK");
    assert_eq!(
        acknowledged.engine_ack_state,
        AlgoliaImportEngineAckState::Acknowledged
    );
    let after_ack = repo
        .get(promoting_final.id)
        .await
        .expect("read job after recovered ACK")
        .expect("acknowledged job retained");
    assert_eq!(
        after_ack.terminal_at,
        Some(promoting_terminal_at),
        "recovered ACK preserves durable terminal_at"
    );
    assert!(
        !has_active_reservation(&db.pool, promoting_final.id).await,
        "reservation releases only after the recovered ACK"
    );
    assert_eq!(
        catalog_row_count(&db.pool, promoting_customer).await,
        1,
        "recovered ACK does not disturb durable catalog truth"
    );
}

#[path = "algolia_import_catalog_soft_delete_boundaries.rs"]
mod soft_delete_boundaries;
