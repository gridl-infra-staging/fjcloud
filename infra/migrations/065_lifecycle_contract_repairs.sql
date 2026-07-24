-- Keep persisted lifecycle guards aligned with their canonical Rust contracts.

CREATE FUNCTION algolia_import_job_has_active_reservation(
    erased_at TIMESTAMPTZ,
    publication_disposition TEXT,
    resumable BOOLEAN,
    status TEXT,
    engine_ack_state TEXT,
    dispatch_intent_state TEXT,
    engine_job_id UUID
)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
AS $$
    SELECT erased_at IS NULL AND NOT (
        resumable = FALSE AND (
            (
                engine_ack_state = 'acknowledged'
                AND dispatch_intent_state <> 'absent'
                AND engine_job_id IS NOT NULL
                AND (
                    (status IN ('completed', 'completed_with_warnings')
                     AND publication_disposition = 'promoted')
                    OR (status = 'cancelled' AND publication_disposition = 'unchanged')
                    OR (status = 'failed'
                        AND publication_disposition IN ('unchanged', 'not_started'))
                    OR (status = 'interrupted' AND publication_disposition = 'unchanged')
                )
            )
            OR (
                engine_ack_state = 'not_applicable'
                AND status = 'failed'
                AND publication_disposition = 'not_started'
                AND dispatch_intent_state = 'absent'
                AND engine_job_id IS NULL
            )
            OR (
                engine_ack_state = 'seal_acknowledged'
                AND status = 'interrupted'
                AND publication_disposition = 'not_started'
                AND dispatch_intent_state <> 'absent'
                AND engine_job_id IS NULL
            )
        )
    )
$$;

CREATE OR REPLACE FUNCTION vm_inventory_reference_blockers(target_vm_id UUID)
RETURNS TABLE(owner TEXT, reference_column TEXT, blocker_count BIGINT)
LANGUAGE SQL
STABLE
AS $$
    SELECT 'customer_tenants', 'vm_id', COUNT(*)
      FROM customer_tenants
     WHERE vm_id = target_vm_id
    UNION ALL
    SELECT 'index_migrations', 'source_vm_id', COUNT(*)
      FROM index_migrations
     WHERE source_vm_id = target_vm_id
       AND status NOT IN ('completed', 'failed')
    UNION ALL
    SELECT 'index_migrations', 'dest_vm_id', COUNT(*)
      FROM index_migrations
     WHERE dest_vm_id = target_vm_id
       AND status NOT IN ('completed', 'failed')
    UNION ALL
    SELECT 'cold_snapshots', 'source_vm_id', COUNT(*)
      FROM cold_snapshots
     WHERE source_vm_id = target_vm_id
       AND status IN ('pending', 'exporting', 'completed')
    UNION ALL
    SELECT 'restore_jobs', 'dest_vm_id', COUNT(*)
      FROM restore_jobs
     WHERE dest_vm_id = target_vm_id
       AND status IN ('queued', 'downloading', 'importing')
    UNION ALL
    SELECT 'index_replicas', 'primary_vm_id', COUNT(*)
      FROM index_replicas
     WHERE primary_vm_id = target_vm_id
       AND status NOT IN ('removing', 'failed', 'suspended')
    UNION ALL
    SELECT 'index_replicas', 'replica_vm_id', COUNT(*)
      FROM index_replicas
     WHERE replica_vm_id = target_vm_id
       AND status NOT IN ('removing', 'failed', 'suspended')
    UNION ALL
    SELECT 'algolia_import_jobs', 'destination_vm_id', COUNT(*)
      FROM algolia_import_jobs
     WHERE destination_vm_id = target_vm_id
       AND (
            algolia_import_job_has_active_reservation(
                erased_at,
                publication_disposition,
                resumable,
                status,
                engine_ack_state,
                dispatch_intent_state,
                engine_job_id
            )
            OR (
                erased_at IS NOT NULL
                AND cleanup_phase IN (
                    'exact_target_absence_required',
                    'exact_target_absent'
                )
                AND NOT (
                    cleanup_phase = 'exact_target_absent'
                    AND engine_ack_state = 'acknowledged'
                )
            )
       )
$$;

DROP FUNCTION algolia_import_job_has_active_reservation(
    TIMESTAMPTZ, TEXT, BOOLEAN, TEXT, TEXT
);

ALTER TABLE vm_lifecycle_events
    DROP CONSTRAINT vm_lifecycle_events_check,
    ADD CONSTRAINT vm_lifecycle_events_replacement_refused_guardrail_check
    CHECK (
        event_type <> 'replacement_refused'
        OR COALESCE(
            jsonb_typeof(detail -> 'guardrail') = 'string'
            AND btrim(detail ->> 'guardrail') <> '',
            FALSE
        )
    );
