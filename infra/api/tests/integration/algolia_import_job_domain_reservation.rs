use api::models::algolia_import_job::{
    AlgoliaImportCreateDestination, AlgoliaImportDispatchIntentState, AlgoliaImportEngineAckState,
    AlgoliaImportErrorCode, AlgoliaImportJobState, AlgoliaImportJobStatus,
    AlgoliaImportPublicationDisposition, AlgoliaImportSource, AlgoliaImportSourceMetadata,
    AlgoliaImportSummary, NewAlgoliaImportJob,
};
use api::repos::{AlgoliaImportJobRepo, PgAlgoliaImportJobRepo, PgTenantRepo, TenantRepo};
use chrono::{DateTime, Utc};
use serde_json::json;
use sqlx::PgPool;
use uuid::Uuid;

use crate::common::support::pg_schema_harness::{connect_and_migrate, insert_active_customer};

#[test]
fn active_target_reservation_releases_only_after_engine_reconciliation() {
    let migration = include_str!("../../../migrations/056_algolia_import_jobs.sql");
    let active_target_index = migration
        .split("CREATE UNIQUE INDEX idx_algolia_import_jobs_active_target")
        .nth(1)
        .expect("active-target unique reservation index");

    assert!(active_target_index.contains("publication_disposition = 'unknown'"));
    assert!(active_target_index.contains("resumable = TRUE"));
    assert!(active_target_index.contains(
        "engine_ack_state NOT IN ('not_applicable', 'seal_acknowledged', 'acknowledged')"
    ));
    assert!(!active_target_index.contains("worker_lease_expires_at"));
}

#[test]
fn migration_declares_active_reservation_accounting_columns() {
    let migration = include_str!("../../../migrations/056_algolia_import_jobs.sql");

    for column in [
        "reserved_index_count BIGINT DEFAULT 0",
        "reserved_customer_storage_bytes BIGINT DEFAULT 0",
        "reserved_node_transient_bytes BIGINT DEFAULT 0",
    ] {
        assert!(
            migration.contains(column),
            "migration must own Algolia import reservation accounting column {column}"
        );
    }
}

#[tokio::test]
async fn admission_snapshots_active_customer_generation_and_rejects_deleted_customer() {
    let Some(db) = connect_and_migrate("algolia_admission_lifecycle_generation").await else {
        return;
    };
    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 6).await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());

    let admitted = repo
        .create(create_job(customer_id, "products", "active-generation"))
        .await
        .expect("active customer admission");
    assert_eq!(admitted.lifecycle_generation, 6);

    sqlx::query(
        "UPDATE customers \
         SET status = 'deleted', lifecycle_generation = lifecycle_generation + 1 \
         WHERE id = $1",
    )
    .bind(customer_id)
    .execute(&db.pool)
    .await
    .expect("soft-delete customer fixture");

    assert!(
        repo.create(create_job(customer_id, "products", "active-generation"))
            .await
            .is_err(),
        "idempotent lookup must not bypass the active-customer generation fence"
    );
    assert!(repo
        .create(create_job(customer_id, "orders", "deleted-generation"))
        .await
        .is_err());
}

fn create_job(customer_id: Uuid, target: &str, key: &str) -> NewAlgoliaImportJob {
    create_job_with_source_size(customer_id, target, key, 12_345)
}

fn create_job_with_source_size(
    customer_id: Uuid,
    target: &str,
    key: &str,
    source_size_bytes: i64,
) -> NewAlgoliaImportJob {
    NewAlgoliaImportJob::create(
        customer_id,
        AlgoliaImportCreateDestination::new(target, "us-east-1"),
        AlgoliaImportSource::from_final_key_metadata(
            "AB12CD34EF",
            "Products",
            AlgoliaImportSourceMetadata::new(
                Some(source_size_bytes),
                Some(1_000),
                format!("revision-{key}"),
            ),
        ),
        key,
    )
}

