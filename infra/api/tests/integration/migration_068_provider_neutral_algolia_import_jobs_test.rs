use crate::common::support::pg_schema_harness::{
    connect_without_migrations, migrate_through_version,
};

#[tokio::test]
async fn migration_068_clears_provider_for_existing_erased_tombstones() {
    let Some(db) = connect_without_migrations("migration_068_erased_tombstone").await else {
        return;
    };

    migrate_through_version(&db.pool, 67)
        .await
        .expect("run migrations before provider discriminator");

    sqlx::query(
        "INSERT INTO customers (id, name, email, status, lifecycle_generation)
         VALUES (
             '11111111-1111-4111-8111-111111116823',
             'Migration 068 erased customer',
             'migration-068-erased@example.test',
             'active',
             1
         )",
    )
    .execute(&db.pool)
    .await
    .expect("seed erased tombstone customer");
    sqlx::query(
        "INSERT INTO algolia_import_jobs
         (id, customer_id, tenant_id, algolia_app_id, destination_kind, logical_target,
          destination_region, source_name, lifecycle_generation, idempotency_key,
          canonical_fingerprint, source_size_bytes)
         VALUES (
             '11111111-1111-4111-8111-111111116821',
             '11111111-1111-4111-8111-111111116823',
             'erased_products',
             'ERASED123',
             'create',
             'erased_products',
             'us-east-1',
             'Products',
             1,
             'erased-provider-row',
             'sha256:c2992025238bfb03f40af1149aa4d2e08978b58c4c0e72669950b73f08c88b50',
             2048
         )",
    )
    .execute(&db.pool)
    .await
    .expect("seed public pre-068 import row");
    sqlx::query(
        "UPDATE algolia_import_jobs SET
            erased_at = NOW(),
            erasure_handle = '11111111-1111-4111-8111-111111116822',
            cleanup_phase = 'engine_disposition_required',
            customer_id = NULL, tenant_id = NULL, algolia_app_id = NULL,
            destination_kind = NULL, logical_target = NULL, destination_region = NULL,
            destination_deployment_id = NULL, physical_uid = NULL, source_name = NULL,
            cloud_job_id = NULL, dispatch_intent_state = NULL, lifecycle_generation = NULL,
            idempotency_key = NULL, canonical_fingerprint = NULL, routing_identity = NULL,
            source_size_bytes = NULL, reserved_index_count = NULL,
            reserved_customer_storage_bytes = NULL, reserved_node_transient_bytes = NULL,
            retryable = NULL, worker_claimed_at = NULL, worker_lease_expires_at = NULL,
            cancel_requested_at = NULL, resume_intent_generation = NULL,
            resume_checkpoint = NULL, resume_deadline = NULL,
            resume_status_observed_at = NULL, resumable = NULL, resume_count = NULL,
            documents_expected = NULL, documents_imported = NULL,
            documents_rejected = NULL, settings_applied = NULL,
            settings_unsupported = NULL, synonyms_expected = NULL,
            synonyms_imported = NULL, synonyms_rejected = NULL, rules_expected = NULL,
            rules_imported = NULL, rules_rejected = NULL, terminal_outcome_observed = NULL,
            warnings = NULL, error_code = NULL, error_message = NULL, status = NULL,
            terminal_at = NULL
         WHERE id = '11111111-1111-4111-8111-111111116821'",
    )
    .execute(&db.pool)
    .await
    .expect("scrub public row into valid pre-068 erased tombstone");

    sqlx::raw_sql(include_str!(
        "../../../migrations/068_provider_neutral_algolia_import_jobs.sql"
    ))
    .execute(&db.pool)
    .await
    .expect("migration 068 must upgrade existing erased tombstones");

    let provider: Option<String> = sqlx::query_scalar(
        "SELECT source_provider
         FROM algolia_import_jobs
         WHERE id = '11111111-1111-4111-8111-111111116821'",
    )
    .fetch_one(&db.pool)
    .await
    .expect("read migrated erased tombstone");
    assert_eq!(provider, None);
}

