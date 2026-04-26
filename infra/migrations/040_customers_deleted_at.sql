-- Soft-delete support for the customers table. The deleted_at column was
-- originally inlined into 001_customers.sql, which broke sqlx's "applied
-- migrations are immutable" invariant on environments that had already
-- applied 001 (e.g. the 2026-04-09 staging deploy). Reverting 001 to its
-- originally-applied form and adding the deleted_at change as a new
-- migration here keeps the migration history checksum-stable.
--
-- pg_customer_repo.rs reaper queries (find_soft_deleted_due_for_purge,
-- soft_delete_customer) rely on this column existing, so this migration
-- must apply before the new API binary is exposed to traffic.

ALTER TABLE customers
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_customers_deleted_at
    ON customers(deleted_at);
