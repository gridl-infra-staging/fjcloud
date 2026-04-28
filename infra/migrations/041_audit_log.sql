-- 041_audit_log.sql — append-only operator-action audit trail.
--
-- Owns the "who did what to whom and when" record for high-trust admin
-- write paths (impersonation token issuance, customer suspend/reactivate,
-- hard erasure, etc.). Tokens themselves are stateless JWTs with no DB
-- persistence, so this table is the durable trail.
--
-- Read pattern (T1.4 builds the per-customer view):
--   SELECT * FROM audit_log
--    WHERE target_tenant_id = $1
--    ORDER BY created_at DESC
--    LIMIT 100
-- The composite index below supports that exact pattern.
--
-- Schema decisions worth keeping in mind (so a future agent doesn't undo them):
--
--   * `target_tenant_id` is NULLABLE because some auditable actions don't
--     target a specific customer (e.g. an "operator opened admin console"
--     event might be logged with no target). Don't mark NOT NULL without
--     re-checking every call site.
--
--   * `metadata` is JSONB rather than TEXT so we can later add typed
--     inspection / GIN index without rewriting historical rows. Empty rows
--     default to '{}'::jsonb so reads are uniformly Object.
--
--   * `actor_id` references no FK by design. The single-shared-admin-key
--     auth model (see auth/admin.rs) means we cannot attribute to a
--     particular human admin today; the helper `write_audit_log` writes
--     a sentinel UUID for now. When per-admin auth lands, switch the
--     sentinel for the real id and (optionally) add an FK to a future
--     `admin_users` table — a pure ALTER TABLE, no row migration needed.
--
--   * Rows are append-only. No UPDATE / DELETE in the application path.
--     Retention pruning (T1.4 follow-up) runs as a scheduled background
--     job and TRUNCATEs partitions / DELETEs by created_at < NOW() -
--     INTERVAL '1 year' — but that's not in scope for T0.2.

CREATE TABLE IF NOT EXISTS audit_log (
    id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_id          UUID        NOT NULL,
    action            TEXT        NOT NULL,
    target_tenant_id  UUID        NULL,
    metadata          JSONB       NOT NULL DEFAULT '{}'::jsonb,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- T1.4's per-customer audit timeline view filters by target_tenant_id and
-- orders by created_at DESC. A composite index covers that exact query.
CREATE INDEX IF NOT EXISTS idx_audit_log_target_tenant_created
    ON audit_log (target_tenant_id, created_at DESC);
