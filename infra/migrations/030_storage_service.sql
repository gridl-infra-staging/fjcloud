-- Storage buckets: customer-facing bucket metadata mapping to internal Garage buckets
CREATE TABLE storage_buckets (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id           UUID NOT NULL REFERENCES customers(id),
    name                  TEXT NOT NULL,
    garage_bucket         TEXT NOT NULL,
    size_bytes            BIGINT NOT NULL DEFAULT 0,
    object_count          BIGINT NOT NULL DEFAULT 0,
    egress_bytes          BIGINT NOT NULL DEFAULT 0,
    egress_watermark_bytes BIGINT NOT NULL DEFAULT 0,
    status                TEXT NOT NULL DEFAULT 'active'
                          CHECK (status IN ('active', 'deleted')),
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Only one active bucket per customer+name (deleted buckets don't conflict)
CREATE UNIQUE INDEX idx_storage_buckets_customer_name_active
    ON storage_buckets (customer_id, name)
    WHERE status != 'deleted';

CREATE INDEX idx_storage_buckets_customer_id
    ON storage_buckets (customer_id);

-- Storage access keys: S3-compatible credentials with encrypted secrets
CREATE TABLE storage_access_keys (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id     UUID NOT NULL REFERENCES customers(id),
    bucket_id       UUID NOT NULL REFERENCES storage_buckets(id),
    access_key      TEXT NOT NULL UNIQUE,
    garage_access_key_id TEXT NOT NULL UNIQUE,
    secret_key_enc  BYTEA NOT NULL,
    secret_key_nonce BYTEA NOT NULL,
    label           TEXT NOT NULL DEFAULT '',
    revoked_at      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Fast lookup of active (non-revoked) keys during S3 auth
CREATE INDEX idx_storage_access_keys_active
    ON storage_access_keys (access_key)
    WHERE revoked_at IS NULL;

CREATE INDEX idx_storage_access_keys_bucket_id
    ON storage_access_keys (bucket_id);
