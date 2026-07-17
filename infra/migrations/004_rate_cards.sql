-- Rate cards: pricing rules applied to monthly usage summaries.
-- Only one rate card should have effective_until = NULL (the current one).
CREATE TABLE rate_cards (
    id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    name                    TEXT        NOT NULL,
    effective_from          TIMESTAMPTZ NOT NULL,
    -- NULL means this is the currently active rate card.
    effective_until         TIMESTAMPTZ,
    -- All rates in USD. NUMERIC(10,6) gives sub-cent precision.
    search_rate_per_1k      NUMERIC(10,6) NOT NULL, -- $ per 1,000 search requests
    write_rate_per_1k       NUMERIC(10,6) NOT NULL, -- $ per 1,000 write operations
    storage_rate_per_gb_month     NUMERIC(10,6) NOT NULL, -- $ per GB per billing period
    vm_rate_per_hour        NUMERIC(10,6) NOT NULL, -- $ per VM-hour (Phase 1)
    -- JSON: {"us-east-1": 1.0, "eu-west-1": 1.3}. Missing region = 1.0.
    region_multipliers      JSONB       NOT NULL DEFAULT '{}',
    -- Minimum billable amount per cycle, in cents.
    minimum_spend_cents     BIGINT      NOT NULL DEFAULT 500,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Prevent overlapping active rate cards at the DB level.
CREATE UNIQUE INDEX idx_rate_cards_current
    ON rate_cards(effective_until)
    WHERE effective_until IS NULL;

-- Per-customer rate overrides for enterprise deals.
CREATE TABLE customer_rate_overrides (
    customer_id     UUID        NOT NULL REFERENCES customers(id),
    rate_card_id    UUID        NOT NULL REFERENCES rate_cards(id),
    -- JSON patch: only the fields that differ from the base rate card.
    -- e.g. {"search_rate_per_1k": "0.30", "minimum_spend_cents": 0}
    overrides       JSONB       NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (customer_id, rate_card_id)
);

-- Seed the initial rate card.
INSERT INTO rate_cards (
    name,
    effective_from,
    effective_until,
    search_rate_per_1k,
    write_rate_per_1k,
    storage_rate_per_gb_month,
    vm_rate_per_hour,
    region_multipliers,
    minimum_spend_cents
) VALUES (
    'launch-2026',
    '2026-01-01T00:00:00Z',
    NULL,
    0.500000,   -- $0.50 per 1K searches
    0.100000,   -- $0.10 per 1K writes
    0.200000,   -- $0.20 per GB/month
    0.050000,   -- $0.05 per VM-hour (~$36/month for a t4g.micro)
    '{"eu-west-1": 1.3, "ap-southeast-1": 1.4}',
    500         -- $5.00 minimum
);
