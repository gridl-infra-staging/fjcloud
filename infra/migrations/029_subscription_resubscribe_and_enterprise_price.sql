-- Allow re-subscription after cancellation by limiting customer uniqueness
-- to non-canceled rows only.
ALTER TABLE subscriptions
    DROP CONSTRAINT IF EXISTS subscriptions_customer_id_key;

CREATE UNIQUE INDEX idx_subscriptions_customer_non_canceled_unique
    ON subscriptions(customer_id)
    WHERE status <> 'canceled';

-- Enterprise is custom priced, so price_cents_monthly should be nullable.
ALTER TABLE subscription_plans
    ALTER COLUMN price_cents_monthly DROP NOT NULL;

UPDATE subscription_plans
SET price_cents_monthly = NULL
WHERE tier = 'enterprise';

ALTER TABLE subscription_plans
    ADD CONSTRAINT subscription_plans_enterprise_custom_price_ck
    CHECK (
        (tier = 'enterprise' AND price_cents_monthly IS NULL)
        OR
        (tier IN ('starter', 'pro') AND price_cents_monthly IS NOT NULL)
    );
