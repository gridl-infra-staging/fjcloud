use std::collections::BTreeSet;

use api::models::algolia_import_job::{
    AlgoliaImportCreateDestination, AlgoliaImportDispatchIntentState, AlgoliaImportEngineAckState,
    AlgoliaImportErrorCode, AlgoliaImportJob, AlgoliaImportJobState, AlgoliaImportJobStatus,
    AlgoliaImportPublicationDisposition, AlgoliaImportSource, AlgoliaImportSourceMetadata,
    AlgoliaImportSummary, NewAlgoliaImportJob, NewAlgoliaReplaceImportJob,
};
use api::repos::{
    AlgoliaImportJobAdmissionError, AlgoliaImportJobRepo, CustomerHardDeleteKind, CustomerRepo,
    PgAlgoliaImportJobRepo, PgCustomerRepo, PgTenantRepo, TenantRepo,
};
use chrono::{DateTime, Utc};
use serde_json::json;
use sqlx::PgPool;
use uuid::Uuid;

use crate::common::algolia_import_reservation_lifetime::{
    algolia_import_engine_ack_states, algolia_import_publication_dispositions,
    algolia_import_statuses, assert_algolia_import_job_unchanged_except_worker_claim,
    force_reservation_lifetime_case, reservation_lifetime_denominator,
    validate_reservation_lifetime_denominator, DenominatorValidation, ReservationExpectation,
};
use crate::common::support::pg_schema_harness::{
    connect_and_migrate, insert_active_customer, postgres_timestamp,
};

#[test]
fn reservation_lifetime_denominator_matches_model_and_schema_once() {
    let migration = include_str!("../../../migrations/056_algolia_import_jobs.sql");
    assert_migration_enum_values(
        migration,
        "CHECK (status IN (",
        algolia_import_statuses()
            .iter()
            .map(|status| status.as_str())
            .collect(),
    );
    assert_migration_enum_values(
        migration,
        "CHECK (publication_disposition IN (",
        algolia_import_publication_dispositions()
            .iter()
            .map(|disposition| disposition.as_str())
            .collect(),
    );
    assert_migration_enum_values(
        migration,
        "CHECK (engine_ack_state IN (",
        algolia_import_engine_ack_states()
            .iter()
            .map(|ack_state| ack_state.as_str())
            .collect(),
    );
    for required_constraint in [
        "CHECK (NOT resumable OR (",
        "status IN ('failed', 'interrupted')",
        "publication_disposition = 'unchanged'",
        "engine_ack_state = 'pending'",
        "CHECK (status <> 'interrupted' OR (",
        "CHECK (engine_ack_state <> 'not_applicable' OR erased_at IS NOT NULL OR (",
        "CHECK (engine_ack_state <> 'seal_acknowledged' OR erased_at IS NOT NULL OR (",
        "CHECK (engine_ack_state NOT IN ('outbox_pending', 'acknowledged') OR erased_at IS NOT NULL OR (",
    ] {
        assert!(
            migration.contains(required_constraint),
            "migration 056 must retain reservation denominator constraint {required_constraint}"
        );
    }

    let active_target_index = migration
        .split("CREATE UNIQUE INDEX idx_algolia_import_jobs_active_target")
        .nth(1)
        .expect("active-target unique reservation index");
    assert!(active_target_index.contains("publication_disposition = 'unknown'"));
    assert!(active_target_index.contains("resumable = TRUE"));
    assert!(active_target_index.contains(
        "engine_ack_state NOT IN ('not_applicable', 'seal_acknowledged', 'acknowledged')"
    ));
    assert!(
        !active_target_index.contains("worker_lease_expires_at"),
        "reservation lifetime must not use wall-clock worker lease expiry"
    );

    let cases = reservation_lifetime_denominator();
    assert_eq!(
        validate_reservation_lifetime_denominator(&cases),
        DenominatorValidation::default(),
        "reservation lifetime denominator must classify every schema-valid state exactly once"
    );
    assert!(
        cases
            .iter()
            .any(|case| case.expectation == ReservationExpectation::Release)
            && cases
                .iter()
                .any(|case| case.expectation == ReservationExpectation::Retain),
        "denominator must cover both release and retain outcomes"
    );
}

