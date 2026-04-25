<!-- [scrai:start] -->
## scripts

| File | Summary |
| --- | --- |
| api-dev.sh | api-dev.sh — Start the API with repo-local env files exported. |
| bootstrap-env-local.sh | bootstrap-env-local.sh — Generate .env.local from .env.local.example and
the external secret source.

Resolution order for each key:
  1. |
| check-sizes.sh | Enforce hard file-size limits for source files. |
| e2e-preflight.sh | Stub summary for e2e-preflight.sh. |
| integration-down.sh | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar25_am_4_admin_workflow_depth/fjcloud_dev/scripts/integration-down.sh. |
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
| local-dev-migrate.sh | Stub summary for local-dev-migrate.sh. |
| local-dev-up.sh | Stub summary for local-dev-up.sh. |
| local-signoff-cold-storage.sh | Stub summary for local-signoff-cold-storage.sh. |
| local-signoff-commerce.sh | Stub summary for local-signoff-commerce.sh. |
| local-signoff.sh | Stub summary for local-signoff.sh. |
| local_demo.sh | Stub summary for local_demo.sh. |
| run-aggregation-job.sh | run-aggregation-job.sh — Run the aggregation job for a target date.

Rolls up raw usage_records into daily aggregates in usage_daily.
Idempotent — safe to run multiple times for the same date.
Defaults to yesterday (UTC) when no date argument is provided.

Usage:
  scripts/run-aggregation-job.sh                # yesterday
  scripts/run-aggregation-job.sh 2026-03-27     # specific date. |
| seed_local.sh | Stub summary for seed_local.sh. |
| staging_billing_dry_run.sh | Stub summary for staging_billing_dry_run.sh. |
| staging_billing_rehearsal.sh | staging_billing_rehearsal.sh — guarded staging billing mutation rehearsal. |
| start-metering.sh | start-metering.sh — Start the metering agent for local dev.

Must run AFTER seed_local.sh (needs a real customer UUID from the database).
The metering agent scrapes Flapjack /metrics, computes deltas, and writes
usage_records to Postgres. |
| stripe_webhook_replay_fixture.sh | Stub summary for stripe_webhook_replay_fixture.sh. |
| validate-metering.sh | Validate metering pipeline health against a live database and emit JSON. |
| validate-stripe.sh | Stub summary for validate-stripe.sh. |
| validate_ses_readiness.sh | Stub summary for validate_ses_readiness.sh. |
| web-dev.sh | web-dev.sh — Start the SvelteKit dev server with repo-local auth env loaded. |

| Directory | Summary |
| --- | --- |
| chaos | Chaos engineering scripts for testing Flapjack high-availability failover detection, including region kill and restart operations that validate the health monitor's ability to identify unhealthy deployments within its 60-second cycle threshold. |
| launch | The launch directory contains validation and evidence-collection scripts for the billing system launch, including backend validation, synthetic traffic seeding for testing billing rehearsal, and email deliverability verification. |
| lib | This lib directory contains shared bash utility functions for backend staging workflows, including environment parsing, Stripe integration, metering and billing validation, health checks, and preflight gate enforcement. |
| load | The load directory contains shell scripts and utilities for running load tests and performance regression detection on the fjcloud system. |
| reliability | The reliability directory contains profiling and security validation scripts that measure fjcloud's capacity across document tiers (1k, 10k, 100k) and run automated security gates (cargo audit, secret scanning, unsafe code detection). |
| stripe | The stripe directory contains operational scripts for configuring Stripe billing infrastructure, including a script to set up the Stripe Customer Portal against specific accounts and a stub for catalog creation. |
| tests | The tests directory contains shared shell script utilities and helpers for integration testing and local development, including assertion helpers, mock infrastructure for cargo tests, and harnesses for staging billing rehearsals, billing validation, chaos testing, and local development state management. |
<!-- [scrai:end] -->
