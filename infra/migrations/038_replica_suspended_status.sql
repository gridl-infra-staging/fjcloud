-- Add "suspended" status for replicas whose primary was failed over.
--
-- When the region failover monitor promotes a replica by flipping
-- customer_tenants.vm_id, the index_replicas row becomes stale:
-- primary_vm_id still points at the dead VM.  Rather than let the
-- replication orchestrator discover this and mark_failed(), we
-- proactively suspend the replica so the orchestrator skips it.
-- An admin must manually restore the replication topology after
-- the region recovers (matches existing no-auto-switchback policy).

-- Widen the CHECK to accept "suspended"
ALTER TABLE index_replicas DROP CONSTRAINT IF EXISTS index_replicas_status_check;
ALTER TABLE index_replicas ADD CONSTRAINT index_replicas_status_check
    CHECK (status IN ('provisioning', 'syncing', 'active', 'stale', 'removing', 'failed', 'suspended'));

-- Update the partial index used by list_actionable() to also skip suspended rows
DROP INDEX IF EXISTS idx_index_replicas_status;
CREATE INDEX idx_index_replicas_status
    ON index_replicas (status) WHERE status NOT IN ('removing', 'failed', 'suspended');
