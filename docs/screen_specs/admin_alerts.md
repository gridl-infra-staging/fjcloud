# Admin Alerts Screen Spec

## Scope

- Primary route: `/admin/alerts`
- Related routes: `/admin/fleet`, `/admin/replicas`
- Audience: operators triaging platform events
- Priority: P0

## User Goal

Review alerts, filter by severity, and inspect metadata without leaving the admin console.

## Target Behavior

The page shows `Alerts`, severity filter, auto-refresh behavior, and either `No alerts found.` or an alert table with timestamp, severity, title, message, and metadata controls.

## Required States

- Loading: route load resolves alerts or empty state.
- Empty: no alerts shows `No alerts found.`
- Error: route/server errors should surface via admin error handling.
- Success: alert rows render severity badges and optional expandable metadata.

## Controls And Navigation

- Severity filter supports all, critical, warning, and info.
- Metadata toggle expands/collapses key-value metadata for each alert.

## Acceptance Criteria

- [ ] Heading renders.
- [ ] Table body or empty state is visible.
- [ ] Severity filter changes visible alert set.
- [ ] Metadata toggle exposes metadata only for rows with metadata.

## Current Implementation Gaps

Browser-unmocked coverage currently verifies page shell/table-or-empty state; metadata expansion is component-owned.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/admin/admin-pages.spec.ts`
- Component tests: `web/src/routes/admin/alerts/admin-alerts.test.ts`
- Server/contract tests: route/component tests.