fn assert_migration_enum_values(
    migration: &str,
    start_marker: &str,
    expected_values: BTreeSet<&'static str>,
) {
    let start = migration
        .find(start_marker)
        .unwrap_or_else(|| panic!("missing migration enum marker {start_marker}"));
    let values_sql = &migration[start + start_marker.len()..];
    let end = values_sql
        .find(')')
        .unwrap_or_else(|| panic!("unterminated migration enum marker {start_marker}"));
    let observed_values = parse_single_quoted_values(&values_sql[..end]);
    assert_eq!(
        observed_values, expected_values,
        "migration enum values for {start_marker} must match model as_str owners"
    );
}

fn parse_single_quoted_values(sql: &str) -> BTreeSet<&str> {
    let mut values = BTreeSet::new();
    let mut rest = sql;
    while let Some(start) = rest.find('\'') {
        let after_start = &rest[start + 1..];
        let end = after_start.find('\'').expect("unterminated SQL string");
        assert!(
            values.insert(&after_start[..end]),
            "duplicate SQL enum literal {}",
            &after_start[..end]
        );
        rest = &after_start[end + 1..];
    }
    values
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

#[tokio::test]
async fn soft_deleted_customer_refuses_replace_admission_and_replay_without_mutating_reservation() {
    let Some(db) = connect_and_migrate("algolia_deleted_replace_fence").await else {
        return;
    };
    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 5).await;
    seed_replace_target(&db.pool, customer_id, "products").await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let original_request = replace_job(customer_id, "products", "deleted-replace-replay");
    let retained = repo
        .create_replace(original_request.clone())
        .await
        .expect("admit active-generation replace import");
    assert_eq!(retained.lifecycle_generation, 5);
    let retained_before = serialized_import_job_row(&db.pool, retained.id).await;
    let reservation_before = reservation_totals_for_customer(&db.pool, customer_id).await;

    soft_delete_customer(&db.pool, customer_id).await;

    assert_destination_changed_admission(
        repo.create_replace(original_request).await,
        "same-key replace replay after soft-delete",
    );
    assert_destination_changed_admission(
        repo.create_replace(replace_job(
            customer_id,
            "products",
            "deleted-replace-new-key",
        ))
        .await,
        "new replace after soft-delete",
    );
    assert_eq!(
        import_job_count_for_customer(&db.pool, customer_id).await,
        1
    );
    assert_eq!(
        serialized_import_job_row(&db.pool, retained.id).await,
        retained_before
    );
    assert_eq!(
        reservation_totals_for_customer(&db.pool, customer_id).await,
        reservation_before
    );
}

fn create_job(customer_id: Uuid, target: &str, key: &str) -> NewAlgoliaImportJob {
    create_job_with_source_size(customer_id, target, key, 12_345)
}

fn replace_job(customer_id: Uuid, target: &str, key: &str) -> NewAlgoliaReplaceImportJob {
    NewAlgoliaReplaceImportJob::new(customer_id, target, import_source(key, 12_345), key)
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
        import_source(key, source_size_bytes),
        key,
    )
}

fn import_source(key: &str, source_size_bytes: i64) -> AlgoliaImportSource {
    AlgoliaImportSource::from_final_key_metadata(
        "AB12CD34EF",
        "Products",
        AlgoliaImportSourceMetadata::new(
            Some(source_size_bytes),
            Some(1_000),
            format!("revision-{key}"),
        ),
    )
}

async fn seed_replace_target(pool: &PgPool, customer_id: Uuid, target: &str) {
    let vm_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO vm_inventory
         (id, region, provider, hostname, flapjack_url, status, capacity, current_load)
         VALUES ($1, 'us-east-1', 'aws', $2, 'https://replace-target.invalid', 'active',
                 $3::jsonb, $4::jsonb)",
    )
    .bind(vm_id)
    .bind(format!("vm-{vm_id}"))
    .bind(json!({ "disk_bytes": 10_000_000_000_i64 }))
    .bind(json!({ "disk_bytes": 0_i64 }))
    .execute(pool)
    .await
    .expect("seed replace VM");

    let deployment_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO customer_deployments
         (id, customer_id, node_id, region, vm_type, vm_provider, status,
          flapjack_url, health_status)
         VALUES ($1, $2, $3, 'us-east-1', 't4g.small', 'aws', 'running',
                 'https://replace-target.invalid', 'healthy')",
    )
    .bind(deployment_id)
    .bind(customer_id)
    .bind(format!("node-{deployment_id}"))
    .execute(pool)
    .await
    .expect("seed replace deployment");

    sqlx::query(
        "INSERT INTO customer_tenants
         (customer_id, tenant_id, deployment_id, vm_id, tier, service_type)
         VALUES ($1, $2, $3, $4, 'active', 'flapjack')",
    )
    .bind(customer_id)
    .bind(target)
    .bind(deployment_id)
    .bind(vm_id)
    .execute(pool)
    .await
    .expect("seed replace target");
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

