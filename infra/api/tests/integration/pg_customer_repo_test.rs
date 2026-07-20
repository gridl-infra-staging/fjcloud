/// SQL integration tests for PgCustomerRepo data contracts.
use api::models::{
    AlgoliaImportEngineAckState, AlgoliaImportPublicationDisposition,
    AlgoliaImportTombstoneCleanupPhase, Customer, IngestQuotaWarningMetric,
};
use api::repos::{
    CustomerHardDeleteKind, CustomerHardDeleteOutcome, CustomerRepo, PgCustomerRepo,
    ResendVerificationOutcome,
};
use rust_decimal::Decimal;
use rust_decimal_macros::dec;
use sqlx::PgPool;
use std::collections::HashSet;
use std::sync::Arc;
use uuid::Uuid;

use crate::common::support::pg_schema_harness;
use crate::common::support::pg_schema_harness::postgres_timestamp;
use crate::common::vm_inventory_reference_guard_fixtures::insert_vm_with_id;

async fn cleanup_customer(pool: &PgPool, email: &str) {
    sqlx::query("DELETE FROM customers WHERE email = $1")
        .bind(email)
        .execute(pool)
        .await
        .ok();
}

async fn cleanup_customer_graph(pool: &PgPool, customer_ids: &[Uuid]) {
    sqlx::query("DELETE FROM customer_tenants WHERE customer_id = ANY($1)")
        .bind(customer_ids.to_vec())
        .execute(pool)
        .await
        .ok();
    sqlx::query("DELETE FROM customer_deployments WHERE customer_id = ANY($1)")
        .bind(customer_ids.to_vec())
        .execute(pool)
        .await
        .ok();
    sqlx::query("DELETE FROM subscriptions WHERE customer_id = ANY($1)")
        .bind(customer_ids.to_vec())
        .execute(pool)
        .await
        .ok();
    sqlx::query("DELETE FROM invoices WHERE customer_id = ANY($1)")
        .bind(customer_ids.to_vec())
        .execute(pool)
        .await
        .ok();
    sqlx::query("DELETE FROM customers WHERE id = ANY($1)")
        .bind(customer_ids.to_vec())
        .execute(pool)
        .await
        .ok();
}

/// Minimal row shape used to inspect retention metadata directly from SQL.
#[derive(sqlx::FromRow)]
struct CustomerDeletionMetadataRaw {
    #[allow(dead_code)]
    id: Uuid,
    updated_at: chrono::DateTime<chrono::Utc>,
    deleted_at: Option<chrono::DateTime<chrono::Utc>>,
}

#[derive(Debug, PartialEq, sqlx::FromRow)]
struct CustomerLifecycleSnapshot {
    id: Uuid,
    email: String,
    status: String,
    lifecycle_generation: i64,
    created_at: chrono::DateTime<chrono::Utc>,
    updated_at: chrono::DateTime<chrono::Utc>,
    deleted_at: Option<chrono::DateTime<chrono::Utc>>,
}

#[derive(Debug, PartialEq)]
struct RetainedEvidenceSnapshot {
    deployments: String,
    vm_inventory: String,
    tenants: String,
    cold_snapshots: String,
    algolia_import_jobs: String,
}

/// Reads deletion metadata via a schema-tolerant projection so the test can
/// fail on missing behavior without requiring Stage 2 schema changes first.
async fn fetch_customer_deletion_metadata(pool: &PgPool, id: Uuid) -> CustomerDeletionMetadataRaw {
    sqlx::query_as(
        "SELECT \
            id, \
            updated_at, \
            (to_jsonb(customers)->>'deleted_at')::timestamptz AS deleted_at \
         FROM customers \
         WHERE id = $1",
    )
    .bind(id)
    .fetch_one(pool)
    .await
    .expect("fetch customer deletion metadata")
}

async fn fetch_customer_lifecycle_snapshot(pool: &PgPool, id: Uuid) -> CustomerLifecycleSnapshot {
    sqlx::query_as(
        "SELECT \
            id, email, status, lifecycle_generation, created_at, updated_at, deleted_at \
         FROM customers \
         WHERE id = $1",
    )
    .bind(id)
    .fetch_one(pool)
    .await
    .expect("fetch customer lifecycle snapshot")
}

async fn fetch_retained_evidence_snapshot(
    pool: &PgPool,
    customer_id: Uuid,
) -> RetainedEvidenceSnapshot {
    RetainedEvidenceSnapshot {
        deployments: fetch_jsonb_rows(
            pool,
            "SELECT id, customer_id, node_id, region, vm_type, vm_provider, ip_address, \
                    status, provider_vm_id, hostname, flapjack_url, health_status, \
                    failure_reason, created_at, terminated_at, last_health_check_at \
             FROM customer_deployments WHERE customer_id = $1",
            customer_id,
        )
        .await,
        vm_inventory: fetch_jsonb_rows(
            pool,
            "SELECT id, region, provider, hostname, flapjack_url, capacity, current_load, status, \
                    created_at, updated_at, load_scraped_at \
             FROM vm_inventory \
             WHERE id IN (SELECT source_vm_id FROM cold_snapshots WHERE customer_id = $1)",
            customer_id,
        )
        .await,
        tenants: fetch_jsonb_rows(
            pool,
            "SELECT customer_id, tenant_id, deployment_id, created_at, vm_id, tier, \
                    resource_quota, last_accessed_at, cold_snapshot_id, service_type \
             FROM customer_tenants WHERE customer_id = $1",
            customer_id,
        )
        .await,
        cold_snapshots: fetch_jsonb_rows(
            pool,
            "SELECT id, customer_id, tenant_id, source_vm_id, object_key, size_bytes, checksum, \
                    status, error, created_at, completed_at, expires_at \
             FROM cold_snapshots WHERE customer_id = $1",
            customer_id,
        )
        .await,
        algolia_import_jobs: fetch_jsonb_rows(
            pool,
            "SELECT id, customer_id, tenant_id, algolia_app_id, destination_kind, logical_target, \
                    destination_region, destination_deployment_id, destination_vm_id, \
                    physical_uid, source_name, cloud_job_id, engine_job_id, \
                    dispatch_intent_state, lifecycle_generation, idempotency_key, \
                    canonical_fingerprint, routing_identity, source_size_bytes, \
                    reserved_index_count, reserved_customer_storage_bytes, \
                    reserved_node_transient_bytes, retryable, worker_claimed_at, \
                    worker_lease_expires_at, cancel_requested_at, resume_intent_generation, \
                    resume_checkpoint, resume_deadline, resume_status_observed_at, resumable, \
                    resume_count, documents_expected, documents_imported, documents_rejected, \
                    settings_applied, settings_unsupported, synonyms_expected, \
                    synonyms_imported, synonyms_rejected, rules_expected, rules_imported, \
                    rules_rejected, warnings, error_code, error_message, status, \
                    publication_disposition, engine_ack_state, terminal_at, cleanup_phase, \
                    created_at, updated_at \
             FROM algolia_import_jobs WHERE customer_id = $1",
            customer_id,
        )
        .await,
    }
}

fn assert_algolia_recovery_metadata_seeded(evidence: &RetainedEvidenceSnapshot) {
    let jobs: Vec<serde_json::Value> = serde_json::from_str(&evidence.algolia_import_jobs)
        .expect("Algolia import job snapshot should deserialize");
    assert!(
        jobs.iter().any(|job| {
            json_field_is_populated(job, "cleanup_phase")
                && json_field_is_populated(job, "cancel_requested_at")
                && json_field_is_populated(job, "cloud_job_id")
        }),
        "retained-evidence fixture must include populated cleanup_phase, \
         cancel_requested_at, and cloud_job_id values"
    );
}

fn json_field_is_populated(row: &serde_json::Value, field: &str) -> bool {
    matches!(row.get(field), Some(value) if !value.is_null())
}

async fn fetch_jsonb_rows(pool: &PgPool, sql: &str, customer_id: Uuid) -> String {
    let wrapped_sql = format!(
        "SELECT COALESCE(jsonb_agg(to_jsonb(row_data) ORDER BY to_jsonb(row_data)::text)::text, '[]') \
         FROM ({sql}) AS row_data"
    );
    sqlx::query_scalar::<_, String>(&wrapped_sql)
        .bind(customer_id)
        .fetch_one(pool)
        .await
        .expect("fetch retained evidence JSON rows")
}

async fn seed_soft_delete_recovery_evidence(
    pool: &PgPool,
    customer: &Customer,
    lifecycle_generation: i64,
) -> (Uuid, Uuid, Uuid) {
    let deployment_id = Uuid::new_v4();
    let vm_id = Uuid::new_v4();
    let cold_snapshot_id = Uuid::new_v4();
    let tenant_id = format!("retained-cold-{}", &Uuid::new_v4().to_string()[..8]);

    sqlx::query(
        "INSERT INTO customer_deployments \
            (id, customer_id, node_id, region, vm_type, vm_provider, ip_address, status, \
             provider_vm_id, hostname, flapjack_url, health_status) \
         VALUES ($1, $2, $3, 'us-east-1', 't4g.small', 'aws', '10.0.0.7', 'running', \
                 'i-retained-soft-delete', 'retained-node.internal', \
                 'http://retained-node.internal:7700', 'healthy')",
    )
    .bind(deployment_id)
    .bind(customer.id)
    .bind(format!(
        "retained-node-{}",
        &Uuid::new_v4().to_string()[..8]
    ))
    .execute(pool)
    .await
    .expect("seed retained customer_deployments row");

    sqlx::query(
        "INSERT INTO vm_inventory \
            (id, region, provider, hostname, flapjack_url, capacity, current_load, status) \
         VALUES ($1, 'us-east-1', 'aws', $2, 'http://retained-vm.internal:7700', \
                 '{\"storage_bytes\": 1000000, \"indexes\": 8}'::jsonb, \
                 '{\"storage_bytes\": 123456, \"indexes\": 2}'::jsonb, 'active')",
    )
    .bind(vm_id)
    .bind(format!(
        "retained-vm-{}.internal",
        &Uuid::new_v4().to_string()[..8]
    ))
    .execute(pool)
    .await
    .expect("seed retained vm_inventory row");

    sqlx::query(
        "INSERT INTO cold_snapshots \
            (id, customer_id, tenant_id, source_vm_id, object_key, size_bytes, checksum, status, \
             completed_at, expires_at) \
         VALUES ($1, $2, $3, $4, 'cold/retained/index.snapshot', 4096, \
                 'sha256:retained', 'completed', \
                 NOW() - INTERVAL '1 hour', NOW() + INTERVAL '30 days')",
    )
    .bind(cold_snapshot_id)
    .bind(customer.id)
    .bind(&tenant_id)
    .bind(vm_id)
    .execute(pool)
    .await
    .expect("seed retained cold_snapshots row");

    sqlx::query(
        "INSERT INTO customer_tenants \
            (customer_id, tenant_id, deployment_id, vm_id, tier, resource_quota, \
             last_accessed_at, cold_snapshot_id, service_type) \
         VALUES ($1, $2, $3, $4, 'cold', \
                 '{\"records\": 25000, \"storage_bytes\": 1048576}'::jsonb, \
                 NOW() - INTERVAL '2 days', $5, 'flapjack')",
    )
    .bind(customer.id)
    .bind(&tenant_id)
    .bind(deployment_id)
    .bind(vm_id)
    .bind(cold_snapshot_id)
    .execute(pool)
    .await
    .expect("seed retained customer_tenants row");

    seed_algolia_import_jobs(
        pool,
        customer.id,
        deployment_id,
        vm_id,
        lifecycle_generation,
    )
    .await;

    (deployment_id, vm_id, cold_snapshot_id)
}

async fn seed_algolia_import_jobs(
    pool: &PgPool,
    customer_id: Uuid,
    deployment_id: Uuid,
    vm_id: Uuid,
    lifecycle_generation: i64,
) {
    seed_queued_import_job(pool, customer_id, lifecycle_generation).await;
    seed_active_import_job(
        pool,
        customer_id,
        deployment_id,
        vm_id,
        lifecycle_generation,
    )
    .await;
    seed_failed_resumable_import_job(
        pool,
        customer_id,
        deployment_id,
        vm_id,
        lifecycle_generation,
    )
    .await;
    seed_acknowledged_terminal_import_job(
        pool,
        customer_id,
        deployment_id,
        vm_id,
        lifecycle_generation,
    )
    .await;
}

async fn seed_queued_import_job(pool: &PgPool, customer_id: Uuid, lifecycle_generation: i64) {
    sqlx::query(
        "INSERT INTO algolia_import_jobs \
            (customer_id, tenant_id, algolia_app_id, destination_kind, logical_target, \
             destination_region, source_name, lifecycle_generation, idempotency_key, \
             canonical_fingerprint, source_size_bytes, documents_expected, warnings) \
         VALUES ($1, 'queued_target', 'QUEUE01', 'create', 'queued_target', 'us-east-1', \
                 'queued_source', $2, $3, 'fingerprint-queued', 1024, 10, \
                 '[\"queued warning\"]'::jsonb)",
    )
    .bind(customer_id)
    .bind(lifecycle_generation)
    .bind(format!("queued-{}", Uuid::new_v4()))
    .execute(pool)
    .await
    .expect("seed queued Algolia import job");
}

async fn seed_active_import_job(
    pool: &PgPool,
    customer_id: Uuid,
    deployment_id: Uuid,
    vm_id: Uuid,
    lifecycle_generation: i64,
) {
    sqlx::query(
        "INSERT INTO algolia_import_jobs \
            (customer_id, tenant_id, algolia_app_id, destination_kind, logical_target, \
             destination_region, destination_deployment_id, destination_vm_id, physical_uid, \
             source_name, cloud_job_id, engine_job_id, dispatch_intent_state, lifecycle_generation, \
             idempotency_key, canonical_fingerprint, routing_identity, source_size_bytes, \
             reserved_index_count, reserved_customer_storage_bytes, \
             reserved_node_transient_bytes, worker_claimed_at, worker_lease_expires_at, \
             cancel_requested_at, documents_expected, documents_imported, settings_applied, \
             synonyms_expected, rules_expected, status, cleanup_phase) \
         VALUES ($1, 'active_target', 'ACTIVE01', 'replace', 'active_target', 'us-east-1', \
                 $2, $3, 'physical-active', 'active_source', $4, $5, 'committed', $6, $7, \
                 'fingerprint-active', 'route-active', 2048, 1, 2048, 512, NOW(), \
                 NOW() + INTERVAL '5 minutes', NOW() - INTERVAL '1 minute', 20, 7, 3, 4, 5, \
                 'copying_documents', 'public')",
    )
    .bind(customer_id)
    .bind(deployment_id)
    .bind(vm_id)
    .bind(Uuid::new_v4())
    .bind(Uuid::new_v4())
    .bind(lifecycle_generation)
    .bind(format!("active-{}", Uuid::new_v4()))
    .execute(pool)
    .await
    .expect("seed active Algolia import job");
}

