# Dashboard Billing Screen Spec

## Scope

- Primary route: `/dashboard/billing`
- Related routes: `/dashboard/billing/invoices`
- Audience: authenticated customers managing billing through Stripe Customer Portal
- Priority: P0

## User Goal

Open Stripe Customer Portal from the billing dashboard to manage billing details, or see a deterministic unavailable state when billing is not configured.

## Target Behavior

The page shows `Billing` and starts from a server-owned availability seam in `web/src/routes/dashboard/billing/+page.server.ts`: `load()` calls `getPaymentMethods()` and returns only `billingUnavailable` in the page-data contract.

UI ownership stays in `web/src/routes/dashboard/billing/+page.svelte`: the available state renders a single native form action (`Manage billing`) posting to `?/manageBilling`; the unavailable state renders `BillingUnavailableCard` and hides the manage form.

## Required States

- Loading: route load resolves to available (`Manage billing`) or unavailable state.
- Error: failed portal-session creation shows a visible alert.
- Success: server action redirects with HTTP 303 to Stripe portal session URL.
- Unavailable: billing-disabled environments render the billing-unavailable card and no manage-billing submit action.

## Controls And Navigation

- `Manage billing` submits `POST ?/manageBilling` on `/dashboard/billing`.
- Server action ownership is `web/src/routes/dashboard/billing/+page.server.ts::actions.manageBilling`: it derives `return_url` as `<request origin>/dashboard/billing`, calls `POST /billing/portal`, and redirects with HTTP 303 to Stripe.
- Action failures render a visible alert in `web/src/routes/dashboard/billing/+page.svelte`.
- The page intentionally does not include add-payment-method, set-default, remove, invoice-management, subscription-status banner, payment-recovery, or cancellation controls.

## Copy Contract

- Heading: `Billing`
- Manage action label: `Manage billing`
- Available-state description copy: `Use Stripe Customer Portal to manage payment methods and subscription billing details.`
- Legacy subscription banners are removed from this route: no `subscriptionCancelledBannerText` or `subscriptionRecoveryBannerText` UI remains.

## Acceptance Criteria

- [ ] Default page body renders `Billing`.
- [ ] Available environments render exactly one actionable billing control: `Manage billing`.
- [ ] Unavailable environments render the deterministic billing-unavailable card and no manage button.
- [ ] Route does not render legacy `subscriptionCancelledBannerText` or `subscriptionRecoveryBannerText` banner UI.
- [ ] Billing action ownership remains server-side in `+page.server.ts::actions.manageBilling` with no client-side redirect logic.

## Current Implementation Gaps

Live Stripe Customer Portal behavior after the 303 handoff remains external to this route contract. This screen owns only local rendering and server action handoff state.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/billing.spec.ts`
- Component tests: `web/src/routes/dashboard/billing/billing.test.ts`
- Server/contract tests: `web/src/routes/dashboard/billing/billing.server.test.ts`

## Open Questions

- None.
