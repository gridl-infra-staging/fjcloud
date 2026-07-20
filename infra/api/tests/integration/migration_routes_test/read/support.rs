use super::super::*;

pub(super) async fn setup_algolia_cloud_job_read_app(
    pool: PgPool,
    algolia_migration_enabled: bool,
) -> (axum::Router, String, Uuid) {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    insert_active_customer(&pool, customer.id, 1).await;
    let state = TestStateBuilder::new()
        .with_pool(pool)
        .with_customer_repo(customer_repo)
        .with_algolia_migration_enabled(algolia_migration_enabled)
        .build();
    let app = axum::Router::new()
        .route(
            "/migration/algolia/jobs",
            axum::routing::get(api::routes::migration::list_algolia_import_jobs),
        )
        .route(
            "/migration/algolia/jobs/:id",
            axum::routing::get(api::routes::migration::get_algolia_import_job),
        )
        .with_state(state);
    (app, create_test_jwt(customer.id), customer.id)
}

pub(super) async fn setup_algolia_cloud_job_lifecycle_app(
    pool: PgPool,
    algolia_migration_enabled: bool,
    source_service: Arc<dyn AlgoliaSourceLister>,
) -> (axum::Router, String, Uuid) {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    insert_active_customer(&pool, customer.id, 1).await;
    let state = TestStateBuilder::new()
        .with_pool(pool)
        .with_customer_repo(customer_repo)
        .with_algolia_source_service(source_service)
        .with_algolia_migration_enabled(algolia_migration_enabled)
        .build();
    let app = axum::Router::new()
        .route(
            "/migration/algolia/jobs",
            axum::routing::get(api::routes::migration::list_algolia_import_jobs),
        )
        .route(
            "/migration/algolia/jobs/:id",
            axum::routing::get(api::routes::migration::get_algolia_import_job),
        )
        .route(
            "/migration/algolia/jobs/:id/cancel",
            axum::routing::post(api::routes::migration::cancel_algolia_import_job),
        )
        .route(
            "/migration/algolia/jobs/:id/resume",
            axum::routing::post(api::routes::migration::resume_algolia_import_job),
        )
        .with_state(state);
    (app, create_test_jwt(customer.id), customer.id)
}

pub(super) async fn seed_retained_job_with_internals(
    pool: &PgPool,
    customer_id: Uuid,
    target: &str,
    key: &str,
    created_at: chrono::DateTime<Utc>,
) -> Uuid {
    let id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO algolia_import_jobs
         (id, customer_id, tenant_id, algolia_app_id, destination_kind, logical_target,
          destination_region, destination_vm_id, physical_uid, routing_identity,
          source_name, idempotency_key, canonical_fingerprint, source_size_bytes,
          lifecycle_generation, reserved_index_count, reserved_customer_storage_bytes,
          reserved_node_transient_bytes, created_at, updated_at)
         VALUES ($1, $2, $3, 'TESTAPP123', 'create', $3, 'us-east-1', $4,
                 'phys-secret-uid', 'routing-secret-id', 'source_products', $5,
                 'sha256:secret-fingerprint', 4096, 1, 1, 100, 0, $6, $6)",
    )
    .bind(id)
    .bind(customer_id)
    .bind(target)
    .bind(Uuid::new_v4())
    .bind(format!("idem-secret-{key}"))
    .bind(created_at)
    .execute(pool)
    .await
    .expect("seed retained job with internal fields");
    id
}

pub(super) async fn seed_retained_job_with_status(
    pool: &PgPool,
    customer_id: Uuid,
    target: &str,
    key: &str,
    status: AlgoliaImportJobStatus,
) -> Uuid {
    let id = seed_retained_job_with_internals(pool, customer_id, target, key, Utc::now()).await;
    let mut query = sqlx::query(
        "UPDATE algolia_import_jobs
         SET status = $2,
             dispatch_intent_state = $3,
             engine_job_id = $4,
             publication_disposition = $5,
             engine_ack_state = $6,
             error_code = $7,
             resumable = FALSE,
             updated_at = NOW()
         WHERE id = $1",
    )
    .bind(id)
    .bind(status.as_str());
    query = match status {
        AlgoliaImportJobStatus::Queued => query
            .bind("absent")
            .bind(None::<Uuid>)
            .bind("not_started")
            .bind("pending")
            .bind(None::<&str>),
        AlgoliaImportJobStatus::Interrupted => query
            .bind("committed")
            .bind(Some(Uuid::new_v4()))
            .bind("unchanged")
            .bind("pending")
            .bind(Some("interrupted")),
        AlgoliaImportJobStatus::Failed => query
            .bind("committed")
            .bind(Some(Uuid::new_v4()))
            .bind("unchanged")
            .bind("pending")
            .bind(Some("backend_unavailable")),
        AlgoliaImportJobStatus::Completed | AlgoliaImportJobStatus::CompletedWithWarnings => query
            .bind("committed")
            .bind(Some(Uuid::new_v4()))
            .bind("promoted")
            .bind("acknowledged")
            .bind(None::<&str>),
        AlgoliaImportJobStatus::Cancelled => query
            .bind("committed")
            .bind(Some(Uuid::new_v4()))
            .bind("unchanged")
            .bind("outbox_pending")
            .bind(None::<&str>),
        _ => query
            .bind("committed")
            .bind(Some(Uuid::new_v4()))
            .bind("unchanged")
            .bind("pending")
            .bind(None::<&str>),
    };
    query.execute(pool).await.expect("seed retained job status");
    id
}

