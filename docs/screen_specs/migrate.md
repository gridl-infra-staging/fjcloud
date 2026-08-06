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
8. Preview step: an advisory, inline state between review and execution of
   `Start import`, with source counts, compatibility findings, retry, and a
   proceed-anyway action; it is not a route, modal, or second create flow.
9. Recent imports: compact list with status, source provider, source, target,
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
  `cancel`, `resume`, `replace`, or `verify` capabilities hide those controls;
  `true` enables only the matching UI action if the job state also allows it.
  An absent, omitted, or `false` `capabilities.verify` hides the cutover
  verification controls.

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

### Preview

- Preview is the next state in the existing `MigrationCreateFlow.svelte`
  machine after review and before job creation on the same `/console/migrate`
  route when the provider-scoped availability response reports
  `capabilities.preview: true`. Review exposes `Preview import` as its primary
  action; `Start import` is unavailable until one preview attempt has resolved
  as success or error.
- If `capabilities.preview` is not true, the preview panel states that preview
  is unavailable for the selected source, the migration can still run, and
  compatibility warnings appear after the job starts. `Start import` remains
  reachable without a preview attempt in this state.
- Stage 2 adds one provider-neutral preview call to
  `web/src/lib/api/migration_client.ts`. It takes `source_provider` separately
  from the selected provider's live credential/source/destination payload and
  calls `/migration/{source_provider}/preview`; it does not add Algolia-,
  Meilisearch-, or Typesense-specific client methods.
- Loading keeps the review summary visible, labels the active action
  `Previewing import`, prevents duplicate preview requests, and does not expose
  `Start import` until the attempt resolves.
- Success shows exact `sourceCounts.indexes` and `sourceCounts.records`, then
  the report-summary counts for hard rejections, warnings, and scope gaps,
  followed by every compatibility entry. No browser-visible entry-set
  truncation or `and N more` copy is allowed.
- Preview and post-import compatibility entries use the same
  `AlgoliaImportCompatibilityWarningPresentation` group/entry model from
  `job_presentation.ts` and the same shared warning component. Stage 2 extracts
  the warning-only block currently inside `ImportJobDetail.svelte` into
  `MigrationCompatibilityWarnings.svelte`; both preview and
  `ImportJobDetail.svelte` render that component. The existing
  `algoliaImportCompatibilityWarningPresentation` remains the retained-job
  adapter, while the preview adapter returns the same presentation type.
- Until the producer publishes a customer-facing `message`, each preview entry
  uses the shared presentation owner's bounded `Compatibility warning` fallback
  as its primary line. It also preserves bounded `code` and the same locator
  construction used after import: present page index, present item index, and
  bounded JSON path. Grouping, field order, bounds, and accessible list
  structure remain shared with retained-job warnings.
- Empty: when the preview returns zero compatibility entries, keep the source
  counts visible and show the positive state `No compatibility issues found`;
  do not render an empty warning container.
- Error: network failure, rejected/bad credentials, and
  `source_provider_unsupported` render sanitized, human-readable copy inside
  this step. The copy says no preview was completed and no import job was
  created, preserves non-secret review selections, leaves credentials editable,
  and offers `Retry preview` without restarting the flow.
- Hard rejections in a successful report and preview-request errors are
  advisory. They warn that the import may fail or omit incompatible data, but
  do not by themselves disable the explicit `Start import anyway` action.
  Existing target-eligibility, admission, replace-confirmation, and duplicate-
  submit guards remain authoritative and may still block Start.
- Preview is report-only: requesting it, retrying it, receiving findings, or
  receiving an error creates no import job, consumes no create idempotency key,
  and emits no job-detail navigation. Only `Start import` calls the existing
  neutral create-job seam.
- A source-provider, credential, selected-source, destination, mode, or target-
  eligibility change invalidates the preview result/error and returns the same
  machine to review with `Preview import` as the primary action.

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

### Cutover Verification Detail

- Owner: the retained job detail route
  `/console/migrate/[jobId]?source_provider={job.sourceProvider}`. This panel is
  mounted only for retained jobs whose server-loaded status is `completed` or
  `completed_with_warnings`; the create wizard never renders it.
- Supported state: driven solely by the server-published, provider-scoped
  `capabilities.verify: true` for this job's `source_provider`, loaded by the
  route alongside the retained job. The panel never infers support from the
  job's provider.
- Unsupported-provider state: a state distinct from the loading and error
  states, entered whenever `capabilities.verify` is absent, omitted, or `false`.
  It renders provider-labelled explanation-only copy with no credential fields,
  no query or result-limit controls, and no submit control. The backend
  publishes `verify: true` for Algolia sources only, so Meilisearch and
  Typesense retained jobs always land here.
