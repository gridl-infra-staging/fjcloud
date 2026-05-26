# Security Sources Tab

## Task

Manage the CIDR/IP allowlist that gates secured API-key requests for one index.

## Layout

1. Tab section root (`data-testid="security-sources-section"`, carries `data-index` with the index name).
2. Header row: title `Security Sources`, secondary-styled entry-count badge to the right of the title (`data-testid="security-sources-entry-count"`), and a primary `Add Source` trigger button on the far right (`data-testid="add-security-source-btn"`).
3. Short description line under the header explaining that sources are IP-based allowlist entries (CIDR or single IP).
4. Inline success banner area: render `Security source added.` after a successful append, `Security source deleted.` after a successful delete. Each banner has `role="status"`.
5. Inline server-error banner area: render any `securitySourceAppendError` / `securitySourceDeleteError` from the most recent form action, with `role="alert"`.
6. Body card titled `Source Allowlist` whose contents vary by state (Loading / Load-error / Empty / Populated; see State contract).
7. When populated: one row per source entry inside the body card (`data-testid="security-source-row"`), each row showing the source value in monospace, the description (or `No description` if blank), and a Delete button (`data-testid="delete-security-source-btn"`, `aria-label="Delete security source <source>"`).
8. `EditorDialog` (hidden until triggered) for Add Source — see `_component_EditorDialog`.
9. `ConfirmDialog` (hidden until triggered) for Delete confirmation — see `_component_ConfirmDialog`.

## State contract

### Loading
- Body card renders `Loading security sources...` text only. Header (title, badge, `Add Source` trigger) is visible; badge shows `0` until data resolves. No row controls visible.

### Load-error
- Body card renders `Unable to load security sources.` followed by the server-provided error detail (`data-testid="security-sources-error-state"`).
- A `Retry` button (`data-testid="security-sources-retry-btn"`) re-issues the load action.
- The `Add Source` trigger is disabled in this state (writes against an unreachable backend would 5xx anyway; surface the load failure first).
- Distinct from the Empty state — copy and testid differ; an automated probe MUST be able to tell them apart.

### Empty
- Body card renders `No security sources configured yet.` (`data-testid="security-sources-empty-state"`). Entry-count badge shows `0`. `Add Source` trigger enabled.

### Populated
- Body card renders one row per entry, ordered by server response. Entry-count badge shows row count. `Add Source` trigger enabled. Each row exposes Delete.

### Add-dialog-open
- `EditorDialog` mounted with title `Add Security Source`, schema `{ source: text-required, description: textarea-optional }`. First field focused. Save button labelled `Add Source`.

### Add-untouched
- Sub-state of Add-dialog-open: source field empty, no validation message visible, Save disabled (per `EditorDialog` create-mode default).

### Add-validation-error
- Sub-state of Add-dialog-open: user submitted with blank-or-whitespace source. Inline message `Source is required.` rendered under the source input with `role="alert"`. Save disabled. Message clears the moment the user types a non-whitespace character.

### Saving
- Sub-state of Add-dialog-open after Save click with valid input: Save button shows pending label, all dialog controls disabled, Esc/backdrop dismiss disabled (per `EditorDialog` Saving contract).

### Save-error
- Sub-state of Add-dialog-open: `appendSecuritySource` action returned non-2xx. Server error (e.g. `Source 10.0.0.0/8 is already configured` or malformed-CIDR message) rendered in `EditorDialog`'s form-level `role="alert"` region. Dialog re-enables; in-flight values preserved.

### Delete-confirm-open
- `ConfirmDialog` mounted with title `Delete security source`, body naming the source value (`Delete 192.168.1.0/24? This will block requests from this source immediately.`), destructive Confirm button labelled `Delete`, secondary Cancel.

### Delete-in-flight
- Sub-state of Delete-confirm-open after Confirm click: Confirm shows pending label and is disabled, Cancel disabled, dialog cannot be dismissed.

### Delete-error
- `deleteSecuritySource` action returned non-2xx. `ConfirmDialog` closes; the inline server-error banner in the tab body renders the returned `securitySourceDeleteError` with `role="alert"`. List reloads to current server truth.

## Navigation

- Route: `/console/indexes/[name]` with the SecuritySources tab active (tab state is part of the parent `index_detail` URL/query contract).
- Entry: clicking the `Security Sources` tab on `Index Detail`.
- Add Source trigger: opens Add-dialog-open state; closes on Save success, Cancel, or non-dirty Esc/backdrop (per `EditorDialog` contract).
- Delete row button: opens Delete-confirm-open state; closes on Confirm success or Cancel.
- Retry (Load-error): re-invokes the SvelteKit `load` for the security-sources payload via `invalidate()` or equivalent — no full-page reload.
- Tab leave: any open dialog follows its own dirty-cancel-confirm path before navigation completes.

