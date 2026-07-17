# Metrics-tab reconciliation — finding (2026-07-11)

Reconciles the June 3 customer-release `Metrics` tab miss recorded in
`docs/runbooks/evidence/customer-release-verification/20260603T020623Z/summary.json`
against the shipped per-index metrics path
(`infra/api/src/routes/indexes/index_metrics_route.rs::get_index_metrics`,
`web/src/routes/console/indexes/[name]/tabs/MetricsTab.svelte`).

## Disposition: (a) drift-explained

Current local code is **green** against a healthy local stack. The June 3 miss
is explained by **stale deployed staging** at that time (the customer-facing
metrics slice had not yet shipped), NOT by a live defect in the current Metrics
tab. No product code was changed this stage; disposition (b) (code-gap-fixed)
was not needed.

## Seeded expected value

- `seedMetricsSearchableIndex` seeds `METRICS_READY_DOCUMENTS.length = 12`
  documents (`web/tests/fixtures/searchable-index.ts`), so
  `expectedDocumentCount = 12` and the Documents KPI must render
  `Documents 12` via `$lib/format`'s `formatNumber`.

## Exact command lines

- Green (local stack via Playwright `webServer` owner
  `../scripts/playwright_local_stack.sh --force-api-restart`):
  `pnpm exec playwright test web/tests/e2e-ui/smoke/customer_release_surfaces.spec.ts`
  → `2 passed` (`green_smoke.log`).
- Non-vacuous red proof (asserted count temporarily flipped to
  `expectedDocumentCount + 1` = 13 at the test call site, then restored):
  same command → `toHaveText` failed with Expected `"Documents 13"` /
  actual `"Documents 12"` (`wrong_value_red.log`). Post-restore `git diff` on
  the spec is clean and the green re-run passed.
- Lint gate (the exact CI command): `pnpm run lint:e2e` → exit 0,
  `168 problems (0 errors, 168 warnings)`; all warnings pre-existing in other
  specs (`lint_e2e.log`).

## Local stack readiness (health)

The Playwright `webServer` owner gates flapjack `/health` + api `/health` before
web boot, then Playwright waits on the web baseURL before running specs. Ports
are workspace-derived (not the nominal 7700/3001/5173). Observed in
`.local/playwright_*.log` for this run:

- Flapjack: `🥞 Flapjack v1.0.9 ready in 82ms`; write queue started for the
  seeded tenant index.
- API: `API listening on 127.0.0.1:9376`; `GET /health -> 200`.
- Seeded index for the green run: `customer_release_metrics_1783731492607`.

## Staging cross-check verdict — L1 tooling issue, NOT a Metrics-tab defect

Command:
`bash scripts/canary/contracts/customer_metrics_endpoint_authenticated_probe.sh --staging-only`
(credentials sourced from
`/Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret`;
`API_URL=https://api.staging.flapjack.foo`). Full output in `staging_probe.log`;
the probe's own structured summary (conventionally tracked, like the prior
2026-06-01/2026-06-03 probe bundles) is at
`docs/runbooks/evidence/customer-metrics-probe/20260711T010307Z/summary.json`:
`status: "fail"`, `exit_code: 1`,
`failure_detail: "metrics did not report documents_count > 0 within the scrape window"`.

The probe advanced past the historical signup-429 blocker: **signup →
verify-email → index create → index write all succeeded on staging**, and the
authenticated `GET /indexes/{name}/metrics` returned **HTTP 200** bodies (the
shape validator ran on the body, which only happens after a 200). This shows the
customer-facing metrics slice is **deployed and serving on staging today** — the
opposite of stale staging.

The probe nonetheless recorded `status: fail`
(`failure_detail: "metrics did not report documents_count > 0 within the scrape
window"`). Root cause is a **repo-owned probe-tooling (L1) defect**, not a
Metrics-tab defect: the staging engine emits `fetched_at` with **nanosecond**
precision (e.g. `2026-07-11T01:03:15.766682746+00:00`, 9 fractional digits), and
the probe's Python validators call `datetime.datetime.fromisoformat(...)`
(`customer_metrics_endpoint_authenticated_probe.sh:122` in `metrics_shape_ok`
and `:265` in `metrics_tab_data_shape_ok`), which accepts only 3- or 6-digit
fractional seconds. Every one of the 12 population polls raised
`ValueError: Invalid isoformat string: '...'`, so the probe could never observe
the (present, 200-served) `documents_count`. Classified L1; filed as a
follow-up bug (`probe-nanosecond-fetched-at-parse`). The probe cleaned up after
itself (`index deleted`, `account delete attempted`, `admin cleanup completed`).

## Residual blind spot

Only the Documents KPI is pinned to an exact value; storage, search-requests,
and write-operations use well-formed value patterns rather than exact values
(recorded in the Stage 3 handoff — see that handoff for the rationale).
