# Cluster Screen Spec

## Scope

- Primary route: `/cluster`
- Related routes: `/system`
- Audience: standalone engine operators validating cluster/replication state
- Priority: P1 standalone-only ops surface per `docs/design/console_unification_revised_plan.md` Decision R5

## User Goal

Confirm whether the engine is intentionally standalone or running HA replication, and inspect peer health without changing cluster state.

## Target Behavior

`/cluster` is a read-only page titled `Cluster`. It fetches GET `/internal/cluster/status` relative to the serving origin, retries once, and polls every 5 seconds through `engine/dashboard/src/hooks/useClusterStatus.ts::useClusterStatus`. The route is registered in `engine/dashboard/src/App.tsx`; the backend route is owned by `engine/flapjack-http/src/router.rs::build_internal_routes` and `engine/flapjack-http/src/handlers/internal.rs::cluster_status`.

The discriminated response is:

| Branch | Shape |
| --- | --- |
| Standalone | `{ "node_id": string, "replication_enabled": false, "peers": [] }` |
| HA | `{ "node_id": string, "replication_enabled": true, "peers_total": number, "peers_healthy": number, "peers": [{ "peer_id": string, "addr": string, "status": "healthy" | "stale" | "unhealthy" | "circuit_open" | "never_contacted", "last_success_secs_ago": number | null }] }` |

`peers_total` and `peers_healthy` are backend-owned counts and must not be recomputed client-side. Cluster has no mutations.

## Required States

- Loading: render `cluster-loading-state` with two skeleton blocks inside `cluster-page-shell`.
- Empty: when the query returns no payload and no error, render `cluster-empty-state` with `Cluster status response is empty.`
- Error: request failures and contract parse failures both render `cluster-error-state`, `Failed to fetch cluster status`, and the surfaced error message. `parseClusterStatusResponse` and `parsePeer` reject malformed object shape, missing or invalid `node_id`, missing/invalid `replication_enabled`, missing/non-array `peers`, HA payloads with missing/non-integer/negative `peers_total` or `peers_healthy`, invalid peer fields, and unknown status values by throwing `ClusterStatusContractError`.
- Success:
  - Standalone renders `cluster-standalone-state`, heading `Standalone mode`, `cluster-node-id-value`, `cluster-replication-value` as `Standalone mode`, and `Single-node operation is healthy and expected. Add peers only if you want multi-node HA replication.`
  - HA renders `cluster-ha-state`, summary cards for `Node ID`, `Peers Total`, and `Peers Healthy`, `cluster-node-id-value`, `cluster-peers-total-value`, `cluster-peers-healthy-value`, and a Peer Health table when peers exist.
  - HA zero-peer state renders the summary cards and `cluster-ha-empty-state` with `HA is enabled but no peer health rows are available yet.`

Peer Health columns are `Peer ID`, `Address`, `Status`, and `Last Success`. Each row uses `cluster-peer-row-<peer_id>`, `cluster-peer-status-<peer_id>`, and `cluster-peer-last-success-<peer_id>`.

Status mapping is exhaustive:

| Wire value | Visible label |
| --- | --- |
| `healthy` | `Healthy` |
| `stale` | `Stale` |
| `unhealthy` | `Unhealthy` |
| `circuit_open` | `Circuit Open` |
| `never_contacted` | `Never Contacted` |

Last-success formatting is `Never` for null, `<1s ago` for values under 1, `Ns ago` for values under 60, `Nm ago` for values under 3600, and `Nh ago` otherwise.

## Mobile Narrow Contract

Baseline viewport: 390px wide. Summary cards stack to one column. Long node IDs, peer IDs, and addresses remain readable with wrapping or table-cell constraints. The peer table scrolls within its own card surface when necessary and must not widen the page.

## Controls And Navigation

- `/cluster` has no forms, buttons, links, or mutations in the current evidence.
- The only automatic control is the 5-second polling query. Refresh recovery uses the next successful query payload and must replace previous error or stale peer status text.

## Acceptance Criteria

