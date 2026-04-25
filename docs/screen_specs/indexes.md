# Indexes Screen Spec

## Scope

- Primary route: `/dashboard/indexes`
- Related routes: `/dashboard/indexes/[name]`, `/dashboard/billing`
- Audience: authenticated customers managing search indexes
- Priority: P0

## User Goal

View existing indexes, create a new index in a chosen region, inspect status and size, and remove indexes.

## Target Behavior

The screen shows `Indexes`, a `Create Index` button, a hidden-by-default creation form, quota or error callouts when needed, and either an empty state or a table of indexes with name, region, status, entries, data size, created date, and delete action.

## Required States

- Loading: route load should resolve table or empty state before user action.
- Empty: no indexes shows `No indexes yet — create your first one.`
- Error: quota exceeded shows an upgrade/delete callout; duplicate/API failures show visible alert text and do not show success.
- Success: created indexes appear in the table or provisioning/success feedback appears while setup completes.

## Controls And Navigation

- `Create Index` toggles the form.
- `Index name` and region picker submit through `Create`.
- `Cancel` hides the form.
- Index name links navigate to `/dashboard/indexes/[name]`.
- `Delete` asks for browser confirmation before deletion.

## Acceptance Criteria

- [ ] Seeded index appears in the table with exact name.
- [ ] Create form toggles open/closed and exposes accessible controls.
- [ ] Creating through UI adds a visible table row or setup feedback.
- [ ] Duplicate index name fails safely and remains on `/dashboard/indexes`.
- [ ] Clicking an index name opens the detail page.

## Current Implementation Gaps

Delete confirmation relies on native `confirm`; browser coverage validates button presence but not every destructive branch.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/indexes.spec.ts`; `web/tests/e2e-ui/smoke/indexes.spec.ts`
- Component tests: `web/src/routes/dashboard/indexes/indexes.test.ts`; `web/src/routes/dashboard/indexes/indexes.server.test.ts`
- Server/contract tests: `web/src/routes/dashboard/indexes/indexes.server.test.ts`
