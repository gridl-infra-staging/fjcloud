# Local Development

## Prerequisites

- **Docker** — Docker Desktop or compatible runtime (`docker compose` required)
- **Rust toolchain** — install via [rustup.rs](https://rustup.rs)
- **Node.js** — v20.19+ or v22.12+ with npm. Node 22 LTS is the recommended local signoff runtime.
- **flapjack_dev repo** — clone adjacent to this repo, build with `cd engine && cargo build -p flapjack-server` (produces `engine/target/debug/flapjack`)

> **Note:** A host `psql` binary is **not** required for the standard local
> bring-up flow. `scripts/local-dev-up.sh`, `scripts/local-dev-migrate.sh`,
> `scripts/seed_local.sh`, `scripts/start-metering.sh`, and
> `scripts/integration-up.sh` can use Docker Postgres access when the host
> client is absent. `scripts/local-dev-migrate.sh` still uses host `psql` as an
> optional fast path when available, and otherwise falls back to
> `docker compose exec -T postgres env PGPASSWORD=<password> psql -h 127.0.0.1 -U <user> -d <database>`,
> with credentials parsed from `DATABASE_URL` and SQL applied from
> `/migrations` inside the Postgres container.

## Quick Start

```bash
./scripts/local_demo.sh
```

Use [`docs/LOCAL_QUICKSTART.md`](./LOCAL_QUICKSTART.md) for the concise
one-command walkthrough. The API runs at `http://localhost:3001`, the frontend
at `http://localhost:5173`.

Manual component startup is still available when you need to debug a single
piece:

```bash
scripts/local-dev-up.sh
scripts/api-dev.sh
scripts/web-dev.sh
./scripts/seed_local.sh
scripts/start-metering.sh --multi-region
scripts/run-aggregation-job.sh
```

`scripts/local-dev-up.sh` derives the Docker Postgres host bind from the port in
`DATABASE_URL`, so a local URL such as `postgres://...@localhost:15432/...`
works without a separate manual proxy. The startup summary prints the resolved
flapjack binary path and whether a flapjack admin key is configured, without
echoing the secret value into terminal output.

After the stack is up, use [`docs/LOCAL_LAUNCH_READINESS.md`](./LOCAL_LAUNCH_READINESS.md)
for the local-only validation matrix and [`docs/checklists/LOCAL_SIGNOFF_CHECKLIST.md`](./checklists/LOCAL_SIGNOFF_CHECKLIST.md)
for the exact execution order.

## Full Simulation Stack (P0)

The local dev stack simulates every production service with zero internet
dependency. `scripts/local-dev-up.sh` starts Docker services and Flapjack
automatically; metering and aggregation are started manually after seeding.

| Production Service    | Local Replacement                                                     | How it starts                                                              |
| --------------------- | --------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| AWS EC2 VMs           | 3 Flapjack processes (ports 7700/7701/7702)                           | `local-dev-up.sh` (auto)                                                   |
| AWS S3 (cold storage) | SeaweedFS Docker container (port 8333)                                | `local-dev-up.sh` via `docker-compose.yml` (auto)                          |
| AWS SES (email)       | Mailpit Docker container (port 8025)                                  | `local-dev-up.sh` via `docker-compose.yml` (auto)                          |
| Stripe billing        | `LocalStripeService` — stateful in-process mock with webhook dispatch | API startup when `STRIPE_LOCAL_MODE=1` (auto)                              |
| Metering agent        | `metering-agent` crate binary                                         | `scripts/start-metering.sh` (manual, after seed)                           |
| Aggregation job       | `aggregation-job` crate binary                                        | `scripts/run-aggregation-job.sh` (manual)                                  |
| Health monitor / HA   | Chaos scripts for kill/restart                                        | `scripts/chaos/kill-region.sh`, `scripts/chaos/restart-region.sh` (manual) |

### Email (Mailpit)

When `MAILPIT_API_URL` is set in `.env.local`, the API uses `MailpitEmailService`
instead of `NoopEmailService`. Emails are sent via Mailpit's HTTP JSON API
(`POST /api/v1/send`) using `reqwest` (already in workspace — no new deps).
View caught emails at `http://localhost:8025`. Tags (`verification`,
`password-reset`, `invoice`, `quota-warning`) let you filter by email type.

### Billing (LocalStripeService)

When `STRIPE_LOCAL_MODE=1` is set and `STRIPE_SECRET_KEY` is absent, the API
starts a stateful in-memory Stripe mock. It stores customers, subscriptions,
invoices, and payment methods. A background `WebhookDispatcher` task signs
events with HMAC-SHA256 and POSTs them to the API's `/webhooks/stripe`
endpoint, exactly like real Stripe. Set `STRIPE_WEBHOOK_SECRET` to match
between the API and the dispatcher (defaults to `whsec_local_dev_secret`).

### Cold Storage (SeaweedFS)

SeaweedFS provides an S3-compatible API on port 8333. The API's `S3ObjectStore`
connects to it when the strict local profile sets
`COLD_STORAGE_ENDPOINT=http://localhost:8333` along with
`COLD_STORAGE_BUCKET`, `COLD_STORAGE_REGION`, `COLD_STORAGE_ACCESS_KEY`, and
`COLD_STORAGE_SECRET_KEY`. These are deterministic local-only credentials from
`ops/seaweedfs_s3_config.json`; do not replace them with real AWS credentials.
Buckets are created by the signed cold-storage proof. Data persists across
restarts via a Docker volume.
The cold-storage proof is run automatically by `./scripts/local-signoff.sh`
(which delegates to `scripts/local-signoff-cold-storage.sh`). That wrapper
calls the Rust integration test
`integration_cold_tier_test::cold_tier_full_lifecycle_s3_round_trip` rather
than requiring manual SeaweedFS probing. For a scoped rerun, use
`./scripts/local-signoff.sh --only cold-storage`.

### Metering and Aggregation

`scripts/start-metering.sh` looks up a shared-plan customer UUID from the
database (seeded by `seed_local.sh`) and starts the metering agent, which
scrapes Flapjack `/metrics` every 30s and writes `usage_records` to Postgres.
Use `--multi-region` to start one agent per region in `FLAPJACK_REGIONS`.

`scripts/run-aggregation-job.sh` rolls up raw usage records into `usage_daily`.
Idempotent — safe to run multiple times for the same date.

### Chaos Testing

Simulate region failures to exercise the health monitor:

```bash
# Kill a region (the script prints the current config-derived timing)
scripts/chaos/kill-region.sh eu-west-1

# Restart it (the script prints the current config-derived recovery window)
scripts/chaos/restart-region.sh eu-west-1
```

The full automated HA proof is run by `./scripts/local-signoff.sh` (which
delegates to `scripts/chaos/ha-failover-proof.sh`). For a scoped rerun, use
`./scripts/local-signoff.sh --only ha`.

### Multi-Region Mode

Set `FLAPJACK_REGIONS` in `.env.local` to start multiple Flapjack processes:

```bash
FLAPJACK_REGIONS="us-east-1:7700 eu-west-1:7701 eu-central-1:7702"
```

`local-dev-up.sh` starts one Flapjack per entry. Each mapping must use a plain
numeric TCP port, for example `eu-west-1:7701` rather than a URL fragment.
`seed_local.sh` creates
per-region VM inventory. `start-metering.sh --multi-region` starts one metering
agent per region with auto-derived health ports (9091, 9092, 9093).

## Standalone Flapjack Smoke Test

Verify the Flapjack binary works in isolation — no Docker, no `.env.local`, no
API/web processes. This proves the build artifact from
[Prerequisites](#prerequisites) is functional before involving `local-dev-up.sh`.

```bash
# 1. Build (if not already done)
cd /path/to/flapjack_dev/engine && cargo build -p flapjack-server

# 2. Start Flapjack on loopback with a disposable data directory
./target/debug/flapjack --port 7700 --data-dir /tmp/flapjack-smoke &
FLAPJACK_PID=$!

# 3. Wait briefly, then probe the health endpoint
sleep 2
curl -sf http://127.0.0.1:7700/health | grep '"status":"ok"'

# 4. Clean up
kill "$FLAPJACK_PID"
rm -rf /tmp/flapjack-smoke
```

Expected: `curl` returns JSON containing `"status":"ok"`. The `--port 7700`
flag binds to `127.0.0.1:7700` by default (see `resolve_bind_addr()` in
`flapjack-server/src/main.rs`). The `/health` endpoint is unauthenticated
(see `is_public_path()` in `flapjack-http/src/auth/middleware.rs`).

## Environment Files

- **`.env.local`** (repo root) — canonical local-dev config for the Rust API and
  local helper scripts (`DATABASE_URL`, `JWT_SECRET`, `ADMIN_KEY`,
  `LISTEN_ADDR`, `RUST_LOG`, `FLAPJACK_PORT`, optional `FLAPJACK_URL`,
  `LOCAL_DEV_FLAPJACK_URL`, `SKIP_EMAIL_VERIFICATION`, `NODE_SECRET_BACKEND`,
  `MAILPIT_API_URL`, `STRIPE_LOCAL_MODE`, `FLAPJACK_REGIONS`)
- **`web/.env.local`** — optional web override file (`API_BASE_URL=http://127.0.0.1:3001`)

Run `scripts/bootstrap-env-local.sh` to generate `.env.local` from the example
template with randomly generated `JWT_SECRET` and `ADMIN_KEY` values.
`scripts/local-dev-up.sh` auto-runs the bootstrap when `.env.local` is missing.
The bootstrap never overwrites an existing `.env.local`, so hand edits are safe.
See `.env.local.example` for the full variable reference.

Use one of the two profiles below. Keep this section as the canonical source of
truth and have other docs link here instead of copying env guidance.

### Quick Local Dev

Use this profile when you want the fastest local setup and do not need full
email-proof evidence:

```bash
API_BASE_URL=http://127.0.0.1:3001
SKIP_EMAIL_VERIFICATION=1
LOCAL_DEV_FLAPJACK_URL=http://127.0.0.1:7700
FLAPJACK_ADMIN_KEY=fj_local_dev_admin_key_000000000000
NODE_SECRET_BACKEND=memory
AUTH_RATE_LIMIT_RPM=120
ADMIN_RATE_LIMIT_RPM=1000
TENANT_RATE_LIMIT_RPM=5000
DEFAULT_MAX_QUERY_RPS=60
DEFAULT_MAX_WRITE_RPS=100
DEFAULT_MAX_INDEXES=100

# P0 local simulation services (see "Full Simulation Stack" above)
MAILPIT_API_URL=http://localhost:8025
EMAIL_FROM_ADDRESS=noreply@griddle.local
EMAIL_FROM_NAME=Flapjack Cloud Local Dev
STRIPE_LOCAL_MODE=1
STRIPE_WEBHOOK_SECRET=whsec_local_dev_secret
# FLAPJACK_REGIONS=us-east-1:7700 eu-west-1:7701 eu-central-1:7702
```

- `SKIP_EMAIL_VERIFICATION` auto-verifies new signups so local users can reach
  dashboard flows without waiting on email.
- This profile is for day-to-day development convenience, not strict launch
  signoff.
- `API_BASE_URL=http://127.0.0.1:3001` keeps the SvelteKit server on an IPv4
  loopback target that works reliably with the local auth forms and browser setup.

### Strict Local Signoff

Use this profile when collecting launch-readiness evidence:

```bash
API_BASE_URL=http://127.0.0.1:3001
LOCAL_DEV_FLAPJACK_URL=http://127.0.0.1:7700
FLAPJACK_ADMIN_KEY=fj_local_dev_admin_key_000000000000
NODE_SECRET_BACKEND=memory
DATABASE_URL=<reuse the value from your base .env.local setup>
MAILPIT_API_URL=http://localhost:8025
EMAIL_FROM_ADDRESS=noreply@griddle.local
EMAIL_FROM_NAME=Flapjack Cloud Local Dev
STRIPE_LOCAL_MODE=1
STRIPE_WEBHOOK_SECRET=whsec_local_dev_secret
COLD_STORAGE_BUCKET=griddle-cold-storage
COLD_STORAGE_ENDPOINT=http://localhost:8333
COLD_STORAGE_REGION=us-east-1
COLD_STORAGE_ACCESS_KEY=griddle_local_s3
COLD_STORAGE_SECRET_KEY=griddle_local_s3_secret
FLAPJACK_REGIONS=us-east-1:7700 eu-west-1:7701 eu-central-1:7702
AUTH_RATE_LIMIT_RPM=120
ADMIN_RATE_LIMIT_RPM=1000
TENANT_RATE_LIMIT_RPM=5000
DEFAULT_MAX_QUERY_RPS=60
DEFAULT_MAX_WRITE_RPS=100
DEFAULT_MAX_INDEXES=100
```

- Leave `SKIP_EMAIL_VERIFICATION` unset so a fresh signup can emit a real
  verification email into Mailpit.
- Keep `FLAPJACK_REGIONS` set so signoff evidence covers the multi-region local
  topology instead of the single-node shortcut.
- SeaweedFS-backed cold storage is part of the strict signoff env contract, and
  the canonical cold-tier integration proof now uses the same `COLD_STORAGE_*`
  env family instead of the old `LOCALSTACK_*` contract.
- `API_BASE_URL=http://127.0.0.1:3001` keeps the SvelteKit server on an IPv4
  loopback target that works reliably with the local auth forms and browser setup.
- `LOCAL_DEV_FLAPJACK_URL` makes shared-VM auto-provisioning insert `local`
  inventory rows instead of calling cloud provisioners. Use a loopback
  `http://` or `https://` URL. When `FLAPJACK_REGIONS` is also set and
  `FLAPJACK_SINGLE_INSTANCE` is not `1`, the API resolves the requested region
  to the matching local Flapjack port instead of reusing one shared endpoint.
- `FLAPJACK_ADMIN_KEY` keeps the local API and the single local flapjack
  process on the same admin key. This matters when `NODE_SECRET_BACKEND=memory`,
  because the in-memory node secret manager must generate the same key flapjack
  is actually enforcing. The isolated integration stack on ports `3099`/`7799`
  and the reliability profiling scripts now rely on the same contract.
- `NODE_SECRET_BACKEND=memory` keeps node API keys in-process when AWS SSM is
  unavailable.
- Keep `DATABASE_URL` set in this strict profile using the value from the base
  `.env.local` setup; do not replace it with a machine-specific example DSN in
  docs or evidence notes.
- `AUTH_RATE_LIMIT_RPM=120`, `ADMIN_RATE_LIMIT_RPM=1000`,
  `TENANT_RATE_LIMIT_RPM=5000`, `DEFAULT_MAX_QUERY_RPS=60`,
  `DEFAULT_MAX_WRITE_RPS=100`, and `DEFAULT_MAX_INDEXES=100` are local-only
  strict-signoff overrides so browser-unmocked and Phase 6 load checks measure
  app behavior instead of tripping conservative launch defaults.

Once the strict profile is active, run the top-level orchestrator:

```bash
./scripts/local-signoff.sh --check-prerequisites
```

Run this first when you need fail-fast triage before destructive HA proof
steps. It validates tool availability, strict-signoff env shape, and shared
restart-ready flapjack binary resolution, then exits before proof delegation or
artifact creation. Secret-bearing env checks stay redacted in output.

After prerequisites pass, run the full orchestrator:

```bash
./scripts/local-signoff.sh
```

This validates the strict env prerequisites (`require_strict_signoff_env`),
then delegates in deterministic order to `scripts/local-signoff-commerce.sh`,
`scripts/local-signoff-cold-storage.sh`, and `scripts/chaos/ha-failover-proof.sh`.
After each run:

- Use the printed `Artifacts:` path as the run-scoped evidence directory.
- Open `<artifact_dir>/summary.json` first to confirm the overall status and
  per-proof JSON statuses (`pass`, `fail`, or `not_run`). The terminal summary
  prints the same outcomes as `PASS`/`FAIL`/`SKIP` for quick scanning.
- Treat `${TMPDIR:-/tmp}/fjcloud-local-signoff-*` as a run-scoped pattern, not a
  permanent path.
- Before the HA proof, the orchestrator reruns `scripts/seed_local.sh` and
  writes that output to `ha_seed.log`; this keeps the HA candidate state tied to
  the same run-scoped evidence bundle as the proof logs.
- The HA proof intentionally kills and restarts the selected local Flapjack
  region, and its proof-owner artifacts are written under
  `/tmp/fjcloud-ha-proof/`. Treat those HA artifacts as debugging context unless
  the top-level orchestrator summary also passed.
- After the HA proof succeeds, the orchestrator checks the API health endpoint
  and every `FLAPJACK_REGIONS` health endpoint before it writes an overall pass.
  This keeps the signoff result tied to a recovered local stack, not only to a
  successful failover event.

Use `--only {commerce|cold-storage|ha}` only after the main run, to rerun a
specific failed proof while preserving the orchestrator summary as the
canonical signoff record.

For readiness pass bars and evidence expectations, see
[`docs/LOCAL_LAUNCH_READINESS.md`](./LOCAL_LAUNCH_READINESS.md). For the
exact checklist execution order, see
[`docs/checklists/LOCAL_SIGNOFF_CHECKLIST.md`](./checklists/LOCAL_SIGNOFF_CHECKLIST.md).

`scripts/web-dev.sh` sources root `.env.local` and `web/.env.local`, then starts
the SvelteKit dev server with the server-side auth env (`JWT_SECRET`,
`ADMIN_KEY`) the app needs for login redirects and admin routes. The wrapper
passes `--strictPort` by default so occupied ports fail closed instead of
sliding to a different Vite port.

Both are gitignored. Do not commit them.

## Phase 6 Validation Notes

For the Phase 6 local load harness, use:

```bash
LOAD_PREPARE_LOCAL=1 LOAD_GATE_LIVE=1 bash scripts/load/run_load_harness.sh
```

`LOAD_PREPARE_LOCAL=1` prepares a dedicated local load-test user and index before
the k6 run. If that setup fails, the harness now returns JSON with
`LOAD_LOCAL_PREP_FAILURE` instead of dropping straight into opaque k6 threshold
errors.

The authoritative signoff path now defaults to the same local fixed-profile
settings used by `scripts/load/approve-baselines.sh`, so the live harness and
the checked-in approved baselines measure the same workload shape. If you want
the heavier script-owned staged workload for investigation, set
`LOAD_K6_MODE=script` explicitly.

For seeded Search Preview local-dev flows, keep this in root `.env.local`:

```bash
NODE_SECRET_BACKEND=memory
```

This enables process-local node secret storage when AWS/SSM is not configured, so
`/admin/tenants/:id/indexes` with `flapjack_url` can seed a proxy-authenticated target.

## Seeded Search Preview

For the browser-unmocked Search Preview validation flow, bring up the stack
per [Quick Start](#quick-start), then seed and run preflight per
[`docs/runbooks/local-dev.md`](./runbooks/local-dev.md) Seed And Preflight.
See [`docs/env-vars.md`](./env-vars.md) for the E2E variable fallback chain.
When you set `BASE_URL` explicitly, you own that frontend process; start a
strict loopback server yourself with `scripts/web-dev.sh --host 127.0.0.1 --port 5173`.

Run the focused spec:

```bash
cd web
API_URL=http://127.0.0.1:3001 BASE_URL=http://127.0.0.1:5173 \
  npx playwright test tests/e2e-ui/full/indexes.spec.ts --grep "Search Preview tab shows real search results from Flapjack"
```

## Common Tasks

**Reset the database** (drop all data and re-migrate):

```bash
scripts/local-dev-down.sh --clean
scripts/local-dev-up.sh
```

**Stop everything** (keep data):

```bash
scripts/local-dev-down.sh
```

For day-to-day operator commands (viewing logs, checking services, seed/preflight),
see [`docs/runbooks/local-dev.md`](./runbooks/local-dev.md).

## Troubleshooting

**Port conflict** — If port 5432, 7700, or 3001 is already in use, stop the
conflicting process or override the port via environment variables
(`FLAPJACK_PORT`, `LISTEN_ADDR` in `.env.local`). For Postgres specifically,
set the host port in `DATABASE_URL` (for example `localhost:25432`) before
running `scripts/local-dev-up.sh`.

**API env vars from `.env.local` not taking effect** — use `scripts/api-dev.sh`
instead of launching Cargo directly. The wrapper uses `load_env_file` from
`scripts/lib/env.sh` to parse `.env.local` safely (rejecting executable shell
syntax) and export the variables before starting the Rust API.

**Flapjack binary not found** — set `FLAPJACK_DEV_DIR` to your local
`flapjack_dev` checkout (repo root or `engine/` subdirectory) first. The
restart-critical prerequisite callers (`./scripts/local-signoff.sh
--check-prerequisites`, `bash scripts/integration-up.sh --check-prerequisites`,
and HA restart helpers) try that explicit directory first, continue through
configured/default nearby directory candidates, and only then fall back to
`PATH`; they fail closed when no binary resolves. `scripts/local-dev-up.sh`
keeps its warning-only startup path when no local flapjack binary is found.
Build with `cd ../flapjack_dev/engine && cargo build -p flapjack-server` to
restore `engine/target/debug/flapjack`.

**Migration failures on rerun** — Migrations are tracked in a
`_schema_migrations` table and skip already-applied files on rerun. If a
migration fails mid-apply, fix the SQL and rerun `scripts/local-dev-up.sh`.
To start from scratch: `scripts/local-dev-down.sh --clean`.

**Existing Docker Postgres volume uses old credentials** — `scripts/local-dev-up.sh`
now detects when the stored role/database no longer match `.env.local` and
recreates the local Postgres volume automatically. Back up any data you need
before rerunning the script.

**psql not found** — Host `psql` is optional. `scripts/local-dev-migrate.sh`
uses host `psql` when available, otherwise it falls back to
`docker compose exec -T postgres env PGPASSWORD=<password> psql -h 127.0.0.1 -U <user> -d <database>`,
with credentials parsed from `DATABASE_URL` and migration files applied from
`/migrations`. If you get a `DATABASE_URL must include ...` error, fix the URL
in `.env.local` first (username/password/host/port/database are required for
fallback). If fallback fails with Docker/Postgres access errors, start Docker
and make sure the `postgres` service is running. Install host `psql` only if
you want the optional fast path or ad-hoc local queries.

**Phase 6 reliability capture uses `scripts/integration-up.sh`** —
host `psql` is no longer required there either. The integration helper now
falls back to `docker compose exec postgres psql ...` when Docker Postgres is
running and root `.env.local` exposes a usable `DATABASE_URL`. When fallback
fails, the error names the specific blocker (e.g. missing `DATABASE_URL`)
instead of suggesting a generic `psql` install. The `--check-prerequisites`
output confirms that a `FLAPJACK_ADMIN_KEY` is configured without printing the
secret, and the startup summary prints `Node secret:` and `Flapjack URL:` so
operators can verify the isolated stack env before running reliability
profiling scripts. For the isolated
integration stack, keep `FLAPJACK_ADMIN_KEY` aligned between the wrapper and
the profiling scripts so direct authenticated flapjack probes (`/metrics`,
`/internal/storage`, `/1/indexes/...`) stay valid.

**Login succeeds but `/dashboard` redirects back to `/login`** —
restart the frontend with `scripts/web-dev.sh` so the SvelteKit server picks up
`JWT_SECRET` and `ADMIN_KEY` from root `.env.local`.

**Login page says "Authentication service is unavailable" even though the API is up** —
set `API_BASE_URL=http://127.0.0.1:3001` in `.env.local` or `web/.env.local`,
restart `scripts/web-dev.sh`, and retry. `scripts/web-dev.sh` defaults to
`http://localhost:3001`, which may resolve to IPv6 on some systems. The explicit
`http://127.0.0.1:3001` override in `.env.local` forces IPv4 for reliability.

**Frontend dev server shows a Vite/SvelteKit overlay under Node 25** — switch to
a supported runtime (`nvm use`, `fnm use`, or another Node 22 / Node 20 install)
before running browser-unmocked suites. Local signoff is validated on Node 20.19+
or Node 22.12+, with Node 22 recommended.

**`secret manager error: secret store not configured` during seeded Search Preview** —
set `NODE_SECRET_BACKEND=memory` in root `.env.local`, restart the API, and
re-run the seed step.

**Emails not arriving in Mailpit** — verify `MAILPIT_API_URL=http://localhost:8025`
is in `.env.local` and that the Mailpit container is running
(`docker compose ps mailpit`). `scripts/local-dev-up.sh` now always attempts to
start Mailpit and logs health-check failures explicitly, but you can still
recover manually with `docker compose up -d mailpit` if the container is down.
If `MAILPIT_API_URL` is unset, the API falls back to `NoopEmailService` and
logs emails to stdout instead.

**Billing operations return "Stripe not configured"** — set
`STRIPE_LOCAL_MODE=1` in `.env.local` and restart the API. Do NOT set
`STRIPE_SECRET_KEY` — that would bypass the local mock and try to hit real
Stripe.

**Batch billing says a seeded customer has no Stripe account linked** — when
`STRIPE_LOCAL_MODE=1`, `scripts/seed_local.sh` automatically calls
`/admin/customers/:id/sync-stripe` for both seeded users. Re-run
`scripts/seed_local.sh`; if the issue persists, treat it as a local blocker and
capture the failing evidence.

**Metering agent fails with "no shared customer found"** — run
`scripts/seed_local.sh` first. The metering agent looks up a `billing_plan='shared'`
customer from the database; seeding creates one.
