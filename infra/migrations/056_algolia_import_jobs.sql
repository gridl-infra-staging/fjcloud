-- Public Algolia import lifecycle. This is intentionally distinct from
-- index_migrations, whose sole domain is VM-to-VM movement.
CREATE TABLE algolia_import_environment_contract (
    singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
    rollback_epoch TEXT NOT NULL DEFAULT 'pre_admission'
        CHECK (rollback_epoch IN ('pre_admission', 'migration_aware_required')),
    min_migration_schema_floor BIGINT NOT NULL DEFAULT 56 CHECK (min_migration_schema_floor > 0),
    min_protocol_floor BIGINT NOT NULL DEFAULT 1 CHECK (min_protocol_floor > 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE FUNCTION prevent_algolia_import_environment_contract_rewind()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.rollback_epoch = 'migration_aware_required'
       AND NEW.rollback_epoch = 'pre_admission' THEN
        RAISE EXCEPTION 'algolia import rollback epoch cannot rewind';
    END IF;
    IF NEW.min_migration_schema_floor < OLD.min_migration_schema_floor THEN
        RAISE EXCEPTION 'algolia import schema floor cannot rewind';
    END IF;
    IF NEW.min_protocol_floor < OLD.min_protocol_floor THEN
        RAISE EXCEPTION 'algolia import protocol floor cannot rewind';
    END IF;
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_algolia_import_environment_contract_no_rewind
BEFORE UPDATE ON algolia_import_environment_contract
FOR EACH ROW
EXECUTE FUNCTION prevent_algolia_import_environment_contract_rewind();

INSERT INTO algolia_import_environment_contract
    (singleton, rollback_epoch, min_migration_schema_floor, min_protocol_floor)
VALUES (TRUE, 'pre_admission', 56, 1);

ALTER TABLE customers
    ADD COLUMN lifecycle_generation BIGINT NOT NULL DEFAULT 1
        CHECK (lifecycle_generation >= 0);

CREATE TABLE algolia_import_jobs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id UUID,
    tenant_id TEXT,
    algolia_app_id TEXT CHECK (algolia_app_id ~ '^[A-Z0-9]+$'),
    destination_kind TEXT CHECK (destination_kind IN ('create', 'replace')),
    logical_target TEXT,
    destination_region TEXT,
    destination_deployment_id UUID,
    destination_vm_id UUID,
    physical_uid TEXT,
    source_name TEXT,
    cloud_job_id UUID DEFAULT gen_random_uuid() UNIQUE,
    engine_job_id UUID UNIQUE,
    dispatch_intent_state TEXT DEFAULT 'absent'
        CHECK (dispatch_intent_state IN ('absent', 'committed', 'ambiguous')),
    lifecycle_generation BIGINT CHECK (lifecycle_generation >= 0),
    idempotency_key TEXT,
    canonical_fingerprint TEXT,
    routing_identity TEXT,
    source_size_bytes BIGINT CHECK (source_size_bytes >= 0),
    reserved_index_count BIGINT DEFAULT 0 CHECK (reserved_index_count IN (0, 1)),
    reserved_customer_storage_bytes BIGINT DEFAULT 0 CHECK (reserved_customer_storage_bytes >= 0),
    reserved_node_transient_bytes BIGINT DEFAULT 0 CHECK (reserved_node_transient_bytes >= 0),
    retryable BOOLEAN DEFAULT FALSE,
    worker_claimed_at TIMESTAMPTZ,
    worker_lease_expires_at TIMESTAMPTZ,
    cancel_requested_at TIMESTAMPTZ,
    resume_intent_generation BIGINT DEFAULT 0 CHECK (resume_intent_generation >= 0),
    resume_checkpoint TEXT CHECK (
        resume_checkpoint IS NULL OR octet_length(resume_checkpoint) BETWEEN 1 AND 1024
    ),
    resume_deadline TIMESTAMPTZ,
    resume_status_observed_at TIMESTAMPTZ,
    resumable BOOLEAN DEFAULT FALSE,
    resume_count BIGINT DEFAULT 0 CHECK (resume_count >= 0),
    documents_expected BIGINT DEFAULT 0 CHECK (documents_expected >= 0),
    documents_imported BIGINT DEFAULT 0 CHECK (documents_imported >= 0),
    documents_rejected BIGINT DEFAULT 0 CHECK (documents_rejected >= 0),
    settings_applied BIGINT DEFAULT 0 CHECK (settings_applied >= 0),
    settings_unsupported BIGINT DEFAULT 0 CHECK (settings_unsupported >= 0),
    synonyms_expected BIGINT DEFAULT 0 CHECK (synonyms_expected >= 0),
    synonyms_imported BIGINT DEFAULT 0 CHECK (synonyms_imported >= 0),
    synonyms_rejected BIGINT DEFAULT 0 CHECK (synonyms_rejected >= 0),
    rules_expected BIGINT DEFAULT 0 CHECK (rules_expected >= 0),
    rules_imported BIGINT DEFAULT 0 CHECK (rules_imported >= 0),
    rules_rejected BIGINT DEFAULT 0 CHECK (rules_rejected >= 0),
    warnings JSONB DEFAULT '[]'::jsonb CHECK (jsonb_typeof(warnings) = 'array'),
    error_code TEXT CHECK (error_code IS NULL OR error_code IN (
        'invalid_credentials', 'missing_source_permission', 'source_not_found',
        'source_catalog_too_large', 'destination_conflict', 'quota_exceeded',
        'source_too_large', 'insufficient_engine_storage', 'destination_changed',
        'source_changed', 'incompatible_data', 'engine_upgrade_required',
        'migration_ha_not_supported', 'migration_provider_unsupported',
        'backend_unavailable', 'interrupted', 'cancel_not_permitted',
        'not_resumable', 'internal'
    )),
    error_message TEXT,
    status TEXT DEFAULT 'queued' CHECK (status IN (
        'queued', 'validating_source', 'copying_configuration', 'copying_documents',
        'verifying', 'promoting', 'cancelling', 'cancelled', 'resuming', 'completed',
        'completed_with_warnings', 'failed', 'interrupted'
    )),
    publication_disposition TEXT NOT NULL DEFAULT 'not_started'
        CHECK (publication_disposition IN ('not_started', 'unchanged', 'promoted', 'unknown')),
    engine_ack_state TEXT NOT NULL DEFAULT 'pending'
        CHECK (engine_ack_state IN ('pending', 'not_applicable', 'seal_acknowledged', 'outbox_pending', 'acknowledged')),
    terminal_at TIMESTAMPTZ,
    erasure_handle UUID UNIQUE,
    cleanup_phase TEXT NOT NULL DEFAULT 'public'
        CHECK (cleanup_phase IN ('public', 'engine_disposition_required',
                                 'exact_target_absence_required', 'exact_target_absent')),
    erased_at TIMESTAMPTZ,
    tombstone_compacted_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (customer_id, idempotency_key),
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
            AND erasure_handle IS NOT NULL
            AND cleanup_phase <> 'public'
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
            AND worker_claimed_at IS NULL
            AND worker_lease_expires_at IS NULL
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
    ),
    CHECK (erased_at IS NULL OR terminal_at IS NULL),
    CHECK (tombstone_compacted_at IS NULL OR (
        erased_at IS NOT NULL
        AND cleanup_phase = 'exact_target_absent'
        AND engine_ack_state = 'acknowledged'
    )),
    CHECK (tenant_id = logical_target),
    CHECK (
        erased_at IS NOT NULL OR
        (destination_kind = 'create'
            AND destination_deployment_id IS NULL
            AND ((destination_vm_id IS NULL
                    AND physical_uid IS NULL
                    AND routing_identity IS NULL)
                OR (destination_vm_id IS NOT NULL
                    AND physical_uid IS NOT NULL
                    AND routing_identity IS NOT NULL)))
        OR
        (destination_kind = 'replace'
            AND destination_deployment_id IS NOT NULL
            AND destination_vm_id IS NOT NULL
            AND physical_uid IS NOT NULL
            AND routing_identity IS NOT NULL)
    ),
    CHECK ((status = 'interrupted') = (error_code IS NOT DISTINCT FROM 'interrupted')),
    CHECK (status <> 'cancelled' OR publication_disposition = 'unchanged'),
    CHECK (NOT resumable OR (
        status IN ('failed', 'interrupted')
        AND dispatch_intent_state IN ('committed', 'ambiguous')
        AND engine_job_id IS NOT NULL
        AND resume_checkpoint IS NOT NULL
        AND resume_status_observed_at IS NOT NULL
        AND resume_deadline > resume_status_observed_at
        AND publication_disposition = 'unchanged'
        AND engine_ack_state = 'pending'
    )),
    CHECK (status <> 'interrupted' OR (
        (publication_disposition = 'not_started'
            AND dispatch_intent_state <> 'absent'
            AND engine_job_id IS NULL
            AND engine_ack_state = 'seal_acknowledged')
        OR
        (publication_disposition = 'unchanged'
            AND dispatch_intent_state <> 'absent'
            AND engine_job_id IS NOT NULL
            AND engine_ack_state IN ('pending', 'outbox_pending', 'acknowledged'))
    )),
    CHECK (dispatch_intent_state <> 'absent' OR engine_job_id IS NULL),
    CHECK (engine_ack_state <> 'pending' OR status NOT IN (
        'cancelled', 'completed', 'completed_with_warnings', 'failed', 'interrupted'
    ) OR (
        dispatch_intent_state <> 'absent'
        AND engine_job_id IS NOT NULL
    )),
    CHECK (engine_ack_state <> 'not_applicable' OR erased_at IS NOT NULL OR (
        status = 'failed'
        AND publication_disposition = 'not_started'
        AND dispatch_intent_state = 'absent'
        AND engine_job_id IS NULL
        AND error_code IS NOT NULL
        AND retryable = FALSE
    )),
    CHECK (engine_ack_state <> 'seal_acknowledged' OR erased_at IS NOT NULL OR (
        status = 'interrupted'
        AND publication_disposition = 'not_started'
        AND dispatch_intent_state <> 'absent'
        AND engine_job_id IS NULL
    )),
    CHECK (engine_ack_state NOT IN ('outbox_pending', 'acknowledged') OR erased_at IS NOT NULL OR (
        status IN ('cancelled', 'completed', 'completed_with_warnings', 'failed', 'interrupted')
        AND dispatch_intent_state <> 'absent'
        AND engine_job_id IS NOT NULL
    ))
);

CREATE INDEX idx_algolia_import_jobs_customer_status
    ON algolia_import_jobs (customer_id, status)
    WHERE erased_at IS NULL;
CREATE INDEX idx_algolia_import_jobs_worker_claim
    ON algolia_import_jobs (worker_lease_expires_at)
    WHERE erased_at IS NULL
      AND status NOT IN ('cancelled', 'completed', 'completed_with_warnings', 'failed', 'interrupted');
CREATE INDEX idx_algolia_import_jobs_resume_deadline
    ON algolia_import_jobs (resume_deadline, id)
    WHERE erased_at IS NULL AND resumable = TRUE AND engine_ack_state = 'pending';

CREATE UNIQUE INDEX idx_algolia_import_jobs_active_target
    ON algolia_import_jobs (customer_id, logical_target)
    WHERE erased_at IS NULL AND (publication_disposition = 'unknown'
       OR resumable = TRUE
       OR status NOT IN ('completed', 'completed_with_warnings', 'cancelled', 'failed', 'interrupted')
       OR engine_ack_state NOT IN ('not_applicable', 'seal_acknowledged', 'acknowledged'));
