-- Fix restore_jobs idempotency constraint: the unconditional UNIQUE on
-- idempotency_key prevents retrying restores after failures. Replace with
-- a partial unique index that only enforces uniqueness for active jobs.

ALTER TABLE restore_jobs DROP CONSTRAINT IF EXISTS restore_jobs_idempotency_key_key;

CREATE UNIQUE INDEX idx_restore_jobs_active_idempotency
    ON restore_jobs (idempotency_key)
    WHERE status IN ('queued', 'downloading', 'importing');
