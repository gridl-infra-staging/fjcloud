# Admin Fleet Screen Spec

## Scope

- Primary route: `/admin/fleet`
- Related routes: `/admin/fleet/[id]`, `/admin/customers`, `/admin/replicas`, `/admin/alerts`
- Audience: operators monitoring infrastructure
- Priority: P0

## User Goal

Review VM capacity and regional health first, then inspect deployment health, filter deployment rows, and exercise safe local kill controls for HA validation.

## Workflow Record

- Current flow before this capacity change: enter from the admin `Fleet` navigation, review the basic VM Infrastructure table and optional local kill actions, then review deployment summary cards, filters, and the deployment table.
- Proposed VM-first flow: enter the same route, review region rollups and the expanded VM Capacity table first, drill into a hostname or use the existing local kill action when needed, then continue to the unchanged deployment summary, filters, and table.
- Chosen table approach: extend the existing VM Infrastructure table because it already owns VM identity, lifecycle, detail navigation, and kill actions. A second capacity table would split one operator task across duplicate VM rows and create competing owners for the same inventory.
- Chosen rollup arithmetic: use capacity-weighted disk utilization rather than the mean of per-VM percentages. Summing used and total bytes preserves the contribution of differently sized disks; averaging VM percentages would give small and large disks equal weight and misstate regional load.

## Target Behavior

The page shows `Fleet Overview`, auto-refresh control, a VM-first capacity table when inventory exists, region rollup cards, deployment summary cards, status/provider filters, and deployment rows. The capacity table extends the existing VM infrastructure table rather than adding a second VM table. VM rows show hostname detail links, region, provider, lifecycle status, canonical health, utilization columns for dimensions numeric in both `capacity` and `current_load` labelled as proxy values, real host telemetry columns, replica placement, tenant and index counts, Flapjack URL, updated time, and actions. Localhost VMs expose a `Kill` action; remote VMs do not.

Region rollups group VMs by region in deterministic region order. Each card shows the exact VM count and **Aggregate disk utilization**, calculated as capacity-weighted disk use: `round(sum(current_load.disk_bytes) / sum(capacity.disk_bytes) * 100)`. Regions with no qualifying positive disk capacity show `Unavailable` instead of a fabricated percentage.

The capacity table includes a **Replica placement** column derived from the canonical `/admin/replicas` data as a frontend join, not a denormalized VM field. Each VM cell shows `Primary: N` (replicas this VM is the primary for) and `Replica: N` (replica copies this VM hosts), plus sorted unique region labels: `Replica regions: <regions>` for primary roles and `Hosts replica: <regions>` for hosted replicas. A VM with neither role shows `No replicas`. When the `/admin/replicas` fetch fails, the cell shows `Replica placement unavailable` so an API failure is never read as an empty placement fact.

Real host telemetry comes from the FJ-5 `/admin/vms/{id}/host-metrics` contract already composed into the page loader as `hostMetricsByVmId`. The capacity table shows four host columns beside the proxy capacity columns: **Disk (host)**, **CPU (host)**, **RAM (host)**, and **Network RX/TX totals (host)**. Proxy capacity headers must remain visually distinct with labels such as `<dimension> (proxy)`. A missing or null VM host-metrics sample renders `No host data` in every host cell for that VM. A present sample with null disk fields renders `—` only in **Disk (host)**. A present sample with a non-positive disk or RAM total renders `—` only in the affected **Disk (host)** or **RAM (host)** cell. CPU and network cells continue to render from the present sample and must not fabricate `0%`, `NaN%`, or `Infinity%` for invalid disk/RAM inputs.

## Required States

- Loading: fleet rows, VM capacity rows, region rollups, or `No deployments found.` resolve after route load.
- Empty: no deployments shows `No deployments found.`
- Error: kill failures show `kill-error`; VM inventory failures show `vm-capacity-unavailable` while preserving independently loaded deployment data; deployment fetch failures show `fleet-unavailable` instead of a false empty fleet state while preserving independently loaded VM capacity data.
- Success: seeded VM capacity rows, host telemetry cells, and region rollups render exact visible values; seeded deployment rows render exact row content and filters narrow visible rows.

## Mobile Narrow Contract

At 390px wide, the page keeps the heading and auto-refresh control visible, stacks summary and rollup cards, and preserves table access through horizontal overflow instead of compressing or hiding columns. Hostname links, kill controls, filters, and deployment navigation remain reachable without overlapping text.

## Controls And Navigation

