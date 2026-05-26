# Merchandising Tab

## Task

Curate search results for a specific query by pinning desired items to chosen positions and hiding undesired items — all via direct manipulation (drag-and-drop or arrow buttons) on a live preview, then persist as a `Rule`.

## Layout

1. Tab header row: heading `Merchandising` + helper text `Configure how results appear for a specific search query.`
2. Query card (`data-testid="merch-query-card"`):
   - Search input (`data-testid="merch-query-input"`, placeholder `Enter a search query to merchandise`) — required to start.
   - `Load Results` button (`data-testid="merch-load-btn"`) — submits query, populates preview.
3. **Preview canvas** (`data-testid="merch-preview-canvas"`, shown only after Load Results) — vertical list of result rows in current order (pins applied, hides filtered out). Each row contains:
   - **Drag handle** (`data-testid="merch-drag-handle"`, leftmost; cursor `grab`; keyboard-accessible via `tabindex=0`).
   - Position number (`#1`, `#2`, ...).
   - ObjectID + summary text (truncated to one line, full visible on hover).
   - **Up-arrow button** (`data-testid="merch-move-up"`, `aria-label="Move <objectID> up"`) — disabled for top row.
   - **Down-arrow button** (`data-testid="merch-move-down"`, `aria-label="Move <objectID> down"`) — disabled for bottom row.
   - **Pin toggle** (`data-testid="merch-pin-toggle"`) — pinned rows have a visible badge `Pinned to #N` and a distinct background tint.
   - **Hide button** (`data-testid="merch-hide-btn"`) — moves the row to the Hidden tray below the canvas.
4. **Hidden tray** (`data-testid="merch-hidden-tray"`, shown when any row is hidden) — collapsed by default with `<N> hidden items ▾`. Expanded: list of hidden rows with `Restore` per row.
5. Description input (`data-testid="merch-description-input"`, optional) — `What does this rule do?` (placeholder).
6. Save row: `Save as Rule` button (`data-testid="merch-save-btn"`) — disabled if no merchandising operations performed yet. Saves via existing `?/saveRule` action.
7. **Recent merchandising rules** card (`data-testid="merch-recent-rules"`) — last 5 rules created via this tab, each with `Edit` (loads into canvas) and `Delete` (via `ConfirmDialog`).

## State contract

### Loading (initial)
- Header + Query card visible. Preview canvas hidden. Hidden tray hidden. Recent rules card shows skeleton.

### Query-untouched (no query submitted)
- Per Loading; Save button hidden (not just disabled).

### Loading-results (after Load Results clicked)
- Query card disabled. Preview canvas shows 5-row skeleton.

### Results-empty
- Preview canvas shows `No results for "<query>". Try a different query.` Save button hidden.

### Results-populated
- Preview canvas shows ≤30 rows in their current (modified-by-pins-and-hides) order.
- Drag handle interactive: clicking + dragging a row repositions it; on drop, the rule's `pins` array updates.
- Keyboard parity: focus a drag handle, press Space to "grab" (visual indicator), arrow keys to move, Space again to drop.
- Up/Down arrow buttons: clicking moves the row one position; pins array updates.

### Reorder-in-progress (drag active)
- Active row shows visual lift (shadow/tilt); other rows show drop indicators between them.

### Rule-saving
- Save button shows `Saving…` + disabled; preview canvas read-only.

### Rule-saved
- Toast `Merchandising rule saved` for ~3s; Recent rules card refreshes to include the new rule at the top.

### Save-error
- Inline `role="alert"` next to Save button with server message; preview canvas re-enables.

### Edit-existing-rule (Recent rules → Edit click)
- Canvas re-populates with the rule's pins/hides applied to a fresh search of the rule's query; description input prefills. Save now updates the existing rule.

### Delete-existing-rule (Recent rules → Delete click)
- `ConfirmDialog` standard mode warn: `Delete merchandising rule for "<query>"?` → on Confirm, rule removed, Recent rules card refreshes.

## Navigation

