-- Persist resend-verification cooldown state on the customer row.
-- This keeps the 60-second resend window durable across process restarts
-- and avoids introducing a separate auth-only state table.
ALTER TABLE customers
    ADD COLUMN resend_verification_sent_at TIMESTAMPTZ NULL;
