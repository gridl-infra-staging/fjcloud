# Dashboard Billing Screen Spec

## Scope

- Primary route: `/dashboard/billing`
- Related routes: `/dashboard/billing/invoices`
- Audience: authenticated customers managing billing through Stripe Customer Portal
- Priority: P0

## User Goal

Open Stripe Customer Portal from the billing dashboard to manage payment methods and subscription billing details.

## Target Behavior

The page shows `Billing`, renders a single `Manage billing` action that submits to the server action, and relies on server-side redirect to Stripe Customer Portal. When Stripe billing is unavailable in the current environment, the billing-unavailable card replaces the action.

## Required States

- Loading: route load resolves to available (`Manage billing`) or unavailable state.
- Error: failed portal-session creation shows a visible alert.
- Success: server action redirects with HTTP 303 to Stripe portal session URL.

## Controls And Navigation

- `Manage billing` submits `POST ?/manageBilling` on `/dashboard/billing`.
- Server action derives `return_url` as `<request origin>/dashboard/billing`, calls `POST /billing/portal`, and redirects with HTTP 303 to Stripe.
- The page intentionally does not include custom add-payment-method, set-default, remove, invoice-management, payment-update, or cancellation controls.

## Acceptance Criteria

- [ ] Default page body renders `Billing`.
- [ ] Available environments render exactly one actionable billing control: `Manage billing`.
- [ ] Unavailable environments render the deterministic billing-unavailable card and no manage button.
- [ ] Billing action ownership remains server-side (`+page.server.ts`) with no client-side redirect logic.

## Current Implementation Gaps

Browser-unmocked Stripe redirection behavior remains environment-dependent. End-to-end commerce proof remains owned by `scripts/local-signoff-commerce.sh`.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/billing.spec.ts`
- Component tests: `web/src/routes/dashboard/billing/billing.test.ts`; `web/src/routes/dashboard/billing/billing.server.test.ts`
- Server/contract tests: `web/src/routes/dashboard/billing/billing.server.test.ts`; `cd infra && cargo test -p api --test billing_endpoints_test`; `cd infra && cargo test -p api --test stripe_billing_test`
- LocalStripe/Mailpit proof: `scripts/local-signoff-commerce.sh`; `docs/design/stage3_local_commerce_proof_contract.md`; `docs/checklists/LOCAL_SIGNOFF_EVIDENCE_TEMPLATE.md`
