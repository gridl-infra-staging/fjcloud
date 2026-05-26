# Indexes

## Task

View existing indexes, create a new index optionally seeded from a demo template (Movies / Products) so the user can immediately try the search experience, and delete indexes safely.

## Layout

### List view (`/console/indexes`)

1. Page heading `Indexes` and a primary `Create Index` button (top-right) that opens `[CreateIndexDialog]`.
2. Quota-exceeded callout (when applicable) with link to `/console/billing`.
3. Form-result error callout (when applicable, `role="alert"`).
4. Success callout `Index created successfully.` (when applicable, after create completes).
5. Indexes table with columns: `Name` (link to detail), `Region`, `Status` (badge), `Entries`, `Data Size`, `Created`, per-row `Delete` button.
6. Empty-state card (when no indexes): `No indexes yet — create your first one.`

### `[CreateIndexDialog]`

A modal dialog (specialized instance of `[EditorDialog]`; see `_component_EditorDialog.md`) with:

1. Title `Create Index` + subtitle `Create a new search index to start adding documents.`
2. Template picker (radio group, vertical stack):
   - `Empty index` — `Start from scratch — add your own documents later.`
   - `Movies — 1,000 docs` — `Search by title/director, filter by genre, includes 8 synonyms & 2 merchandising rules.`
   - `Products — 1,000 docs` — `E-commerce demo with facets, 8 synonyms & 2 merchandising rules.`
3. `Index name` text input (autofocus). Prefilled from selected template (`movies`, `products`) when non-Empty; cleared when Empty. User-editable afterward.
4. `Region` radio group sourced from `data.regions`; defaults to first region.
5. Inline validation message area (`role="alert"`) for name-format errors and duplicate-name errors.
6. Footer: `Cancel` (secondary, dismisses dialog) and primary submit button whose label depends on template: `Create Index` (Empty) or `Create & Load movies` / `Create & Load products`.

## State contract

### Loading-list
- Route load resolves before render; no spinner state expected. If load fails, fall through to Error-list.

### Empty-list
- Empty-state card visible. `Create Index` button remains primary action. No table, no row actions.

### Error-list
- Load returned no rows AND a server error is signaled: render error callout above the empty-state card. `Create Index` remains enabled (creation is a separate code path).

### Populated-list
- Table renders one row per index. Each row links the name cell to `/console/indexes/[name]`. `Delete` per row opens `[ConfirmDialog]`.

### Quota-exceeded
- Yellow callout `You've reached your free plan index limit.` with link to upgrade. `Create Index` button remains visible but submitting from the dialog re-surfaces the same callout on return.

### Create-dialog-closed
- Dialog hidden. List view fully interactive. No dialog state retained between opens (template resets to Empty, name cleared, region reset to default).

### Create-dialog-template-empty-untouched
- Empty radio selected; `Index name` empty; submit button labeled `Create Index`; submit disabled while name empty.

### Create-dialog-template-empty-typing
- User has typed a name. Submit enabled when name passes client-side `/^[a-zA-Z0-9_-]+$/` regex AND is not a duplicate of an existing index. Otherwise inline `role="alert"` message visible (`Only letters, numbers, hyphens, and underscores allowed` or `An index named "<name>" already exists`).

### Create-dialog-template-movies-selected
- Movies radio selected; `Index name` prefilled with `movies` (user may edit). Submit button labeled `Create & Load movies`. Region picker active.

### Create-dialog-template-products-selected
- Products radio selected; `Index name` prefilled with `products` (user may edit). Submit button labeled `Create & Load products`. Region picker active.

### Create-dialog-creating
- Submit button disabled and labeled `Creating...` (Empty template) or `Configuring & loading...` (Movies/Products). Cancel disabled. Template and name fields disabled. Dialog cannot be dismissed by Escape or backdrop click during this state.

### Create-dialog-seed-error
- Submit re-enabled. Error callout inside dialog (`role="alert"`) names what completed and what failed: e.g. `Index created, but seeding failed at: synonyms. Delete this index and retry, or open it to inspect partial state.` Dialog remains open so the user can retry or cancel.

