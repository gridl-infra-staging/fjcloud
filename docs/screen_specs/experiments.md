# Experiments Tab (List + Detail + Create Wizard)

## Task

Compare two search configurations on live traffic, monitor progress with statistical and ranking-quality signals, and conclude with a deliberate winner-promotion decision — covering the list view, the per-experiment detail page, and the guided create wizard.

## Layout

### List view (`/console/indexes/[name]?tab=experiments`)

1. Header row (left): heading `Experiments` (`data-testid="experiments-heading"`) + one-line subtext (`Compare search strategies and safely roll out winners.`) + inline count badge (`data-testid="experiment-count"`) showing total experiments for this index.
2. Header row (right): primary `Create Experiment` button (`data-testid="create-experiment-btn"`) — opens the purpose-built `CreateExperimentDialog` in the 4-step wizard configuration. `CreateExperimentDialog` is a single-purpose component for Experiments (re-uses ConfirmDialog overlay styles but with custom step-aware body content + per-step footer); it is NOT a configuration of `EditorDialog`. Mirrors upstream `flapjack_dev/engine/dashboard/src/components/experiments/CreateExperimentDialog.tsx` (507 lines, hand-rolled).
3. Experiments table (`data-testid="experiments-table"`) — one row per experiment with columns:
   1. **Name** — link styled `<a href={`./experiments/${experiment.abTestID}`}>` (real anchor, not a button — supports middle-click / cmd-click new-tab).
   2. **Status** — colored pill via `formatExperimentStatusBadgeClass(status)`; values `created` / `running` / `stopped` / `concluded`.
   3. **Metric** — humanized via `formatMetricLabel(primaryMetric)` (e.g. `Conversion Rate`, not `conversionRate`).
   4. **Traffic split** — right-aligned `50% / 50%`.
   5. **Started** — `experiment.startedAt` formatted as locale date, or `—` when unstarted.
   6. **Actions** (right): `Stop` (outline, visible only when `status === 'running'`) and `Delete` (ghost, destructive-tinted, `disabled` when `status === 'running'`). Both wired to `ConfirmDialog`.

### Detail view (`/console/indexes/[name]/experiments/[experimentId]`)

