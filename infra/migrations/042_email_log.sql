-- 042_email_log.sql — per-recipient broadcast delivery outcomes.
--
-- Stage 3 test-audit pins the contract that a live admin broadcast writes
-- one row per attempted recipient (success OR failure). Keep this schema
-- intentionally narrow until route behavior is implemented in Stage 4.

CREATE TABLE IF NOT EXISTS email_log (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    recipient_email TEXT        NOT NULL,
    subject         TEXT        NOT NULL,
    delivery_status TEXT        NOT NULL CHECK (delivery_status IN ('success', 'failed')),
    error_message   TEXT        NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Stage 3 tests query by subject and then inspect one row per recipient.
CREATE INDEX IF NOT EXISTS idx_email_log_subject_created
    ON email_log (subject, created_at DESC);