async fn force_terminal_released(pool: &PgPool, job_id: Uuid) {
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET status = 'completed', publication_disposition = 'promoted',
             engine_ack_state = 'acknowledged', dispatch_intent_state = 'committed',
             engine_job_id = gen_random_uuid(), lifecycle_generation = 1,
             updated_at = NOW()
         WHERE id = $1",
    )
    .bind(job_id)
    .execute(pool)
    .await
    .expect("force terminal released");
}

async fn force_failed_not_resumable(pool: &PgPool, job_id: Uuid) {
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET status = 'failed', publication_disposition = 'not_started',
             engine_ack_state = 'not_applicable', dispatch_intent_state = 'absent',
             error_code = 'invalid_credentials', retryable = FALSE, resumable = FALSE,
             updated_at = NOW()
         WHERE id = $1",
    )
    .bind(job_id)
    .execute(pool)
    .await
    .expect("force failed not resumable");
}

async fn force_failed_resumable(pool: &PgPool, job_id: Uuid) {
    let observed_at = chrono::Utc::now();
    let deadline = observed_at + chrono::Duration::minutes(30);
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET status = 'failed', publication_disposition = 'unchanged',
             engine_ack_state = 'pending', dispatch_intent_state = 'committed',
             engine_job_id = gen_random_uuid(), lifecycle_generation = 1,
             error_code = 'backend_unavailable', retryable = TRUE, resumable = TRUE,
             resume_checkpoint = 'checkpoint-data', resume_status_observed_at = $2,
             resume_deadline = $3, updated_at = NOW()
         WHERE id = $1",
    )
    .bind(job_id)
    .bind(observed_at)
    .bind(deadline)
    .execute(pool)
    .await
    .expect("force failed resumable");
}

#[derive(Debug, PartialEq, Eq)]
struct TargetExclusionSnapshot {
    customer_id: Uuid,
    logical_target: String,
    engine_job_id: Option<Uuid>,
    dispatch_intent_state: AlgoliaImportDispatchIntentState,
    lifecycle_generation: i64,
    resumable: bool,
    retryable: bool,
    resume_intent_generation: i64,
    resume_count: i64,
    resume_deadline: Option<DateTime<Utc>>,
    resume_status_observed_at: Option<DateTime<Utc>>,
    resume_checkpoint: Option<String>,
    publication_disposition: AlgoliaImportPublicationDisposition,
    engine_ack_state: AlgoliaImportEngineAckState,
    status: AlgoliaImportJobStatus,
}

impl TargetExclusionSnapshot {
    fn from_job(job: &api::models::algolia_import_job::AlgoliaImportJob) -> Self {
        Self {
            customer_id: job.customer_id,
            logical_target: job.logical_target.clone(),
            engine_job_id: job.engine_job_id,
            dispatch_intent_state: job.dispatch_intent_state,
            lifecycle_generation: job.lifecycle_generation,
            resumable: job.resumable,
            retryable: job.retryable,
            resume_intent_generation: job.resume_intent_generation,
            resume_count: job.resume_count,
            resume_deadline: job.resume_deadline,
            resume_status_observed_at: job.resume_status_observed_at,
            resume_checkpoint: job.resume_checkpoint.clone(),
            publication_disposition: job.publication_disposition,
            engine_ack_state: job.engine_ack_state,
            status: job.status,
        }
    }
}

async fn expire_resume_worker_claim(pool: &PgPool, job_id: Uuid, now: DateTime<Utc>) {
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET worker_claimed_at = $2,
             worker_lease_expires_at = $3,
             resume_deadline = $4,
             resume_status_observed_at = $5,
             updated_at = NOW()
         WHERE id = $1",
    )
    .bind(job_id)
    .bind(now - chrono::Duration::minutes(20))
    .bind(now - chrono::Duration::minutes(10))
    .bind(now - chrono::Duration::minutes(5))
    .bind(now - chrono::Duration::minutes(15))
    .execute(pool)
    .await
    .expect("expire resume worker claim");
}

