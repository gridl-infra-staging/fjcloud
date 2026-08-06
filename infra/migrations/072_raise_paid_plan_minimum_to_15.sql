-- Raise the paid-plan monthly minimum from $5 to $15.
--
-- Rationale is recorded in `decisions/2026-08-05_pricing_strategy_decision.md`.
-- In short: Meilisearch's own entry price is $14.88, so $15 is defensible against
-- their published sheet; and Stripe's flat $0.30 consumed 8.8% of a $5 charge
-- versus 4.9% of a $15 one, so the old floor lost nearly a tenth of its revenue
-- to payment processing before covering any cost.
--
-- WHY THIS IS AN `UPDATE` AND NOT A NEW RATE-CARD ROW
--
-- `docs/design/pricing_contract.md` ("Rate card versioning") requires superseding
-- rather than mutating a rate card **that has already priced an invoice**. That
-- condition does not hold yet: paid beta has not launched, so no invoice has been
-- issued against `launch-2026`. Mutating in place is therefore still safe and
-- matches migrations 016, 019, 031, 036, 042 and 049.
--
-- This is the last pricing change for which that is true by default. Once billing
-- runs, the next rate change must close `effective_until` on this row and INSERT a
-- successor, naming every rate column explicitly — several column DEFAULTs have
-- drifted from their live values. See that document before writing it.
--
-- 042 and 049 are left untouched; both are immutable by their own comments.

UPDATE rate_cards
SET shared_minimum_spend_cents = 1500
WHERE name = 'launch-2026'
  AND effective_until IS NULL;
