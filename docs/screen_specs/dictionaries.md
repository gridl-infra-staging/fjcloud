# Dictionaries Tab Screen Spec

## Task

Browse, add, edit, and delete `stopwords`, `plurals`, and `compounds` dictionary entries for a single index, one dictionary type at a time.

## Layout

1. Tab header: title `Dictionaries` with a total-count badge for the active dictionary type (e.g. `12`).
2. Dictionary-type tabs (single row, three triggers): `Stopwords`, `Plurals`, `Compounds`. Clicking auto-fetches that dictionary type; no intermediate Browse submit.
3. Active-dictionary sub-heading with `{count} entries` badge.
4. Language selector (left) and search/filter input (right) scoped to the active dictionary.
5. Primary action row (right-aligned): `Add Entry` (opens `[EditorDialog]`).
6. Entries list — one card per entry, top-to-bottom:
   - Human-readable description (e.g. `the` for stopwords; `shoe, shoes` for plurals; `notebook -> note + book` for compounds).
   - Metadata badges: `language`, `state` (stopwords only), and `{count} total`.
   - Per-row `Edit` button (opens `[EditorDialog]` prefilled) and `Delete` button (opens `[ConfirmDialog]`).
7. Footer action row (left-aligned, destructive): `Clear All` (opens `[ConfirmDialog]`, only visible when entries.length > 0).

## State contract

### Loading
- Three skeleton row placeholders inside the entries list region. Tabs remain visible and clickable. No `Add Entry`, `Edit`, `Delete`, or `Clear All` buttons rendered.

### Error
- Inline error banner above the entries list with the server message and a `Retry` button. Tabs remain clickable. `Add Entry` is hidden until retry succeeds.

### Empty (per dictionary type)
- Dictionary-specific copy: `No stopword entries yet.` / `No plural entries yet.` / `No compound entries yet.`
- `Add Entry` visible. `Clear All` not rendered.

### Populated
- Entries list rendered per Layout #6. `Add Entry`, per-row `Edit`, per-row `Delete`, and `Clear All` all visible.

### Add-dialog-open
- `[EditorDialog]` titled `Add {Stopwords|Plurals|Compounds} Entry`. Fields per dictionary type: stopwords = `Word` + `Language` + `State (enabled|disabled)`; plurals = `Words` (comma-separated, minimum 1) + `Language`; compounds = `Word` + `Decomposition` (comma-separated, minimum 1) + `Language`. `Language` is a select with 8 options (`en, fr, de, es, it, pt, nl, sv`). Footer: `Cancel` + primary `Add Entry`. `objectID` is NOT a visible field — minted server-side.
- Underlying page controls remain visible but non-interactive (modal scrim).

### Edit-dialog-open
- Same `[EditorDialog]` shape as Add but titled `Edit Entry` and prefilled from the row. `objectID` preserved, not editable. Footer: `Cancel` + primary `Save`.

### Delete-confirm-open
- `[ConfirmDialog]` titled `Delete entry?`, body names the entry description (e.g. `Delete "shoe, shoes"?`). Buttons: `Cancel` + destructive `Delete`.

### Clear-all-confirm-open
- `[ConfirmDialog]` titled `Clear all {Stopwords|Plurals|Compounds}?` with body `This will permanently remove {count} entries for {language}.` Requires the user to type the active dictionary name to enable the destructive `Clear All` button. Buttons: `Cancel` + destructive `Clear All`.

### Saving-in-flight
- Triggered from Add/Edit/Delete/Clear-all confirm. The triggering dialog's primary button shows a spinner and is disabled. `Cancel` remains enabled. Underlying page is non-interactive.

### Save-error
- The triggering dialog stays open. An inline error banner appears above its footer with the server message. Primary button re-enabled. `Cancel` enabled.

## Navigation

- Route: `/console/indexes/[name]` with `tab=dictionaries` query param. Active dictionary-type and language reflected as `dict={stopwords|plurals|compounds}` and `lang={code}` query params so deep links round-trip.
- Entry: clicking `Dictionaries` in the tab strip on `Index Detail`.
- Back: browser back returns to the previously active tab on `Index Detail`. Closing a dialog (`Cancel`, ESC, or scrim click) returns to the underlying tab state with no save.
- Add / Edit / Delete / Clear All success: dialog closes; entries list refreshes in place; success toast shown.

## Acceptance Criteria

- Given an index with seeded stopword, plural, and compound entries, when the user opens the `Dictionaries` tab, then the `Stopwords` tab is active by default and its entries render as human-readable strings (e.g. `the`) with `language` and `state` badges — not as a raw JSON block.
- Given the `Stopwords` tab is active, when the user clicks the `Plurals` tab, then plural entries auto-fetch and render as `word1, word2` strings without requiring any `Browse` submit.
- Given the `Plurals` tab, when entries exist, the count badge next to the `Dictionaries` heading reflects `nbHits` for plurals and updates after add/delete.
- Given the user clicks `Add Entry` on the `Stopwords` tab, when the dialog opens, then `Word`, `Language`, and `State` fields are visible; `objectID` is not visible.
- Given the Add dialog is open for stopwords, when the user enters `the`, selects `en`, leaves `State` as `enabled`, and clicks `Add Entry`, then the new entry appears in the list with badges `en` and `enabled`, and the server-stored entry round-trips the `state: 'enabled'` field on subsequent fetches.
- Given the Add dialog is open for plurals, when the user enters a single word `shoe` (1 word) and clicks `Add Entry`, then the entry is accepted (≥1 word, matching upstream rule).
- Given the user clicks the per-row `Delete` button, when the `[ConfirmDialog]` opens and the user clicks `Delete`, then the entry is removed from the list and the count badge decrements; clicking `Cancel` instead leaves the list unchanged.
- Given the user clicks `Clear All` with 5 entries present, when the `[ConfirmDialog]` opens, then the destructive button is disabled until the user types the active dictionary name; clicking `Clear All` empties the list and shows the per-type empty-state copy.
- Given the entries fetch fails, when the tab renders, then an inline error banner with a `Retry` button is visible and `Add Entry` is hidden until retry succeeds.
- Given the user clicks `Edit` on a stopword entry, when the dialog opens, then the `Word`, `Language`, and `State` fields are prefilled from the row and saving preserves the original `objectID`.

