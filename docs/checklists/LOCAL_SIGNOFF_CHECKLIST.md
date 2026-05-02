# Local Signoff Checklist

Concrete local-only execution order for proving Flapjack Cloud is ready for the next launch phase without AWS, Stripe, SES, or production credentials.

Use this together with [`docs/LOCAL_DEV.md`](../LOCAL_DEV.md) (strict env
source of truth) and [`docs/LOCAL_LAUNCH_READINESS.md`](../LOCAL_LAUNCH_READINESS.md)
(readiness pass bars).

## Phase 0: Rules

- Do not use real AWS, Stripe, SES, or production credentials for this checklist.
- Prefer deterministic local fixtures and seeded data over manual improvisation.
- Prefer the strict local signoff env profile in [`docs/LOCAL_DEV.md`](../LOCAL_DEV.md) over quick-start shortcuts. In practice this means `STRIPE_LOCAL_MODE=1`, `MAILPIT_API_URL`, `STRIPE_WEBHOOK_SECRET`, `COLD_STORAGE_*`, `FLAPJACK_REGIONS`, `AUTH_RATE_LIMIT_RPM`, `ADMIN_RATE_LIMIT_RPM`, `TENANT_RATE_LIMIT_RPM`, `DEFAULT_MAX_QUERY_RPS`, `DEFAULT_MAX_WRITE_RPS`, and `DEFAULT_MAX_INDEXES` should be set, while `SKIP_EMAIL_VERIFICATION` must stay unset and `DATABASE_URL` must remain present from the base `.env.local` setup.
- Treat `./scripts/local-signoff.sh --check-prerequisites` and `bash scripts/integration-up.sh --check-prerequisites` as the canonical prerequisite evidence commands; capture redacted status output, not raw secret values.
- If a scenario is skipped, record the current blocker and the exact missing harness or dependency.
- If local behavior changes while running this checklist, update the affected docs in the same PR.

## Phase 1: Local Stack Bring-Up

- [x] Copy `.env.local.example` to `.env.local`
- [x] Set local secrets in `.env.local`
- [x] Confirm the recommended local-only toggles from [`docs/LOCAL_DEV.md`](../LOCAL_DEV.md) Environment Files are present in `.env.local`
- [x] For strict signoff, confirm `.env.local` matches the strict profile in [`docs/LOCAL_DEV.md`](../LOCAL_DEV.md), including `STRIPE_LOCAL_MODE=1`, `MAILPIT_API_URL`, `STRIPE_WEBHOOK_SECRET`, `COLD_STORAGE_*`, `FLAPJACK_REGIONS`, and the local signoff-only rate-limit/load overrides; keep `SKIP_EMAIL_VERIFICATION` unset and keep `DATABASE_URL` present

- [x] Start local infrastructure:

```bash
scripts/local-dev-up.sh
```

- [x] Verify the startup summary prints the resolved flapjack binary path; treat admin-key output as secret-safe status only (never a raw `FLAPJACK_ADMIN_KEY` value).
- [x] Capture fail-fast strict prerequisite evidence before orchestrator proofs:

```bash
./scripts/local-signoff.sh --check-prerequisites
```

Record success/failure lines for tools, strict env validation, and flapjack binary resolution from this command output.

- [x] Start the API:

```bash
scripts/api-dev.sh
```

- [x] Start the web app:

```bash
scripts/web-dev.sh
```

- [x] Confirm the browser toolchain uses Node 20.19+ or Node 22.12+ before trusting browser-unmocked failures
- [x] Confirm flapjack is healthy before document/search validation:

```bash
curl -sf http://127.0.0.1:7700/health
```

- [x] Confirm SeaweedFS and Mailpit are healthy before trusting local email or cold-storage evidence:

```bash
curl -sf http://localhost:8333/
curl -sf http://localhost:8025/api/v1/info
```

- [x] Seed local data twice to prove idempotency:

```bash
./scripts/seed_local.sh
./scripts/seed_local.sh
```

- [x] Run browser preflight:

