-- Hetzner region pricing: add region multipliers for Hetzner Cloud locations.
-- Hetzner is generally cheaper than AWS, reflected in sub-1.0 multipliers.
-- Regions without an explicit multiplier default to 1.0× (standard AWS pricing).

UPDATE rate_cards
SET region_multipliers = region_multipliers || '{
    "eu-central-1": 0.70,
    "eu-north-1": 0.75,
    "us-east-2": 0.80,
    "us-west-1": 0.80
}'::jsonb
WHERE name = 'launch-2026';
