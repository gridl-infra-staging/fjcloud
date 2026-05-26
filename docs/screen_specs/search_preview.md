# Search Preview

## Task

Generate a temporary preview key for an index and use a full browse surface (search box, facets, filters, pagination, highlighted hits, hybrid-search controls) to validate live search behavior against that index.

## Layout

### Pre-key state (gate UI, before `Generate Preview Key`)

1. Section heading `Search Preview`.
2. Gate panel whose body varies by index lifecycle (see State contract: Cold-index / Restoring / Provisioning / Awaiting-key / Generating-key).
3. When `Awaiting-key`: explanatory copy `Generate a temporary search key to preview live search results from this index.`, optional error message (`role="alert"`), and primary button `Generate Preview Key` (form posts to `?/createPreviewKey`).

### Post-key browse surface (after key generation)

1. Header strip (left → right): index name, inline `Entries` count, `Data Size`, `[VectorStatusBadge]` (only when `health.capabilities.vectorSearch === true` and at least one embedder configured).
2. Header strip right cluster: `Track Analytics` toggle (Switch + animated red recording-indicator dot when on), `Display Preferences` button (opens `[DisplayPreferencesModal]`), `Add Documents` button (opens the same dialog used by the Documents tab).
3. `[SearchPreviewBox]`: search input (`type="search"`, placeholder `Search documents…`, Enter submits) and inline filter-expression toggle button. When toggle is on, a second input accepts a raw Algolia-format filter string (e.g. `category:books AND price > 10`). Active filter renders as a removable badge with an `x` clear.
4. `[HybridSearchControls]` (gated — see Hybrid-search-active state): horizontal strip with `Hybrid Search` label, semantic-ratio range slider (0–1, step 0.1), live ratio label (`Keyword only` / `Balanced` / `Semantic only` / `<N>% semantic`), and an embedder `<select>` when more than one embedder is configured.
5. Main two-column area (collapses to one column below `lg`):
   - Left (flex-1): `[SearchPreviewResults]` — results header card showing `<nbHits> results · <processingTimeMS>ms`, then a list of `[DocumentCard]` hits, then pagination controls (`< Prev`, page-N indicator, `Next >`, total-page count) at the bottom.
   - Right (300px sidebar on `lg`+, above results on smaller widths): `[SearchPreviewFacets]` — one collapsible panel per faceted attribute. Each panel shows attribute name, list of values with per-value document count, checkbox to toggle, and a `Clear` link per panel when at least one value is selected. A global `Clear all` link at the top of the sidebar when any facet is active.

### Component primitives referenced

Three new primitives are referenced by name; their full specs are deferred to the implementation lane that builds them. Brief inline contracts:

- `[DocumentCard]` — renders one hit as a structured card: header from configured `titleAttribute` / `subtitleAttribute` / `imageAttribute`; matched `<em>` highlight terms rendered as `bg-yellow-200` spans (sanitized via DOMPurify); body shows remaining fields in stable canonical order (see Edge cases); footer actions `View JSON` (expands inline Monaco viewer), `Copy objectID`, `Ranking info`.
- `[DisplayPreferencesModal]` — modal with three single-select dropdowns (Title field, Subtitle field, Image field), a multi-select chip group for Tag fields, and footer actions `Auto-detect`, `Clear`, `Cancel`, `Save`. Selections persist per-index in localStorage and drive `[DocumentCard]` rendering.
- `[VectorStatusBadge]` — small badge: `Vector Search · <N> embedder(s) · Neural|Keyword`. Hidden entirely when vector search is not enabled on the engine build.

## State contract

### Loading
- Pre-key panel shows skeleton row in place of the `Generate Preview Key` button until the route load resolves the index lifecycle. No misleading active search box.

### Error
- Preview-key generation failure renders an inline `role="alert"` message inside the gate panel (e.g. `Failed to generate preview key: <reason>`); the `Generate Preview Key` button remains enabled so the user can retry. Search-time errors render in the results panel as `Search failed: <message>` with a `Retry` link that re-issues the last request.

