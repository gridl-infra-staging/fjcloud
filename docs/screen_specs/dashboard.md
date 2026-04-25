# Dashboard Screen Spec

## Scope

- Primary route: `/dashboard`
- Related routes: `/dashboard/indexes`, `/dashboard/api-keys`, `/dashboard/billing`, `/dashboard/settings`, `/dashboard/onboarding`
- Audience: authenticated customers
- Priority: P0

## User Goal

Understand account health, usage, billing state, onboarding status, and next actions from one customer-console landing page.

## Target Behavior

The dashboard shows the page heading, month selector, estimated bill when available, index summary, plan badge context from the layout, a public-beta banner with scope link, a feedback mailto entry point, onboarding or billing prompts when required, and usage sections when usage exists.

## Required States

- Loading: route load should render a coherent page after server data resolves; no client-only spinner is required.
- Empty: no-index accounts show `No indexes yet` with a create-first-index path.
- Error: unavailable billing estimate hides the estimate widget rather than showing stale or fake totals.
- Success: seeded customer data renders exact visible values for billing estimates, index counts/statuses, and plan-aware sections.

## Controls And Navigation

- Month selector updates the dashboard query month.
- `Manage indexes` links to `/dashboard/indexes` when indexes exist.
- `Create your first index` and onboarding prompts link to `/dashboard/onboarding`.
- Billing prompts link to `/dashboard/billing/setup` or `/dashboard/billing`.
- Sidebar links reach indexes, API keys, billing, and settings pages.
- Beta banner link opens `/beta`; feedback link opens the shared support mailbox.

## Acceptance Criteria

- [ ] Dashboard body renders the page heading and `indexes-card`.
- [ ] Estimated bill shows the backend month and total exactly when an estimate exists.
- [ ] Estimate breakdown opens only when backend line items exist.
- [ ] Shared-plan users without payment method see billing prompts and no free-tier progress.
- [ ] Free-plan users see free-tier usage metrics and no shared-plan billing prompts.
- [ ] Customer dashboard exposes beta context and a feedback entry point.

## Current Implementation Gaps

Some browser tests still carry accepted conditional-expect lint warnings around optional billing estimate states.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/dashboard.spec.ts`; `web/tests/e2e-ui/smoke/dashboard.spec.ts`; `web/tests/e2e-ui/full/onboarding.spec.ts`
- Component tests: `web/src/routes/dashboard/dashboard.test.ts`; `web/src/routes/dashboard/dashboard.server.test.ts`
- Server/contract tests: `web/src/routes/dashboard/dashboard.server.test.ts`