async fn hard_erase_customer(pool: &PgPool, customer_id: Uuid) {
    soft_delete_customer(pool, customer_id).await;
    PgCustomerRepo::new(pool.clone())
        .hard_delete(customer_id, CustomerHardDeleteKind::PrivacyErasure)
        .await
        .expect("hard-erase customer");
}

async fn serialized_import_job_row(pool: &PgPool, id: Uuid) -> serde_json::Value {
    sqlx::query_scalar(
        "SELECT to_jsonb(algolia_import_jobs.*)
         FROM algolia_import_jobs WHERE id = $1",
    )
    .bind(id)
    .fetch_one(pool)
    .await
    .expect("serialize retained import job row")
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

async fn public_import_job_ids_for_customer_target(
    pool: &PgPool,
    customer_id: Uuid,
    target: &str,
) -> Vec<Uuid> {
    sqlx::query_scalar(
        "SELECT id
         FROM algolia_import_jobs
         WHERE customer_id = $1
           AND logical_target = $2
           AND erased_at IS NULL
         ORDER BY id",
    )
    .bind(customer_id)
    .bind(target)
    .fetch_all(pool)
    .await
    .expect("fetch active reservation owners")
}

async fn import_job_count_for_customer(pool: &PgPool, customer_id: Uuid) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM algolia_import_jobs WHERE customer_id = $1")
        .bind(customer_id)
        .fetch_one(pool)
        .await
        .expect("count customer import jobs")
}

async fn reservation_totals_for_customer(pool: &PgPool, customer_id: Uuid) -> (i64, i64, i64) {
    sqlx::query_as(
        "SELECT COALESCE(SUM(reserved_index_count), 0)::BIGINT,
                COALESCE(SUM(reserved_customer_storage_bytes), 0)::BIGINT,
                COALESCE(SUM(reserved_node_transient_bytes), 0)::BIGINT
         FROM algolia_import_jobs WHERE customer_id = $1",
    )
    .bind(customer_id)
    .fetch_one(pool)
    .await
    .expect("sum customer import reservations")
}

