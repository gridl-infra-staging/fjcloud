<!-- [scrai:start] -->
## scripts

| File | Summary |
| --- | --- |
| cleanup_api_server_metering_ghost.sh | cleanup_api_server_metering_ghost.sh

One-shot operator cleanup for the dormant fj-metering-agent ghost that older
API-server deploys installed on the control-plane host.

Dry-run for planning on any workstation:
  bash ops/scripts/cleanup_api_server_metering_ghost.sh --dry-run

Live execution must run on the API server itself after the Stage 3 cleanup
deploy is live. |
| deploy.sh | deploy.sh — Zero-downtime deploy via SSM (no SSH keys)
Called from CI after binaries are uploaded to S3.

Usage: deploy.sh <env> <git-sha>

Flow:
  1. |
| live_e2e_budget_guardrail_prep.sh | live_e2e_budget_guardrail_prep.sh -- prepare a non-mutating budget-action proposal. |
| live_e2e_ttl_janitor.sh | live_e2e_ttl_janitor.sh — fail-closed TTL cleanup for disposable live-E2E resources. |
| migrate.sh | migrate.sh — Run SQL migrations on EC2 instance
Called by deploy.sh via SSM or manually. |
| provision_bootstrap.sh | provision_bootstrap.sh — Create AWS bootstrap prerequisites for fjcloud

Idempotent counterpart to validate_bootstrap.sh: creates the resources
that validate_bootstrap.sh checks. |
| rds_restore_drill.sh | rds_restore_drill.sh — operator-only restore rehearsal entrypoint

Usage: rds_restore_drill.sh <env> [options]
  env: staging | prod

Required options:
  --source-db-instance-id <id>
  --target-db-instance-id <id>

Exactly one restore mode is required:
  --snapshot-id <snapshot-id>
  --restore-time <RFC3339 timestamp>. |
| rds_restore_evidence.sh | rds_restore_evidence.sh — wrapper around rds_restore_drill.sh for evidence artifacts.

This script owns:
- input discovery and wrapper-level execution gating
- run-scoped artifact generation
- live-only polling and verification artifact wiring

Restore API command construction remains delegated to rds_restore_drill.sh. |
| rollback.sh | rollback.sh — Roll back to a previous release via SSM
Does NOT run migrations (never roll back migrations).

Usage: rollback.sh <env> <previous-sha>. |
| validate_bootstrap.sh | validate_bootstrap.sh — Verify AWS bootstrap prerequisites for fjcloud

Checks that all infrastructure prerequisites exist and are correctly
configured before running terraform init or deploy scripts.

Usage: validate_bootstrap.sh <env>
  env: staging | prod

Prerequisites checked:
  - S3 tfstate bucket (versioned, encrypted, public access blocked)
  - S3 releases bucket (versioned, public access blocked)
  - DynamoDB lock table with LockID key
  - SSM parameters (database_url as SecureString)
  - Cloudflare DNS credentials for the public staging zone. |

| Directory | Summary |
| --- | --- |
| lib | The lib directory contains shared deployment and infrastructure utilities including SSM parameter-to-environment mapping (generate_ssm_env.sh), pre-deployment validation adapters, Cloudflare zone parsing, and RDS restore selection helpers. |
| tests | The tests directory contains a fixture capture script for Cloudflare zones, used to create test data snapshots of Cloudflare zone configurations. |
| lib | The lib directory contains shared operational helper scripts for deployment workflows, including pre-deployment validation, SSM parameter-to-environment-file generation for systemd services, Cloudflare zone parsing, and RDS restore utilities. |
| tests | The tests directory contains a single shell script that captures Cloudflare zone fixtures for testing purposes. |
<!-- [scrai:end] -->
