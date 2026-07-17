# Suggestions Tab (Query Suggestions)

## Task

Configure and operate a query-suggestions index that learns from the source index's search history — through a structured (non-JSON) editor with rebuild-status visibility and build-log inspection.

## Layout

1. Tab header row: heading `Query Suggestions` + helper text `Build a query-suggestions index from this index's search history.`
2. **Setup state branches based on whether a config exists** (see State contract). Two top-level branches: `Not-configured` and `Configured`.

### When configured (default render):

3. Status card (`data-testid="qs-status-card"`) showing:
   - Current build state badge: `Idle` / `Building...` / `Failed` (with color tint).
   - `Last built:` relative-time tag (`data-testid="qs-last-built"`).
   - `Last successful build:` relative-time tag (`data-testid="qs-last-successful"`).
   - `Rebuild Now` button (`data-testid="qs-rebuild-btn"`) — disabled while a build is in-progress.
4. Configuration card (`data-testid="qs-config-card"`):
   - `Edit Configuration` button (`data-testid="qs-edit-btn"`) — opens `EditorDialog` with the structured form (see Edit-dialog sub-state).
   - Read-only summary lines: `Source indexes: <list>` / `Languages: <list>` / `Min hits: <N>` / `Allow special characters: <yes/no>` / `Personalization enabled: <yes/no>`.
   - `Delete Configuration` button (`data-testid="qs-delete-btn"`) — opens `ConfirmDialog` typed-severe.
5. **Build log card** (`data-testid="qs-build-log-card"`) — collapsed by default with `<N> log lines ▾`. Expanded: scrollable `<pre>` showing the most recent build's log output (line-numbered). Refresh button at top right.

### When not configured:

3. Create-config card (`data-testid="qs-create-card"`) — empty-state copy + primary `Configure Query Suggestions` button (`data-testid="qs-configure-btn"`) opening `EditorDialog` in create mode.

## State contract

### Loading
- All cards skeleton. Header visible.

### Error (config load failed)
- `role="alert"` line at top: `Could not load query-suggestions config. <Retry button>` — distinct from "no config exists." Other cards hidden.

### Not-configured
- Per Layout § "When not configured." Status card hidden. Build log card hidden.

### Configured · idle
- Status card shows `Idle` badge with build timestamps. Rebuild button enabled. All cards rendered.

### Configured · building
- Status card shows `Building...` badge with spinner. Rebuild button disabled with tooltip `Build in progress`. Build log auto-refreshes every 5s while building.

### Configured · build-failed
- Status card shows `Failed` badge in `flapjack-rose` color. Last-built timestamp shows the failed build time. Build log expanded by default. Rebuild button re-enabled.

