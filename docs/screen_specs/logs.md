# Logs Screen Spec

## Scope

- Primary route: `/dashboard/logs`
- Related route: `/dashboard`
- Audience: authenticated customers inspecting client-captured API request history
- Priority: P0

## User Goal

Inspect recent API request rows, open request details for a selected row, and clear the log when needed.

## Target Behavior

The page shows `API Logs` with a `Search Log` panel. The panel renders a table with `Method`, `URL`, `Status`, and `Duration` headers, shows newest-first rows from the shared log store, opens request JSON details for a selected row, and clears rows plus selected detail when `Clear` is clicked.

## Required States

- Loading: viewer initializes from current shared store state.
- Empty: no entries shows `No API calls recorded`.
- Error: none rendered by this route-level view; data is store-backed.
- Success: seeded entries render in newest-first order with selectable request detail.

## Controls And Navigation

- Clicking a data row selects that entry and reveals a `Request` JSON panel.
- `Clear` empties all rows and resets the selected request detail.

## Acceptance Criteria

- [ ] Route heading renders `API Logs`.
- [ ] Empty store state renders `No API calls recorded`.
- [ ] Populated store state renders table headers and newest-first rows with method/url/status/duration values.
- [ ] Clicking a row reveals request detail JSON for that entry.
- [ ] `Clear` removes rows and hides request detail.

## Current Implementation Gaps

No route-level gaps are currently known. Browser-unmocked coverage exercises the shared dashboard log path, row selection, request detail rendering, and clear-reset behavior.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/dashboard.spec.ts`
- Component tests: `web/src/routes/dashboard/logs/logs.test.ts`
- Server/contract tests: none (route behavior is client store/UI only).