### Cold-index
- Gate panel renders yellow callout: `Search preview is not available while the index is cold. Please wait for the index to become active.` No button, no search box.

### Restoring
- Same as Cold-index but copy says `restoring`. No button, no search box.

### Provisioning
- When `index.endpoint` is not yet available: neutral callout `Endpoint not available yet. The index is still being provisioned.` No button, no search box.

### Awaiting-key
- Active ready index with endpoint, no preview key yet. Explanatory copy + `Generate Preview Key` button visible. No search box mounted.

### Generating-key
- Submit-in-flight after click. Button disabled and labeled `Generating…`. Form re-enables on response (success transitions to Browse-empty-query; failure transitions to Error).

### Browse-empty-query
- Post-key browse surface mounted. Search input empty. Results panel shows the placeholder hits returned by an empty query (engine default) OR an instructional empty-state card `Type a query to start searching` when the engine returns zero hits for empty queries. Facets panel renders facet values from an unconstrained query.

### Browse-with-query-results
- User has submitted a query and at least one hit returned. Results header `<nbHits> results · <processingTimeMS>ms` visible. Hit cards render with highlighted matches. Pagination controls visible iff `nbHits > hitsPerPage`.

### Browse-with-query-no-results
- Submitted query returned zero hits. Results panel renders `No results found.` Facets panel collapses to empty.

### Browse-with-facets-applied
- One or more facet values selected. Active facet pills render at the top of the results panel with per-pill `x` to remove. Results re-issue with `facetFilters` appended. `Clear all` link visible in facets sidebar. URL reflects facet selections.

### Browse-paginated
- User has advanced past page 0. Page-N indicator visible. `< Prev` enabled, `Next >` disabled iff on last page. URL reflects current page.

### Hybrid-search-active
- `[HybridSearchControls]` mounted (only when vector search is enabled on the engine AND at least one embedder is configured on the index). Slider at 0 sends pure keyword query (no `hybrid` param); slider > 0 sends `hybrid: { semanticRatio, embedder }` in each search request. Ratio label updates live. Embedder dropdown only renders when more than one embedder configured.

### Display-prefs-open
- `[DisplayPreferencesModal]` overlay visible. Search input and results behind modal remain in their current state but are non-interactive. Save closes the modal and re-renders all visible hit cards with the new attribute mapping. Cancel discards changes.

## Navigation

