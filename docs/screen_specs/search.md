# Search

## Task

Search or browse an authenticated index, refine results with configured facets, and inspect
the desired record without managing engine credentials.

## Layout

### Stable shell

1. Search is the second index-detail tab, immediately after Overview.
2. The page renders one `Search` heading. A top toolbar contains the `Search as you type`
   checkbox, query field, Search action, clearly labeled advanced-filter control, and
   preview-activity control.
3. Active refinement chips appear below the query field only when refinements exist.
4. Desktop uses a 240-280px sticky Refine sidebar beside a flexible results column.
   The sidebar is bounded to the viewport and scrolls independently when its facets are taller
   than the available space.
5. The results toolbar shows exact result count, engine processing time, and page size.
6. Result cards expose an explicit `Open details` or `Inspect` action; raw JSON is available
   through that visible action rather than an invisible analytics-only card click.

### Narrow layout

- At 390px the sidebar is not squeezed beside results. `Refine (N)` opens an overlay drawer.
- Escape and backdrop close the drawer and return focus to its trigger.
- Keyboard focus stays within the open drawer.
- Query, results, pagination, and inspect actions remain within the viewport.

### Result presentation

- There is no Display Preferences modal. Conventional fields select title, subtitle, image,
  and tags deterministically.
- `Search as you type` is the only persisted search-display choice and is an inline checkbox
  directly above the query field, scoped per index.
- When an image is available, the result card places it beside the text rather than stacking
  all content vertically. Raw JSON remains behind `Open details`.
- `Add advanced filter` reveals an `Advanced filter expression` field with an example that
  explains the supported expression syntax.

## State contract

### Loading settings

Render the stable shell while configuration loads. Do not label facet configuration until
authoritative index settings resolve.

### Settings failure

Show `Couldn't load facet configuration` with Retry or Settings navigation. Never infer
`No facets configured` from a failed or empty search response.

### Initial ready

The query field is immediately usable. Opening Search sends no search request. Configured
facet names come from settings. Display fields use conventional names from the document
sample and returned hits.

### Searching

After explicit submission, retain prior hits and refinements and show an in-place progress
indicator. A hydrated URL with a non-empty committed query runs exactly once.

### Populated results

Show exact result count, processing time, configured facets with response counts, and
one-based page information. Engine pages remain zero-based on the wire.

### Empty index

Show Add documents. Retain configured facet names but do not claim those facets have values.

### No matches

Retain query and active filters. Show Clear filters only when filters are active and provide
a concise recovery suggestion. Configured facets remain visible with `No values for these
results` where appropriate.

### No facets configured

Only when authoritative settings contain no configured facets, show:

> No facets configured
>
> Make fields such as genre, year, or language filterable to refine these results.
>
> Configure facets

The action navigates to `?tab=settings&settingsTab=facets-filters`. No clear action appears.

### Configured facets with values

Render every configured facet returned by settings. Counts come exactly from the standard
engine `facets` response. Global Clear all and per-facet clear appear only when relevant
refinements are active.

### Search failure

Retain query, filters, and prior hits. Show a customer-safe error and Retry. Do not clear
intent or fall back to a key form.

### Authorization failure

Show one authenticated-search failure with Retry. Never display or request a browser search
key.

### Lifecycle unavailable

- Cold: explain that the index is in cold storage to reduce storage costs and show a
  `Restore index` action. A failed restore remains on the Search tab with the API's
  customer-safe error in an alert.
- Restoring: explain that restore time depends on index size and show `Refresh status`.
  Search controls remain hidden until a refreshed index payload reports `active`.
- Provisioning: explain that the index is still being prepared. Do not offer restore or
  render active Search controls.

Never tell a customer to wait for a cold index to become active: cold indexes require an
explicit restore request.

### Search as you type

The inline checkbox defaults off and persists per index. When on, each query edit searches;
when off, typing remains local until Search or Enter commits it.

### Preview activity off

Default is Off. Search requests explicitly send boolean `analytics=false`; explicit result
opens send no preview event.

### Preview activity on

The label is `Record preview activity in Analytics`. Help text is:

> When enabled, preview searches and explicit result opens are recorded for this index and
> may appear in Analytics. When disabled, preview searches are excluded.

Subsequent searches send boolean `analytics=true` and `clickAnalytics=true`. An explicit
result open sends the returned query ID, object ID, absolute one-based position, timestamp,
and session-scoped non-PII preview token. Show `Recorded result open` only after the event
endpoint acknowledges it. An analytics tag is permitted only after an end-to-end contract
probe proves support.

Changing the preview-activity state invalidates any query ID from the prior state. Result
opens remain inspectable but emit no event until a search under the new state finishes;
retained hits also emit no event while a replacement search is pending.

### Preview activity failure

Missing query ID suppresses the correlated event and shows a deterministic warning. Event
401, 403, 429, timeout, and other failures show a non-blocking warning and are never
classified as success.

## Results and highlighting

