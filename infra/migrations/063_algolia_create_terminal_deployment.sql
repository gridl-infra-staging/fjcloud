DO $$
DECLARE
    destination_constraint TEXT;
BEGIN
    SELECT conname INTO destination_constraint
    FROM pg_constraint
    WHERE conrelid = 'algolia_import_jobs'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) LIKE '%destination_kind = ''create''%'
      AND pg_get_constraintdef(oid) LIKE '%destination_deployment_id IS NULL%'
      AND pg_get_constraintdef(oid) LIKE '%destination_kind = ''replace''%'
      AND pg_get_constraintdef(oid) LIKE '%destination_deployment_id IS NOT NULL%';

    IF destination_constraint IS NOT NULL THEN
        EXECUTE format('ALTER TABLE algolia_import_jobs DROP CONSTRAINT %I', destination_constraint);
    END IF;
END;
$$;

ALTER TABLE algolia_import_jobs
    ADD CONSTRAINT algolia_import_jobs_destination_identity_shape
    CHECK (
        erased_at IS NOT NULL OR
        (destination_kind = 'create'
            AND (
                (destination_deployment_id IS NULL
                    AND ((destination_vm_id IS NULL
                            AND physical_uid IS NULL
                            AND routing_identity IS NULL)
                        OR (destination_vm_id IS NOT NULL
                            AND physical_uid IS NOT NULL
                            AND routing_identity IS NOT NULL)))
                OR
                (destination_deployment_id IS NOT NULL
                    AND destination_vm_id IS NOT NULL
                    AND physical_uid IS NOT NULL
                    AND routing_identity IS NOT NULL
                    AND status IN ('completed', 'completed_with_warnings')
                    AND publication_disposition = 'promoted'
                    AND engine_ack_state IN ('outbox_pending', 'acknowledged'))
            ))
        OR
        (destination_kind = 'replace'
            AND destination_deployment_id IS NOT NULL
            AND destination_vm_id IS NOT NULL
            AND physical_uid IS NOT NULL
            AND routing_identity IS NOT NULL)
    );
