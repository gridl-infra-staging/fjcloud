-- Persist password-reset resend cooldown state on the customer row.
-- Mirrors resend-verification cooldown durability so route handlers can
-- fail closed on email-delivery errors and roll back reserved reset tokens.
ALTER TABLE customers
    ADD COLUMN resend_password_reset_sent_at TIMESTAMPTZ NULL;
