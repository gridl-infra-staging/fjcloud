# Admin Customers Screen Spec

## Scope

- Primary route: `/admin/customers`
- Related route: `/admin/customers/[id]`
- Audience: operators managing customers
- Priority: P0

## User Goal

Search and filter customers, inspect truthful list data, and perform quick suspend/impersonate actions.

## Target Behavior

The page shows `Customer Management`, search and status-filter controls, and one of four route states: unavailable dataset, dataset empty, filter-empty results, or success table with truthful customer fields and quick actions.

## Required States

- Loading: route load resolves to either unavailable state or a customer dataset before rendering table-state branch.
- Empty: dataset-empty state shows `No customers found.` when `customers.length === 0`.
- Error: unavailable dataset state shows `Customer data unavailable.` when server returns `customers === null`.
- Success: table renders truthful name/email/status/created/last-activity/index-count/billing-health values, supports search and status filter, supports billing-health sort, and exposes quick actions where applicable.
- Filter-empty: when dataset exists but search/filter excludes all rows, page shows `No customers match the current filters.`

## Mobile Narrow Contract

Baseline viewport: 390px wide (iPhone 14). The page keeps heading, search input, and status filter visible and usable; the responsive table container remains horizontally scrollable where needed so truthful row data and quick actions (when present) remain reachable without adding new breakpoint behavior.

## Controls And Navigation

- Search filters by customer name or email.
- Status filter supports all, active, suspended, and deleted.
- `Billing health` header toggle switches between default ordering and risk-first health ordering.
- Customer name links to detail route.
- Active rows show quick suspend and quick impersonate; deleted rows hide impersonate.

## Acceptance Criteria

- [ ] Heading and correct state branch (unavailable, dataset-empty, filter-empty, or table) render from data.
- [ ] Search plus status filter narrows rows by truthful route data.
- [ ] Table rows render last-activity and billing-health semantics from mapped formatter/test owners.
- [ ] Active customer rows expose quick suspend and quick impersonate actions with detail-route action URLs.
- [ ] Mobile narrow layout keeps controls and row/actions access usable at 390px.

## Current Implementation Gaps

Current browser tests cover active-row actions and truthfulness; broader list pagination is not present/mapped.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/admin/admin-pages.spec.ts`; `web/tests/e2e-ui/full/admin/customer-detail.spec.ts`
- Component tests: `web/src/routes/admin/customers/admin-customers-list.test.ts`; `web/src/routes/admin/customers/admin-customers.test.ts`
- Server/contract tests: admin customer route tests.
