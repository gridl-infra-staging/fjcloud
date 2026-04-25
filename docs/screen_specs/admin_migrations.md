# Admin Migrations Screen Spec

## Scope

- Primary route: `/admin/migrations`
- Related route: `/dashboard/migrate`
- Audience: operators moving indexes between VMs
- Priority: P1

## User Goal

Trigger migrations and inspect active/recent migration status.

## Target Behavior

The page shows `Migration Management`, optional feedback, a trigger form with index name and destination VM ID, active migrations section, and recent migrations section.

## Required States

- Loading: active/recent migration sections resolve to table or empty state.
- Empty: no active/recent migrations show explicit empty copy.
- Error: trigger failures show visible error feedback.
- Success: trigger success shows visible message and migration appears in active/recent sections as data refreshes.

## Controls And Navigation

- `Index Name` input identifies the source index.
- `Destination VM ID` input identifies the target VM.
- `Start Migration` submits the trigger action.

## Acceptance Criteria

- [ ] Heading renders.
- [ ] Active migrations table or empty state is visible.
- [ ] Recent migrations table or empty state is visible.
- [ ] Trigger form exposes required index and VM inputs.

## Current Implementation Gaps

Browser-unmocked admin page coverage verifies sections; data-dependent migration success paths are covered more deeply by migration recovery/browser tests and server tests.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/admin/admin-pages.spec.ts`; `web/tests/e2e-ui/full/migration-recovery.spec.ts`
- Component tests: `web/src/routes/admin/migrations/admin-migrations.test.ts`; `web/src/routes/dashboard/migrate/migrate.test.ts`
- Server/contract tests: migration route/component tests.
