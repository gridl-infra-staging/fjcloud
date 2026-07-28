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

### Lifecycle Data Ownership

This document owns the VM autorepair lifecycle presentation contract. The
backend remains the source of truth for the data contract:

- Reuse the existing `GET /admin/vms/:id/lifecycle-events` endpoint implemented
  by `infra/api/src/routes/admin/vms.rs::get_vm_lifecycle_events`.
- `infra/api/src/models/vm_lifecycle_event.rs::VmLifecycleEventType` owns the
  supported event types.
- `infra/api/src/repos/pg_vm_lifecycle_event_repo.rs::list_for_vm` owns the
  `created_at ASC, id ASC` ordering. The backend order is the canonical
  `created_at`/`id` event matrix order; the UI must render the response in
  received order and must not apply a frontend sort.
- The route owns VM existence semantics: it returns 404 before listing events
  when the VM does not exist, so an unknown VM returns 404.
- `infra/api/src/repos/vm_lifecycle_event_repo.rs::replacement_provisioning_event`
  and `infra/api/src/services/vm_autorepair/lifecycle.rs` own the persisted
  detail keys.

The presentation implementation extends the existing owners
`web/src/lib/admin-client.ts`,
`web/src/routes/admin/fleet/[id]/+page.server.ts`, and
`web/src/routes/admin/fleet/[id]/+page.svelte`. It must not create a parallel
endpoint, a new transport abstraction, a raw JSON dump, a frontend sort,
or frontend-only lifecycle states.

### Lifecycle Event Labels

Map every supported backend `event_type` to exactly this UI label:

| Backend event type | UI label |
| --- | --- |
| `detected_dead` | `Detected dead` |
| `replacement_refused` | `Replacement refused` |
| `replacement_provisioning` | `Replacement provisioning` |
| `replacement_booted` | `Replacement booted` |
| `tenants_replaced` | `Tenants replaced` |
| `replacement_failed` | `Replacement failed` |
| `replacement_completed` | `Replacement completed` |

The unsupported names `ready` and `decommissioned` must not be used.

### Lifecycle States

- A successful populated response renders one row per event in received order.
- A successful `[]` response renders
  `No lifecycle events recorded for this VM.`
- A known VM with no lifecycle events returns an empty array from the lifecycle
  endpoint and renders the empty timeline state.
- A lifecycle fetch failure returns `null` from the server load and renders
  `VM lifecycle history unavailable.` The failure must not become an empty
  array; it remains unavailable rather than a false-empty timeline.
- A missing VM continues through the existing route/server 404 path rather
  than rendering a partial detail page.

### Lifecycle Presentation

Render exactly one section headed `VM autorepair lifecycle`. Events use
ordered-list semantics, with one list row per event. Each row renders
`<time datetime={event.created_at}>` and formats its visible timestamp with
`formatDateTime` from `web/src/lib/format.ts`.

The presentation contract includes these stable selectors:

- Section: `vm-lifecycle-section`
- Ordered list: `vm-lifecycle-list`
- Event row: `vm-lifecycle-row-{event.id}`
- Empty state: `vm-lifecycle-empty`
- Unavailable state: `vm-lifecycle-unavailable`
- Replacement link: `vm-lifecycle-replacement-link-{event.id}`
- Detail-page refresh toggle: `vm-detail-auto-refresh-toggle`

### Lifecycle Detail Fields

For `replacement_refused`, render `detail.guardrail` verbatim with the label
`Guardrail`. For other generic event detail, render only scalar values from
this allowlist with the exact labels below:

| Persisted detail key | UI label |
| --- | --- |
| `dead_hostname` | `Dead hostname` |
| `provider` | `Provider` |
| `provider_vm_id` | `Provider VM ID` |
| `region` | `Region` |
| `planned_replacement_hostname` | `Planned replacement hostname` |
| `failure_phase` | `Failure phase` |
| `failure_reason` | `Failure reason` |

Omit unknown keys and absent, object, array, or `null` values. The
`replacement_vm_id` and `replacement_hostname` keys belong to the replacement
navigation presentation below and must not also render as generic detail.

### Replacement Navigation

When `detail.replacement_vm_id` is a non-empty string, render a link to
`/admin/fleet/{replacement_vm_id}`. Its text uses the non-empty
`detail.replacement_hostname` when available and otherwise falls back to the
replacement VM ID. When a non-empty replacement hostname exists without a
usable replacement VM ID, render the hostname as plain text. Do not render a
replacement link for an absent or empty ID.

### Detail Auto-refresh

The detail page has one default-on `Auto-refresh (5s)` control. Its single
interval runs every 5,000 ms and, while enabled, invalidates only
`admin:fleet:detail:${data.vm.id}`. The interval must be cleared on teardown.

## Required States

- Loading: route load should render VM identity after server data resolves.
- Empty: no assigned indexes shows `No indexes assigned to this VM.`
- Empty timeline: a known VM with a successful empty lifecycle response renders `No lifecycle events recorded for this VM.`
- Error: missing VM should use route/server error handling rather than partial UI.
- Error timeline: lifecycle-event repository or API failures render `VM lifecycle history unavailable.` from `null`, not an empty timeline.
- Success: VM info, utilization, and tenant breakdown render truthful values.
- Success timeline: populated lifecycle events render in received order using the exact labels and allowlisted detail contract above.

## Controls And Navigation

- `Fleet` back link returns to `/admin/fleet`.
- Tenant breakdown table is read-only.
- `Auto-refresh (5s)` is default-on and controls only the detail-page lifecycle refresh interval.

## Acceptance Criteria

- [ ] VM detail heading uses the VM hostname.
- [ ] VM info section shows hostname, region, provider, provider VM ID, Flapjack URL, created, and updated.
- [ ] Utilization bars show used/total and percentage for numeric capacity dimensions.
- [ ] Tenant table or empty state renders.
- [ ] VM autorepair lifecycle timeline reuses `GET /admin/vms/:id/lifecycle-events`, preserves received backend order, maps only supported `VmLifecycleEventType` values to the exact labels above, and follows the detail allowlist and replacement-link rules.
- [ ] Populated, empty, unavailable, and missing-VM lifecycle states remain distinct and use the exact copy and 404 behavior above.
- [ ] Semantic markup, timestamps, stable selectors, and the single teardown-safe detail auto-refresh interval match this contract.

## Current Implementation Gaps

No known gap remains in the VM autorepair lifecycle timeline seam. The shipped
detail page now renders the timeline through the existing admin client, VM
detail server load, and VM detail page owners while preserving the backend
ordering, distinct empty versus unavailable states, and the single five-second
detail refresh lifecycle. JSDOM axe coverage now proves populated and empty
lifecycle states in `web/src/routes/admin/fleet/[id]/admin_vm_detail_a11y.test.ts`.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/admin/fleet.spec.ts`
- Component tests: `web/src/routes/admin/fleet/[id]/admin-vm-detail.test.ts`
- Server/contract tests: route/component tests for VM detail data rendering.
