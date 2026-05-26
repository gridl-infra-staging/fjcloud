# ConfirmDialog (shared component)

## Task

Gate a destructive action behind a modal that names the affected entity, describes consequences, and — for irreversible production-impact ops — requires the user to type the entity name (or a fixed phrase) before the Confirm button enables.

## Layout

1. Modal backdrop (dims page, click-outside dismisses unless `mode="typed"` and danger=`severe`).
2. Header row: warning icon (severity-tinted) + title text (`Stop running experiment`, `Delete index "<name>"`, etc.).
3. Body paragraph: human-readable consequences (e.g. `All historical analytics for "spring_promo" will be permanently removed.`).
4. Optional rationale block: caller-supplied additional context (rendered as muted text below consequences).
5. "This cannot be undone" line (severe mode only, bold).
6. Typed-confirmation input (typed mode only): label `Type "<phrase>" to confirm`, single-line text input, `data-testid="confirm-input"`.
7. Footer row, right-aligned: `Cancel` button (outline) then `Confirm` button (color and label caller-supplied; defaults to `Confirm` / red in severe mode).

## State contract

### Closed
- Nothing rendered. Trigger button on the parent screen has focus.

### Open-standard
- Modal visible. Confirm button enabled. Focus on Cancel by default (avoids accidental Enter-to-destroy).
- Controls: Cancel, Confirm.

### Open-typed-untouched
- Modal visible. Typed input rendered, empty. Confirm button **disabled** with `aria-disabled="true"`.
- Focus on the typed input.
- Controls: Cancel, typed input, Confirm (disabled).

### Open-typed-mismatch
- Same as untouched but input has content that does not equal the expected phrase (case-sensitive, trimmed).
- Confirm button still disabled. Input border tinted warn-color.
- Optional inline hint: `Must match exactly` (only after first blur to avoid yelling at active typists).

### Open-typed-match
- Input value equals expected phrase exactly. Confirm button enabled. Input border returns to neutral.
- Controls: Cancel, typed input, Confirm (enabled).

### Confirming-in-flight
- All controls disabled. Confirm button shows spinner + `Please wait…` label. Cancel disabled to prevent double-fire / race.
- Backdrop click and Esc are suppressed.

### Confirm-error
- Controls re-enabled. Inline error banner above footer with server-supplied message and `role="alert"`. Typed input retains its value.
- Confirm button re-enabled and re-clickable (user can retry without retyping).

## Navigation

- Not route-owned. Mounted by a parent screen's state contract (e.g. `Experiments tab → Stop pending`, `Indexes list → Delete pending`).
- Mount trigger: parent dispatches `open` with props.
- Dismiss paths:
  - `Cancel` button → `onCancel()` → parent closes dialog.
  - Esc key → equivalent to Cancel (suppressed during Confirming-in-flight).
  - Backdrop click → equivalent to Cancel in standard mode; **ignored in severe mode** to prevent accidental dismissal mid-decision.
- On successful confirm: parent closes dialog and navigates per its own contract (e.g. stays on Experiments tab; for index delete, navigates to `Indexes list`).
- **Return-focus pattern**: on close (success or cancel), focus returns to the trigger element the parent passed via `triggerRef`. If the trigger no longer exists (e.g. the deleted row), focus returns to the nearest stable container (`role="main"` or the parent tab heading).

### Props

- `mode`: `"standard" | "typed"` (required).
- `dangerLevel`: `"warn" | "severe"` (required; severe adds the "This cannot be undone" line, red Confirm button, suppresses backdrop dismiss, sets `role="alertdialog"`).
- `entityLabel`: short label for the entity type (e.g. `"experiment"`, `"synonym group"`).
- `entityName`: display name of the affected entity (rendered in title and consequences). For typed mode, this doubles as the expected phrase unless `typedPhrase` is supplied.
- `typedPhrase`: optional override for the required typed string (e.g. `"CLEAR"`, `"STOP"`).
- `title`: optional title override; default `"<Verb> <entityLabel>"`.
- `consequences`: required string or node describing what the action does.
- `rationale`: optional additional context node.
- `confirmLabel`: default `"Confirm"` or `"Delete"` / `"Stop"` per caller.
- `cancelLabel`: default `"Cancel"`.
- `onConfirm`: async handler. Component manages the Confirming-in-flight state from the returned promise.
- `onCancel`: handler called on any dismiss path.
- `triggerRef`: optional handle for return-focus.

### Keyboard

- **Esc**: cancels (suppressed in-flight).
- **Enter**: in standard mode, submits Confirm when Confirm is enabled and the focused element is not a text input. In typed mode, Enter submits only when the input value equals the expected phrase (Enter from inside the input is allowed; from any other focused control Enter does nothing).
- **Tab**: focus trap inside the dialog. Tab order in typed mode: typed-input → Cancel → Confirm → (wrap). In standard mode: Cancel → Confirm → (wrap).

### Accessibility

- `role="dialog"` for warn, `role="alertdialog"` for severe.
- `aria-labelledby` → title id; `aria-describedby` → consequences id (and rationale id when present).
- Typed input has visible `<label>` and `aria-describedby` pointing at any mismatch hint.
- Confirm-error banner uses `role="alert"` for screen-reader announcement.
- Focus trap and return-focus per Navigation section.

## Acceptance Criteria

