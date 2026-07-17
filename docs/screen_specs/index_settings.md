# Index Settings Tab Screen Spec

## Scope

- Primary route: `/console/indexes/[name]?tab=settings`
- Related route: `/console/indexes/[name]`
- Related specs: `index_detail.md`, `search.md`
- Audience: authenticated customers configuring one search index
- Priority: P0

## User Goal

Inspect and edit index-owned settings through focused settings sub-tabs while keeping one authoritative settings payload, one reset lifecycle, and one save action.

## Target Behavior

The Settings tab is the single detailed owner for nested behavior under `/console/indexes/[name]?tab=settings`. The parent index detail spec owns only the tab shell, lazy mount behavior, and cross-tab context; account management remains owned by `settings.md` at `/console/account`.

The tab renders a nested sub-tab strip driven by `settingsTab`. `Search`, `Ranking`, `Facets & Filters`, `Display`, and `Advanced JSON` expose editable controls only for fields already proven by the settings payload contract. `Language & Text` currently has no repo-proven query-language settings key, so it renders a documented gap state and must not introduce client-only query-language state.

All nested states share one settings draft. Structured controls read from and write to that shared draft, the raw `Settings JSON` textarea always reflects the same draft, `Reset` restores the latest server-hydrated JSON, and `Save Settings` submits the single `Settings JSON` form field. No nested sub-tab gets a separate save button, separate reset lifecycle, or separate warning path.

## Query Param Contract

- Parent route tab: `/console/indexes/[name]?tab=settings`.
- Nested query key: `settingsTab`.
- Part 1 deep links:
  - `settingsTab=search` opens the `Search` settings state.
  - `settingsTab=ranking` opens the `Ranking` settings state.
  - `settingsTab=advanced-json` opens the `Advanced JSON` state.
- Stage 1 deep links:
  - `settingsTab=language-text` opens the documented Language & Text gap state.
  - `settingsTab=facets-filters` opens editable `filterableAttributes` controls.
  - `settingsTab=display` opens editable `displayedAttributes` controls.
- Missing, empty, or invalid `settingsTab` values fall back to `Search`.
- Nested tab changes update only `settingsTab`; they preserve `tab=settings` and do not discard unsaved draft text.

## Settings Breadcrumb Contract

The breadcrumb is owned by `IndexDetailShell.svelte` (the route wrapper `+page.svelte` only delegates). Parity evidence: `docs/audits/3h_settings_migrate_findings.md` row `followup-settings-breadcrumb` (upstream `settings.spec.ts:226`) expects a Settings-specific breadcrumb that links back to the index rather than a page-level breadcrumb that ends at the index name.

- On non-settings tabs the breadcrumb is unchanged: `Console / Indexes / {index.name}`, where `{index.name}` is the trailing non-link crumb.
- When `activeTab === 'settings'` the breadcrumb gains one extra trailing label, `Settings`, and the `{index.name}` crumb becomes a link back to the base index detail route (`/console/indexes/[name]` with no `settingsTab` and no `tab=settings`, i.e. the default index detail view). The final `Settings` crumb is the current, non-link label.
- The settings breadcrumb reads `Console / Indexes / {index.name} / Settings`. Only the settings tab changes the breadcrumb; switching to any other tab restores the page-level breadcrumb with no extra `Settings` label.
- The breadcrumb reuses the existing page-level breadcrumb structure. No new breadcrumb component is introduced.

## Reindex Warning Save Lifecycle

The single shared settings form must confirm before saving when the draft changes a reindex-risk field. Parity evidence: `docs/audits/3h_settings_migrate_findings.md` row `followup-settings-reindex-warn` (upstream `settings.spec.ts:397`) expects a reindex warning dialog on save with a confirm-to-proceed path.

