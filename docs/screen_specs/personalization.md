# Personalization Tab Screen Spec

## Task

Configure event and facet scoring for a single index, save the strategy to enable personalized ranking, then look up and inspect (or delete) a specific user's personalization profile.

## Layout

1. Tab header: title `Personalization` and a one-line description: `Configure event and facet scoring to influence ranking.`
2. Setup section (only when no strategy is persisted and no draft is in flight) — heading `Personalization is not configured yet.`, helper copy, and a primary `Use starter strategy` button.
3. Strategy editor card (visible when a draft exists OR a persisted strategy was loaded):
   - `Personalization impact (0-100)` numeric input (`personalization-impact-input`).
   - `Event scoring` section: per-row controls `event-name-N` (text), `event-type-N` (select: `click | conversion | view`), `event-score-N` (numeric 1-100), per-row `Remove`, header `Add event` button (disabled at 15 rows).
   - `Facet scoring` section: per-row controls `facet-name-N` (text), `facet-score-N` (numeric 1-100), per-row `Remove`, header `Add facet` button (disabled at 15 rows).
   - Footer action row: primary `Save strategy` (`save-strategy-btn`), destructive `Delete Strategy`, and the gating reminder `Save the strategy to enable profile lookup.` when no strategy is persisted yet.
4. Profile-lookup section (only when a strategy is persisted):
   - Heading `User profile lookup`.
   - Row: `profile-lookup-input` text field (placeholder `Enter user token`) + primary `Lookup profile` button (`profile-lookup-btn`, disabled when the input is empty/whitespace).
   - Results region (`profile-results`, rendered only after a lookup is submitted): user token line, optional `Last event at` line, then a per-facet card per `scores` entry — facet name as header, per-facet-value `value: score` list. Below the results: destructive `Delete Profile` button (fjcloud-only addition; preserved).

## State contract

### Loading
- `Loading personalization strategy...` text; setup, editor, and lookup sections all hidden.

### Error
- `Failed to load personalization strategy.` card with `Retry` button; editor and lookup sections hidden.

### Not-configured (no persisted strategy, no draft)
- Setup section visible per Layout #2. Editor and lookup sections hidden. `Use starter strategy` is the single primary action.

### Strategy-saved (persisted strategy loaded; draft = persisted values)
- Editor section visible per Layout #3 with persisted values; lookup section visible per Layout #4. Save reminder copy hidden. `Save strategy` disabled when the draft is unchanged AND valid (or unconditionally disabled when invalid).

### Strategy-editor-open (draft in flight, no persisted strategy yet)
- Editor section visible with starter or in-flight draft values; lookup section HIDDEN. Save reminder copy `Save the strategy to enable profile lookup.` visible below the action row.

### Saving
- `Save strategy` button shows `Saving...` label and is disabled. All other editor controls remain enabled. No success toast yet.

### Save-error
- Inline destructive text below the action row: server message verbatim. Editor stays open with the user's draft preserved. `Save strategy` re-enabled (subject to validity).

### Profile-lookup-untouched (strategy persisted, no lookup submitted yet)
- Lookup form visible; the `profile-results` region is NOT rendered. The user sees no placeholder text that could be mistaken for "no profile found".

### Profile-lookup-in-flight
- `profile-results` region renders `Loading profile...` text only. Submit button remains visible but disabled until response.

### Profile-lookup-found
- `profile-results` region renders the structured per-facet cards per Layout #4 plus the `Delete Profile` button.

### Profile-lookup-empty
- `profile-results` region renders `No profile found` text only (distinct from the untouched state). `Delete Profile` NOT rendered.

### Profile-lookup-error
- `profile-results` region renders destructive text `Failed to load profile.` with the server message. `Delete Profile` NOT rendered.

### Profile-delete-confirm
- `[ConfirmDialog]` titled `Delete profile?` with body `This permanently removes the profile for "{userToken}".` Buttons: `Cancel` + destructive `Delete`. Underlying page non-interactive. On confirm: profile cleared, lookup region returns to Profile-lookup-untouched state and a success toast appears.

## Navigation

- Route: `/console/indexes/[name]` with `tab=personalization` query param.
- Entry: clicking `Personalization` in the tab strip on `Index Detail`.
- Back: browser back returns to the previously active tab on `Index Detail`. ESC / scrim / `Cancel` on the delete dialog returns to the prior state with no mutation.
- Save success: editor remains open with the just-saved values; a success toast `Strategy saved.` appears; the lookup section becomes visible if it was hidden.
- Delete-strategy success: editor returns to Not-configured state; success toast `Strategy deleted.`
- Delete-profile success: lookup region returns to Profile-lookup-untouched state; success toast `Profile deleted.`

## Acceptance Criteria

