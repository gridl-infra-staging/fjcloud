-- Canonical mapping from OAuth provider identities to existing customer rows.
-- This table is the schema owner for external identity linkage and enforces:
--   1) one unique row per (provider, provider_user_id) pair
--   2) referential integrity to customers with ON DELETE CASCADE semantics
CREATE TABLE oauth_identities (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id         UUID        NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
    provider            TEXT        NOT NULL,
    provider_user_id    TEXT        NOT NULL,
    linked_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (provider, provider_user_id)
);

CREATE INDEX idx_oauth_identities_customer_id
    ON oauth_identities(customer_id);