- The warning is evaluated against the diff between the server-hydrated settings object and the current parsed draft, so it fires for both structured-subtab edits and raw `Advanced JSON` textarea edits that flip a reindex-risk key.
- The reindex-risk keys are a single source of truth in `settings_draft.ts`. Stage 3 covers the engine-defined reindex-trigger keys the repo can already load and save: `searchableAttributes`, `filterableAttributes`, `sortableAttributes`, and `distinctAttribute`.
- If the draft changes at least one reindex-risk field, `Save Settings` opens `ConfirmDialog` (`mode="standard"`, `dangerLevel="warn"`) that lists exactly the changed risky fields. If no reindex-risk field changed, `Save Settings` submits directly through the existing `?/saveSettings` form path with no dialog.
- `Cancel` closes the dialog and keeps the draft dirty: `settingsText`, the selected `settingsTab`, and the dirty-state UI (including `Reset`) are preserved, and nothing is submitted.
- `Confirm` proceeds through the same `?/saveSettings` form submission the current `Save Settings` button uses today, with no payload rewrite. `actions.saveSettings` remains the single unchanged save action.
- No per-subtab save buttons and no second warning path are introduced. The warning gate lives only in `SettingsTab.svelte`.

## Required States

- Loading: the parent detail shell may lazy-mount the Settings tab after click or deep link; once mounted, the selected nested tab uses the latest server settings payload to hydrate the shared draft.
- Empty: an empty server settings payload hydrates the shared draft as `{}` and still renders nested navigation, the raw JSON editor, and Save.
- Error: save failures render the existing tab-local `settingsError` without changing the selected nested tab or discarding the shared draft.
- Success: `Save Settings` shows the shared saved confirmation and keeps the user on `/console/indexes/[name]?tab=settings&settingsTab=<current>`.
- Invalid JSON: raw JSON remains editable and available to the form path, but structured editors are blocked from mutating the draft and show the existing quick-control guardrail message until the JSON is a valid object again.
- Language & Text gap: because the current settings payload contract exposes no supported query-language key, the tab explains that query-language editing is not available here and renders no editable query-language field.
- Facets & Filters: saved `filterableAttributes` hydrate as a comma-separated editable list. Values already wrapped as `filterOnly(<attribute>)` render distinctly in the same control and round-trip exactly as strings in `filterableAttributes`.
- Display: saved `displayedAttributes` hydrate as a comma-separated editable list and round-trip exactly as strings in `displayedAttributes`.

## Controls And Navigation

- Nested tab buttons expose `Search`, `Ranking`, `Language & Text`, `Facets & Filters`, `Display`, and `Advanced JSON`.
- `Search` owns structured controls for search-mode settings that are safe to edit from the shared draft. The existing mode control belongs here when Part 1 UI is implemented.
- `Ranking` owns structured controls for ranking settings that are safe to edit from the shared draft. Ranking controls introduced later must use the shared draft and the shared Reset/Save lifecycle.
- `Advanced JSON` owns raw settings editing and advanced controls that do not yet have dedicated structured homes. The existing vector, hybrid, embedder, and re-ranking controls stay under `Advanced JSON`.
- `Language & Text` owns the documented no-query-language-key gap state only. It must not mutate settings until a repo-proven settings key exists.
- `Facets & Filters` owns `filterableAttributes` editing through the shared draft. The field is a comma-separated string-list control and preserves literal values such as `filterOnly(category)`.
- `Display` owns `displayedAttributes` editing through the shared draft. The field is a comma-separated string-list control.
- `Settings JSON` is the single form field submitted by Save.
- `Reset` appears only after the shared draft differs from the server-hydrated JSON and resets every nested state because all nested states read the same draft.
- `Save Settings` is the only submit control for all nested states.

## Stage 1 Payload Contract

- Existing evidence: `web/src/routes/console/indexes/[name]/detail.test.shared.ts` hydrates settings as a generic JSON object with `searchableAttributes`, `displayedAttributes`, `filterableAttributes`, and `sortableAttributes`.
- Existing evidence: `web/src/routes/console/indexes/[name]/detail.settings.test.ts` owns component coverage for the shared settings draft, nested routing, Reset, Save, invalid-JSON guardrail, and structured settings controls.
- Existing evidence: `web/src/lib/api/client-indexes.test.ts` proves `GET /indexes/:name/settings` and `PUT /indexes/:name/settings` pass generic JSON settings through without a narrower typed request object.
- Existing evidence: `web/src/routes/console/indexes/[name]/detail.server.actions.test.ts` proves `actions.saveSettings` parses one `settings` JSON object and passes it unchanged to `updateIndexSettings`.
- Allowed Stage 1 field owners: `SettingsTab.svelte` owns the single settings form, nested tab routing, `settingsText`, global `Reset`, and `Save Settings`; `settings_draft.ts` owns shared draft parsing, formatting, and mutation helpers; `+page.server.ts` `actions.saveSettings` owns the one save path.
- Supported Stage 1 editable keys: `filterableAttributes` and `displayedAttributes`, both represented as JSON string arrays in the shared settings draft.
- Unsupported Stage 1 key: query-language settings. No current settings payload contract key supports it, so `Language & Text` must render the documented gap state without an editable query-language control.