- Unsupported copy contract: the statement names what is unavailable, names the
  job's source provider, and states that the completed migration and any preview
  support published for it are unaffected. It is rendered inside
  `data-testid="cutover-verification-unsupported"`. The exact sentence is
  `Cutover verification is not available for this {Provider} migration, so you
  cannot compare source and fjcloud search results here. The completed migration
  and any preview support published for it are unaffected.` The copy must stay
  true when verification is withheld for a reason other than provider support —
  an operator-disabled platform fails `capabilities.verify` closed for Algolia
  too — so it must not name Algolia as the supported source or promise a future
  release. Owner:
  `web/src/lib/components/migration/job_presentation.ts::describeUnsupportedCutoverVerification`,
  with the literal wording pinned by
  `web/src/lib/components/migration/MigrationCutoverVerification.test.ts` and
  every other consumer asserting through the builder.
- Read-only job identity: source provider, source index name, destination index
  name, job id, and job status come from the retained job loaded by the route.
  Source and destination index names are displayed as read-only values and are
  not accepted from hidden or editable form fields.
- Customer inputs: supported verification asks for a fresh Algolia Application
  ID and temporary API key, a query list, and a result limit. The secret fields
  start blank on page load/remount and after any completed attempt. Queries are
  customer-entered lines; empty lines are ignored. Result limit is a numeric
  control whose canonical acceptance bounds remain owned by FS-7.
- Submission path: the route action reloads the retained job, derives
  `sourceIndex` from `job.source.name`, derives `destinationIndex` from
  `job.destination.target`, and calls
  `POST /migration/{source_provider}/verify` with request fields `appId`,
  `apiKey`, `sourceIndex`, `destinationIndex`, `queries`, and `resultLimit`.
  The action uses no create-job idempotency key and returns only sanitized
  structured error data or the report.
- Idle: show the read-only source/destination pair, blank credential fields, the
  query/result-limit controls, and copy stating the report compares top result
  identifiers and rank positions. Copy must say this is an inspection report,
  not a migration verdict, score, threshold, pass badge, or deployment approval.
- Running: disable duplicate submissions immediately, keep the read-only job
  fields and non-secret query/result-limit values visible, and announce
  `Running cutover verification`.
- Complete with high agreement: render the exact report values for each query
  without a success, pass, ready, safe, green, or equivalent verdict. The
  allowed customer copy is neutral, for example `Review the matching result
  identifiers and rank movement before cutover`.
- Complete with differences: render the same report shape and include
  source-only, destination-only, and rank-delta rows. Differences do not imply a
  failure verdict; they are inspectable facts.
- Report shape: the response renders read-only `sourceIndex`,
  `destinationIndex`, `resultLimit`, and one query report per response item.
  Each query report renders `query`, `overlapCount`, `sourceOnly`,
  `destinationOnly`, and `hits`. Each hit renders `objectID`, `sourceRank`,
  `destinationRank`, and `rankDelta`, where FS-7 defines
  `rankDelta = destinationRank - sourceRank`.
- Accessible names: the report summary uses
  `aria-label="Cutover verification report"`. Per-query result lists use
  `aria-label="Cutover verification query report: <query>"`. Source-only and
  destination-only lists use `aria-label="Source-only object IDs: <query>"` and
  `aria-label="Destination-only object IDs: <query>"`. Hit-rank tables use
  `aria-label="Hit rank comparison: <query>"`.
- Rejected credentials: `invalid_credentials` renders source-provider-labelled
  copy telling the customer to enter a valid Algolia key. The rejected key and
  Application ID never appear in the action result, retained markup, URLs, or
  non-input text.
- Missing source permission or source not found:
  `missing_source_permission` and `source_not_found` render source-oriented copy
  from the migration presentation owner. They do not claim the destination is
  unhealthy.
- Unavailable comparison: `backend_unavailable` renders origin-neutral copy
  because FS-7 can return that same public code for source and destination
  transport failures. The UI must not say which side failed unless the published
  response message explicitly identifies it.
- Validation and destination readiness failures: request validation errors,
  incompatible destination responses, destination not ready, destination not
  found, destination cold/restore-required, rate limiting, or quota errors render
  sanitized structured error code/message data from the route action. The panel
  keeps safe non-secret inputs available for correction or retry.