```bash
bash scripts/e2e-preflight.sh
```

Pass bar:

- API reachable on `http://localhost:3001`
- Web reachable on `http://localhost:5173`
- Flapjack reachable on `http://127.0.0.1:7700`
- SeaweedFS reachable on `http://localhost:8333`
- Mailpit reachable on `http://localhost:8025`
- Seed script succeeds twice
- Billing estimate smoke check in `seed_local.sh` succeeds without requiring host `psql`
- The `.env.local` used for evidence is clearly a strict signoff profile, not a quick-start profile with `SKIP_EMAIL_VERIFICATION=1`

Run note:

- The first Mar 27 evidence sweep used Node `v25.6.1`, but browser signoff was later re-run on supported Node `v22.22.2`, which closes the runtime checkbox for local launch evidence.

## Phase 1.5: Automated Signoff Orchestrator

Run the top-level orchestrator after the local stack is up and seeded. This is
the canonical automated signoff entry point that validates the strict env,
then delegates to the three proof-owner scripts in deterministic order:
`commerce -> cold-storage -> ha`.

- [ ] Run the orchestrator:

```bash
./scripts/local-signoff.sh
```

The orchestrator:

- Validates the strict signoff env prerequisites (see [`docs/LOCAL_DEV.md`](../LOCAL_DEV.md) Strict Local Signoff)
- Creates a run-scoped artifact directory under `${TMPDIR:-/tmp}/fjcloud-local-signoff-*`
- Delegates to `scripts/local-signoff-commerce.sh`, `scripts/local-signoff-cold-storage.sh`, and `scripts/chaos/ha-failover-proof.sh` in order
- Uses fail-fast semantics: if a proof fails, later proofs are `SKIP`ped
- Writes `summary.json` and prints a human summary with per-proof `PASS`/`FAIL`/`SKIP`

- [ ] Record the artifact directory path and `summary.json` location
- [ ] If any proof failed, use `--only {commerce|cold-storage|ha}` to rerun that proof after fixing the issue
- [ ] Treat the orchestrator artifact directory as the canonical signoff record (`summary.json`, `commerce.log`, `cold_storage.log`, `ha_seed.log`, `ha.log`); use proof-owner wrapper artifacts only as secondary debugging context

Pass bar:

- All three proofs show `PASS` in the human summary
- `summary.json` shows `"overall":"pass"` with all proofs at `"status":"pass"`
- Artifact directory contains per-proof logs (`commerce.log`, `cold_storage.log`, `ha.log`) and the HA seed refresh log (`ha_seed.log`)
- A passing HA proof also means the orchestrator's post-HA gate reached the API
  health endpoint and every configured `FLAPJACK_REGIONS` health endpoint

Blocker classification guidance for prerequisite checks:

- Missing `docker`, `curl`, or `jq`: record as tooling blocker with the exact missing command.
- Malformed strict-signoff env (`FLAPJACK_REGIONS`, `DATABASE_URL`, or `SKIP_EMAIL_VERIFICATION` set when strict profile requires unset): record as strict-env validation blocker and link to [`docs/LOCAL_DEV.md`](../LOCAL_DEV.md).
- No restart-ready Flapjack binary after explicit/candidate/default directory lookup: record as flapjack-binary blocker and link to [`docs/env-vars.md`](../env-vars.md).
- Autodiscovery miss on nonstandard host layout: set explicit `FLAPJACK_DEV_DIR`, rerun prerequisite checks, and record the host-layout blocker if unresolved.

## Phase 2: Browser-Unmocked Customer Flows

- [x] Lint browser specs:

```bash
cd web && npm run lint:e2e
```

Compliance note: this is the browser-unmocked spec gate. It must pass with 0
errors before Playwright results are trusted; accepted warnings remain cleanup
debt and do not allow `waitForTimeout()`, raw selectors, forced actions,
`evaluate()`, or spec-local API shortcuts.

- [x] Validate screen spec coverage map:

```bash
bash scripts/tests/screen_specs_coverage_test.sh
```