- Route: `/console/indexes/[name]` with the `SearchPreview` tab active (tab state is part of the index-detail page's tab strip).
- Entry: tab strip on the index-detail page; from the `Indexes` screen's post-create banner `Index ready — try the search preview` (see `indexes.md` § Create-success-banner-on-detail) which deep-links here.
- URL query-param persistence: `?q=<query>&p=<page>&f=<facetFilters-encoded>&hr=<hybridRatio>` reflect the current query, page, active facets, and hybrid ratio. Pasting a URL with these params reproduces the same browse state on load (after preview-key generation). The preview key itself is NOT in the URL — it is regenerated on each session.
- Back: browser back undoes the last URL-state change (e.g. removing a facet, reverting a page advance). Back from the gate state (no key) returns to the parent index-detail tab strip.
- Display Preferences modal: open/close does not change URL. Saved prefs persist in localStorage keyed by index name.
- Deep-link via shared URL: a user can share `/console/indexes/movies?tab=search-preview&q=inception&f=genre:Sci-Fi&p=2` and the recipient (after generating their own preview key) sees the same query+facet+page state.

## Acceptance Criteria

- Given a cold or restoring index, when the user opens the SearchPreview tab, then the search box is never mounted and the lifecycle-specific copy is shown.
- Given an active ready index with no preview key, when the user clicks `Generate Preview Key`, then within 5s the browse surface mounts with the search input focused.
- Given the Movies index seeded by the demo-loader, when the user lands on SearchPreview with a generated key, then facet panels show `genre`, `director`, and `year`, and clicking a `genre` value narrows the visible hits to that genre only (verified by `nbHits` decreasing and every visible hit's `genre` field matching).
- Given a query that returns hits, when results render, then matched terms inside title/body/configured fields are wrapped in `<em>` highlight markup styled distinctly from surrounding text.
- Given a query that returns more than `hitsPerPage` hits, when the user clicks `Next >`, then page 2 hits render, the URL updates to `?p=1`, and the `< Prev` control becomes enabled.
- Given a query returning zero hits, when the response arrives, then `No results found.` renders and the facets sidebar collapses (no facet values to show).
- Given a facet value is active and the user clicks its `x` pill, then the facet is removed, `facetFilters` is dropped from the next request, and the URL updates.
- Given the `Display Preferences` modal is open, when the user selects `title` as Title field and `poster` as Image field and clicks `Save`, then the modal closes, every visible hit card re-renders with the poster image and title prominently, and the same selection is restored on reload.
- Given an index has at least one embedder configured AND the engine reports `vectorSearch: true`, when the SearchPreview tab loads, then `[HybridSearchControls]` is visible above the results.
- Given the hybrid slider is at 0.5, when the user submits a query, then the request body includes `hybrid: { semanticRatio: 0.5, embedder: "<first-embedder>" }` and the live label reads `Balanced`.
- Given the user toggles `Track Analytics` on, when a hit is clicked, then a click event is POSTed to `/1/events` with the right `queryID`, `objectID`, `position`, and a session-scoped user token.
- Given the user shares a URL containing `?q=foo&f=genre:Action&p=1`, when a recipient with their own preview key opens it, then after key generation the search input is prefilled, the `genre:Action` facet is active, and page 2 is shown.
- Given the filter-expression input contains a malformed filter, when the user submits, then the results panel renders a `Search failed: invalid filter expression` message with the failing expression highlighted, and the prior valid hits remain visible underneath until the user retries.
- Given the engine is slow, when a search is in flight, then a skeleton card placeholder (matching final card shape) renders in the results panel rather than a plain spinner.

## Edge cases

- Preview key expiration (server returns 401/403 mid-session): re-prompt with `Preview key expired. Generate a new key to continue.` and a `Generate Preview Key` button; clear cached hits.
- Very large facet count (>50 values for one attribute): facet panel scrolls vertically (max-height ~320px) with a `Show all` link to expand; counts always visible.
- Index has zero faceted attributes configured: facets sidebar shows `No facets configured for this index — set "Attributes for faceting" in the Settings tab.` with a link to the Settings tab.
- Index has no embedders configured AND vector search is enabled on the engine: `[HybridSearchControls]` is not rendered (no slider, no embedder picker, no error). The pure-keyword search path is unaffected.
- Engine build does not include vector search: `[VectorStatusBadge]` renders `Vector Search unavailable (not compiled in)` and `[HybridSearchControls]` is not rendered.
- Hit lacks the configured `titleAttribute`: `[DocumentCard]` falls back to `objectID` for the header, never crashes.
- Inconsistent field shapes across hits: stable canonical field order is computed once from the union of all visible hits' keys, so every card lists the same attributes in the same positions even when some are null.
- User submits an empty query while facets are active: facets remain active, results panel shows all docs matching the facet selection.
- User toggles analytics off mid-session: subsequent clicks do not post events; previously posted events are unaffected. The session user token is retained so toggling back on re-uses the same identity.
- Network offline during a search: results panel shows `Search failed: network unavailable` with `Retry`; prior hits remain visible.

## Current Implementation Gaps

- Current: bare InstantSearch with search box + `<pre>JSON.stringify(rest)</pre>` hit cards at `web/src/lib/components/InstantSearch.svelte`.
- Target: full browse surface per Layout § Post-key, with facets, filters, pagination, highlighting, display preferences, hybrid controls, analytics toggle, and structured `[DocumentCard]` rendering.
- Evidence: parity audit `docs/audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/tab_searchpreview.md` (8 present / 1 partial / 15 absent of 24 catalog rows + 5 absent OOC gaps).

Specific deltas (each tied to an audit row or OOC observation):

- Current: no facet UI at all. Target: per-attribute facet panels with counts, toggles, per-panel and global clears. Evidence: audit rows 2, 3, 4, 9, 18, 19, 20.
- Current: no pagination plumbed; user stuck on engine's default page. Target: `< Prev` / `Next >` controls with page-N indicator and URL persistence. Evidence: audit row 8.
- Current: no `attributesToHighlight` sent, no `_highlightResult` consumed. Target: highlighted matches sanitized via DOMPurify and rendered with distinct styling. Evidence: audit OOC § Highlighting.
- Current: no filter-expression input. Target: filter-toggle button, raw `filters=` string input, active-filter badge with clear. Evidence: audit OOC § Filter expression input.
- Current: no per-result actions. Target: `View JSON` (Monaco), `Copy objectID`, `Ranking info` per hit card. Evidence: audit OOC § Per-result document actions.
- Current: no Display Preferences modal; hit cards render `<strong>{title ?? objectID}</strong>` + `<pre>{JSON.stringify(rest)}</pre>`. Target: `[DisplayPreferencesModal]` driving `[DocumentCard]`. Evidence: audit OOC § Display Preferences modal.
- Current: no hybrid-search controls; no `hybrid: { semanticRatio, embedder }` ever sent. Target: `[HybridSearchControls]` strip when vector search is enabled and embedders are configured. Evidence: audit rows H1, H2, H3, H4.
- Current: no analytics toggle, no `/1/events` posts, no session user token. Target: `Track Analytics` switch with recording indicator, session-scoped user token, click-event POSTs. Evidence: audit row 10.
- Current: no URL query-param persistence; reload returns to empty query. Target: `?q`, `?p`, `?f`, `?hr` reflect current browse state. Evidence: deferred from prior audit — required for shareable deep-links.
- Current: hit field ordering follows JSON parser key-order (non-deterministic across hits). Target: stable canonical field order computed once across the visible result set. Evidence: audit OOC § Stable field ordering.
- Current: loading state is the text `Searching...`. Target: skeleton cards matching final card shape. Evidence: audit OOC § Loading skeleton (partial).
- Current: results header is a single-line `{nbHits} results` caption. Target: dedicated header card with `<nbHits> results · <processingTimeMS>ms`, `data-testid="results-count"`, `data-testid="results-label"`. Evidence: audit row 7 (partial).
- Current: no inline index stats / `[VectorStatusBadge]` adjacent to search box. Target: header strip with entries, data size, vector badge. Evidence: audit row 12.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/search-preview.spec.ts` covering each acceptance criterion against a seeded Movies index.
- Browser-mocked tests: `web/tests/e2e-ui/mocked/search-preview.spec.ts` only for deterministic states hard to reproduce against a live engine (preview-key expiration mid-session, hybrid-controls visibility gating on `capabilities.vectorSearch`).
- Component tests: `web/src/lib/components/SearchPreviewBox.test.ts`, `SearchPreviewResults.test.ts`, `SearchPreviewFacets.test.ts`, `HybridSearchControls.test.ts`, `DisplayPreferencesModal.test.ts`, `DocumentCard.test.ts`, plus existing `SearchPreviewTab.test.ts` and `detail-search-preview.test.ts`.
- Server/contract tests: existing `detail.server.actions.test.ts` and `search-preview-helpers.test.ts`, extended for the new search-params surface (`facets`, `facetFilters`, `filters`, `page`, `hitsPerPage`, `attributesToHighlight`, `hybrid`) in `web/src/lib/flapjack-search-client.test.ts`.

Browser tests must follow `~/.matt/scrai/globals/standards/browser_testing.md`: liberal `data-testid` attributes, no xpath/CSS selectors, assert actual visible text/values not just element existence.