### Create-dialog (EditorDialog, create mode)
- `EditorDialog` open with title `Configure Query Suggestions`. Field schema:
  - `indexName` — pre-populated, read-only display (the current index's name).
  - `sourceIndices` — array of text inputs labelled `Source index name`, `addLabel="Add Source Index"`, `minItems=1`. Defaults to `[currentIndexName]`.
  - `languages` — multiselect labelled `Languages` from the standard fjcloud language list. Defaults to `['en']`.
  - `exclude` — array of text inputs labelled `Exclude word`, `addLabel="Add Exclusion"`, `minItems=0`.
  - `minHits` — number input labelled `Minimum hits per source query`, default `2`, `min=1`.
  - `allowSpecialCharacters` — toggle labelled `Allow special characters in suggestions`, default `false`.
  - `enablePersonalization` — toggle labelled `Use personalization signals`, default `false`.
- Save persists via existing `?/saveQsConfig` action.

### Edit-dialog (EditorDialog, edit mode)
- Same schema, prefilled from current config. `indexName` disabled (can't change owner index). Save updates.

### Delete-confirm (ConfirmDialog, typed mode, severe)
- Title: `Delete Query Suggestions configuration`. Body: `Deleting will stop future builds. The existing suggestions index will remain until manually deleted from the indexes list. This cannot be undone.` Typed phrase: `DELETE`. Confirm label: `Delete Configuration`.

### Rebuild-running
- Rebuild button shows `Rebuilding...` + spinner. Status badge transitions to `Building...` (matches Configured · building).

### Rebuild-error (immediate, not a build failure)
- Inline `role="alert"` next to Rebuild button with the server's rejection message (e.g. `Rebuild already in progress`). Status card otherwise unchanged.

## Navigation

- Route: `/console/indexes/[name]?tab=suggestions`.
- Entry: tab strip on Index Detail.
- Create / Edit / Delete: open respective modal; on success, modal closes + cards refresh.
- Build log expansion: pure local state, no URL change.
- Rebuild: stays on route; status card transitions to building.

## Acceptance Criteria

- Given an index with no query-suggestions config, when the user opens the Suggestions tab, then the Create-config card is visible AND no status/build-log cards are rendered AND `Configure Query Suggestions` is the only primary action.
- Given a configured index in idle state, when the user clicks `Edit Configuration`, then `EditorDialog` opens prefilled with the current values AND the `indexName` field is disabled.
- Given the Edit dialog open in edit mode, when the user adds a source index `products-v2` and clicks Save, then the dialog closes AND the read-only summary line shows `Source indexes: <current>, products-v2`.
- Given a configured index, when the user clicks `Rebuild Now`, then the Rebuild button shows the `Rebuilding...` state AND the status badge transitions to `Building...` within 1s.
- Given the build is in-progress, when 5s elapses, then the Build log card auto-refreshes (verified by spec asserting the log content changes when seeded with growing log data) WITHOUT user action.
- Given the build completed with a failure, when the user opens the Suggestions tab, then the Status card shows the `Failed` badge AND the Build log card is expanded by default (so the user immediately sees the failure log).
- Given a configured index, when the user clicks `Delete Configuration` and types `DELETE` then Confirm, then the configuration is deleted AND the tab transitions back to the Not-configured branch.
- Given the user clicks `Delete Configuration` and types a wrong phrase, when the user clicks Confirm (which should be disabled), then no deletion occurs AND the dialog stays open with the typed-input error visible.

## Edge cases

- Source index name does not exist in the workspace: server rejects on save with a per-field error mapped onto the offending `sourceIndices` row.
- Languages list empty (user removes all): client-side validator blocks Save with `Select at least one language.`
- `minHits` < 1: native input validation blocks Save.
- Build log endpoint returns 404 (no builds yet): show `No builds yet. Click Rebuild Now to start the first build.` in the build-log card area.
- Build log very large (>1MB): client truncates display to last 1000 lines with a `Showing last 1000 lines.` note (full log downloadable via secondary action — defer for post-launch if usage emerges).
- Rebuild fails to start because another build is in progress (race): server rejects; surface the rejection inline.
- Concurrent edit by another tab: out of scope here; relies on the same reload-on-close pattern as `EditorDialog`.

## Current Implementation Gaps

- Current: create/edit uses a raw JSON `<textarea>` exposing the full config object.
  Target: `EditorDialog` with structured fields per the Create/Edit dialog sub-states.
  Evidence: `web/src/routes/console/indexes/[name]/tabs/SuggestionsTab.svelte:117-128` (textarea bound to `qsConfigText`); parent audit Recommendation 5.

- Current: Build status renders as a flat block of text (`Running: yes/no`, `Last built:`, `Last successful build:`) — no badge, no `Failed` distinction.
  Target: Status card with colored badge + relative-time tags + Rebuild button.
  Evidence: `SuggestionsTab.svelte:142-149`.

- Current: no Rebuild Now button. fjcloud's TS client has `getQsStatus`, `saveQsConfig`, `deleteQsConfig` but no rebuild trigger. The upstream flapjack engine HAS the endpoint (`POST /1/configs/<indexName>/build` per upstream `useTriggerQsBuild` hook).
  Target: lane consumer (3F) is CROSS-LAYER:
  1. **Rust addition in `infra/api/src/services/flapjack_proxy/`** — new `trigger_qs_build(node_id, region, index_name)` method (~20 lines) calling `POST {flapjack_url}/1/configs/{index_name}/build`. Mirrors the existing QS proxy methods.
  2. **Rust route addition** — new handler in the existing QS route module exposing the trigger to the frontend (~15 lines).
  3. **TS client addition in `web/src/lib/api/client.ts`** — new `triggerQsBuild(indexName)` method (~5 lines).
  4. **Server action + frontend wiring** — `?/rebuildQsConfig` action + button in SuggestionsTab.
  Evidence: `web/src/lib/api/client.ts:600-665` (no rebuild method); upstream `flapjack_dev/engine/dashboard/src/hooks/useQuerySuggestions.ts:110-115` (`useTriggerQsBuild` posts to `/1/configs/${indexName}/build`).

- Current: no build-log display.
  Target: Build log card per Layout #5; new flapjack-proxy method `getQsBuildLog(indexName)` reading the engine's build log.
  Evidence: `SuggestionsTab.svelte` (no matches for `log|stdout|stderr`); parent audit Recommendation 5 "build-log UX (expandable/collapsible output)".

- Current: deletion fires immediately on click (no confirm).
  Target: `ConfirmDialog` typed-severe per Delete-confirm sub-state.
  Evidence: `SuggestionsTab.svelte:131-135` (`formaction="?/deleteQsConfig"` direct submit).

- Current: setup-state branching is implicit (textarea always visible, even when no config).
  Target: explicit `Not-configured` vs `Configured` top-level branch.
  Evidence: `SuggestionsTab.svelte:79-100` (always renders textarea form).

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/suggestions.spec.ts` (new) — empty-state branch shows Configure card; create config via EditorDialog; edit existing; Rebuild Now transitions status; Delete with typed-confirm; build-log expand/collapse.
- Browser-mocked tests: `web/tests/e2e-ui/mocked/suggestions_build_failed.spec.ts` (new) — build-failed status renders red badge + log auto-expanded; `web/tests/e2e-ui/mocked/suggestions_rebuild_race.spec.ts` (new) — rebuild-while-building race surfaces role=alert.
- Component tests: `web/src/routes/console/indexes/[name]/tabs/SuggestionsTab.test.ts` (new) — branch logic (Not-configured vs Configured); status-badge color/text per build state; build-log expand state.
- Server/contract tests: extend `web/src/routes/console/indexes/[name]/detail.server.actions.test.ts` — new `?/rebuildQsConfig` action; `?/saveQsConfig` accepts structured form payload (not JSON string).