#[tokio::test]
async fn migration_068_backfills_algolia_provider_without_rewriting_fingerprint() {
    let Some(db) = connect_without_migrations("migration_068_provider_neutral").await else {
        return;
    };

    migrate_through_version(&db.pool, 67)
        .await
        .expect("run migrations before provider discriminator");

    let canonical_fingerprint =
        "sha256:bd7583de7ff271c353aa6c6d6c3cf9af4337c3e8f5d2b630ca2f2cc17788a0e5";
    sqlx::query(
        "INSERT INTO customers (id, name, email, status, lifecycle_generation)
         VALUES (
             '11111111-1111-4111-8111-111111116801',
             'Migration 068 customer',
             'migration-068@example.test',
             'active',
             1
         )",
    )
    .execute(&db.pool)
    .await
    .expect("seed customer");
    sqlx::query(
        "INSERT INTO algolia_import_jobs
         (id, customer_id, tenant_id, algolia_app_id, destination_kind, logical_target,
          destination_region, source_name, lifecycle_generation, idempotency_key,
          canonical_fingerprint, source_size_bytes)
         VALUES (
             '11111111-1111-4111-8111-111111116802',
             '11111111-1111-4111-8111-111111116801',
             'legacy_products',
             'LEGACY123',
             'create',
             'legacy_products',
             'us-east-1',
             'Products',
             1,
             'legacy-provider-row',
             $1,
             4096
         )",
    )
    .bind(canonical_fingerprint)
    .execute(&db.pool)
    .await
    .expect("seed pre-068 Algolia import row");

    sqlx::raw_sql(include_str!(
        "../../../migrations/068_provider_neutral_algolia_import_jobs.sql"
    ))
    .execute(&db.pool)
    .await
    .expect("migration 068 must add provider discriminator");

    let legacy_row: (String, String) = sqlx::query_as(
        "SELECT source_provider, canonical_fingerprint
         FROM algolia_import_jobs
         WHERE id = '11111111-1111-4111-8111-111111116802'",
    )
    .fetch_one(&db.pool)
    .await
    .expect("read migrated legacy row");
    assert_eq!(legacy_row.0, "algolia");
    assert_eq!(legacy_row.1, canonical_fingerprint);
}

#[tokio::test]
async fn migration_068_accepts_explicit_algolia_provider_for_new_rows() {
    let Some(db) = connect_without_migrations("migration_068_explicit_algolia").await else {
        return;
    };

    migrate_through_version(&db.pool, 68)
        .await
        .expect("run migrations through provider discriminator");

    sqlx::query(
        "INSERT INTO customers (id, name, email, status, lifecycle_generation)
         VALUES (
             '11111111-1111-4111-8111-111111116811',
             'Migration 068 explicit customer',
             'migration-068-explicit@example.test',
             'active',
             1
         )",
    )
    .execute(&db.pool)
    .await
    .expect("seed customer");
    sqlx::query(
        "INSERT INTO algolia_import_jobs
         (id, source_provider, customer_id, tenant_id, algolia_app_id, destination_kind,
          logical_target, destination_region, source_name, lifecycle_generation,
          idempotency_key, canonical_fingerprint, source_size_bytes)
         VALUES (
             '11111111-1111-4111-8111-111111116812',
             'algolia',
             '11111111-1111-4111-8111-111111116811',
             'explicit_products',
             'EXPLICT123',
             'create',
             'explicit_products',
             'us-east-1',
             'Products',
             1,
             'explicit-provider-row',
             'sha256:6a5b40f832bb5436ae1cc8a7ec513d0236af1994fd06dba41240c0833f4b9ab7',
             8192
         )",
    )
    .execute(&db.pool)
    .await
    .expect("insert explicit post-068 Algolia row");

    let provider: String = sqlx::query_scalar(
        "SELECT source_provider
         FROM algolia_import_jobs
         WHERE id = '11111111-1111-4111-8111-111111116812'",
    )
    .fetch_one(&db.pool)
    .await
    .expect("read explicit provider");
    assert_eq!(provider, "algolia");
}
