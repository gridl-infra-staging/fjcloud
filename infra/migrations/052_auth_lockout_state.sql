-- Auth lockout state: add durable login-attempt tracking and lockout columns
-- to the existing customers row. Keeps auth state on the canonical row rather
-- than introducing a separate table (same pattern as 006_auth.sql and
-- 047_resend_verification_cooldown.sql).
--
-- 3 live login lockout fields:
ALTER TABLE customers
    ADD COLUMN failed_login_count       INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN failed_login_window_start TIMESTAMPTZ NULL,
    ADD COLUMN login_locked_until       TIMESTAMPTZ NULL;

-- 6 reserve fields for verify/reset lockout (v2, not enforced yet):
ALTER TABLE customers
    ADD COLUMN failed_verify_count          INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN failed_verify_window_start   TIMESTAMPTZ NULL,
    ADD COLUMN verify_locked_until          TIMESTAMPTZ NULL,
    ADD COLUMN failed_reset_count           INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN failed_reset_window_start    TIMESTAMPTZ NULL,
    ADD COLUMN reset_locked_until           TIMESTAMPTZ NULL;