async fn seed_failed_resumable_import_job(
    pool: &PgPool,
    customer_id: Uuid,
    deployment_id: Uuid,
    vm_id: Uuid,
    lifecycle_generation: i64,
) {
    sqlx::query(
        "INSERT INTO algolia_import_jobs \
            (customer_id, tenant_id, algolia_app_id, destination_kind, logical_target, \
             destination_region, destination_deployment_id, destination_vm_id, physical_uid, \
             source_name, engine_job_id, dispatch_intent_state, lifecycle_generation, \
             idempotency_key, canonical_fingerprint, routing_identity, source_size_bytes, \
             retryable, resume_intent_generation, resume_checkpoint, resume_deadline, \
             resume_status_observed_at, resumable, resume_count, documents_expected, \
             documents_imported, documents_rejected, settings_applied, settings_unsupported, \
             synonyms_expected, synonyms_imported, synonyms_rejected, rules_expected, \
             rules_imported, rules_rejected, warnings, error_code, error_message, status, \
             publication_disposition, engine_ack_state) \
         VALUES ($1, 'failed_target', 'FAILED01', 'replace', 'failed_target', 'us-east-1', \
                 $2, $3, 'physical-failed', 'failed_source', $4, 'committed', $5, $6, \
                 'fingerprint-failed', 'route-failed', 4096, TRUE, 3, 'checkpoint-failed', \
                 NOW() + INTERVAL '1 hour', NOW(), TRUE, 2, 30, 12, 1, 4, 2, 6, 3, 1, \
                 5, 2, 1, '[\"retryable warning\"]'::jsonb, 'internal', \
                 'retained failure details', 'failed', 'unchanged', 'pending')",
    )
    .bind(customer_id)
    .bind(deployment_id)
    .bind(vm_id)
    .bind(Uuid::new_v4())
    .bind(lifecycle_generation)
    .bind(format!("failed-{}", Uuid::new_v4()))
    .execute(pool)
    .await
    .expect("seed failed resumable Algolia import job");
}

async fn seed_acknowledged_terminal_import_job(
    pool: &PgPool,
    customer_id: Uuid,
    deployment_id: Uuid,
    vm_id: Uuid,
    lifecycle_generation: i64,
) {
    sqlx::query(
        "INSERT INTO algolia_import_jobs \
            (customer_id, tenant_id, algolia_app_id, destination_kind, logical_target, \
             destination_region, destination_deployment_id, destination_vm_id, physical_uid, \
             source_name, engine_job_id, dispatch_intent_state, lifecycle_generation, \
             idempotency_key, canonical_fingerprint, routing_identity, source_size_bytes, \
             documents_expected, documents_imported, settings_applied, synonyms_expected, \
             synonyms_imported, rules_expected, rules_imported, warnings, status, \
             publication_disposition, engine_ack_state, terminal_at) \
         VALUES ($1, 'completed_target', 'DONE001', 'replace', 'completed_target', 'us-east-1', \
                 $2, $3, 'physical-completed', 'completed_source', $4, 'committed', $5, $6, \
                 'fingerprint-completed', 'route-completed', 8192, 40, 40, 7, 8, 8, 9, 9, \
                 '[\"terminal warning\"]'::jsonb, 'completed_with_warnings', 'promoted', \
                 'acknowledged', NOW())",
    )
    .bind(customer_id)
    .bind(deployment_id)
    .bind(vm_id)
    .bind(Uuid::new_v4())
    .bind(lifecycle_generation)
    .bind(format!("completed-{}", Uuid::new_v4()))
    .execute(pool)
    .await
    .expect("seed acknowledged terminal Algolia import job");
}

async fn cleanup_soft_delete_recovery_evidence(pool: &PgPool, customer_id: Uuid, vm_id: Uuid) {
    sqlx::query("DELETE FROM algolia_import_jobs WHERE customer_id = $1")
        .bind(customer_id)
        .execute(pool)
        .await
        .ok();
    sqlx::query("DELETE FROM customer_tenants WHERE customer_id = $1")
        .bind(customer_id)
        .execute(pool)
        .await
        .ok();
    sqlx::query("DELETE FROM cold_snapshots WHERE customer_id = $1")
        .bind(customer_id)
        .execute(pool)
        .await
        .ok();
    sqlx::query("DELETE FROM customer_deployments WHERE customer_id = $1")
        .bind(customer_id)
        .execute(pool)
        .await
        .ok();
    sqlx::query("DELETE FROM vm_inventory WHERE id = $1")
        .bind(vm_id)
        .execute(pool)
        .await
        .ok();
    sqlx::query("DELETE FROM customers WHERE id = $1")
        .bind(customer_id)
        .execute(pool)
        .await
        .ok();
}

async fn force_deleted_at_for_ids(
    pool: &PgPool,
    ids: &[Uuid],
    deleted_at: chrono::DateTime<chrono::Utc>,
) {
    sqlx::query("UPDATE customers SET deleted_at = $1, updated_at = $1 WHERE id = ANY($2)")
        .bind(deleted_at)
        .bind(ids.to_vec())
        .execute(pool)
        .await
        .expect("force deleted_at fixture timestamp for deterministic tie-break test");
}

async fn force_customer_id(pool: &PgPool, original_id: Uuid, forced_id: Uuid) -> Uuid {
    sqlx::query("UPDATE customers SET id = $2 WHERE id = $1")
        .bind(original_id)
        .bind(forced_id)
        .execute(pool)
        .await
        .expect("force customer id fixture for deterministic ordering test");
    forced_id
}

async fn set_resend_verification_sent_at(
    pool: &PgPool,
    id: Uuid,
    resend_verification_sent_at: chrono::DateTime<chrono::Utc>,
) -> chrono::DateTime<chrono::Utc> {
    sqlx::query_scalar(
        "UPDATE customers \
         SET resend_verification_sent_at = $2, updated_at = NOW() \
         WHERE id = $1 \
         RETURNING resend_verification_sent_at",
    )
    .bind(id)
    .bind(resend_verification_sent_at)
    .fetch_one(pool)
    .await
    .expect("seed resend_verification_sent_at fixture timestamp")
}

async fn set_resend_password_reset_sent_at(
    pool: &PgPool,
    id: Uuid,
    resend_password_reset_sent_at: chrono::DateTime<chrono::Utc>,
) -> chrono::DateTime<chrono::Utc> {
    sqlx::query_scalar(
        "UPDATE customers \
         SET resend_password_reset_sent_at = $2, updated_at = NOW() \
         WHERE id = $1 \
         RETURNING resend_password_reset_sent_at",
    )
    .bind(id)
    .bind(resend_password_reset_sent_at)
    .fetch_one(pool)
    .await
    .expect("seed resend_password_reset_sent_at fixture timestamp")
}

#[tokio::test]
async fn subscription_cycle_anchor_round_trip_and_clear_with_none() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let email = format!(
        "anchor-roundtrip-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let customer = repo
        .create("Anchor Roundtrip", &email)
        .await
        .expect("create customer");
    let first_anchor = postgres_timestamp(chrono::Utc::now());

    let set_result = repo
        .set_subscription_cycle_anchor(customer.id, Some(first_anchor))
        .await
        .expect("set initial subscription anchor");
    assert!(
        set_result,
        "setting anchor should update active customer rows"
    );

    let after_set = repo
        .find_by_id(customer.id)
        .await
        .expect("find customer after anchor set")
        .expect("customer should exist after anchor set");
    assert_eq!(
        after_set.subscription_cycle_anchor_at,
        Some(first_anchor),
        "anchor setter must persist the exact timestamp"
    );

    let clear_result = repo
        .set_subscription_cycle_anchor(customer.id, None)
        .await
        .expect("clear subscription anchor");
    assert!(
        clear_result,
        "clearing anchor should update active customer rows"
    );

    let after_clear = repo
        .find_by_id(customer.id)
        .await
        .expect("find customer after anchor clear")
        .expect("customer should exist after anchor clear");
    assert_eq!(
        after_clear.subscription_cycle_anchor_at, None,
        "anchor setter must clear the persisted value when None is provided"
    );

    cleanup_customer(&pool, &email).await;
}

#[tokio::test]
async fn try_upgrade_to_shared_atomic_allows_exactly_one_concurrent_winner() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let email = format!(
        "atomic-upgrade-race-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let customer = repo
        .create("Atomic Upgrade Race", &email)
        .await
        .expect("create customer");
    let base_anchor = postgres_timestamp(chrono::Utc::now());
    let mut join_handles = Vec::new();
    for offset_ms in 0_i64..8_i64 {
        let pooled_repo = PgCustomerRepo::new(pool.clone());
        let candidate_anchor = base_anchor + chrono::Duration::milliseconds(offset_ms);
        join_handles.push(tokio::spawn(async move {
            let won = pooled_repo
                .try_upgrade_to_shared_atomic(customer.id, candidate_anchor)
                .await
                .expect("attempt atomic free-to-shared upgrade");
            (candidate_anchor, won)
        }));
    }

    let mut winning_anchor: Option<chrono::DateTime<chrono::Utc>> = None;
    let mut winner_count = 0_usize;
    for handle in join_handles {
        let (candidate_anchor, won) = handle
            .await
            .expect("join concurrent atomic-upgrade attempt");
        if won {
            winner_count += 1;
            winning_anchor = Some(candidate_anchor);
        }
    }

    assert_eq!(
        winner_count, 1,
        "compare-and-set upgrade seam must allow exactly one winner under concurrency"
    );

    let upgraded_customer = repo
        .find_by_id(customer.id)
        .await
        .expect("find customer after concurrent upgrade race")
        .expect("customer should still exist after concurrent upgrade race");
    assert_eq!(
        upgraded_customer.billing_plan, "shared",
        "winning atomic update must persist shared plan"
    );
    assert_eq!(
        upgraded_customer.subscription_cycle_anchor_at, winning_anchor,
        "winning atomic update must persist the winner's anchor timestamp"
    );

    cleanup_customer(&pool, &email).await;
}