- Route: `/console/indexes/[name]?tab=merchandising`.
- Entry: tab strip on Index Detail.
- Edit rule from Recent: stays on same route; canvas state replaces.
- Save: stays on same route; banner + Recent rules update.
- Back: closes any open `ConfirmDialog` first; then exits to previous tab.

## Acceptance Criteria

- Given the user enters `laptop` in the query input and clicks Load Results, when the search returns 10 hits, then the Preview canvas renders 10 rows with drag handles AND each row has Up/Down/Pin/Hide buttons.
- Given the user clicks the Down arrow on row #1, when the click completes, then row #1's item moves to position #2 AND the position numbers re-renumber consistently.
- Given the user drags row #3 to position #1 (via mouse drag-and-drop), when the drop completes, then row #3's item is at the top AND the row's `Pinned to #1` badge appears.
- Given a keyboard-only user focuses a drag handle and presses Space, when the user presses ArrowDown then Space, then the row moves down one position (keyboard parity with mouse drag).
- Given the user clicks Hide on row #2, when the hide completes, then the row is removed from the preview canvas AND the Hidden tray shows `1 hidden item ▾`.
- Given the user has performed at least one pin or hide, when the user enters a description and clicks Save as Rule, then the rule persists via `?/saveRule` AND a transient `Merchandising rule saved` toast appears.
- Given the user clicks Edit on a Recent rule, when the canvas re-populates, then the previously-pinned rows show their `Pinned to #N` badges in the correct positions.
- Given the user clicks Delete on a Recent rule, when the `ConfirmDialog` opens, then deletion does NOT occur until the user clicks Confirm (regression test for current no-confirm behavior).

## Edge cases

- Query returns >30 hits: canvas shows the first 30; helper text `Showing first 30 results. Save the rule to apply to the full result set.`
- User drags a row off the canvas (out of bounds): drag cancels; row returns to original position.
- Pin to position #N where N > result count: clamp to last position.
- Editing a rule whose original query now returns different results (catalog changed): canvas shows current results with the rule's pins/hides applied where objectIDs still exist; missing objectIDs show in the Hidden tray with a `Source item no longer in index` note.
- Mobile narrow (390px): drag handles are larger touch targets; Up/Down arrow buttons remain as the primary reorder interaction (drag becomes secondary on touch).
- Recent rules card empty: shows `No merchandising rules yet. Create one above by loading a query and pinning items.`

## Current Implementation Gaps

- Current: pin/hide toggling exists but no drag-and-drop, no Up/Down arrow buttons, no drag handle.
  Target: full direct-manipulation surface per Layout — drag handle + drop-to-position + Up/Down arrows + keyboard parity.
  Evidence: `web/src/routes/console/indexes/[name]/tabs/MerchandisingTab.svelte` (no matches for `drag|draggable|move|arrow|reorder|tabindex` in interactive context); parent audit Recommendation 4.

- Current: pins use a single position number prompt (not direct manipulation).
  Target: position emerges from the row's current ordinal in the canvas — no prompt.
  Evidence: `MerchandisingTab.svelte:78` (`togglePin(objectID, position)` takes explicit position arg).

- Current: deletion of an existing merchandising rule has no confirm.
  Target: `ConfirmDialog` standard mode warn.
  Evidence: this lane covers it explicitly (no current Delete path on merchandising; rule deletion happens via Rules tab today).

- Current: no Recent merchandising rules surface within the Merchandising tab.
  Target: Recent rules card per Layout #7.
  Evidence: `MerchandisingTab.svelte` is 255 lines, all preview-canvas focused; no rule-list section.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/merchandising.spec.ts` (new) — load query → drag row to top → Pinned badge appears → save rule → rule appears in Recent; Up/Down arrow keyboard interaction parity; Hide → Hidden tray expand/restore.
- Browser-mocked tests: `web/tests/e2e-ui/mocked/merchandising_save_error.spec.ts` (new) — save 500 surfaces role=alert without losing canvas state.
- Component tests: extend `web/src/routes/console/indexes/[name]/tabs/MerchandisingTab.test.ts` — pin/hide state machine; reorder math (drop-to-position translates to correct pins array).
- Server/contract tests: `?/saveRule` action accepts the new rule shape (pins + hides + description).
