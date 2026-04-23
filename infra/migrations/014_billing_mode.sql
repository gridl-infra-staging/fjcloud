-- Add customer billing mode for Stage 7 shared vs dedicated routing behavior.
ALTER TABLE customers
    ADD COLUMN billing_mode TEXT NOT NULL DEFAULT 'shared'
        CHECK (billing_mode IN ('shared', 'dedicated'));

CREATE INDEX idx_customers_billing_mode ON customers (billing_mode);