#[tokio::test]
async fn try_upgrade_to_shared_atomic_returns_false_without_mutation_for_shared_or_deleted_rows() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());

    let already_shared_email = format!(
        "atomic-upgrade-shared-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );
    let deleted_email = format!(
        "atomic-upgrade-deleted-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );
    let already_shared = repo
        .create("Already Shared", &already_shared_email)
        .await
        .expect("create already-shared fixture");
    let deleted = repo
        .create("Deleted Fixture", &deleted_email)
        .await
        .expect("create deleted fixture");

    let preexisting_anchor = postgres_timestamp(chrono::Utc::now() - chrono::Duration::hours(6));
    repo.set_billing_plan(already_shared.id, "shared")
        .await
        .expect("set already-shared plan fixture");
    repo.set_subscription_cycle_anchor(already_shared.id, Some(preexisting_anchor))
        .await
        .expect("seed already-shared anchor fixture");
    repo.soft_delete(deleted.id)
        .await
        .expect("soft-delete deleted fixture");

    let shared_attempt_anchor = chrono::Utc::now();
    let shared_attempt = repo
        .try_upgrade_to_shared_atomic(already_shared.id, shared_attempt_anchor)
        .await
        .expect("attempt atomic upgrade on already-shared row");
    assert!(
        !shared_attempt,
        "atomic upgrade should return false when row is already shared"
    );
    let already_shared_after = repo
        .find_by_id(already_shared.id)
        .await
        .expect("reload already-shared row")
        .expect("already-shared row should still exist");
    assert_eq!(
        already_shared_after.billing_plan, "shared",
        "failed upgrade attempt must not change already-shared billing plan"
    );
    assert_eq!(
        already_shared_after.subscription_cycle_anchor_at,
        Some(preexisting_anchor),
        "failed upgrade attempt must preserve existing anchor on already-shared row"
    );

    let deleted_attempt = repo
        .try_upgrade_to_shared_atomic(deleted.id, chrono::Utc::now())
        .await
        .expect("attempt atomic upgrade on deleted row");
    assert!(
        !deleted_attempt,
        "atomic upgrade should return false when row is soft-deleted"
    );
    let deleted_after = repo
        .find_by_id(deleted.id)
        .await
        .expect("reload deleted row")
        .expect("deleted row should still exist as retained row");
    assert_eq!(deleted_after.status, "deleted");
    assert_eq!(
        deleted_after.billing_plan, "free",
        "failed upgrade on deleted row must not mutate billing plan"
    );
    assert_eq!(
        deleted_after.subscription_cycle_anchor_at, None,
        "failed upgrade on deleted row must not set anchor"
    );

    cleanup_customer(&pool, &already_shared_email).await;
    cleanup_customer(&pool, &deleted_email).await;
}

#[tokio::test]
async fn claim_ingest_quota_warning_is_monthly_per_metric_and_atomic() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let email = format!(
        "quota-warning-claim-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let customer = repo
        .create("Quota Warning Claim", &email)
        .await
        .expect("create customer");

    let first_records_claim = repo
        .claim_ingest_quota_warning_for_month(
            customer.id,
            IngestQuotaWarningMetric::Records,
            2026,
            5,
        )
        .await
        .expect("first records warning claim");
    assert!(
        first_records_claim,
        "first claim for metric/month should succeed"
    );

    let duplicate_records_claim = repo
        .claim_ingest_quota_warning_for_month(
            customer.id,
            IngestQuotaWarningMetric::Records,
            2026,
            5,
        )
        .await
        .expect("duplicate records warning claim");
    assert!(
        !duplicate_records_claim,
        "duplicate claim for same metric/month should fail atomically"
    );

    let storage_claim_same_month = repo
        .claim_ingest_quota_warning_for_month(
            customer.id,
            IngestQuotaWarningMetric::StorageMb,
            2026,
            5,
        )
        .await
        .expect("storage warning claim in same month");
    assert!(
        storage_claim_same_month,
        "different metric in same month should claim independently"
    );

    let next_month_records_claim = repo
        .claim_ingest_quota_warning_for_month(
            customer.id,
            IngestQuotaWarningMetric::Records,
            2026,
            6,
        )
        .await
        .expect("records warning claim in next month");
    assert!(
        next_month_records_claim,
        "same metric should claim again next month"
    );

    let sent_for_may_records = repo
        .ingest_quota_warning_sent_for_month(
            customer.id,
            IngestQuotaWarningMetric::Records,
            2026,
            5,
        )
        .await
        .expect("read records warning state for may");
    assert!(
        !sent_for_may_records,
        "recorded month should move forward after next-month claim"
    );

    let sent_for_june_records = repo
        .ingest_quota_warning_sent_for_month(
            customer.id,
            IngestQuotaWarningMetric::Records,
            2026,
            6,
        )
        .await
        .expect("read records warning state for june");
    assert!(
        sent_for_june_records,
        "latest claimed month should be readable for matching metric"
    );

    let sent_for_may_storage = repo
        .ingest_quota_warning_sent_for_month(
            customer.id,
            IngestQuotaWarningMetric::StorageMb,
            2026,
            5,
        )
        .await
        .expect("read storage warning state for may");
    assert!(
        sent_for_may_storage,
        "storage warning state should remain independent from records state"
    );

    cleanup_customer(&pool, &email).await;
}

#[tokio::test]
async fn rollback_ingest_quota_warning_reopens_same_month_claim() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let email = format!(
        "quota-warning-rollback-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let customer = repo
        .create("Quota Warning Rollback", &email)
        .await
        .expect("create customer");

    assert!(
        repo.claim_ingest_quota_warning_for_month(
            customer.id,
            IngestQuotaWarningMetric::Records,
            2026,
            5,
        )
        .await
        .expect("initial claim"),
        "initial claim should reserve the records warning slot"
    );

    assert!(
        repo.rollback_ingest_quota_warning_for_month(
            customer.id,
            IngestQuotaWarningMetric::Records,
            2026,
            5,
        )
        .await
        .expect("rollback claim"),
        "rollback should clear the current month reservation"
    );

    assert!(
        !repo
            .ingest_quota_warning_sent_for_month(
                customer.id,
                IngestQuotaWarningMetric::Records,
                2026,
                5,
            )
            .await
            .expect("read rolled back month state"),
        "rolled back month should no longer appear claimed"
    );

    assert!(
        repo.claim_ingest_quota_warning_for_month(
            customer.id,
            IngestQuotaWarningMetric::Records,
            2026,
            5,
        )
        .await
        .expect("reclaim same month"),
        "same month should become claimable again after rollback"
    );

    cleanup_customer(&pool, &email).await;
}

#[tokio::test]
async fn create_customer_has_zero_carryforward() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let email = format!(
        "cf-test-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let customer = repo
        .create("CF Test", &email)
        .await
        .expect("create customer");
    assert_eq!(
        customer.object_storage_egress_carryforward_cents,
        Decimal::ZERO,
        "new customer carry-forward must default to zero"
    );

    cleanup_customer(&pool, &email).await;
}

#[tokio::test]
async fn create_with_password_has_zero_carryforward() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let email = format!(
        "cfpw-test-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let customer = repo
        .create_with_password("CF PW Test", &email, "$argon2id$test_hash")
        .await
        .expect("create customer with password");
    assert_eq!(
        customer.object_storage_egress_carryforward_cents,
        Decimal::ZERO,
    );

    cleanup_customer(&pool, &email).await;
}

#[tokio::test]
async fn set_and_read_carryforward_round_trips() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let email = format!(
        "cfrt-test-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let customer = repo.create("CF Round-Trip", &email).await.expect("create");

    // Set a sub-cent carry-forward value
    let ok = repo
        .set_object_storage_egress_carryforward_cents(customer.id, dec!(0.3712))
        .await
        .expect("set carryforward");
    assert!(ok, "setter should return true for existing active customer");

    // Read it back via find_by_id
    let updated = repo
        .find_by_id(customer.id)
        .await
        .expect("find_by_id")
        .expect("customer must exist");
    assert_eq!(
        updated.object_storage_egress_carryforward_cents,
        dec!(0.3712),
        "carry-forward must round-trip through Postgres"
    );

    // Also verify find_by_email sees the same value
    let by_email = repo
        .find_by_email(&email)
        .await
        .expect("find_by_email")
        .expect("customer must exist");
    assert_eq!(
        by_email.object_storage_egress_carryforward_cents,
        dec!(0.3712),
    );

    cleanup_customer(&pool, &email).await;
}

#[tokio::test]
async fn set_carryforward_on_deleted_customer_returns_false() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let email = format!(
        "cfdel-test-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let customer = repo.create("CF Deleted", &email).await.expect("create");
    repo.soft_delete(customer.id).await.expect("soft_delete");

    let ok = repo
        .set_object_storage_egress_carryforward_cents(customer.id, dec!(1.5))
        .await
        .expect("set carryforward on deleted");
    assert!(!ok, "setter must return false for deleted customer");

    cleanup_customer(&pool, &email).await;
}

#[tokio::test]
async fn resend_verification_cooldown_persists_across_repo_reload() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let first_repo = PgCustomerRepo::new(pool.clone());
    let email = format!(
        "resend-cooldown-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let customer = first_repo
        .create("Resend Cooldown", &email)
        .await
        .expect("create customer");

    let first_outcome = first_repo
        .rotate_email_verification_token_with_resend_cooldown(
            customer.id,
            "first-token",
            chrono::Utc::now() + chrono::Duration::hours(24),
        )
        .await
        .expect("first resend token rotation");
    assert!(
        matches!(first_outcome, ResendVerificationOutcome::Allowed { .. }),
        "first resend should be allowed"
    );

    let customer_after_first_send = first_repo
        .find_by_id(customer.id)
        .await
        .expect("reload customer after first resend")
        .expect("customer should exist");
    assert_eq!(
        customer_after_first_send.email_verify_token.as_deref(),
        Some("first-token"),
        "first resend should persist the token on the customer row"
    );
    assert!(
        customer_after_first_send
            .resend_verification_sent_at
            .is_some(),
        "first resend should stamp cooldown state on the customer row"
    );

    let reloaded_repo = PgCustomerRepo::new(pool.clone());
    let second_outcome = reloaded_repo
        .rotate_email_verification_token_with_resend_cooldown(
            customer.id,
            "second-token",
            chrono::Utc::now() + chrono::Duration::hours(24),
        )
        .await
        .expect("second resend token rotation");

    match second_outcome {
        ResendVerificationOutcome::CooldownActive {
            retry_after_seconds,
        } => {
            assert!(
                (1..=60).contains(&retry_after_seconds),
                "retry_after_seconds should stay within the 60-second cooldown window"
            );
        }
        unexpected => panic!(
            "immediate second resend after repo reload should be blocked by cooldown, got {unexpected:?}"
        ),
    }

    let customer_after_second_attempt = reloaded_repo
        .find_by_id(customer.id)
        .await
        .expect("reload customer after blocked resend")
        .expect("customer should exist");
    assert_eq!(
        customer_after_second_attempt.email_verify_token.as_deref(),
        Some("first-token"),
        "blocked resend must not rotate the token again"
    );

    cleanup_customer(&pool, &email).await;
}

#[tokio::test]
async fn rollback_resend_verification_restores_previous_token_and_cooldown_state() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let email = format!(
        "resend-rollback-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let customer = repo
        .create("Resend Rollback", &email)
        .await
        .expect("create customer");
    let previous_expiry = postgres_timestamp(chrono::Utc::now() + chrono::Duration::hours(24));
    let historical_cooldown_timestamp = chrono::Utc::now()
        - chrono::Duration::seconds(api::repos::RESEND_VERIFICATION_COOLDOWN_SECONDS + 5);
    let previous_token = "last-deliverable-token";
    let reserved_token = "reserved-token";

    let seeded = repo
        .set_email_verify_token(customer.id, previous_token, previous_expiry)
        .await
        .expect("seed last deliverable token");
    assert!(seeded, "fixture seed should update an active customer");
    let seeded_cooldown_timestamp =
        set_resend_verification_sent_at(&pool, customer.id, historical_cooldown_timestamp).await;

    let reservation = match repo
        .rotate_email_verification_token_with_resend_cooldown(
            customer.id,
            reserved_token,
            chrono::Utc::now() + chrono::Duration::hours(24),
        )
        .await
        .expect("reserve resend token")
    {
        ResendVerificationOutcome::Allowed { reservation } => reservation,
        unexpected => panic!("first resend reservation should be allowed, got {unexpected:?}"),
    };
    assert_eq!(
        reservation.previous_resend_verification_sent_at,
        Some(seeded_cooldown_timestamp),
        "reservation should carry the prior non-NULL cooldown timestamp for rollback"
    );
    assert!(
        reservation.reserved_resend_verification_sent_at
            > reservation
                .previous_resend_verification_sent_at
                .unwrap_or(chrono::DateTime::<chrono::Utc>::MIN_UTC),
        "reservation should stamp a fresh resend cooldown timestamp"
    );

    let rolled_back = repo
        .rollback_resend_verification_token_rotation(customer.id, reserved_token, &reservation)
        .await
        .expect("rollback resend reservation");
    assert!(
        rolled_back,
        "rollback should restore prior values when reservation still matches"
    );

    let after_rollback = repo
        .find_by_id(customer.id)
        .await
        .expect("load customer after rollback")
        .expect("customer should exist");
    assert_eq!(
        after_rollback.email_verify_token.as_deref(),
        Some(previous_token),
        "rollback should restore the last deliverable token"
    );
    assert_eq!(
        after_rollback.email_verify_expires_at,
        Some(previous_expiry),
        "rollback should restore the prior token expiry"
    );
    assert_eq!(
        after_rollback.resend_verification_sent_at,
        reservation.previous_resend_verification_sent_at,
        "rollback should restore the previous cooldown timestamp"
    );

    let immediate_retry = repo
        .rotate_email_verification_token_with_resend_cooldown(
            customer.id,
            "retry-token-after-rollback",
            chrono::Utc::now() + chrono::Duration::hours(24),
        )
        .await
        .expect("retry resend after rollback");
    assert!(
        matches!(immediate_retry, ResendVerificationOutcome::Allowed { .. }),
        "customer should be able to retry immediately after rollback"
    );

    cleanup_customer(&pool, &email).await;
}

#[tokio::test]
async fn resend_password_reset_cooldown_persists_across_repo_reload() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let first_repo = PgCustomerRepo::new(pool.clone());
    let email = format!(
        "resend-password-reset-cooldown-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let customer = first_repo
        .create("Resend Password Reset Cooldown", &email)
        .await
        .expect("create customer");

    let first_outcome = first_repo
        .rotate_password_reset_token_with_resend_cooldown(
            customer.id,
            "first-reset-token",
            chrono::Utc::now() + chrono::Duration::hours(1),
        )
        .await
        .expect("first password reset resend token rotation");
    assert!(
        matches!(
            first_outcome,
            api::repos::ResendPasswordResetOutcome::Allowed { .. }
        ),
        "first reset resend should be allowed"
    );

    let customer_after_first_send = first_repo
        .find_by_id(customer.id)
        .await
        .expect("reload customer after first reset resend")
        .expect("customer should exist");
    assert_eq!(
        customer_after_first_send.password_reset_token.as_deref(),
        Some("first-reset-token"),
        "first reset resend should persist the token on the customer row"
    );
    assert!(
        customer_after_first_send
            .resend_password_reset_sent_at
            .is_some(),
        "first reset resend should stamp cooldown state on the customer row"
    );

    let reloaded_repo = PgCustomerRepo::new(pool.clone());
    let second_outcome = reloaded_repo
        .rotate_password_reset_token_with_resend_cooldown(
            customer.id,
            "second-reset-token",
            chrono::Utc::now() + chrono::Duration::hours(1),
        )
        .await
        .expect("second password reset resend token rotation");

    match second_outcome {
        api::repos::ResendPasswordResetOutcome::CooldownActive {
            retry_after_seconds,
        } => {
            assert!(
                (1..=60).contains(&retry_after_seconds),
                "retry_after_seconds should stay within the 60-second cooldown window"
            );
        }
        unexpected => panic!(
            "immediate second reset resend after repo reload should be blocked by cooldown, got {unexpected:?}"
        ),
    }

    let customer_after_second_attempt = reloaded_repo
        .find_by_id(customer.id)
        .await
        .expect("reload customer after blocked reset resend")
        .expect("customer should exist");
    assert_eq!(
        customer_after_second_attempt
            .password_reset_token
            .as_deref(),
        Some("first-reset-token"),
        "blocked reset resend must not rotate the token again"
    );

    cleanup_customer(&pool, &email).await;
}

#[tokio::test]
async fn rollback_password_reset_resend_restores_previous_token_and_cooldown_state() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let email = format!(
        "resend-password-reset-rollback-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let customer = repo
        .create_with_password("Resend Reset Rollback", &email, "$argon2id$seed")
        .await
        .expect("create customer");
    let previous_expiry = postgres_timestamp(chrono::Utc::now() + chrono::Duration::hours(1));
    let historical_cooldown_timestamp = chrono::Utc::now()
        - chrono::Duration::seconds(api::repos::RESEND_VERIFICATION_COOLDOWN_SECONDS + 5);
    let previous_token = "deliverable-reset-token";
    let reserved_token = "reserved-reset-token";

    let seeded = repo
        .set_password_reset_token(customer.id, previous_token, previous_expiry)
        .await
        .expect("seed last deliverable reset token");
    assert!(seeded, "fixture seed should update an active customer");
    let seeded_cooldown_timestamp =
        set_resend_password_reset_sent_at(&pool, customer.id, historical_cooldown_timestamp).await;

    let reservation = match repo
        .rotate_password_reset_token_with_resend_cooldown(
            customer.id,
            reserved_token,
            chrono::Utc::now() + chrono::Duration::hours(1),
        )
        .await
        .expect("reserve password reset resend token")
    {
        api::repos::ResendPasswordResetOutcome::Allowed { reservation } => reservation,
        unexpected => {
            panic!("first password reset reservation should be allowed, got {unexpected:?}")
        }
    };
    assert_eq!(
        reservation.previous_password_reset_sent_at,
        Some(seeded_cooldown_timestamp),
        "reservation should carry the prior non-NULL password-reset cooldown timestamp for rollback"
    );
    assert!(
        reservation.reserved_password_reset_sent_at
            > reservation
                .previous_password_reset_sent_at
                .unwrap_or(chrono::DateTime::<chrono::Utc>::MIN_UTC),
        "reservation should stamp a fresh password-reset resend cooldown timestamp"
    );

    let rolled_back = repo
        .rollback_password_reset_token_rotation(customer.id, reserved_token, &reservation)
        .await
        .expect("rollback password reset resend reservation");
    assert!(
        rolled_back,
        "rollback should restore prior values when password-reset reservation still matches"
    );

    let after_rollback = repo
        .find_by_id(customer.id)
        .await
        .expect("load customer after rollback")
        .expect("customer should exist");
    assert_eq!(
        after_rollback.password_reset_token.as_deref(),
        Some(previous_token),
        "rollback should restore the last deliverable reset token"
    );
    assert_eq!(
        after_rollback.password_reset_expires_at,
        Some(previous_expiry),
        "rollback should restore the prior reset token expiry"
    );
    assert_eq!(
        after_rollback.resend_password_reset_sent_at, reservation.previous_password_reset_sent_at,
        "rollback should restore the previous password-reset cooldown timestamp"
    );

    let immediate_retry = repo
        .rotate_password_reset_token_with_resend_cooldown(
            customer.id,
            "retry-reset-token-after-rollback",
            chrono::Utc::now() + chrono::Duration::hours(1),
        )
        .await
        .expect("retry password reset resend after rollback");
    assert!(
        matches!(
            immediate_retry,
            api::repos::ResendPasswordResetOutcome::Allowed { .. }
        ),
        "customer should be able to retry password-reset resend immediately after rollback"
    );

    cleanup_customer(&pool, &email).await;
}

#[tokio::test]
async fn soft_delete_retains_row_and_is_idempotent() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let email = format!(
        "soft-delete-test-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let customer = repo
        .create_with_password("Soft Delete Test", &email, "$argon2id$integration_hash")
        .await
        .expect("create customer");

    let first_delete = repo
        .soft_delete(customer.id)
        .await
        .expect("first soft_delete");
    assert!(first_delete, "first soft_delete should return true");

    let first_delete_metadata = fetch_customer_deletion_metadata(&pool, customer.id).await;
    let first_deleted_at = first_delete_metadata
        .deleted_at
        .expect("first soft_delete should stamp deleted_at for retained-row metadata");
    assert_eq!(
        first_deleted_at, first_delete_metadata.updated_at,
        "first soft_delete should stamp deleted_at and updated_at together"
    );

    let retained_customer = repo
        .find_by_id(customer.id)
        .await
        .expect("find_by_id after soft_delete")
        .expect("soft-deleted row should still be retained");
    assert_eq!(retained_customer.status, "deleted");
    assert_eq!(retained_customer.email, email);

    let second_delete = repo
        .soft_delete(customer.id)
        .await
        .expect("second soft_delete");
    assert!(
        !second_delete,
        "second soft_delete should return false for an already-deleted row"
    );

    let second_delete_metadata = fetch_customer_deletion_metadata(&pool, customer.id).await;
    assert_eq!(
        second_delete_metadata.deleted_at,
        Some(first_deleted_at),
        "second soft_delete must be idempotent and not re-stamp deleted_at"
    );
    assert_eq!(
        second_delete_metadata.updated_at, first_delete_metadata.updated_at,
        "second soft_delete must not change updated_at once the row is already deleted"
    );

    cleanup_customer(&pool, &email).await;
}

#[tokio::test]
async fn soft_delete_increments_lifecycle_generation_exactly_once() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_customer_lifecycle_generation").await
    else {
        return;
    };
    let repo = PgCustomerRepo::new(db.pool.clone());
    let email = format!("lifecycle-generation-{}@integration.test", Uuid::new_v4());
    let customer = repo
        .create("Lifecycle Generation", &email)
        .await
        .expect("create lifecycle customer");

    assert_eq!(customer.lifecycle_generation, 1);
    assert!(repo.soft_delete(customer.id).await.expect("soft delete"));
    let after_first = repo
        .find_by_id(customer.id)
        .await
        .expect("reload deleted customer")
        .expect("soft delete retains customer");
    assert_eq!(after_first.lifecycle_generation, 2);

    assert!(!repo
        .soft_delete(customer.id)
        .await
        .expect("repeat soft delete"));
    let after_repeat = repo
        .find_by_id(customer.id)
        .await
        .expect("reload repeated delete")
        .expect("repeated soft delete retains customer");
    assert_eq!(after_repeat.lifecycle_generation, 2);

    cleanup_customer(&db.pool, &email).await;
}