Each call-site below is a discrete Playwright scenario in `web/tests/e2e-ui/full/<owner>.spec.ts`. All use `data-testid` selectors (`confirm-dialog`, `confirm-input`, `confirm-confirm-btn`, `confirm-cancel-btn`).

- Given an Experiments tab with a running experiment, when the user clicks `Stop` and the typed-mode dialog opens, then Confirm is disabled until the user types the experiment name exactly; after Confirm, the experiment row's status reads `Stopped`.
- Given an Experiments tab with a finished experiment, when the user clicks `Delete` and types the experiment name into the typed-mode dialog, then after Confirm the experiment row is removed and a toast `Experiment deleted` appears.
- Given a Synonyms tab with one synonym group, when the user clicks `Delete` on that row, then the standard-mode dialog opens showing the primary term; clicking Confirm removes the row.
- Given a Synonyms tab with N synonym groups, when the user clicks `Clear All` and types `CLEAR` into the typed-mode dialog, then after Confirm the list renders the empty state.
- Given a Rules tab with one rule, when the user clicks `Delete` on a row, then the standard-mode dialog opens; clicking Confirm removes the rule.
- Given a Rules tab with N rules, when the user clicks `Clear All rules` and types `CLEAR` into the typed-mode dialog, then after Confirm the list renders the empty state.
- Given a SecuritySources tab with one configured source, when the user clicks `Delete` on the row, then the standard-mode dialog opens; clicking Confirm removes the source.
- Given a Dictionaries tab with stopword entries, when the user clicks `Delete` on an entry, then the standard-mode dialog opens; clicking Confirm removes the entry.
- Given a Suggestions tab with a saved config, when the user clicks `Delete` on the config card, then the standard-mode dialog opens; clicking Confirm removes the config.
- Given the Indexes list with an index named `movies_demo`, when the user clicks `Delete` and types `movies_demo` into the typed-mode dialog, then after Confirm the row disappears and the URL stays on the indexes list. This call-site replaces the current `window.confirm` cited in `indexes.md`.
- Given any open dialog, when the user presses Esc, then the dialog closes and focus returns to the originating trigger button.
- Given any typed-mode dialog, when the user types a non-matching string, then the Confirm button remains disabled and pressing Enter does not submit.

## Edge cases

- **Mid-confirm network failure**: `onConfirm` promise rejects with a network error. Dialog transitions to Confirm-error, shows the error banner with `Try again`, leaves the typed input populated, re-enables Cancel and Confirm.
- **Server rejects the operation** (e.g. 409 because another user already deleted the entity): Confirm-error shows the server message verbatim; Confirm becomes a no-op until the user dismisses, at which point the parent reloads the list and reflects the upstream change.
- **Race with another tab confirming first**: parent screen's optimistic update may show the row already gone when the dialog closes; the dialog itself does not assume the entity still exists at confirm time. The parent's reload-on-close pattern handles reconciliation.
- **Typed input pre-filled by browser autofill**: ignored; the component does not auto-enable Confirm on mount even when input value happens to match (requires an `input` event from the user).
- **Trigger element unmounted before close**: return-focus falls back to nearest stable container (see Navigation).
- **Mobile narrow viewport (390px)**: dialog max-width is viewport-aware; typed input remains tappable; Cancel + Confirm stack vertically below 360px so labels are not truncated.
- **User clears the typed input after a match**: Confirm returns to disabled; pressing Enter does nothing.
- **Caller passes a multi-line `consequences` node**: rendered as paragraphs inside the body; `aria-describedby` covers the whole block.

## Current Implementation Gaps

This component does **not exist** in fjcloud today. Destructive actions across the console either use no confirmation or browser `window.confirm`.

- Current: `Experiments → Stop` and `Experiments → Delete` submit on first click with no confirmation. Target: typed-confirmation mode. Evidence: [CRITICAL_BUGS.md S2-1](../audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/CRITICAL_BUGS.md), [S2-2](../audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/CRITICAL_BUGS.md).
- Current: `Synonyms → Delete` submits on first click with no confirmation; no `Clear All` exists. Target: standard mode for Delete, typed mode for Clear All. Evidence: [CRITICAL_BUGS.md S2-3](../audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/CRITICAL_BUGS.md).
- Current: `Indexes list → Delete` uses native browser `window.confirm`. Target: typed-confirmation mode requiring the index name. Evidence: `docs/screen_specs/indexes.md` lines 31, 43.
- Current: `Rules`, `SecuritySources`, `Dictionaries`, `Suggestions` destructive actions either have no confirmation or use `window.confirm`. Target: per the Acceptance criteria. Evidence: [SUMMARY.md Theme B](../audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/SUMMARY.md).

## Automated Coverage

- Component tests (Vitest, jsdom): `web/src/lib/components/__tests__/ConfirmDialog.test.ts` covering each state in the contract, keyboard handling, focus trap, and typed-phrase mismatch.
- Browser-unmocked tests (Playwright): one spec per call-site under `web/tests/e2e-ui/full/` (`experiments.spec.ts`, `synonyms.spec.ts`, `rules.spec.ts`, `security-sources.spec.ts`, `dictionaries.spec.ts`, `suggestions.spec.ts`, `indexes.spec.ts`).
- No browser-mocked coverage needed unless a server-error state cannot be produced via real fixtures.
