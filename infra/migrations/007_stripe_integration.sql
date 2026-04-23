-- Stripe integration: add hosted_invoice_url to invoices, create webhook_events table.

ALTER TABLE invoices ADD COLUMN hosted_invoice_url TEXT;

-- Idempotent webhook event tracking: prevents double-processing of Stripe events.
CREATE TABLE webhook_events (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    stripe_event_id TEXT        UNIQUE NOT NULL,
    event_type      TEXT        NOT NULL,
    payload         JSONB       NOT NULL,
    processed_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_webhook_events_stripe_event_id ON webhook_events(stripe_event_id);
