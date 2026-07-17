-- Cold storage pricing: add cold rate and shared minimum to rate_cards.

ALTER TABLE rate_cards
    ADD COLUMN cold_storage_rate_per_gb_month NUMERIC(10,6) NOT NULL DEFAULT 0.020000,
    ADD COLUMN shared_minimum_spend_cents BIGINT NOT NULL DEFAULT 200;

-- Seed the launch rate card with cold storage pricing.
UPDATE rate_cards
    SET cold_storage_rate_per_gb_month = 0.020000,
        shared_minimum_spend_cents = 200
    WHERE name = 'launch-2026';
