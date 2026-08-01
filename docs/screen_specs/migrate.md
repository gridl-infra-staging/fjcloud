# Migrate Screen Spec

This file is the normative target contract for `/console/migrate`. The internal
workflow rationale is `docs/design/2026_07_26_source_migration_architecture_decision.md`;
because `docs/design/` is not synced by `.debbie.toml`, public-mirror consumers
must use this file as the complete screen-state source of truth.

## Task

Import one supported source search index from Algolia, Meilisearch, or Typesense
into a new or replacement fjcloud index without persisting source credentials.

## Layout

1. Header: `Migrate search data`, one-line status copy, and no navigation tabs.
2. Provider step: destination provider/region summary and eligibility result.
3. Source-provider step: required selection for exactly one closed source
   provider, `algolia`, `meilisearch`, or `typesense`.
4. Connect step: one provider-specific credential panel selected by
   `source_provider`; no sibling panel remains mounted for the unselected
   providers.
5. Source step: search input, paginated source-index list, metadata row for each
   loaded source, and selected-source summary.
6. Destination step: editable destination index name seeded from the source name,
   validation message, and target eligibility refresh status.
7. Review step: exact source provider, source, destination, scope,
   quota/admission summary, and `Start import`.
8. Recent imports: compact list with status, source provider, source, target,
   updated time, reopen link, empty state, error state, and pagination. It must
   not hide or block the create workflow when the list fails.

## State Contract

### Loading

- The route-level availability load renders a bounded loading state. Dormant
  component fixtures render loading rows for provider eligibility, source-provider
  credential verification, source discovery, target eligibility, job submission,
  and recent imports.

### Error

- Provider/target eligibility errors render typed messages and retry controls.
- `source_provider_unsupported` says the selected source provider is not yet
  supported for this import path; it is distinct from destination-side
  `migration_provider_unsupported`.
- `migration_provider_unsupported` says the current destination provider or
  region cannot receive migration imports; it does not render credential fields.
- Source discovery errors clear any stale catalog, show the producer error, and
  retry from the first page for the selected `source_provider`.
- Recent-import errors leave the create flow visible and expose a retry control.
- Capability-gated lifecycle controls fail closed: absent, omitted, or `false`
  `cancel`, `resume`, or `replace` capabilities hide those controls; `true`
  enables only the matching UI action if the job state also allows it.

### Shipped Unavailable

- Direct authenticated visits render the unavailable explanation loaded from the
  migration availability endpoint.
- The page renders no form actions, source-provider controls, credential fields,
  source controls, target controls, import CTA, dormant component mount, or
  migrate nav link.

### Provider Eligibility

- Destination provider eligibility is credential-free and runs before
  source-provider credential panels are visible.
- Success is bound to customer, mode `create`, destination provider, and region.
- Stale, tampered, cross-customer, provider-change, or region-change fixtures
  invalidate the result and hide every credential panel until refreshed.

### Source Provider Selection

- The create flow owns one `source_provider` value, selected from the closed set
  `algolia`, `meilisearch`, and `typesense`.
- Changing `source_provider` clears volatile credentials, connection state,
  source catalog, cursor, selected source, key fingerprint, submit intent, and
  target eligibility.
- The selected source provider is included in source-list, destination
  eligibility, create-job, recent-job, detail, cancel, and resume transport where
  the neutral client contract requires it.

### Source Credentials

- The customer enters temporary source credentials only after destination
  provider success and source-provider selection.
- Algolia credential copy asks for an Application ID and temporary API key.
  Meilisearch credential copy asks for host URL and API key. Typesense credential
  copy asks for host URL and API key.
- Provider-specific instructions explain least-privilege, temporary credentials,
  validity long enough for the projected import, and source-provider-side
  revocation after completion or failure.
- Copy must state that fjcloud zeroizes its in-memory copy but cannot revoke the
  vendor key at the source provider.
- A browser refresh, component remount, provider change, reconnect, or retry that
  needs source credentials starts with blank secret fields.

### Source Selection

- Connect calls the neutral API client with the selected `source_provider`, live
  credential payload, and optional cursor only.
- Source pagination is lazy, retryable, bounded below the proxy timeout, and
  client-searchable over loaded pages.
