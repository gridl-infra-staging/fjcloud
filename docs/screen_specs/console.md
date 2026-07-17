# Console Screen Spec

## Scope

- Primary route: `/console`
- Related routes: `/console/indexes`, `/console/api-keys`, `/console/billing`, `/console/billing/setup`, `/console/settings`, `/console/onboarding`
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
- `/console` owns setup discoverability: `Create your first index` and onboarding prompts link to `/console/onboarding`.
- Shared-plan billing setup prompts link to `/console/billing/setup`; broader billing navigation and upgrade flows link to `/console/billing`.
- The shell shared-plan billing CTA is hidden on `/console/billing` and `/console/billing/setup` so billing routes do not self-link.
- Free-plan index-quota warning links to `/console/billing` for upgrade flow.
- Layout drawer/sidebar links navigate to console sections (indexes, API keys, billing, settings).
- Index-detail Overview does not carry a duplicate `Continue setup` banner; setup discovery remains centralized on `/console`.
- Index-detail uses the shared `API Activity Log` viewer for session-captured API calls instead of a search-query-specific log label.
- Beta banner link opens `/beta`; feedback link opens the shared support mailbox.

## Acceptance Criteria

- [ ] Console body renders route-owned content including indexes card and billing/usage sections.
- [ ] Estimated-bill widget renders backend month/total exactly when estimate exists and hides when estimate is unavailable.
- [ ] Free-tier progress renders searches/records/storage/indexes values for free-plan users, with storage displayed against MB-based limits (`max_storage_mb` API surface), and shared-plan billing prompt is suppressed in that state.
- [ ] Shared-plan users without payment method see billing setup prompt to `/console/billing/setup` outside billing routes and not free-tier metric cards.
- [ ] Onboarding banner renders with suggested next step for incomplete onboarding and is absent when onboarding is complete.
- [ ] Usage section renders a readable Daily Usage grouped bar chart for search requests and write operations, plus region breakdown when usage data exists and no-usage fallback text when it does not.
- [ ] Index detail and logs surfaces label the shared session-captured request viewer as `API Activity Log` and make the browser-session scope explicit.
- [ ] Mobile narrow drawer flow keeps Billing navigation reachable at 390px.

## Visual contract

The console shell uses the shipped cream canvas: `bg-flapjack-cream` around a desktop `w-64` `bg-brand-cream text-flapjack-ink` sidebar with `border-flapjack-ink/15`, active nav in `bg-flapjack-mint`, inactive hover in `hover:bg-flapjack-mint/20`, and brand text in the Cabinet font. The top bar is `h-16`, `bg-brand-cream`, and border-separated; the `main` content region is `flex-1 overflow-y-auto p-6`.

Mobile keeps the drawer-first treatment from the shell: a `w-72` fixed drawer in `bg-flapjack-cream text-flapjack-ink shadow-xl`, an ink translucent backdrop, a compact Menu trigger, and the same nav/link palette inside the drawer. Verification, impersonation, beta/support, and billing banners stay full-width shell bands using rose, pink, cream, and ink tokens from the layout owner.

Route-owned content uses cream cards with `rounded-lg`, `border-2 border-flapjack-ink/15`, `shadow`, and `text-flapjack-ink` hierarchy. Free-plan metric cards, indexes card, onboarding callout, usage chart/table, region table, and no-usage fallback all preserve this card/table vocabulary, with primary CTAs using `bg-brand-pink` or rose/plum treatments. The Daily Usage chart is owned by `web/src/routes/console/+page.svelte`: it uses the existing `dailyTotals` aggregation, grouped search-request/write-operation series, a top legend, and explicit axis/bar padding so labels and grouped bars remain readable. Implementation evidence: `web/src/routes/console/+layout.svelte` owns shell/sidebar/drawer/top-bar/banners/main treatment; `web/src/routes/console/+page.svelte` owns dashboard cards, callouts, tables, and usage sections.

## Current Implementation Gaps

Some browser tests still carry accepted conditional-expect lint warnings around optional billing estimate states.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/console.spec.ts`; `web/tests/e2e-ui/smoke/console.spec.ts`; `web/tests/e2e-ui/full/onboarding.spec.ts`
- Component tests: `web/src/routes/console/console.test.ts`; `web/src/routes/console/console_usage.test.ts`; `web/src/routes/console/layout.test.ts`; `web/src/routes/console/console.server.test.ts`
- Server/contract tests: `web/src/routes/console/console.server.test.ts`
