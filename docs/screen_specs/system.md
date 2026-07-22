# System Screen Spec

## Scope

- Primary route: `/system`
- Related routes: `/cluster`; standalone `/snapshots` target in `snapshots.md`
- Audience: standalone engine operators inspecting node, index, and replication health
- Priority: P1 standalone-only ops surface per `docs/design/console_unification_revised_plan.md` Decision R5

## User Goal

Understand whether the standalone engine node is healthy, whether indexes are caught up, and whether replication is enabled without changing engine state.

## Target Behavior

`/system` is a read-only four-tab shell titled `System` with tabs `Health`, `Indexes`, `Replication`, and `Snapshots`; `Health` is selected by default. The `Snapshots` tab remains present as current React evidence, but target standalone navigation must cross-link to `snapshots.md` because Decision R5 makes Snapshots a standalone ops surface.

Health shows `Auto-refreshes every 5 seconds`, optional version/build pill, health cards from `createHealthStats`, memory pressure, and index health. Indexes shows total index count, total documents, total storage, status meaning guidance, pending-task notice when needed, and an Index Details table. Replication shows `Auto-refreshes every 10 seconds`, node ID, replication enabled/disabled state, connected peer count when enabled, and optional SSL/TLS renewal dates.

All data is fetched relative to the serving origin because `engine/dashboard/src/lib/api.ts` uses an empty Axios `baseURL`.

| Owner | Contract |
| --- | --- |
| `engine/dashboard/src/hooks/useSystemStatus.ts::useHealthDetail` | GET `/health`, retry 1, poll every 5 seconds. Fields: `status`, `active_writers`, `max_concurrent_writers`, `facet_cache_entries`, `facet_cache_cap`, `tenants_loaded`, `uptime_secs`, `version`, `heap_allocated_mb`, `system_limit_mb`, `pressure_level`, `allocator`, `build_profile`, optional `capabilities`. |
| `engine/flapjack-http/src/router.rs::build_public_health_routes` and `handlers/health.rs::health` | Own `/health` route and successful `status: "ok"` health payload shape. |
| `engine/dashboard/src/hooks/useIndexes.ts::useIndexes` | GET `/1/indexes`, maps `uid` from `uid || name`, retry 1, 30-second stale time. |
| `engine/dashboard/src/hooks/useSystemStatus.ts::useInternalStatus` | GET `/internal/status`, retry 1, poll every 10 seconds. |
| `engine/flapjack-http/src/router.rs::build_internal_routes` and `handlers/internal.rs::replication_status` | Own `/internal/status` peer-health route and response fields used by Replication. |

Health, Indexes, and Replication issue no mutations.

## Required States

- Loading:
  - Health renders six card skeletons in the card grid.
  - Indexes renders five full-width skeleton rows.
  - Replication renders two skeleton blocks.
- Empty:
  - Health has no separate empty branch; missing fields render default values from `createHealthStats`, memory defaults to `0 MB / 0 MB (0%)`, and pressure defaults to `Normal`.
  - Indexes with an empty list renders zero totals and an empty Index Details table; `IndexHealthSummary` is omitted.
  - Replication with missing `node_id` renders `N/A` and the explanation `Expected for standalone instances. Node IDs are assigned when replication is configured.`
- Error:
  - Health renders `Failed to fetch health status` and the request error message.
  - Indexes renders `Unable to load indexes.`
  - Replication renders `Replication status unavailable` and either the request message or `Could not reach internal status endpoint.`
- Success:
  - Health renders `health-status` with raw status text, `health-active-writers` as `active_writers / max_concurrent_writers`, `health-facet-cache` as `facet_cache_entries / facet_cache_cap`, `health-uptime` using `formatUptime`, `health-tenants-loaded`, and `health-memory` as `heap_allocated_mb MB / system_limit_mb MB (roundedPercent%)`.
  - The memory bar is capped at 100% width. `health-pressure` normalizes case and labels `Critical`, `Elevated`, or `Normal`; color alone is never the only status signal.
  - `health-version` renders `version` alone, or `version`, a middle-dot separator, and `build_profile` when present.
  - `index-health-summary` renders each `index-dot-<uid>` link, counts healthy indexes, totals pending tasks, and explains Healthy versus Processing.
  - Indexes renders `indexes-total-count`, `indexes-total-docs`, `indexes-total-storage`, status guidance, optional pending-task notice, and table columns `Name`, `Status`, `Documents`, `Size`, `Pending`. Healthy means zero pending tasks and renders `Healthy (no pending tasks)`; processing means one or more pending tasks and renders `Processing (N pending task(s))`.
  - Replication renders `node-id-value`, `replication-status` as `Enabled` or `Disabled`, `{peer_count} peer(s) connected` when enabled, and optional `Certificate expires:` / `Next renewal:` rows.

## Mobile Narrow Contract

