<!-- [scrai:start] -->
## scripts

| File | Summary |
| --- | --- |
| api-dev.sh | api-dev.sh — Start the API with repo-local env files exported. |
| audit_secrets.sh | Machine-checkable secrets drift audit.
Emits one structured line per finding:
  category|name|location|status. |
| bootstrap-env-local.sh | bootstrap-env-local.sh — Generate .env.local from .env.local.example and
the external secret source.

Resolution order for each key:
  1. |
| check-sizes.sh | Enforce hard file-size limits for source files.

Limits are calibrated to flag genuinely-too-large source files while
accommodating the line-count overhead that `prettier --write` adds when
breaking long lines into multi-line form. |
| check_status_doc_consistency.sh | check_status_doc_consistency.sh — assert NOW.md is not stale relative to
LAUNCH.md's most recent ## STATUS entry.

Why this exists: the project had a drift class where LAUNCH.md got a fresh
STATUS append (a B1 verdict, an announce-gate run, a launch-readiness
refresh) but NOW.md still pointed at the prior stage. |
| customer_broadcast.sh | customer_broadcast.sh — operator wrapper for POST /admin/broadcast. |
| deploy_status.sh | deploy_status.sh — one-screen answer to "what's deployed?"

Probes /version on the live API, compares dev_sha against `git rev-parse main`
in the dev repo, and shows the gap. |
| e2e-preflight.sh | Preflight checks for Stage 6 browser (Playwright) test runs.
Validates that required environment variables and services are available
before invoking Playwright, to produce clear errors instead of cryptic failures.

Loads .env.local via the shared env parser so that ADMIN_KEY and other
local-dev values are available without manual exports. |
| git_push_with_sync.sh | Wrap git push with best-effort mirror sync on main. |
| integration-down.sh | integration-down.sh — Tear down the integration test stack.

Kills API + flapjack processes, drops test DB, cleans up PID files.
Idempotent: safe to run even when nothing is running. |
| integration-test.sh | integration-test.sh — Run integration tests against an isolated stack.

Brings up the integration stack, runs tests with INTEGRATION=1, then tears down.
The stack is always torn down on exit (via trap). |
| integration-up.sh | integration-up.sh — Bring up an isolated integration test stack.

Creates fjcloud_integration_test DB, runs migrations, builds binaries,
starts flapjack on port 7799, fjcloud API on port 3099, metering-agent
on health port 9191, and health-checks all three.

Prerequisites: Postgres 16 running locally, flapjack_dev repo at FLAPJACK_DEV_DIR. |
| live-backend-gate.sh | Backend launch gate — orchestrates all required backend validation checks
and produces a machine-readable JSON summary.

Usage:
  scripts/live-backend-gate.sh [--skip-rust-tests] [--fail-fast] [--staging-only]

Options:
  --skip-rust-tests  Skip Rust validation tests (cargo test)
  --fail-fast        Stop on first check failure
  --staging-only     Force commerce checks into soft-skip mode (BACKEND_LIVE_GATE=0)

Output:
  stdout: JSON summary with check_results, reason codes, and timing
  stderr: Per-check progress (always printed)

Exit codes:
  0 — all checks passed (or were skipped in dev mode)
  1 — one or more actionable gate failures

Environment:
  GATE_CHECK_TIMEOUT_SEC  Per-check timeout in seconds (default: 30). |
| local-ci.sh | # HELP-TEXT-BEGIN
local-ci.sh — Run every gate the staging deploy-staging job depends on,
locally, in parallel where safe. |
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
| playwright_local_stack.sh | playwright_local_stack.sh — Start local API + web for Playwright runs. |
| probe_alert_delivery.sh | probe_alert_delivery.sh — synthetic critical alert delivery probe

Purpose: verify that the Slack and/or Discord webhook URLs configured for the
fjcloud alert pipeline ACTUALLY accept incoming POSTs. |
| probe_canary_live_state.sh | probe_canary_live_state.sh — answer "is the env's canary infrastructure
healthy right now?" from live AWS state.

Why this exists: the canonical bundle pointer at
`docs/runbooks/evidence/canary-customer-loop/.current_bundle` was being
read as a launch-readiness signal, but bundle capture is event-triggered
(intentional snapshots after a wave merges or a deploy lands), not
continuous. |
| probe_cloudflare_ai_block.sh | Read-only Cloudflare AI-bot-protection probe. |
| probe_deployed_signup_renders.sh | probe_deployed_signup_renders.sh — assert deployed /signup actually renders the form.

Purpose: detect the architectural failure where the public web host
(cloud.flapjack.foo) is served by a static-only deployment that has no
`signup.html` artifact, so requests for `/signup` fall back to `index.html`
(the landing page). |
| probe_live_state.sh | scripts/probe_live_state.sh — fjcloud realization of Live State Discipline.

Per-project read-only inventory probe. |
| probe_organic_alert_dispatch.sh | probe_organic_alert_dispatch.sh — staging in-process invoice failure alert probe.

This probe seeds a synthetic finalized invoice in staging, replays a signed
invoice.payment_failed webhook to the deployed API, then verifies the alert
row persisted with delivery_status='sent'. |
| probe_ses_bounce_complaint_e2e.sh | probe_ses_bounce_complaint_e2e.sh — app-owned bounce/complaint suppression proof. |
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
| seed_operator_accounts.sh | seed_operator_accounts.sh — Seed the six operator test accounts on staging or prod.