1. Header row: `← Back to experiments` link (`<a>` to the list) + experiment name (`data-testid="experiment-detail-name"`) + status pill (`data-testid="experiment-detail-status"`) + index label (`data-testid="experiment-detail-index"`) + primary-metric pill (`data-testid="experiment-detail-primary-metric"`, value humanized).
2. Action row (right-aligned): `Stop` (running only), `Declare Winner` (when `viewModel.canDeclareWinner`), `Delete` (concluded/stopped only). All three confirm via `ConfirmDialog`.
3. Days-gate warning card (`data-testid="minimum-days-warning"`) — only when `viewModel.needsDaysGateWarning` (minimumN reached, minimumDays not). Warns about novelty effect.
4. Progress card (`data-testid="experiment-progress"`) — only when `!results.gate.readyToRead`. Shows `currentSearchesPerArm / requiredSearchesPerArm`, `progressPct`%, `estimatedDaysRemaining` (when present), `<div role="progressbar">` with full ARIA attrs.
5. Recommendation banner (`data-testid="experiment-recommendation"`) — sky-blue informational card rendered whenever `results.recommendation` is non-null (running OR concluded — not just post-conclude).
6. SRM banner (`data-testid="experiment-srm-banner"`) — when `results.sampleRatioMismatch`. Body lists remediation hints (`Possible causes: bot traffic, cookie clearing, variant index errors. Results may be invalid. Investigate before concluding.`).
7. Guard-rail alerts (`data-testid="experiment-guardrail-banner"`) — per-alert row showing humanized metric label + dropPct + formatted control vs variant values via `formatExperimentPrimaryMetricValue`.
8. Arm metrics cards (`data-testid="experiment-arm-control"`, `experiment-arm-variant`) — side-by-side: Searches, Users, Clicks, CTR, Conversion, Zero-result, Abandonment, **Revenue / Search** (currency-formatted).
9. Significance card (`data-testid="experiment-significance-card"`) — confidence % + colored bar (95% emerald-600, 90% emerald-400, 50% amber, else red), winner label, relative improvement %, **`CUPED` badge** when `results.cupedApplied`.
10. Bayesian card (`data-testid="experiment-bayesian-card"`) — prominent (2xl font) `<probVariantBetter>% probability variant wins` with subtext `Valid to inspect at any time. Useful when frequentist significance may take weeks.`.
11. Mean click rank card (`data-testid="experiment-mean-click-rank"`) — side-by-side control vs variant average click position with `↓ Lower is better` hint.
12. Interleaving card (`data-testid="experiment-interleaving-card"`) — only when `results.interleaving` non-null. ΔAB delta, verdict (`Control preferred` / `Variant preferred` / `No preference detected`), p-value, 2×2 grid of wins/ties, data-quality warning when `dataQualityOk === false`, footnote about 50× sensitivity vs A/B.
13. Outlier / unstable-userToken notices (`data-testid="experiment-outlier-notice"`, `experiment-unstable-token-notice`) — muted text when `viewModel.outlierUsersExcluded > 0` or `viewModel.unstableIdFraction > 0.05`.
14. Variants table (`data-testid="experiment-variants-table"`) — per-variant index name, query overrides preview (read-only), traffic %.
15. Conclusion summary card (`data-testid="experiment-conclusion-card"`) — only when `viewModel.hasConclusion`. Renders **`results.conclusion.reason`** (the human-supplied text), `controlMetric` / `variantMetric` from the **stored conclusion** (not recomputed), winner label, `promoted: Yes|No`, `endedAt` date.

## State contract

### List — Loading
- Skeleton: header row hidden, three skeleton table rows; `Create Experiment` button hidden until data resolves (no mid-paint flicker).

### List — Error
- Table area replaced by `Experiments could not be loaded. Try refreshing the page.` inside a `role="alert"` region. `Create Experiment` button remains enabled (create flow does not depend on the list load).

### List — Empty
- `No experiments yet` headline + explanation (`Create an experiment to compare control and variant performance.`) + inline `Create Experiment` shortcut. Count badge hidden.

### List — Populated
- Header (count, `Create Experiment`) + table per Layout. Default sort: most recently created first.

### Detail — Loading
- Skeleton: name + status pill skeleton, two arm-card skeletons, no actions visible.

### Detail — Not-found
- `Experiment not found` headline + `Back to experiments` link. Returned when the server load throws 404 (e.g. deleted by another tab).

### Detail — Created (not-yet-started)
- Header shows `Status: Created` pill. Actions row shows `Start` button + `Delete` (with confirm). No metrics cards (no data yet); placeholder `Experiment has not started collecting data.`

### Detail — Running
- Header shows `Status: Running`. Actions row: `Stop` (with confirm). Progress card visible (unless soft-gate ready). Metrics + significance + bayesian + arm cards render. `Declare Winner` visible when `viewModel.canDeclareWinner`. Days-gate warning card rendered when `viewModel.needsDaysGateWarning`.

### Detail — Stopped-pending-conclude
- Header shows `Status: Stopped`. Actions row: `Declare Winner` (when minimumN reached, still pre-conclude) + `Delete` (with confirm). Same metric/significance surfaces as Running, but no progress card.

