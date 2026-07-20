# Migrate Screen Spec

This file is the normative target contract for `/console/migrate`. The internal
workflow rationale is `docs/design/2026_07_18_batch_10_algolia_migration_workflow.md`;
because `docs/design/` is not synced by `.debbie.toml`, public-mirror consumers
must use this file as the complete screen-state source of truth.

## Task

Import one Algolia primary index into a new fjcloud index without persisting the
Algolia credentials.

## Layout

1. Header: `Migrate from Algolia`, one-line status copy, and no navigation tabs.
2. Provider step: destination provider/region summary and eligibility result.
3. Connect step: Algolia Application ID, temporary API key, dashboard key
   instructions, and `Connect to Algolia`.
4. Source step: search input, paginated source-index list, metadata row for each
   loaded source, and selected-source summary.
5. Destination step: editable destination index name seeded from the source name,
   validation message, and target eligibility refresh status.
6. Review step: exact source, destination, scope, quota/admission summary, and
   `Start import`.
7. Recent imports: compact list with status, source, target, updated time, reopen
   link, empty state, error state, and pagination. It must not hide or block the
   create workflow when the list fails.

## State Contract

### Loading

- The route-level availability load renders a bounded loading state. Dormant
  component fixtures render loading rows for provider eligibility, source
  discovery, target eligibility, job submission, and recent imports.

### Error

- Provider/target eligibility errors render typed messages and retry controls.
- `migration_provider_unsupported` says the current create flow supports only
  configured AWS-backed regions; it does not render credential fields.
- Source discovery errors clear any stale catalog, show the producer error, and
  retry from the first page.
- Recent-import errors leave the create flow visible and expose a retry control.
- Capability-gated lifecycle controls fail closed: absent, omitted, or `false`
  `cancel`, `resume`, or `replace` capabilities hide those controls; `true`
  enables only the matching UI action if the job state also allows it.

### Shipped Unavailable

- Direct authenticated visits render the unavailable explanation loaded from
  `GET /migration/algolia/availability`.
- The page renders no form actions, Algolia App ID field, API key field, source
  controls, target controls, import CTA, dormant component mount, or migrate nav
  link.

### Provider Eligibility

- Provider eligibility is credential-free and runs before Algolia fields are
  visible.
- Success is bound to customer, mode `create`, provider, and region.
- Stale, tampered, cross-customer, provider-change, or region-change fixtures
  invalidate the result and hide credential fields until refreshed.

### Connect To Algolia

- The customer enters an Algolia Application ID and temporary API key only after
  provider success.
- Instructions tell the customer to create a temporary Algolia key with
  `listIndexes`, `browse`, and `settings`; add `seeUnretrievableAttributes` only
  when the source uses unretrievable attributes; restrict indices as narrowly as
  the source index or source-pattern choice allows; set validity long enough for
  the projected import; and delete the key after completion or failure.
- Copy must state that fjcloud zeroizes its in-memory copy but cannot revoke the
  vendor key in Algolia.
- A browser refresh, component remount, reconnect, or retry that needs source
  credentials starts with a blank key field.

### Source Selection

- `Connect to Algolia` calls `ApiClient.listAlgoliaSourceIndexes` with the live
  App ID/key and optional cursor only.
- Source pagination is lazy, retryable, bounded below the proxy timeout, and
  client-searchable over loaded pages.
- Each row shows name, record count, source size, updated date, optional last
  build seconds, and primary/replica type.
- Replica migration copy is not normative until an engine translation owner
  proves the exact replica contract. The UI may label `Primary` or
  `Replica of <primary>` from the source DTO but must not claim replica topology
  behavior.

### Destination

- Selecting a source displays the exact source name and seeds an editable
  destination proposal.
- The proposal must be deterministic, valid under `web/src/lib/index-name.ts`,
  preserve user edits until the source changes, and never consult a client-side
  destination catalog.
- Target eligibility is credential-free and bound to customer, mode, provider,
  region, destination name, and routing generation. Source changes, user edits,
  provider/region/routing changes, and expiry invalidate only final eligibility
  and block submit until refresh.
- Same-tenant conflicts and quota refusals come only from producer eligibility
  or job admission responses; equal names in other tenant fixtures are allowed.

### Review And Start

- Review shows exact source, destination, scope, and quota/admission summary.
- Start sends one `ApiClient.createAlgoliaImportJob(request, idempotencyKey)`
  call through the existing client, disables duplicate submit immediately, reuses
  the same idempotency key for retries of the same intent, and creates a new key
  only after the user changes source, destination, mode, or target eligibility.
- Success emits one future navigation request to `/console/migrate/[jobId]`.

### Recent Imports

- Owner: the tenant-owned retained jobs page from
  `ApiClient.listAlgoliaImportJobs`.
- Loading: show a compact loading row inside `data-testid="migration-recent-imports"`;
  the create workflow remains visible.
- Empty: show a compact empty row saying no imports have run yet; the create
  workflow remains visible.
- Error: show a retryable list error; the create workflow remains visible and
  usable if its own prerequisites are satisfied.
- Populated: rows show status, source name, destination target, updated time, and
  a customer-owned reopen link to `/console/migrate/[jobId]`.
- Pagination: `nextCursor` loads the next retained page without clearing already
  visible rows until the next page succeeds.