- [x] Run core customer/account/browser flows:

```bash
cd web && npx playwright test \
  tests/e2e-ui/full/dashboard.spec.ts \
  tests/e2e-ui/full/settings.spec.ts \
  tests/e2e-ui/full/billing.spec.ts
```

- [x] Run tenant-isolation coverage:

```bash
cd web && npx playwright test tests/e2e-ui/full/isolation.spec.ts
```

- [x] Real-Safari smoke (operator-driven, macOS only):

  Open `cloud.flapjack.foo` in Safari and walk: signup → email verify → dashboard
  → billing portal opens. ~5 minutes. Catches Stripe 3DS / ITP / Apple Pay
  quirks that Playwright-on-Linux WebKit cannot.

  Firefox/WebKit Playwright projects were dropped 2026-05-02 (see
  `web/playwright.config.contract.ts` for the SSOT browser list). WebKit-on-Linux
  isn't real Safari, and Firefox is ~3-6% of users — neither earned its CI cost
  at paid-beta scale.

Pass bar:

- Signup/login reaches dashboard locally
- Settings flows work, including password change and account deletion for throwaway users
- Billing UI renders without requiring real Stripe
- Dashboard estimated-bill coverage passes, or any skip names a current billing-data blocker
- Isolation coverage proves no cross-tenant leakage
- Real Safari signup→dashboard→billing-portal walk completes without error

## Phase 3: Browser-Unmocked Admin And Support Flows

- [x] Run admin shell and workflow coverage:

```bash
cd web && npx playwright test \
  tests/e2e-ui/full/admin/admin-pages.spec.ts \
  tests/e2e-ui/full/admin/customer-detail.spec.ts
```

Pass bar:

- Admin customer list and detail routes render
- Status filters behave correctly
- Suspend/reactivate works locally
- Impersonation works locally and returns to the exact customer detail route
- Soft delete behavior remains consistent with status filtering

## Phase 4: Local Reliability And Failover Logic

- [x] Run local health-monitor pipeline coverage:

```bash
cd infra && cargo test -p api --test integration_health_monitor_test
```

- [x] Run region failover coverage:

```bash
cd infra && cargo test -p api --test region_failover_test
```

Pass bar:

- Pure Rust health-monitor crash/recovery tests pass
- Region failover tests pass, including promotion, unhealthy-replica avoidance, and recovery behavior
- Any live destructive crash/restart step skipped by env gating is recorded as a harness limitation, not a feature limitation

## Phase 5: Local Billing, Email, And Mocked Commerce Logic

- [x] Run billing endpoint coverage with mock Stripe behavior:

```bash
cd infra && cargo test -p api --test billing_endpoints_test
```

- [x] Run Stripe-facing mock lifecycle tests:

```bash
cd infra && cargo test -p api --test stripe_billing_test
cd infra && cargo test -p api --test subscription_lifecycle_test
```

Pass bar:

- Billing estimate and invoice logic pass locally with mocks
- LocalStripeService-backed billing paths are covered by tests, and any live local batch-billing run confirms that seeded customers already have a `stripe_customer_id` after `scripts/seed_local.sh` when `STRIPE_LOCAL_MODE=1`
- If a seeded user still needs a manual `/admin/customers/:id/sync-stripe` call, record it as a current local regression/blocker
- Mailpit-backed email behavior is either exercised directly in the local run or recorded as a current local blocker
- No local signoff step requires `STRIPE_TEST_SECRET_KEY`

## Phase 5.5: Cold Storage Signoff

The cold-storage proof runs automatically as part of `./scripts/local-signoff.sh`
(Phase 1.5). To rerun only the cold-storage proof:

```bash
./scripts/local-signoff.sh --only cold-storage
```

This delegates to `scripts/local-signoff-cold-storage.sh`, which calls the
Rust integration test
`integration_cold_tier_test::cold_tier_full_lifecycle_s3_round_trip` via a thin
env bridge. Requires `COLD_STORAGE_ENDPOINT`, `COLD_STORAGE_BUCKET`,
`COLD_STORAGE_REGION`, and `DATABASE_URL` (or `INTEGRATION_DB_URL`) in the
strict local signoff profile.

