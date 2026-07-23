-- Retain destination VMs while erased Algolia imports still require exact-target cleanup.
--
-- Live quota and logical-target ownership remains in
-- algolia_import_job_has_active_reservation. This forward migration extends
-- only the canonical VM blocker so opaque erased work cannot lose its engine
-- cleanup target before both absence and durable acknowledgement are known.

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
                engine_ack_state
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