- [ ] Given `/cluster`, when the page loads, then `cluster-page-shell` renders the `Cluster` heading.
- [ ] Given a standalone payload with `replication_enabled: false` and `peers: []`, when the query succeeds, then `cluster-standalone-state`, `cluster-node-id-value`, `Standalone mode`, and the single-node reassurance render.
- [ ] Given an HA payload, when the query succeeds, then `cluster-ha-state` renders `Node ID`, `Peers Total`, `Peers Healthy`, `cluster-peers-total-value`, and `cluster-peers-healthy-value` from the backend payload exactly.
- [ ] Given HA peer rows, when the table renders, then it shows columns `Peer ID`, `Address`, `Status`, and `Last Success` with each `cluster-peer-row-<peer_id>`.
- [ ] Given peer statuses `healthy`, `stale`, `unhealthy`, `circuit_open`, and `never_contacted`, when rows render, then badges say `Healthy`, `Stale`, `Unhealthy`, `Circuit Open`, and `Never Contacted` respectively.
- [ ] Given a previously unhealthy peer becomes `healthy` in a later payload, when the 5-second refresh succeeds, then `cluster-peer-status-<peer_id>` updates to `Healthy` without client-side summary remapping.
- [ ] Given `last_success_secs_ago` is null, below 1, below 60, 60 or above, and 3600 or above, when rows render, then values format as `Never`, `<1s ago`, `Ns ago`, `Nm ago`, and `Nh ago`.
- [ ] Given GET `/internal/cluster/status` fails, when the page renders, then `cluster-error-state`, `Failed to fetch cluster status`, and the request error text are visible.
- [ ] Given the response violates the discriminated contract, when `parseClusterStatusResponse` or `parsePeer` throws `ClusterStatusContractError`, then the same `cluster-error-state` branch is visible.
- [ ] Given the query returns no payload and no error, when the page renders, then `cluster-empty-state` says `Cluster status response is empty.`
- [ ] Given HA is enabled with `peers: []`, when the page renders, then `cluster-ha-state` and `cluster-ha-empty-state` are visible with `HA is enabled but no peer health rows are available yet.`
- [ ] Given a 390px viewport, when standalone or HA states render, then summary cards stack, long IDs/addresses remain readable, and the peer table scrolls inside its surface rather than causing page-level horizontal overflow.

## Visual contract

Name the target visual treatment for this screen without creating a second design system:

- Layout and surface: mirror `engine/dashboard/src/pages/Cluster.tsx`: title row with network icon, one page shell, standalone card or HA summary-card grid plus table card.
- Typography and color: use fjcloud tokens from `web/src/app.css` for card, border, muted, destructive, and badge treatments. Badge colors reinforce status but labels remain the canonical meaning.
- Controls and states: loading skeletons, error card, empty card, standalone card, HA summary cards, HA empty card, and table rows use stable `data-testid` selectors listed above.
- Mobile: one-column summary cards at 390px; peer table gets internal horizontal scroll only.
- Implementation evidence: `engine/dashboard/src/pages/Cluster.tsx`, `engine/dashboard/src/hooks/useClusterStatus.ts`, `engine/flapjack-http/src/router.rs`, `engine/flapjack-http/src/handlers/internal.rs`; corroborating evidence only from `engine/dashboard/src/pages/Cluster.test.tsx`, `engine/dashboard/src/hooks/__tests__/useClusterStatus.test.ts`, and `engine/dashboard/tests/specs/cluster.md`.

## Current Implementation Gaps

- The managed fjcloud console does not render this standalone-only operator surface today.
- Current evidence does not show a manual refresh or navigation path from Cluster; this spec does not invent one.
- The hook accepts nullable `last_success_secs_ago` but does not reject non-finite numbers; no target behavior is invented beyond the current parser evidence.

## Automated Coverage

- Browser-unmocked tests: no fjcloud implementation coverage exists yet. External React scenario evidence is `engine/dashboard/tests/specs/cluster.md`.
- Component tests: corroborating external React coverage is `engine/dashboard/src/pages/Cluster.test.tsx`.
- Server/contract tests: corroborating external hook/contract coverage is `engine/dashboard/src/hooks/__tests__/useClusterStatus.test.ts`; backend route evidence is in flapjack `router.rs` and `handlers/internal.rs`.
