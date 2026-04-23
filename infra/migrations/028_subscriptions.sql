-- Subscriptions table for Stripe subscription lifecycle management.
-- One active subscription per customer. Historical subscriptions are soft-deleted
-- or archived via status='canceled' rather than hard-deleted.
CREATE TABLE subscriptions (
    id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id             UUID        NOT NULL REFERENCES customers(id),
    stripe_subscription_id  TEXT        NOT NULL UNIQUE,
    stripe_price_id         TEXT        NOT NULL,
    plan_tier               TEXT        NOT NULL
                                CHECK (plan_tier IN ('starter', 'pro', 'enterprise')),
    status                  TEXT        NOT NULL DEFAULT 'active'
                                CHECK (status IN ('active', 'past_due', 'trialing', 'canceled', 'unpaid', 'incomplete')),
    current_period_start    DATE        NOT NULL,
    current_period_end      DATE        NOT NULL,
    cancel_at_period_end    BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- One active subscription per customer (enforced at DB level)
    UNIQUE (customer_id)
);

-- Indexes for common query patterns.
-- Note: customer_id and stripe_subscription_id already have implicit indexes
-- from their UNIQUE constraints, so only status and plan_tier need explicit indexes.
CREATE INDEX idx_subscriptions_status ON subscriptions(status);
CREATE INDEX idx_subscriptions_plan_tier ON subscriptions(plan_tier);

-- Optional: subscription_plans config table for flexible plan configuration.
-- If using env vars for Stripe price IDs, this table may be omitted.
-- Keeping it minimal for now; can be added later if needed.
CREATE TABLE subscription_plans (
    id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tier                    TEXT        NOT NULL UNIQUE
                                CHECK (tier IN ('starter', 'pro', 'enterprise')),
    stripe_product_id       TEXT        NOT NULL,
    stripe_price_id         TEXT        NOT NULL,
    max_searches_per_month  BIGINT      NOT NULL,
    max_records             BIGINT      NOT NULL,
    max_storage_gb          BIGINT      NOT NULL,
    max_indexes             INTEGER     NOT NULL,
    price_cents_monthly     BIGINT      NOT NULL,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Seed the plan definitions based on design note
-- Starter: $29/mo, 100K searches, 500K records, 50GB, 5 indexes
-- Pro: $99/mo, 500K searches, 2M records, 200GB, 20 indexes
-- Enterprise: $299/mo, custom limits (using high defaults)
INSERT INTO subscription_plans (
    tier, stripe_product_id, stripe_price_id,
    max_searches_per_month, max_records, max_storage_gb, max_indexes, price_cents_monthly
) VALUES
    ('starter', 'prod_starter_placeholder', 'price_starter_placeholder',
     100000, 500000, 50, 5, 2900),
    ('pro', 'prod_pro_placeholder', 'price_pro_placeholder',
     500000, 2000000, 200, 20, 9900),
    ('enterprise', 'prod_enterprise_placeholder', 'price_enterprise_placeholder',
     10000000, 100000000, 10000, 1000, 29900);
