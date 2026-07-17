# Admin Customer Detail Screen Spec

## Scope

- Primary route: `/admin/customers/[id]`
- Related route: `/admin/customers`
- Audience: operators managing one customer
- Priority: P0

## User Goal

Inspect customer identity/status, manage lifecycle actions, impersonate safely, and inspect indexes, deployments, usage, invoices, rate card, and quotas.

## Target Behavior

The page shows customer name/email/status, lifecycle action buttons, form feedback, and tabs for Info, Indexes, Deployments, Usage, Invoices, Rate Card, and Quotas. Tabs lazy-mount on click and render data, unavailable states, or empty states truthfully.

## Required States

- Loading: detail route renders heading/status after server data resolves.
- Empty: fresh customers show no indexes/deployments/invoices and quota empty state.
- Error: action failures show visible feedback without leaving the page unless the action intentionally redirects.
- Success: suspend/reactivate updates status-gated controls; soft delete redirects to list; impersonation shows banner and can return to the same detail page; quota update shows success.

## Controls And Navigation

- `Sync Stripe`, `Suspend`, `Reactivate`, `Impersonate`, and `Soft Delete` are status-gated.
- Tab buttons switch panels.
- Quotas form updates query/write/storage/index limits.
- Impersonation flow enters dashboard and returns through the impersonation banner.

## Acceptance Criteria

- [ ] Detail route shows customer identity and status.
- [ ] All tab buttons render and lazy-mount panel content.
- [ ] Suspend to reactivate lifecycle updates visible controls.
- [ ] Soft delete redirects to customer list and status filters prove deleted state.
- [ ] Impersonation returns to the same customer detail page.
- [ ] Quota update submits and shows visible success feedback.

## Current Implementation Gaps

Deployment termination requires seeded deployment data and is currently covered as an empty-state blocker.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/admin/customer-detail.spec.ts`
- Component tests: `web/src/routes/admin/customers/admin-customer-detail.component.test.ts`; `web/src/routes/admin/customers/[id]/admin-customer-detail.server.test.ts`
- Server/contract tests: admin customer detail server tests.
