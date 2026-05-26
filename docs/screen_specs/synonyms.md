# Synonyms Tab

## Task

Browse, search, create, edit, and delete the synonym groups that influence relevance for one index.

## Layout

1. Tab header row (left): heading `Synonyms` + inline count badge (`data-testid="synonym-count"`) showing `nbHits`.
2. Tab header row (right): `Clear All` button (outline, destructive-tinted; visible only when `nbHits > 0`) and primary `Add Synonym` button (`data-testid="add-synonym-btn"`) that opens `EditorDialog` in create mode.
3. Filter row: single-line search input (`data-testid="synonyms-search"`, `placeholder="Search synonyms..."`) with leading search icon; debounced submission re-queries the server with `?q=`.
4. Synonym list (`data-testid="synonyms-list"`) — one card per `hits[]` row, each showing:
   1. Human-readable type pill (`data-testid="synonym-type-badge"`) — `Multi-way` / `One-way` / `Alt. Correction 1` / `Alt. Correction 2` / `Placeholder` per the type-label map (never the raw enum).
   2. Synonym summary string from `synonymSummary()` (e.g. `hoodie = sweatshirt = pullover`, `phone → mobile, cell`).
   3. `Edit` button (ghost) — opens `EditorDialog` in edit mode prefilled with this row.
   4. `Delete` button (ghost, destructive-tinted, `aria-label="Delete synonym <objectID>"`) — opens `ConfirmDialog` in standard mode.

## State contract

### Loading
- Three skeleton cards in the list area; header (badge, search, buttons) hidden until data resolves to avoid mid-paint flicker.

### Error
- Server load failed: list area replaced by `Synonyms could not be loaded. Try refreshing the page.` inside a `role="alert"` region. `Add Synonym` button remains enabled (create flow does not depend on the list load).

### Empty
- `No synonyms yet` headline + one-line explanation (`Synonyms help users find results even when they use different words.`) + two inline shortcut buttons (`Add Multi-way`, `Add One-way`) that open `EditorDialog` with that type preselected. `Clear All` hidden. Search input remains visible so the empty state is reachable from a filter-with-no-matches state too.

### Filter-active
- Same layout as Populated but list is filtered server-side. When the search returns zero hits, list area shows `No synonyms match "<query>"` with a `Clear search` link that empties the input. Count badge reflects filtered `nbHits`.

### Populated
- Header row visible (count, search, `Clear All`, `Add Synonym`); rows rendered per Layout #4. Default sort is server-returned order.

### Add-dialog (EditorDialog, create mode)
- `EditorDialog` open with title `Create Synonym`. First field is a type selector (5 buttons: Multi-way / One-way / Alt. Correction 1 / Alt. Correction 2 / Placeholder) — selecting a type swaps the schema below to that type's fields. Object ID input is editable. Per-type form variations:
  - **Multi-way sub-state**: dynamic `array` of text inputs labelled `Words (bidirectional)`, `minItems=2`, `addLabel="Add Word"`, X-remove enabled when length > 2.
  - **One-way sub-state**: single `Input (source word)` text field, visual `→` divider, dynamic `array` labelled `Synonyms`, `minItems=1`, `addLabel="Add Synonym"`.
  - **Alt. Correction 1/2 sub-state**: single `Word` text field, dynamic `array` labelled `Corrections`, `minItems=1`, `addLabel="Add Correction"`.
  - **Placeholder sub-state**: single `Placeholder token` text field, dynamic `array` labelled `Replacements`, `minItems=1`, `addLabel="Add Replacement"`.
- Save disabled until `objectID` is non-empty AND the active sub-state's validators pass (all list items non-blank, min-items satisfied).

### Edit-dialog (EditorDialog, edit mode)
- Same per-type sub-states as Add, prefilled from the row. Type selector hidden (changing type on an existing synonym is server-side a delete+create — out of scope; user must Delete then Add). Object ID disabled. Save label reads `Save`.

