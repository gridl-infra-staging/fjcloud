-- Add carry-forward column for sub-cent object-storage egress remainders.
-- Stored as fixed-scale decimal cents (e.g. 0.37 cents) so invoice
-- finalization can persist fractional remainders without precision loss.
-- DEFAULT 0 ensures existing INSERT paths keep working without changes.
ALTER TABLE customers
    ADD COLUMN object_storage_egress_carryforward_cents NUMERIC(12,4) NOT NULL DEFAULT 0;