- Default title: `title`, then `name`, then `objectID`.
- Default subtitle: `overview`, then `description`.
- Default image: `poster_url`, then `image_url`, then `image`, and only safe HTTP(S) URLs.
- Default tags: `genre`, `genres`, `category`, `categories`, then `tags`.
- Sanitized engine `<em>` output is normalized to application-owned `<mark>` semantics.
- Marked text uses bold weight, yellow background, readable ink contrast, and normal font
  style. Scripts, handlers, image injection, frames, and objects are forbidden.

## Navigation

- Route: `/console/indexes/[name]?tab=search`.
- Tab ID and slug remain `search`; no compatibility alias is introduced.
- Browser back/forward restores selected tab and committed query/refinement/page state.
- Search is second on desktop and narrow tab navigation.
- The Refine overlay does not change the URL. The per-index `Search as you type` choice is
  browser-local and does not change committed query state.
- Add documents opens the established Documents action; Configure facets uses the existing
  Settings destination.

## Acceptance Criteria

- [x] Opening a ready Search tab sends no request until the customer submits a query.
- [x] A URL-hydrated non-empty query sends exactly one request.
- [x] Search works through the dashboard session without generating or exposing a key.
- [x] Movies settings read back exact facets `genre`, `director`, and `year`; a standard
      `facets` response renders their hand-calculated counts.
- [x] Selecting Action in the known-answer fixture returns exactly the expected object IDs,
      not merely fewer hits.
- [x] An empty index, configured facets with zero values, and no configured facets render
      three different observable states.
- [x] Search renders one page heading, has no Display Preferences control, and exposes the
      per-index `Search as you type` checkbox directly above the query field.
- [x] `Add advanced filter` reveals an `Advanced filter expression` field and a concrete
      example; its active expression is summarized as `Filtering by: …`.
- [x] A conventional image URL renders beside the result text in a bounded image column.
- [x] Sanitized engine `<em>` content renders as bold yellow `<mark>` text with normal font
      style, while unsafe markup is absent.
- [x] Analytics off sends JSON boolean `false`; on sends JSON booleans `true` and preserves
      the exact response query ID for result-open events.
- [x] Changing analytics state or starting a replacement search invalidates the prior query
      ID so retained hits cannot be correlated to the wrong query.
- [x] With 20 hits per page, the first result on UI page 2 sends position 21.
- [x] Missing query IDs and 401/403/429 event responses produce visible failure states.
- [x] Two browser sessions have different preview tokens; one session reuses its token.
- [x] Desktop keeps Refine and the first result simultaneously in bounds; 390px uses a
      focus-trapped, focus-returning drawer.
- [x] Replacement searches retain the prior result list while loading.
- [x] Every result-open action has a visible inspector/detail outcome.
- [x] A cold index offers `Restore index`; a restoring index offers `Refresh status`; neither
      state renders active Search controls or a dead-end "please wait" message.

## Edge cases

- Empty submitted query is allowed only as an explicit customer action and can browse the
  index without an automatic request on mount.
- Malformed filters preserve the last valid result set and show Retry.
- Unsafe or missing configured image URLs render no image.
- Missing title falls back deterministically to name and then objectID.
- Facets with many values remain bounded and expose a deliberate expansion/search action.
- Many configured facet panels remain reachable through the desktop Refine pane's visible
  vertical scroll; the sticky pane never extends past the viewport without an access path.
- Toggling preview activity affects subsequent searches; it does not rewrite prior events.
- Multi-request payloads above the documented cap are rejected; accepted batches preserve
  order with bounded fan-out.

## Mobile Narrow

- At 390px the query and result toolbar wrap without horizontal page overflow.
- `Refine (N)` is visible, the inline sidebar is hidden, and the drawer contains configured
  facets and active-filter clear actions.
- The Refine drawer stays within the viewport and has automated focus-return coverage.

## Visual contract

- Refine sidebar width is 240-280px and sticky below the query toolbar.
- Refine sidebar height is bounded to the viewport with vertical overflow scrolling.
- Enabled buttons and button roles use a pointer cursor and visible hover/focus states;
  disabled or aria-disabled controls do not.
- Active refinements, progress, analytics state, and event-delivery feedback are visible
  near their owning controls.
- Results remain in place behind overlays and during replacement queries.

## Current Implementation Gaps

None verified. The acceptance criteria above map to the automated owners below.

## Automated Coverage

- Component: `web/src/lib/flapjack-search-client.test.ts`,
  `web/src/lib/components/InstantSearch.test.ts`, `DocumentCard.test.ts`, and focused tests
  under `web/src/lib/components/search/`.
- Web contract: `web/src/routes/api/search/[name]/search.server.test.ts`, API client tests,
  Search tab tests, and index-detail tab tests.
- Rust contract: `infra/api/tests/integration/indexes_test.rs` structured search, tenant
  isolation, and preview-event tests.
- Browser-unmocked real engine: `web/tests/e2e-ui/full/unified-search.spec.ts` with setup
  shortcuts confined to fixtures and visible interactions/assertions in the spec, plus
  `web/tests/e2e-ui/full/demo_loader_end_to_end.spec.ts` for the real Movies create,
  settings, exact facet-count, known-object refinement, and highlight journey.
- Static mapping: `bash scripts/tests/screen_specs_coverage_test.sh`.
