# Admin Customer Detail Screen Spec

## Scope

- Primary route: `/admin/customers/[id]`
- Related route: `/admin/customers`
- Audience: operators managing one customer
- Priority: P0

## User Goal

Inspect customer identity/status, manage lifecycle actions, impersonate safely, and inspect indexes, deployments, usage, invoices, rate card, and quotas.

## Target Behavior

The page shows customer name/email/status, the exact plan tier in the Info tab, lifecycle action buttons, form feedback, and tabs for Info, Indexes, Deployments, Usage, Invoices, Rate Card, Quotas, and Audit. Tabs lazy-mount on click and render data, unavailable states, or empty states truthfully; the Indexes tab renders the customer's DB-backed catalog rows from `/admin/tenants/[id]/indexes` with name, region, status, tier, and `entries: 0` for every resolved Stage 1 catalog row, the Invoices tab lets operators load stored Stripe drill-in fields for a selected invoice, and the Audit tab renders action, actor ID, timestamp, and non-empty metadata.

## Required States

- Loading: detail route renders heading/status after server data resolves.
- Empty: fresh customers show no indexes/deployments/invoices/audit events and quota empty state; the Indexes tab says `No indexes found for this customer.` when the catalog endpoint succeeds with an empty array, and Audit omits metadata blocks for empty metadata objects.
- Error: action failures show visible feedback without leaving the page unless the action intentionally redirects.
- Success: suspend/reactivate updates status-gated controls; soft delete redirects to list; impersonation shows banner and can return to the same detail page; quota update shows success; invoice view keeps the Invoices tab active and shows stored Stripe invoice ID plus safe hosted invoice/PDF links for the selected row.
- Invoice mismatch: if the selected invoice detail belongs to another customer, the action returns visible error feedback and no selected invoice detail is exposed.
- Unavailable: the Indexes tab shows `Index data unavailable.` only when the optional catalog request fails; the Audit tab shows `Audit timeline unavailable.` only when the already-loaded audit rows are unavailable.

## Controls And Navigation

- `Sync Stripe`, `Suspend`, `Reactivate`, `Impersonate`, and `Soft Delete` are status-gated.
- Tab buttons switch panels.
- Invoice rows include a visible `View` submit control that posts the exact selected invoice ID to `?/viewInvoice` without leaving the page.
- Selected invoice hosted/PDF URLs open in a new tab with `target="_blank"` and `rel="noopener"` only when the stored URL passes the shared billing URL policy.
- Safe hosted invoice links allow HTTPS only. Safe PDF links allow HTTPS plus loopback HTTP for local invoice fixtures; remote HTTP and non-HTTP schemes are rejected. Rejected or missing hosted/PDF URLs render `Not available` with no anchor.
- Quotas form updates query/write/storage/index limits.
- Impersonation flow enters dashboard and returns through the impersonation banner.

## Acceptance Criteria

- [ ] Detail route shows customer identity, status, and the exact plan tier from loaded customer data.
- [ ] All tab buttons render and lazy-mount panel content.
- [ ] The Indexes tab renders exact catalog row values from `/admin/tenants/[id]/indexes`, including tier and `entries: 0`, preserves an empty-array state, and uses `Index data unavailable.` only for optional fetch failure.
- [ ] The Invoices tab renders a View action for each invoice, loads detail through `/admin/invoices/[id]`, rejects invoice detail for another customer, keeps the Invoices tab active after enhanced action data, and renders exact Stripe invoice ID, hosted invoice URL, and PDF URL values without live Stripe calls.
- [ ] Missing or unsafe stored invoice hosted/PDF URLs render `Not available` and do not render external anchors.
- [ ] The Audit tab renders each row's exact actor ID and compact metadata values while suppressing empty metadata objects.
- [ ] Suspend to reactivate lifecycle updates visible controls.
- [ ] Soft delete redirects to customer list and status filters prove deleted state.
- [ ] Impersonation returns to the same customer detail page.
- [ ] Quota update submits and shows visible success feedback.

## Current Implementation Gaps

Deployment termination requires seeded deployment data and is currently covered as an empty-state blocker.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/admin/customer-detail.spec.ts`
- Component tests: `web/src/routes/admin/customers/admin-customer-detail.component.test.ts`; `web/src/routes/admin/customers/[id]/admin-customer-detail.server.test.ts`; `web/src/routes/admin/customers/admin-customers.test.ts`; `web/src/routes/admin/customers/[id]/audit-timeline.component.test.ts`; `web/src/lib/audit.test.ts`
- Server/contract tests: admin customer detail server tests.
