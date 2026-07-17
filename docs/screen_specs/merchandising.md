# Merchandising Hub Screen Spec

## Scope

- Primary route: `/console/indexes/[name]?tab=merchandising`
- Legacy route compatibility: `/console/indexes/[name]?tab=rules` normalizes to the Merchandising tab through `resolveTabParam` in `web/src/routes/console/indexes/[name]/index_detail_tabs.ts`.
- Related specs: [`_component_ConfirmDialog.md`](_component_ConfirmDialog.md), [`_component_EditorDialog.md`](_component_EditorDialog.md), [`index_detail.md`](index_detail.md)
- Audience: authenticated customers creating, auditing, publishing, editing, and deleting ranking rules for one index.

## User Goal

Manage the index's rule configuration from one hub without hand-authoring full rule JSON: create draft or published rules, inspect existing rule scope and consequences, identify same-scope conflicts, publish drafts, and delete one or all rules through confirmation dialogs.

## Data Contract

- The hub renders from the `RuleListPayload` passed to `MerchandisingTab.svelte`. `RuleListPayload` extends `RuleSearchResponse` with optional `totalNbHits` and `query`.
- Rule rows render from `RuleSearchResponse.hits` in API order. Display order is informational only and does not define execution priority.
- `filteredCount` uses `rules.nbHits`; `totalRuleCount` uses `rules.totalNbHits ?? rules.nbHits`.
- `activeQuery` uses `rules.query` and pre-fills the GET filter input.
- Row description copy is owned by `buildRuleDescription(rule)`.
- Row state is owned by `buildRuleRowStatus(rule)`. `enabled === false` renders the `Draft` badge; enabled rules do not render an `Active` badge.
- Conflict indicators are owned by `buildRuleConflictMap(rules.hits)`, which flags rules that share the same normalized first-condition query pattern, anchoring, and filter scope.
- Publishing a draft posts `ruleForPublish(rule)` through the existing `?/saveRule` action.

## Layout

1. Hub panel:
   - `data-testid="merchandising-section"` on the tab panel.
   - `data-index` contains the current index name.
   - Heading text: `Merchandising hub`.
   - Stats placeholder copy: `Merchandising performance stats are not available yet.`
2. Header controls:
   - `+ New rule` button opens `RulesEditorDialog` in create mode.
   - `Clear All Rules` button is rendered only when `totalRuleCount > 0`; it opens a typed `ConfirmDialog` before submitting `?/clearRules`.
3. Feedback banners:
   - `Rule saved.`
   - `Rule deleted.`
   - `Rules cleared.`
   - `ruleError` and `rulesClearError` render as tab-local error copy.
4. Search form:
   - GET form with `action=""`.
   - Hidden input `tab=merchandising`.
   - Search input `name="q"`, label `Search merchandising rules`, placeholder `Search rules`, value from `rules.query`.
   - Submit button text: `Search`.
5. Count display:
   - Rendered when `rules !== null`.
   - Shows `<N> filtered rule(s)` and `<N> total rule(s)`.
6. Rule list:
   - Each row uses `data-testid="merchandising-rule-row-{objectID}"`.
   - Each row shows the rule `objectID`, optional `Draft` badge, `buildRuleDescription(rule)` summary, optional conflict warning, and row actions.
   - Conflict warning text: `Conflicts with another rule for this query and filter scope`.
   - Row actions are `Edit`, optional `Publish` for draft rows, and `Delete`.
7. Editor and confirmations:
   - `RulesEditorDialog` is mounted once by the hub and switches between create and edit mode.
   - The per-row delete flow uses a standard `ConfirmDialog`.
   - The clear-all flow uses a typed `ConfirmDialog`.

## State Contract

- **Loading / degraded load:** `rules === null`. Header controls remain visible. The list area shows `Merchandising rules could not be loaded.`
- **Empty no rules:** `rules.hits.length === 0` and `totalRuleCount === 0`. The empty state shows `No merchandising rules yet` and `Create rules to promote, hide, or pin records for this index.` `+ New rule` remains available.
- **Empty search no match:** `rules.hits.length === 0` and `totalRuleCount > 0`. The empty state shows `No rules match your search` and `Adjust the query or clear the filter to see all rules.`
- **Populated:** one row renders for each rule in `rules.hits`; filtered and total counts are visible.
- **Rule saved:** `ruleSaved` shows `Rule saved.`
- **Rule deleted:** `ruleDeleted` shows `Rule deleted.`
- **Rules cleared:** `rulesCleared` shows `Rules cleared.`
- **Load or save error:** `ruleError` renders as tab-local error text.
- **Clear error:** `rulesClearError` renders as tab-local error text.
- **Delete confirm:** clicking `Delete` on a row opens the standard severe confirmation dialog and only then submits the row's `?/deleteRule` form.
- **Clear-all confirm:** clicking `Clear All Rules` opens the typed severe confirmation dialog and only then submits the `?/clearRules` form.

## Controls

### Rule Search

- The search form preserves tab state by submitting `?tab=merchandising&q=<query>`.
- Filtering is server-owned through the existing rules load path; the component does not locally filter `hits`.

### RulesEditorDialog

- Create mode is opened by `+ New rule`.
- Edit mode is opened by a row's `Edit` button and preserves the existing rule `objectID`.
- The dialog is a structured builder backed by `RulesEditorDialog.svelte`; it exposes object ID in create mode, description, query pattern, anchoring mode, filter scope, validity dates, rule state, promote item ID, promote position, hide item ID, and a read-only JSON preview.
- Saves post the existing `?/saveRule` form with `objectID` and serialized `rule` fields.