async fn force_failed_unknown_disposition(pool: &PgPool, job_id: Uuid) {
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET status = 'failed', publication_disposition = 'unknown',
             engine_ack_state = 'acknowledged', dispatch_intent_state = 'committed',
             engine_job_id = gen_random_uuid(), lifecycle_generation = 1,
             error_code = 'internal', retryable = FALSE, resumable = FALSE,
             updated_at = NOW()
         WHERE id = $1",
    )
    .bind(job_id)
    .execute(pool)
    .await
    .expect("force failed unknown disposition");
}

// ---------------------------------------------------------------------------
// Active-target reservation: partial unique constraint on (customer_id, logical_target)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn active_reservation_rejects_concurrent_same_target_create() {
    let Some(db) = connect_and_migrate("algolia_reserve_concurrent").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;

    let _first = repo
        .create(create_job(customer, "products", "key-1"))
        .await
        .expect("first create succeeds");

    let second = repo.create(create_job(customer, "products", "key-2")).await;

    assert!(
        second.is_err(),
        "second active job for same customer+target must be rejected"
    );
}

#[tokio::test]
async fn exact_replay_succeeds_after_original_consumes_customer_byte_quota() {
    let Some(db) = connect_and_migrate("algolia_reserve_replay_at_quota").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;
    let request = create_job_with_source_size(
        customer,
        "products",
        "quota-boundary-replay",
        10_737_418_240,
    );

    let original = repo
        .create(request.clone())
        .await
        .expect("initial admission");
    let replay = repo
        .create(request)
        .await
        .expect("exact replay must bypass a second quota admission");

    assert_eq!(replay.id, original.id);
    assert_eq!(replay.canonical_fingerprint, original.canonical_fingerprint);
}

#[tokio::test]
async fn active_reservation_allows_different_customers_same_target() {
    let Some(db) = connect_and_migrate("algolia_reserve_diff_cust").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let first_customer = Uuid::new_v4();
    let second_customer = Uuid::new_v4();
    insert_active_customer(&db.pool, first_customer, 1).await;
    insert_active_customer(&db.pool, second_customer, 1).await;
    let _first = repo
        .create(create_job(first_customer, "products", "key-a"))
        .await
        .expect("customer A create succeeds");

    let _second = repo
        .create(create_job(second_customer, "products", "key-b"))
        .await
        .expect("customer B same target must succeed");
}

#[tokio::test]
async fn active_reservation_allows_same_customer_different_targets() {
    let Some(db) = connect_and_migrate("algolia_reserve_diff_target").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;

    let _first = repo
        .create(create_job(customer, "products", "key-1"))
        .await
        .expect("first target succeeds");

    let _second = repo
        .create(create_job(customer, "orders", "key-2"))
        .await
        .expect("different target for same customer must succeed");
}

#[tokio::test]
async fn terminal_completed_releases_reservation() {
    let Some(db) = connect_and_migrate("algolia_reserve_release").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;

    let first = repo
        .create(create_job(customer, "products", "key-1"))
        .await
        .expect("first create");
    force_terminal_released(&db.pool, first.id).await;

    let _second = repo
        .create(create_job(customer, "products", "key-2"))
        .await
        .expect("create after terminal release must succeed");
}

#[tokio::test]
async fn terminal_failed_not_resumable_releases_reservation() {
    let Some(db) = connect_and_migrate("algolia_reserve_fail_rel").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;

    let first = repo
        .create(create_job(customer, "products", "key-1"))
        .await
        .expect("first create");
    force_failed_not_resumable(&db.pool, first.id).await;

    let _second = repo
        .create(create_job(customer, "products", "key-2"))
        .await
        .expect("create after non-resumable failure must succeed");
}

#[tokio::test]
async fn resumable_failed_retains_reservation() {
    let Some(db) = connect_and_migrate("algolia_reserve_resumable").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;

    let first = repo
        .create(create_job(customer, "products", "key-1"))
        .await
        .expect("first create");
    force_failed_resumable(&db.pool, first.id).await;

    let second = repo.create(create_job(customer, "products", "key-2")).await;
    assert!(
        second.is_err(),
        "resumable failed job must retain target reservation"
    );
}

