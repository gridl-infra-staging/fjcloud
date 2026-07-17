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

### Create-success-detail

- After successful create (including full seed for Movies/Products), the dialog closes and
  the route navigates to the canonical `/console/indexes/[name]` URL. The detail page does
  not render a redundant success banner or `Open Search` CTA; create feedback uses the
  shared toast surface and Search remains available in the tab list.

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
- Create success: navigates to canonical `/console/indexes/[name]` with no one-time query
  marker.
- Quota-exceeded callout link: navigates to `/console/billing`.
- Delete success: stays on `/console/indexes` and re-runs `load` so the row disappears.

## Acceptance Criteria

- Given a populated list, when the page loads, then the seeded index appears in the table with exact name, region, status, entries, data size, and created date.
- Given the dialog is closed, when the user clicks `Create Index`, then `[CreateIndexDialog]` opens with Empty template selected, empty name field, and default region selected.
- Given the dialog is open with Movies selected, when the user clicks submit, then within 30s the new index exists, has settings configured (`searchableAttributes` includes `title`/`overview`/`director`, `attributesForFaceting` includes `genre`/`director`/`year`), contains ≥1,000 documents, has 8 synonyms and 2 merchandising rules, and the user is on `/console/indexes/movies`.
- Given a Movies create succeeds, when the user navigates to `/console/indexes/movies?tab=search`, then no request runs until submission; after submitting a known query, exact facet panels `genre`, `director`, and `year` render from the settings read back from the API.
- Given a Products create succeeds, when the user lands on the detail page, then no redundant `Index ready` banner or `Open Search` button is present and the Search tab remains visible.
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
- User reloads the page mid-seed: the create POST has already started server-side; the user
  lands on the list view, may see the index in `provisioning` status, and can navigate to
  its canonical detail URL.
- User cancels the dialog after submit has started: cancel is disabled during Create-dialog-creating to prevent orphaned seeds.
- Empty `data.regions` array (region API failed and fallback returned empty): submit button disabled with helper text `No regions available — please retry later.`
- First-time user (zero indexes) closing the dialog: empty-state card remains; no banner state to clear.

## Visual contract

The indexes list uses the shipped console list/table treatment: a `mb-6 flex items-center justify-between` header with `text-2xl font-bold text-flapjack-ink` title and rose/plum primary `Create Index` action; quota and form-error callouts above the content with yellow or rose bordered backgrounds; a white `rounded-lg p-12 text-center shadow` empty card; and a white `rounded-lg shadow` table with cream uppercase header row, divided body rows, rose/plum linked index names, status badges from `indexStatusBadgeColor`, muted ink metadata, and bordered rose delete actions.

`CreateIndexDialog` is the target create surface for this screen. Its shipped form treatment is a white `rounded-lg bg-white p-6 shadow` panel with `text-flapjack-ink` heading/body copy, yellow/rose callouts, selected template/region cards in `border-flapjack-mint bg-flapjack-mint/25`, unselected cards in `border-flapjack-ink/20`, rounded inputs with rose focus states, and rose primary plus bordered secondary footer actions.

At 390px, the page header can stack or wrap without hiding the create action, callouts remain above the table/form, template and region card grids collapse to fit the viewport, and table overflow stays contained rather than forcing page-wide horizontal scroll. Implementation evidence: `web/src/routes/console/indexes/+page.svelte` owns the list header/callouts/empty/table/delete row action; `web/src/routes/console/indexes/CreateIndexDialog.svelte` owns the current create-form visual tokens.

## Current Implementation Gaps

None verified for the Movies-to-Search workflow. The browser-unmocked owner proves template
ordering through the customer flow, exact settings readback, standard facet counts, and a
known-object refinement.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/indexes.spec.ts` and
  `web/tests/e2e-ui/full/demo_loader_end_to_end.spec.ts` for Movies seed, settings readback,
  and exact Search results; `web/tests/e2e-ui/smoke/indexes.spec.ts` owns the list smoke path.
- Component tests: `web/src/routes/console/indexes/indexes.test.ts`; `web/src/routes/console/indexes/indexes.server.test.ts`.
- Server/contract tests: `web/src/routes/console/indexes/indexes.server.test.ts` covers
  `template_id` validation, ordered seed phases, bare/empty creation, create conflicts, and
  each partial-seed error surface with its exact `partialIndexName` contract.
