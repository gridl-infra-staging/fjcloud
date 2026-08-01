-- Persist privileged operators separately from the shared startup credential.
-- audit_log.actor_id intentionally has no foreign key to this table: later
-- stable SES and Stripe system actors share that audit identity namespace.
CREATE TABLE admin_users (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    identifier          TEXT        NOT NULL UNIQUE,
    credential_prefix   TEXT        NOT NULL,
    credential_sha256   TEXT        NOT NULL UNIQUE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    revoked_at          TIMESTAMPTZ NULL
);

CREATE INDEX idx_admin_users_credential_prefix
    ON admin_users(credential_prefix);
