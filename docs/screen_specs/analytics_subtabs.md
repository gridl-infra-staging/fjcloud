# Analytics Tab (with sub-surface tabs)

## Task

Diagnose how customers are searching one index — across overview KPIs, raw queries, no-result queries, filter usage, conversion rate, device breakdown, and geography — through a tabbed sub-surface within the parent Analytics tab.

## Layout

1. Parent tab header: heading `Analytics` + period selector (`7d` / `30d` / `90d` segmented control, `data-testid="analytics-period-7d"` etc., existing).
2. **Sub-tab strip** (`data-testid="analytics-subtabs"`, new) — seven sub-tab buttons in this fixed order (matches upstream):
   1. `Overview` (`data-testid="analytics-subtab-overview"`)
   2. `Searches` (`data-testid="analytics-subtab-searches"`)
   3. `No Results` (`data-testid="analytics-subtab-no-results"`)
   4. `Filters` (`data-testid="analytics-subtab-filters"`)
   5. `Conversions` (`data-testid="analytics-subtab-conversions"`)
   6. `Devices` (`data-testid="analytics-subtab-devices"`)
   7. `Geography` (`data-testid="analytics-subtab-geography"`)
3. Sub-tab body (`data-testid="analytics-subtab-body"`) renders the active sub-tab's content — see State contract per-sub-tab.

## State contract

### Loading (any sub-tab)
- Active sub-tab body shows two-row skeleton (header card + chart area). Sub-tab strip and period selector remain interactive.

### Error (any sub-tab)
- Active sub-tab body shows `role="alert"` with sub-tab-specific message (e.g. `Could not load conversion data for this period.`) + `Retry` button. Other sub-tabs still navigable.

### Sub-state: Overview (default sub-tab; replaces current single-view AnalyticsTab content)
- Search-volume area chart (existing) — full width.
- Two side-by-side cards below: `Top Searches` (existing top-N table) and `No-Result Queries` (existing top-N table). Both link `View more →` to the Searches / No Results sub-tabs respectively.

### Sub-state: Searches
- Top searches table sortable by `count` (default desc) / `avg hits` / `query text`. Columns: `Query`, `Count`, `Avg Hits per Query`. Rows: ≤100 per page. `data-testid="analytics-searches-table"`.

### Sub-state: No Results
- Top no-result queries table. Columns: `Query`, `Count`. Rows ≤100. `data-testid="analytics-no-results-table"`.

### Sub-state: Filters
- KPI: `Total filters applied (period)`.
- Expandable table: `Filter attribute` | `Applied count` | `Top values`. Clicking a row expands to show top 10 filter VALUES for that attribute (e.g. `brand: Apple (412), Samsung (308), ...`). Backed by the existing flapjack engine `/2/filters` endpoint, proxied through a new fjcloud `getAnalyticsFilters` method.
- Secondary table: `Filters that returned zero results` (top N, smaller). `data-testid="analytics-filters-no-results"`.

### Sub-state: Conversions
- 4 KPI cards: `Conversion Rate`, `Add-to-Cart Rate`, `Purchase Rate`, `Click-through Rate` — each shows current period + delta vs previous period.
- Trend chart: conversion rate over the period (line chart). `data-testid="analytics-conversion-chart"`.
- Country filter dropdown (optional, narrows the conversion KPIs to a country). `data-testid="conversion-country-filter"`.
- Backed by the flapjack engine `/2/conversions/conversionRate` endpoint, proxied through a new fjcloud `getAnalyticsConversionRate` method.

### Sub-state: Devices
- 3 cards: `Desktop`, `Mobile`, `Tablet` — each shows search count + percentage of total. `data-testid="device-<platform>"`.
- Bar chart below: device breakdown over the period. `data-testid="device-chart"`.
- Filters out `platform === 'unknown'` per upstream convention.
- Backed by a new flapjack-engine endpoint (existing in upstream — `/2/devices` or equivalent; verify endpoint path during implementation), proxied as `getAnalyticsDevices`.