- Terminal rows: `completed`, `completed_with_warnings`, `failed`, and
  `cancelled` remain visible and reopenable; they do not imply a fresh create
  action is blocked.

### Credential Containment

- Algolia credentials may appear only as live input values and in credential
  bearing source-list/create request bodies.
- They must never appear in SSR/load data, URLs, localStorage, sessionStorage,
  form-history serialization, logs, analytics, non-input text or attributes, page
  HTML, or state that survives component destruction.

### Loading, Focus, And Keyboard

- Initial route loading focuses no hidden controls and announces only the
  unavailable or loaded state that is actually rendered.
- Provider, source, target, submit, and recent-import reload buttons are standard
  buttons reachable in DOM order; Enter in text inputs does not bypass the
  current step's primary button or idempotency guard.
- Validation errors set `aria-describedby` on the affected input and move focus
  to the first actionable error summary only after the failed user action.
- Retry controls preserve the user's non-secret selections when safe; any retry
  that needs Algolia credentials starts with the API-key field blank.

## Navigation

- Route: `/console/migrate`
- Current entry: authenticated direct visit only; console navigation must not
  advertise migration while the served page is unavailable.
- Target entry: future console navigation after route activation.
- Start success: future navigation to `/console/migrate/[jobId]`.
- Reopen: Recent-import rows link to future `/console/migrate/[jobId]` detail
  pages owned by the retained job contract.
- Browser back from in-progress create state returns to the previous console
  page; if a future mounted flow has unsent credentials, leaving destroys them
  without persistence.

## Acceptance Criteria

- [ ] Given the shipped route is unavailable, direct visits render the
      unavailable explanation and no migration controls.
- [ ] Given AWS provider eligibility succeeds, credential fields become visible;
      given unsupported or invalid provider eligibility, credential fields remain
      hidden.
- [ ] Given credentials are entered, source discovery sends exactly the live
      App ID/key to `listAlgoliaSourceIndexes` and never persists either value.
- [ ] Given loaded sources, source rows render exact metadata and client-side
      search/pagination behavior without refetching for search.
- [ ] Given a selected source, the exact source name remains visible and the
      destination proposal is valid, editable, deterministic, and advisory only.
- [ ] Given target eligibility is stale, expired, or bound to an old source,
      destination, provider, region, or routing generation, submit is blocked
      until refresh.
- [ ] Given review submit is activated twice, exactly one create request is
      emitted for that intent and the stable idempotency key is reused on retry.
- [ ] Given any credential canary, it appears only in the two live inputs and
      credential-bearing request bodies.

## Edge Cases

- Empty source catalog: show an empty state, not a failure.
- Later source page fails: clear stale rows and retry from the first page.
- Credentials edited after a catalog loads or while discovery is in flight:
  hide the catalog, selection, cursor, and destination until reconnect.
- Over-64-character, Unicode, punctuation, reserved-name, and boundary-character
  source names: proposal remains valid and user-editable.
- Operational pause or backpressure after route activation: preserve route,
  help, recent imports, reopen/status, and cancel presentation; disable fresh
  start/resume with typed reason and retry-after.

## Mobile Narrow Contract

- Baseline width: 390px.
- Steps stack vertically with full-width inputs and buttons.
- Source metadata wraps within each row without horizontal scrolling.
- Review rows use label/value stacking rather than side-by-side columns.
- Recent imports show status, source, target, and updated time in one vertical
  row per job.

## Current Implementation Gaps

- Current: `/console/migrate` renders only the unavailable explanation.
  Target: mounted provider-gated create flow and recent imports.
  Evidence: `web/src/routes/console/migrate/+page.svelte` and
  `web/src/routes/console/migrate/migrate.test.ts`.
- Current: public `ApiClient` intentionally exposes availability and source
  discovery plus destination eligibility and retained job create/list/get/cancel/resume.
  Target: `/console/migrate` still does not mount the connected workflow until
  presentation activation.
  Evidence: `web/src/lib/api/client-migration.test.ts`,
  `infra/api/src/router/route_assembly.rs`, and
  `infra/api/tests/integration/migration_routes_test/discovery.rs`.
- Current: replica topology copy is not specified.
  Target: exact replica behavior only after a bounded engine translation owner
  is cited and tested.
  Evidence: `docs/design/2026_07_18_batch_10_algolia_migration_workflow.md`.

## Automated Coverage

- Browser-unmocked current unavailable proof:
  `web/tests/e2e-ui/full/migration-recovery.spec.ts`.
- Route component proof:
  `web/src/routes/console/migrate/migrate.test.ts`.
- Route server proof:
  `web/src/routes/console/migrate/migrate.server.test.ts`.
- Dormant create component proof:
  `web/src/lib/components/migration/MigrationCreateFlow.test.ts`;
  `web/src/lib/components/migration/MigrationCreateFlowProvider.test.ts`;
  `web/src/lib/components/migration/MigrationCreateFlowDestination.test.ts`;
  `web/src/lib/components/migration/MigrationAdmission.test.ts`;
  `web/src/lib/components/migration/RecentImports.test.ts`;
  `web/src/lib/components/migration/ImportJobDetail.test.ts`.
- API client proof:
  `web/src/lib/api/client-migration.test.ts`.
