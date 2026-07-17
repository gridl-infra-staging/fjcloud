# Recommendations Tab Screen Spec

## Task

Configure a recommendation model and preview the resulting hits against the current index, with model-driven structured form fields and human-readable result rendering.

## Layout

1. Tab header: title `Recommendations`, subtitle showing the current index name in a stable testid (`recommendations-index-name`).
2. Configuration card (top): model picker dropdown + `Run` button row. The dropdown is the first and always-visible control; the `Run` button is right-aligned and labelled `Get Recommendations` (`get-recommendations-btn`). A secondary `Edit Configuration` button opens `[EditorDialog]` for full structured field editing (objectID, facetName, facetValue, threshold, maxRecommendations).
3. Inline structured form body (rendered within the card under the model picker): conditional fields driven by the selected model's `RECOMMENDATION_MODEL_METADATA` entry — `objectID` input for `related-products` / `bought-together` / `looking-similar`; `facetName` (required) + `facetValue` (optional) inputs for `trending-facets`; no extra inputs for `trending-items`. Each field rendered with its label, `data-testid` (`recommendations-object-input`, `recommendations-facet-input`, `recommendations-facet-value-input`), and the HTML `required` attribute where applicable.
4. Results section (below the configuration card, `recommendations-results`): error region first (when present), then either empty-state copy or one card per request result.
5. Per-result card: heading `processingTimeMS: {n}`; body is a list of hit rows, one row per hit, each rendered via the per-model `hitLabel` helper described in the State contract.

## State contract

### Loading
- Configuration card visible with model picker disabled and `Get Recommendations` showing the pending label (`Loading…`) and disabled. Results section shows a single skeleton row in the results card. No empty-state or prior-results copy rendered during this state.

### Error
- Results section shows a `role="alert"` error region above any prior results, containing the server message verbatim. Configuration card re-enables for retry. Prior results, if any, remain rendered below the alert so the user can compare; if no prior results, only the alert + the per-state empty copy are shown.

### Model-picker-empty
- Defensive guard: if `RECOMMENDATION_MODEL_METADATA` is somehow empty at runtime, the picker renders a disabled single option `No models available` and `Get Recommendations` stays disabled. Used as the spec's null-safety floor; not expected in normal operation.

### Config-untouched (default on first mount)
- Model picker preselects `related-products` (matches upstream `RECOMMENDATION_MODEL_METADATA[0]`). `objectID` input is rendered (since the default model requires it) but empty. `Get Recommendations` is disabled because `required` fields are blank. Results section shows the placeholder copy `Submit a preview request to view recommendations.` No error.

### Config-valid
- All `required` fields for the selected model are filled (trimmed). `Get Recommendations` is enabled. Trimming is applied client-side before submit (matches upstream behavior).

### Config-invalid
- At least one `required` field for the selected model is empty or whitespace-only. `Get Recommendations` is disabled. The field's native browser validation tooltip surfaces on submit attempt; no inline `role="alert"` per-field needed since the picker + structured form makes invalidity obvious.

### Fetching
- `Get Recommendations` shows the pending label and is disabled; model picker and structured-form fields are disabled. Any prior results remain visible (do not blank out) until the response settles. A stale-result guard (request-generation token) ensures responses from an earlier in-flight submission do not overwrite a later submission.

### Results-populated
- Results section shows one card per request result. Each hit row renders via the per-model helper:
  - `trending-facets` hits: `{facetName}: {facetValue}` (e.g. `brand: Apple`) — never raw JSON.
  - All other models: the `objectID` string when available; otherwise (legacy/unexpected hit shape) the document JSON is shown in a `<pre>` code block as a last-resort fallback, not silently dropped.
- `Get Recommendations` re-enables. Model picker re-enables.

### Results-empty
- Server returned ≥1 result(s) with zero hits aggregated across all results (`hasAnyHits === false`). Results section shows a single aggregate empty message: `No recommendations found.` — not a per-result "No hits returned." per card.