- [ ] Confirm cold-storage proof shows `PASS` in the orchestrator summary (Phase 1.5), or run the scoped rerun above
- [ ] Record the orchestrator artifact evidence paths for `summary.json` and `cold_storage.log`
- [ ] If used for debugging, record the wrapper's operator-readable `.txt` summary path as secondary evidence

Pass bar:

- The orchestrator artifact directory remains the default signoff evidence source (`summary.json`, `commerce.log`, `cold_storage.log`, `ha.log`)
- The wrapper may emit JSON and operator-readable evidence files for debugging, but those outputs do not replace orchestrator summary evidence
- If the test passes, the evidence records a successful SeaweedFS-backed cold-storage round-trip
- If the test fails or the local stack is unavailable, record the exact failure output as blocker evidence — do not treat failure evidence as successful signoff

## Phase 6: Local Load And Profiling

- [x] Run the local load harness in live-local mode if `k6` is available:

```bash
LOAD_PREPARE_LOCAL=1 LOAD_GATE_LIVE=1 bash scripts/load/run_load_harness.sh
```

This authoritative signoff path defaults to the same `local_fixed` profile used
for approved baselines. Use `LOAD_K6_MODE=script` only for heavier
troubleshooting runs, not for the baseline-comparison signoff pass.

- [x] Check integration-stack prerequisites for reliability profiling:

```bash
bash scripts/integration-up.sh --check-prerequisites
```

- [x] Verify the `--check-prerequisites` output reports redacted `FLAPJACK_ADMIN_KEY` status (configured/not configured) so reliability probes can be gated without exposing secret values.

- [x] Run reliability profiling if the integration stack is available:

```bash
bash scripts/integration-up.sh
RELIABILITY=1 scripts/reliability/capture-all.sh
bash scripts/tests/reliability_profile_test.sh
```

Pass bar:

- Load harness emits JSON and does not require cloud credentials
- `LOAD_PREPARE_LOCAL=1` can prepare a dedicated local load user/index; if it fails, record the exact setup error as the current local blocker
- If `k6` is missing, the skip is recorded as `LOAD_K6_SKIP_TOOL_MISSING`
- Reliability profile artifacts are generated or the missing local prerequisite is clearly recorded
- If `bash scripts/integration-up.sh --check-prerequisites` fails, record the missing prerequisite exactly; do not collapse it into a generic reliability failure

Run note:

- Mar 27 load prep exposed a real soft-delete contract: deleting `loadtest-signoff@example.com` in admin does not free that email for re-registration. `scripts/load/setup-local-prereqs.sh` now rotates to a fresh `loadtest-signoff+recreated-...@example.com` address when that deleted-email conflict is present.
- Record the latest run-scoped load artifact directory, command, branch, and commit in the evidence note; do not treat one temp path as permanent truth.
- Local baseline comparison now ignores latency drift of `<=50ms` on already-fast loopback endpoints before applying percentage regression logic, which prevents false failures when explicit k6 SLAs still pass comfortably.

## Phase 7: Evidence And Exit

- [x] Copy the evidence template from [`LOCAL_SIGNOFF_EVIDENCE_TEMPLATE.md`](./LOCAL_SIGNOFF_EVIDENCE_TEMPLATE.md)
- [x] Record every suite run, pass/fail result, and blocker
- [x] Separate local-only blockers from live-credential blockers
- [x] Update docs if real local behavior differed from the checklist
- [x] Store ad hoc artifacts outside the repo tree and link or summarize them from the evidence note

Local signoff is complete when:

- The local stack can be brought up from docs without tribal knowledge
- Core customer, admin, isolation, billing, failover, and strict-signoff env selection have local evidence
- Remaining gaps are explicitly live-only or intentionally deferred scope-expansion items, not hidden in stale comments