### Delete-confirm (ConfirmDialog, standard mode, warn)
- Title: `Delete synonym`. Body: `Are you sure you want to delete synonym <objectID>? This action cannot be undone.` Confirm label: `Delete`.

### Clear-all-confirm (ConfirmDialog, typed mode, severe)
- Title: `Delete all synonyms`. Body: `Delete ALL synonyms for this index? This cannot be undone.` Typed phrase: `CLEAR`. Confirm label: `Delete All`.

### Saving
- Active `EditorDialog` or `ConfirmDialog` is in its own Saving state per its component contract; the underlying list shows the prior data unchanged (no skeleton swap) so the user sees the optimistic outcome only after the action resolves.

### Save-error
- Toast or in-dialog `role="alert"` (per component contract) surfaces the server message verbatim. List state unchanged; the action did not mutate.

## Navigation

- Route: `/console/indexes/[name]?tab=synonyms` (tab state preserved in URL query so back-button returns to the same tab).
- Entry: `Index Detail` tab strip → `Synonyms`.
- Search: typing in the search input updates `?q=<query>` (debounced ~250ms) so back-button restores the filter; clearing the input removes the param.
- Add / Edit / Delete / Clear All: open their respective modal; on save/confirm success, the dialog closes, the list reloads server-side, and a transient confirmation banner (`Synonym saved` / `Synonym deleted` / `All synonyms cleared`) renders above the list for ~3s.
- Back / browser back: closes any open modal first (treated as Cancel per `EditorDialog` dirty-cancel-confirm contract); subsequent back exits the Synonyms tab to the previously active tab or to `Indexes`.

## Acceptance Criteria

- Given the Synonyms tab loaded with three seeded synonym groups, when the user views the header, then the count badge reads `3` and each row displays its type via the human-readable label map (never the raw `synonym` / `onewaysynonym` enum string).
- Given an empty index, when the user opens the Synonyms tab, then the empty state renders with `Add Multi-way` and `Add One-way` shortcuts and `Clear All` is not shown.
- Given the Populated state, when the user clicks `Add Synonym` and selects `One-way` in the dialog, then the form renders an `Input (source word)` field, an arrow divider, and a `Synonyms` dynamic-array field with one row + `Add Synonym` button — no JSON textarea is visible anywhere in the dialog.
- Given the Add dialog in One-way sub-state, when the user enters an Object ID and one source word but leaves all synonym rows blank, then Save remains disabled and the first invalid field shows a `role="alert"` error.
- Given a valid filled Add dialog, when the user clicks Save and the server returns 200, then the dialog closes, the new row appears in the list, the count badge increments, and a `Synonym saved` banner appears.
- Given a synonym row, when the user clicks `Delete`, then `ConfirmDialog` opens in standard mode showing the objectID and Delete does **not** fire until Confirm is clicked (regression test for current no-confirm behavior).
- Given the Populated state with `nbHits > 0`, when the user clicks `Clear All` and types `CLEAR` in the typed-confirm input, then on Confirm the list transitions to the Empty state and the count badge reads `0`.
- Given the user types `hoodie` in the search input, when the debounced query fires, then the URL updates to `?q=hoodie`, the list re-renders with only matching synonyms, and the count badge reflects the filtered `nbHits`.
- Given an Edit dialog open on a Multi-way synonym with 4 words, when the user clicks X on the third word, then the row is removed locally; when the count would drop below 2 (minItems), the remaining X buttons are disabled.
- Given any open dialog with unsaved changes, when the user presses Esc, then the `EditorDialog` dirty-cancel-confirm replaces the footer until the user picks Discard or Keep editing (no silent data loss).

## Edge cases

