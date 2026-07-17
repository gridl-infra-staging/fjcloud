# DPA Screen Spec

## Scope

- Primary route: `/dpa`
- Related routes: `/`, `/terms`, `/privacy`
- Audience: unauthenticated prospects and authenticated customers reviewing data processing terms
- Priority: P0

## User Goal

Read data processing addendum content with clear section headings, effective date, and support/legal navigation.

## Target Behavior

The page renders a single legal article card with a back link to `/`, the `Data Processing Addendum` heading, an effective-date header, canonical DPA sections, and the shared legal footer/support contract.

## Required States

- Loading: N/A. Shipped static public document rendered as a single article card with back-link, effective-date header, and shared legal footer/support contract; no async data fetch.
- Empty: N/A. Shipped static public document rendered as a single article card with back-link, effective-date header, and shared legal footer/support contract; content is compile-time static.
- Error: N/A. Shipped static public document rendered as a single article card with back-link, effective-date header, and shared legal footer/support contract; falls back to route error boundary only on hard route failure.
- Success: DPA heading, effective date, all expected section headings, and shared support footer are visible and consistent.

## Mobile Narrow Contract

Baseline viewport: 390px wide (iPhone 14). The single article card remains readable without horizontal scrolling, the back link remains visible at top, effective-date text stays above section body copy, and shared legal footer/support links remain accessible.

## Controls And Navigation

- `Back to Flapjack Cloud` link navigates to `/`.
- Shared legal footer support link uses the canonical support mailbox contract.

## Acceptance Criteria

- [ ] The page body renders `Data Processing Addendum` and the route-specific effective date.
- [ ] Route-specific section headings match the legal route heading contract.
- [ ] Shared legal footer/support behavior matches the centralized legal contract helpers.

## Current Implementation Gaps

None known for this static public legal route.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/public-pages.spec.ts`
- Component tests: `web/src/routes/dpa/dpa.test.ts`
- Server/contract tests: `web/tests/fixtures/legal_page_contract.ts`; `web/src/routes/legal_page_test_helpers.ts`
