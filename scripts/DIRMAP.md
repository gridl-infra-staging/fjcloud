<!-- [scrai:start] -->
## scripts

| File | Summary |
| --- | --- |
| api-dev.sh | api-dev.sh — Start the API with repo-local env files exported. |
| bootstrap-env-local.sh | bootstrap-env-local.sh — Generate .env.local from .env.local.example and
the external secret source.

Resolution order for each key:
  1. |
| check-sizes.sh | Enforce hard file-size limits for source files.

Limits are calibrated to flag genuinely-too-large source files while
accommodating the line-count overhead that `prettier --write` adds when
breaking long lines into multi-line form. |
| customer_broadcast.sh | customer_broadcast.sh — operator wrapper for POST /admin/broadcast. |
| e2e-preflight.sh | Preflight checks for Stage 6 browser (Playwright) test runs.
Validates that required environment variables and services are available
before invoking Playwright, to produce clear errors instead of cryptic failures.

Loads .env.local via the shared env parser so that ADMIN_KEY and other
local-dev values are available without manual exports. |
| integration-down.sh | integration-down.sh — Tear down the integration test stack.

Kills API + flapjack processes, drops test DB, cleans up PID files.
Idempotent: safe to run even when nothing is running. |
| integration-test.sh | integration-test.sh — Run integration tests against an isolated stack.

Brings up the integration stack, runs tests with INTEGRATION=1, then tears down.
The stack is always torn down on exit (via trap). |
| integration-up.sh | integration-up.sh — Bring up an isolated integration test stack.

Creates fjcloud_integration_test DB, runs migrations, builds binaries,
starts flapjack on port 7799, starts fjcloud API on port 3099, health-checks both.

Prerequisites: Postgres 16 running locally, flapjack_dev repo at FLAPJACK_DEV_DIR. |
| live-backend-gate.sh | Backend launch gate — orchestrates all required backend validation checks
and produces a machine-readable JSON summary.

Usage:
  scripts/live-backend-gate.sh [--skip-rust-tests] [--fail-fast]

Options:
  --skip-rust-tests  Skip Rust validation tests (cargo test)
  --fail-fast        Stop on first check failure

Output:
  stdout: JSON summary with check_results, reason codes, and timing
  stderr: Per-check progress (always printed)

Exit codes:
  0 — all checks passed (or were skipped in dev mode)
  1 — one or more actionable gate failures

Environment:
  GATE_CHECK_TIMEOUT_SEC  Per-check timeout in seconds (default: 30). |
| local-dev-down.sh | local-dev-down.sh — Tear down local dev services.

Kills flapjack, stops Docker Compose, cleans up PID/log files.
Idempotent: safe to run even when nothing is running.

Usage:
  scripts/local-dev-down.sh           # stop services, keep data
  scripts/local-dev-down.sh --clean   # stop services and remove volumes. |
| local-dev-migrate.sh | local-dev-migrate.sh — Apply database migrations for local development.

Prerequisites: source .env.local first to set DATABASE_URL.
Not safely rerunnable — migrations are not uniformly idempotent.
To reset, drop the database and re-create it before running again. |
| local-dev-up.sh | local-dev-up.sh — Start the local development environment.

Starts Docker Compose Postgres, runs migrations, starts Flapjack on port 7700,
and prints instructions for starting the API and web processes manually.

Prerequisites: docker, curl, .env.local at repo root.
Optional: FLAPJACK_DEV_DIR pointing to flapjack_dev repo. |
| local-signoff-cold-storage.sh | local-signoff-cold-storage.sh — Thin env bridge + cargo test delegate for
cold-storage integration signoff.

Resolves strict local stack defaults, validates cold-storage prerequisites,
delegates to the authoritative Rust integration test, and emits JSON +
operator-readable evidence.

Usage:
  ./scripts/local-signoff-cold-storage.sh. |
| local-signoff-commerce.sh | local-signoff-commerce.sh — Strict local commerce proof runner.

Exercises the full local commerce lane: signup -> email verification ->
batch billing -> invoice payment. |
| local-signoff.sh | local-signoff.sh — Top-level orchestrator that delegates to commerce,
cold-storage, and HA proof-owner scripts in strict order.

