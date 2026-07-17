-- Raw usage events written by the metering agent on every scrape.
-- The idempotency_key unique constraint ensures retries never double-count.
CREATE TABLE usage_records (
    id                  BIGSERIAL   PRIMARY KEY,
    idempotency_key     TEXT        NOT NULL UNIQUE,
    customer_id         UUID        NOT NULL REFERENCES customers(id),
    tenant_id           TEXT        NOT NULL,
    region              TEXT        NOT NULL,
    node_id             TEXT        NOT NULL,
    event_type          TEXT        NOT NULL
                            CHECK (event_type IN (
                                'search_requests',
                                'write_operations',
                                'documents_indexed',
                                'documents_deleted',
                                'storage_bytes',
                                'document_count'
                            )),
    -- For counter events: delta since the last scrape.
    -- For gauge events (storage_bytes, document_count): point-in-time snapshot.
    value               BIGINT      NOT NULL,
    recorded_at         TIMESTAMPTZ NOT NULL,
    flapjack_ts         TIMESTAMPTZ NOT NULL
);

CREATE INDEX idx_usage_customer_ts   ON usage_records(customer_id, recorded_at);
CREATE INDEX idx_usage_tenant_ts     ON usage_records(tenant_id, recorded_at);
CREATE INDEX idx_usage_event_type    ON usage_records(event_type, recorded_at);

-- Daily aggregates: rolled up from usage_records by the aggregation job.
-- One row per (customer, date, region).
CREATE TABLE usage_daily (
    customer_id             UUID        NOT NULL REFERENCES customers(id),
    date                    DATE        NOT NULL,
    region                  TEXT        NOT NULL,
    search_requests         BIGINT      NOT NULL DEFAULT 0,
    write_operations        BIGINT      NOT NULL DEFAULT 0,
    -- Time-weighted average bytes stored during this calendar day.
    storage_bytes_avg       BIGINT      NOT NULL DEFAULT 0,
    documents_count_avg     BIGINT      NOT NULL DEFAULT 0,
    aggregated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (customer_id, date, region)
);

CREATE INDEX idx_usage_daily_date ON usage_daily(date);
