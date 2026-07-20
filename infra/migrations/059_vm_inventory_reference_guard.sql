-- VM inventory retirement reference guard.
--
-- This migration owns both persisted-reference blocker enumeration and
-- per-column reference eligibility. Writers keep their existing insert/update
-- paths; retirement callers and triggers consume these functions instead of
-- duplicating lifecycle predicates.

CREATE FUNCTION algolia_import_job_has_active_reservation(
    erased_at TIMESTAMPTZ,
    publication_disposition TEXT,
    resumable BOOLEAN,
    status TEXT,
    engine_ack_state TEXT
)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
AS $$
    SELECT erased_at IS NULL AND (
        publication_disposition = 'unknown'
        OR resumable = TRUE
        OR status NOT IN (
            'completed', 'completed_with_warnings', 'cancelled', 'failed', 'interrupted'
        )
        OR engine_ack_state NOT IN ('not_applicable', 'seal_acknowledged', 'acknowledged')
    )
$$;

CREATE FUNCTION vm_inventory_reference_blockers(target_vm_id UUID)
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
       AND algolia_import_job_has_active_reservation(
            erased_at,
            publication_disposition,
            resumable,
            status,
            engine_ack_state
       )
$$;

CREATE FUNCTION vm_inventory_reference_allowed(
    target_vm_id UUID,
    reference_table TEXT,
    reference_column TEXT
)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
AS $$
    SELECT CASE inventory.status
        WHEN 'active' THEN TRUE
        WHEN 'draining' THEN (reference_table, reference_column) IN (
            ('index_migrations', 'source_vm_id'),
            ('cold_snapshots', 'source_vm_id'),
            ('index_replicas', 'primary_vm_id')
        )
        ELSE FALSE
    END
    FROM vm_inventory inventory
    WHERE inventory.id = target_vm_id
$$;

CREATE FUNCTION enforce_vm_inventory_reference_allowed()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    new_vm_id UUID;
    old_vm_id UUID;
    inventory_status TEXT;
BEGIN
    EXECUTE format('SELECT ($1).%I::uuid', TG_ARGV[1]) USING NEW INTO new_vm_id;

    IF TG_OP = 'UPDATE' THEN
        EXECUTE format('SELECT ($1).%I::uuid', TG_ARGV[1]) USING OLD INTO old_vm_id;
        IF new_vm_id IS NOT DISTINCT FROM old_vm_id THEN
            RETURN NEW;
        END IF;
    END IF;

    IF new_vm_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT status
      INTO inventory_status
      FROM vm_inventory
     WHERE id = new_vm_id
     FOR KEY SHARE;

    IF inventory_status IS NULL THEN
        RETURN NEW;
    END IF;

    IF NOT vm_inventory_reference_allowed(new_vm_id, TG_ARGV[0], TG_ARGV[1]) THEN
        RAISE EXCEPTION
            'vm_inventory reference %.% to VM % is not allowed while VM status is %',
            TG_ARGV[0], TG_ARGV[1], new_vm_id, inventory_status
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

ALTER TABLE algolia_import_jobs
    ADD CONSTRAINT algolia_import_jobs_destination_vm_id_fkey
    FOREIGN KEY (destination_vm_id) REFERENCES vm_inventory(id);

CREATE TRIGGER trg_customer_tenants_vm_id_vm_inventory_reference_guard
BEFORE INSERT OR UPDATE OF vm_id ON customer_tenants
FOR EACH ROW
EXECUTE FUNCTION enforce_vm_inventory_reference_allowed('customer_tenants', 'vm_id');

CREATE TRIGGER trg_index_migrations_source_vm_id_vm_inventory_reference_guard
BEFORE INSERT OR UPDATE OF source_vm_id ON index_migrations
FOR EACH ROW
EXECUTE FUNCTION enforce_vm_inventory_reference_allowed('index_migrations', 'source_vm_id');

CREATE TRIGGER trg_index_migrations_dest_vm_id_vm_inventory_reference_guard
BEFORE INSERT OR UPDATE OF dest_vm_id ON index_migrations
FOR EACH ROW
EXECUTE FUNCTION enforce_vm_inventory_reference_allowed('index_migrations', 'dest_vm_id');

CREATE TRIGGER trg_cold_snapshots_source_vm_id_vm_inventory_reference_guard
BEFORE INSERT OR UPDATE OF source_vm_id ON cold_snapshots
FOR EACH ROW
EXECUTE FUNCTION enforce_vm_inventory_reference_allowed('cold_snapshots', 'source_vm_id');

CREATE TRIGGER trg_restore_jobs_dest_vm_id_vm_inventory_reference_guard
BEFORE INSERT OR UPDATE OF dest_vm_id ON restore_jobs
FOR EACH ROW
EXECUTE FUNCTION enforce_vm_inventory_reference_allowed('restore_jobs', 'dest_vm_id');

CREATE TRIGGER trg_index_replicas_primary_vm_id_vm_inventory_reference_guard
BEFORE INSERT OR UPDATE OF primary_vm_id ON index_replicas
FOR EACH ROW
EXECUTE FUNCTION enforce_vm_inventory_reference_allowed('index_replicas', 'primary_vm_id');

CREATE TRIGGER trg_index_replicas_replica_vm_id_vm_inventory_reference_guard
BEFORE INSERT OR UPDATE OF replica_vm_id ON index_replicas
FOR EACH ROW
EXECUTE FUNCTION enforce_vm_inventory_reference_allowed('index_replicas', 'replica_vm_id');

CREATE TRIGGER trg_algolia_import_jobs_destination_vm_id_vm_inventory_reference_guard
BEFORE INSERT OR UPDATE OF destination_vm_id ON algolia_import_jobs
FOR EACH ROW
EXECUTE FUNCTION enforce_vm_inventory_reference_allowed('algolia_import_jobs', 'destination_vm_id');