## Acceptance Criteria

- Given the API returns 500 for `getSecuritySources`, when the tab loads, then `security-sources-error-state` is visible with the server's error detail AND `security-sources-empty-state` is NOT in the DOM (load-error and empty states are visually and structurally distinct).
- Given the load-error state is visible, when the user clicks Retry and the API now succeeds, then the populated list renders and the error block is removed.
- Given an index with zero sources, when the tab loads successfully, then `security-sources-empty-state` is visible, the entry-count badge shows `0`, and `Add Source` is enabled.
- Given the user clicks `Add Source`, when the dialog opens, then it has `role="dialog"`, `aria-modal="true"`, focus on the source input, and Save disabled.
- Given the Add dialog is open with a blank source, when the user clicks Save, then an inline `Source is required.` message with `role="alert"` renders under the source input and the dialog stays open.
- Given the inline `Source is required.` message is visible, when the user types any non-whitespace character, then the message is removed from the DOM.
- Given the Add dialog is open with a valid source, when the user clicks Save and the server appends successfully, then the dialog closes, the new row is visible in the list, the entry-count badge increments by 1, and a `Security source added.` success banner renders.
- Given the server rejects the append with a duplicate-source error, when the rejection settles, then the dialog stays open with the server's error in its form-level `role="alert"` and the entered values preserved.
- Given a populated list, when the user clicks Delete on a row, then `ConfirmDialog` opens naming that source; clicking Cancel leaves the row in place; clicking Confirm and waiting for success removes the row, decrements the badge, and renders `Security source deleted.`.

## Edge cases

- Whitespace-only input in the source field is treated as blank (`source.trim().length === 0`) and triggers the same `Source is required.` validation as empty input.
- A very long source list (e.g. 200 entries) renders all rows in a scrollable card body; the header (title + badge + `Add Source`) stays in view. No pagination required at current expected scale.
- Mid-add network failure (browser offline, request hangs past timeout): `onSave` rejects, dialog enters Save-error state with a generic `Network error — please retry.` message; entered values preserved.
- Server rejects with a duplicate-source error: surfaced in the dialog's form-level alert (Save-error sub-state), not in the tab-body banner; the existing row is not duplicated; entry-count badge unchanged.
- Server rejects delete because the source no longer exists (concurrent deletion in another tab/session): the inline tab-body delete-error banner shows the server message and the list reloads, removing the stale row from view.
- Description field is optional everywhere; rows with no description render the literal placeholder `No description` (matches upstream `formatSecuritySourceDescription`).

## Current Implementation Gaps

- Current: Add Source is an always-visible inline grid form (`SecuritySourcesTab.svelte:66-97`) with disabled-button blocking and no inline validation message. Target: header-triggered `EditorDialog` with `role="alert"` `Source is required.` message that clears on input. Evidence: [tab_securitysources.md](../audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/tab_securitysources.md) rows 2 and 3 (both partial).
- Current: Delete submits a one-click form (`SecuritySourcesTab.svelte:131`) with no confirmation. Target: `ConfirmDialog` naming the source value before submit. Evidence: same audit, destructive-action site flagged in [SUMMARY.md](../audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/SUMMARY.md) Theme B (ConfirmDialog primitive).
- Current: `loadSecuritySourcesPayload` (`security-sources.server.ts:38-44`) wraps the API call in `try/catch` and returns `emptySecuritySourcesPayload()` on any error, making backend failure visually identical to "no sources." Target: discriminated load result (`{ sources } | { loadError: string }`) propagated to the tab; render `security-sources-error-state` with a Retry button when the error branch is populated. Evidence: [CRITICAL_BUGS.md S1-1](../audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/CRITICAL_BUGS.md).
- Current: no entry-count badge anywhere on the tab. Target: secondary-styled badge next to the `Security Sources` header showing `entries.length`. Evidence: [tab_securitysources.md](../audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/tab_securitysources.md) "Out-of-catalog observations" section.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/security-sources.spec.ts` (new) — load-error vs empty distinction, Retry recovery, add-dialog validation/success, and delete confirm with badge decrement.
- Browser-mocked tests: `web/tests/e2e-ui/mocked/security-sources_errors.spec.ts` (new) — duplicate-source append rejection and concurrent delete failure banner.
- Component tests: extend `web/src/routes/console/indexes/[name]/tabs/SecuritySourcesTab.test.ts` for state-branch rendering, entry-count badge behavior, and modal open/close flows.
- Server/contract tests: extend `web/src/routes/console/indexes/[name]/detail.server.actions.test.ts` or `security-sources.server` tests for discriminated load-error shaping plus append/delete action error propagation.
