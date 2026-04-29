# Admin Customers Screen Spec

## Scope

- Primary route: `/admin/customers`
- Related route: `/admin/customers/[id]`
- Audience: operators managing customers
- Priority: P0

## User Goal

Search and filter customers, inspect truthful list data, and perform quick suspend/impersonate actions.

## Target Behavior

The page shows `Customer Management`, customer search, status filter, and either unavailable/empty/filter-empty state or a customer table with name, email, status, created, index count, last invoice, and quick actions.

## Required States

- Loading: route load resolves customer list or unavailable state.
- Empty: no customers shows `No customers found.`
- Error: unavailable customer data shows `Customer data unavailable.`
- Success: seeded customers render exactly once when searched.

## Controls And Navigation

- Search filters by customer name or email.
- Status filter supports all, active, suspended, and deleted.
- Customer name links to detail.
- Active rows show quick suspend and quick impersonate; deleted rows hide impersonate.

## Acceptance Criteria

- [ ] Heading and table/empty state render.
- [ ] Search plus active-status filter narrows to seeded customer.
- [ ] Active customer rows show quick suspend and quick impersonate.
- [ ] Unavailable index count renders `—`; zero-invoice sentinel renders `none`.

## Current Implementation Gaps

Current browser tests cover active-row actions and truthfulness; broader list pagination is not present/mapped.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/admin/admin-pages.spec.ts`; `web/tests/e2e-ui/full/admin/customer-detail.spec.ts`
- Component tests: `web/src/routes/admin/customers/admin-customers.test.ts`; `web/src/routes/admin/customers/admin-customers-list.test.ts` <!-- TODO(loader-test): a separate component test for the +page.server.ts loader (admin-customers-loader.test.ts) is planned but not yet written; uncomment from the spec list when the file lands so the screen-specs coverage gate stays accurate. -->

- Server/contract tests: admin customer route tests.
