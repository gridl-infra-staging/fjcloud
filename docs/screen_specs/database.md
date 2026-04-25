# Database Screen Spec

## Scope

- Primary route: `/dashboard/database`
- Related route: `/dashboard`
- Audience: authenticated customers managing their AllYourBase database instance
- Priority: P0

## User Goal

See current database-instance status, create an instance when none exists, and delete an existing instance with explicit confirmation.

## Target Behavior

The page shows `Database` and then either a no-instance state or an instance-details card. No-instance handling splits into duplicate-instance conflict guidance, request-failed guidance, create-form availability, and a default persisted-empty message. Persisted-instance handling shows status and core AYB fields plus a delete action.

## Required States

- Loading: route resolves directly to no-instance or persisted-instance content before user action.
- Empty: no persisted instance shows either create-form guidance or default no-instance copy.
- Error: load failures and create/delete action failures render a visible alert.
- Success: create/delete submissions apply pending button states and refresh the visible database state.

## Controls And Navigation

- `Name`, `Slug`, and `Plan` fields collect create payload values.
- `Create Database` submits `?/create` and shows `Creating...` while pending.
- `Delete Database` requires browser confirmation before submitting `?/delete`.
- Delete action shows `Deleting...` while pending.

## Acceptance Criteria

- [ ] No-instance + provisioning-available state shows create-form controls.
- [ ] Duplicate-instance load errors show duplicate-resolution copy and suppress create/delete actions.
- [ ] Request-failed load errors show persisted-state load-failure guidance.
- [ ] Persisted instance state shows status badge plus URL, slug, cluster, plan, created, and updated fields.
- [ ] Delete action requires confirmation and transitions to disabled pending state while submitting.

## Current Implementation Gaps

Browser-unmocked coverage now exercises the deterministic persisted-instance branch via the authenticated dashboard suite. The no-instance and load-error branches remain covered by component/server tests.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/dashboard.spec.ts`
- Component tests: `web/src/routes/dashboard/database/database.test.ts`; `web/src/routes/dashboard/database/database.server.test.ts`
- Server/contract tests: `web/src/routes/dashboard/database/database.server.test.ts`