### Create-success-banner-on-detail
- After successful create (including full seed for Movies/Products), the dialog closes and the route navigates to `/console/indexes/[name]?welcome=1`. The detail page shows a one-time banner: `Index ready — try the search preview` with a link to the `SearchPreview` tab. Banner dismissable; suppression persists across reloads via the `?welcome=0` query param convention.

### Delete-confirm-open
- `[ConfirmDialog]` (see `_component_ConfirmDialog.md`) renders with title `Delete index "<name>"?`, body explaining the destructive nature, a text input requiring the user to type the exact index name to confirm, and `Cancel` / `Delete` buttons. `Delete` disabled until typed name matches exactly.

### Delete-in-flight
- Delete button labeled `Deleting...` and disabled. Cancel disabled. Confirm dialog cannot be dismissed.

### Delete-error
- Confirm dialog stays open with an inline `role="alert"` error message naming the failure (`Failed to delete index: <reason>`). User can retry or cancel.

## Navigation

- Route: `/console/indexes`
- Entry: `Indexes` link in the console sidebar (primary nav).
- Back: browser back from a detail page returns to the list with table state preserved (no client-side cache to invalidate).
- Row click (name cell): navigates to `/console/indexes/[name]` detail page.
- Create success: navigates to `/console/indexes/[name]?welcome=1` (triggers Create-success-banner-on-detail).
- Quota-exceeded callout link: navigates to `/console/billing`.
- Delete success: stays on `/console/indexes` and re-runs `load` so the row disappears.

## Acceptance Criteria

- Given a populated list, when the page loads, then the seeded index appears in the table with exact name, region, status, entries, data size, and created date.
- Given the dialog is closed, when the user clicks `Create Index`, then `[CreateIndexDialog]` opens with Empty template selected, empty name field, and default region selected.
- Given the dialog is open with Movies selected, when the user clicks submit, then within 30s the new index exists, has settings configured (`searchableAttributes` includes `title`/`overview`/`director`, `attributesForFaceting` includes `genre`/`director`/`year`), contains ≥1,000 documents, has 8 synonyms and 2 merchandising rules, and the user is on `/console/indexes/movies?welcome=1`.
- Given a Movies create succeeds, when the user navigates to `SearchPreview`, then within 10s the search box returns hits and facet pills for `genre`, `director`, and `year` render.
- Given a Products create succeeds, when the user lands on the detail page, then the `Index ready — try the search preview` banner is visible and links to the `SearchPreview` tab.
- Given the dialog is open with Movies selected, when the user clears and re-types `my-movies` in the name field, then submit uses the edited name (the prefill is a starting value, not a lock).
- Given a duplicate index name typed in the dialog, when the user attempts submit, then an inline `role="alert"` message names the conflict and submit is blocked client-side without a server round-trip.
- Given an index seed fails mid-flight at synonyms, when the server returns an error, then the dialog re-enables with an error message naming the failed step, and the partial index is still visible in the list (no silent rollback).
- Given a populated list, when the user clicks Delete on a row, then `[ConfirmDialog]` opens requiring the user to type the exact index name; `Delete` stays disabled until the typed value matches.
- Given the typed-confirmation matches, when the user clicks Delete, then the row disappears from the list within 5s and no `window.confirm` prompt is shown.
- Given quota is exhausted, when the user submits the dialog, then the dialog closes (or stays open with a quota-exceeded error inside it) and the list view shows the quota callout with an upgrade link.

## Edge cases

