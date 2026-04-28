<!-- [scrai:start] -->
## terraform

| File | Summary |
| --- | --- |
| audit_no_secrets.sh | Audit Terraform and GitHub workflow files for secret hygiene. |
| publish_support_email_canary_image.sh | Build + push the support-email canary Lambda container image to ECR. |
| tests_bootstrap_static.sh | Static contract tests for ops/scripts/validate_bootstrap.sh
TDD red phase for Task 4 — Production Bootstrap Parity

These tests validate that validate_bootstrap.sh has correct structural
checks for all prerequisites (AWS bootstrap resources plus Cloudflare
public DNS credentials) across both environments. |
| tests_deploy_scripts_static.sh | Static contract tests for ops/scripts/{deploy,migrate,rollback}.sh
TDD red phase for Task 3 — Deploy/Migrate/Rollback Runtime Smoke

These tests validate structural correctness of the deploy scripts
without requiring AWS credentials or live infrastructure. |
| tests_provision_bootstrap_static.sh | Static contract tests for ops/scripts/provision_bootstrap.sh
TDD red phase — tests written before the script exists

provision_bootstrap.sh is the counterpart to validate_bootstrap.sh:
it CREATES the AWS bootstrap resources that validate_bootstrap.sh checks. |
| tests_rds_restore_evidence_static.sh | Static ownership assertions for ops/scripts/rds_restore_evidence.sh. |
| tests_rds_restore_evidence_unit.sh | Red-phase contract tests for ops/scripts/rds_restore_evidence.sh.
Stage 1 intentionally locks the behavior contract before wrapper implementation. |
| tests_rds_restore_evidence_unit_execute_and_poll_contract.sh | Stub summary for tests_rds_restore_evidence_unit_execute_and_poll_contract.sh. |
| tests_rds_restore_evidence_unit_selection_helper_contract.sh | Selection-helper fail-row regression coverage extracted from the main unit harness. |
| tests_runbooks_static.sh | Static content tests for infrastructure runbooks.
TDD red phase for Task 5 — Backend Runbook Finalization.

These tests assert that each required runbook exists and contains
the key commands, sections, and procedures documented in the checklist. |
| tests_stage5_static.sh | Static validation tests for Stage 5: Deploy & Migration Scripts
TDD: these tests define the contract; scripts must satisfy them.
Run from the repo root: bash ops/terraform/tests_stage5_static.sh. |
| tests_stage6_static.sh | Static validation tests for Stage 6: CI/CD Pipeline
TDD: these tests define the contract; workflow must satisfy them. |
| tests_stage7_preflight_static.sh | Static contract tests for preflight checks in tests_stage7_runtime_smoke.sh.
Ensures all required preflight validations are wired and cannot be silently removed.

These tests use grep-based pattern matching against the source file to verify
that each preflight check exists, uses the correct exit code constant, and
runs before terraform init. |
| tests_stage7_preflight_unit.sh | Behavioral tests for preflight checks in tests_stage7_runtime_smoke.sh.
Uses mock AWS/terraform/dig/curl commands to validate exit codes and
remediation messages without requiring live infrastructure. |
| tests_stage7_runtime_smoke.sh | Runtime validation harness for Stage 7.6 Definition of Done.

This script intentionally runs only targeted runtime checks and keeps
destructive operations opt-in. |
| tests_stage7_runtime_static.sh | Static contract tests for runtime assertions in tests_stage7_runtime_smoke.sh.
Ensures runtime_fail(), exit codes, CLI args, and script invocations are wired
and cannot be silently removed. |
| tests_stage7_runtime_unit.sh | Behavioral tests for runtime smoke assertions in tests_stage7_runtime_smoke.sh.
Exercises ACM, ALB, target-group, health, deploy, migrate, and rollback paths
via mock AWS/curl/terraform/bash commands — no live infrastructure required. |
| tests_stage7_secrets_static.sh | Static validation tests for Stage 7 secret hygiene.
TDD contract for audit_no_secrets.sh behavior. |
| tests_stage7_static.sh | Static validation tests for Stage 7: Monitoring & Final Validation
TDD: these tests define the contract; Terraform code must satisfy them. |
| tests_stage8_static.sh | Static validation tests for Stage 8: spend + cleanup guardrail ownership.
TDD: these tests define the red contract before implementation. |
| tests_support_email_canary_static.sh | Static validation tests for Stage 5 support-email canary Terraform substrate.
TDD: this test locks ownership, delegation, and secret-boundary contracts. |

| Directory | Summary |
| --- | --- |
| support_email_canary | AWS Lambda handler that executes email deliverability canary tests by running shell scripts and resolving webhook credentials from SSM Parameter Store. |
<!-- [scrai:end] -->
