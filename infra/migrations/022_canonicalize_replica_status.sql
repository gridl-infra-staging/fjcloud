-- Canonicalize replica status: rename "replicating" to "syncing".
--
-- The orchestrator code already writes "syncing" for replicas in the
-- replication-convergence phase, but migration 021 only included
-- "replicating" in the CHECK constraint.  This migration:
--   1. Replaces the CHECK to use "syncing" instead of "replicating"
--   2. Migrates any existing "replicating" rows to "syncing"

-- Migrate existing data first (while old CHECK still allows "replicating")
UPDATE index_replicas SET status = 'syncing' WHERE status = 'replicating';

-- Replace the CHECK constraint: drop old, add new with "syncing"
ALTER TABLE index_replicas DROP CONSTRAINT IF EXISTS index_replicas_status_check;
ALTER TABLE index_replicas ADD CONSTRAINT index_replicas_status_check
    CHECK (status IN ('provisioning', 'syncing', 'active', 'stale', 'removing', 'failed'));
