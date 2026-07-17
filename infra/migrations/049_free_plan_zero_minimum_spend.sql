-- Move Free-plan launch pricing to a true zero minimum without changing Shared minimum semantics.
-- 042 remains immutable because it may already be applied in existing environments.

UPDATE rate_cards
SET minimum_spend_cents = 0
WHERE name = 'launch-2026'
  AND effective_until IS NULL;