## Edge cases

- Index has zero entries across all three dictionary types: the active tab shows its per-type empty-state copy; all three tabs remain clickable (no "no dictionaries" page-level empty state).
- A dictionary type has never been fetched yet: show Loading skeletons on first tab activation, not the empty state, so users don't mistake in-flight for empty.
- Mid-add network failure (transient 5xx): the Add dialog stays open with the inline Save-error banner; the typed fields are preserved.
- Server rejects entry shape (e.g. malformed compound decomposition): Save-error banner shows the server message verbatim; the dialog does not close.
- Very large entry list (>50): list paginates; pagination controls render below the list; tab switch resets to page 1.
- Language has entries in one dictionary type but not others: switching to a type with zero entries for that language shows the per-type empty state, not the list from a different language.
- Concurrent edit conflict: if the server returns a 409 on save, show the conflict in the Save-error banner and surface a `Refresh` action that reloads the entry and re-opens the dialog with the latest values.

## Current Implementation Gaps

These deltas are documented per the 2026-05-25 parity audit ([tab_dictionaries.md](../audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/tab_dictionaries.md)).

- Current: dictionary type is selected via a `<select id="dictionary-type">` dropdown inside a `Browse Entries` form that the user must submit before entries appear.
  Target: top-level tab triggers (`Stopwords` / `Plurals` / `Compounds`) that auto-fetch on click.
  Evidence: `web/src/routes/console/indexes/[name]/tabs/DictionariesTab.svelte:134-145` (the `<select>`); upstream `engine/dashboard/src/pages/Dictionaries.tsx:47-62` (`TabsList` with `data-testid="dictionary-tab-{name}"`).
- Current: entries render as `<pre>{JSON.stringify(entry, null, 2)}</pre>` blocks.
  Target: human-readable cards rendered via `buildEntryDescription` (`the` / `shoe, shoes` / `notebook -> note + book`) with `language`, `state`, and `{count} total` badges.
  Evidence: `web/src/routes/console/indexes/[name]/tabs/DictionariesTab.svelte:305-311`; upstream `engine/dashboard/src/pages/dictionaries/DictionaryEntriesPanel.tsx:47-83` + `shared.ts:94-112`.
- Current: stopword `state: enabled|disabled` field is silently dropped on save — the form has no `state` input and `parseDictionaryEntryFromForm` accepts only `word`+`language`+`objectID`.
  Target: stopword Add/Edit dialog includes a `State` select (`enabled` / `disabled`); the server parser accepts and round-trips it.
  Evidence: `web/src/routes/console/indexes/[name]/dictionary-helpers.server.ts:70-77` (no `state` parse); upstream `engine/dashboard/src/pages/dictionaries/DictionaryEntryDialog.tsx:49-82` (StopwordFormFields with `State` select).
- Current: plurals server-side parser rejects `<2` words.
  Target: accept `≥1` word (matches upstream `buildDialogEntry` plurals rule).
  Evidence: `web/src/routes/console/indexes/[name]/dictionary-helpers.server.ts:85-87`; upstream `engine/dashboard/src/pages/dictionaries/shared.ts:137-148`.
- Current: the user must hand-type an `objectID` for every Add (server rejects empty).
  Target: `objectID` is auto-minted server-side via `crypto.randomUUID()` and never shown in the dialog.
  Evidence: `web/src/routes/console/indexes/[name]/tabs/DictionariesTab.svelte:197-213` + `dictionary-helpers.server.ts:60-65`; upstream `engine/dashboard/src/pages/dictionaries/shared.ts:67-92` (`buildObjectId`).
- Current: Delete and Clear All have no confirmation step.
  Target: both gated behind `[ConfirmDialog]` per the cross-cutting Theme B fix.
  Evidence: `web/src/routes/console/indexes/[name]/tabs/DictionariesTab.svelte:292-303`; audit SUMMARY.md § Theme B.
- Current: no loading skeleton, no count badges, generic `No dictionary entries found` empty state.
  Target: three skeleton rows during fetch; total-count badge in the heading and `{count} entries` badge above the list; per-type empty-state copy from `DICTIONARY_EMPTY_STATES`.
  Evidence: `DictionariesTab.svelte:314-316`; upstream `DictionaryEntriesPanel.tsx:31-39` + `shared.ts:11-15`.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/dictionaries.spec.ts` (new) — type-tab auto-fetch, stopword state round-trip, plurals single-word acceptance, row delete confirm, and typed `Clear All`.
- Browser-mocked tests: `web/tests/e2e-ui/mocked/dictionaries_errors.spec.ts` (new) — fetch failure Retry branch, malformed-entry save rejection, and 409 edit-conflict handling.
- Component tests: `web/src/routes/console/indexes/[name]/tabs/DictionariesTab.test.ts` (new) — `buildEntryDescription` rendering, per-type dialog schema swaps, and badge/empty-state branches.
- Server/contract tests: extend `web/src/routes/console/indexes/[name]/detail.server.actions.test.ts` and dictionary helper tests for `state` parsing, server-side `objectID` minting, plurals `>=1` acceptance, and query-param load routing.
