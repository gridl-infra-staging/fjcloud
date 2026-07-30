use super::*;

pub(super) struct LegacyErasedSpecimen {
    pub job_id: Uuid,
    pub erasure_handle: Uuid,
}

pub(super) async fn seed_migration_067_erased_specimen_on_vm(
    pool: &PgPool,
    idempotency_key: &str,
    destination_vm_id: Uuid,
) -> LegacyErasedSpecimen {
    let job_id = Uuid::new_v4();
    let customer_id = Uuid::new_v4();
    let engine_job_id = Uuid::new_v4();
    let erasure_handle = Uuid::new_v4();
    insert_active_customer(pool, customer_id, 1).await;

    sqlx::query(
        "INSERT INTO algolia_import_jobs
         (id, customer_id, tenant_id, algolia_app_id, destination_kind, logical_target,
          destination_region, source_name, lifecycle_generation, idempotency_key,
          canonical_fingerprint, source_size_bytes)
         VALUES ($1, $2, $3, 'AB12CD34EF', 'create', $3, $4, $5, 1, $6, $7, $8)",
    )
    .bind(job_id)
    .bind(customer_id)
    .bind(LOGICAL_TARGET_PII_CANARY)
    .bind(REGION)
    .bind(SOURCE_NAME_PII_CANARY)
    .bind(idempotency_key)
    .bind(format!("sha256:{job_id}"))
    .bind(12_345_i64)
    .execute(pool)
    .await
    .expect("seed pre-068 public import row");

    sqlx::query(
        "UPDATE algolia_import_jobs SET
            erased_at = $2,
            erasure_handle = $3,
            cleanup_phase = 'exact_target_absence_required',
            destination_vm_id = $4,
            engine_job_id = $5,
            customer_id = NULL, tenant_id = NULL, algolia_app_id = NULL,
            destination_kind = NULL, logical_target = NULL, destination_region = NULL,
            destination_deployment_id = NULL, physical_uid = NULL, source_name = NULL,
            cloud_job_id = NULL, dispatch_intent_state = NULL, lifecycle_generation = NULL,
            idempotency_key = NULL, canonical_fingerprint = NULL, routing_identity = NULL,
            source_size_bytes = NULL, reserved_index_count = NULL,
            reserved_customer_storage_bytes = NULL, reserved_node_transient_bytes = NULL,
            retryable = NULL, worker_claimed_at = NULL, worker_lease_expires_at = NULL,
            cancel_requested_at = NULL, resume_intent_generation = NULL,
            resume_checkpoint = NULL, resume_deadline = NULL, resume_status_observed_at = NULL,
            resumable = NULL, resume_count = NULL, documents_expected = NULL,
            documents_imported = NULL, documents_rejected = NULL, settings_applied = NULL,
            settings_unsupported = NULL, synonyms_expected = NULL, synonyms_imported = NULL,
            synonyms_rejected = NULL, rules_expected = NULL, rules_imported = NULL,
            rules_rejected = NULL, warnings = NULL, error_code = NULL, error_message = NULL,
            status = NULL, terminal_at = NULL, terminal_outcome_observed = NULL
         WHERE id = $1",
    )
    .bind(job_id)
    .bind(postgres_timestamp(Utc::now()))
    .bind(erasure_handle)
    .bind(destination_vm_id)
    .bind(engine_job_id)
    .execute(pool)
    .await
    .expect("scrub pre-068 public row into migration-066 erased tombstone");

    LegacyErasedSpecimen {
        job_id,
        erasure_handle,
    }
}