### Save-config-confirm (when `[EditorDialog]` is open)
- `[EditorDialog]` titled `Edit Recommendation Configuration` opens with the current form values prefilled. Model picker is the first field in the schema; selecting a model in the dialog updates the visible field set (objectID vs facetName/facetValue) live within the dialog. Footer: `Cancel` + primary `Save`. Save persists the structured config back to the inline card, replacing prior values; Cancel discards (with the dialog's standard dirty-cancel confirm if the user edited anything). Save does not auto-submit — the user still clicks `Get Recommendations` to fetch.

## Navigation

- Route: `/console/indexes/[name]` with `tab=recommendations` query param.
- Entry: clicking `Recommendations` in the tab strip on `Index Detail`.
- Back: browser back returns to the previously active tab on `Index Detail`. Closing `[EditorDialog]` returns to the underlying tab state with no config save unless the user clicked `Save`.
- Run: stays on the same route; results replace the placeholder/prior-results body in place.
- Index change (route param `name` changes): clears `objectID`, `facetName`, `facetValue` inputs back to empty, resets selected model to `related-products`, clears prior results and error, and invalidates any in-flight request-generation token so a stale response from the previous index never overwrites the new index's state.

## Acceptance Criteria

- Given the user opens the Recommendations tab on an index, when the page renders, then the model picker is visible with `data-testid="recommendations-model-select"`, populated with all five options (`Related Products`, `Bought Together`, `Trending Items`, `Trending Facets`, `Looking Similar`), and `Related Products` is selected by default.
- Given the default state, when the user inspects the form, then a required `objectID` input is visible (matching `RECOMMENDATION_MODEL_METADATA[0].requiresObjectID === true`) and `Get Recommendations` is disabled because `objectID` is empty.
- Given the model picker, when the user selects `Trending Facets`, then the `objectID` input is removed from the DOM and a required `facetName` input plus an optional `facetValue` input are rendered, each with their respective testids.
- Given the model picker, when the user selects `Trending Items`, then no required model-specific inputs are visible and `Get Recommendations` is enabled immediately.
- Given a populated `objectID` and the `Related Products` model, when the user clicks `Get Recommendations` and the server returns hits, then each hit row renders the hit's `objectID` as plain text (not raw JSON).
- Given the `Trending Facets` model with `facetName=brand`, when the server returns hits with `{facetName: "brand", facetValue: "Apple"}`, then the row renders the text `brand: Apple` — verified as `getByText('brand: Apple')` and NOT as `JSON.stringify(...)`.
- Given prior results are visible on screen, when the user changes the model picker, then the prior results clear, any prior error clears, and the structured form fields for the previously-selected model are removed; only the new model's fields and the empty-state placeholder remain.
- Given a submit fails with a server error, when the rejection settles, then the error message renders inside a region with `role="alert"` (asserted via Playwright `getByRole('alert')`) inside `recommendations-results`.
- Given the user clicks `Edit Configuration`, when `[EditorDialog]` opens and the user changes the model, fills `objectID`, and clicks `Save`, then the dialog closes, the inline card reflects the saved values, and `Get Recommendations` is enabled but not auto-fired.
- Given the user submits a request and immediately changes the model before the response arrives, when the (now-stale) response resolves, then the results section reflects the new model's empty state — the stale response is discarded by the request-generation guard.
- Given the server returns one or more results with zero aggregate hits, when the response renders, then a single `No recommendations found.` message is shown — not a per-result "No hits returned." card.

## Edge cases

- Model not supported by backend (e.g. user-deep-link with `?model=foo`): default back to `related-products`; do not crash; surface no error (deep-link models are not part of the URL contract).
- Hit list larger than 30 (server returned more than `DEFAULT_RECOMMENDATION_MAX_RECOMMENDATIONS`): render the first 30 in a scrollable list within the card; no pagination controls yet (defer until users actually request more).
- Stale-result race during rapid index switching: the request-generation token both clears prior results on `name` route-param change AND ignores any in-flight response whose generation does not match the latest. Verified by the spec for index-switch behavior.
- Very long results list (e.g. >100 hits across multiple results): cards scroll within the results region; the configuration card stays sticky at the top of the tab so the user can re-submit without scrolling back up.
- `trending-facets` returns a hit without `facetName` or `facetValue` (server contract violation): render the JSON in a `<pre>` fallback rather than silently dropping; do not throw.
- Whitespace-only `objectID` / `facetName`: client-side `trim()` collapses to empty, which keeps `Get Recommendations` disabled and matches upstream's trim-before-submit behavior.
- First mount on an index where the backend has never been provisioned for recommendations: server error renders in `role="alert"`; configuration card stays enabled so the user can retry once provisioning catches up.

## Current Implementation Gaps

These deltas are documented per the 2026-05-25 parity audit ([tab_recommendations.md](../audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/tab_recommendations.md)).

- Current: configuration is a raw JSON `<textarea>` that the user hand-edits, with the entire `{requests: [{...}]}` envelope exposed and the model string buried inside.
  Target: model picker dropdown + conditional structured inputs driven by `RECOMMENDATION_MODEL_METADATA`, with `[EditorDialog]` for full editing.
  Evidence: `web/src/routes/console/indexes/[name]/tabs/RecommendationsTab.svelte:73-84` (the `<textarea>`); audit row #1, #3, #5, #6.
- Current: only `trending-items` is discoverable — it's the only `model` string seeded into the default JSON, so users must know to type `"model": "bought-together"` to access the other four.
  Target: all five models surfaced as picker options on first render.
  Evidence: `web/src/routes/console/indexes/[name]/tabs/RecommendationsTab.svelte:20` (`model: 'trending-items'` hardcoded); audit row #3.
- Current: default model is `trending-items` on first mount.
  Target: default is `related-products` (matches upstream `RECOMMENDATION_MODEL_METADATA[0]`).
  Evidence: `web/src/routes/console/indexes/[name]/tabs/RecommendationsTab.svelte:20`; audit row #4.
- Current: `trending-facets` hits render as `JSON.stringify(hit)` because `hitLabel` only special-cases `objectID` and falls through to JSON for `{facetName, facetValue}` shape.
  Target: detect the trending-facet hit shape and render `{facetName}: {facetValue}`.
  Evidence: `web/src/routes/console/indexes/[name]/tabs/RecommendationsTab.svelte:44-49` (`hitLabel`); audit row #14 (S1-4 bug).
- Current: submit error renders in a styled `<div>` without `role="alert"`, so screen-reader announcement and Playwright `getByRole('alert')` parity are lost.
  Target: error region wrapped in `role="alert"` inside `recommendations-results`.
  Evidence: `web/src/routes/console/indexes/[name]/tabs/RecommendationsTab.svelte:62-66`; audit row #16.
- Current: changing the JSON's `model` value does not clear prior results; switching index does clear `requestText` but not `formResult`, allowing a stale response to display under a new index.
  Target: model-change clears prior results + error; index-change clears all of `model`/`objectID`/`facetName`/`facetValue`/results/error AND invalidates the in-flight request-generation token.
  Evidence: `web/src/routes/console/indexes/[name]/tabs/RecommendationsTab.svelte:32-42`; audit rows #9, #17.
- Current: empty state shows per-result `No hits returned.` cards rather than an aggregate `No recommendations found.` when every result has zero hits.
  Target: aggregate empty message when `hasAnyHits(results) === false`.
  Evidence: `web/src/routes/console/indexes/[name]/tabs/RecommendationsTab.svelte:91-103`; audit row #12.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/recommendations.spec.ts` (port from upstream `flapjack_dev/engine/dashboard/tests/e2e-ui/full/recommendations.spec.ts`) — model-picker discoverability, default-model selection, structured form per model, trending-facets human-readable rendering, model-change clears prior results, error role=alert, aggregate empty message.
- Browser-mocked tests: `web/tests/e2e-ui/mocked/recommendations.spec.ts` (new) — stale-result race (slow request from index A overlapped by index B switch), server-error rendering paths that are hard to produce deterministically against the real backend.
- Component tests: `web/src/routes/console/indexes/[name]/tabs/RecommendationsTab.test.ts` (new) — picker → conditional-field rendering matrix for all five models, `hitLabel` per-model output (especially `isTrendingFacetHit`), `hasAnyHits` empty aggregation.
- Server/contract tests: extend `web/src/routes/console/indexes/[name]/detail.server.actions.test.ts` to cover the new structured-form action shape (`model`, `objectID`, `facetName`, `facetValue`) replacing the opaque JSON action.
