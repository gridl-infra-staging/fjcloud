# Admin Fleet Screen Spec

## Scope

- Primary route: `/admin/fleet`
- Related routes: `/admin/fleet/[id]`, `/admin/customers`, `/admin/replicas`, `/admin/alerts`
- Audience: operators monitoring infrastructure
- Priority: P0

## User Goal

Review deployment and VM health, filter fleet rows, and exercise safe local kill controls for HA validation.

## Target Behavior

The page shows `Fleet Overview`, auto-refresh control, optional VM infrastructure table, deployment summary cards, status/provider filters, and fleet rows. Localhost VMs expose a `Kill` action; remote VMs do not.

## Required States

- Loading: fleet rows or `No deployments found.` resolve after route load.
- Empty: no deployments shows `No deployments found.`
- Error: kill failures show `kill-error` banner.
- Success: seeded fleet rows render exact row content and filters narrow visible rows.

## Controls And Navigation

- Auto-refresh checkbox toggles 5s invalidation.
- Status and provider filters narrow rows.
- VM infrastructure hostname links navigate to that VM's detail page.
- Local VM `Kill` sends the server action and refreshes fleet data.
- Admin nav links expose fleet, customers, migrations, replicas, billing, and alerts.

## Acceptance Criteria

- [ ] Page heading renders after admin auth.
- [ ] Seeded fleet rows appear in `fleet-table-body`.
- [ ] Seeded VM inventory rows link to `/admin/fleet/[id]`.
- [ ] Status/provider filters narrow or preserve the visible row set according to seeded data.
- [ ] Admin navigation links are present and target expected routes.
- [ ] Kill action is available only for localhost-backed VMs.

## Current Implementation Gaps

VM kill and HA aftermath are covered in local signoff, not fully in the current browser spec.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/admin/fleet.spec.ts`
- Component tests: `web/src/routes/admin/fleet/admin-fleet.test.ts`
- Server/contract tests: admin fleet route tests through component/server tests and local signoff HA proof.
