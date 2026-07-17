# Payment Method Setup Screen Spec

## Scope

- Primary route: `/console/billing/setup`
- Related route: `/console/billing`
- Audience: authenticated customers adding a payment method
- Priority: P0

## User Goal

Add a payment method through the Stripe Elements setup flow or understand why payment setup is unavailable locally.

## Target Behavior

The `/console/billing/setup` route data contract is owned by `web/src/routes/console/billing/setup/+page.server.ts::load`: it returns `billingUnavailable`, `clientSecret`, and optional `error`.

Runtime Stripe bootstrap is owned by `web/src/lib/stripe.ts::getStripe`, which fetches the publishable key from `web/src/routes/api/stripe/publishable-key/+server.ts::GET` and caches the loaded Stripe instance. Retry cache reset semantics stay in `web/src/lib/stripe.ts::resetStripeBootstrapForRetry` so the form never fetches publishable keys or calls `loadStripe` directly.

Route-level rendering is owned by `web/src/routes/console/billing/setup/+page.svelte`: when `billingUnavailable` is true it renders `BillingUnavailableCard`; when `clientSecret` exists it renders `PaymentMethodSetupForm` and keeps server-provided setup alerts distinct from form bootstrap alerts.

Rendering and setup-confirmation UX are owned by `web/src/routes/console/billing/PaymentMethodSetupForm.svelte`: it mounts Stripe Payment Element, renders `Cancel`, and submits `Save payment method`. Redirecting successes return to `/console/billing`; same-route `redirect: 'if_required'` successes invalidate billing data and show the `Payment method saved` toast.

## Required States

- Loading: Stripe Elements mount after client-side initialization; submit button remains present.
- Empty: missing client secret or disabled billing shows the billing-unavailable/error state rather than an empty form.
- Error: Stripe confirmation errors or setup-intent failures show a visible alert. Null Stripe bootstrap shows the retryable alert `Payment service is unavailable right now. Retry loading the payment form.` with `Retry payment form`, and does not replace the setup form with `BillingUnavailableCard`.
- Success: redirecting successful confirmation returns to `/console/billing`; same-route successful confirmation keeps the customer in place and shows the `Payment method saved` toast.

## Controls And Navigation

- Stripe Payment Element owns card/payment input controls.
- `Save payment method` submits the Stripe setup confirmation and changes to `Saving...` while submitting.
- `Retry payment form` clears failed Stripe bootstrap cache state through `$lib/stripe.ts` and reinitializes Stripe Elements.
- `Cancel` links back to `/console/billing`.

## Acceptance Criteria

- [ ] Setup route renders `Add Payment Method`.
- [ ] Billing-unavailable environments show deterministic unavailable copy.
- [ ] Available environments expose a save action and cancel link.
- [ ] Null Stripe bootstrap shows a retryable form alert without hiding the setup form.
- [ ] Successful redirecting setup returns to `/console/billing`; successful same-route setup shows `Payment method saved`.

## Current Implementation Gaps

Browser-unmocked setup navigation is covered only when local Stripe-backed payment management is available; payment form internals are owned by Stripe Elements and local commerce proof.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/billing.spec.ts`; `web/tests/e2e-ui/full/billing_portal_payment_method_update.spec.ts`
- Component tests: `web/src/routes/console/billing/setup/setup.test.ts`; `web/src/routes/console/billing/setup/setup.server.test.ts`
- Stripe runtime tests: `web/src/lib/stripe.test.ts`; `web/src/routes/api/stripe/publishable-key/publishable-key.server.test.ts`
- Server/contract tests: `web/src/routes/console/billing/setup/setup.server.test.ts`
- LocalStripe/Mailpit proof: `scripts/local-signoff-commerce.sh`; `docs/design/stage3_local_commerce_proof_contract.md`; `docs/checklists/LOCAL_SIGNOFF_EVIDENCE_TEMPLATE.md`
