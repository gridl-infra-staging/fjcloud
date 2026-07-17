-- Align the active launch rate card with the public marketing pricing contract.
-- This keeps /admin/tenants/{id}/rate-card consistent with MARKETING_PRICING.

UPDATE rate_cards
SET minimum_spend_cents = 1000,
    shared_minimum_spend_cents = 500,
    region_multipliers = '{
        "us-east-1": "1.0",
        "eu-west-1": "1.0",
        "eu-central-1": "0.70",
        "eu-north-1": "0.75",
        "us-east-2": "0.80",
        "us-west-1": "0.80"
    }'::jsonb
WHERE name = 'launch-2026'
  AND effective_until IS NULL;
