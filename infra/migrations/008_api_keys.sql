CREATE TABLE api_keys (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id     UUID        NOT NULL REFERENCES customers(id),
    name            TEXT        NOT NULL,
    key_prefix      TEXT        NOT NULL,
    key_hash        TEXT        NOT NULL,
    scopes          TEXT[]      NOT NULL DEFAULT '{}',
    last_used_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    revoked_at      TIMESTAMPTZ
);

CREATE INDEX idx_api_keys_customer_id ON api_keys(customer_id);
CREATE INDEX idx_api_keys_key_prefix  ON api_keys(key_prefix);
