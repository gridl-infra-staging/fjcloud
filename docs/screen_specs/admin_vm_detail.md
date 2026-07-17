# Admin VM Detail Screen Spec

## Scope

- Primary route: `/admin/fleet/[id]`
- Related route: `/admin/fleet`
- Audience: operators inspecting one VM
- Priority: P1

## User Goal

Inspect VM identity, provider metadata, utilization, and indexes assigned to a specific VM.

## Target Behavior

The page shows a back link to fleet, VM hostname heading, status badge, `VM Info`, utilization bars for capacity/load dimensions when available, and an `Indexes on this VM` table or empty state.

## Required States

- Loading: route load should render VM identity after server data resolves.
- Empty: no assigned indexes shows `No indexes assigned to this VM.`
- Error: missing VM should use route/server error handling rather than partial UI.
- Success: VM info, utilization, and tenant breakdown render truthful values.

## Controls And Navigation

- `Fleet` back link returns to `/admin/fleet`.
- Tenant breakdown table is read-only.

## Acceptance Criteria

- [ ] VM detail heading uses the VM hostname.
- [ ] VM info section shows hostname, region, provider, provider VM ID, Flapjack URL, created, and updated.
- [ ] Utilization bars show used/total and percentage for numeric capacity dimensions.
- [ ] Tenant table or empty state renders.

## Current Implementation Gaps

None known for the mapped VM detail drill-down behavior.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/admin/fleet.spec.ts`
- Component tests: `web/src/routes/admin/fleet/[id]/admin-vm-detail.test.ts`
- Server/contract tests: route/component tests for VM detail data rendering.