#[tokio::test]
async fn elapsed_resume_takeover_preserves_target_exclusion() {
    let Some(db) = connect_and_migrate("algolia_reserve_takeover_exclusion").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;

    let first = repo
        .create(create_job(customer, "products", "key-1"))
        .await
        .expect("first create");
    force_failed_resumable(&db.pool, first.id).await;

    let now = Utc::now();
    let new_lease_expiry = now + chrono::Duration::minutes(15);
    expire_resume_worker_claim(&db.pool, first.id, now).await;
    let before_claim = repo
        .get(first.id)
        .await
        .expect("load before claim")
        .expect("job exists before claim");
    let exclusion_before = TargetExclusionSnapshot::from_job(&before_claim);

    let claims = repo
        .claim_elapsed_resume_deadlines(now, new_lease_expiry, 10)
        .await
        .expect("claim elapsed resume deadline");

    assert_eq!(claims.len(), 1);
    assert_eq!(claims[0].job_id, first.id);
    assert_eq!(claims[0].worker_claimed_at, now);
    assert_eq!(claims[0].worker_lease_expires_at, new_lease_expiry);

    let after_claim = repo
        .get(first.id)
        .await
        .expect("load after claim")
        .expect("job exists after claim");
    assert_eq!(
        TargetExclusionSnapshot::from_job(&after_claim),
        exclusion_before,
        "resume takeover must only change worker-claim ownership, not target exclusion facts"
    );

    let second = repo.create(create_job(customer, "products", "key-2")).await;
    assert!(
        second.is_err(),
        "expired worker lease and takeover must not release the active target reservation"
    );
}

#[tokio::test]
async fn unknown_disposition_retains_reservation() {
    let Some(db) = connect_and_migrate("algolia_reserve_unknown").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;

    let first = repo
        .create(create_job(customer, "products", "key-1"))
        .await
        .expect("first create");
    force_failed_unknown_disposition(&db.pool, first.id).await;

    let second = repo.create(create_job(customer, "products", "key-2")).await;
    assert!(
        second.is_err(),
        "publication_disposition='unknown' must retain reservation until reconciliation"
    );
}

#[tokio::test]
async fn cancelled_job_releases_reservation() {
    let Some(db) = connect_and_migrate("algolia_reserve_cancel").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;

    let first = repo
        .create(create_job(customer, "products", "key-1"))
        .await
        .expect("first create");

    sqlx::query(
        "UPDATE algolia_import_jobs
         SET status = 'cancelled', publication_disposition = 'unchanged',
             engine_ack_state = 'acknowledged', dispatch_intent_state = 'committed',
             engine_job_id = gen_random_uuid(), lifecycle_generation = 1,
             cancel_requested_at = NOW(), updated_at = NOW()
         WHERE id = $1",
    )
    .bind(first.id)
    .execute(&db.pool)
    .await
    .expect("force cancelled");

    let _second = repo
        .create(create_job(customer, "products", "key-2"))
        .await
        .expect("create after cancellation must succeed");
}

// ---------------------------------------------------------------------------
// Create target invisibility: new create targets must not appear in customer_tenants
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_destination_target_absent_from_customer_tenants() {
    let Some(db) = connect_and_migrate("algolia_reserve_invis").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;

    let _job = repo
        .create(create_job(customer, "products", "key-1"))
        .await
        .expect("create import job");

    let tenant_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM customer_tenants WHERE customer_id = $1 AND tenant_id = 'products'",
    )
    .bind(customer)
    .fetch_one(&db.pool)
    .await
    .expect("count tenants");

    assert_eq!(
        tenant_count, 0,
        "create-destination target must not appear in customer_tenants before promotion"
    );

    let tenant_repo = PgTenantRepo::new(db.pool.clone());
    let visible = tenant_repo
        .find_by_name(customer, "products")
        .await
        .expect("catalog lookup should succeed");
    assert!(
        visible.is_none(),
        "create-destination target must stay invisible through TenantRepo::find_by_name"
    );
}

