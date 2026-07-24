# Admin VM Detail Screen Spec

## Scope

- Primary route: `/admin/fleet/[id]`
- Related route: `/admin/fleet`
- Audience: operators inspecting one VM
- Priority: P1

## User Goal

Inspect VM identity, provider metadata, utilization, indexes assigned to a specific VM, and the VM autorepair lifecycle timeline.

## Target Behavior

The page shows a back link to fleet, VM hostname heading, status badge, `VM Info`, utilization bars for capacity/load dimensions when available, a VM autorepair lifecycle timeline, and an `Indexes on this VM` table or empty state.

The VM autorepair lifecycle timeline contract is owned here for successor lane
`jul23_11am_11_replacement_timeline_admin_ui`. That lane must reuse
`GET /admin/vms/:id/lifecycle-events` from
`infra/api/src/routes/admin/vms.rs`, extend `web/src/lib/admin-client.ts`,
`web/src/routes/admin/fleet/[id]/+page.server.ts`, and
`web/src/routes/admin/fleet/[id]/+page.svelte`, and must not create a parallel
lifecycle endpoint, duplicate event ordering, or invent frontend-only lifecycle
states.

Timeline rows render API events in chronological order by `created_at`/`id`.
Labels come from `VmLifecycleEventType`: `detected_dead`,
`replacement_refused`, `replacement_provisioning`, `replacement_booted`,
`tenants_replaced`, `replacement_completed`, and `replacement_failed`.
`replacement_refused` rows show guardrail chips from `detail.guardrail`, using
the persisted guardrail value verbatim.

A known VM with no lifecycle events returns an empty array and renders a true
empty timeline state. An unknown VM returns 404 through route/server error
handling. Repository/API failure renders lifecycle history unavailable rather than a false-empty timeline.

## Required States

- Loading: route load should render VM identity after server data resolves.
- Empty: no assigned indexes shows `No indexes assigned to this VM.`
- Empty timeline: a known VM with no lifecycle events renders a true empty lifecycle timeline from the API's empty array.
- Error: missing VM should use route/server error handling rather than partial UI.
- Error timeline: lifecycle-event repository or API failures show unavailable lifecycle history, not an empty timeline.
- Success: VM info, utilization, and tenant breakdown render truthful values.

## Controls And Navigation

- `Fleet` back link returns to `/admin/fleet`.
- Tenant breakdown table is read-only.

## Acceptance Criteria

- [ ] VM detail heading uses the VM hostname.
- [ ] VM info section shows hostname, region, provider, provider VM ID, Flapjack URL, created, and updated.
- [ ] Utilization bars show used/total and percentage for numeric capacity dimensions.
- [ ] Tenant table or empty state renders.
- [ ] VM autorepair lifecycle timeline reuses `GET /admin/vms/:id/lifecycle-events`, preserves chronological API order, labels only `VmLifecycleEventType` values, shows guardrail chips from `detail.guardrail`, renders a known-VM empty array as empty, treats unknown VM as 404, and treats repository/API failure as unavailable rather than false-empty.

## Current Implementation Gaps

The VM autorepair lifecycle timeline is successor-owned by
`jul23_11am_11_replacement_timeline_admin_ui`; current shipped UI does not yet
render this timeline.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/admin/fleet.spec.ts`
- Component tests: `web/src/routes/admin/fleet/[id]/admin-vm-detail.test.ts`
- Server/contract tests: route/component tests for VM detail data rendering.
