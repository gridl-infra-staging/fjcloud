# Admin Billing Screen Spec

## Scope

- Primary route: `/admin/billing`
- Related route: `/admin/customers/[id]`
- Audience: finance/operators running billing
- Priority: P0

## User Goal

Review revenue KPIs, failed/draft invoices, bulk finalize drafts, and run batch billing for a selected month.

## Target Behavior

The page shows `Billing Review`, action feedback, backend-owned KPI cards, failed invoice rows, draft invoice rows, and the existing batch billing confirmation flow. Revenue and count KPIs come from `GET /admin/billing/summary`; the frontend does not fan out through tenants or recompute status totals from invoice rows.

## Required States

- Loading: route data resolves before the screen renders; no partial client-side loading controls are introduced.
- Empty: zero summary values render as `$0.00`/`0`, failed invoices show `No failed invoices.`, and draft invoices show `No draft invoices awaiting finalization.` with no `Bulk Finalize` button.
- Error: summary load failure uses the safe fallback empty summary; billing action failures show `billing-feedback-error`.
- Success: seeded summary data renders exact KPI dollars/counts and joined failed/draft rows; run billing and bulk finalize success messages show `billing-feedback-message`.

## Mobile Narrow Contract

At 390px width, KPI cards stack in the existing two-column grid, failed/draft tables remain horizontally scrollable, customer detail links remain reachable, and the Run Billing confirmation keeps the month input plus Confirm/Cancel controls visible without text overlap.

## Controls And Navigation

- Failed invoice rows link to `/admin/customers/[id]`.
- `Bulk Finalize` appears only when draft invoices exist and submits all visible draft invoice IDs.
- `Run Billing` opens confirmation with a billing month input.
- `Confirm` runs batch billing for the selected `YYYY-MM`; `Cancel` closes confirmation without submitting.

## Acceptance Criteria

- [ ] Total Revenue renders `status_totals.paid.total_cents` with `formatCents` at `kpi-total-revenue`.
- [ ] MRR renders `mrr_proxy_cents` with `formatCents` at `kpi-mrr`.
- [ ] This Month renders the current UTC `YYYY-MM` bucket's `paid_total_cents` with `formatCents`, defaulting to `$0.00` only when that bucket is absent.
- [ ] Count cards render `total_count`, `status_totals.paid.count`, `status_totals.failed.count`, and `pending_count` from the backend summary.
- [ ] Seeded failed/draft summary rows show customer name, email, formatted amount, and the existing customer link/action controls.
- [ ] The page server load performs exactly one `/admin/billing/summary` request and no `/admin/tenants` or per-tenant invoice requests.
- [ ] Run Billing and Bulk Finalize behavior remains unchanged.

## Visual contract

- Layout and surface: keep the existing admin page frame, compact summary-card grid, bordered failed/draft tables, feedback callouts, and batch billing confirmation block.
- Typography and color: continue using existing slate, green, red, amber, and violet utility tokens already owned by `web/src/routes/admin/billing/+page.svelte`.
- Controls and states: keep existing button treatments, table row hover styles, feedback test IDs, invoice row test IDs, Run Billing controls, and Bulk Finalize controls.
- Mobile: preserve the current responsive grid and `overflow-x-auto` table containers at the 390px baseline.
- Implementation evidence: `web/src/routes/admin/billing/+page.svelte`, `web/src/routes/admin/billing/+page.server.ts`, and `web/src/routes/admin/billing/admin-billing.test.ts`.

## Current Implementation Gaps

- Current: launch-grade browser-unmocked admin batch billing proof remains part of Phase 6 local signoff.
- Target: Stage 2 owns focused component, loader, source-guard, lint, and type-check coverage for the summary endpoint migration.
- Evidence: `docs/screen_specs/coverage.md` maps `/admin/billing` to the existing browser and component owners.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/admin/admin-pages.spec.ts`
- Component tests: `web/src/routes/admin/billing/admin-billing.test.ts`
- Server/source-guard tests: `web/src/routes/admin/billing/admin-billing.test.ts`; `web/src/routes/admin/billing/no_invoice_fanout.test.ts`
- Backend contract tests: `cd infra && cargo test -p api --test billing_endpoints_test`; `cd infra && cargo test -p api --test stripe_billing_test`
