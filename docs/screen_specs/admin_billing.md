# Admin Billing Screen Spec

## Scope

- Primary route: `/admin/billing`
- Related route: `/admin/customers/[id]`
- Audience: finance/operators running billing
- Priority: P0

## User Goal

Review failed/draft invoices, bulk finalize drafts, and run batch billing for a selected month.

## Target Behavior

The page shows `Billing Review`, feedback messages, summary cards, failed invoice section, draft invoice section, and batch billing confirmation flow.

## Required States

- Loading: failed/draft sections resolve to rows or empty states.
- Empty: no failed invoices and no draft invoices show explicit empty copy.
- Error: billing action failures show `billing-feedback-error`.
- Success: run billing and bulk finalize show `billing-feedback-message`.

## Controls And Navigation

- Failed invoice rows link to customer detail.
- `Bulk Finalize` appears only when draft invoices exist.
- `Run Billing` opens confirmation with billing month input.
- `Confirm` runs batch billing; `Cancel` closes confirmation.

## Acceptance Criteria

- [ ] Failed and draft sections render rows or empty states.
- [ ] Seeded failed/draft rows show customer, email, and dollar amount when present.
- [ ] Run Billing flow shows confirmation and success feedback.
- [ ] Bulk Finalize either succeeds or is hidden when no drafts exist.

## Current Implementation Gaps

Browser-unmocked admin batch billing proof is present but still part of Phase 6 local signoff for launch-grade evidence.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/admin/admin-pages.spec.ts`
- Component tests: `web/src/routes/admin/billing/admin-billing.test.ts`
- Server/contract tests: `cd infra && cargo test -p api --test billing_endpoints_test`; `cd infra && cargo test -p api --test stripe_billing_test`
