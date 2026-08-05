CREATE TABLE admin_sessions (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    admin_user_id       UUID        NOT NULL REFERENCES admin_users(id),
    secret_sha256       TEXT        NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_activity_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at          TIMESTAMPTZ NOT NULL,
    revoked_at          TIMESTAMPTZ NULL
);

CREATE INDEX idx_admin_sessions_active_admin_user
    ON admin_sessions(admin_user_id)
    WHERE revoked_at IS NULL;