Baseline viewport: 390px wide. Health and index summary cards stack to one column; tab controls remain operable; card values, long node IDs, and index names wrap instead of overflowing. Index and health-summary tables/lists must stay readable inside their own surfaces without page-level horizontal overflow. All status meanings remain visible as text or icons plus labels, not color alone.

## Controls And Navigation

- The tab list exposes `Health`, `Indexes`, `Replication`, and `Snapshots`; `Health` is default.
- `Health`, `Indexes`, and `Replication` are read-only tabs with no buttons or forms.
- Index links in `index-health-summary` and the Index Details `Name` column navigate to `/index/<encoded uid>` in the React source.
- The `Snapshots` tab entry is retained as current behavior evidence, but the standalone target links operators to the separate `snapshots.md` surface.

## Acceptance Criteria

- [ ] Given `/system`, when the page loads, then the `System` heading and `Health`, `Indexes`, `Replication`, and `Snapshots` tabs render with `Health` active by default.
- [ ] Given a successful `/health` payload, when Health renders, then `health-status`, `health-active-writers`, `health-facet-cache`, `health-uptime`, `health-tenants-loaded`, `health-memory`, `health-pressure`, and optional `health-version` show the source-formatted values.
- [ ] Given index-list data, when Health renders, then `index-health-summary` shows per-index dots, Healthy/Processing labels, healthy count, pending-task count when nonzero, and status meaning copy.
- [ ] Given the Health tab is active, when approximately 5 seconds pass, then the health query refreshes without flickering into `Failed to fetch health status` during a successful refresh.
- [ ] Given the Indexes tab is selected, when index data is available, then `indexes-total-count`, total documents, total storage, and the Index Details columns `Name`, `Status`, `Documents`, `Size`, and `Pending` render from GET `/1/indexes`.
- [ ] Given an index has zero pending tasks, when the Indexes table renders, then its status says `Healthy (no pending tasks)`; given pending tasks are nonzero, it says `Processing (N pending task(s))`.
- [ ] Given `/health` fails, when Health renders, then the tab-local error says `Failed to fetch health status`.
- [ ] Given GET `/1/indexes` fails, when Indexes renders, then the tab-local error says `Unable to load indexes.`
- [ ] Given GET `/internal/status` fails, when Replication renders, then the tab-local error says `Replication status unavailable`.
- [ ] Given Replication succeeds without a configured node ID, when the card renders, then `node-id-value` is `N/A` or `unknown` and the standalone node-ID explanation is visible.
- [ ] Given Replication succeeds with replication enabled, when the card renders, then `replication-status` says `Enabled` and peer-count copy is visible.
- [ ] Given a 390px viewport, when each read-only tab renders, then cards stack, tabs remain usable, tables/long IDs do not widen the page, and status meaning is available without relying on color alone.
- [ ] Given the operator chooses `Snapshots`, when standalone placement is implemented, then the operator can enter the separate Snapshots surface described in `snapshots.md`.

## Visual contract

Name the target visual treatment for this screen without creating a second design system:

- Layout and surface: Svelte implementation should mirror the current React evidence from `System.tsx` and `SystemTabSections.tsx`: page title row with icon, tabbed content, card grids for health/summary values, tab-local error cards, and table cards for index details.
- Typography and color: use existing fjcloud tokens from `web/src/app.css` for muted text, destructive/error text, primary links, borders, cards, and status badges. Preserve text labels for every colored status dot or icon.
- Controls and states: tab triggers are the only Health/Indexes/Replication controls. Error, loading, and empty/success surfaces remain tab-local so one failed dependency does not imply another tab failed.
- Mobile: at 390px, grids collapse to one column and table containers scroll internally if needed.
- Implementation evidence: `engine/dashboard/src/pages/System.tsx`, `engine/dashboard/src/pages/SystemTabSections.tsx`, `engine/dashboard/src/hooks/useSystemStatus.ts`, `engine/dashboard/src/hooks/useIndexes.ts`, `engine/dashboard/src/lib/api.ts`, `engine/flapjack-http/src/router.rs`, `engine/flapjack-http/src/handlers/health.rs`, and `engine/flapjack-http/src/handlers/internal.rs`.

## Current Implementation Gaps

- The managed fjcloud console does not render this standalone-only operator surface today.
- Current React exposes Snapshots inside `/system`; Decision R5 targets Snapshots as a standalone ops surface, so the Svelte port must separate that boundary without inventing a capability flag.
- The React Health hook normalizes `capabilities`, but System does not render those fields; this spec intentionally does not create a capabilities UI contract.
- Index response shape is normalized by the React hook from `results`, `items`, or a bare array; the backend list owner remains the data contract source.

## Automated Coverage

- Browser-unmocked tests: no fjcloud implementation coverage exists yet. External React scenario evidence is `engine/dashboard/tests/specs/system.md` for default Health, Indexes values, 5-second refresh, and Snapshots entry.
- Component tests: no fjcloud component tests exist yet for this standalone-only surface.
- Server/contract tests: source evidence is in flapjack handlers/routes and hooks listed above; fjcloud does not yet own route-level contract tests for these endpoints.
