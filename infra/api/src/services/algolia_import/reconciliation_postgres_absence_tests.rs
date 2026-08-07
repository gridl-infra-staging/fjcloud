use super::*;

fn engine_disowns_job_response() -> Result<FlapjackHttpResponse, ProxyError> {
    Ok(FlapjackHttpResponse {
        status: 404,
        body: json!({"code": "migration_job_not_found"}).to_string(),
        request_api_key: String::new(),
    })
}

fn engine_transport_failure() -> Result<FlapjackHttpResponse, ProxyError> {
    Err(ProxyError::Unreachable(
        "engine transport unavailable".to_string(),
    ))
}

async fn engine_unavailable_since(pool: &PgPool, job_id: Uuid) -> Option<DateTime<Utc>> {
    sqlx::query_scalar("SELECT engine_unavailable_since FROM algolia_import_jobs WHERE id = $1")
        .bind(job_id)
        .fetch_one(pool)
        .await
        .expect("read persisted engine absence mark")
}

async fn backdate_engine_absence_mark(pool: &PgPool, job_id: Uuid, by: Duration) {
    let opened = engine_unavailable_since(pool, job_id)
        .await
        .expect("absence mark must exist before it is backdated");
    sqlx::query("UPDATE algolia_import_jobs SET engine_unavailable_since = $2 WHERE id = $1")
        .bind(job_id)
        .bind(opened - by)
        .execute(pool)
        .await
        .expect("backdate engine absence mark");
}

fn absence_runtime(pool: &PgPool) -> AlgoliaImportReconciliationRuntime<PgAlgoliaImportJobRepo> {
    AlgoliaImportReconciliationRuntime::new(
        Arc::new(PgAlgoliaImportJobRepo::new(pool.clone())),
        Arc::new(PgVmInventoryRepo::new(pool.clone())),
        Arc::new(MockAlertService::new()),
        config(),
    )
}

#[tokio::test]
async fn postgres_reconciliation_starts_absence_grace_only_after_authenticated_404() {
    let Some(db) = connect_and_migrate("algolia_absence_requires_404").await else {
        return;
    };
    let vm_id = seed_active_vm(&db.pool).await;
    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 1).await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let job = prepare_running_create_job(
        &repo,
        &db.pool,
        customer_id,
        vm_id,
        Uuid::new_v4(),
        "absence-requires-404",
    )
    .await;
    let observed_at = postgres_timestamp(Utc::now());
    let runtime = absence_runtime(&db.pool);
    let (service, _) = service_harness(vec![
        engine_transport_failure(),
        engine_disowns_job_response(),
    ])
    .await;

    service
        .reconcile_once(&runtime, observed_at)
        .await
        .expect("persist transport failure");
    assert_eq!(engine_unavailable_since(&db.pool, job.id).await, None);

    service
        .reconcile_once(&runtime, observed_at + Duration::seconds(1))
        .await
        .expect("persist authenticated absence");
    assert_eq!(
        engine_unavailable_since(&db.pool, job.id).await,
        Some(observed_at + Duration::seconds(1))
    );
    assert!(has_active_reservation(&db.pool, job.id).await);
}

/// The persisted absence mark must close as soon as the engine answers with a
/// real observation. If it survived a recovery, a single later 404 on a job
/// that had once been unavailable would read as an expired grace and terminate
/// a healthy running import.
#[tokio::test]
async fn postgres_reconciliation_clears_the_engine_absence_mark_when_the_engine_answers_again() {
    let Some(db) = connect_and_migrate("algolia_absence_mark_clears").await else {
        return;
    };
    let vm_id = seed_active_vm(&db.pool).await;
    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 1).await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let engine_job_id = Uuid::new_v4();
    let job = prepare_running_create_job(
        &repo,
        &db.pool,
        customer_id,
        vm_id,
        engine_job_id,
        "absence-mark-clears",
    )
    .await;
    let observed_at = postgres_timestamp(Utc::now());
    let runtime = absence_runtime(&db.pool);
    let (service, _) = service_harness(vec![
        engine_disowns_job_response(),
        running_response(engine_job_id),
    ])
    .await;

    service
        .reconcile_once(&runtime, observed_at)
        .await
        .expect("record the engine absence");
    let opened = engine_unavailable_since(&db.pool, job.id).await;

    service
        .reconcile_once(&runtime, observed_at + Duration::seconds(1))
        .await
        .expect("record the engine recovery");

    assert!(
        opened.is_some(),
        "the first engine absence must open the mark"
    );
    assert_eq!(engine_unavailable_since(&db.pool, job.id).await, None);
    assert!(has_active_reservation(&db.pool, job.id).await);
}

/// A retained import the engine has disowned for longer than the grace window
/// must fail closed and release its node import reservation. Left unbounded,
/// enough forgotten jobs exhaust the active node import limit and every new
/// create on that node is refused.
#[tokio::test]
async fn postgres_reconciliation_fails_a_disowned_import_closed_past_the_absence_grace() {
    let Some(db) = connect_and_migrate("algolia_absence_grace_expiry").await else {
        return;
    };
    let vm_id = seed_active_vm(&db.pool).await;
    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 1).await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let engine_job_id = Uuid::new_v4();
    let job = prepare_running_create_job(
        &repo,
        &db.pool,
        customer_id,
        vm_id,
        engine_job_id,
        "absence-grace-expiry",
    )
    .await;
    let observed_at = postgres_timestamp(Utc::now());
    let runtime = absence_runtime(&db.pool);
    let (service, http) = service_harness(vec![
        engine_disowns_job_response(),
        engine_disowns_job_response(),
        empty_response(404),
    ])
    .await;

    let retained = service
        .reconcile_once(&runtime, observed_at)
        .await
        .expect("record the engine absence");

    assert_eq!(retained.persisted, 1);
    assert_eq!(retained.terminal_finalized, 0);
    assert!(has_active_reservation(&db.pool, job.id).await);

    backdate_engine_absence_mark(
        &db.pool,
        job.id,
        ENGINE_STATUS_ABSENCE_GRACE + Duration::minutes(1),
    )
    .await;
    let expired_at = observed_at + Duration::seconds(1);
    let expired = service
        .reconcile_once(&runtime, expired_at)
        .await
        .expect("fail the disowned import closed");

    assert_eq!(expired.terminal_finalized, 1);
    let failed = repo
        .get(job.id)
        .await
        .expect("read the failed import")
        .expect("failed import retained");
    assert_eq!(failed.status, AlgoliaImportJobStatus::Failed);
    assert_eq!(
        failed.publication_disposition,
        AlgoliaImportPublicationDisposition::Unchanged
    );
    assert_eq!(
        failed.error_code,
        Some(crate::models::AlgoliaImportErrorCode::BackendUnavailable)
    );
    assert!(!failed.retryable);
    assert_eq!(
        failed.engine_ack_state,
        AlgoliaImportEngineAckState::Acknowledged
    );
    assert_eq!(failed.terminal_at, Some(expired_at));
    assert_eq!(engine_unavailable_since(&db.pool, job.id).await, None);
    assert!(!has_active_reservation(&db.pool, job.id).await);
    let requests = http.requests.lock().unwrap();
    assert_eq!(requests.len(), 3);
    assert_eq!(requests[2].method, reqwest::Method::POST);
    assert!(requests[2].url.ends_with("/acknowledge"));
}
