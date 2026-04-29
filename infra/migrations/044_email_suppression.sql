CREATE TABLE IF NOT EXISTS email_suppression (
    recipient_email    TEXT        PRIMARY KEY,
    suppression_reason TEXT        NOT NULL,
    source             TEXT        NOT NULL,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_email_suppression_created_at
    ON email_suppression (created_at DESC);
