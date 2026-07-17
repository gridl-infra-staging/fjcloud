# Pricing FAQ

This page documents the customer-visible pricing contract and its code owners.

## Is there a free tier?

Yes. Every account includes 250 MB of hot index storage before paid billing starts. No credit card is required to sign up.

## What does storage cost?

- Hot index storage: $0.05 per MB per month.
- Cold (snapshot) storage: $0.02 per GB per month.

These values are defined in `web/src/lib/pricing.ts` (`MARKETING_PRICING`) and enforced by the billing engine in `infra/billing/src/rate_card.rs`.

## Is there a minimum spend?

Yes. Once usage exceeds the free tier, a $10/month floor applies (`minimum_spend_cents: 1000` in `RateCard`). Paid-plan customers have a $5/month floor (`shared_minimum_spend_cents: 500`).

## Are searches and writes billed?

No. Search requests and write operations are not billed dimensions.

`calculate_invoice` in `infra/billing/src/pricing.rs` applies billable dimensions for storage and object-storage usage only. Search and write counters are usage/quota signals, not invoice line items.

## How does region affect price?

`RateCard::region_multiplier(region)` returns a per-region cost multiplier (defaulting to `1.0` when a region is absent from the map). `calculate_invoice` multiplies each billable storage dimension by this multiplier.

Example: a region configured at 1.3x means storage in that region costs 30% more than the base rate.

## Source Evidence

- Presentation contract and free tier: `web/src/lib/pricing.ts` (`MARKETING_PRICING`, `free_tier_mb: 250`, `minimum_spend_cents: 1000`).
- Region multiplier and minimum spend: `infra/billing/src/rate_card.rs` (`RateCard::region_multiplier`, `minimum_spend_cents`, `shared_minimum_spend_cents`).
- Billing calculator: `infra/billing/src/pricing.rs` (`calculate_invoice`; searches and writes not billed).