- Server returns `null` for `synonyms` (load error vs empty): Error state (not Empty) — these must be distinguishable per Theme C anti-pattern.
- Synonym summary contains very long content (50+ words): each row's summary truncates with ellipsis at one line; full content visible in the Edit dialog.
- ObjectID collision on create: server rejects with a per-field error mapped onto the Object ID field via the `EditorDialog` server-error contract.
- User searches while a modal is open: search input is part of the underlying tab, not the modal — keystrokes there are blocked until the modal closes (focus trap per `EditorDialog`).
- Mobile narrow (390px): header row wraps so `Add Synonym` and `Clear All` stack below the heading; row action buttons collapse into a single `…` menu (`Edit`, `Delete`).
- Type change requested on existing synonym: not supported — Edit dialog hides the type selector; user must Delete then Add (documented in the dialog's help text).
- Concurrent edit by another tab: out of scope here; relies on the same reload-on-close pattern as `EditorDialog`'s edge-case contract.

## Current Implementation Gaps

- Current: per-row Delete posts directly to `?/deleteSynonym` with no confirmation — one click destroys the synonym.
  Target: Delete opens `ConfirmDialog` (standard mode, warn) per the Delete-confirm sub-state.
  Evidence: `web/src/routes/console/indexes/[name]/tabs/SynonymsTab.svelte:149-158` (`<form method="POST" action="?/deleteSynonym" use:enhance>` direct submit); [audit tab_synonyms.md row 9](../audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/tab_synonyms.md).
- Current: no Clear All button; bulk delete requires iterating row-by-row.
  Target: `Clear All` in header row opens `ConfirmDialog` typed-severe (`CLEAR`) and invokes a new `?/clearSynonyms` server action.
  Evidence: no matches for `Clear All` / `clearSynonyms` in `SynonymsTab.svelte` or `+page.server.ts`; [audit row 10](../audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/tab_synonyms.md).
- Current: create/edit uses a flat, always-visible form with a free-text JSON textarea (`bind:value={newSynonymJson}`) that requires hand-editing Algolia JSON with brackets and commas.
  Target: `EditorDialog` (create/edit modes) with per-type structured sub-states and dynamic Add Word / X-remove rows; no JSON visible to the user.
  Evidence: `SynonymsTab.svelte:188-208` (textarea bound to `newSynonymJson`); [audit rows 4, 5, 7](../audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/tab_synonyms.md).
- Current: header reads literal text `Synonyms` with no count.
  Target: inline count badge showing `nbHits` (`data-testid="synonym-count"`).
  Evidence: no matches for `nbHits` or `synonym-count` in `SynonymsTab.svelte`; [audit row 3](../audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/tab_synonyms.md).
- Current: no inline search/filter; server load calls `api.searchSynonyms(name)` with no query.
  Target: debounced search input bound to `?q=`, server action passes through.
  Evidence: `+page.server.ts:135` calls `api.searchSynonyms(name)` with no args; [audit row 6](../audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/tab_synonyms.md).
- Current: type pill renders the raw enum (`synonym`, `onewaysynonym`, `altcorrection1`).
  Target: human-readable label via a `SYNONYM_TYPE_LABELS` constant (`Multi-way`, `One-way`, `Alt. Correction 1/2`, `Placeholder`).
  Evidence: `SynonymsTab.svelte:142-145` renders `{synonym.type}` raw; [audit row 2](../audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/tab_synonyms.md).

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/synonyms.spec.ts` (new) — count badge, server-side search query-param flow, add/edit per-type dialogs, row delete confirm, and typed `Clear All`.
- Browser-mocked tests: `web/tests/e2e-ui/mocked/synonyms_error_states.spec.ts` (new) — load-error vs empty distinction and create-time `objectID` collision handling.
- Component tests: extend `web/src/routes/console/indexes/[name]/tabs/SynonymsTab.test.ts` for type-label mapping, summary rendering, per-type form validation, and min-items remove-guard behavior.
- Server/contract tests: extend `web/src/routes/console/indexes/[name]/detail.server.actions.test.ts` or synonym action tests for `q=` passthrough, `clearSynonyms`, and structured create/edit parsing.