- Auto-refresh checkbox toggles 5s invalidation.
- Status and provider filters narrow rows.
- VM capacity hostname links navigate to that VM's detail page.
- The VM detail page owns the VM autorepair lifecycle timeline contract in
  `docs/screen_specs/admin_vm_detail.md`; the fleet table should only provide
  the existing per-VM entry point.
- Local VM `Kill` sends the server action and refreshes fleet data.
- Admin nav links expose fleet, customers, migrations, replicas, billing, and alerts.

## Acceptance Criteria

- [ ] Page heading renders after admin auth.
- [ ] Seeded fleet rows appear in `fleet-table-body`.
- [ ] Seeded VM inventory rows appear in `capacity-table-body` with exact hostname, region, provider, lifecycle status, health, tenant count, index count, proxy utilization values, host telemetry values, Flapjack URL, updated time, and action state.
- [ ] Seeded VM inventory rows link to `/admin/fleet/[id]`.
- [ ] Only dimensions numeric in both `capacity` and `current_load` appear as utilization columns.
- [ ] Missing per-row capacity/load pairs render `Unavailable`.
- [ ] Proxy capacity columns are labelled distinctly from real host telemetry columns, for example `disk_bytes (proxy)` beside `Disk (host)`.
- [ ] A present host-metrics sample with disk `25/100`, RAM `3/4`, CPU `12.5`, RX `1024`, and TX `2048` renders exact host cells `25%`, `75%`, `12.5%`, and `RX total 1.0 KB / TX total 2.0 KB`.
- [ ] Missing or null host-metrics samples render `No host data` in **Disk (host)**, **CPU (host)**, **RAM (host)**, and **Network RX/TX totals (host)**.
- [ ] Present host-metrics samples with nullable disk fields or non-positive disk/RAM totals render `—` only in the affected disk/RAM cell while unaffected CPU and network values remain exact.
- [ ] Region rollups show exact VM counts and **Aggregate disk utilization** using weighted disk utilization, or `Unavailable` when no positive disk capacity qualifies.
- [ ] The **Replica placement** column shows `Primary: N`/`Replica: N` counts with sorted unique `Replica regions`/`Hosts replica` labels for VMs with a role, `No replicas` for VMs with neither role, and `Replica placement unavailable` when the replicas fetch fails.
- [ ] A failed VM inventory request shows `vm-capacity-unavailable` instead of a false empty capacity state, without hiding independently loaded deployments or replica data.
- [ ] A failed fleet request shows `fleet-unavailable` instead of `No deployments found.`, without hiding independently loaded VM capacity data.
- [ ] Status/provider filters narrow or preserve the visible row set according to seeded data.
- [ ] Admin navigation links are present and target expected routes.
- [ ] Kill action is available only for localhost-backed VMs.

## Visual contract

- Layout and surface: dark admin page frame with full-width sections, compact summary cards, horizontal-overflow tables, and rollup cards at the section level.
- Typography and color: existing admin text scale and slate/violet status treatment from `web/src/routes/admin/fleet/+page.svelte` and shared badge tokens from `web/src/lib/format`.
- Controls and states: existing checkbox, select, link, status badge, kill button, empty, and error banner styling remains unchanged.
- Host telemetry: compact text-only cells in the capacity table near the proxy utilization and replica placement columns, using the existing slate text scale and shared byte/percent formatting owners.
- Replica placement: compact text-only cell in the capacity table between the host telemetry columns and Tenants, using the existing slate text scale; stacks `Primary`/`Replica` counts and region labels without new badge tokens.
- Mobile: rollup and summary cards stack; capacity and deployment tables scroll horizontally at the 390px baseline.
- Implementation evidence: `web/src/routes/admin/fleet/+page.svelte`, `web/src/lib/vm-capacity.ts`, and `web/src/lib/format`.

## Current Implementation Gaps

No shipped-vs-target delta is verified for the current scope. Sorting, pagination, host telemetry history, and additional backend fields are intentionally outside this screen contract.

## Unresolved Risks

- The admin fleet browser spec covers the kill control's presence, while the full kill-and-HA aftermath remains owned by local signoff rather than one combined browser scenario.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/admin/fleet.spec.ts` (includes the seeded VM host telemetry evidence path, seeded VM `No replicas` empty-placement state, and the 390px overflow/control contract)
- Component tests: `web/src/routes/admin/fleet/admin-fleet.test.ts` (includes exact host telemetry formatting/absence states and exact replica placement join correctness for primary, replica-host, no-role, and unavailable states)
- Server/contract tests: admin fleet route tests through component/server tests and local signoff HA proof.
- Pure helper tests: `web/src/lib/vm-capacity.test.ts`
