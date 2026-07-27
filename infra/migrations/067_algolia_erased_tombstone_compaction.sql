-- Allow privacy-scrub compaction to erase the opaque handle mapping only after
-- exact target absence has been durably acknowledged.

DO $$
DECLARE
    erased_shape_constraint TEXT;
BEGIN
    SELECT conname INTO erased_shape_constraint
    FROM pg_constraint
    WHERE conrelid = 'algolia_import_jobs'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) LIKE '%erasure_handle IS NOT NULL%'
      AND pg_get_constraintdef(oid) LIKE '%customer_id IS NULL%'
      AND pg_get_constraintdef(oid) LIKE '%tombstone_compacted_at IS NULL%';

    IF erased_shape_constraint IS NOT NULL THEN
        EXECUTE format(
            'ALTER TABLE algolia_import_jobs DROP CONSTRAINT %I',
            erased_shape_constraint
        );
    END IF;
END;
$$;

ALTER TABLE algolia_import_jobs
    ADD CONSTRAINT algolia_import_jobs_public_or_erased_tombstone_shape
    CHECK (
        (erased_at IS NULL
            AND erasure_handle IS NULL
            AND cleanup_phase = 'public'
            AND tombstone_compacted_at IS NULL
            AND customer_id IS NOT NULL
            AND tenant_id IS NOT NULL
            AND algolia_app_id IS NOT NULL
            AND destination_kind IS NOT NULL
            AND logical_target IS NOT NULL
            AND destination_region IS NOT NULL
            AND source_name IS NOT NULL
            AND cloud_job_id IS NOT NULL
            AND dispatch_intent_state IS NOT NULL
            AND lifecycle_generation IS NOT NULL
            AND idempotency_key IS NOT NULL
            AND canonical_fingerprint IS NOT NULL
            AND source_size_bytes IS NOT NULL
            AND reserved_index_count IS NOT NULL
            AND reserved_customer_storage_bytes IS NOT NULL
            AND reserved_node_transient_bytes IS NOT NULL
            AND retryable IS NOT NULL
            AND resume_intent_generation IS NOT NULL
            AND resumable IS NOT NULL
            AND resume_count IS NOT NULL
            AND documents_expected IS NOT NULL
            AND documents_imported IS NOT NULL
            AND documents_rejected IS NOT NULL
            AND settings_applied IS NOT NULL
            AND settings_unsupported IS NOT NULL
            AND synonyms_expected IS NOT NULL
            AND synonyms_imported IS NOT NULL
            AND synonyms_rejected IS NOT NULL
            AND rules_expected IS NOT NULL
            AND rules_imported IS NOT NULL
            AND rules_rejected IS NOT NULL
            AND warnings IS NOT NULL
            AND status IS NOT NULL)
        OR
        (erased_at IS NOT NULL
            AND (
                (erasure_handle IS NOT NULL
                    AND tombstone_compacted_at IS NULL
                    AND cleanup_phase <> 'public')
                OR
                (tombstone_compacted_at IS NOT NULL
                    AND cleanup_phase = 'exact_target_absent'
                    AND engine_ack_state = 'acknowledged'
                    AND worker_claimed_at IS NULL
                    AND worker_lease_expires_at IS NULL)
            )
            AND customer_id IS NULL
            AND tenant_id IS NULL
            AND algolia_app_id IS NULL
            AND destination_kind IS NULL
            AND logical_target IS NULL
            AND destination_region IS NULL
            AND destination_deployment_id IS NULL
            AND physical_uid IS NULL
            AND source_name IS NULL
            AND cloud_job_id IS NULL
            AND dispatch_intent_state IS NULL
            AND lifecycle_generation IS NULL
            AND idempotency_key IS NULL
            AND canonical_fingerprint IS NULL
            AND routing_identity IS NULL
            AND source_size_bytes IS NULL
            AND reserved_index_count IS NULL
            AND reserved_customer_storage_bytes IS NULL
            AND reserved_node_transient_bytes IS NULL
            AND retryable IS NULL
            AND cancel_requested_at IS NULL
            AND resume_intent_generation IS NULL
            AND resume_checkpoint IS NULL
            AND resume_deadline IS NULL
            AND resume_status_observed_at IS NULL
            AND resumable IS NULL
            AND resume_count IS NULL
            AND documents_expected IS NULL
            AND documents_imported IS NULL
            AND documents_rejected IS NULL
            AND settings_applied IS NULL
            AND settings_unsupported IS NULL
            AND synonyms_expected IS NULL
            AND synonyms_imported IS NULL
            AND synonyms_rejected IS NULL
            AND rules_expected IS NULL
            AND rules_imported IS NULL
            AND rules_rejected IS NULL
            AND warnings IS NULL
            AND error_code IS NULL
            AND error_message IS NULL
            AND status IS NULL)
    );
