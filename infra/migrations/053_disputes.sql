-- Canonical Stripe dispute persistence for chargeback lifecycle handling.
-- Customer ownership is derived via invoice_id -> invoices.customer_id.
CREATE TABLE disputes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    stripe_dispute_id TEXT NOT NULL UNIQUE,
    stripe_charge_id TEXT NOT NULL,
    stripe_payment_intent_id TEXT,
    invoice_id UUID REFERENCES invoices(id) ON DELETE SET NULL,
    amount_cents BIGINT NOT NULL,
    currency TEXT NOT NULL,
    reason TEXT,
    status TEXT NOT NULL,
    evidence_due_by TIMESTAMPTZ,
    disputed_at TIMESTAMPTZ,
    resolved_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_disputes_invoice_id ON disputes(invoice_id);
CREATE INDEX idx_disputes_status ON disputes(status);
CREATE INDEX idx_disputes_stripe_payment_intent_id ON disputes(stripe_payment_intent_id);
