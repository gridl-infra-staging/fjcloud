# Dashboard Billing Screen Spec

## Scope

- Primary route: `/dashboard/billing`
- Related routes: `/dashboard/billing/invoices`
- Audience: authenticated customers managing billing through Stripe Customer Portal
- Priority: P0

## User Goal

Open Stripe Customer Portal from the billing dashboard to manage payment methods and subscription billing details, including payment-recovery flows when subscription billing becomes delinquent.

## Target Behavior

The page shows `Billing` and starts from a server-owned availability seam in `web/src/routes/dashboard/billing/+page.server.ts`: `load()` calls `getPaymentMethods()` and derives `billingUnavailable`, then reads subscription state and derives `subscriptionCancelledBannerText` and `subscriptionRecoveryBannerText`.

UI ownership stays in `web/src/routes/dashboard/billing/+page.svelte`: the available state renders `Manage billing`, dunning recovery copy/CTA when present, and cancellation copy when present; the unavailable state renders the deterministic billing-unavailable card and hides all billing actions.

## Required States

- Loading: route load resolves to available (`Manage billing`) or unavailable state.
- Error: failed portal-session creation shows a visible alert.
- Success: server action redirects with HTTP 303 to Stripe portal session URL.
- Dunning/recovery: when subscription status is delinquent (`past_due`, `unpaid`, `incomplete`, `incomplete_expired`), show exact copy `Payment failed for your subscription. Update your payment method to recover access.` and CTA `Recover payment`.
- Cancellation: when cancellation state is present, show exact copy `Subscription cancelled, ends YYYY-MM-DD`.

## Controls And Navigation

- `Manage billing` submits `POST ?/manageBilling` on `/dashboard/billing`.
- Server action derives `return_url` as `<request origin>/dashboard/billing`, calls `POST /billing/portal`, and redirects with HTTP 303 to Stripe.
- The page intentionally does not include custom add-payment-method, set-default, remove, invoice-management, payment-update, or cancellation controls.

## Copy Contract

- Dunning/recovery banner copy: `Payment failed for your subscription. Update your payment method to recover access.`
- Dunning/recovery CTA label: `Recover payment`
- Cancellation banner copy: `Subscription cancelled, ends YYYY-MM-DD`
- Subscription state source of truth: `infra/api/src/routes/billing.rs::SubscriptionResponse` (`status`, `current_period_end`, `cancel_at_period_end`).

## Acceptance Criteria

- [ ] Default page body renders `Billing`.
- [ ] Available environments without dunning render exactly one actionable billing control: `Manage billing`.
- [ ] Unavailable environments render the deterministic billing-unavailable card and no manage button.
- [ ] Delinquent subscription states render the exact recovery copy and `Recover payment` CTA alongside the server-owned manage-billing form.
- [ ] Billing action ownership remains server-side (`+page.server.ts`) with no client-side redirect logic.

## Current Implementation Gaps

Live portal-cancel verification in real Stripe Customer Portal remains external to this page contract. This screen owns only local rendering and server action handoff state.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/billing.spec.ts`
- Browser-unmocked fresh-signup lifecycle lane: `web/tests/e2e-ui/full/signup_to_paid_invoice.spec.ts`
- Component tests: `web/src/routes/dashboard/billing/billing.test.ts`; `web/src/routes/dashboard/billing/billing.server.test.ts`
- Server/contract tests: `web/src/routes/dashboard/billing/billing.server.test.ts`; `cd infra && cargo test -p api --test billing_endpoints_test`; `cd infra && cargo test -p api --test stripe_billing_test`
- LocalStripe/Mailpit proof: `scripts/local-signoff-commerce.sh`; `docs/design/stage3_local_commerce_proof_contract.md`; `docs/checklists/LOCAL_SIGNOFF_EVIDENCE_TEMPLATE.md`

## Open Questions

- None for Stage 3 contract lock.
