<!-- [scrai:start] -->
## scripts

| File | Summary |
| --- | --- |
| algolia_migration_safety_probe.sh | Read-only safety oracle for the fail-closed Algolia migration state. |
| algolia_source_discovery_live_probe.sh | Live acceptance probe for fjcloud-owned Algolia source-index discovery. |
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
| check_dirmap_merge_driver.sh | check_dirmap_merge_driver.sh — assert the DIRMAP merge driver is fully wired.

The DIRMAP anti-duplication mechanism has TWO halves that must agree:
  1. |
| check_doc_surface_allowlist.sh | Validate the doc-system v2 root/doc-directory surface against the checked-in allowlist. |
| check_package_manager_consistency.sh | check_package_manager_consistency.sh — assert web/ uses exactly one package
manager, and that it is npm.

This gate is the canonical owner of the "one package manager" invariant.
It exists because the repo genuinely forked (captured 2026-07-19):
  - CI installs with `npm ci` in 5 places (.github/workflows/ci.yml:142,
    235, 266, 491, 563) and never invokes pnpm anywhere.
  - ~8 contract tests assert the literal string `npm ci`.
  - Yet web/ also tracked pnpm-lock.yaml, and scripts/local-ci.sh told
    developers to run `pnpm install` — three lines above a comment reading
    "local devs already have node_modules from `npm install`".
  - The working tree carried BOTH install markers (node_modules/.package-lock.json
    from npm AND node_modules/.modules.yaml from pnpm), i.e. |
| check_roadmap_v2_shape.sh | check_roadmap_v2_shape.sh — assert ROADMAP.md follows the v2 owner contract.

Stage 2 of the doc-system v2 wave reshapes ROADMAP.md from its older
`## Current Focus` + `## Feature Status` + `## Planned (Next Up)` +
`## Open / Not Yet Implemented` layout into a `## Active` + `## Planned`
owner shape, with a tight `## Archive` pointer to the implemented/ directory.
Several other repo seams (LAUNCH.md, contract tests) quote priority and
open-work item titles by their exact text, so the reshape must preserve
those titles verbatim.

This gate is the structural-contract owner. |
| check_status_doc_consistency.sh | check_status_doc_consistency.sh — assert doc-system v2 launch/work owners
are present and retired mutable-owner docs have not been recreated.

Exit codes:
  0 — v2 owner surface is present and retired owners are absent
  1 — drift or missing files / sections

Env vars:
  FJCLOUD_DOC_ROOT  override the repo root for testing (defaults to script's
                    repo root). |
| clean-orphans.sh | clean-orphans.sh — find and kill stale fjcloud-* dev processes left
behind by parallel-worktree sessions that ended without teardown.

What this exists to clean up (anchored 2026-06-02): on a typical week
of parallel batman/matt dispatch, 10-15 long-running `nohup`'d dev
binaries from past sessions (`fjcloud-api`, `fj-metering-agent`,
`flapjack`) end up with PPID=1 and survive forever. |
| cleanup_dev_orphans.sh | cleanup_dev_orphans.sh — targeted cleanup for stale local E2E fixture DB rows. |
| customer_broadcast.sh | customer_broadcast.sh — operator wrapper for POST /admin/broadcast. |
| dedupe_dirmap.py | Remove duplicated table rows from generated DIRMAP.md files.

WHY THIS EXISTS (measured 2026-07-19)
-------------------------------------
`.gitattributes` carried `**/DIRMAP.md merge=union`. |
| deploy_status.sh | deploy_status.sh — one-screen answer to "what's deployed?"

Probes /version on the live API, compares dev_sha against `git rev-parse main`
in the dev repo, and shows the gap. |
| dev_state_audit.sh | Audit local development state after canonical seed data is applied. |
| e2e-preflight.sh | Preflight checks for Stage 6 browser (Playwright) test runs.
Validates that required environment variables and services are available
before invoking Playwright, to produce clear errors instead of cryptic failures.

Loads .env.local via the shared env parser so that ADMIN_KEY and other
local-dev values are available without manual exports. |
| git_push_with_sync.sh | Wrap git push with best-effort staging mirror sync on main.

Prod is NOT synced by default: prod promotion is a deliberate, gated step
owned by scripts/launch/post_wave_a_sync_prod.sh --execute (staging CI must
be green at staging HEAD first). |
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
| local_play.sh | local_play.sh - One-command fresh local demo launcher. |
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
| probe_demo_template_image_urls.sh | Probe seeded demo template image URLs for malformed, placeholder, and unreachable values. |
| probe_deployed_signup_renders.sh | probe_deployed_signup_renders.sh — assert deployed /signup actually renders the form.

Purpose: detect the architectural failure where the public web host
(cloud.flapjack.foo) is served by a static-only deployment that has no
`signup.html` artifact, so requests for `/signup` fall back to `index.html`
(the landing page). |
| probe_flapjack_build_identity.sh | scripts/probe_flapjack_build_identity.sh — canonical Flapjack build-identity
evidence probe.

