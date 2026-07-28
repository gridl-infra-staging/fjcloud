# Public Infrastructure Screen Spec

## Task

- Primary route: `/infrastructure`
- Audience: unauthenticated visitors checking current fleet health and coarse capacity posture
- Priority: P0
- Wire owner: `infra/api/src/routes/public_infrastructure.rs::PublicInfrastructureResponse`

Show current infrastructure only at region granularity. The page may consume only
`region`, `provider`, `display_name`, `provider_location`, `health`, `utilization`, and
`vm_count` for each region, plus `overall.availability_pct`, `overall.total_regions`, and
`overall.total_vms`. It must not derive or expose a parallel per-machine view.

## Layout

- Reuse the public-page header with the Flapjack Cloud brand and `Log In` link.
- Render the `Infrastructure` heading and concise region-granularity explanation.
- Present overall availability as the primary summary figure, accompanied by total regions
  and total VMs.
- Render one accessible table row per region with region identity, provider metadata, health,
  coarse utilization, and VM count.
- Use text-bearing badges for health and utilization so meaning does not depend on color.
- Do not render authenticated-console, placement, host, VM-detail, refresh, or management
  controls.

## State contract

- Loading: this is a server-rendered route; navigation retains the browser's normal pending
  behavior until the server load resolves, so no client-only spinner or invented data is
  required.
- Error: upstream failures return a complete public page with safe page-local unavailable
  copy. Raw upstream errors and infrastructure identifiers are never rendered.
- Empty fleet / zero VM: render the region table when configured regions exist, including
  `vm_count` values of zero. When `overall.total_vms` is zero, availability is explicitly
  unavailable because there are no VM health observations; it must not render as `100%`.
- Successful mixed-region: render every region exactly once and preserve the API-provided
  region, provider, display name, provider location, health, utilization, and VM count.
- Null utilization: render an em dash (`—`) and neutral treatment. Do not guess a bucket or
  reveal a raw capacity/load value.
- Privacy: DOM content and raw public JSON stay region-granular. Hostnames, IP addresses,
  machine or VM identifiers, Flapjack URLs, capacity, and current-load details are forbidden.
  Tenantless standby capacity and terminated deployments are also forbidden from anonymous
  totals, rows, and availability calculations.

## Mobile Narrow Contract

Baseline viewport: 390px wide (iPhone 14). Summary figures remain readable before the region table, the table may use horizontal scrolling for its allowed region columns, and no private identifiers, per-machine details, or management controls appear in the first viewport or overflow area.

## Navigation

- Header brand link navigates to `/`.
- Header `Log In` link navigates to `/login`.
- The page has no authenticated-console or per-machine navigation.

## Acceptance Criteria

- [ ] Anonymous navigation to `/infrastructure` renders the `Infrastructure` heading and
  overall availability summary.
- [ ] A successful response renders one accessible table row per region with all seven
  allowed region fields represented and no per-machine details.
- [ ] `operational`, `degraded`, `outage`, and `unknown` health values render distinct exact
  labels and semantic badge colors; missing or unexpected health fails closed to `unknown`.
- [ ] `green`, `yellow`, and `red` utilization values render exact coarse labels and semantic
  badge colors; null, missing, or unexpected utilization renders `—`.
- [ ] Null `availability_pct` and zero `total_vms` render explicit no-data copy rather than a
  fabricated percentage.
- [ ] Upstream failure renders safe unavailable copy and no raw error detail.
- [ ] Component and browser-unmocked checks reject private sentinel strings and keys in both
  the rendered DOM and raw `/public/infrastructure` JSON.

## Edge cases

- An empty `regions` array renders an explicit no-region-data message rather than an empty
  table shell.
- A nonzero VM total with null availability still renders availability as unavailable.
- Region order follows the canonical API response; the page does not duplicate sorting or
  availability rules.
- Unexpected health or utilization values fail closed to the presentation contract's
  `unknown` / `—` states.
- Public JSON may contain only `overall` and `regions` at the top level, only
  `availability_pct`, `total_regions`, and `total_vms` under `overall`, and only the seven
  allowed region keys listed in `Task`.

## Current Implementation Gaps

- Product gaps: None known for the current region-granularity page and privacy contract.
- JSDOM axe coverage now proves populated and empty infrastructure states in `web/src/routes/infrastructure/infrastructure.test.ts`.
- Browser proof gap: PUBUX-003 remains handed off to the existing public infrastructure browser-test owner; the live browser command is blocked/inconclusive until it proves both successful UI and raw public JSON allowlist states without route interception.

## Automated Coverage

- Client contract: `web/src/lib/api/public_infrastructure.test.ts`
- Route contract, rendering, and server load: `web/src/routes/infrastructure/infrastructure.test.ts`
- Browser-unmocked UI and raw JSON privacy contract: `web/tests/fixtures/fixtures.ts::arrangePublicInfrastructureCanaryVm` owns the tethered canary. `web/tests/e2e-ui/full/public-infrastructure.spec.ts` is the required owner for proving the successful seven-field region UI and raw JSON allowlist; per PUBUX-003, that owner remains handed off and must not be reported green until the exact browser command proves both states at HEAD.