// ---------------------------------------------------------------------------
// Release through record_no_dispatch_failure
// ---------------------------------------------------------------------------

#[tokio::test]
async fn no_dispatch_failure_releases_reservation() {
    let Some(db) = connect_and_migrate("algolia_reserve_nodispatch").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;

    let job = repo
        .create(create_job(customer, "products", "key-1"))
        .await
        .expect("create");

    repo.record_no_dispatch_failure(
        job.id,
        AlgoliaImportErrorCode::MigrationProviderUnsupported,
        Some("provider not supported"),
    )
    .await
    .expect("record no-dispatch failure");

    let _second = repo
        .create(create_job(customer, "products", "key-2"))
        .await
        .expect("create after no-dispatch failure must succeed — reservation released");
}

// ---------------------------------------------------------------------------
// Release through update_persisted_state to terminal
// ---------------------------------------------------------------------------

fn terminal_completed_state(engine_job_id: Uuid) -> AlgoliaImportJobState {
    AlgoliaImportJobState {
        status: AlgoliaImportJobStatus::Completed,
        publication_disposition: AlgoliaImportPublicationDisposition::Promoted,
        engine_ack_state: AlgoliaImportEngineAckState::Acknowledged,
        dispatch_intent_state: AlgoliaImportDispatchIntentState::Committed,
        engine_job_id: Some(engine_job_id),
        lifecycle_generation: 1,
        retryable: false,
        resume_intent_generation: 0,
        resume_mirror: None,
        resumable: false,
        resume_count: 0,
        summary: AlgoliaImportSummary::default(),
        warnings: json!([]),
        error_code: None,
        error_message: None,
    }
}

fn active_engine_state(
    status: AlgoliaImportJobStatus,
    engine_job_id: Uuid,
) -> AlgoliaImportJobState {
    AlgoliaImportJobState {
        status,
        publication_disposition: AlgoliaImportPublicationDisposition::NotStarted,
        engine_ack_state: AlgoliaImportEngineAckState::Pending,
        dispatch_intent_state: AlgoliaImportDispatchIntentState::Committed,
        engine_job_id: Some(engine_job_id),
        lifecycle_generation: 1,
        retryable: false,
        resume_intent_generation: 0,
        resume_mirror: None,
        resumable: false,
        resume_count: 0,
        summary: AlgoliaImportSummary::default(),
        warnings: json!([]),
        error_code: None,
        error_message: None,
    }
}

async fn advance_to_copying_documents(
    repo: &PgAlgoliaImportJobRepo,
    job_id: Uuid,
    engine_job_id: Uuid,
) {
    repo.record_dispatch_intent_committed(job_id, engine_job_id)
        .await
        .expect("commit dispatch intent");
    for status in [
        AlgoliaImportJobStatus::ValidatingSource,
        AlgoliaImportJobStatus::CopyingConfiguration,
        AlgoliaImportJobStatus::CopyingDocuments,
    ] {
        repo.update_persisted_state(job_id, active_engine_state(status, engine_job_id))
            .await
            .expect("advance active import phase");
    }
}

#[tokio::test]
async fn terminal_state_update_releases_reservation() {
    let Some(db) = connect_and_migrate("algolia_reserve_state_rel").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;

    let job = repo
        .create(create_job(customer, "products", "key-1"))
        .await
        .expect("create");

    let engine_job_id = Uuid::new_v4();
    advance_to_copying_documents(&repo, job.id, engine_job_id).await;

    for status in [
        AlgoliaImportJobStatus::Verifying,
        AlgoliaImportJobStatus::Promoting,
    ] {
        repo.update_persisted_state(job.id, active_engine_state(status, engine_job_id))
            .await
            .expect("advance import toward completion");
    }

    repo.update_persisted_state(job.id, terminal_completed_state(engine_job_id))
        .await
        .expect("transition to completed");

    let _second = repo
        .create(create_job(customer, "products", "key-2"))
        .await
        .expect("create after terminal state update must succeed — reservation released");
}