## Acceptance Criteria

- [ ] `/console/indexes/[name]?tab=settings` opens Settings and falls back to the `Search` nested state when `settingsTab` is missing.
- [ ] `settingsTab=search`, `settingsTab=ranking`, and `settingsTab=advanced-json` deep-link directly to their named nested states.
- [ ] Invalid nested tab values preserve the parent Settings tab and fall back to `Search`.
- [ ] `Language & Text` renders the documented query-language gap state with no editable query-language control and no draft mutation.
- [ ] `Facets & Filters` deep-links to a `filterableAttributes` editor that preserves `filterOnly(...)` strings and writes the exact expected array into the shared draft.
- [ ] `Display` deep-links to a `displayedAttributes` editor that writes the exact expected array into the shared draft.
- [ ] All nested states read and write one shared draft; switching nested tabs preserves unsaved JSON text.
- [ ] The raw `Settings JSON` textarea remains available in `Advanced JSON` and stays the submitted form field.
- [ ] Existing vector, hybrid, embedder, and re-ranking controls stay under `Advanced JSON` and update the shared draft before save.
- [ ] `actions.saveSettings` remains a single JSON-object pass-through for Stage 1 payloads containing `filterableAttributes` and `displayedAttributes`.
- [ ] Invalid JSON blocks structured editors with the quick-control guardrail while leaving raw JSON accessible.
- [ ] `Reset` and `Save Settings` are shared across nested states; no nested state introduces a second reset, save, success toast, or warning path.
- [ ] On `/console/indexes/[name]?tab=settings` the breadcrumb reads `Console / Indexes / {index.name} / Settings`, with `{index.name}` linking back to the base index detail route and `Settings` as the trailing non-link crumb; non-settings tabs keep the unchanged `Console / Indexes / {index.name}` breadcrumb.
- [ ] Editing a reindex-risk field (`searchableAttributes`, `filterableAttributes`, `sortableAttributes`, or `distinctAttribute`) via a structured subtab OR the raw `Advanced JSON` textarea makes `Save Settings` open `ConfirmDialog` listing the changed risky fields; a draft change touching only non-risky fields saves directly with no dialog.
- [ ] In the reindex warning dialog, `Cancel` preserves the dirty draft and submits nothing; `Confirm` submits exactly once through the unchanged `?/saveSettings` form path with no payload rewrite.

## Current Implementation Gaps

- Language & Text query-language editing remains blocked on a repo-proven settings payload key. Do not add a client-only field as a substitute.
- The current browser coverage in `web/tests/e2e-ui/full/index-detail.spec.ts` proves Settings lazy mount, raw JSON visibility, Reset, Save, and the shared success toast. Later browser tests should codify the Stage 1 structured subtab contracts from this spec.
- Compact-index parity rows `compact index button is visible and enabled` and `compact index button click triggers compaction` (from `docs/audits/3h_settings_migrate_findings.md:162-163`) are **blocked-on-engine**. Zero compact/compaction/optimize surface exists in `infra/api/src/`, `web/src/lib/api/`, or `web/src/routes/console/indexes/[name]/+page.server.ts`. The smallest unblocking backend change (engine endpoint + proxy method + API route + client method) is documented in `chats/icg/stubs/jul07_3pm_12_compact_gap.md`. Do not add a dead UI button while blocked.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/index-detail.spec.ts`
- Component tests: `web/src/routes/console/indexes/[name]/detail.settings.test.ts`
- Server/contract tests: `web/src/routes/console/indexes/[name]/detail.server.actions.test.ts`
