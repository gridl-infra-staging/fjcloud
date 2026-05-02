# Payment Method Setup Screen Spec

## Scope

- Primary route: `/dashboard/billing/setup`
- Related route: `/dashboard/billing`
- Audience: authenticated customers adding a payment method
- Priority: P0

## User Goal

Add a payment method through the Stripe Elements setup flow or understand why payment setup is unavailable locally.

## Target Behavior

The `/dashboard/billing/setup` route data contract is owned by `web/src/routes/dashboard/billing/setup/+page.server.ts::load`: it returns `billingUnavailable`, `clientSecret`, and optional `error`.

Runtime Stripe bootstrap is owned by `web/src/lib/stripe.ts::getStripe`, which fetches the publishable key from `web/src/routes/api/stripe/publishable-key/+server.ts::GET` and caches the loaded Stripe instance.

Rendering and setup-confirmation UX are owned by `web/src/routes/dashboard/billing/setup/+page.svelte`: when `billingUnavailable` is true it renders `BillingUnavailableCard`; when `clientSecret` exists it mounts Stripe Payment Element, renders `Cancel`, and submits `Save payment method`. Successful setup returns to `/dashboard/billing`.

## Required States

- Loading: Stripe Elements mount after client-side initialization; submit button remains present.
- Empty: missing client secret or disabled billing shows the billing-unavailable/error state rather than an empty form.
- Error: Stripe confirmation errors or setup-intent failures show a visible alert.
- Success: successful confirmation redirects back to `/dashboard/billing`.

## Controls And Navigation

- Stripe Payment Element owns card/payment input controls.
- `Save payment method` submits the Stripe setup confirmation and changes to `Saving...` while submitting.
- `Cancel` links back to `/dashboard/billing`.

## Acceptance Criteria

- [ ] Setup route renders `Add Payment Method`.
- [ ] Billing-unavailable environments show deterministic unavailable copy.
- [ ] Available environments expose a save action and cancel link.
- [ ] Successful setup returns to `/dashboard/billing`.

## Current Implementation Gaps

Browser-unmocked setup navigation is covered only when local Stripe-backed payment management is available; payment form internals are owned by Stripe Elements and local commerce proof.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/billing.spec.ts`
- Component tests: `web/src/routes/dashboard/billing/setup/setup.test.ts`; `web/src/routes/dashboard/billing/setup/setup.server.test.ts`
- Stripe runtime tests: `web/src/lib/stripe.test.ts`; `web/src/routes/api/stripe/publishable-key/publishable-key.server.test.ts`
- Server/contract tests: `web/src/routes/dashboard/billing/setup/setup.server.test.ts`
- LocalStripe/Mailpit proof: `scripts/local-signoff-commerce.sh`; `docs/design/stage3_local_commerce_proof_contract.md`; `docs/checklists/LOCAL_SIGNOFF_EVIDENCE_TEMPLATE.md`
