# Payment Method Setup Screen Spec

## Scope

- Primary route: `/dashboard/billing/setup`
- Related route: `/dashboard/billing`
- Audience: authenticated customers adding a payment method
- Priority: P0

## User Goal

Add a payment method through the Stripe Elements setup flow or understand why payment setup is unavailable locally.

## Target Behavior

The page shows `Add Payment Method`. If billing is unavailable, it shows the canonical billing-unavailable card. If a setup intent client secret exists, it mounts Stripe Payment Element, exposes `Cancel`, and saves the payment method through Stripe confirmation. Successful setup returns to `/dashboard/billing`.

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
- [ ] Successful setup returns to the payment-method list.

## Current Implementation Gaps

Browser-unmocked setup navigation is covered only when local Stripe-backed payment management is available; payment form internals are owned by Stripe Elements and local commerce proof.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/billing.spec.ts`
- Component tests: `web/src/routes/dashboard/billing/setup/setup.test.ts`; `web/src/routes/dashboard/billing/setup/setup.server.test.ts`
- Server/contract tests: `web/src/routes/dashboard/billing/setup/setup.server.test.ts`; `cd infra && cargo test -p api --test stripe_billing_test`
- LocalStripe/Mailpit proof: `scripts/local-signoff-commerce.sh`; `docs/design/stage3_local_commerce_proof_contract.md`; `docs/checklists/LOCAL_SIGNOFF_EVIDENCE_TEMPLATE.md`
