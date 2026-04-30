<!-- [scrai:start] -->
## scripts

| File | Summary |
| --- | --- |
| api-dev.sh | api-dev.sh — Start the API with repo-local env files exported. |
| audit_secrets.sh | Stub summary for audit_secrets.sh. |
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
| probe_alert_delivery.sh | Stub summary for probe_alert_delivery.sh. |
| probe_ses_bounce_complaint_e2e.sh | Stub summary for probe_ses_bounce_complaint_e2e.sh. |
| probe_ses_simulator_send.sh | Send-only SES mailbox simulator probe for bounce/complaint proof. |
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
| staging_billing_dry_run.sh | Stub summary for staging_billing_dry_run.sh. |
| staging_billing_rehearsal.sh | staging_billing_rehearsal.sh — guarded staging billing mutation rehearsal. |
| start-metering.sh | start-metering.sh — Start the metering agent for local dev.

Must run AFTER seed_local.sh (needs a real customer UUID from the database).
The metering agent scrapes Flapjack /metrics, computes deltas, and writes
usage_records to Postgres. |
| stripe_cutover_prereqs.sh | Stub summary for stripe_cutover_prereqs.sh. |
| stripe_webhook_replay_fixture.sh | Stub summary for stripe_webhook_replay_fixture.sh. |
| validate-metering.sh | Validate metering pipeline health against a live database and emit JSON. |
| validate-stripe.sh | Validate Stripe test-mode billing lifecycle and emit machine-readable JSON. |
| validate_inbound_email_roundtrip.sh | Validate SES outbound-to-inbound roundtrip for the shared test inbox path. |
| validate_ses_readiness.sh | Validate SES readiness using read-only API calls and machine-readable output. |
| web-dev.sh | web-dev.sh — Start the SvelteKit dev server with repo-local auth env loaded. |

| Directory | Summary |
| --- | --- |
| canary | The canary directory contains synthetic monitoring scripts for continuous end-to-end validation: customer_loop_synthetic.sh runs the full signup-to-billing flow with deterministic cleanup and alert dispatch, outside_aws_health_check.sh probes external service availability, and support_email_deliverability.sh validates inbound email roundtrips. |
| chaos | The chaos directory contains failure-injection and HA resilience test scripts that validate the system's ability to detect outages, trigger failover, and recover—including region kill/restart tests, metering service failure detection, and end-to-end failover proofs. |
| launch | This directory contains shell scripts for deploying and validating the fjcloud billing platform in staging, including environment setup from AWS SSM, tenant configuration verification, synthetic traffic seeding, and remote command execution on EC2 infrastructure. |
| lib | Shared bash utilities providing reusable helpers for infrastructure validation (health checks, metering, Stripe), alert dispatch, environment parsing, billing rehearsal workflows, and deployment operations used across integration tests and shell scripts. |
| load | The load directory contains regression checking utilities for validating load testing performance, including scripts that compare offline and live load harness results to detect performance regressions. |
| reliability | The reliability directory contains shell scripts for backend capacity profiling, security validation, and reliability gating that generate performance metrics across document tiers. |
| stripe | The stripe directory contains operational scripts for managing Stripe integration with fjcloud: configuring the Customer Portal and creating the canonical Flapjack product catalog, both supporting multi-account operations. |
| tests | The tests directory contains shell-based integration test suites for ops-layer validation, including smoke tests for customer broadcast functionality and SES bounce/complaint probes, alongside a comprehensive lib/ of shared testing utilities, assertion helpers, and specialized harnesses for billing rehearsal, budget validation, and chaos testing scenarios. |
<!-- [scrai:end] -->
