# Console Screen Spec

## Scope

- Primary route: `/console`
- Related routes: `/console/indexes`, `/console/api-keys`, `/console/billing`, `/console/settings`, `/console/onboarding`
- Audience: authenticated customers
- Priority: P0

## User Goal

Understand account health, usage, billing state, onboarding status, and next actions from one customer-console landing page.

## Target Behavior

The console renders account-summary widgets and next-action guidance from server-provided usage, plan, and onboarding context. In success state it can show estimated bill details, free-tier metric cards (including MB-based storage quota progress), index quota warnings, onboarding banner state, index summary, and usage charts/region breakdown when usage data exists.

## Required States

- Loading: route resolves server data and renders the console body without a client-only spinner.
- Empty: indexes card shows `No indexes yet` plus `Create your first index` onboarding CTA when `indexes.length === 0`.
- Error: unavailable estimate/usage-derived optional sections hide gracefully (for example estimate widget absent when estimate is null) while rest of console remains truthful.
- Success: estimated-bill widget (month + formatted amount + optional breakdown), free-tier progress cards, index-quota warning when over limit, onboarding banner behavior, indexes card with status totals and manage link, and usage chart/region-breakdown or no-usage fallback copy render according to data.

## Mobile Narrow Contract

Baseline viewport: 390px wide (iPhone 14). Console shell uses the shipped drawer-first layout: sidebar navigation is reachable through the mobile menu trigger, billing and other console links remain navigable through the drawer, and console body content remains readable without requiring new breakpoints or alternate interactions.

## Controls And Navigation

- Month selector updates the console query month.
- `Manage indexes` links to `/console/indexes` when indexes exist.
- `Create your first index` and onboarding prompts link to `/console/onboarding`.
- Billing prompts link to `/console/billing/setup` or `/console/billing`.
- Free-plan index-quota warning links to `/console/billing` for upgrade flow.
- Layout drawer/sidebar links navigate to console sections (indexes, API keys, billing, settings).
- Beta banner link opens `/beta`; feedback link opens the shared support mailbox.

## Acceptance Criteria

- [ ] Console body renders route-owned content including indexes card and billing/usage sections.
- [ ] Estimated-bill widget renders backend month/total exactly when estimate exists and hides when estimate is unavailable.
- [ ] Free-tier progress renders searches/records/storage/indexes values for free-plan users, with storage displayed against MB-based limits (`max_storage_mb` API surface), and shared-plan billing prompt is suppressed in that state.
- [ ] Shared-plan users without payment method see billing setup prompt and not free-tier metric cards.
- [ ] Onboarding banner renders with suggested next step for incomplete onboarding and is absent when onboarding is complete.
- [ ] Usage section renders chart/region breakdown when usage data exists and no-usage fallback text when it does not.
- [ ] Mobile narrow drawer flow keeps Billing navigation reachable at 390px.

## Current Implementation Gaps

Some browser tests still carry accepted conditional-expect lint warnings around optional billing estimate states.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/console.spec.ts`; `web/tests/e2e-ui/smoke/console.spec.ts`; `web/tests/e2e-ui/full/onboarding.spec.ts`
- Component tests: `web/src/routes/console/console.test.ts`; `web/src/routes/console/console_usage.test.ts`; `web/src/routes/console/layout.test.ts`; `web/src/routes/console/console.server.test.ts`
- Server/contract tests: `web/src/routes/console/console.server.test.ts`
