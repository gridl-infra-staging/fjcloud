# Admin Cold Storage Screen Spec

## Scope

- Primary route: `/admin/cold`
- Related route: `/admin/customers/[id]`
- Audience: operators managing cold indexes
- Priority: P1

## User Goal

Review indexes in cold storage and trigger restore when a snapshot is available.

## Target Behavior

The page shows `Cold Storage` and either `No indexes in cold storage.` or a table with index, customer, size, cold since date, days cold, and restore action.

## Required States

- Loading: route load resolves cold-index list or empty state.
- Empty: no cold indexes shows `No indexes in cold storage.`
- Error: restore failures should surface through route/action feedback.
- Success: restore action submits for rows with snapshot IDs.

## Controls And Navigation

- `Restore` appears only when a snapshot ID exists for the cold index.

## Acceptance Criteria

- [ ] Heading renders.
- [ ] Table body or empty state is visible.
- [ ] Restore button is present only for restorable rows.

## Current Implementation Gaps

Browser-unmocked coverage verifies shell/table-or-empty state; full restore flow is deferred to cold-storage local signoff.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/admin/admin-pages.spec.ts`
- Component tests: `web/src/routes/admin/cold/admin-cold.test.ts`
- Server/contract tests: cold-storage local signoff scripts.
