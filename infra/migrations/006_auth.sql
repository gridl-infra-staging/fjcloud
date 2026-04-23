-- Auth: add password hash, email verification, and password reset support.
ALTER TABLE customers
    ADD COLUMN password_hash              TEXT,
    ADD COLUMN email_verified_at          TIMESTAMPTZ,
    ADD COLUMN email_verify_token         TEXT,
    ADD COLUMN email_verify_expires_at    TIMESTAMPTZ,
    ADD COLUMN password_reset_token       TEXT,
    ADD COLUMN password_reset_expires_at  TIMESTAMPTZ;

CREATE UNIQUE INDEX idx_customers_email_verify_token ON customers(email_verify_token) WHERE email_verify_token IS NOT NULL;
CREATE UNIQUE INDEX idx_customers_password_reset_token ON customers(password_reset_token) WHERE password_reset_token IS NOT NULL;