Does NOT duplicate proof-owner internals — only calls the three scripts
and interprets exit codes/output. |
| local_demo.sh | One-command local demo launcher: infra + API + web + seed data + metering. |
| probe_alert_delivery.sh | probe_alert_delivery.sh — synthetic critical alert delivery probe

Purpose: verify that the Slack and/or Discord webhook URLs configured for the
fjcloud alert pipeline ACTUALLY accept incoming POSTs. |
| run-aggregation-job.sh | run-aggregation-job.sh — Run the aggregation job for a target date.

Rolls up raw usage_records into daily aggregates in usage_daily.
Idempotent — safe to run multiple times for the same date.
Defaults to yesterday (UTC) when no date argument is provided.

Usage:
  scripts/run-aggregation-job.sh                # yesterday
  scripts/run-aggregation-job.sh 2026-03-27     # specific date. |
| seed_local.sh | seed_local.sh — Idempotent local development seed script.

Creates a test user, index, and optionally seeds search data.
Safe to run multiple times — skips resources that already exist.

Usage:
  ./scripts/seed_local.sh              # uses defaults from .env.local
  API_URL=http://localhost:3001 ADMIN_KEY=my-key ./scripts/seed_local.sh. |
| set_status.sh | set_status.sh — publish runtime service_status.json for /status hydration. |
| staging_billing_dry_run.sh | staging_billing_dry_run.sh — safe staging billing preflight / rehearsal entrypoint.

This script intentionally stays small and orchestration-focused. |
| staging_billing_rehearsal.sh | staging_billing_rehearsal.sh — guarded staging billing mutation rehearsal. |
| start-metering.sh | start-metering.sh — Start the metering agent for local dev.

Must run AFTER seed_local.sh (needs a real customer UUID from the database).
The metering agent scrapes Flapjack /metrics, computes deltas, and writes
usage_records to Postgres. |
| stripe_webhook_replay_fixture.sh | stripe_webhook_replay_fixture.sh — deterministic local webhook replay fixture.

Purpose:
- Build a safe Stripe webhook payload/signature pair for local replay checks.
- Keep check mode non-mutating (no curl calls).
- Allow an explicit run mode for one-shot webhook POST verification. |
| validate-metering.sh | Validate metering pipeline health against a live database and emit JSON. |
| validate-stripe.sh | Validate Stripe test-mode billing lifecycle and emit machine-readable JSON. |
| validate_inbound_email_roundtrip.sh | Validate SES outbound-to-inbound roundtrip for the shared test inbox path. |
| validate_ses_readiness.sh | Validate SES readiness using read-only API calls and machine-readable output. |
| web-dev.sh | web-dev.sh — Start the SvelteKit dev server with repo-local auth env loaded. |

| Directory | Summary |
| --- | --- |
| canary | The canary directory contains synthetic monitoring scripts for continuous end-to-end validation: customer_loop_synthetic.sh runs the full signup-to-billing flow with deterministic cleanup and alert dispatch, outside_aws_health_check.sh probes external service availability, and support_email_deliverability.sh validates inbound email roundtrips. |
| chaos | Chaos engineering scripts for testing Flapjack region HA failover and recovery, validating health monitor detection, region failover, and tenant promotion behavior. |
| launch | This directory contains deployment validation and staging environment orchestration scripts, including SSM-driven environment hydration, tenant-map verification, synthetic traffic seeding, and evidence capture for the launch process. |
| lib | This lib directory contains reusable bash utility scripts that provide shared functions for the project's validation and integration workflows—including environment loading, health checks, HTTP requests, Stripe and billing operations, database migrations, metering validation, and alert dispatch. |
| load | The load directory contains regression checking utilities for validating load testing performance, including scripts that compare offline and live load harness results to detect performance regressions. |
| reliability | The reliability directory contains shell scripts for backend capacity profiling, security validation, and reliability gating that generate performance metrics across document tiers. |
| stripe | The stripe directory contains operational scripts for managing Stripe integration with fjcloud: configuring the Customer Portal and creating the canonical Flapjack product catalog, both supporting multi-account operations. |
| tests | The tests/ directory contains shell script test infrastructure, including focused smoke tests for wrapper scripts like customer_broadcast.sh and a shared lib/ of utilities supporting chaos tests, integration tests, e2e billing cycles, and staging validation. |
<!-- [scrai:end] -->
