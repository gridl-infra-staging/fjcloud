-- Add billing plan for free-tier quota enforcement.
ALTER TABLE customers
    ADD COLUMN billing_plan VARCHAR(20) NOT NULL DEFAULT 'free';

CREATE INDEX idx_customers_billing_plan ON customers(billing_plan);
