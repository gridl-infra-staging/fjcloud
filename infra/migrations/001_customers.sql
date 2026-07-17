-- Customers: one row per paying account.
CREATE TABLE customers (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name                TEXT        NOT NULL,
    email               TEXT        NOT NULL UNIQUE,
    stripe_customer_id  TEXT,
    status              TEXT        NOT NULL DEFAULT 'active'
                            CHECK (status IN ('active', 'suspended', 'deleted')),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_customers_email  ON customers(email);
CREATE INDEX idx_customers_status ON customers(status);