Idempotent: accounts that already exist are treated as success.
Requires a direct DATABASE_URL for force-verifying email (SKIP_EMAIL_VERIFICATION
is production-gated and cannot be used here).

Usage (staging):
  API_URL=https://api.flapjack.foo \
  DATABASE_URL_SSM_PARAM=/fjcloud/staging/database_url \
  AWS_DEFAULT_REGION=us-east-1 \
    bash scripts/seed_operator_accounts.sh

If DATABASE_URL is set directly instead of via DATABASE_URL_SSM_PARAM,
SSM_INSTANCE_ID must also be set (auto-detection requires the SSM param path).
See docs/runbooks/staging-access.md for full context. |
| staging_billing_dry_run.sh | staging_billing_dry_run.sh — safe staging billing preflight / rehearsal entrypoint.

This script intentionally stays small and orchestration-focused. |
| staging_billing_rehearsal.sh | staging_billing_rehearsal.sh — guarded staging billing mutation rehearsal. |
| start-metering.sh | start-metering.sh — Start the metering agent for local dev.

Must run AFTER seed_local.sh (needs a real customer UUID from the database).
The metering agent scrapes Flapjack /metrics, computes deltas, and writes
usage_records to Postgres. |
| stripe_cutover_prereqs.sh | Stage 1 gate for Stripe restricted-key cutover prerequisites.

This script is intentionally non-mutating. |
| stripe_webhook_replay_fixture.sh | stripe_webhook_replay_fixture.sh — deterministic local webhook replay fixture.

Purpose:
- Build a safe Stripe webhook payload/signature pair for local replay checks.
- Keep check mode non-mutating (no curl calls).
- Allow an explicit run mode for one-shot webhook POST verification. |
| validate-metering.sh | Validate metering pipeline health against a live database and emit JSON. |
| validate-stripe.sh | Validate Stripe test-mode billing lifecycle and emit machine-readable JSON. |
| validate_customer_quickstart.sh | Validate customer quickstart contracts across staging/prod modes. |
| validate_full_vm_lifecycle_prod.sh | Deterministic lifecycle orchestrator for prod VM lifecycle validation modes.
shellcheck disable=SC1091. |
| validate_inbound_email_roundtrip.sh | Validate SES outbound-to-inbound roundtrip for the shared test inbox path. |
| validate_oauth_routes.sh | Validate local OAuth route shape without a live provider round-trip. |
| validate_ses_readiness.sh | Validate SES readiness using read-only API calls and machine-readable output. |
| validate_staging_dunning_delivery.sh | Validate staging dunning email delivery by reusing rehearsal artifacts and SES inbound S3 evidence. |
| validate_subprocessor_disclosure.sh | Validate sub-processor disclosure content on staging/prod legal pages. |
| web-dev.sh | web-dev.sh — Start the SvelteKit dev server with repo-local auth env loaded. |

| Directory | Summary |
| --- | --- |
| canary | This directory contains synthetic monitoring scripts and contract tests for validating the fjcloud platform's health and correctness, including customer-flow canaries (signup through billing), external health probes, email deliverability checks, and cross-system integration contract tests for authentication, payment processing, and infrastructure configuration. |
| chaos | This directory contains chaos engineering and failure injection scripts that validate the system's resilience to critical failures like region outages, primary VM crashes, and metering service disruptions. |
| dev | Migrates integration test files from the top-level `infra/api/tests/` directory into a consolidated `infra/api/tests/integration/` subdirectory and rewrites their module paths to use crate-absolute imports. |
| launch | The `launch/` directory contains shell scripts that orchestrate staging environment validation and pre-deployment verification, including tenant isolation probes, billing rehearsal data seeding, browser-based E2E testing, and evidence capture. |
| lib | Shared shell script libraries providing reusable utilities for billing workflows, database operations, HTTP communication, security checks, Stripe integration, environment configuration, and testing across the fjcloud project. |
| load | The load directory contains regression check utilities for load testing infrastructure, specifically designed to compare offline and live load harness performance metrics. |
| reliability | The reliability directory contains capacity profiling and security validation scripts for the backend, including tools to profile document tier performance, run automated security checks, seed test data deterministically, and validate infrastructure consistency between VM inventory and EC2 instances. |
| stripe | This directory contains shell scripts for provisioning Stripe integrations, including customer billing portal configuration and product catalog creation, with support for managing multiple Stripe accounts via environment variables. |
| tests | This directory contains shell script smoke tests for customer broadcast and SES event handling, along with a lib subdirectory of shared testing utilities and helpers for integration, chaos, and billing validation scenarios. |
| vlm | The vlm directory contains verdict/validation aggregation logic and environment variable helper utilities extracted from uff_dev to support VLM judge operations, particularly for reading and processing environment configuration values. |
| w3_triage | The w3_triage directory contains scripts and utilities for orchestrating a multi-stage triage workflow, with the bootstrap script handling initial state probing, audit discovery, and persistent state setup for downstream triage stages. |
<!-- [scrai:end] -->
