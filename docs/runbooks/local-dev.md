# Local Development Runbook

Operator-oriented commands for bringing the local stack up, seeding it, and preparing for local launch-readiness validation.

## Canonical References

- Full setup and troubleshooting: [`docs/LOCAL_DEV.md`](../LOCAL_DEV.md)
- Local-only validation scope and pass criteria: this runbook plus [`docs/checklists/LOCAL_SIGNOFF_CHECKLIST.md`](../checklists/LOCAL_SIGNOFF_CHECKLIST.md)
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

`scripts/local-dev-up.sh` exports a path-derived `COMPOSE_PROJECT_NAME` before
it calls `docker compose`, which keeps each worktree isolated from sibling
worktrees with the same directory basename. Set `COMPOSE_PROJECT_NAME`
explicitly in your shell when you need an override.

Because `scripts/local-dev-up.sh` runs as a child process, its export does not
persist in your parent shell. For status/troubleshooting commands in your shell,
resolve the same project name directly via `scripts/lib/compose_project.sh`.

The startup summary prints the resolved flapjack binary path, helper-owned
source receipt provenance when a selected checkout is built or reused, and
secret-safe admin-key status for verification — see
[`docs/LOCAL_DEV.md`](../LOCAL_DEV.md) for details.

Local services are accepted only when they satisfy the checked-in compatibility
contract. `scripts/lib/flapjack_binary.sh` owns the exact supported Flapjack
version, selected-source Cargo build, source receipt validation, release
artifact exceptions, binary identity, and provenance summary.
`scripts/lib/local_stack_contract.sh` owns runtime `/health` identity and
capability comparison. Local startup, integration startup, the Playwright local
stack, browser preflight, and local signoff consume those helper seams and fail
closed when a selected source checkout cannot build or validate. The API's
`/version` response advertises named capabilities, and browser preflight rejects
a live but stale API that lacks a capability the dashboard requires. A green
`/health` response proves liveness only; it is never treated as compatibility.

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
restart-ready Flapjack discovery, including helper-owned source receipt
provenance for selected checkouts, while redacting secret values. A selected
`FLAPJACK_DEV_DIR` source build or receipt failure is fatal here; local signoff
does not fall back to a `PATH` artifact for that case.

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

Use this runbook for scope, pass bars, and blocker semantics. Use
[`docs/checklists/LOCAL_SIGNOFF_CHECKLIST.md`](../checklists/LOCAL_SIGNOFF_CHECKLIST.md)
for the exact operator execution order.

## Service Endpoints

- Web portal: `http://localhost:5173` (override via `LOCAL_WEB_PORT`)
- API: `http://localhost:3001` (override via `PLAYWRIGHT_API_PORT`)
- Postgres: host/port derived from `DATABASE_URL` (override host port via `LOCAL_DB_PORT`)

| Env var | Default | Service |
| --- | --- | --- |
| `LOCAL_WEB_PORT` | `5173` | SvelteKit web dev server |
| `PLAYWRIGHT_API_PORT` | `3001` | Local API HTTP endpoint |
| `LOCAL_DB_PORT` | `5432` | Docker Postgres host bind |
| `LOCAL_S3_PORT` | `8333` | SeaweedFS S3-compatible endpoint |
| `LOCAL_MAILPIT_UI_PORT` | `8025` | Mailpit web UI |
| `LOCAL_SMTP_PORT` | `1025` | Mailpit SMTP endpoint |

## Common Commands

Clean stale local E2E fixture database rows without resetting the whole stack:

```bash
bash scripts/cleanup_dev_orphans.sh
bash scripts/cleanup_dev_orphans.sh --apply
bash scripts/dev_state_audit.sh
```

The first command is a dry-run that prints the exact stale fixture tenants,
exclusive deployments, and `e2e-seed-%` VM inventory rows eligible for cleanup.
Use `--apply` only after reviewing that plan, then keep
`scripts/dev_state_audit.sh` as the canonical verifier for the Stage 3 local
seed-state contract.

Use a full local reset as the broader fallback when targeted cleanup is not
enough:

```bash
scripts/local-dev-down.sh --clean && scripts/local_demo.sh
```

Stop the stack but keep local data:

```bash
scripts/local-dev-down.sh
```

Inspect flapjack logs:

```bash
cat .local/flapjack.log
```

Check Docker and flapjack status (project-scoped for multi-worktree safety):

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
source "$REPO_ROOT/scripts/lib/compose_project.sh"
docker compose --project-name "$(resolve_compose_project_name "$REPO_ROOT")" ps
cat "$REPO_ROOT/.local/flapjack.pid"
```

Using the resolver-derived project name keeps status checks aligned with
`scripts/local-dev-up.sh` and avoids reading another worktree's stack.

## Usage Notes

- `scripts/local-dev-up.sh` remains the canonical local bring-up path and runs migrations through Docker Postgres.
- `scripts/local-dev-migrate.sh` uses host `psql` when available and falls back to Docker Postgres when it is not; see [`docs/LOCAL_DEV.md`](../LOCAL_DEV.md) for the detailed migration-access and troubleshooting guidance.
- For local launch signoff, follow [`docs/checklists/LOCAL_SIGNOFF_CHECKLIST.md`](../checklists/LOCAL_SIGNOFF_CHECKLIST.md) instead of inventing ad hoc coverage each time.
- If the local stack behavior changes, update the canonical docs in the same PR rather than extending this runbook with duplicate prose.
