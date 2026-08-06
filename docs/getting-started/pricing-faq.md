# Pricing FAQ

This page documents the customer-visible pricing contract and its code owners.

## Is there a free tier?

Yes. Every account includes 250 MB of hot index storage before paid billing starts. No credit card is required to sign up.

## What does storage cost?

- Hot index storage: $0.05 per MB per month.
- Cold (snapshot) storage: $0.02 per GB per month.

These values are defined in `web/src/lib/pricing.ts` (`MARKETING_PRICING`) and enforced by the billing engine in `infra/billing/src/rate_card.rs`.

## Is there a minimum spend?

Free-plan estimate and invoice computation has a $0 minimum-spend floor, including when usage exceeds 250 MB. Automated batch billing skips Free customers before invoice creation, so it creates no Free invoice. Shared-plan billing instead applies the effective rate card's `shared_minimum_spend_cents`; the active `launch-2026` migration base is 500 cents ($5/month), and a per-customer rate-card override can change that value before invoice computation.

## Are searches and writes billed?

No. Search requests and write operations are not billed dimensions.

`calculate_invoice` in `infra/billing/src/pricing.rs` applies billable dimensions for storage and object-storage usage only. Search and write counters are usage/quota signals, not invoice line items.

## How does region affect price?

`RateCard::region_multiplier(region)` returns a per-region cost multiplier (defaulting to `1.0` when a region is absent from the map). `calculate_invoice` multiplies each billable storage dimension by this multiplier.

Example: a region configured at 1.3x means storage in that region costs 30% more than the base rate.

## Source Evidence

- Presentation contract and free tier: `web/src/lib/pricing.ts` (`MARKETING_PRICING`, including `free_tier_mb: 250`, `minimum_spend_cents: 0`, and `shared_minimum_spend_cents: 500`).
- Launch minimum migrations: `infra/migrations/042_align_launch_rate_card_marketing_contract.sql` establishes the 500-cent Shared base, and `infra/migrations/049_free_plan_zero_minimum_spend.sql` later sets the active `launch-2026` Free minimum to zero without changing that Shared value.
- Plan-specific invoice floor: `infra/api/src/invoicing/line_items.rs` (`invoice_total_with_minimum()` selects zero for Free and the effective card's `shared_minimum_spend_cents` for Shared).
- Shared override path: `infra/api/src/invoicing.rs` (`compute_invoice_for_customer_with_shared_inputs()` applies the customer override before converting the effective card) and `infra/api/src/models/rate_card.rs` (`RateCardRow::with_overrides()`).
- Free batch skip: `infra/api/src/routes/admin/invoices.rs` (`run_batch_billing()` skips Free customers before invoice computation and creation).
- Region multiplier: `infra/billing/src/rate_card.rs` (`RateCard::region_multiplier`).
- Billing calculator: `infra/billing/src/pricing.rs` (`calculate_invoice`; searches and writes not billed).