fn assert_destination_changed_admission(
    result: Result<AlgoliaImportJob, AlgoliaImportJobAdmissionError>,
    context: &str,
) {
    assert!(
        matches!(
            result,
            Err(AlgoliaImportJobAdmissionError::Refused(
                AlgoliaImportErrorCode::DestinationChanged
            ))
        ),
        "{context}: expected destination_changed refusal, got {result:?}"
    );
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

fn assert_destination_conflict(
    result: Result<
        api::models::algolia_import_job::AlgoliaImportJob,
        AlgoliaImportJobAdmissionError,
    >,
) {
    assert!(matches!(
        result,
        Err(AlgoliaImportJobAdmissionError::Refused(
            AlgoliaImportErrorCode::DestinationConflict
        ))
    ));
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
async fn reservation_lifetime_release_and_retain_match_denominator() {
    let Some(db) = connect_and_migrate("algolia_reserve_denominator").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());

    for (index, case) in reservation_lifetime_denominator().iter().enumerate() {
        let customer = Uuid::new_v4();
        insert_active_customer(&db.pool, customer, 1).await;
        let target = format!("target-{index}");
        let first = repo
            .create(create_job(customer, &target, &format!("first-{index}")))
            .await
            .unwrap_or_else(|error| panic!("first create for {}: {error:?}", case.label));
        force_reservation_lifetime_case(&db.pool, first.id, case).await;

        let second = repo
            .create(create_job(customer, &target, &format!("second-{index}")))
            .await;
        match case.expectation {
            ReservationExpectation::Release => {
                second.unwrap_or_else(|error| {
                    panic!(
                        "{} should release target reservation: {error:?}",
                        case.label
                    )
                });
            }
            ReservationExpectation::Retain => assert!(
                second.is_err(),
                "{} should retain target reservation",
                case.label
            ),
        }
    }
}

#[tokio::test]
async fn erased_tombstone_selector_releases_active_target_reservation() {
    let Some(db) = connect_and_migrate("algolia_erased_reservation_release").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer_id = Uuid::new_v4();
    let target = "products";
    insert_active_customer(&db.pool, customer_id, 1).await;
    seed_replace_target(&db.pool, customer_id, target).await;

    let original = repo
        .create_replace(replace_job(
            customer_id,
            target,
            "erased-reservation-original",
        ))
        .await
        .expect("admit original replace import");
    assert_eq!(
        public_import_job_ids_for_customer_target(&db.pool, customer_id, target).await,
        vec![original.id]
    );

    hard_erase_customer(&db.pool, customer_id).await;
    let tombstone_after_erase = serialized_import_job_row(&db.pool, original.id).await;
    let erasure_handle: Uuid = tombstone_after_erase["erasure_handle"]
        .as_str()
        .expect("erased import must retain opaque erasure handle")
        .parse()
        .expect("erasure handle is a UUID");

    insert_active_customer(&db.pool, customer_id, 1).await;
    seed_replace_target(&db.pool, customer_id, target).await;
    let replacement = repo
        .create_replace(replace_job(
            customer_id,
            target,
            "erased-reservation-replacement",
        ))
        .await
        .expect("erased tombstone must release active target reservation");
    assert_destination_conflict(
        repo.create_replace(replace_job(
            customer_id,
            target,
            "erased-reservation-duplicate",
        ))
        .await,
    );

    assert_eq!(
        serialized_import_job_row_by_erasure_handle(&db.pool, erasure_handle).await,
        tombstone_after_erase
    );
    assert_eq!(
        public_import_job_ids_for_customer_target(&db.pool, customer_id, target).await,
        vec![replacement.id],
        "replacement public row alone must own the active reservation"
    );
}

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

    let now = postgres_timestamp(Utc::now());
    let new_lease_expiry = now + chrono::Duration::minutes(15);
    expire_resume_worker_claim(&db.pool, first.id, now).await;
    let before_competitor = repo.create(create_job(customer, "products", "key-2")).await;
    assert_destination_conflict(before_competitor);
    let before_claim = repo
        .get(first.id)
        .await
        .expect("load before claim")
        .expect("job exists before claim");
    let old_worker_claimed_at = now - chrono::Duration::minutes(20);
    let old_worker_lease_expires_at = now - chrono::Duration::minutes(10);
    assert_eq!(before_claim.worker_claimed_at, Some(old_worker_claimed_at));
    assert_eq!(
        before_claim.worker_lease_expires_at,
        Some(old_worker_lease_expires_at)
    );

    let claims = repo
        .claim_elapsed_resume_deadlines(now, new_lease_expiry, 10)
        .await
        .expect("claim elapsed resume deadline");

    assert_eq!(claims.len(), 1);
    let claim = claims.first().expect("one elapsed resume claim");
    assert_eq!(claim.job_id, before_claim.id);
    assert_eq!(claim.cloud_job_id, before_claim.cloud_job_id);
    assert_eq!(
        Some(claim.engine_job_id),
        before_claim.engine_job_id,
        "claim must return the persisted non-null engine job id"
    );
    assert_eq!(
        claim.resume_intent_generation,
        before_claim.resume_intent_generation
    );
    assert_eq!(claim.resume_count, before_claim.resume_count);
    assert_eq!(
        Some(claim.resume_deadline),
        before_claim.resume_deadline,
        "claim must return the persisted non-null resume deadline"
    );
    assert_eq!(claim.worker_claimed_at, now);
    assert_eq!(claim.worker_lease_expires_at, new_lease_expiry);

    let after_claim = repo
        .get(first.id)
        .await
        .expect("load after claim")
        .expect("job exists after claim");
    assert_algolia_import_job_unchanged_except_worker_claim(&before_claim, &after_claim);
    assert_eq!(after_claim.worker_claimed_at, Some(now));
    assert_eq!(after_claim.worker_lease_expires_at, Some(new_lease_expiry));

    let after_competitor = repo.create(create_job(customer, "products", "key-3")).await;
    assert_destination_conflict(after_competitor);
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