- Given an index with no persisted personalization strategy, when the user opens the Personalization tab, then the setup section is visible with the `Use starter strategy` button and NO editor, NO lookup section, and NO pre-filled JSON is shown.
- Given the setup section is visible, when the user clicks `Use starter strategy`, then the editor renders with starter defaults (1 event row: `Product Viewed` / `view` / 20; 1 facet row: `brand` / 70; impact 60) and the lookup section remains hidden until save.
- Given the editor is open with a valid draft, when the user clicks `Save strategy`, then the strategy persists, the success toast appears, and the lookup section becomes visible.
- Given the editor is open, when any row has an empty name, a score outside 1-100, an impact outside 0-100, zero rows, or more than 15 rows in either section, then `Save strategy` is disabled (no server round-trip occurs).
- Given a persisted strategy is loaded, when the user submits a lookup for a known userToken, then the `profile-results` region renders one per-facet card per `scores` key, each listing facet-value/score pairs as discrete elements (NOT a raw JSON `<pre>` block).
- Given a persisted strategy is loaded, when the user submits a lookup for an unknown userToken, then the `profile-results` region renders `No profile found` — distinct from the pre-lookup state, which renders no `profile-results` region at all.
- Given a profile-lookup-found state, when the user clicks `Delete Profile`, the `[ConfirmDialog]` opens; clicking `Delete` clears the profile, returns the lookup region to Profile-lookup-untouched state, and shows the `Profile deleted.` toast; clicking `Cancel` instead leaves the profile rendered unchanged.
- Given the Personalization tab is shipping, then `web/tests/e2e-ui/full/personalization.spec.ts` exists and covers: setup → save happy path, validation gates (empty name, score out of range, 16-row max), lookup-found vs lookup-empty distinction, delete-profile flow, and delete-strategy returning to setup state.

## Edge cases

- Server rejects strategy on save (validation drift, 4xx with server-side message): editor stays open, draft preserved, server message rendered inline; the user can adjust and resubmit without losing input.
- Mid-save network failure (transient 5xx, fetch abort): editor stays open with `Save strategy` re-enabled; inline error banner shows `Save failed — please retry.`; no toast.
- Profile lookup for nonexistent / empty userToken: input-empty disables the submit button (no request fires); whitespace-only input is treated as empty.
- Profile lookup against an index with persisted strategy but zero matching events ingested: response is null → Profile-lookup-empty state with `No profile found`.
- User attempts to save a strategy with 16 event rows (drift from upstream-API loosening): the client gate blocks at 15; if the server ever returns 422 for >15, the message surfaces via Save-error state.
- Delete-strategy with no persisted strategy: button hidden in setup state, so this is not reachable from the UI.
- Concurrent edit (another operator persists a different strategy mid-edit): on next reload the persisted values overwrite the unsaved draft and a non-blocking warning toast appears; the draft is not silently merged.

## Current Implementation Gaps

These deltas are documented per the 2026-05-25 parity audit ([tab_personalization.md](../audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/tab_personalization.md)).

- Current: editor is a single raw-JSON `<textarea name="strategy">` pre-filled from a hardcoded `defaultStrategy` (`Product viewed`/view/10 + `Product purchased`/conversion/50 + brand/70 + category/30 + impact 75) regardless of whether a strategy was persisted.
  Target: structured per-row event + facet editor with typed selects and bounded numeric inputs, fronted by `[EditorDialog]`-style form primitives, plus an explicit setup-state branch with a `Use starter strategy` CTA when nothing is persisted.
  Evidence: `web/src/routes/console/indexes/[name]/tabs/PersonalizationTab.svelte:25-35` (hardcoded default), `:37-53` (single render path), `:96-127` (textarea editor); upstream `engine/dashboard/src/pages/Personalization.tsx:29-35` (`createStarterStrategy`), `:100-110` (`SetupStateCard`), `:137-228` + `:235-304` (Event/Facet sections), `:328-347` (`personalization-impact-input`), `:361-370` (save-disabled + gating copy), `:442-449` (render-branch).
- Current: profile-lookup card is always rendered regardless of whether a strategy is persisted; null profile and pre-lookup states both render `No profile loaded.` indistinguishably.
  Target: lookup section gated behind `hasPersistedStrategy`; render NO `profile-results` region pre-lookup; render `No profile found` only after a submitted lookup returns null.
  Evidence: `PersonalizationTab.svelte:129-168` (no gating, ambiguous placeholder); upstream `Personalization.tsx:463-474` (`ProfileLookupCard` gated on `hasPersistedStrategy`), `personalization/ProfileLookupCard.tsx:72-78` (`No profile found` branch).
- Current: profile result renders as `<pre>{JSON.stringify(personalizationProfile, null, 2)}</pre>`.
  Target: structured rendering — user token row, optional `Last event at` row, per-facet card with per-facet-value `value: score` list (`profile-results` testid wrapper).
  Evidence: `PersonalizationTab.svelte:147-168`; upstream `personalization/ProfileLookupCard.tsx:17-45` (`ProfileResults` component).
- Current: zero Playwright coverage for this tab (`grep personalization web/tests/` returns nothing); only Vitest server-action + client-API tests exist.
  Target: `web/tests/e2e-ui/full/personalization.spec.ts` covering the acceptance criteria above, per CLAUDE.md "No Manual QA" + `~/.matt/scrai/globals/standards/browser_testing.md`.
  Evidence: audit § Summary stats ("zero Playwright tests reference Personalization"); audit § Theme G.
- Current: `Delete Profile` is preserved as a useful SaaS addition not present upstream.
  Target: KEEP `Delete Profile`, but gate behind a `[ConfirmDialog]` per cross-cutting Theme B; not a parity gap, not for removal.
  Evidence: `PersonalizationTab.svelte:156-164`; audit § Theme B (destructive confirmations).

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/index-detail.spec.ts`; `web/tests/e2e-ui/full/indexes.spec.ts`
- Server/contract tests: `web/src/routes/console/indexes/[name]/detail.server.actions.test.ts`