- Unsupported provider: `source_provider_unsupported` or a retained job whose
  source provider is not Stage-1 supported renders source-provider unsupported
  copy and no verification credential fields.

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
- [x] Given a retained completed job whose source provider has no
      server-published `capabilities.verify`, the real browser detail page states
      that cutover verification is unavailable, names that provider, says the
      completed migration and any published preview support are unaffected, and
      exposes no credential, query, result-limit, or submit control; and given a
      retained completed job whose provider does publish `verify`, the same panel
      exposes `Run verification` and no unsupported statement. Proven unmocked
      against a migration-enabled local stack by
      `web/tests/e2e-ui/full/migration-recovery.spec.ts`. This criterion covers
      the boundary only; the report-rendering criteria below stay unchecked.
- [ ] Given a retained `completed` or `completed_with_warnings` Algolia job,
      the cutover verification panel derives source and destination indexes
      from the retained job, accepts fresh Algolia credentials plus query and
      result-limit controls, emits one provider-scoped verify request with no
      idempotency key, and renders the returned per-query overlap,
      source-only, destination-only, and hit-rank facts with no verdict copy.
- [ ] Given cutover verification returns rejected credentials, missing source
      permission/source not found, unavailable comparison, validation or
      destination-readiness failure, or unsupported-provider data, the retained
      job detail renders sanitized customer copy and never serializes credential
      canaries outside the live credential input value.
- [x] Given an Algolia source index served by a real local search engine, the
      API verification path returns a per-query report whose `overlapCount`,
      `sourceOnly`, `destinationOnly`, `objectID`, `sourceRank`,
      `destinationRank`, and `rankDelta` values equal a hand-calculated
      known-answer oracle, and a source whose transport is unreachable maps to
      `503` with `retry-after: 30` and the labelled backend-unavailable body
      before any destination search runs. Proven against a lane-local
      Flapjack reached through the `FJCLOUD_ALGOLIA_SOURCE_BASE_URL` loopback
      override, seeded with a five-document corpus whose ranking is derivable
      from the document titles rather than from engine scoring internals.
- [ ] Given a real Algolia (`algolia.net`) source index, the API verification
      path returns the same report values against the live vendor. Unproven:
      this lane never contacted `algolia.net` and holds no Algolia credentials,
      so vendor-specific authentication, request shape, result ordering, and
      rate-limit behavior remain unverified.
- [x] Given a valid review, when the customer activates `Preview import`, one
      provider-neutral preview request carries the selected `source_provider`
      and no create-job request, idempotency key, or navigation is emitted.
- [x] Given a successful preview, source index/record counts and all hard-
      rejection, warning, and scope-gap counts render with the full compatibility
      list through `MigrationCompatibilityWarnings.svelte`.
- [x] Given a successful preview with zero compatibility entries, the exact
      source counts and `No compatibility issues found` render with no empty
      warning container.
- [ ] Given a preview hard rejection, network error, rejected/bad credentials,
      or `source_provider_unsupported`, the customer is warned that import may
      fail or omit incompatible data, can correct credentials and retry, and can
      use `Start import anyway` when all pre-existing Start guards pass.
- [x] Given the same compatibility entry appears before and after import, both
      states render identical resource grouping, bounded code, page/item/JSON-
      path locator, field order, and accessible list structure through the shared
      warning component; the preview primary line remains the bounded fallback
      until the producer publishes the retained-job message.
- [x] Given any preview-bound source, credential, destination, mode, or target-
      eligibility input changes, the old preview is removed and a new preview
      attempt is required before Start becomes available.

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
- Preview returns hard rejections, warnings, and scope gaps together: render the
  exact summary counts and every entry, then leave Start governed by the existing
  Start guards rather than report severity.
- Preview fails after a prior success or while its bound inputs change: discard
  the stale response/error, preserve safe non-secret selections, and require a
  fresh preview attempt for the current inputs.
- Cutover verification submits twice before the first request resolves: the
  second submit is ignored and the first request remains the only active action.
- Cutover verification returns after the retained job, query list, or result
  limit binding has changed: discard the stale report/error and require a fresh
  attempt for the current inputs.

## Mobile Narrow Contract

- Baseline width: 390px.
- Steps stack vertically with full-width inputs and buttons.
- Source-provider controls and provider-specific credential panels stack without
  horizontal scrolling.
- Source metadata wraps within each row without horizontal scrolling.
- Review rows use label/value stacking rather than side-by-side columns.
- Preview counts and the shared compatibility-warning list stack vertically at
  390px; message, code, and locator wrap within their rows, and neither the
  summary nor entries introduce horizontal scrolling. This mirrors retained
  warning-detail behavior.
