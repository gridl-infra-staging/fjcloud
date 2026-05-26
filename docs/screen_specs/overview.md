# Overview Tab

## Task

Inspect one index's high-level state, test a quick search, run per-index export/import, and jump into deeper tools (Analytics, Settings) — all from a single index-detail landing surface.

## Layout

1. Tab header row: heading `Overview` (no `Last updated` tag — parked per [post_launch_followups.md](../post_launch_followups.md); requires a backend `updated_at` column on the indexes table + sqlx migration + TS-type addition before the relative-time UI can land).
2. Stat cards row (4 cards, grid): `Entries`, `Data Size`, `Region`, `Endpoint` (existing) — unchanged from current implementation.
3. **Analytics summary section** (`data-testid="overview-analytics-summary"`) — three KPI mini-cards: `Searches (7d)`, `No-results rate (7d)`, `Top query (7d)` — each sourced from existing analytics endpoints. Below the cards, a 7-day sparkline (`data-testid="overview-analytics-sparkline"`) of search count. Footer: `View Details →` link (`data-testid="overview-view-analytics-link"`) that navigates to the Analytics tab.
4. **Data management card** (`data-testid="overview-data-management"`) — title `Data Management` + two buttons side by side: `Export Index` (`data-testid="overview-export-btn"`, see Export-running state for the paginate-and-concat behavior) and `Import Documents` (`data-testid="overview-import-btn"`, opens file picker → uploads through existing `?/uploadDocuments` action). Below the buttons, a one-line help text: `Export downloads all documents as JSON. Import adds new documents without replacing existing ones.`
5. Test Search widget (existing) — unchanged.
6. Connect Your App (existing) — unchanged.
7. Read Replicas section (existing) — unchanged.
8. **In-card navigation footer** (`data-testid="overview-navigation"`) — three small `Card-link` blocks: `Configure Settings →` (links to Settings tab), `View Analytics →` (links to Analytics tab), `Manage Documents →` (links to Documents tab). Renders ONLY when the index has provisioned (endpoint present).

## State contract

### Loading
- Stat cards show shimmer placeholders. Analytics summary section shows three card-shaped skeletons. Data Management card shows disabled buttons. Test Search + Connect Your App + Replicas keep their existing loading behavior.

### Error (analytics summary load failed)
- Analytics summary section renders a single `role="alert"` line: `Analytics summary unavailable. <Retry button>` — does NOT block the rest of the page. Other sections render normally.

### Error (index not yet provisioned, `endpoint === null`)
- Stat cards show their values; Endpoint card shows `Preparing...` (existing). Test Search hidden. Connect Your App shows `Endpoint not ready` (existing). Data Management buttons disabled with tooltip `Available once your index is provisioned`. In-card navigation footer hidden.

### Provisioned (default)
- Per Layout. All sections render.

### Export-running (client-side paginate-and-concat)
- Implementation: there is no fjcloud snapshot/export endpoint today, so Export runs CLIENT-SIDE — repeated calls to the existing `?/browseDocuments` action paginate at 1000 docs/page, accumulating hits in browser memory, then producing a single JSON file download via `Blob` + `URL.createObjectURL`. Hard cap at 10,000 documents — beyond that, the button shows a different state (Export-too-large) rather than triggering the loop.
- Visible state: `Export Index` button shows `Exporting <N> of <total> docs…` (progress indicator updating each page); button disabled. On success, browser download starts (filename `<indexName>-export-<YYYYMMDD>.json`); button returns to default state with a transient `Exported <N> documents` toast (~3s).

### Export-too-large
- When `index.entries > 10000`: the `Export Index` button stays enabled but clicking it opens a small inline notice (NOT a dialog — just a `role="alert"` block) reading `This index has <N> documents. Browser-side export is limited to 10,000 documents. Contact support to export larger indexes.` Documents the limit honestly; sets up the post-launch backend-export work as a real customer ask.

### Export-error
- Any pagination call fails mid-loop: `Export Index` button returns to default state; inline `role="alert"` next to button shows `Export failed after <N>/<total> documents: <server message>`. Partial download NOT delivered — keeps the contract simple (all-or-nothing).

### Import-running
- `Import Documents` button shows `Uploading…` label + spinner; disabled.

### Import-success
- Transient `Imported <N> documents. <Refresh page to see them>` banner above stat cards; banner has `Refresh` button that re-invalidates the load.

### Import-error
- Inline `role="alert"` next to button with server message. Button re-enabled.

## Navigation

- Route: `/console/indexes/[name]?tab=overview` (default tab when query param absent).
- Entry: clicking an index in `/console/indexes` list; clicking `Overview` in the index-detail tab strip.
- `View Details →` link in Analytics summary: navigates to `?tab=analytics` on the same index route — preserves browser back.
- In-card navigation footer links: each navigates to its `?tab=<name>` route.
- Export: triggers browser file download; no route change.
- Import: opens file picker; on file select, uploads via existing `?/uploadDocuments` action.

## Acceptance Criteria

