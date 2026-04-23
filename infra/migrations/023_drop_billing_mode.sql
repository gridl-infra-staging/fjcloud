-- Remove billing_mode column: dedicated hosting has been removed.
-- All customers now use shared infrastructure only.
DROP INDEX IF EXISTS idx_customers_billing_mode;

ALTER TABLE customers DROP COLUMN IF EXISTS billing_mode;