- Network failure during create (before index creation): dialog stays open, error callout shows `Failed to create index: <reason>`, user can retry.
- Network failure mid-seed (after index created, before documents/synonyms/rules applied): dialog surfaces Create-dialog-seed-error with the named failed step; the user must either retry from the detail page (manual reseed not yet specced) or delete the partial index and start over.
- Quota exhaustion mid-seed: treat as Create-dialog-seed-error with reason `quota_exceeded`; the partial index counts against quota until deleted.
- Template doc count mismatch (template advertises 1,000 docs but seed payload returns fewer): the seed completes with the actual count; no client-side enforcement of doc-count parity (server payload is the SSOT). Acceptance criterion checks `≥1,000` not `==1,000` to absorb future template growth.
- User reloads the page mid-seed: the create POST has already started server-side; the user lands on the list view, may see the index in `provisioning` status, and can navigate to its detail page where the banner will not show (no `?welcome=1` query param on direct navigation).
- User cancels the dialog after submit has started: cancel is disabled during Create-dialog-creating to prevent orphaned seeds.
- Empty `data.regions` array (region API failed and fallback returned empty): submit button disabled with helper text `No regions available — please retry later.`
- First-time user (zero indexes) closing the dialog: empty-state card remains; no banner state to clear.

## Current Implementation Gaps

The shipped W3.1 implementation is name-only template prefill. The dialog primitive, atomic seeding, post-create banner, and typed-confirmation delete are all not yet wired.

- Current: template radios prefill `indexName` only; server `create` action ignores any `template` form field and accepts only `name` + `region`.
- Target: server accepts `template_id ∈ {empty, movies, products}`, creates the index, applies settings, uploads ≥1,000 documents, saves synonyms, saves rules, all before returning success.
- Evidence: `web/src/routes/console/indexes/+page.svelte:140-167` (template radios with `defaultName` only); `web/src/routes/console/indexes/+page.server.ts:42-58` (create action reads only `name` + `region`); audit extension Theme D at `docs/audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/SUMMARY.md` (Recommendation 4: demo-loader + SearchPreview coupled lane); parent audit at `docs/audits/feature-parity/20260524T174411Z_fjcloud_vs_engine_dashboard/SUMMARY.md:255-261` (Recommendation 1: demo-index-loader P0).

- Current: create form is an inline expandable section toggled by `showCreateForm`.
- Target: create form is a modal `[CreateIndexDialog]` (specialized `[EditorDialog]`) matching upstream `flapjack_dev/engine/dashboard/src/components/indexes/CreateIndexDialog.tsx`.
- Evidence: `web/src/routes/console/indexes/+page.svelte:107-208` (inline form pattern).

- Current: per-row Delete uses `window.confirm(...)`.
- Target: Delete opens `[ConfirmDialog]` with typed-confirmation requiring the exact index name.
- Evidence: `web/src/routes/console/indexes/+page.svelte:278-282` (inline `onclick` handler with `confirm()`); audit extension Theme B at `docs/audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/SUMMARY.md` (destructive-action ConfirmDialog primitive).

- Current: success path shows a generic `Index created successfully.` callout above the still-open list; user must manually navigate into the new index.
- Target: success path navigates to `/console/indexes/[name]?welcome=1` and shows the `Index ready — try the search preview` banner with a link to the `SearchPreview` tab.
- Evidence: `web/src/routes/console/indexes/+page.svelte:128-134` (current success callout); no post-create navigation or banner anywhere in the route.

- Current: no template metadata visible in the radio cards beyond `label` + one-line `description`.
- Target: each non-Empty template card displays seed-content preview text matching the dialog layout above (doc count + facet attributes + synonym count + rule count).
- Evidence: `web/src/routes/console/indexes/+page.svelte:32-54` (current `indexTemplates` array).

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/indexes.spec.ts`; `web/tests/e2e-ui/smoke/indexes.spec.ts` (must be extended to cover the Movies + Products end-to-end seed-then-search flow per the `SearchPreview` spec).
- Component tests: `web/src/routes/console/indexes/indexes.test.ts`; `web/src/routes/console/indexes/indexes.server.test.ts`.
- Server/contract tests: `web/src/routes/console/indexes/indexes.server.test.ts` (must be extended to cover `template_id` handling, partial-seed error surfaces, and atomic-vs-partial rollback semantics).