- Given a provisioned index with 1000+ entries, when the Overview tab loads, then `Entries`, `Data Size`, `Region`, `Endpoint` cards show their values AND the Analytics summary section renders three KPI cards with values (not skeletons) within 3s.
- Given the Analytics summary section is rendered, when the user clicks `View Details →`, then the URL updates to `?tab=analytics` and the Analytics tab body renders.
- Given an index with ≤10,000 entries, when the user clicks `Export Index`, then the client paginates through documents (showing `Exporting <N> of <total> docs…` progress), accumulates them into a single JSON array, downloads a file named `<indexName>-export-<YYYYMMDD>.json` AND shows a transient toast `Exported <N> documents` for ~3s.
- Given an index with >10,000 entries, when the user clicks `Export Index`, then no download triggers; an inline `role="alert"` shows the size-limit message AND no pagination requests are made.
- Given the user clicks `Import Documents` and selects a valid JSON file, when the upload completes, then a banner `Imported <N> documents` appears above the stat cards with a working `Refresh` action.
- Given the analytics summary endpoint returns 500, when the Overview tab loads, then ONLY the Analytics summary section shows `role="alert"` with a Retry button; stat cards + Test Search + Replicas remain functional.
- Given an unprovisioned index (`endpoint === null`), when the Overview tab loads, then Data Management buttons are disabled with the `Available once your index is provisioned` tooltip AND the in-card navigation footer is hidden.

## Edge cases

- Index with 0 entries: Analytics summary cards show `0` / `N/A` placeholder for Top Query; sparkline shows flat line at zero. Not an error state.
- Export of very large index (>10k docs): the Export-too-large state owns this case (see State contract). A proper backend-streamed export endpoint is parked in [post_launch_followups.md](../post_launch_followups.md) (same backend-design conversation as the Metrics page).
- Import file larger than 50MB: server rejects with a customer-facing message surfaced via inline `role="alert"`.
- Multi-index export "Export All" surface: explicitly NOT in scope for the per-index Overview tab — that lives on `/console/indexes` list page (separate audit item, post-launch).
- `Health indicator` / `Server health badge` from the upstream parent audit: confirmed N/A — engine-internal connection-health surfaces inappropriate for the managed cloud product. Reclassify in pre-launch sweep.

## Current Implementation Gaps

- Current: no analytics summary section on the Overview tab. Customers must click into the Analytics tab to see any usage signal.
  Target: 3 KPI cards (Searches 7d, No-results rate 7d, Top query 7d) + 7-day sparkline + `View Details →` link.
  Evidence: `web/src/routes/console/indexes/[name]/tabs/OverviewTab.svelte` (no matches for `analytics summary|KPI|sparkline`); parent audit rows "Analytics summary section displays data" / "Analytics chart renders in overview analytics section" (both `absent`).

- Current: no per-index Export or Import controls on the Overview tab. fjcloud's API has NO snapshot/export proxy endpoint today (the upstream flapjack engine has `/1/indexes/<name>/snapshot` but fjcloud does not surface it).
  Target: `Data Management` card per Layout #4. Export ships as a CLIENT-SIDE paginate-and-concat using the existing `?/browseDocuments` action, gated at 10,000 documents (see Export-too-large state). A proper backend export endpoint is parked in [docs/post_launch_followups.md](../post_launch_followups.md) for indexes beyond that threshold.
  Evidence: `web/src/lib/api/client.ts` (no matches for `snapshot|exportIndex|exportObjects`); `infra/api/src/routes/indexes/` (no export proxy route); parent audit row "Per-index export and import buttons visible" (`absent`).

- Current: no `Last updated` tag on the Overview tab.
  Target: **PARKED.** Relative-time tag next to heading sourced from a future `index.updated_at` field. Requires a backend `updated_at` column on the indexes table + sqlx migration + TS-type addition to `Index` in `web/src/lib/api/types.ts` (currently has only `created_at` per `web/src/lib/api/types.ts:218-227`). Parked in [post_launch_followups.md](../post_launch_followups.md); un-park once the backend schema lands.
  Evidence: `OverviewTab.svelte` (no matches for `updated|last updated`); `web/src/lib/api/types.ts` `Index` interface has no `updated_at` (verified 2026-05-25); parent audit row "Index row shows storage size and update info" (`partial`).

- Current: tab strip is the only path from Overview to Analytics / Settings / Documents.
  Target: in-card navigation footer with direct links (additive — does not remove the tab strip).
  Evidence: parent audit rows "View Details link navigates to analytics page" / "Settings link navigates to settings page" (both `partial`).

- Current: parent audit listed `Health indicator` + `Server health badge` as `absent`.
  Target: N/A — engine-internal, reclassify in pre-launch sweep.
  Evidence: confirmed engine-internal per `post_launch_followups.md` § "N/A — engine-internal".

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/overview_enrichment.spec.ts` (new) — analytics summary renders for a populated index; sparkline visible; `View Details →` navigates to Analytics tab; Export Index downloads JSON; Import Documents accepts a small JSON file and reflects the count in a refresh banner; in-card nav footer links navigate correctly.
- Browser-mocked tests: `web/tests/e2e-ui/mocked/overview_analytics_error.spec.ts` (new) — analytics-summary endpoint 500 produces the partial-failure `role="alert"` without breaking other sections.
- Component tests: extend `web/src/routes/console/indexes/[name]/tabs/OverviewTab.test.ts` — KPI card rendering matrix (zero entries / populated / endpoint-null states); in-card-nav-footer hidden when unprovisioned.
- Server/contract tests: extend `web/src/routes/console/indexes/[name]/detail.server.actions.test.ts` for the new export action (if added as `?/exportIndex` server action) and the new analytics-summary load path.