pub(super) async fn seed_resumable_retained_job(
    pool: &PgPool,
    customer_id: Uuid,
    target: &str,
    key: &str,
    deadline: chrono::DateTime<Utc>,
) -> Uuid {
    let id = Uuid::new_v4();
    let engine_job_id = Uuid::new_v4();
    let observed_at = deadline - chrono::Duration::minutes(5);
    sqlx::query(
        "INSERT INTO algolia_import_jobs
         (id, customer_id, tenant_id, algolia_app_id, destination_kind, logical_target,
          destination_region, destination_vm_id, physical_uid, routing_identity,
          source_name, idempotency_key, canonical_fingerprint, source_size_bytes,
          lifecycle_generation, dispatch_intent_state, engine_job_id,
          publication_disposition, engine_ack_state, status, resumable,
          resume_checkpoint, resume_status_observed_at, resume_deadline, error_code,
          reserved_index_count, reserved_customer_storage_bytes, reserved_node_transient_bytes,
          created_at, updated_at)
         VALUES ($1, $2, $3, 'SERVERAPP123', 'create', $3, 'us-east-1', $4,
                 'phys-secret-uid', 'routing-secret-id', 'server_source', $5,
                 'sha256:secret-fingerprint', 4096, 1, 'committed', $6,
                 'unchanged', 'pending', 'failed', TRUE, 'opaque-checkpoint-secret',
                 $7, $8, 'backend_unavailable', 1, 100, 0, NOW(), NOW())",
    )
    .bind(id)
    .bind(customer_id)
    .bind(target)
    .bind(Uuid::new_v4())
    .bind(format!("idem-secret-{key}"))
    .bind(engine_job_id)
    .bind(observed_at)
    .bind(deadline)
    .execute(pool)
    .await
    .expect("seed resumable retained job");
    id
}

pub(super) async fn seed_resumable_retained_job_with_status(
    pool: &PgPool,
    customer_id: Uuid,
    target: &str,
    key: &str,
    status: AlgoliaImportJobStatus,
    deadline: chrono::DateTime<Utc>,
) -> Uuid {
    let id = seed_resumable_retained_job(pool, customer_id, target, key, deadline).await;
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET status = $2, error_code = $3, updated_at = NOW()
         WHERE id = $1",
    )
    .bind(id)
    .bind(status.as_str())
    .bind(match status {
        AlgoliaImportJobStatus::Interrupted => "interrupted",
        _ => "backend_unavailable",
    })
    .execute(pool)
    .await
    .expect("seed resumable retained job status");
    id
}

pub(super) async fn seed_replace_resumable_retained_job_without_target(
    pool: &PgPool,
    customer_id: Uuid,
    target: &str,
    key: &str,
) -> Uuid {
    let id = seed_resumable_retained_job(
        pool,
        customer_id,
        target,
        key,
        Utc::now() + chrono::Duration::hours(1),
    )
    .await;
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET destination_kind = 'replace', destination_deployment_id = $2, updated_at = NOW()
         WHERE id = $1",
    )
    .bind(id)
    .bind(Uuid::new_v4())
    .execute(pool)
    .await
    .expect("seed replace resumable job without target");
    id
}

pub(super) async fn status_generation_checkpoint_count(
    pool: &PgPool,
    id: Uuid,
) -> (String, i64, Option<String>, i64) {
    sqlx::query_as(
        "SELECT status, resume_intent_generation, resume_checkpoint, resume_count
         FROM algolia_import_jobs WHERE id = $1",
    )
    .bind(id)
    .fetch_one(pool)
    .await
    .expect("read lifecycle state")
}

pub(super) async fn serialized_job_row(pool: &PgPool, id: Uuid) -> String {
    sqlx::query_scalar::<_, serde_json::Value>(
        "SELECT to_jsonb(algolia_import_jobs.*)
         FROM algolia_import_jobs WHERE id = $1",
    )
    .bind(id)
    .fetch_one(pool)
    .await
    .expect("serialize job row")
    .to_string()
}

pub(super) async fn get_json(
    app: &axum::Router,
    jwt: &str,
    uri: &str,
) -> (StatusCode, serde_json::Value) {
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri(uri)
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    response_json(response).await
}

pub(super) async fn post_job_action(
    app: &axum::Router,
    jwt: &str,
    uri: &str,
    body: serde_json::Value,
) -> (StatusCode, http::HeaderMap, serde_json::Value) {
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri(uri)
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from(body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let headers = response.headers().clone();
    let (_, body) = response_json(response).await;
    (status, headers, body)
}