- Cutover verification stacks the read-only job fields, credential controls,
  query controls, per-query source-only/destination-only lists, and hit-rank
  rows vertically at 390px. Long object IDs wrap inside their rows without
  horizontal scrolling.
- Recent imports show status, source provider, source, target, and updated time
  in one vertical row per job.

## Current Implementation Gaps

- Current: `MigrationCreateFlow.svelte` invokes the inline advisory preview
  after target eligibility and before the existing start path. Preview state is
  owned by `migration_create_preview_state.ts`; the flow rejects stale preview
  responses, suppresses duplicate preview requests, and keeps create
  idempotency-key allocation inside the explicit start path. Evidence:
  `web/src/lib/components/migration/MigrationCreateFlow.svelte`,
  `web/src/lib/components/migration/MigrationCreateDestination.svelte`, and
  `web/src/lib/components/migration/migration_create_preview_state.ts`.
- Current: `MigrationCompatibilityWarnings.svelte` owns warning markup and
  accessible names, `ImportJobDetail.svelte` uses it, and the preview adapter in
  `job_presentation.ts` returns the same presentation type. The preview adapter
  carries severity as an optional warning-entry field, uses the shared bounded
  `Compatibility warning` fallback while producer `message` is absent, and does
  not own per-code customer-facing message copy. Evidence:
  `web/src/lib/components/migration/MigrationCompatibilityWarnings.svelte`,
  `web/src/lib/components/migration/ImportJobDetail.svelte`, and
  `web/src/lib/components/migration/job_presentation.ts`.
- Upstream engine gap: `MigrationPreviewReportEntry` publishes code,
  resource, severity, page/item indexes, and JSON path but no customer-visible
  `message`, while the shared warning entry requires `message`, `code`, and
  locator. The preview adapter uses the existing bounded fallback until the
  producer adds a public message; the OpenAPI tripwire then requires adopting it.
  Evidence: `infra/api/src/routes/migration/preview.rs:80` and
  `web/src/lib/components/migration/job_presentation.ts:70`.
- Current: FS-7 publishes one read-only Algolia verification route at
  `POST /migration/{source_provider}/verify` with request fields `appId`,
  `apiKey`, `sourceIndex`, `destinationIndex`, `queries`, and `resultLimit`,
  response fields `sourceIndex`, `destinationIndex`, `resultLimit`, and
  `queries`, per-query fields `query`, `overlapCount`, `sourceOnly`,
  `destinationOnly`, and `hits`, and hit fields `objectID`, `sourceRank`,
  `destinationRank`, and `rankDelta`. The route rejects Meilisearch and
  Typesense before source I/O. Evidence:
  `infra/api/src/routes/migration/verify.rs`.
- Gap: cutover verification remains Algolia-only. The console publishes
  `capabilities.verify` true only for Algolia through
  `infra/api/src/routes/migration/capabilities.rs`; Meilisearch and Typesense
  retained jobs render the unsupported state until the engine and
  `infra/api/src/routes/migration/verify.rs` guard widen together. Those two
  owners state the same rule and must move together.
- Current: the API verification path now has a real-source execution proof, not
  only a transport proof. `verify_seeded_local_source_red_proof` seeds a
  five-document corpus into a lane-local Flapjack, reaches it through the
  `FJCLOUD_ALGOLIA_SOURCE_BASE_URL` loopback override, and asserts full-body
  equality against a hand-calculated parity oracle covering ranking,
  per-query result limit, `objectID` overlap, source-only, destination-only,
  and rank deltas. The corpus separates on proximity and single-term exact
  match, so the expected ranking is derivable by reading the document titles
  and does not depend on the engine's scoring weights. Evidence:
  `infra/api/tests/integration/migration_routes_test/verify.rs` and
  `infra/api/tests/integration/migration_routes_test/verify_support.rs`.
- Gap: no vendor round-trip exists. Every verification proof runs against a
  local engine or a stub; nothing in this repository has contacted
  `algolia.net`, and no Algolia credentials are available to it. Algolia's
  authentication, exact request shape, result ordering, and rate-limit
  behavior are therefore assumed from the documented contract, not observed.
  The local proof narrows the source-behavior gap; it does not close the
  vendor-compatibility gap.
- Current: the retained-job cutover verification unsupported/supported boundary
  now has an unmocked browser proof.
  `web/tests/e2e-ui/full/migration-recovery.spec.ts` (`Retained cutover
  verification boundary`) seeds one completed Meilisearch and one completed
  Algolia retained job through
  `web/tests/fixtures/fixtures.ts::seedCompletedRetainedMigrationJob`, proves
  each is readable through `GET /migration/{source_provider}/jobs/{id}`, and
  opens both detail routes in a real browser against a real API, PostgreSQL,
  and Flapjack. The Meilisearch arm asserts the exact unsupported statement with
  no credential, query, result-limit, or submit control; the Algolia arm is the
  negative control that asserts `Run verification` and the absence of the
  unsupported statement, so the proof follows server-published
  `capabilities.verify` rather than provider-name copy.