#[tokio::test]
async fn soft_delete_preserves_recovery_evidence_and_generation_fence() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_soft_delete_recovery_evidence").await
    else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let email = format!("soft-delete-evidence-{}@integration.test", Uuid::new_v4());
    let initial_generation = 41_i64;
    let customer = repo
        .create_with_password("Soft Delete Evidence", &email, "$argon2id$integration_hash")
        .await
        .expect("create retained-evidence customer");

    sqlx::query("UPDATE customers SET lifecycle_generation = $2 WHERE id = $1")
        .bind(customer.id)
        .bind(initial_generation)
        .execute(&pool)
        .await
        .expect("seed explicit lifecycle generation");

    let (_deployment_id, vm_id, _cold_snapshot_id) =
        seed_soft_delete_recovery_evidence(&pool, &customer, initial_generation).await;
    let customer_before_delete = fetch_customer_lifecycle_snapshot(&pool, customer.id).await;
    let evidence_before_delete = fetch_retained_evidence_snapshot(&pool, customer.id).await;

    assert_eq!(
        customer_before_delete.lifecycle_generation,
        initial_generation
    );
    assert_algolia_recovery_metadata_seeded(&evidence_before_delete);
    assert!(
        repo.soft_delete(customer.id)
            .await
            .expect("first soft_delete"),
        "first soft_delete should report that it changed the active customer row"
    );

    let customer_after_delete = fetch_customer_lifecycle_snapshot(&pool, customer.id).await;
    let evidence_after_delete = fetch_retained_evidence_snapshot(&pool, customer.id).await;
    assert_eq!(customer_after_delete.id, customer_before_delete.id);
    assert_eq!(customer_after_delete.email, customer_before_delete.email);
    assert_eq!(
        customer_after_delete.created_at,
        customer_before_delete.created_at
    );
    assert_eq!(customer_after_delete.status, "deleted");
    assert_eq!(
        customer_after_delete.lifecycle_generation,
        initial_generation + 1
    );
    let first_deleted_at = customer_after_delete
        .deleted_at
        .expect("first soft_delete should stamp deleted_at");
    assert_eq!(
        customer_after_delete.updated_at, first_deleted_at,
        "first soft_delete should stamp updated_at and deleted_at together"
    );
    assert_ne!(
        customer_after_delete.updated_at,
        customer_before_delete.updated_at
    );
    assert_eq!(
        evidence_after_delete, evidence_before_delete,
        "soft_delete must preserve catalog, snapshot, VM, deployment, and import evidence"
    );

    assert!(
        !repo
            .soft_delete(customer.id)
            .await
            .expect("repeat soft_delete"),
        "repeat soft_delete should report that no active row was changed"
    );
    let customer_after_repeat = fetch_customer_lifecycle_snapshot(&pool, customer.id).await;
    let evidence_after_repeat = fetch_retained_evidence_snapshot(&pool, customer.id).await;
    assert_eq!(customer_after_repeat, customer_after_delete);
    assert_eq!(evidence_after_repeat, evidence_before_delete);

    cleanup_soft_delete_recovery_evidence(&pool, customer.id, vm_id).await;
}

#[tokio::test]
async fn reactivation_preserves_lifecycle_generation() {
    let Some(db) =
        pg_schema_harness::connect_and_migrate("it_customer_reactivation_generation").await
    else {
        return;
    };
    let repo = PgCustomerRepo::new(db.pool.clone());
    let email = format!(
        "reactivation-generation-{}@integration.test",
        Uuid::new_v4()
    );
    let customer = repo
        .create("Reactivation Generation", &email)
        .await
        .expect("create lifecycle customer");
    sqlx::query("UPDATE customers SET lifecycle_generation = 7 WHERE id = $1")
        .bind(customer.id)
        .execute(&db.pool)
        .await
        .expect("seed established lifecycle generation");

    assert!(repo.suspend(customer.id).await.expect("suspend customer"));
    assert!(repo
        .reactivate(customer.id)
        .await
        .expect("reactivate customer"));
    let reactivated = repo
        .find_by_id(customer.id)
        .await
        .expect("reload reactivated customer")
        .expect("reactivated customer remains present");
    assert_eq!(reactivated.lifecycle_generation, 7);

    cleanup_customer(&db.pool, &email).await;
}

