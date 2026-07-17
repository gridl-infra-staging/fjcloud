# EditorDialog Component Spec

## Scope

- Primary route: not route-bound; modal mounted within consumer tabs under `/console/indexes/[name]` (Rules, Synonyms, Recommendations, Personalization initially; later Dictionaries, SecuritySources, etc.)
- Related routes: parent tab routes that own the trigger button and the underlying resource collection
- Audience: authenticated customers creating or editing structured index resources
- Priority: P0 (foundation lane for Theme A — see [feature-parity audit](../audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/SUMMARY.md))

## User Goal

Create or edit one structured resource (synonym group, rule, recommendation config, personalization strategy, dictionary entry, security source, etc.) through model-driven form fields rather than by hand-writing JSON, with field-level validation and dirty-state protection on cancel.

## Target Behavior

`EditorDialog` is a single shared Svelte component that accepts a **field schema** (declarative model description) plus props and renders a modal with header, validated form body, and footer (Cancel + Save). The schema is the key abstraction: each consumer tab supplies its own schema and the dialog reuses one implementation for header chrome, focus management, validation pipeline, dirty tracking, error rendering, keyboard handling, and save lifecycle.

**Required props:**

- `title: string` — header text (e.g. `Create Rule`, `Edit Synonym: syn-film-movie`)
- `mode: 'create' | 'edit'` — controls primary-button label (`Create` vs `Save`) and may affect title styling
- `schema: FieldSchema[]` — ordered list of field definitions (see Field types below)
- `initialValue: Record<string, unknown>` — starting field values; in edit mode the existing record; in create mode the schema-defined defaults
- `open: boolean` — bound visibility (consumer owns the open/close state)
- `onSave: (value) => Promise<void>` — async; resolution closes dialog, rejection surfaces server error
- `onCancel: () => void` — called after the dirty-cancel confirm resolves (or immediately if not dirty)
- Optional: `description?: string` (subtitle under title), `submitLabel?: string` (override primary button text), `testId?: string` (component-level test handle; defaults to `editor-dialog`)

**Field types the schema must support:**