#[tokio::test]
async fn resumable_failure_state_retains_reservation_through_update() {
    let Some(db) = connect_and_migrate("algolia_reserve_resume_upd").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;

    let job = repo
        .create(create_job(customer, "products", "key-1"))
        .await
        .expect("create");

    let engine_job_id = Uuid::new_v4();
    let observed_at = chrono::Utc::now();
    let deadline = observed_at + chrono::Duration::minutes(30);
    advance_to_copying_documents(&repo, job.id, engine_job_id).await;

    let failed_resumable_state = AlgoliaImportJobState {
        status: AlgoliaImportJobStatus::Failed,
        publication_disposition: AlgoliaImportPublicationDisposition::Unchanged,
        engine_ack_state: AlgoliaImportEngineAckState::Pending,
        dispatch_intent_state: AlgoliaImportDispatchIntentState::Committed,
        engine_job_id: Some(engine_job_id),
        lifecycle_generation: 1,
        retryable: true,
        resume_intent_generation: 0,
        resume_mirror: Some(
            api::models::algolia_import_job::EngineResumeMirror::new(
                "checkpoint-data".into(),
                observed_at,
                deadline,
            )
            .unwrap(),
        ),
        resumable: true,
        resume_count: 0,
        summary: AlgoliaImportSummary::default(),
        warnings: json!([]),
        error_code: Some(AlgoliaImportErrorCode::BackendUnavailable),
        error_message: Some("transient backend error".into()),
    };
    repo.update_persisted_state(job.id, failed_resumable_state)
        .await
        .expect("transition to resumable failed");

    let second = repo.create(create_job(customer, "products", "key-2")).await;
    assert!(
        second.is_err(),
        "resumable failed job must retain reservation through state update path"
    );
}

#[tokio::test]
async fn resumed_job_does_not_create_second_reservation() {
    let Some(db) = connect_and_migrate("algolia_reserve_resume_nodup").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;

    let job = repo
        .create(create_job(customer, "products", "key-1"))
        .await
        .expect("create");

    let engine_job_id = Uuid::new_v4();
    let observed_at = chrono::Utc::now();
    let deadline = observed_at + chrono::Duration::minutes(30);

    advance_to_copying_documents(&repo, job.id, engine_job_id).await;

    let failed_resumable = AlgoliaImportJobState {
        status: AlgoliaImportJobStatus::Failed,
        publication_disposition: AlgoliaImportPublicationDisposition::Unchanged,
        engine_ack_state: AlgoliaImportEngineAckState::Pending,
        dispatch_intent_state: AlgoliaImportDispatchIntentState::Committed,
        engine_job_id: Some(engine_job_id),
        lifecycle_generation: 1,
        retryable: true,
        resume_intent_generation: 0,
        resume_mirror: Some(
            api::models::algolia_import_job::EngineResumeMirror::new(
                "checkpoint-data".into(),
                observed_at,
                deadline,
            )
            .unwrap(),
        ),
        resumable: true,
        resume_count: 0,
        summary: AlgoliaImportSummary::default(),
        warnings: json!([]),
        error_code: Some(AlgoliaImportErrorCode::BackendUnavailable),
        error_message: Some("transient".into()),
    };
    repo.update_persisted_state(job.id, failed_resumable)
        .await
        .expect("transition to resumable failed");

    let resume_outcome = repo.prepare_resume(job.id).await.expect("prepare resume");
    assert_eq!(resume_outcome.job.status, AlgoliaImportJobStatus::Resuming);

    let job_after_resume = repo.get(job.id).await.expect("get").expect("job exists");
    assert_eq!(job_after_resume.status, AlgoliaImportJobStatus::Resuming);

    let second = repo.create(create_job(customer, "products", "key-2")).await;
    assert!(
        second.is_err(),
        "resumed job must retain the same reservation, not create a second one"
    );
}