- Each row shows name, record count, source size, updated date, optional last
  build seconds when the provider reports it, and primary/replica type when the
  provider reports it.
- Primary rows can be selected for import. Replica rows remain disabled, keep the
  source `Replica of <primary>` label, and direct customers to import the primary
  instead.
- Importing the primary imports primary index records, settings, synonyms, and
  rules. Source replicas are reconstructed as Flapjack virtual replicas when the
  source provider supports replica metadata. If one replica reconstruction fails,
  the imported primary remains in place.

### Destination

- Selecting a source displays the exact source-provider name and exact source
  index name, then seeds an editable destination proposal.
- The proposal must be deterministic, valid under `web/src/lib/index-name.ts`,
  preserve user edits until the source or source provider changes, and never
  consult a client-side destination catalog.
- Target eligibility is credential-free and bound to customer, mode, source
  provider, destination provider, region, destination name, and routing
  generation. Source-provider changes, source changes, user edits,
  provider/region/routing changes, and expiry invalidate final eligibility and
  block submit until refresh.
- Same-tenant conflicts and quota refusals come only from producer eligibility
  or job admission responses; equal names in other tenant fixtures are allowed.

### Review And Start

- Review shows exact source provider, source, destination, scope, and
  quota/admission summary.
- The Scope row communicates the same bounded replica consequence in create and
  replace modes: primary index records, settings, synonyms, and rules are
  imported; supported source replicas are reconstructed as Flapjack virtual
  replicas; if one cannot be reconstructed, the imported primary remains in
  place.
- Start sends one neutral create-job call with the selected `source_provider`,
  disables duplicate submit immediately, reuses the same idempotency key for
  retries of the same intent, and creates a new key only after the user changes
  source provider, source, destination, mode, or target eligibility.
- Success emits one future navigation request to
  `/console/migrate/[jobId]?source_provider={selectedSourceProvider}` so the
  detail loader can stay on the provider-scoped owner contract.

### Recent Imports

- Owner: the tenant-owned retained jobs page from the neutral migration job-list
  client method.
- Loading: show a compact loading row inside `data-testid="migration-recent-imports"`;
  the create workflow remains visible.
- Empty: show a compact empty row saying no imports have run yet; the create
  workflow remains visible.
- Error: show a retryable list error; the create workflow remains visible and
  usable if its own prerequisites are satisfied.
- Populated: rows show status, source provider, source name, destination target,
  updated time, and a customer-owned reopen link to
  `/console/migrate/[jobId]?source_provider={job.sourceProvider}`.
- Pagination: `nextCursor` loads the next retained page without clearing already
  visible rows until the next page succeeds.
- Terminal rows: `completed`, `completed_with_warnings`, `failed`, and
  `cancelled` remain visible and reopenable; they do not imply a fresh create
  action is blocked.

### Warning Detail

- Completed retained Algolia jobs with compatibility warnings render a
  customer-visible summary in `data-testid="migration-job-warning-summary"`.
- The detail page renders every compatibility warning returned by
  `PublicAlgoliaImportJob.warnings`; it does not truncate the browser-visible
  list or append `and N more` copy.
- Warning entries are grouped by source resource, including distinct groups
  whose raw resource identifiers normalize to the same visible label. Duplicate
  visible resource labels keep unique list accessible names.
- Each warning entry shows the bounded public `message`, bounded `code`, and a
  locator derived from page index, item index, and a bounded JSON path when
  those fields are present. The 80-character per-field presentation bound does
  not remove warning entries from the list.

### Credential Containment

- Source credentials may appear only as live input values and in
  credential-bearing source-list/create/resume request bodies.
- They must never appear in SSR/load data, URLs, localStorage, sessionStorage,
  form-history serialization, logs, analytics, non-input text or attributes, page
  HTML, or state that survives component destruction.

### Loading, Focus, And Keyboard

- Initial route loading focuses no hidden controls and announces only the
  unavailable or loaded state that is actually rendered.
- Provider, source-provider, source, target, submit, and recent-import reload
  buttons are standard buttons reachable in DOM order; Enter in text inputs does
  not bypass the current step's primary button or idempotency guard.