### Detail — Concluded
- Header shows `Status: Concluded`. Actions row: `Delete` only. `Declare Winner` button hidden. Conclusion summary card (Layout #15) is the primary affordance; arm metrics + significance still visible read-only.

### Detail — Stopping-in-flight (ConfirmDialog confirming)
- Stop button shown in `Confirming-in-flight` per `_component_ConfirmDialog.md`. Page otherwise unchanged.

### Detail — Deleting-confirm-open (ConfirmDialog typed-severe)
- `ConfirmDialog` open in typed mode, danger=severe, `typedPhrase = experiment.name`. Body: `All historical analytics for "<name>" will be permanently removed.` On Confirm success: navigate to `/console/indexes/[name]?tab=experiments`.

### Detail — Days-gate-confirm-open
- Inline `ConfirmDialog` standard mode, warn. Title: `Conclude before minimum days reached?`. Body: `Concluding early risks a novelty effect bias. The experiment has reached minimum sample size but not the recommended minimum days. Are you sure you want to conclude now?` Cancel returns to detail; Confirm transitions to `Declare-winner-dialog-open`.

### Detail — Declare-winner-dialog-open
- `Dialog` (full primitive, not inline form). Sections:
  1. `SettingsDiff` block (`data-testid="settings-diff"`): if Mode-B, shows `Mode B: routes to index <variantIndex>`. Lists query overrides as `<key>: <JSON value>` rows.
  2. Winner radio group: Control / Variant / No Winner (inconclusive). Default selection: `results.significance?.winner` or `null` (the `null` value backs the `No Winner` radio per `ConcludeExperimentRequest.winner: 'control' | 'variant' | null`; do NOT introduce `'none'` as a literal — it is not a valid `winner` value).
  3. Reason textarea: prefilled by `defaultReason(results)` (e.g. `Statistically significant: variant wins on Conversion Rate with 95.2% confidence.`).
  4. Promote checkbox: rendered **only when** `canPromote === true` (`promoteOverrides` non-empty). Label: `Promote winner settings to the base index`.
  5. Footer: Cancel + Confirm. Confirm label `Concluding...` during in-flight.
- `data-testid="declare-winner-dialog"`.

### Detail — Conclude-save-error
- Declare-winner dialog stays open; inline `<p data-testid="declare-winner-error" role="alert">` above footer with server message. Form re-enabled; user can retry.

### Create-wizard — Step 1 (Basics)
- Purpose-built `CreateExperimentDialog` open with `title="Create Experiment"` and a `Step 1 of 4` indicator. Single panel shows: Name (text, required), Primary Metric (radio cards — one card per metric with description, e.g. `Conversion Rate — % of searches that lead to a conversion event`). Footer: Cancel + `Next`. `Next` disabled until name non-blank AND metric selected. (Re-uses ConfirmDialog overlay styles; not a configuration of EditorDialog.)

### Create-wizard — Step 2 (Variants)
- Panel shows: Control index label (read-only, set to current `index.name`). Variant mode toggle (`Mode A — query overrides` / `Mode B — separate index`).
  - Mode A: nested fields — `Enable synonyms` toggle, `Enable rules` toggle, `Filters` text input with placeholder + help text.
  - Mode B: `Variant index` `<select>` populated from `useIndexes()` filtered to `index.uid !== index.name` (cannot pick the same index as control). Renders inline red `role="alert"` `Variant index must differ from control` if violated.
- Footer: Back + `Next`. `Next` disabled until variant config valid (Mode B requires a non-control variant index).

### Create-wizard — Step 3 (Allocation)
- Panel shows: Traffic split slider (1-99, default 50). Minimum runtime days (number input, default 7). Live MDE runtime estimate table (`data-testid="runtime-estimate-table"`) with 4 rows at 2,400 searches/day baseline:
  - `Large lift (10%)` → ~X days
  - `Typical lift (5%)` → ~X days
  - `Small lift (2%)` → ~X days
  - `Mature optimization (1%)` → ~X days
  Recomputed live via `estimateRuntimeDays(baseDays, trafficSplitPercent)`. Shows `runtime-warning` chip when any row >90 days, `runtime-danger` chip when >365 days.
- Footer: Back + `Next`.

### Create-wizard — Step 4 (Review + UserToken Warning)
- Sky-blue `data-testid="user-token-warning"` callout: `Valid results require a stable userToken. Pass an authenticated user ID or server-side UUID, not a browser cookie. Browser-cookie-only IDs will inflate unique-user counts and bias results.`
- Review block: Name, Primary Metric (humanized), Variant mode + summary, Traffic split, Minimum runtime days.
- Footer: Back + `Create Experiment` (primary). Create disabled until all prior steps valid (defensive — should already be enforced by per-step `Next`).

### Create-wizard — Wizard-validation-error
- Per-step `Next` validation surfaces field-level errors inline beneath each invalid field (purpose-built validation; the wizard does NOT use EditorDialog's shared validation schema contract). The dialog stays on the current step.

### Create-wizard — Save-error
- `Create Experiment` submit returns server error: dialog stays on Step 4 with form-level `role="alert"` above footer (purpose-built error rendering; mirrors EditorDialog's Save-error visual treatment but is locally implemented in `CreateExperimentDialog`).

## Navigation

- List route: `/console/indexes/[name]?tab=experiments` (tab state preserved in URL query).
- Detail route: `/console/indexes/[name]/experiments/[experimentId]` (real SvelteKit route, deep-linkable, bookmarkable, refresh-safe, browser-back returns to list).
- Entry to list: `Index Detail` tab strip → `Experiments`.
- Entry to detail: clicking name in list (anchor, supports middle/cmd-click new tab). Also reachable from alerting emails and external links via the experiment URL.
- Back from detail: browser back → list. The on-screen `← Back to experiments` link is an `<a href>` not a `<button>`, so middle-click works.
- Wizard step transitions: Back / Next inside the dialog. Esc / Cancel / X trigger the purpose-built dirty-cancel-confirm flow inside `CreateExperimentDialog` (wires `ConfirmDialog` for the discard prompt; no silent data loss). Wizard step is dialog-local state — not URL-encoded (the dialog is ephemeral).
- Declare-winner success: dialog closes, detail page refetches `results`, transitions to Concluded state, conclusion summary card appears.
- Delete success: navigate to `/console/indexes/[name]?tab=experiments`. Stop success: stay on detail, transition to Stopped-pending-conclude state.

## Acceptance Criteria

- Given the list Populated state, when the user clicks `Stop` on a running experiment, then `ConfirmDialog` opens in typed-severe mode requiring the experiment name to be typed, and **no stop occurs** until Confirm is clicked (regression test for current no-confirm S2-1 footgun).
- Given the list Populated state, when the user clicks `Delete` on a stopped experiment, then `ConfirmDialog` opens in typed-severe mode requiring the experiment name, and **no delete occurs** until Confirm is clicked (regression test for S2-2).
- Given a concluded experiment with `results.conclusion.reason = "Rolled out B; mobile lift was 8%"`, when the user views the detail page, then the conclusion card renders that exact string — not `results.recommendation` (regression test for S1-3 wrong-field bug).
- Given a direct browser navigation to `/console/indexes/[name]/experiments/<id>`, when the page loads, then the correct experiment renders (deep-link works; refresh preserves the view; browser back returns to the list).
- Given the create wizard at Step 2 in Mode B, when the user opens the Variant Index `<select>`, then options exclude the current control index (cannot pick same-as-control); manual selection of same-as-control is impossible by construction.
- Given a results payload with `cupedApplied: true`, when the detail page renders, then the significance section header shows a `CUPED` badge adjacent to the title (and is absent when `cupedApplied: false`).
- Given a results payload with `interleaving` non-null and `dataQualityOk: true`, when the detail page renders, then the interleaving card renders with deltaAB, verdict label, p-value, and a 2×2 wins/ties grid (regression test for absent-row #12).
- Given `viewModel.outlierUsersExcluded === 12`, when the detail page renders, then a muted notice reads `12 users excluded as outliers (bot-like traffic patterns).`.
- Given a running experiment with `minimumNReached: true` and `minimumDaysReached: false`, when the user clicks `Declare Winner`, then a days-gate `ConfirmDialog` opens warning about novelty effect bias before the declare-winner dialog opens.
- Given the declare-winner dialog open on a Mode-A experiment with `queryOverrides = { enableSynonyms: true }`, when the dialog renders, then the `SettingsDiff` block shows that override AND the `Promote winner settings` checkbox is visible. Given a Mode-B-only experiment with no overrides, when the dialog renders, then the Promote checkbox is hidden (`canPromote === false`).
- Given the declare-winner submit returns a 500 error, when the response settles, then the dialog stays open with `data-testid="declare-winner-error"` rendering the server message, and the user can retry without retyping the reason.
- Given the create wizard at Step 3 with traffic split at 80/20, when the slider value changes, then the runtime estimate table recomputes live and the `Typical lift (5%)` row updates to reflect the asymmetric-split runtime extension (e.g. ~3.3× longer than 50/50).
- Given the create wizard at Step 4, when the user views the panel, then the `data-testid="user-token-warning"` callout is visible above the Review block (regression for absent userToken warning).
- Given a running experiment, when its variant index is deleted by another operator, then the detail page surfaces a guard-rail / SRM banner on next results refetch (not a silent NaN render); the underlying server load returns `variantIndexMissing: true` and the page renders an explicit `role="alert"` banner.

## Edge cases

- Variant index deleted while experiment is running: detail page renders an explicit error banner (`Variant index "<name>" no longer exists. Stop this experiment or restore the index.`), arm cards show `—` for variant, Declare Winner disabled.
- UserToken propagation failure (high `noStableIdQueries`): if `unstableIdFraction > 0.05`, render the unstable-token notice prominently above the arm cards so the data-quality issue blocks accidental conclusion.
- Partial concurrent conclude from another tab: detail page refetches on focus; if `status` flips to `concluded` mid-dialog, the declare-winner dialog closes with a `role="alert"` toast (`This experiment was concluded in another tab.`) and the page transitions to Concluded state.
- Very long experiment list (>50 rows): list paginates server-side at 25/page; URL gets `?page=N` query param so back-button restores the page. Count badge shows total across all pages.
- Results not yet available (just-created, no data): detail page renders the Created state — no arm cards, no significance card, single placeholder message + Start button.
- Server load fails for one experiment but not the list: list still renders; the failing row shows `—` in metric column with a tooltip `Results unavailable`. Clicking the name still navigates to detail, which shows the Error state.
- Mobile narrow (390px): list table columns collapse — Status + Actions stay; Metric + Traffic split + Started move into a per-row expandable row. Detail-page cards stack single-column; metric pills wrap.
- Wizard cancel with dirty state: per `CreateExperimentDialog`'s purpose-built dirty-cancel-confirm flow (which wires `ConfirmDialog` for the discard prompt), user must explicitly Discard or Keep editing — no silent data loss.

## Current Implementation Gaps

- Current: per-row Stop posts directly to `?/stopExperiment` with no confirmation — one click halts a running production experiment.
  Target: Stop opens `ConfirmDialog` (typed-severe, `typedPhrase = experiment.name`) per the List view Stop action.
  Evidence: `web/src/routes/console/indexes/[name]/tabs/ExperimentsTab.svelte:264-274`; [CRITICAL_BUGS.md S2-1](../audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/CRITICAL_BUGS.md), [audit row 2](../audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/tab_experiments.md).
- Current: per-row Delete posts directly to `?/deleteExperiment` with no confirmation — one click destroys historical analytics.
  Target: Delete opens `ConfirmDialog` (typed-severe) per List view Delete action.
  Evidence: `ExperimentsTab.svelte:276-285`; [CRITICAL_BUGS.md S2-2](../audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/CRITICAL_BUGS.md), [audit row 4](../audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/tab_experiments.md).
- Current: conclusion-summary card reads `results.recommendation` (the live computed string) instead of `results.conclusion.reason` (the human-supplied text).
  Target: render `results.conclusion.reason` per Layout #15 of the Detail view; surface `results.recommendation` separately in the live recommendation banner (Layout #5).
  Evidence: `ExperimentsTab.svelte:532`; [CRITICAL_BUGS.md S1-3](../audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/CRITICAL_BUGS.md), [audit "Conclusion summary card" row](../audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/tab_experiments.md).
- Current: detail view is in-place tab state mutation (`selectedExperimentId = abTestID`); no URL, no deep-link, no browser-back, no shareable link, name is a `<button>` not a link (no middle-click new-tab).
  Target: real SvelteKit route `/console/indexes/[name]/experiments/[experimentId]` with `+page.server.ts` server load; name renders as `<a href>`.
  Evidence: `ExperimentsTab.svelte:102-105,241-247,298-304`; [audit rows 5, 9](../audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/tab_experiments.md).
- Current: create flow is a flat inline form rendered below the table; no step indicator, no Next/Back, no runtime estimate table, no userToken warning, no Mode-B index `<select>` (free-text input only).
  Target: purpose-built `CreateExperimentDialog` 4-step wizard per Create-wizard states (re-uses ConfirmDialog overlay styles; NOT a configuration of EditorDialog); Mode-B uses a filtered `<select>` excluding control.
  Evidence: `ExperimentsTab.svelte:539-684`; [audit row 3, "Runtime estimate table", "User-token warning", "Mode-B variant index dropdown" rows](../audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/tab_experiments.md).
- Current: declare-winner dialog is an inline form (not a real `Dialog`), has no `SettingsDiff` preview, empty default reason, always-visible Promote checkbox (even when there's nothing to promote), no inline error display on submit failure, no days-gate guard.
  Target: full `Dialog` primitive per Detail — Declare-winner-dialog-open sub-state, with `SettingsDiff`, `defaultReason()`, conditional Promote checkbox, `declare-winner-error` rendering, and a days-gate `ConfirmDialog` wrapper.
  Evidence: `ExperimentsTab.svelte:136-168,459-512`; [audit row 14](../audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/tab_experiments.md).
- Current: interleaving card, mean-click-rank card, CUPED badge, outlier-users notice, unstable-userToken notice, live recommendation banner are all absent or partial despite the type fields being defined.
  Target: Detail view Layout items 5, 9 (CUPED badge), 11, 12, 13 per spec.
  Evidence: `ExperimentsTab.svelte` (no matches for `interleaving`, `meanClickRank`, `cupedApplied`, `outlierUsersExcluded`, `noStableIdQueries`); [audit "Interleaving card" / "Mean click rank" / "CUPED badge" / "Outlier-users" / "Recommendation banner" rows](../audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/tab_experiments.md).
- Current: arm metric cards omit `Revenue / Search` even though `revenuePerSearch` is in the type.
  Target: Layout item 8 lists Revenue / Search currency-formatted per arm.
  Evidence: `ExperimentsTab.svelte:325-370`; [audit row 8](../audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/tab_experiments.md).
- Current: per-row test IDs absent (`experiment-row-<id>`, `experiment-status-<id>`, `experiment-started-<id>`); only a `experiments-section` wrapper exists.
  Target: full test-id coverage per Layout (`experiments-table`, per-row IDs, detail-page IDs `experiment-detail-name|status|index|primary-metric`).
  Evidence: `ExperimentsTab.svelte:196,238`; [audit row 1, 6](../audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/tab_experiments.md).

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/index-detail.spec.ts`; `web/tests/e2e-ui/full/indexes.spec.ts`
- Component tests: `web/src/routes/console/indexes/[name]/detail-experiments.test.ts`
- Server/contract tests: `web/src/routes/console/indexes/[name]/detail.server.actions.test.ts`
