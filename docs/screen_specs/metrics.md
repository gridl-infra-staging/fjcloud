# Metrics Screen Spec

## Scope

- Primary route: `/console/indexes/[name]?tab=metrics`
- Related specs: `index_detail.md`, `overview.md`
- Audience: authenticated customers inspecting one search index
- Priority: P0

## User Goal

Inspect raw engine-source operational metrics for a single index: `documents_count`, `storage_bytes`, `search_requests_total`, and `write_operations_total`, with a refresh control and a trustworthy fetch timestamp.

## Target Behavior

The Metrics tab renders inside the existing index-detail shell. Selecting it keeps the user on `/console/indexes/[name]`, shows four KPI cards backed by the customer-facing `/indexes/{name}/metrics` JSON endpoint, distinguishes these engine-source counters from the customer-behavior analytics shown on the Analytics tab, and lets the user retry only the metrics slice when the fetch fails.

## Required States

- Loading: the tab header, explainer copy, button row, and KPI slots render in place while the route payload is refreshing.
- Empty: when `documents_count`, `search_requests_total`, and `write_operations_total` are all zero, the tab shows `No metrics available yet - newly-created indexes report stats after the first scrape interval (60s).`
- Error: a tab-local `role="alert"` block renders with retry guidance while the page shell and other tabs remain usable.
- Success: the tab shows four KPI cards, a relative `Last fetched ...` label, and a visible refresh button.

## Mobile Narrow Contract

Baseline viewport: 390px wide. The heading, refresh button, fetched-time line, and all four KPI cards remain visible without horizontal scrolling. KPI cards collapse to a single-column stack.

## Controls And Navigation

- The shell owner remains `web/src/routes/console/indexes/[name]/IndexDetailShell.svelte`; Metrics extends that existing `?tab=` contract rather than adding a second tab owner.
- The tab strip exposes a `Metrics` tab button with `aria-selected="true"` when `?tab=metrics`.
- The refresh button retries the metrics dependency only; it does not introduce a parallel form action or full-page redirect.

## Acceptance Criteria

- [ ] Given `/console/indexes/[name]?tab=metrics`, when the page loads, then the Metrics tab is selected by the existing query-param tab owner in `IndexDetailShell.svelte`.
- [ ] Given a successful metrics payload, when the Metrics tab renders, then it shows four KPI cards for documents, storage, search requests, and write operations using the route-owned payload.
- [ ] Given a successful metrics payload, when the Metrics tab renders, then it shows a `Last fetched ...` relative-time label derived from `fetched_at`.
- [ ] Given a zero-value payload, when the Metrics tab renders, then it shows the deterministic empty-state copy instead of a route-level error.
- [ ] Given metrics loading fails, when the Metrics tab renders, then it shows a tab-local alert with a retry affordance and does not take over the whole index-detail page.

## Current Implementation Gaps

None known for the mapped launch-critical behavior; the Metrics tab is shipped per the owners listed under Automated Coverage.

## Automated Coverage

- Browser-unmocked tests: the metrics verification lane is `web/tests/e2e-ui/smoke/customer_release_surfaces.spec.ts`, which seeds a Metrics-ready index against the repo-owned local Playwright stack and asserts the Documents KPI equals the seeded document count via `$lib/format`'s `formatNumber` (exact `toHaveText(`Documents ${formatNumber(count)}`)`), with well-formed value patterns pinned on the storage, search-requests, and write-operations KPI cards.
- Honest-staging cross-check (a final gate, not the metrics verification lane): the authenticated contract probe `scripts/canary/contracts/customer_metrics_endpoint_authenticated_probe.sh --staging-only`.
- Component tests: `web/src/routes/console/indexes/[name]/tabs/MetricsTab.test.ts`
- Server/contract tests: `web/src/routes/console/indexes/[name]/detail.server.load.test.ts`; `web/tests/e2e-ui/mocked/index_metrics_tab.spec.ts`