- Validation errors set `aria-describedby` on the affected input and move focus
  to the first actionable error summary only after the failed user action.
- Retry controls preserve the user's non-secret selections when safe; any retry
  that needs source credentials starts with blank secret fields.

## Navigation

- Route: `/console/migrate`
- Entry: authenticated direct visit; console navigation must not advertise
  migration while the served page is unavailable by default.
- Start success: navigation to
  `/console/migrate/[jobId]?source_provider={selectedSourceProvider}`.
- Reopen: Recent-import rows link to
  `/console/migrate/[jobId]?source_provider={job.sourceProvider}` detail pages
  owned by the retained job contract.
- Browser back from in-progress create state returns to the previous console
  page; if a mounted flow has unsent credentials, leaving destroys them without
  persistence.

## Acceptance Criteria

- [x] Given the shipped route is unavailable, direct visits render the
      unavailable explanation and no migration controls.
- [x] Given destination provider eligibility succeeds, source-provider selection
      and exactly one provider-specific credential panel become visible.
- [x] Given source provider `algolia`, the credential panel asks for Algolia
      Application ID and API key only.
- [x] Given source provider `meilisearch`, the credential panel asks for
      Meilisearch host URL and API key only.
- [x] Given source provider `typesense`, the credential panel asks for Typesense
      host URL and API key only.
- [x] Given credentials are entered, source discovery sends exactly the selected
      `source_provider` and live credential payload to the neutral source-list
      client method and never persists any credential value.
- [x] Given loaded sources, source rows render exact metadata and client-side
      search/pagination behavior without refetching for search.
- [x] Given loaded sources include a replica, the replica source row is disabled,
      labels the source as `Replica of <primary>`, tells customers to import the
      primary, states that supported source replicas are reconstructed as
      Flapjack virtual replicas, and states that a failed reconstruction leaves
      the imported primary in place.
- [x] Given source provider, host, or credential values change, connection state,
      source catalog, cursor, selected source, key fingerprint, submit intent,
      and target eligibility are cleared.
- [x] Given a selected source, the exact source provider and source name remain
      visible and the destination proposal is valid, editable, deterministic,
      and advisory only.
- [x] Given target eligibility is stale, expired, or bound to an old source
      provider, source, destination, provider, region, or routing generation,
      submit is blocked until refresh.
- [x] Given review submit is activated twice, exactly one neutral create request
      is emitted for that intent and the stable idempotency key is reused on
      retry.
- [x] Given create-mode review renders, the Scope row states the exact create
      consequence copy for primary import, Flapjack virtual replica
      reconstruction, and primary preservation after failed reconstruction.
- [x] Given replace-mode review renders, the Scope row states the exact replace
      consequence copy for primary import, Flapjack virtual replica
      reconstruction, and primary preservation after failed reconstruction.
- [x] Given `source_provider_unsupported`, the UI renders human-readable source
      provider copy that is distinct from destination-side
      `migration_provider_unsupported`.
- [x] Given any credential canary, it appears only in live inputs and
      credential-bearing request bodies, never retained markup, stores,
      `__data.json`, URL, or public state after submit.
- [x] Given a retained completed Algolia job has compatibility warnings, the
      real browser detail page renders the warning summary, grouped resource
      headings, every warning entry with its bounded message, code, and locator,
      and no `and N more` warning-set truncation copy.

## Edge Cases

- Empty source catalog: show an empty state, not a failure.
- Later source page fails: clear stale rows and retry from the first page.
- Source provider changed after a catalog loads or while discovery is in flight:
  hide every old credential panel, catalog, selection, cursor, target
  eligibility, and destination until reconnect.
- Host or credentials edited after a catalog loads or while discovery is in
  flight: hide the catalog, selection, cursor, and destination until reconnect.
- `source_provider_unsupported`: keep destination eligibility copy separate and
  leave the customer at source-provider selection or provider-specific
  credentials as appropriate.
- `migration_provider_unsupported`: hide source-provider controls and credential
  panels because the destination cannot receive migration imports.
- Over-64-character, Unicode, punctuation, reserved-name, and boundary-character
  source names: proposal remains valid and user-editable.