### Sub-state: Geography
- KPI card: `Countries (period)` — total distinct countries with searches.
- Table: `Country` | `Searches` (sortable, default desc). Each row clickable. `data-testid="geo-countries-table"`.
- On row click, the table replaces with a drill-down view: `<Flag> <CountryName>` heading + `Back to countries` link + breakdown of top searches FROM that country (top 50). `data-testid="geo-country-detail"`.
- Country names + flags via a static map in `web/src/lib/analytics/country-names.ts` (ported from upstream's `geography-utils.ts`).
- Backed by a new flapjack-engine endpoint (`/2/countries` or equivalent), proxied as `getAnalyticsCountries`.

## Navigation

- Route: `/console/indexes/[name]?tab=analytics&subtab=<overview|searches|noResults|filters|conversions|devices|geography>`.
- Default `subtab=overview` when query param absent.
- Sub-tab click: updates `?subtab=…` (debounced ~50ms so rapid clicks don't pollute history); back-button cycles through previously-visited sub-tabs.
- Period selector: shared across sub-tabs; changing period reloads the active sub-tab's data.
- Geography drill-down: uses a local component state (no URL param) — back-button-press exits drill-down to the country list; second back exits to the parent index detail.

## Acceptance Criteria

- Given the user opens the Analytics tab, when the page renders, then the sub-tab strip is visible with all 7 sub-tab buttons AND `Overview` is the active sub-tab.
- Given the user clicks `Searches`, when the sub-tab transitions, then the URL updates to `?subtab=searches` AND the search-volume chart is replaced by the top-searches table with `data-testid="analytics-searches-table"`.
- Given the user is on the Filters sub-tab with seeded filter analytics data, when the user clicks a filter-attribute row, then the row expands inline showing the top-10 values for that attribute (rendered as `<attribute>: <value> (<count>)` text).
- Given the user is on the Devices sub-tab, when the data resolves, then 3 cards (`device-desktop`, `device-mobile`, `device-tablet`) render with non-zero counts AND the bar chart is visible.
- Given the user is on the Geography sub-tab, when the user clicks a country row, then the table is replaced by the country drill-down view with the country flag, name, and top 50 searches from that country AND a `Back to countries` link.
- Given the user is on the Conversions sub-tab, when data resolves, then 4 KPI cards (Conversion Rate, Add-to-Cart, Purchase, Click-through) render with values AND each shows a delta-vs-previous-period indicator.
- Given the user changes period from `7d` to `30d`, when the new data resolves, then the active sub-tab's KPIs and charts re-render with 30-day values WITHOUT navigating to a different sub-tab.
- Given a sub-tab's backend endpoint returns 500, when the sub-tab loads, then the body shows `role="alert"` with a Retry button AND the sub-tab strip remains interactive (other sub-tabs still navigable).
- Given the user deep-links to `?tab=analytics&subtab=geography`, when the page loads, then Geography is the active sub-tab (no flash of Overview).

## Edge cases

- Period switch DURING sub-tab load: cancel in-flight request via per-(sub-tab, period) request token; only the most-recent token's response renders.
- Sub-tab with no data for the selected period (zero searches in 7d): show sub-tab-specific empty state (e.g. `No conversions recorded for this period.`) rather than the generic skeleton-stuck or error path.
- Geography drill-down country with zero hits: show `No searches recorded from <country> in this period.` (not an error).
- Country code unknown to the country-names map (e.g. `XX`): fall back to displaying the raw code with no flag.
- Very long top-filters / top-searches result set (>100): table paginates client-side (since data set is bounded by upstream limit).
- Deep-link with invalid `subtab=foo`: default to Overview; do not crash.

## Current Implementation Gaps

- Current: AnalyticsTab is a single view with search-volume chart + Top Searches + No-Result Queries inline; no sub-tab strip.
  Target: 7-tab sub-surface per Layout.
  Evidence: `web/src/routes/console/indexes/[name]/tabs/AnalyticsTab.svelte:62-200` (single-view layout); parent audit Recommendation 3.

- Current: Devices / Geography / Filters / Conversions now route through fjcloud's API, TS client, server load, and Svelte sub-tabs.
  Target: keep the cross-layer sub-tab data path wired through fjcloud-owned endpoints rather than directly coupling the browser to upstream engine routes.
  Evidence: `infra/api/src/routes/indexes/analytics.rs`; `web/src/lib/api/client.ts`; `web/src/routes/console/indexes/[name]/analytics-management.server.ts`; `web/src/routes/console/indexes/[name]/tabs/AnalyticsTab.svelte`; component/API coverage in `web/src/lib/api/client-analytics.test.ts` and `web/src/routes/console/indexes/[name]/detail.server.actions.test.ts`.

- Current: Analytics sub-tabs have dedicated browser coverage for navigation and each promoted sub-surface.
  Target: retain the route-level E2E owners for sub-tab behavior and seeded data rendering.
  Evidence: `web/tests/e2e-ui/full/analytics_subtabs.spec.ts`; `web/tests/e2e-ui/full/analytics_devices.spec.ts`; `web/tests/e2e-ui/full/analytics_geography.spec.ts`; `web/tests/e2e-ui/full/analytics_filters.spec.ts`; `web/tests/e2e-ui/full/analytics_conversions.spec.ts`.

## Automated Coverage

- Browser-unmocked tests:
  - `web/tests/e2e-ui/full/analytics_subtabs.spec.ts` (new) — tab strip renders all 7 sub-tabs; clicking each navigates + URL updates; period selector shared; deep-link to specific sub-tab works.
  - `web/tests/e2e-ui/full/analytics_devices.spec.ts` (new) — seeded device data renders 3 cards + chart.
  - `web/tests/e2e-ui/full/analytics_geography.spec.ts` (new) — country table renders; drill-down works; back-link returns.
  - `web/tests/e2e-ui/full/analytics_filters.spec.ts` (new) — top-filters table; row expansion shows values.
  - `web/tests/e2e-ui/full/analytics_conversions.spec.ts` (new) — 4 KPI cards render; chart renders.
- Browser-mocked tests: `web/tests/e2e-ui/mocked/analytics_subtab_error.spec.ts` (new) — sub-tab 500 produces role=alert.
- Component tests: extend `web/src/routes/console/indexes/[name]/tabs/AnalyticsTab.test.ts` — sub-tab navigation state machine; deep-link parsing.
- Server/contract tests: extend `web/src/routes/console/indexes/[name]/detail.server.actions.test.ts` — new analytics loads for each sub-tab call the proxy and return shaped payloads.