### Publish

- `Publish` appears only for rows where `buildRuleRowStatus(rule).isDraft` is true.
- The button submits `?/saveRule` with the same `objectID` and a hidden `rule` payload equal to `ruleForPublish(rule)`.

### Delete

- Each row contains a `?/deleteRule` form with hidden `objectID`.
- The visible `Delete` button is `type="button"` and opens the standard `ConfirmDialog`.
- Confirming the dialog calls `requestSubmit()` on the pending row form.

### Clear All

- The `Clear All Rules` button renders only when the unfiltered total count is greater than zero.
- The button opens a typed `ConfirmDialog` with typed phrase `clear all rules`.
- Confirming the dialog calls `requestSubmit()` on the pending `?/clearRules` form.

## Navigation

- `?tab=merchandising` is the canonical route for rule management.
- `?tab=rules` is accepted only as a legacy URL and normalizes to Merchandising. There is no visible Rules tab button.
- Form result state for `ruleSaved`, `ruleDeleted`, `rulesCleared`, `ruleError`, and `rulesClearError` routes the user to the Merchandising tab even if the previous URL named another tab.

## V1 Non-Goals

- Row order does not affect execution priority; rules execute by match, not display order.
- No drag-and-drop reordering.
- No local-storage order.
- No hidden order metadata or tags.
- No per-query merchandising canvas in this hub. A per-query visual merchandising flow is deferred outside this v1 rule-management hub.

## Acceptance Criteria

- [ ] Given `RuleSearchResponse.hits` contains two rules, when the hub renders, then it shows two `merchandising-rule-row-{objectID}` rows in API order with objectID and `buildRuleDescription(rule)` summary text.
- [ ] Given a rule has `enabled === false`, when the row renders, then `buildRuleRowStatus(rule)` marks it draft and the row shows the `Draft` badge.
- [ ] Given a rule has `enabled !== false`, when the row renders, then no `Draft` badge appears.
- [ ] Given two rules share identical normalized first-condition query pattern, anchoring, and filter scope, when the hub renders, then each matching row shows `Conflicts with another rule for this query and filter scope`.
- [ ] Given the hub renders, then it shows the stats placeholder `Merchandising performance stats are not available yet.`
- [ ] Given the user clicks `+ New rule`, then `RulesEditorDialog` opens in create mode with structured fields and a read-only JSON preview.
- [ ] Given the user clicks `Edit` on a row, then `RulesEditorDialog` opens in edit mode with that rule seeded and objectID read-only.
- [ ] Given the user clicks `Publish` on a draft row, then the row submits `ruleForPublish(rule)` through `?/saveRule`.
- [ ] Given the user clicks `Delete` on a row, then deletion does not submit until the standard `ConfirmDialog` is confirmed.
- [ ] Given existing rules are present and the user clicks `Clear All Rules`, then clearing does not submit until the typed `ConfirmDialog` is confirmed.
- [ ] Given the list cannot load, then the hub shows `Merchandising rules could not be loaded.` while keeping `+ New rule` visible.
- [ ] Given no rules exist, then the hub shows the global empty state and does not render `Clear All Rules`.
- [ ] Given a search returns no matches while total rules exist, then the hub shows the filtered empty state rather than the global empty state.

## Edge Cases

- `rules.totalNbHits` omitted: total count falls back to `rules.nbHits`.
- `rules.query` omitted: the search input starts empty.
- Conflict checks ignore rows whose first condition has no normalized pattern.
- Conflict checks are scoped to the currently loaded `hits`; cross-page conflict discovery is a future server concern.
- A draft row can be edited or published; publishing preserves the rule payload except for `enabled: true`.
- Clear-all is unavailable when the server reports zero total rules, even if the current search query is empty.
- The hub must not render legacy search-and-pin canvas controls, hidden trays, recent-rule cards, pin toggles, drag handles, move-up/down controls, or a `Save as Rule` button.

## Current Implementation Gaps

- Performance stats are intentionally a placeholder in v1. The shipped copy is `Merchandising performance stats are not available yet.`
- Conflict warnings identify that a same-scope conflict exists but do not name the conflicting rule objectID.
- Conflict detection is limited to the loaded `RuleSearchResponse.hits`; server-side whole-index conflict analysis is not yet implemented.
- Browser coverage for the moved merchandising interactions is planned for Stage 6. Stage 5 only documents the as-built hub and current component coverage.

## Automated Coverage

- Component tests: `web/src/routes/console/indexes/[name]/tabs/MerchandisingTab.test.ts` covers the hub shell, absence of the old search-and-pin canvas, GET filter path, stats placeholder, row rendering from `rules.hits`, draft badge behavior, empty states, count display, structured `RulesEditorDialog` create/edit flows, draft publish payload, delete and clear forms, clear feedback, and conflict warnings.
- Detail component tests: `web/src/routes/console/indexes/[name]/detail.test.ts` covers degraded `rules === null` routing, absence of a visible Rules tab button, Merchandising tab selection, and legacy `?tab=rules` normalization to Merchandising.
- Browser-state component tests: `web/src/routes/console/indexes/[name]/detail_browser_tabs.test.ts` covers stale browser URL handling and routing rule form results to Merchandising.
- Stage 6 owns moving browser coverage for the wider merchandising workflow; this spec intentionally does not name a future browser spec file that does not exist yet.