- Gap: that proof needs its own stack.
  `FJCLOUD_ALGOLIA_MIGRATION_ENABLED` — see
  `web/tests/fixtures/migration_enabled_stack.ts` — is read once at API startup,
  and the shared Playwright stack runs with migration disabled because
  `migration-recovery.spec.ts` also proves the closed state. The cutover proof
  therefore spawns a second local stack through
  `web/tests/fixtures/nested_local_stack.ts`. Until the shared stack can serve
  both states, the proof pays a full cold start.
- Gap: FS-7 can return the same public `backend_unavailable` code for source
  and destination transport failures. The screen must keep that copy
  origin-neutral and must not claim a source-versus-engine diagnosis unless a
  future published response identifies the side.
- Upstream engine gap: the route/provider enum admits Typesense, but
  `MigrationPreviewRequest` publishes only Algolia and Meilisearch request arms.
  That lane must publish and contract-test the Typesense host/API-key/source/
  target request shape before the preview client admits Typesense. Evidence:
  `infra/api/src/routes/migration/preview.rs:21` and
  `infra/api/tests/integration/migration_routes_test/preview.rs:13`.
- The public `/console/migrate` route remains unavailable by default. The
  unmocked owner in `web/tests/e2e-ui/full/migration-recovery.spec.ts` now targets
  a test-enabled Meilisearch preview journey, but it is not a closing proof: the
  test runtime does not yet enable migration for the owner selection, and the
  Meilisearch list-index request shape is not accepted by the producer route.
- The unmocked preview owner logs preview and retained-job text rather than
  asserting fixture-exact counts, complete warning identities, terminal-state
  parity, or the 390px mobile contract. The grouped retained-warning detail proof
  remains desktop-only.

## Automated Coverage

- Unmocked preview owner:
  `web/tests/e2e-ui/full/migration-recovery.spec.ts` defines the intended direct
  Meilisearch preview-before-start journey and its no-job-before-start check. It
  is not yet executable or fixture-exact for the implementation gaps above, so
  it does not currently close unmocked preview coverage.
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
- API cutover-verification parity owner:
  `infra/api/tests/integration/migration_routes_test/verify.rs` drives
  `POST /migration/algolia/verify` through the real router. Its
  `verify_seeded_local_source_red_proof` runs against a lane-local Flapjack
  seeded with the corpus in `verify_support.rs::seeded_source_batch`, reached
  through the `FJCLOUD_ALGOLIA_SOURCE_BASE_URL` loopback override, and asserts
  full-body equality against `verify_support.rs::expected_parity_report`. That
  oracle is the single owner of the hand-calculated arithmetic and is shared by
  all three proofs: the fake-source unit proof, the wiremock real-HTTP proof
  `verify_matches_the_parity_oracle_over_real_http_against_a_stubbed_source`,
  and the seeded-engine proof. `verify_maps_unreachable_source_to_labelled_backend_error`
  covers the real-transport failure arm. `infra/api/src/services/algolia_source/tests.rs`
  pins that the override seam falls back to the production
  `https://{app}.algolia.net/1/indexes` host when the override is absent.
  None of these contact `algolia.net`.
- Mocked cutover-verification browser owner:
  `web/tests/e2e-ui/mocked/migration_cutover_verification.spec.ts` opens a
  retained completed job from the recent-imports list, asserts the idle/running
  controls, exact high-agreement and difference reports, sanitized error copy,
  unsupported Meilisearch/Typesense retained-job states, and the negative
  control where a Meilisearch job with `publishedVerifyCapability: true` renders
  the verification control instead of inferring support from provider identity.
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
- Stage-2 preview proof extends the existing create-flow component, route
  component, server-action, API-client, and mocked browser owners rather than
  introducing a new route suite. Those owners assert exact counts and warning
  fields for success, the positive zero-warning state, non-blocking hard-
  rejection and request-error states, input invalidation, no preview-created
  job/idempotency/navigation, and shared-renderer output. Exact unmocked
  before/after parity and the required retry/no-job error copy remain open.
  The API-client owner asserts one neutral
  `/migration/{sourceProvider}/preview` method and exact provider-specific
  bodies without per-provider convenience methods.