- `text` — single-line input; props: `required`, `pattern?`, `maxLength?`, `placeholder?`
- `textarea` — multi-line input; props: `required`, `maxLength?`, `rows?`
- `select` — single-choice dropdown; props: `required`, `options: {value, label}[]`
- `multiselect` — multi-choice (chips or checkbox list); props: `required`, `options`, `minItems?`, `maxItems?`
- `array` — dynamic list of one inner-item shape (the Add Word / Add Condition / Add Promoted Item pattern); props: `item: FieldSchema | GroupFieldSchema`, `minItems?`, `maxItems?`, `addLabel` (e.g. `Add Word`). The inner item can be a single simple field (one input per row, e.g. Add Word) OR a `group` with multiple named fields per row (used by Rules' Conditions / Consequences / Validity sub-sections — each row has e.g. `pattern` + `anchoring` + `context` together).
- `number` — numeric input; props: `required`, `min?`, `max?`, `step?`, `integer?`
- `toggle` — boolean switch; props: `default`
- `radio` — exactly-one of N options, rendered as labelled buttons (NOT a dropdown). Use when ~2-5 options and the caller wants each option visible at once, optionally with per-option descriptive text. Props: `required`, `options: {value, label, description?}[]`. Driver: Rules `Query Modification` mode, Experiments wizard Step 1 Primary Metric.
- `datetime-local` — HTML `<input type="datetime-local">`. Storage shape is the raw ISO-local string (e.g. `2026-01-15T08:30`); consumers convert to/from unix-seconds in their `initialValue`/`onSave` callbacks. The dialog itself is storage-agnostic. Props: `required`, `min?` (ISO-local), `max?` (ISO-local). Driver: Rules `validity` from/until rows.
- `group` — used ONLY as an array's `item`, never at the top level of `schema`. Defines a row shape for compound array fields: `{ type: 'group', fields: FieldSchema[] }`. Group children may not themselves be `array` or `group` (no nested compounds).

Each field carries `name`, `label`, `helpText?`, and optionally:

- `validate(value, allValues) => string | null` for field-level rules (returning `null` for valid, an error message string for invalid); cross-field rules ride the same hook via the `allValues` argument.
- `visible(allValues) => boolean` for conditional visibility — when false, the field is omitted from the rendered DOM AND from the save payload. Driver: Recommendations model picker, which hides `objectID` when the model is `trending-facets` and shows `facetName`/`facetValue` instead.

For group children, the `name` is the key within the row object; for top-level fields, the `name` is the key in the saved value object.

## Required States

- Untouched: dialog open, fields show `initialValue`, no validation messages visible, Save enabled if `initialValue` passes schema validation (edit mode) and disabled if any required field is blank (create mode default).
- Editing-valid: at least one field changed, all schema + custom validators pass, no field-level error text visible, Save enabled.
- Editing-invalid: at least one field changed, one or more validators failing, failing fields show error message in `role="alert"` adjacent to the field, Save disabled.
- Saving: Save button shows pending label (e.g. `Saving...`) and is disabled, Cancel disabled, all fields disabled, no spinner overlay; dialog cannot be dismissed via Esc/backdrop during this state.
- Save-error: `onSave` rejected; form re-enables, server error rendered in a form-level `role="alert"` region above the footer; field-level errors (if returned by the server as a per-field map) attach to their named fields and Save remains disabled until the user edits the offending field.
- Dirty-cancel-confirm: user attempted to dismiss (Cancel / X / Esc / backdrop) while form is dirty; inline confirm prompt (`Discard unsaved changes?` with `Discard` and `Keep editing` buttons) replaces the footer until resolved. `Keep editing` returns to the prior editing state; `Discard` calls `onCancel`.
- Closed: dialog unmounted, focus returned to the trigger element that opened it.

## Mobile Narrow Contract

Baseline viewport: 390px wide (iPhone 14). Dialog must:

- Fill viewport width minus 16px padding; max-height 90vh with scrollable body.
- Header, footer pinned (non-scrolling); only the form body scrolls.
- Footer buttons full-width stacked (Cancel above or below Save per design tokens) when horizontal layout would overflow.
- All field controls and the close X remain reachable without horizontal scroll; long option labels in selects truncate with ellipsis but full text is in the option's `title` attribute.

## Controls And Navigation

- Mount: consumer renders a trigger button (typically `Add X` in the tab header, or `Edit` per-row action). Trigger click sets `open=true` and seeds `initialValue`.
- Header close X (`data-testid="editor-dialog-close"`) follows dirty-cancel-confirm flow.
- Footer Cancel (`data-testid="editor-dialog-cancel"`) follows dirty-cancel-confirm flow.
- Footer Save (`data-testid="editor-dialog-save"`) invokes `onSave(currentValue)`; label is `Create` (create mode) or `Save` (edit mode) unless `submitLabel` overrides.
- Esc key triggers the same path as Cancel; backdrop click triggers the same path.
- Focus on open: first field by schema order receives focus.
- Focus on close: returns to the element that triggered the open (consumer's responsibility to wire, but the component must support it via standard dialog primitives).
- Tab cycles through fields then footer buttons; Shift+Tab reverses. Focus trap is mandatory: Tab from the last footer button returns to the close X.
- Enter inside a single-line input submits the form (equivalent to clicking Save) only when the form is in `Editing-valid`. Enter inside a `textarea` inserts a newline (does not submit).
- Dialog uses `role="dialog"`, `aria-modal="true"`, `aria-labelledby` pointing to the title, and `aria-describedby` pointing to the description (if present). Each field error message has `role="alert"` and is associated with its field via `aria-describedby`.

## Acceptance Criteria

- [ ] Given a consumer tab with an `Add X` button, when the user clicks it, then `EditorDialog` opens with `role="dialog"`, `aria-modal="true"`, and focus on the first field.
- [ ] Given an open dialog in create mode, when the user has not touched any required field, then Save is disabled.
- [ ] Given an open dialog, when the user enters an invalid value (fails schema or custom validator), then the field shows a `role="alert"` error message and Save is disabled.
- [ ] Given an open dialog with all fields valid and at least one changed, when the user clicks Save, then `onSave` is invoked with the current field values and the Save button shows the pending label.
- [ ] Given a save in flight, when the dialog is in the Saving state, then Esc and backdrop click do not close the dialog and all form controls are disabled.
- [ ] Given `onSave` rejects with a server error, when the rejection settles, then a form-level `role="alert"` shows the error and the form re-enables for further editing.
- [ ] Given the form is dirty (user changed any field), when the user clicks Cancel/X/Esc, then a `Discard unsaved changes?` confirm replaces the footer until the user picks `Discard` or `Keep editing`.
- [ ] Given the form is not dirty, when the user clicks Cancel/X/Esc, then the dialog closes immediately with no confirm.
- [ ] Given the dialog is open, when the user presses Tab from the last focusable element, then focus returns to the first focusable element (focus trap).
- [ ] Given the dialog closes (via Save success, Discard, or non-dirty cancel), then keyboard focus returns to the trigger element that opened it.
- [ ] Given a schema with an `array` field with `addLabel: "Add Word"`, when the user clicks the add control, then a new empty item appears and receives focus; given the array has more than `minItems`, when the user clicks the per-item remove control, then that item is removed.

## Visual contract

Target `EditorDialog` visual treatment is the shared console modal surface: a `bg-flapjack-cream` page overlay, centered white `rounded-lg` dialog panel, `text-flapjack-ink` heading/body copy, `border-flapjack-ink/15` section dividers, and `shadow`/`shadow-elevation-card` depth consistent with console cards and CTAs. The close affordance is a compact secondary control; Cancel uses secondary bordered styling; Save uses the primary `bg-flapjack-rose text-white hover:bg-flapjack-plum` button treatment.

Form controls inherit the console input pattern: `rounded-md` or `rounded` borders in `border-flapjack-ink/30`, `focus:border-flapjack-rose`, `focus:ring-flapjack-rose`, muted help text in `text-flapjack-ink/60` or `/80`, and validation/server alerts in `text-flapjack-plum` on `bg-flapjack-rose/10` with a `border-flapjack-rose/35` callout when a form-level error is present. Array rows, grouped fields, radio options, and multiselect controls use the same border, spacing, and selected-state vocabulary as shipped console forms.

At 390px, the dialog panel stays within the viewport with a scrollable body, pinned header/footer, reachable close control, and stacked footer actions when horizontal buttons would overflow. Implementation evidence: `web/src/app.css` owns the Flapjack palette and shadow tokens; `web/src/lib/components/EditorDialog.svelte` owns the shared dialog behavior and current markup.

## Current Implementation Gaps

- Current: `web/src/lib/components/EditorDialog.svelte` now exists and owns schema-driven behavior, focus management, validation, save state, dirty-cancel confirmation, and `role="dialog"` markup, but the dialog/backdrop/form elements still render as bare wrapper elements with no Tailwind classes or shared visual tokens.
- Target: `EditorDialog.svelte` applies the shared console modal visual treatment described above while preserving its existing schema-driven dispatcher, then is consumed by the 4 Theme A tabs and later Dictionaries, SecuritySources, Suggestions, and Experiments-create.
- Evidence: [feature-parity audit Theme A and recommendation 2](../audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/SUMMARY.md); upstream references `flapjack_dev/engine/dashboard/src/pages/RuleEditorDialog.tsx`, `engine/dashboard/src/components/indexes/CreateIndexDialog.tsx`, `engine/dashboard/src/pages/dictionaries/DictionaryEntryDialog.tsx`, `engine/dashboard/src/pages/security-sources/SecuritySourceDialog.tsx`.

## Edge Cases

- Network failure mid-save: `onSave` rejection enters Save-error state; the in-flight values are preserved; the user can retry without re-entering data.
- Server-side validation rejects a save the client passed: server-returned per-field error map attaches errors to their named fields; if the server returns only a generic error, it shows in the form-level alert; in both cases Save stays disabled until the user edits a field (clearing the per-field stale errors that overlap the edit).
- Schema mismatch from server (edit mode): when `initialValue` contains keys not present in the schema, the dialog preserves those keys in the save payload (passthrough) so legacy fields are not silently dropped; when the schema requires a key the `initialValue` is missing, the field renders with its schema default.
- Very long content (e.g. 50KB synonym list pasted into a `textarea`): the body scrolls within the dialog's max-height; the field itself uses its `maxLength` if set; Save remains enabled if validators pass.
- Concurrent edit by another user: out of scope for this component (no optimistic-locking UI); a stale-write rejection from the server surfaces via the standard Save-error path with the server's message.
- Open with no fields changeable (all schema fields disabled by a future `readonly` flag): Save is disabled, only Cancel/close is available.

## Automated Coverage

- Component tests: `web/src/lib/components/EditorDialog.test.ts` (new) — covers schema-driven rendering for each field type, validation transitions across all six non-closed states, focus trap, Esc/backdrop dirty-confirm flow, save lifecycle including server-error path.
- Browser-mocked tests: `web/tests/e2e-ui/mocked/editor_dialog.spec.ts` (new) — covers Saving-state non-dismissal and Save-error rendering using mocked server failures that are hard to produce deterministically against the real backend.
- Browser-unmocked tests: exercised transitively via consumer tab specs (`web/tests/e2e-ui/full/{rules,synonyms,recommendations,personalization}.spec.ts` per recommendations 5/6/7/8); the consumer specs assert end-to-end create/edit flows that drive the dialog.

## Open Design Questions

- Headless library choice: upstream uses Headless UI + Radix Dialog. fjcloud's existing dialog precedent is unverified at spec time — implementation lane must pick between `bits-ui` (Svelte-native, matches shadcn-svelte), `melt-ui`, or hand-rolled focus-trap + portal. Flag for implementation lane.
- Validation timing: schema-described validators may run on every keystroke vs on blur vs on submit. Spec assumes on-blur for field-level and on-change for form-level Save-enabled gating; confirm during implementation that this matches the responsiveness/jitter trade-off the design lane wants.
- Server per-field error contract: each consumer's backend `onSave` may shape errors differently (HTTP 422 with `{errors: {fieldName: message}}` vs flat string). Implementation lane must define one normalized shape that consumers map into before rejecting their `onSave` promise.
