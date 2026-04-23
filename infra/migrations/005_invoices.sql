-- Invoices: one per customer per billing period.
CREATE TABLE invoices (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id         UUID        NOT NULL REFERENCES customers(id),
    period_start        DATE        NOT NULL,
    period_end          DATE        NOT NULL,
    subtotal_cents      BIGINT      NOT NULL,   -- before minimum floor
    tax_cents           BIGINT      NOT NULL DEFAULT 0,
    total_cents         BIGINT      NOT NULL,   -- after minimum floor + tax
    currency            TEXT        NOT NULL DEFAULT 'usd',
    status              TEXT        NOT NULL DEFAULT 'draft'
                            CHECK (status IN ('draft', 'finalized', 'paid', 'failed', 'refunded')),
    -- Whether the $5 minimum was applied to bring total up to floor.
    minimum_applied     BOOLEAN     NOT NULL DEFAULT FALSE,
    stripe_invoice_id   TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    finalized_at        TIMESTAMPTZ,
    paid_at             TIMESTAMPTZ,
    UNIQUE (customer_id, period_start, period_end)
);

CREATE INDEX idx_invoices_customer    ON invoices(customer_id, period_start);
CREATE INDEX idx_invoices_status      ON invoices(status);

-- Line items: one row per billing dimension per region per invoice.
CREATE TABLE invoice_line_items (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    invoice_id          UUID        NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
    description         TEXT        NOT NULL,
    -- NUMERIC so storage quantities like "1.5 GB-months" can be stored exactly.
    quantity            NUMERIC(20,6) NOT NULL,
    unit                TEXT        NOT NULL
                            CHECK (unit IN ('requests_1k', 'write_ops_1k', 'gb_months', 'vm_hours')),
    unit_price_cents    NUMERIC(10,4) NOT NULL,
    amount_cents        BIGINT      NOT NULL,
    region              TEXT        NOT NULL,
    metadata            JSONB
);

CREATE INDEX idx_line_items_invoice ON invoice_line_items(invoice_id);
