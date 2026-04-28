# Invoices Screen Spec

## Scope

- Primary routes: `/dashboard/billing/invoices`, `/dashboard/billing/invoices/[id]`
- Related routes: `/dashboard/billing`, admin batch billing
- Audience: authenticated customers reviewing invoices
- Priority: P1

## User Goal

List invoices, inspect invoice detail and line items, and access safe payment/PDF links when backend data provides them.

## Target Behavior

The invoice list shows `Invoices` and either `No invoices yet` or a table with period, status, total, and `View`. Detail pages show back navigation, invoice period heading, status, total/subtotal, created/finalized/paid dates, optional Stripe pay link for finalized invoices, optional PDF link, and line items with description, quantity, unit price, amount, and region. Refunded invoices render `Refunded` status badges in both list and detail views while preserving the same date/history layout.

## Required States

- Loading: route load should render list/detail after server data resolves.
- Empty: invoice list with no rows shows `No invoices yet`.
- Error: invalid or unauthorized invoice IDs should be handled by route/server error boundaries, not partial invoice UI.
- Success: seeded invoice with PDF URL shows detail structure and `Download PDF`.
- Refunded history: refunded invoices show `Refunded` in list/detail status surfaces and keep Created/Finalized/Paid history labels visible on detail.

## Controls And Navigation

- List `View` links open `/dashboard/billing/invoices/[id]`.
- Detail `Back to invoices` returns to the list.
- `Pay on Stripe` opens only safe HTTPS hosted invoice URLs for finalized invoices.
- `Download PDF` opens only safe HTTPS PDF URLs, plus loopback `http://localhost`/`127.0.0.1` URLs produced by LocalStripe in local signoff.

## Acceptance Criteria

- [ ] Invoice list renders heading and either table headers or empty state.
- [ ] Seeded detail renders back link, date labels, line items, and table headers.
- [ ] PDF action renders when backend provides a safe PDF URL.
- [ ] Unsafe/non-HTTPS external invoice URLs are not rendered as actionable links.
- [ ] Refunded invoices render `Refunded` status badges on list and detail routes.

## Current Implementation Gaps

Invoice-detail browser coverage may skip when local Stripe linkage is unavailable. Mailpit invoice-ready email evidence is owned by the local commerce proof rather than this browser spec.
Recovery/dunning copy contract ownership remains in `docs/screen_specs/dashboard_billing.md` to avoid duplicate source-of-truth text in this invoice-focused spec.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/billing.spec.ts`
- Browser-unmocked fresh-signup lifecycle lane: `web/tests/e2e-ui/full/signup_to_paid_invoice.spec.ts`
- Component tests: `web/src/routes/dashboard/billing/invoices/invoices.test.ts`
- Server/contract tests: `cd infra && cargo test -p api --test billing_endpoints_test`; `cd infra && cargo test -p api --test stripe_billing_test`
- LocalStripe/Mailpit proof: `scripts/local-signoff-commerce.sh`; `docs/design/stage3_local_commerce_proof_contract.md`; `docs/checklists/LOCAL_SIGNOFF_EVIDENCE_TEMPLATE.md`