Inspects the INSTALLED executable bytes and the process-reported runtime
identity, then classifies the observation through the Stage 1 identity owners.
It owns no comparison logic of its own: binary SHA-256 comes from
scripts/lib/flapjack_binary.sh::flapjack_binary_sha256 and runtime `/health`
comparison comes from scripts/lib/local_stack_contract.sh
(flapjack_runtime_identity_reason for the live URL path,
flapjack_classify_health_json for out-of-band SSM-collected health).

Read-only. |
| probe_flapjack_source_rebuild.sh | Probe that a selected Flapjack checkout mutation forces a helper-owned rebuild
and changes behavior served by the rebuilt binary without a version bump. |
| probe_live_state.sh | scripts/probe_live_state.sh — fjcloud realization of Live State Discipline.

Per-project read-only inventory probe. |
| probe_organic_alert_dispatch.sh | probe_organic_alert_dispatch.sh — staging in-process invoice failure alert probe.

This probe seeds a synthetic finalized invoice in staging, replays a signed
invoice.payment_failed webhook to the deployed API, then verifies the alert
row persisted with delivery_status='sent'. |
| probe_ses_bounce_complaint_e2e.sh | probe_ses_bounce_complaint_e2e.sh — app-owned bounce/complaint suppression proof. |
| probe_ses_simulator_send.sh | Send-only SES mailbox simulator probe for bounce/complaint proof. |
| purge_dev_state.sh | purge_dev_state.sh - remove retroactive dev@example.com fixture tenant rows. |
| run-aggregation-job.sh | run-aggregation-job.sh — Run the aggregation job for a target date.

Rolls up raw usage_records into daily aggregates in usage_daily.
Idempotent — safe to run multiple times for the same date.
Defaults to yesterday (UTC) when no date argument is provided.

Usage:
  scripts/run-aggregation-job.sh                # yesterday
  scripts/run-aggregation-job.sh 2026-03-27     # specific date. |
| sanitize_worktree_paths.sh | Scrub host-specific parallel-development worktree prefixes from tracked files.
Default/--check lists leaks without mutation; --write removes prefixes in place.
Postmortem: chats/suggestions/jun11_pm_fjcloud_dev__polished_beta_verify_chicken_egg_and_dirmap_guard_blindspot.md. |
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
| seed_staging_dunning_test_tenant.sh | Link every allowlisted staging dunning tenant to a Stripe test customer.

Reuses the existing /admin/customers/:id/sync-stripe owner so this script
does not create a parallel Stripe customer-linking path. |
| set_status.sh | set_status.sh — update public /status vars in web/wrangler.toml. |
| setup_git_merge_drivers.sh | setup_git_merge_drivers.sh — register this repo's custom git merge drivers.

Run once per clone. |
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
| validate-stripe.sh | shellcheck disable=SC1091
Validate Stripe test-mode billing lifecycle and emit machine-readable JSON. |
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
| canary | The canary directory contains staging validation scripts and contract tests that verify critical infrastructure integration points, including customer-workflow synthetics (signup through Stripe setup), deployment health checks, external availability probes, and email deliverability verification. |
| chaos | The chaos directory contains failure injection scripts for testing HA failover and incident recovery in a distributed Flapjack deployment system, including region killing, primary VM failure simulation, and metering service breach detection. |
| dev | This directory contains helper scripts for managing the project's integration test infrastructure, including utilities for consolidating and migrating integration tests and regenerating test root structures. |
| launch | — |
| lib | This is a shared shell-script library directory providing reusable helpers for AWS identity, alert dispatch, billing rehearsal, authentication, Docker, database access, Stripe integration, security checks, deployment validation, and environment management across the fjcloud infrastructure project. |
| load | Load testing regression check utilities that validate API performance by comparing load test results against baseline JSON files for five key endpoints: health, search_query, index_create, admin_tenant_list, and document_ingestion. |
| reliability | This directory contains profiling and validation automation for the backend, including capacity testing across document tiers (1k/10k/100k), security and reliability gate checks, and VM inventory validation, with helper scripts and shared utilities for testing and security automation. |
| security | The security directory contains a single read-only probe script that tests for unintended engine exposure in the system. |
| stripe | Scripts for configuring Stripe integrations including Customer Portal setup and product catalog creation, supporting multiple Stripe accounts through environment-based account selection. |
| tests | The tests directory contains shell script-based smoke tests for customer broadcast and SES bounce/complaint probes, with supporting fixtures and shared testing libraries that provide assertions, mocks, and infrastructure for integration and chaos testing across multiple subsystems. |
| verify | — |
| vlm | VLM directory contains utilities for aggregating vision language model verdict bundles and shell script helpers for environment variable management in the VLM judge system, with environment handling functions extracted from common deployment scripts. |
| w3_triage | The w3_triage directory contains orchestration tools for bootstrapping audit state, parsing recommendations, and dispatching rule applications across lanes. |
<!-- [scrai:end] -->
