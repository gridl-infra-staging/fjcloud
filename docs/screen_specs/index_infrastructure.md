# Index Infrastructure Screen Spec

## Scope

- Primary route: `/console/indexes/[name]?tab=infrastructure`
- Related routes: `/console/indexes/[name]?tab=metrics`
- Audience: authenticated customers inspecting one search index
- Priority: P0

## User Goal

Understand where an index is hosted, whether its hosts have coarse capacity headroom, what resources the index uses, and whether active cross-region failover is available.

## Target Behavior

The `Infrastructure` tab renders inside the existing index-detail shell as a read-only, informational view. It lists the primary and replica regions, customer-facing statuses, replica lag in operations, coarse utilization buckets, the authenticated index footprint, and qualitative headroom without exposing placement controls or raw host topology. A visible refresh control reloads only this tab and enforces the server-provided minimum refresh interval, which is 60 seconds for the delivered contract. The `Metrics` tab links to this workflow for infrastructure and headroom context.

## Required States

- Loading: the heading, explanatory copy, and disabled refresh control remain visible while no successful payload is available; topology and footprint values are not invented.
- Empty: when there are no replicas, the primary and footprint still render, alongside `No replicas are configured` and an honest statement that automatic cross-region failover is not currently available.
- Error: a tab-local `role="alert"` names the infrastructure failure and provides retry guidance while the shell and other tabs remain usable.
- Success: primary and replica rows show region, formatted status, lag where applicable, and only `Green`, `Yellow`, `Red`, or `Updating...` for utilization. Four footprint cards show documents, storage, search requests, and write operations. Headroom uses a customer label rather than a wire value.
- Refresh cooldown: receipt of the initial non-null payload starts the server-provided cooldown. Refresh remains disabled until the full 60-second interval elapses, is disabled while invalidation is in flight, and restarts only when a replacement non-null payload is received. The tab does not auto-poll.
- Null utilization: a primary or replica with null utilization shows `Updating...`; stale telemetry never becomes a percentage, gauge, or guessed bucket.

## Mobile Narrow Contract

Baseline viewport: 390px wide (iPhone 14). The `Infrastructure` heading, refresh control, topology rows, failover copy, and all four footprint cards remain visible and reachable without horizontal overflow. Cards and region rows stack when needed; content must not depend on hover or color alone.

## Controls And Navigation

- The shell's `Infrastructure` tab is directly after `Metrics` and is selected when `?tab=infrastructure`.
- `Refresh` invalidates only the canonical dependency for this index. Its disabled state communicates cooldown and in-flight behavior; no background refresh runs.
- `View infrastructure and headroom` on the `Metrics` tab uses the shell-built `?tab=infrastructure` destination.
- Browser Back and Forward continue to follow the index-detail shell's existing query-parameter navigation.
- There are no placement, migration, replica-management, hostname, endpoint, or host-detail controls.

## Acceptance Criteria

- [ ] Given a successful payload, the tab shows the exact primary and replica regions, formatted statuses, replica lag in operations, exact four footprint values, and the mapped headroom label.
- [ ] Given mixed replica statuses, the failover line lists only regions whose replica status is exactly `active`.
- [ ] Given no active replicas, including no replicas or syncing/failed/removing-only replicas, the tab says automatic cross-region failover is not currently available.
- [ ] Given null utilization, the affected row shows `Updating...` and no percentage or raw capacity/load value.
- [ ] Given a tab-local fetch error, the alert and refresh guidance render without replacing the index-detail shell.
- [ ] Given a successful payload, refresh is disabled one second before the supplied boundary and enabled at the boundary; a replacement successful payload restarts the cooldown.
- [ ] Given no user interaction, the tab performs no automatic invalidation.
- [ ] Given the 390px viewport, each required heading, control, topology region, failover line, and footprint card stays within the viewport.
- [ ] The DOM contains no endpoint, hostname, IP address, VM or host identifier, timestamp, percentage, gauge, raw capacity/load, other-tenant count, or per-dimension utilization.
- [ ] The default screen body renders page-specific content, not only shared navigation.
- [ ] Seeded/default data renders with exact visible values where applicable.
- [ ] Loading, empty, error, and success states behave as described above.
- [ ] Primary actions use visible controls and produce visible confirmation or errors.
- [ ] Browser-unmocked tests cover the critical path, or gaps are listed below.

## Visual contract

- Layout and surface: reuse the index-detail page frame. The tab has a heading/refresh row followed by separate bordered cards for topology, capacity/headroom explanation, failover posture, and the four-card footprint grid. Rows and cards stack on narrow screens.
- Typography and color: reuse the existing `text-flapjack-ink`, `text-flapjack-ink/70`, `bg-white/90`, and border treatments already owned by index-detail tab components. Bucket badges combine visible text with semantic green/yellow/red treatments.
- Controls and states: refresh uses the existing secondary bordered-button treatment and disabled affordance. Errors use the existing tab-local rose alert treatment. Empty and updating states use neutral explanatory copy.
- Mobile: no fixed-width content, horizontal tables, clipped labels, or off-screen controls at the 390px baseline.
- Implementation evidence: `web/src/routes/console/indexes/[name]/IndexDetailShell.svelte`, `web/src/routes/console/indexes/[name]/index_detail_tabs.ts`, and `web/src/routes/console/indexes/[name]/tabs/MetricsTab.svelte` own the existing shell, tab, surface, and control patterns.

## Workflow Decisions

- Current flow: customers inspect engine counters on `Metrics` and use the neighboring `Infrastructure` tab for customer-safe topology and headroom context.
- Chosen flow: a neighboring read-only `Infrastructure` tab, with a direct link from `Metrics`, separates topology context from raw engine counters while keeping both in one index-detail workflow.
- Alternative considered: merging topology into `Metrics` would overload that screen's raw-counter task and make tab-local error/refresh ownership ambiguous.
- Alternative considered: placement or replica controls here would imply a customer-managed topology contract; those controls remain outside this informational workflow.

## Current Implementation Gaps

- Current: the registered tab, read-only component, refresh cooldown, Metrics link, and deterministic browser acceptance spec are implemented through the existing index-detail and fixture owners.
- Target: no Stage 5 implementation gap remains. Stage 6 executes the authored unmocked browser acceptance spec against the local stack.
- Evidence: the component and shell tests listed below pass, and `web/tests/e2e-ui/full/index-detail-infrastructure.spec.ts` collects successfully.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/index-detail-infrastructure.spec.ts`
- Component tests: `web/src/routes/console/indexes/[name]/tabs/InfrastructureTab.test.ts`; `web/src/routes/console/indexes/[name]/tabs/MetricsTab.test.ts`; `web/src/routes/console/indexes/[name]/detail.test.ts`
- Server/contract tests: `web/src/routes/console/indexes/[name]/detail.server.load.test.ts`; backend endpoint/type coverage delivered before this UI stage
