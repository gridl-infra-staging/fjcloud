# Admin Replicas Screen Spec

## Scope

- Primary route: `/admin/replicas`
- Related routes: `/admin/fleet`
- Audience: operators monitoring replication
- Priority: P0

## User Goal

Review replica health, status counts, lag, source/target VM information, and customer/index ownership.

## Target Behavior

The page shows `Replica Management`, summary cards for total/active/syncing/failed replicas, a status filter, and either `No replicas found.` or a replica table.

## Required States

- Loading: route load resolves summary counts and table/empty state.
- Empty: no replicas shows `No replicas found.`
- Error: route/server errors should not render fake replica counts.
- Success: seeded replica rows render status, regions, lag, VM hostnames, customer, and created date.

## Controls And Navigation

- Status filter supports all, active, syncing, provisioning, failed, and removing.

## Acceptance Criteria

- [ ] Heading and summary cards render.
- [ ] Table body or empty state is visible.
- [ ] Status filter narrows rows according to visible data.

## Current Implementation Gaps

No dedicated browser flow verifies HA-created replica visibility after a deterministic action yet.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/admin/admin-pages.spec.ts`; `web/tests/e2e-ui/full/admin/fleet.spec.ts`
- Component tests: `web/src/routes/admin/replicas/admin-replicas.test.ts`
- Server/contract tests: route/component tests plus HA local signoff proof.
