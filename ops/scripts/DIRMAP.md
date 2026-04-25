<!-- [scrai:start] -->
## scripts

| File | Summary |
| --- | --- |
| deploy.sh | deploy.sh — Zero-downtime deploy via SSM (no SSH keys)
Called from CI after binaries are uploaded to S3.

Usage: deploy.sh <env> <git-sha>

Flow:
  1. |
| live_e2e_budget_guardrail_prep.sh | Stub summary for live_e2e_budget_guardrail_prep.sh. |
| live_e2e_ttl_janitor.sh | Stub summary for live_e2e_ttl_janitor.sh. |
| migrate.sh | migrate.sh — Run SQL migrations on EC2 instance
Called by deploy.sh via SSM or manually. |
| provision_bootstrap.sh | provision_bootstrap.sh — Create AWS bootstrap prerequisites for fjcloud

Idempotent counterpart to validate_bootstrap.sh: creates the resources
that validate_bootstrap.sh checks. |
| rds_restore_drill.sh | Stub summary for rds_restore_drill.sh. |
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
  - Route53 hosted zone with DelegationSet NameServers. |

| Directory | Summary |
| --- | --- |
| lib | This lib directory contains shared deployment and operational utilities: deploy validation gate checks, SSM parameter-to-environment-variable mapping and loading, and RDS restore tooling. |
<!-- [scrai:end] -->