#[tokio::test]
async fn deleted_customer_cutoff_selector_filters_and_orders_by_deleted_at_then_id() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let first_deleted_email = format!(
        "soft-delete-cutoff-first-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );
    let second_deleted_email = format!(
        "soft-delete-cutoff-second-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );
    let active_email = format!(
        "soft-delete-cutoff-active-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let first_deleted = repo
        .create("Cutoff First", &first_deleted_email)
        .await
        .expect("create first deleted customer");
    let second_deleted = repo
        .create("Cutoff Second", &second_deleted_email)
        .await
        .expect("create second deleted customer");
    let active_customer = repo
        .create("Cutoff Active", &active_email)
        .await
        .expect("create active customer");

    repo.soft_delete(first_deleted.id)
        .await
        .expect("soft delete first customer");
    tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    repo.soft_delete(second_deleted.id)
        .await
        .expect("soft delete second customer");

    let cutoff = postgres_timestamp(chrono::Utc::now() - chrono::Duration::days(30));
    let later_deleted_at = cutoff + chrono::Duration::seconds(1);
    force_deleted_at_for_ids(&pool, &[first_deleted.id], cutoff).await;
    force_deleted_at_for_ids(&pool, &[second_deleted.id], later_deleted_at).await;

    let at_first_cutoff = repo
        .list_deleted_before_cutoff(cutoff)
        .await
        .expect("list deleted at inclusive cutoff");
    assert_eq!(
        at_first_cutoff.iter().map(|row| row.id).collect::<Vec<_>>(),
        vec![first_deleted.id],
        "cutoff selector must include rows exactly at the cutoff and exclude later deleted rows"
    );
    assert_eq!(
        at_first_cutoff[0].deleted_at,
        Some(cutoff),
        "inclusive cutoff row should project the exact deleted_at fixture timestamp"
    );
    assert!(
        at_first_cutoff
            .iter()
            .all(|row| row.id != second_deleted.id && row.id != active_customer.id),
        "first cutoff must exclude the later deleted row and the active row"
    );

    let at_second_cutoff = repo
        .list_deleted_before_cutoff(later_deleted_at)
        .await
        .expect("list deleted at later cutoff");
    assert_eq!(
        at_second_cutoff
            .iter()
            .map(|row| row.id)
            .collect::<Vec<_>>(),
        vec![first_deleted.id, second_deleted.id],
        "selector should deterministically order by deleted_at ASC, id ASC"
    );
    assert_eq!(
        at_second_cutoff
            .iter()
            .map(|row| row.deleted_at)
            .collect::<Vec<_>>(),
        vec![Some(cutoff), Some(later_deleted_at)],
        "later cutoff should include both deleted rows with their exact retention timestamps"
    );
    assert!(
        at_second_cutoff
            .iter()
            .all(|row| row.id != active_customer.id),
        "selector must never include active customers"
    );
    assert!(
        at_second_cutoff.iter().all(|row| row.deleted_at.is_some()),
        "selector should only include rows with deleted_at populated"
    );
    assert!(
        at_second_cutoff[0].deleted_at <= at_second_cutoff[1].deleted_at,
        "selector output must be monotonic by deleted_at"
    );

    cleanup_customer(&pool, &first_deleted_email).await;
    cleanup_customer(&pool, &second_deleted_email).await;
    cleanup_customer(&pool, &active_email).await;
}

#[tokio::test]
async fn deleted_customer_cutoff_selector_tie_breaks_equal_deleted_at_by_id() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let first_deleted_email = format!(
        "soft-delete-cutoff-tie-first-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );
    let second_deleted_email = format!(
        "soft-delete-cutoff-tie-second-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let first_deleted = repo
        .create("Cutoff Tie First", &first_deleted_email)
        .await
        .expect("create first deleted customer");
    let second_deleted = repo
        .create("Cutoff Tie Second", &second_deleted_email)
        .await
        .expect("create second deleted customer");
    let first_deleted_id = force_customer_id(
        &pool,
        first_deleted.id,
        Uuid::parse_str("ffffffff-ffff-ffff-ffff-ffffffffffff").expect("valid high fixture uuid"),
    )
    .await;
    let second_deleted_id = force_customer_id(
        &pool,
        second_deleted.id,
        Uuid::parse_str("00000000-0000-0000-0000-000000000001").expect("valid low fixture uuid"),
    )
    .await;

    repo.soft_delete(first_deleted_id)
        .await
        .expect("soft delete first customer");
    repo.soft_delete(second_deleted_id)
        .await
        .expect("soft delete second customer");

    let shared_deleted_at = postgres_timestamp(chrono::Utc::now());
    force_deleted_at_for_ids(
        &pool,
        &[first_deleted_id, second_deleted_id],
        shared_deleted_at,
    )
    .await;

    let tied_rows = repo
        .list_deleted_before_cutoff(shared_deleted_at)
        .await
        .expect("list deleted rows at tie cutoff");
    assert_eq!(
        tied_rows.len(),
        2,
        "selector should return exactly the two seeded deleted rows for the tie case"
    );
    assert_eq!(
        tied_rows.iter().map(|row| row.id).collect::<Vec<_>>(),
        vec![second_deleted_id, first_deleted_id],
        "when deleted_at timestamps are equal, selector must tie-break by id ASC, not creation order"
    );
    let tied_deleted_ats: Vec<_> = tied_rows
        .iter()
        .map(|row| row.deleted_at.expect("deleted rows must carry deleted_at"))
        .collect();
    assert!(
        tied_deleted_ats[0] == tied_deleted_ats[1],
        "fixture override should create an equal deleted_at tie for all selected rows"
    );

    cleanup_customer(&pool, &first_deleted_email).await;
    cleanup_customer(&pool, &second_deleted_email).await;
}

#[tokio::test]
async fn list_aggregates_billing_health_inputs_without_duplicate_customer_rows() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let first_email = format!(
        "list-health-first-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );
    let second_email = format!(
        "list-health-second-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let first = repo
        .create("List Health First", &first_email)
        .await
        .expect("create first customer");
    let second = repo
        .create("List Health Second", &second_email)
        .await
        .expect("create second customer");

    let first_deployment_id = Uuid::new_v4();
    let second_deployment_id = Uuid::new_v4();
    let first_short = &first.id.to_string()[..8];
    let second_short = &second.id.to_string()[..8];

    sqlx::query(
        "INSERT INTO customer_deployments (id, customer_id, node_id, region, vm_type, vm_provider) \
         VALUES ($1, $2, $3, $4, $5, $6)",
    )
    .bind(first_deployment_id)
    .bind(first.id)
    .bind(format!("node-list-health-{first_short}"))
    .bind("us-east-1")
    .bind("t4g.small")
    .bind("aws")
    .execute(&pool)
    .await
    .expect("insert first deployment");

    sqlx::query(
        "INSERT INTO customer_deployments (id, customer_id, node_id, region, vm_type, vm_provider) \
         VALUES ($1, $2, $3, $4, $5, $6)",
    )
    .bind(second_deployment_id)
    .bind(second.id)
    .bind(format!("node-list-health-{second_short}"))
    .bind("us-east-1")
    .bind("t4g.small")
    .bind("aws")
    .execute(&pool)
    .await
    .expect("insert second deployment");

    let older_access = postgres_timestamp(chrono::Utc::now() - chrono::Duration::hours(4));
    let newest_access = postgres_timestamp(chrono::Utc::now() - chrono::Duration::minutes(5));
    sqlx::query(
        "INSERT INTO customer_tenants (customer_id, tenant_id, deployment_id, last_accessed_at) \
         VALUES ($1, $2, $3, $4), ($5, $6, $7, $8), ($9, $10, $11, $12)",
    )
    .bind(first.id)
    .bind(format!("tenant-list-health-a-{first_short}"))
    .bind(first_deployment_id)
    .bind(older_access)
    .bind(first.id)
    .bind(format!("tenant-list-health-b-{first_short}"))
    .bind(first_deployment_id)
    .bind(newest_access)
    .bind(second.id)
    .bind(format!("tenant-list-health-a-{second_short}"))
    .bind(second_deployment_id)
    .bind(chrono::Utc::now() - chrono::Duration::minutes(30))
    .execute(&pool)
    .await
    .expect("insert tenant rows");

    sqlx::query(
        "INSERT INTO invoices (customer_id, period_start, period_end, subtotal_cents, total_cents, status) \
         VALUES \
            ($1, DATE '2026-01-01', DATE '2026-01-31', 100, 100, 'failed'), \
            ($2, DATE '2026-02-01', DATE '2026-02-28', 200, 200, 'failed'), \
            ($3, DATE '2026-03-01', DATE '2026-03-31', 300, 300, 'paid'), \
            ($4, DATE '2026-01-01', DATE '2026-01-31', 100, 100, 'paid')",
    )
    .bind(first.id)
    .bind(first.id)
    .bind(first.id)
    .bind(second.id)
    .execute(&pool)
    .await
    .expect("insert invoice rows");

    let list = repo.list().await.expect("list customers");
    let seeded_rows: Vec<_> = list
        .into_iter()
        .filter(|row| row.id == first.id || row.id == second.id)
        .collect();
    assert_eq!(
        seeded_rows.len(),
        2,
        "list must return exactly one row per customer even with multi-row joins"
    );

    let first_row = seeded_rows
        .iter()
        .find(|row| row.id == first.id)
        .expect("first seeded customer should be in list output");
    assert_eq!(
        first_row.last_accessed_at,
        Some(newest_access),
        "list should project MAX(customer_tenants.last_accessed_at) per customer"
    );
    assert_eq!(
        first_row.overdue_invoice_count, 2,
        "list should count only failed invoices for overdue tally"
    );

    let second_row = seeded_rows
        .iter()
        .find(|row| row.id == second.id)
        .expect("second seeded customer should be in list output");
    assert!(
        second_row.last_accessed_at.is_some(),
        "customer with one tenant should project that tenant's last_accessed_at"
    );
    assert_eq!(
        second_row.overdue_invoice_count, 0,
        "customer with no failed invoices should have overdue_invoice_count = 0"
    );

    cleanup_customer_graph(&pool, &[first.id, second.id]).await;
}

#[tokio::test]
async fn oauth_identity_lookup_returns_linked_customer() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let email = format!(
        "oauth-lookup-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let customer = repo
        .create_oauth_customer("OAuth Lookup", &email)
        .await
        .expect("create oauth customer");

    repo.link_oauth_identity(customer.id, "google", "google-user-lookup")
        .await
        .expect("link oauth identity");

    let found = repo
        .find_oauth_identity("google", "google-user-lookup")
        .await
        .expect("lookup oauth identity")
        .expect("linked identity should resolve to customer");
    assert_eq!(found.id, customer.id);

    cleanup_customer_graph(&pool, &[customer.id]).await;
}

#[tokio::test]
async fn oauth_identity_link_enforces_provider_user_uniqueness() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let first_email = format!(
        "oauth-first-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );
    let second_email = format!(
        "oauth-second-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let first = repo
        .create_oauth_customer("OAuth First", &first_email)
        .await
        .expect("create first oauth customer");
    let second = repo
        .create_oauth_customer("OAuth Second", &second_email)
        .await
        .expect("create second oauth customer");

    repo.link_oauth_identity(first.id, "github", "github-shared-user")
        .await
        .expect("link first oauth identity");

    let duplicate_link = repo
        .link_oauth_identity(second.id, "github", "github-shared-user")
        .await;
    assert!(
        matches!(duplicate_link, Err(api::repos::RepoError::Conflict(_))),
        "second link for the same provider/user tuple must fail with conflict"
    );

    cleanup_customer_graph(&pool, &[first.id, second.id]).await;
}

#[tokio::test]
async fn create_and_link_oauth_customer_flow_preserves_existing_identity_on_conflict() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let linked_email = format!(
        "oauth-linked-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );
    let contender_email = format!(
        "oauth-contender-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let linked = repo
        .create_oauth_customer("OAuth Linked", &linked_email)
        .await
        .expect("create linked customer");
    repo.link_oauth_identity(linked.id, "google", "google-conflict-user")
        .await
        .expect("link canonical identity");

    let contender = repo
        .create_oauth_customer("OAuth Contender", &contender_email)
        .await
        .expect("create contender customer");

    let conflict = repo
        .link_oauth_identity(contender.id, "google", "google-conflict-user")
        .await;
    assert!(
        matches!(conflict, Err(api::repos::RepoError::Conflict(_))),
        "linking an already-linked provider identity must return conflict"
    );

    let owner = repo
        .find_oauth_identity("google", "google-conflict-user")
        .await
        .expect("lookup canonical owner")
        .expect("conflict tuple should remain linked");
    assert_eq!(owner.id, linked.id);

    cleanup_customer_graph(&pool, &[linked.id, contender.id]).await;
}

#[tokio::test]
async fn oauth_identity_link_rejects_deleted_customer_rows() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let email = format!(
        "oauth-deleted-link-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );
    let customer = repo
        .create_oauth_customer("OAuth Deleted", &email)
        .await
        .expect("create oauth customer");
    repo.soft_delete(customer.id)
        .await
        .expect("soft delete oauth customer");

    let result = repo
        .link_oauth_identity(customer.id, "google", "deleted-user-link")
        .await;
    assert!(
        matches!(result, Err(api::repos::RepoError::NotFound)),
        "deleted customers must not accept new oauth identity links"
    );

    cleanup_customer_graph(&pool, &[customer.id]).await;
}

#[tokio::test]
async fn hard_delete_removes_customer_and_dependents_then_404s_on_repeat() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let email = format!(
        "hard-erase-test-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    // 1. Seed a customer with dependent rows across every table that
    //    has a non-cascading FK to customers(id), plus oauth_identities
    //    (which DOES cascade) so we can prove the cascade actually
    //    fires under hard_delete.
    let customer = repo
        .create_with_password("Hard Erase Test", &email, "$argon2id$integration_hash")
        .await
        .expect("create customer");

    // customer_deployments has a NOT NULL node_id (UNIQUE) and a CHECK on
    // vm_provider — schema reality from migrations/002_deployments.sql.
    let node_id = format!("node-{}", &Uuid::new_v4().to_string()[..8]);
    let deployment_id: Uuid = sqlx::query_scalar(
        "INSERT INTO customer_deployments \
            (customer_id, node_id, region, vm_type, vm_provider, status) \
         VALUES ($1, $2, 'us-east-1', 't4g.small', 'aws', 'provisioning') \
         RETURNING id",
    )
    .bind(customer.id)
    .bind(&node_id)
    .fetch_one(&pool)
    .await
    .expect("seed customer_deployments");

    // customer_tenants has a deployment_id FK to customer_deployments(id).
    let tenant_id = format!("tenant-{}", &Uuid::new_v4().to_string()[..6]);
    sqlx::query(
        "INSERT INTO customer_tenants (customer_id, tenant_id, deployment_id) \
         VALUES ($1, $2, $3)",
    )
    .bind(customer.id)
    .bind(&tenant_id)
    .bind(deployment_id)
    .execute(&pool)
    .await
    .expect("seed customer_tenants");

    let primary_vm_id = Uuid::new_v4();
    let replica_vm_id = Uuid::new_v4();
    for (vm_id, region, role) in [
        (primary_vm_id, "us-east-1", "primary"),
        (replica_vm_id, "us-west-2", "replica"),
    ] {
        sqlx::query(
            "INSERT INTO vm_inventory (id, region, provider, hostname, flapjack_url) \
             VALUES ($1, $2, 'aws', $3, $4)",
        )
        .bind(vm_id)
        .bind(region)
        .bind(format!("hard-erase-{role}-{}", &vm_id.to_string()[..8]))
        .bind(format!("http://{role}.hard-erase.test"))
        .execute(&pool)
        .await
        .expect("seed replica VM inventory");
    }
    sqlx::query(
        "INSERT INTO index_replicas \
            (customer_id, tenant_id, primary_vm_id, replica_vm_id, replica_region) \
         VALUES ($1, $2, $3, $4, 'us-west-2')",
    )
    .bind(customer.id)
    .bind(&tenant_id)
    .bind(primary_vm_id)
    .bind(replica_vm_id)
    .execute(&pool)
    .await
    .expect("seed index_replicas");

    sqlx::query(
        "INSERT INTO api_keys (customer_id, name, key_prefix, key_hash) \
         VALUES ($1, 'test-key', $2, 'hash_value')",
    )
    .bind(customer.id)
    .bind(format!("p_{}", &Uuid::new_v4().to_string()[..6]))
    .execute(&pool)
    .await
    .expect("seed api_keys");

    sqlx::query(
        "INSERT INTO invoices \
            (customer_id, period_start, period_end, subtotal_cents, \
             tax_cents, total_cents, status) \
         VALUES ($1, '2026-01-01'::DATE, '2026-01-31'::DATE, \
                 500, 0, 500, 'paid')",
    )
    .bind(customer.id)
    .execute(&pool)
    .await
    .expect("seed invoices");

    sqlx::query(
        "INSERT INTO oauth_identities \
            (customer_id, provider, provider_user_id) \
         VALUES ($1, 'github', $2)",
    )
    .bind(customer.id)
    .bind(format!("gh_{}", &Uuid::new_v4().to_string()[..8]))
    .execute(&pool)
    .await
    .expect("seed oauth_identities");

    // usage_records: idempotency_key UNIQUE, tenant_id/node_id/event_type
    // NOT NULL, event_type CHECKed against an enum-shaped set.
    sqlx::query(
        "INSERT INTO usage_records \
            (idempotency_key, customer_id, tenant_id, region, node_id, \
             event_type, value, recorded_at, flapjack_ts) \
         VALUES ($1, $2, $3, 'us-east-1', $4, \
                 'search_requests', 1, NOW(), NOW())",
    )
    .bind(format!("idem-{}", Uuid::new_v4()))
    .bind(customer.id)
    .bind(format!("tenant-{}", &Uuid::new_v4().to_string()[..6]))
    .bind(&node_id)
    .execute(&pool)
    .await
    .expect("seed usage_records");

    // usage_daily: PK is composite (customer_id, date, region).
    sqlx::query(
        "INSERT INTO usage_daily \
            (customer_id, date, region, search_requests) \
         VALUES ($1, '2026-01-01'::DATE, 'us-east-1', 1)",
    )
    .bind(customer.id)
    .execute(&pool)
    .await
    .expect("seed usage_daily");

    repo.soft_delete(customer.id)
        .await
        .expect("soft delete customer");

    // 2. Hard-erase. The repo seam must return true and leave NO
    //    dependents pointing at this customer.
    let first_erase = repo
        .hard_delete(customer.id, CustomerHardDeleteKind::PrivacyErasure)
        .await
        .expect("hard_delete");
    assert!(matches!(
        first_erase,
        CustomerHardDeleteOutcome::Erased { .. }
    ));

    let remaining_customer = repo
        .find_by_id(customer.id)
        .await
        .expect("find_by_id after hard_delete");
    assert!(
        remaining_customer.is_none(),
        "customer row must be removed by hard_delete"
    );

    // Real DB row-count checks per dependent table; tightens the contract
    // so partial-delete regressions cannot pass.
    for table in [
        "index_replicas",
        "customer_tenants",
        "customer_deployments",
        "api_keys",
        "invoices",
        "oauth_identities",
        "usage_records",
        "usage_daily",
    ] {
        let count: i64 = sqlx::query_scalar(&format!(
            "SELECT COUNT(*)::BIGINT FROM {table} WHERE customer_id = $1"
        ))
        .bind(customer.id)
        .fetch_one(&pool)
        .await
        .expect("count dependent rows");
        assert_eq!(
            count, 0,
            "table {table} still references erased customer {}",
            customer.id
        );
    }

    // 3. Repeat call must return false (already erased).
    let second_erase = repo
        .hard_delete(customer.id, CustomerHardDeleteKind::PrivacyErasure)
        .await
        .expect("second hard_delete");
    assert_eq!(second_erase, CustomerHardDeleteOutcome::NotFound);
}

#[tokio::test]
async fn hard_delete_rejects_customers_with_open_invoices() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let email = format!(
        "hard-erase-open-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let customer = repo
        .create_with_password("Open Invoice", &email, "$argon2id$integration_hash")
        .await
        .expect("create customer");

    // Seed a finalized but unpaid invoice — explicitly NOT in the
    // {paid, refunded} set the seam treats as final.
    sqlx::query(
        "INSERT INTO invoices \
            (customer_id, period_start, period_end, subtotal_cents, \
             tax_cents, total_cents, status) \
         VALUES ($1, '2026-02-01'::DATE, '2026-02-28'::DATE, \
                 500, 0, 500, 'finalized')",
    )
    .bind(customer.id)
    .execute(&pool)
    .await
    .expect("seed open invoice");

    repo.soft_delete(customer.id).await.expect("soft delete");

    let err = repo
        .hard_delete(customer.id, CustomerHardDeleteKind::PrivacyErasure)
        .await
        .expect_err("hard_delete must refuse customers with open invoices");
    match err {
        api::repos::RepoError::Conflict(msg) => {
            assert!(
                msg.contains("open invoice"),
                "open-invoice conflict message must reference open invoices: {msg}"
            );
        }
        other => panic!("expected RepoError::Conflict, got {other:?}"),
    }

    // Customer + invoice rows must be untouched by the rejected call so
    // the admin can wind billing down and retry.
    let still_present = repo
        .find_by_id(customer.id)
        .await
        .expect("find_by_id after rejected hard_delete")
        .expect("rejected hard_delete must not remove the customer row");
    assert_eq!(still_present.status, "deleted");

    let invoice_count: i64 =
        sqlx::query_scalar("SELECT COUNT(*)::BIGINT FROM invoices WHERE customer_id = $1")
            .bind(customer.id)
            .fetch_one(&pool)
            .await
            .expect("count invoices");
    assert_eq!(
        invoice_count, 1,
        "rejected hard_delete must not silently drop invoices"
    );

    cleanup_customer_graph(&pool, &[customer.id]).await;
}

#[derive(Debug, Clone)]
struct AlgoliaHardDeleteMatrixCase {
    name: &'static str,
    status: &'static str,
    dispatch_intent_state: &'static str,
    destination_kind: &'static str,
    destination_bound: bool,
    engine_job_id: Option<Uuid>,
    publication_disposition: AlgoliaImportPublicationDisposition,
    engine_ack_state: AlgoliaImportEngineAckState,
    retryable: bool,
    resumable: bool,
    worker_lease: bool,
    cancel_requested: bool,
    resume_metadata: bool,
    elapsed_resume_deadline: bool,
    error_code: Option<&'static str>,
    terminal_at: bool,
    expected_cleanup_phase: AlgoliaImportTombstoneCleanupPhase,
    expected_engine_ack_state: AlgoliaImportEngineAckState,
}

#[derive(Debug)]
struct SeededAlgoliaHardDeleteMatrixCase {
    name: &'static str,
    id: Uuid,
    engine_job_id: Option<Uuid>,
    destination_vm_id: Option<Uuid>,
    publication_disposition: AlgoliaImportPublicationDisposition,
    expected_cleanup_phase: AlgoliaImportTombstoneCleanupPhase,
    expected_engine_ack_state: AlgoliaImportEngineAckState,
}

#[derive(Debug, sqlx::FromRow)]
struct AlgoliaHardDeleteTombstoneRow {
    id: Uuid,
    erasure_handle: Uuid,
    engine_job_id: Option<Uuid>,
    destination_vm_id: Option<Uuid>,
    publication_disposition: String,
    engine_ack_state: String,
    cleanup_phase: String,
    erased_at: Option<chrono::DateTime<chrono::Utc>>,
    tombstone_compacted_at: Option<chrono::DateTime<chrono::Utc>>,
    lifecycle_generation: Option<i64>,
}

fn hard_delete_algolia_tombstone_matrix_cases() -> Vec<AlgoliaHardDeleteMatrixCase> {
    vec![
        AlgoliaHardDeleteMatrixCase {
            name: "committed",
            status: "copying_documents",
            dispatch_intent_state: "committed",
            destination_kind: "replace",
            destination_bound: true,
            engine_job_id: Some(Uuid::new_v4()),
            publication_disposition: AlgoliaImportPublicationDisposition::Unchanged,
            engine_ack_state: AlgoliaImportEngineAckState::Pending,
            retryable: false,
            resumable: false,
            worker_lease: false,
            cancel_requested: false,
            resume_metadata: false,
            elapsed_resume_deadline: false,
            error_code: None,
            terminal_at: false,
            expected_cleanup_phase: AlgoliaImportTombstoneCleanupPhase::ExactTargetAbsenceRequired,
            expected_engine_ack_state: AlgoliaImportEngineAckState::Pending,
        },
        AlgoliaHardDeleteMatrixCase {
            name: "ambiguous",
            status: "verifying",
            dispatch_intent_state: "ambiguous",
            destination_kind: "replace",
            destination_bound: true,
            engine_job_id: Some(Uuid::new_v4()),
            publication_disposition: AlgoliaImportPublicationDisposition::Unknown,
            engine_ack_state: AlgoliaImportEngineAckState::Pending,
            retryable: false,
            resumable: false,
            worker_lease: false,
            cancel_requested: false,
            resume_metadata: false,
            elapsed_resume_deadline: false,
            error_code: None,
            terminal_at: false,
            expected_cleanup_phase: AlgoliaImportTombstoneCleanupPhase::ExactTargetAbsenceRequired,
            expected_engine_ack_state: AlgoliaImportEngineAckState::Pending,
        },
        AlgoliaHardDeleteMatrixCase {
            name: "pre_linkage",
            status: "validating_source",
            dispatch_intent_state: "committed",
            destination_kind: "create",
            destination_bound: false,
            engine_job_id: None,
            publication_disposition: AlgoliaImportPublicationDisposition::NotStarted,
            engine_ack_state: AlgoliaImportEngineAckState::Pending,
            retryable: false,
            resumable: false,
            worker_lease: false,
            cancel_requested: false,
            resume_metadata: false,
            elapsed_resume_deadline: false,
            error_code: None,
            terminal_at: false,
            expected_cleanup_phase: AlgoliaImportTombstoneCleanupPhase::ExactTargetAbsenceRequired,
            expected_engine_ack_state: AlgoliaImportEngineAckState::Pending,
        },
        AlgoliaHardDeleteMatrixCase {
            name: "cancelling",
            status: "cancelling",
            dispatch_intent_state: "committed",
            destination_kind: "replace",
            destination_bound: true,
            engine_job_id: Some(Uuid::new_v4()),
            publication_disposition: AlgoliaImportPublicationDisposition::Unchanged,
            engine_ack_state: AlgoliaImportEngineAckState::Pending,
            retryable: false,
            resumable: false,
            worker_lease: true,
            cancel_requested: true,
            resume_metadata: false,
            elapsed_resume_deadline: false,
            error_code: None,
            terminal_at: false,
            expected_cleanup_phase: AlgoliaImportTombstoneCleanupPhase::ExactTargetAbsenceRequired,
            expected_engine_ack_state: AlgoliaImportEngineAckState::Pending,
        },
        AlgoliaHardDeleteMatrixCase {
            name: "cancelled_before_ack",
            status: "cancelled",
            dispatch_intent_state: "committed",
            destination_kind: "replace",
            destination_bound: true,
            engine_job_id: Some(Uuid::new_v4()),
            publication_disposition: AlgoliaImportPublicationDisposition::Unchanged,
            engine_ack_state: AlgoliaImportEngineAckState::OutboxPending,
            retryable: false,
            resumable: false,
            worker_lease: false,
            cancel_requested: true,
            resume_metadata: false,
            elapsed_resume_deadline: false,
            error_code: None,
            terminal_at: true,
            expected_cleanup_phase: AlgoliaImportTombstoneCleanupPhase::ExactTargetAbsenceRequired,
            expected_engine_ack_state: AlgoliaImportEngineAckState::OutboxPending,
        },
        AlgoliaHardDeleteMatrixCase {
            name: "failed_resumable_with_lease",
            status: "failed",
            dispatch_intent_state: "committed",
            destination_kind: "replace",
            destination_bound: true,
            engine_job_id: Some(Uuid::new_v4()),
            publication_disposition: AlgoliaImportPublicationDisposition::Unchanged,
            engine_ack_state: AlgoliaImportEngineAckState::Pending,
            retryable: true,
            resumable: true,
            worker_lease: true,
            cancel_requested: false,
            resume_metadata: true,
            elapsed_resume_deadline: false,
            error_code: Some("internal"),
            terminal_at: true,
            expected_cleanup_phase: AlgoliaImportTombstoneCleanupPhase::ExactTargetAbsenceRequired,
            expected_engine_ack_state: AlgoliaImportEngineAckState::Pending,
        },
        AlgoliaHardDeleteMatrixCase {
            name: "credential_accepted_before_socket",
            status: "validating_source",
            dispatch_intent_state: "committed",
            destination_kind: "create",
            destination_bound: false,
            engine_job_id: None,
            publication_disposition: AlgoliaImportPublicationDisposition::NotStarted,
            engine_ack_state: AlgoliaImportEngineAckState::Pending,
            retryable: false,
            resumable: false,
            worker_lease: true,
            cancel_requested: false,
            resume_metadata: false,
            elapsed_resume_deadline: false,
            error_code: None,
            terminal_at: false,
            expected_cleanup_phase: AlgoliaImportTombstoneCleanupPhase::ExactTargetAbsenceRequired,
            expected_engine_ack_state: AlgoliaImportEngineAckState::Pending,
        },
        AlgoliaHardDeleteMatrixCase {
            name: "resuming",
            status: "resuming",
            dispatch_intent_state: "committed",
            destination_kind: "replace",
            destination_bound: true,
            engine_job_id: Some(Uuid::new_v4()),
            publication_disposition: AlgoliaImportPublicationDisposition::Unchanged,
            engine_ack_state: AlgoliaImportEngineAckState::Pending,
            retryable: false,
            resumable: false,
            worker_lease: true,
            cancel_requested: false,
            resume_metadata: true,
            elapsed_resume_deadline: false,
            error_code: None,
            terminal_at: false,
            expected_cleanup_phase: AlgoliaImportTombstoneCleanupPhase::ExactTargetAbsenceRequired,
            expected_engine_ack_state: AlgoliaImportEngineAckState::Pending,
        },
        AlgoliaHardDeleteMatrixCase {
            name: "resume_deadline_race",
            status: "failed",
            dispatch_intent_state: "ambiguous",
            destination_kind: "replace",
            destination_bound: true,
            engine_job_id: Some(Uuid::new_v4()),
            publication_disposition: AlgoliaImportPublicationDisposition::Unchanged,
            engine_ack_state: AlgoliaImportEngineAckState::Pending,
            retryable: true,
            resumable: true,
            worker_lease: false,
            cancel_requested: false,
            resume_metadata: true,
            elapsed_resume_deadline: true,
            error_code: Some("internal"),
            terminal_at: true,
            expected_cleanup_phase: AlgoliaImportTombstoneCleanupPhase::ExactTargetAbsenceRequired,
            expected_engine_ack_state: AlgoliaImportEngineAckState::Pending,
        },
        AlgoliaHardDeleteMatrixCase {
            name: "local_no_dispatch",
            status: "failed",
            dispatch_intent_state: "absent",
            destination_kind: "create",
            destination_bound: false,
            engine_job_id: None,
            publication_disposition: AlgoliaImportPublicationDisposition::NotStarted,
            engine_ack_state: AlgoliaImportEngineAckState::NotApplicable,
            retryable: false,
            resumable: false,
            worker_lease: false,
            cancel_requested: false,
            resume_metadata: false,
            elapsed_resume_deadline: false,
            error_code: Some("internal"),
            terminal_at: true,
            expected_cleanup_phase: AlgoliaImportTombstoneCleanupPhase::EngineDispositionRequired,
            expected_engine_ack_state: AlgoliaImportEngineAckState::NotApplicable,
        },
        AlgoliaHardDeleteMatrixCase {
            name: "seal_tombstone",
            status: "interrupted",
            dispatch_intent_state: "ambiguous",
            destination_kind: "create",
            destination_bound: false,
            engine_job_id: None,
            publication_disposition: AlgoliaImportPublicationDisposition::NotStarted,
            engine_ack_state: AlgoliaImportEngineAckState::SealAcknowledged,
            retryable: false,
            resumable: false,
            worker_lease: false,
            cancel_requested: false,
            resume_metadata: false,
            elapsed_resume_deadline: false,
            error_code: Some("interrupted"),
            terminal_at: true,
            expected_cleanup_phase: AlgoliaImportTombstoneCleanupPhase::EngineDispositionRequired,
            expected_engine_ack_state: AlgoliaImportEngineAckState::SealAcknowledged,
        },
        AlgoliaHardDeleteMatrixCase {
            name: "ambiguous_publication",
            status: "promoting",
            dispatch_intent_state: "ambiguous",
            destination_kind: "replace",
            destination_bound: true,
            engine_job_id: Some(Uuid::new_v4()),
            publication_disposition: AlgoliaImportPublicationDisposition::Unknown,
            engine_ack_state: AlgoliaImportEngineAckState::Pending,
            retryable: false,
            resumable: false,
            worker_lease: false,
            cancel_requested: false,
            resume_metadata: false,
            elapsed_resume_deadline: false,
            error_code: None,
            terminal_at: false,
            expected_cleanup_phase: AlgoliaImportTombstoneCleanupPhase::ExactTargetAbsenceRequired,
            expected_engine_ack_state: AlgoliaImportEngineAckState::Pending,
        },
    ]
}

async fn seed_algolia_hard_delete_matrix_case(
    pool: &PgPool,
    customer_id: Uuid,
    lifecycle_generation: i64,
    ordinal: usize,
    case: &AlgoliaHardDeleteMatrixCase,
) -> SeededAlgoliaHardDeleteMatrixCase {
    let destination_deployment_id = case.destination_bound.then(Uuid::new_v4);
    let destination_vm_id = case.destination_bound.then(Uuid::new_v4);
    let physical_uid = case
        .destination_bound
        .then(|| format!("PII_MATRIX_PHYSICAL_{}", case.name));
    let routing_identity = case
        .destination_bound
        .then(|| format!("PII_MATRIX_ROUTING_{}", case.name));
    let worker_claimed_at = case.worker_lease.then(chrono::Utc::now);
    let worker_lease_expires_at = case
        .worker_lease
        .then(|| chrono::Utc::now() + chrono::Duration::minutes(5));
    let cancel_requested_at = case.cancel_requested.then(chrono::Utc::now);
    let resume_status_observed_at = case
        .resume_metadata
        .then(|| chrono::Utc::now() - chrono::Duration::minutes(10));
    let resume_deadline = case.resume_metadata.then(|| {
        if case.elapsed_resume_deadline {
            chrono::Utc::now() - chrono::Duration::minutes(5)
        } else {
            chrono::Utc::now() + chrono::Duration::hours(1)
        }
    });
    let terminal_at = case.terminal_at.then(chrono::Utc::now);
    let resume_checkpoint = case
        .resume_metadata
        .then(|| format!("PII_MATRIX_CHECKPOINT_{}", case.name));
    let error_message = case
        .error_code
        .map(|_| format!("PII_MATRIX_ERROR_{}", case.name));
    let tenant_id = format!("PII_MATRIX_TENANT_{}", case.name);
    let source_name = format!("PII_MATRIX_SOURCE_{}", case.name);
    let idempotency_key = format!("PII_MATRIX_IDEMPOTENCY_{}_{}", ordinal, Uuid::new_v4());
    let canonical_fingerprint = format!("PII_MATRIX_FINGERPRINT_{}", case.name);
    let warnings = serde_json::json!([
        format!("PII_MATRIX_WARNING_{}", case.name),
        format!("PII_MATRIX_OBJECT_{}", case.name),
    ]);

    if let Some(destination_vm_id) = destination_vm_id {
        insert_vm_with_id(
            pool,
            destination_vm_id,
            &format!("algolia-matrix-{ordinal}-{destination_vm_id}"),
            "active",
        )
        .await;
    }

    let id = sqlx::query_scalar::<_, Uuid>(
        "INSERT INTO algolia_import_jobs
         (customer_id, tenant_id, algolia_app_id, destination_kind, logical_target,
          destination_region, destination_deployment_id, destination_vm_id, physical_uid,
          source_name, engine_job_id, dispatch_intent_state, lifecycle_generation,
          idempotency_key, canonical_fingerprint, routing_identity, source_size_bytes,
          reserved_index_count, reserved_customer_storage_bytes, reserved_node_transient_bytes,
          retryable, worker_claimed_at, worker_lease_expires_at, cancel_requested_at,
          resume_intent_generation, resume_checkpoint, resume_deadline,
          resume_status_observed_at, resumable, resume_count, documents_expected,
          documents_imported, documents_rejected, settings_applied, settings_unsupported,
          synonyms_expected, synonyms_imported, synonyms_rejected, rules_expected,
          rules_imported, rules_rejected, warnings, error_code, error_message, status,
          publication_disposition, engine_ack_state, terminal_at)
         VALUES ($1, $2, $3, $4, $2, $5, $6, $7, $8, $9, $10, $11, $12,
                 $13, $14, $15, 4096, 1, 2048, 512, $16, $17, $18, $19,
                 $20, $21, $22, $23, $24, $25, 31, 17, 2, 5, 1, 7, 6, 1,
                 9, 8, 1, $26, $27, $28, $29, $30, $31, $32)
         RETURNING id",
    )
    .bind(customer_id)
    .bind(&tenant_id)
    .bind(format!("PIIAPP{:02}", ordinal + 1))
    .bind(case.destination_kind)
    .bind(format!("PII_MATRIX_REGION_{}", case.name))
    .bind(destination_deployment_id)
    .bind(destination_vm_id)
    .bind(physical_uid)
    .bind(&source_name)
    .bind(case.engine_job_id)
    .bind(case.dispatch_intent_state)
    .bind(lifecycle_generation)
    .bind(idempotency_key)
    .bind(canonical_fingerprint)
    .bind(routing_identity)
    .bind(case.retryable)
    .bind(worker_claimed_at)
    .bind(worker_lease_expires_at)
    .bind(cancel_requested_at)
    .bind(if case.resume_metadata { 2_i64 } else { 0_i64 })
    .bind(resume_checkpoint)
    .bind(resume_deadline)
    .bind(resume_status_observed_at)
    .bind(case.resumable)
    .bind(if case.resume_metadata { 1_i64 } else { 0_i64 })
    .bind(warnings)
    .bind(case.error_code)
    .bind(error_message)
    .bind(case.status)
    .bind(case.publication_disposition.as_str())
    .bind(case.engine_ack_state.as_str())
    .bind(terminal_at)
    .fetch_one(pool)
    .await
    .unwrap_or_else(|err| panic!("seed Algolia matrix case {}: {err}", case.name));

    SeededAlgoliaHardDeleteMatrixCase {
        name: case.name,
        id,
        engine_job_id: case.engine_job_id,
        destination_vm_id,
        publication_disposition: case.publication_disposition,
        expected_cleanup_phase: case.expected_cleanup_phase,
        expected_engine_ack_state: case.expected_engine_ack_state,
    }
}

fn assert_algolia_matrix_pii_columns_are_null(tombstone: &serde_json::Value) {
    for field in [
        "customer_id",
        "tenant_id",
        "algolia_app_id",
        "destination_kind",
        "logical_target",
        "destination_region",
        "destination_deployment_id",
        "physical_uid",
        "source_name",
        "cloud_job_id",
        "dispatch_intent_state",
        "lifecycle_generation",
        "idempotency_key",
        "canonical_fingerprint",
        "routing_identity",
        "source_size_bytes",
        "reserved_index_count",
        "reserved_customer_storage_bytes",
        "reserved_node_transient_bytes",
        "retryable",
        "worker_claimed_at",
        "worker_lease_expires_at",
        "cancel_requested_at",
        "resume_intent_generation",
        "resume_checkpoint",
        "resume_deadline",
        "resume_status_observed_at",
        "resumable",
        "resume_count",
        "documents_expected",
        "documents_imported",
        "documents_rejected",
        "settings_applied",
        "settings_unsupported",
        "synonyms_expected",
        "synonyms_imported",
        "synonyms_rejected",
        "rules_expected",
        "rules_imported",
        "rules_rejected",
        "warnings",
        "error_code",
        "error_message",
        "status",
    ] {
        assert!(
            tombstone[field].is_null(),
            "retained tombstone field {field} must be NULL after hard erasure: {tombstone}"
        );
    }
}

#[tokio::test]
async fn hard_delete_scrubs_algolia_jobs_and_retains_reconciliation_tombstone_matrix() {
    let Some(db) =
        pg_schema_harness::connect_and_migrate("hard_delete_algolia_tombstone_matrix").await
    else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let customer = repo
        .create_with_password(
            "PII_MATRIX_NAME_CANARY",
            "pii_matrix_email_canary@example.test",
            "$argon2id$pii_matrix_password_canary",
        )
        .await
        .expect("create customer");

    repo.soft_delete(customer.id).await.expect("soft delete");
    let deleted_customer = fetch_customer_lifecycle_snapshot(&pool, customer.id).await;
    assert_eq!(deleted_customer.status, "deleted");
    assert!(
        deleted_customer.lifecycle_generation > customer.lifecycle_generation,
        "matrix fixtures must use the post-soft-delete lifecycle generation"
    );

    let mut seeded_cases = Vec::new();
    for (ordinal, case) in hard_delete_algolia_tombstone_matrix_cases()
        .iter()
        .enumerate()
    {
        seeded_cases.push(
            seed_algolia_hard_delete_matrix_case(
                &pool,
                customer.id,
                deleted_customer.lifecycle_generation,
                ordinal,
                case,
            )
            .await,
        );
    }
    sqlx::query(
        "INSERT INTO audit_log (actor_id, action, target_tenant_id, metadata)
         VALUES ($1, 'PII_MATRIX_AUDIT_ACTION_CANARY', $2,
                 '{\"history\":\"PII_MATRIX_AUDIT_METADATA_CANARY\"}'::jsonb)",
    )
    .bind(Uuid::nil())
    .bind(customer.id)
    .execute(&pool)
    .await
    .expect("seed audit metadata canary");

    let hard_delete_started_at = chrono::Utc::now();
    let outcome = repo
        .hard_delete(customer.id, CustomerHardDeleteKind::PrivacyErasure)
        .await
        .expect("hard delete");
    let hard_delete_finished_at = chrono::Utc::now();
    let CustomerHardDeleteOutcome::Erased { seal_scrub_work } = outcome else {
        panic!("expected typed erased outcome, got {outcome:?}");
    };
    assert_eq!(
        seal_scrub_work.len(),
        seeded_cases.len(),
        "seal/scrub work must include each matrix row exactly once"
    );
    let unique_scrub_handles: HashSet<_> = seal_scrub_work
        .iter()
        .map(|work| work.erasure_handle)
        .collect();
    assert_eq!(
        unique_scrub_handles.len(),
        seeded_cases.len(),
        "seal/scrub work must not duplicate erasure handles"
    );

    let seeded_ids: Vec<Uuid> = seeded_cases.iter().map(|case| case.id).collect();
    let tombstone_rows = sqlx::query_as::<_, AlgoliaHardDeleteTombstoneRow>(
        "SELECT id, erasure_handle, engine_job_id, destination_vm_id, publication_disposition,
                engine_ack_state, cleanup_phase, erased_at, tombstone_compacted_at,
                lifecycle_generation
         FROM algolia_import_jobs
         WHERE id = ANY($1)
         ORDER BY id",
    )
    .bind(seeded_ids.clone())
    .fetch_all(&pool)
    .await
    .expect("fetch matrix tombstones by original id");
    assert_eq!(
        tombstone_rows.len(),
        seeded_cases.len(),
        "hard erase must retain every matrix row as a tombstone"
    );

    let tombstones: serde_json::Value = sqlx::query_scalar(
        "SELECT COALESCE(jsonb_agg(to_jsonb(job) ORDER BY id), '[]'::jsonb)
         FROM algolia_import_jobs AS job
         WHERE id = ANY($1)",
    )
    .bind(seeded_ids.clone())
    .fetch_one(&pool)
    .await
    .expect("retained Algolia reconciliation tombstones");
    let serialized = serde_json::to_string(&serde_json::json!({
        "tombstones": &tombstones,
        "seal_scrub_work": &seal_scrub_work,
    }))
    .expect("serialize erasure evidence");
    let audit_rows: serde_json::Value = sqlx::query_scalar(
        "SELECT COALESCE(jsonb_agg(to_jsonb(audit_log) ORDER BY id), '[]'::jsonb)
         FROM audit_log",
    )
    .fetch_one(&pool)
    .await
    .expect("scan retained audit rows");
    let retained_evidence = format!("{serialized}{audit_rows}");
    for canary in [
        customer.id.to_string(),
        "PII_MATRIX_NAME_CANARY".into(),
        "pii_matrix_email_canary@example.test".into(),
        "PII_MATRIX_TENANT".into(),
        "PIIAPP".into(),
        "PII_MATRIX_REGION".into(),
        "PII_MATRIX_PHYSICAL".into(),
        "PII_MATRIX_SOURCE".into(),
        "PII_MATRIX_IDEMPOTENCY".into(),
        "PII_MATRIX_FINGERPRINT".into(),
        "PII_MATRIX_ROUTING".into(),
        "PII_MATRIX_CHECKPOINT".into(),
        "PII_MATRIX_WARNING".into(),
        "PII_MATRIX_OBJECT".into(),
        "PII_MATRIX_ERROR".into(),
        "PII_MATRIX_AUDIT_ACTION_CANARY".into(),
        "PII_MATRIX_AUDIT_METADATA_CANARY".into(),
    ] {
        assert!(
            !retained_evidence.contains(&canary),
            "retained hard-erasure evidence leaked PII canary {canary}: {retained_evidence}"
        );
    }

    let tombstone_json_rows = tombstones
        .as_array()
        .expect("tombstone aggregate must be an array");
    assert_eq!(tombstone_json_rows.len(), seeded_cases.len());
    for tombstone in tombstone_json_rows {
        assert_algolia_matrix_pii_columns_are_null(tombstone);
        let fields = tombstone
            .as_object()
            .expect("tombstone row must serialize as an object");
        for (field, value) in fields {
            if !value.is_null() {
                assert!(
                    matches!(
                        field.as_str(),
                        "id" | "engine_job_id"
                            | "destination_vm_id"
                            | "publication_disposition"
                            | "engine_ack_state"
                            | "erasure_handle"
                            | "cleanup_phase"
                            | "erased_at"
                            | "tombstone_compacted_at"
                            | "created_at"
                            | "updated_at"
                    ),
                    "unexpected retained Algolia tombstone field {field}={value}"
                );
            }
        }
    }

    for expected in &seeded_cases {
        let tombstone = tombstone_rows
            .iter()
            .find(|row| row.id == expected.id)
            .unwrap_or_else(|| panic!("missing tombstone row for {}", expected.name));
        assert_eq!(
            tombstone.lifecycle_generation, None,
            "{} tombstone must not preserve customer lifecycle identity",
            expected.name
        );
        assert_eq!(
            tombstone.engine_job_id, expected.engine_job_id,
            "{} engine_job_id tombstone mismatch",
            expected.name
        );
        assert_eq!(
            tombstone.destination_vm_id, expected.destination_vm_id,
            "{} destination_vm_id tombstone mismatch",
            expected.name
        );
        assert_eq!(
            tombstone.publication_disposition,
            expected.publication_disposition.as_str(),
            "{} publication_disposition tombstone mismatch",
            expected.name
        );
        assert_eq!(
            tombstone.engine_ack_state,
            expected.expected_engine_ack_state.as_str(),
            "{} engine_ack_state tombstone mismatch",
            expected.name
        );
        assert_eq!(
            tombstone.cleanup_phase,
            expected.expected_cleanup_phase.as_str(),
            "{} cleanup_phase tombstone mismatch",
            expected.name
        );
        let erased_at = tombstone
            .erased_at
            .unwrap_or_else(|| panic!("{} erased_at must be populated", expected.name));
        assert!(
            erased_at >= hard_delete_started_at && erased_at <= hard_delete_finished_at,
            "{} erased_at {erased_at:?} must come from this hard-delete call",
            expected.name
        );
        assert_eq!(
            tombstone.tombstone_compacted_at, None,
            "{} must not compact during initial hard-delete scrub",
            expected.name
        );

        let scrub_work = if let Some(engine_job_id) = expected.engine_job_id {
            seal_scrub_work
                .iter()
                .find(|work| work.engine_job_id == Some(engine_job_id))
                .unwrap_or_else(|| {
                    panic!(
                        "missing seal/scrub work by engine_job_id for {}",
                        expected.name
                    )
                })
        } else {
            seal_scrub_work
                .iter()
                .find(|work| work.erasure_handle == tombstone.erasure_handle)
                .unwrap_or_else(|| {
                    panic!(
                        "missing seal/scrub work by erasure_handle for {}",
                        expected.name
                    )
                })
        };
        assert_eq!(
            scrub_work.destination_vm_id, expected.destination_vm_id,
            "{} seal/scrub destination_vm_id mismatch",
            expected.name
        );
        assert_eq!(
            scrub_work.publication_disposition, expected.publication_disposition,
            "{} seal/scrub publication_disposition mismatch",
            expected.name
        );
        assert_eq!(
            scrub_work.engine_ack_state, expected.expected_engine_ack_state,
            "{} seal/scrub engine_ack_state mismatch",
            expected.name
        );
        assert_eq!(
            scrub_work.cleanup_phase, expected.expected_cleanup_phase,
            "{} seal/scrub cleanup_phase mismatch",
            expected.name
        );
    }

    let compactable_tombstone = tombstone_rows
        .iter()
        .find(|row| row.cleanup_phase == "exact_target_absence_required")
        .expect("matrix must include an exact-target tombstone for compaction guard");
    let early_compaction =
        sqlx::query("UPDATE algolia_import_jobs SET tombstone_compacted_at = NOW() WHERE id = $1")
            .bind(compactable_tombstone.id)
            .execute(&pool)
            .await;
    assert!(
        early_compaction.is_err(),
        "compaction must wait for exact-target absence and terminal ACK"
    );
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET cleanup_phase = 'exact_target_absent', engine_ack_state = 'acknowledged',
             tombstone_compacted_at = NOW()
         WHERE id = $1",
    )
    .bind(compactable_tombstone.id)
    .execute(&pool)
    .await
    .expect("compact only after exact-target absence and terminal ACK");
}

// ─── Login lockout tests ─────────────────────────────────────────────────────

#[tokio::test]
async fn lockout_record_failed_login_increments_and_eventually_locks() {
    let Some(harness) = pg_schema_harness::connect_and_migrate("lockout_basic").await else {
        return;
    };
    let pool = harness.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());

    let customer = repo
        .create_with_password("lockout-user", "lockout@test.dev", "$argon2id$hash")
        .await
        .expect("create test customer");

    // First 4 failures should not lock (threshold is 5)
    for i in 1..=4 {
        let result = repo
            .record_failed_login(customer.id)
            .await
            .expect("record_failed_login");
        assert_eq!(
            result, None,
            "attempt {i}: should not be locked before threshold"
        );
    }

    // 5th failure should trigger lockout
    let result = repo
        .record_failed_login(customer.id)
        .await
        .expect("record_failed_login at threshold");
    assert!(
        result.is_some(),
        "5th failure must trigger lockout — expected Some(seconds_remaining)"
    );
    let seconds = result.unwrap();
    assert!(
        seconds > 0 && seconds <= 1800,
        "lockout duration must be between 1 and 1800 seconds, got {seconds}"
    );

    // Verify lockout_remaining reports the same
    let remaining = repo
        .login_lockout_remaining(customer.id)
        .await
        .expect("login_lockout_remaining");
    assert!(
        remaining.is_some(),
        "lockout_remaining must report locked state"
    );

    cleanup_customer(&pool, "lockout@test.dev").await;
}

#[tokio::test]
async fn lockout_successful_login_resets_counters() {
    let Some(harness) = pg_schema_harness::connect_and_migrate("lockout_reset").await else {
        return;
    };
    let pool = harness.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());

    let customer = repo
        .create_with_password("reset-user", "reset-lockout@test.dev", "$argon2id$hash")
        .await
        .expect("create test customer");

    // Accumulate some failures
    for _ in 0..3 {
        repo.record_failed_login(customer.id)
            .await
            .expect("record_failed_login");
    }

    // Successful login resets everything
    let reset = repo
        .record_successful_login(customer.id)
        .await
        .expect("record_successful_login");
    assert!(reset, "record_successful_login should return true");

    // Next failure should start from count 1 (no lock)
    let result = repo
        .record_failed_login(customer.id)
        .await
        .expect("record_failed_login after reset");
    assert_eq!(
        result, None,
        "after successful login, counter resets — first failure should not lock"
    );

    cleanup_customer(&pool, "reset-lockout@test.dev").await;
}

#[tokio::test]
async fn lockout_concurrent_failures_reach_exact_count() {
    let Some(harness) = pg_schema_harness::connect_and_migrate("lockout_concurrent").await else {
        return;
    };
    let pool = harness.pool.clone();
    let repo = Arc::new(PgCustomerRepo::new(pool.clone()));

    let customer = repo
        .create_with_password(
            "concurrent-user",
            "concurrent-lockout@test.dev",
            "$argon2id$hash",
        )
        .await
        .expect("create test customer");

    let mut set = tokio::task::JoinSet::new();
    for _ in 0..10 {
        let repo_clone = Arc::clone(&repo);
        let cid = customer.id;
        set.spawn(async move { repo_clone.record_failed_login(cid).await });
    }

    let mut results = Vec::new();
    while let Some(res) = set.join_next().await {
        results.push(res.expect("task join").expect("record_failed_login"));
    }

    // All 10 must have completed, and the counter must stop at the lockout threshold.
    let count: i32 = sqlx::query_scalar("SELECT failed_login_count FROM customers WHERE id = $1")
        .bind(customer.id)
        .fetch_one(&pool)
        .await
        .expect("query failed_login_count");

    assert_eq!(
        count, 5,
        "concurrent record_failed_login calls must lock exactly at the configured threshold"
    );

    // At least some results should have reported lockout (threshold is 5)
    let locked_count = results.iter().filter(|r| r.is_some()).count();
    assert!(
        locked_count >= 6,
        "at least 6 of 10 concurrent calls should report locked (calls 5-10), got {locked_count}"
    );

    cleanup_customer(&pool, "concurrent-lockout@test.dev").await;
}

#[tokio::test]
async fn verify_email_succeeds_even_when_deferred_verify_lockout_columns_are_active() {
    let Some(harness) = pg_schema_harness::connect_and_migrate("verify_lockout_deferred").await
    else {
        return;
    };
    let pool = harness.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());

    let email = format!(
        "verify-lockout-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );
    let customer = repo
        .create("Verify Lockout Deferred", &email)
        .await
        .expect("create customer for verify lockout defer regression");

    let token = "verify-token-deferred-lockout";
    repo.set_email_verify_token(
        customer.id,
        token,
        chrono::Utc::now() + chrono::Duration::hours(1),
    )
    .await
    .expect("set verification token");

    sqlx::query(
        "UPDATE customers SET \
            failed_verify_count = 99, \
            failed_verify_window_start = NOW() - INTERVAL '5 minutes', \
            verify_locked_until = NOW() + INTERVAL '2 hours' \
         WHERE id = $1",
    )
    .bind(customer.id)
    .execute(&pool)
    .await
    .expect("seed active deferred verify lockout columns");

    let verified = repo
        .verify_email(token)
        .await
        .expect("verify_email query should succeed");
    assert!(
        verified.is_some(),
        "valid verify token must still succeed while deferred verify lockout columns are active"
    );

    cleanup_customer(&pool, &email).await;
}

#[tokio::test]
async fn reset_password_succeeds_even_when_deferred_reset_lockout_columns_are_active() {
    let Some(harness) = pg_schema_harness::connect_and_migrate("reset_lockout_deferred").await
    else {
        return;
    };
    let pool = harness.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());

    let email = format!(
        "reset-lockout-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );
    let customer = repo
        .create_with_password("Reset Lockout Deferred", &email, "$argon2id$hash")
        .await
        .expect("create customer for reset lockout defer regression");

    let token = "reset-token-deferred-lockout";
    let token_set = repo
        .set_password_reset_token(
            customer.id,
            token,
            chrono::Utc::now() + chrono::Duration::hours(1),
        )
        .await
        .expect("set reset token");
    assert!(token_set, "password reset token setup should succeed");

    sqlx::query(
        "UPDATE customers SET \
            failed_reset_count = 99, \
            failed_reset_window_start = NOW() - INTERVAL '5 minutes', \
            reset_locked_until = NOW() + INTERVAL '2 hours' \
         WHERE id = $1",
    )
    .bind(customer.id)
    .execute(&pool)
    .await
    .expect("seed active deferred reset lockout columns");

    let reset = repo
        .reset_password(token, "$argon2id$newhash")
        .await
        .expect("reset_password query should succeed");
    assert!(
        reset,
        "valid reset token must still succeed while deferred reset lockout columns are active"
    );

    cleanup_customer(&pool, &email).await;
}

#[tokio::test]
async fn reactivate_cannot_cross_soft_delete_generation_fence() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_reactivate_soft_delete_fence").await
    else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let generation = 7_i64;

    // Control arm: a suspended customer at generation G reactivates to active and
    // keeps generation G exactly — the existing admin transition still admits
    // `suspended -> active`.
    let suspended_email = format!("reactivate-suspended-{}@integration.test", Uuid::new_v4());
    let suspended = repo
        .create("Reactivate Suspended", &suspended_email)
        .await
        .expect("create suspended-arm customer");
    sqlx::query("UPDATE customers SET lifecycle_generation = $2 WHERE id = $1")
        .bind(suspended.id)
        .bind(generation)
        .execute(&pool)
        .await
        .expect("seed suspended-arm generation");
    assert!(repo
        .suspend(suspended.id)
        .await
        .expect("suspend control customer"));
    assert!(
        repo.reactivate(suspended.id)
            .await
            .expect("reactivate control customer"),
        "suspended -> active reactivation must report it changed the row"
    );
    let reactivated = fetch_customer_lifecycle_snapshot(&pool, suspended.id).await;
    assert_eq!(reactivated.status, "active");
    assert_eq!(
        reactivated.lifecycle_generation, generation,
        "suspended -> active reactivation must preserve generation G exactly"
    );

    // Fence arm: a real soft-deleted customer at generation G + 1 cannot be
    // reactivated and retains its deletion metadata and Stage 2 recovery evidence
    // byte-for-byte.
    let deleted_email = format!("reactivate-deleted-{}@integration.test", Uuid::new_v4());
    let deleted = repo
        .create_with_password(
            "Reactivate Deleted",
            &deleted_email,
            "$argon2id$integration_hash",
        )
        .await
        .expect("create fence-arm customer");
    sqlx::query("UPDATE customers SET lifecycle_generation = $2 WHERE id = $1")
        .bind(deleted.id)
        .bind(generation)
        .execute(&pool)
        .await
        .expect("seed fence-arm generation");
    let (_deployment_id, vm_id, _cold_snapshot_id) =
        seed_soft_delete_recovery_evidence(&pool, &deleted, generation).await;

    assert!(
        repo.soft_delete(deleted.id)
            .await
            .expect("soft delete fence-arm customer"),
        "soft_delete must report it changed the active customer row"
    );

    let deletion_before = fetch_customer_lifecycle_snapshot(&pool, deleted.id).await;
    let evidence_before = fetch_retained_evidence_snapshot(&pool, deleted.id).await;
    assert_eq!(deletion_before.status, "deleted");
    assert_eq!(
        deletion_before.lifecycle_generation,
        generation + 1,
        "soft_delete must fence the generation at G + 1"
    );
    assert!(
        deletion_before.deleted_at.is_some(),
        "soft_delete must stamp the deletion timestamp"
    );
    assert_algolia_recovery_metadata_seeded(&evidence_before);

    assert!(
        !repo
            .reactivate(deleted.id)
            .await
            .expect("reactivate must not error on a soft-deleted customer"),
        "reactivate must refuse a soft-deleted customer at generation G + 1"
    );

    let deletion_after = fetch_customer_lifecycle_snapshot(&pool, deleted.id).await;
    let evidence_after = fetch_retained_evidence_snapshot(&pool, deleted.id).await;
    assert_eq!(
        deletion_after, deletion_before,
        "refused reactivation must leave status, generation, deletion timestamp, and \
         updated_at unchanged byte-for-byte"
    );
    assert_eq!(
        evidence_after, evidence_before,
        "refused reactivation must retain catalog, snapshot, VM, deployment, and import evidence"
    );

    cleanup_soft_delete_recovery_evidence(&pool, deleted.id, vm_id).await;
    cleanup_customer(&pool, &deleted_email).await;
    cleanup_customer(&pool, &suspended_email).await;
}