- Operational pause or backpressure after route activation: preserve route,
  help, recent imports, reopen/status, and cancel presentation; disable fresh
  start/resume with typed reason and retry-after.

## Mobile Narrow Contract

- Baseline width: 390px.
- Steps stack vertically with full-width inputs and buttons.
- Source-provider controls and provider-specific credential panels stack without
  horizontal scrolling.
- Source metadata wraps within each row without horizontal scrolling.
- Review rows use label/value stacking rather than side-by-side columns.
- Recent imports show status, source provider, source, target, and updated time
  in one vertical row per job.

## Current Implementation Gaps

- The public `/console/migrate` route remains unavailable by default. Unmocked
  browser coverage proves the unavailable explanation and absence of migration
  controls, while the neutral create-flow, recent-import, and job-detail
  contracts remain activated only under test-owned availability fixtures.
- The grouped warning-detail browser proof is desktop-only. The 390px mobile
  contract for warning detail remains a named gap owned by this spec and
  `web/tests/e2e-ui/mocked/migration_console_flow.spec.ts`.

## Automated Coverage

- Unmocked unavailable-route proof:
  `web/tests/e2e-ui/full/migration-recovery.spec.ts` verifies direct
  authenticated visits to `/console/migrate` render the unavailable explanation
  and no migration controls.
- Mocked real-browser console-flow proof:
  `web/tests/e2e-ui/mocked/migration_console_flow.spec.ts` completes enabled
  Algolia, Meilisearch, and Typesense create journeys under mocked availability.
  Its active Chromium create-flow proofs are:
  - `available migration create flow starts a Algolia import and renders retained job progress`
  - `available migration create flow starts a Meilisearch import and renders retained job progress`
  - `available migration create flow starts a Typesense import and renders retained job progress`
- Mocked multipart request owner:
  `web/tests/e2e-ui/mocked/migration_console_flow_fixture.ts` parses action
  payloads with `actionPayload(...)` and verifies `source_provider` and
  provider-specific credentials through the existing
  `expectedSourceListPayload(...)` and `expectedCreatePayload(...)` assertions.
  The same mocked suite also verifies retained job progression through terminal
  summary rows, cancel, invalid-credential failure, and
  `source_provider_unsupported` presentation, plus a retained completed Algolia
  job detail with every grouped warning entry, its fixture-exact bounded
  message, code, and locator, each resource heading,
  `data-testid="migration-job-warning-summary"`, and no `and N more`
  warning-set truncation copy.
- Route component owners:
  `web/src/routes/console/migrate/migrate.test.ts` and
  `web/src/routes/console/migrate/[jobId]/job.test.ts` verify provider-scoped
  route rendering, form payloads, recent-import navigation, detail actions, and
  structural accessibility for the manifest-listed routes.
- Route server owners:
  `web/src/routes/console/migrate/migrate.server.test.ts` and
  `web/src/routes/console/migrate/[jobId]/job.server.test.ts` verify
  source-provider parsing, rejection of missing/unknown/path-shaped values,
  neutral API forwarding, provider-bearing navigation data, and typed
  `source_provider_unsupported` failures.
- Create-flow and detail component owners:
  `web/src/lib/components/migration/MigrationCreateFlow.test.ts`;
  `web/src/lib/components/migration/MigrationCreateFlowProvider.test.ts`;
  `web/src/lib/components/migration/MigrationCreateFlowDestination.test.ts`;
  `web/src/lib/components/migration/MigrationAdmission.test.ts`;
  `web/src/lib/components/migration/RecentImports.test.ts`;
  `web/src/lib/components/migration/ImportJobDetail.test.ts`.
- Credential snapshot race owner:
  `web/src/lib/components/migration/MigrationCreateFlow.test.ts` delays the
  first-connect API-key fingerprint and proves unchanged credentials publish
  one connected snapshot, while the adjacent invalidation cases prove any
  identity or key edit still hides the catalog until reconnect.
- API client owner: `web/src/lib/api/client-migration.test.ts` verifies neutral
  `/migration/{sourceProvider}/...` paths, exact bodies, error typing,
  source-provider identity, and Algolia compatibility wrappers.
