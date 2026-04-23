# Local Development Runbook

Operator-oriented commands for bringing the local stack up, seeding it, and preparing for local launch-readiness validation.

## Canonical References

- Full setup and troubleshooting: [`docs/LOCAL_DEV.md`](../LOCAL_DEV.md)
- Local-only validation scope and pass criteria: [`docs/LOCAL_LAUNCH_READINESS.md`](../LOCAL_LAUNCH_READINESS.md)
- Exact local signoff run order: [`docs/checklists/LOCAL_SIGNOFF_CHECKLIST.md`](../checklists/LOCAL_SIGNOFF_CHECKLIST.md)
- Environment variable contract: [`docs/env-vars.md`](../env-vars.md)

## Bring Up The Stack

```bash
# Bootstrap .env.local from the example template (first-run only; safe to rerun):
scripts/bootstrap-env-local.sh

scripts/local-dev-up.sh
scripts/api-dev.sh
scripts/web-dev.sh
```

`scripts/local-dev-up.sh` auto-runs the bootstrap when `.env.local` is missing,
so the explicit call above is optional for most workflows.

The startup summary prints the resolved flapjack binary path and secret-safe
admin-key status for verification — see [`docs/LOCAL_DEV.md`](../LOCAL_DEV.md)
for details.

For the recommended local-only `.env.local` toggles, see [`docs/LOCAL_DEV.md`](../LOCAL_DEV.md) Environment Files.

## Seed And Preflight

```bash
bash scripts/seed_local.sh
bash scripts/seed_local.sh
cd web && npm ci
bash scripts/e2e-preflight.sh
cd web && npx playwright test -c playwright.config.ts tests/fixtures/auth.setup.ts tests/fixtures/admin.auth.setup.ts --project=setup:user --project=setup:admin --reporter=line
```

Notes:

- `seed_local.sh` is intentionally safe to run twice.
- Run `cd web && npm ci` once per checkout (or after lockfile changes) before any `npx playwright ...` command.
- If host `psql` is unavailable, `seed_local.sh` falls back to `docker compose exec postgres psql ...`.
- The seed path now covers multiple shared regions plus free/shared local tenants.
- `bash scripts/e2e-preflight.sh` checks the local browser-unmocked prerequisites before Playwright runs. Preflight auto-resolves `E2E_ADMIN_KEY` from `ADMIN_KEY` in `.env.local` and defaults user credentials to seed values — see [`docs/env-vars.md`](../env-vars.md) for the full fallback chain.
- When `BASE_URL` is unset, Playwright starts the local web dev server without unsafe reuse, so preflight only requires the Rust API to be up in that default path. If you override `BASE_URL`, you own a strict local frontend server and preflight will verify that URL before the browser run begins.
- If your machine is on Node 25 or another unsupported runtime, switch to Node 22 LTS before trusting browser-unmocked failures.
- For Phase 6 load validation, use `LOAD_PREPARE_LOCAL=1 LOAD_GATE_LIVE=1 bash scripts/load/run_load_harness.sh` so the harness prepares its own local load user/index first. That signoff path now defaults to the same `local_fixed` profile used for approved baselines; set `LOAD_K6_MODE=script` only when you intentionally want the heavier staged workload for investigation.
- For Phase 6 reliability capture, run `bash scripts/integration-up.sh --check-prerequisites` first. The prerequisite check confirms that a `FLAPJACK_ADMIN_KEY` is configured without printing the secret value and names the specific blocker when Docker Postgres fallback fails. The integration startup summary prints `Node secret:` and `Flapjack URL:` so operators can verify the isolated stack env before profiling.
- For Phase 6 load validation, the live harness now emits regression JSON even if script-level k6 thresholds fire, so the remaining blocker is measured baseline drift rather than opaque harness exits.

## Local Signoff

Fail fast on host/tooling/env blockers before any destructive HA proof run:

```bash
./scripts/local-signoff.sh --check-prerequisites
```

Use this output as prerequisite evidence. It validates strict-signoff inputs and
restart-ready Flapjack discovery while redacting secret values.

Then run the full orchestrator:

```bash
./scripts/local-signoff.sh
```

Top-level orchestrator that validates the strict signoff env prerequisites,
then delegates in deterministic order to three proof-owner scripts:

1. `scripts/local-signoff-commerce.sh` — billing, email, and local commerce mocks
2. `scripts/local-signoff-cold-storage.sh` — SeaweedFS-backed cold-storage round-trip
3. `scripts/chaos/ha-failover-proof.sh` — HA failover kill/detect/promote/recover cycle

Execution is fail-fast: if a proof fails, later proofs are skipped (`SKIP` in
the human summary, `not_run` in `summary.json`). Artifacts are written to a
run-scoped directory under `${TMPDIR:-/tmp}/fjcloud-local-signoff-*`.

To rerun a single proof after a failure:

```bash
./scripts/local-signoff.sh --only commerce
./scripts/local-signoff.sh --only cold-storage
./scripts/local-signoff.sh --only ha
```

Use [`docs/LOCAL_LAUNCH_READINESS.md`](../LOCAL_LAUNCH_READINESS.md) for
scope, pass bars, and blocker semantics.
Use [`docs/checklists/LOCAL_SIGNOFF_CHECKLIST.md`](../checklists/LOCAL_SIGNOFF_CHECKLIST.md)
for the exact operator execution order.

## Service Endpoints

- Web portal: `http://localhost:5173`
- API: `http://localhost:3001`
- Postgres: host/port derived from `DATABASE_URL`

## Common Commands

Reset the local database:

```bash
scripts/local-dev-down.sh --clean
scripts/local-dev-up.sh
```

Stop the stack but keep local data:

```bash
scripts/local-dev-down.sh
```

Inspect flapjack logs:

```bash
cat .local/flapjack.log
```

Check Docker and flapjack status:

```bash
docker compose ps
cat .local/flapjack.pid
```

## Usage Notes

- `scripts/local-dev-up.sh` remains the canonical local bring-up path and runs migrations through Docker Postgres.
- `scripts/local-dev-migrate.sh` uses host `psql` when available and falls back to Docker Postgres when it is not; see [`docs/LOCAL_DEV.md`](../LOCAL_DEV.md) for the detailed migration-access and troubleshooting guidance.
- For local launch signoff, follow the scenario matrix in [`docs/LOCAL_LAUNCH_READINESS.md`](../LOCAL_LAUNCH_READINESS.md) instead of inventing ad hoc coverage each time.
- If the local stack behavior changes, update the canonical docs in the same PR rather than extending this runbook with duplicate prose.
