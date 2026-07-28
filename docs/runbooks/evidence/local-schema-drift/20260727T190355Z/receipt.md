# Local Schema Drift Stage 4 Receipt

Generated: `2026-07-27T19:03:55Z`

## Scope

- Successful schema/mutation evidence HEAD: `64cecba30c1c76d137654d140f5e84a3af7d4f3a`
- Current HEAD: `64cecba30c1c76d137654d140f5e84a3af7d4f3a`
- Compose project: `fjcloud_jul27_pm_3_local_schema_drift_detector_fjcloud_dev`
- Chosen host port: `15432`
- Database URL: `postgres://griddle@localhost:15432/fjcloud_dev`
- Mutation URL: `postgres://griddle@localhost:15432/fjcloud_drift_mutation_check`
- Volume pre-existing before successful run: `no`; Postgres service pre-existing: `no`; this stage stopped its Postgres service.
- Local verdict scope: only this compose project and this worktree-owned isolated volume; not evidence about any other worktree or the main clone database.
- Blocker disposition: schema-drift checks passed; broader `bash scripts/local-ci.sh --fast` failed in unrelated gates listed below.

## Setup Evidence

Command: `bash scripts/bootstrap-env-local.sh`

Exit code: `0`

Output:
```text
BOOTSTRAP_OK: .env.local created at <repo>/.env.local
```

Command: `command -v psql`

Exit code: `0`

Output:
```text
/opt/homebrew/bin/psql
```

Command: `source scripts/lib/compose_project.sh; export COMPOSE_PROJECT_NAME="$(resolve_compose_project_name "$PWD")"; docker compose ls --format json`

Exit code: `0`

Output:
```text
exact_compose_rows_before=<none>
```

Command: `source scripts/lib/health.sh; check_port_available 15432 stage4 postgres; source .env.local; redact_db_url "$DATABASE_URL"`

Exit code: `0`

Output:
```text
COMPOSE_PROJECT_NAME=fjcloud_jul27_pm_3_local_schema_drift_detector_fjcloud_dev
exact_compose_rows_before=<none>
LOCAL_DB_PORT=15432
source_env_local_rc=0
DATABASE_URL_REDACTED=postgres://griddle@localhost:15432/fjcloud_dev
volume_name=fjcloud_jul27_pm_3_local_schema_drift_detector_fjcloud_dev_pgdata
volume_preexisting=no
service_state_before=absent
service_preexisting=no
docker_compose_port=0.0.0.0:15432
mutation_url_redacted=postgres://griddle@localhost:15432/fjcloud_drift_mutation_check
chosen_mutation_column=billing_plan
mutation_probe_expected_failure=rc_1_missing_customers_billing_plan
local_schema_verdict=clean
co_resident_local_ci_fast=present_waiting_30s
ERROR: closeout gate failed local_ci_fast_rc=1 git_diff_check_rc=0

```

Command: `docker compose up -d postgres; poll docker compose ps --format json postgres until healthy; docker compose port postgres 5432`

Exit code: `0`

Output:
```text
0.0.0.0:15432
poll 1 health=starting
poll 2 health=starting
poll 3 health=healthy
```

## Canonical Migration And Contract Gates

Command: `bash scripts/local-dev-migrate.sh`

Exit code: `0`

Output:
```text
[local-dev-migrate] Applying migrations to: postgres://griddle@localhost:15432/fjcloud_dev
[local-dev-migrate] Applying: 001_customers.sql
[local-dev-migrate] Applying: 002_deployments.sql
[local-dev-migrate] Applying: 003_usage_records.sql
[local-dev-migrate] Applying: 004_rate_cards.sql
[local-dev-migrate] Applying: 005_invoices.sql
[local-dev-migrate] Applying: 006_auth.sql
[local-dev-migrate] Applying: 007_stripe_integration.sql
[local-dev-migrate] Applying: 008_api_keys.sql
[local-dev-migrate] Applying: 009_deployment_extensions.sql
[local-dev-migrate] Applying: 010_alerts.sql
[local-dev-migrate] Applying: 011_vm_inventory.sql
[local-dev-migrate] Applying: 012_tenant_multitenant.sql
[local-dev-migrate] Applying: 013_index_migrations.sql
[local-dev-migrate] Applying: 014_billing_mode.sql
[local-dev-migrate] Applying: 015_cold_tier.sql
[local-dev-migrate] Applying: 016_cold_storage_pricing.sql
[local-dev-migrate] Applying: 017_fix_restore_idempotency.sql
[local-dev-migrate] Applying: 018_backfill_last_accessed.sql
[local-dev-migrate] Applying: 019_hetzner_region_pricing.sql
[local-dev-migrate] Applying: 020_add_oci_provider.sql
[local-dev-migrate] Applying: 021_index_replicas.sql
[local-dev-migrate] Applying: 022_canonicalize_replica_status.sql
[local-dev-migrate] Applying: 023_drop_billing_mode.sql
[local-dev-migrate] Applying: 024_billing_plan.sql
[local-dev-migrate] Applying: 025_quota_warning_sent_at.sql
[local-dev-migrate] Applying: 026_load_scraped_at.sql
[local-dev-migrate] Applying: 027_add_cold_gb_months_unit.sql
[local-dev-migrate] Applying: 028_subscriptions.sql
[local-dev-migrate] Applying: 029_subscription_resubscribe_and_enterprise_price.sql
[local-dev-migrate] Applying: 030_storage_service.sql
[local-dev-migrate] Applying: 031_object_storage_pricing.sql
[local-dev-migrate] Applying: 032_service_type.sql
[local-dev-migrate] Applying: 033_invoice_pdf_url.sql
[local-dev-migrate] Applying: 035_customer_fractional_egress_carryforward.sql
[local-dev-migrate] Applying: 036_per_mb_pricing.sql
[local-dev-migrate] Applying: 037_add_local_provider.sql
[local-dev-migrate] Applying: 038_replica_suspended_status.sql
[local-dev-migrate] Applying: 039_fix_invoice_unit_check.sql
[local-dev-migrate] Applying: 040_customers_deleted_at.sql
[local-dev-migrate] Applying: 041_audit_log.sql
[local-dev-migrate] Applying: 042_align_launch_rate_card_marketing_contract.sql
[local-dev-migrate] Applying: 043_email_log.sql
[local-dev-migrate] Applying: 044_email_suppression.sql
[local-dev-migrate] Applying: 045_email_log_suppressed_status.sql
[local-dev-migrate] Applying: 046_drop_subscriptions.sql
[local-dev-migrate] Applying: 047_resend_verification_cooldown.sql
[local-dev-migrate] Applying: 048_oauth_identities.sql
[local-dev-migrate] Applying: 049_free_plan_zero_minimum_spend.sql
[local-dev-migrate] Applying: 050_quota_warnings_sent_jsonb.sql
[local-dev-migrate] Applying: 051_customer_subscription_cycle_anchor.sql
[local-dev-migrate] Applying: 052_auth_lockout_state.sql
[local-dev-migrate] Applying: 053_disputes.sql
[local-dev-migrate] Applying: 054_password_reset_resend_cooldown.sql
[local-dev-migrate] Applying: 055_api_keys_managed_key_parity.sql
[local-dev-migrate] Applying: 056_algolia_import_jobs.sql
[local-dev-migrate] Applying: 057_catalog_lifecycle_intent_tiers.sql
[local-dev-migrate] Applying: 058_deployment_failure_reason.sql
[local-dev-migrate] Applying: 059_vm_inventory_reference_guard.sql
psql:<repo>/infra/migrations/059_vm_inventory_reference_guard.sql:187: NOTICE:  identifier "trg_algolia_import_jobs_destination_vm_id_vm_inventory_reference_guard" will be truncated to "trg_algolia_import_jobs_destination_vm_id_vm_inventory_referenc"
[local-dev-migrate] Applying: 060_algolia_import_erased_ack_checks.sql
[local-dev-migrate] Applying: 061_vm_host_metrics.sql
[local-dev-migrate] Applying: 062_algolia_erased_vm_retirement_blocker.sql
[local-dev-migrate] Applying: 063_algolia_create_terminal_deployment.sql
[local-dev-migrate] Applying: 064_vm_lifecycle_events.sql
[local-dev-migrate] Applying: 065_lifecycle_contract_repairs.sql
[local-dev-migrate] Applying: 066_algolia_import_terminal_outcome_presence.sql
[local-dev-migrate] Applying: 067_algolia_erased_tombstone_compaction.sql
[local-dev-migrate] All migrations applied (66 new, 0 skipped)
Applying: 001_customers.sql
Applying: 002_deployments.sql
Applying: 003_usage_records.sql
Applying: 004_rate_cards.sql
Applying: 005_invoices.sql
Applying: 006_auth.sql
Applying: 007_stripe_integration.sql
Applying: 008_api_keys.sql
Applying: 009_deployment_extensions.sql
Applying: 010_alerts.sql
Applying: 011_vm_inventory.sql
Applying: 012_tenant_multitenant.sql
Applying: 013_index_migrations.sql
Applying: 014_billing_mode.sql
Applying: 015_cold_tier.sql
Applying: 016_cold_storage_pricing.sql
Applying: 017_fix_restore_idempotency.sql
Applying: 018_backfill_last_accessed.sql
Applying: 019_hetzner_region_pricing.sql
Applying: 020_add_oci_provider.sql
Applying: 021_index_replicas.sql
Applying: 022_canonicalize_replica_status.sql
Applying: 023_drop_billing_mode.sql
Applying: 024_billing_plan.sql
Applying: 025_quota_warning_sent_at.sql
Applying: 026_load_scraped_at.sql
Applying: 027_add_cold_gb_months_unit.sql
Applying: 028_subscriptions.sql
Applying: 029_subscription_resubscribe_and_enterprise_price.sql
Applying: 030_storage_service.sql
Applying: 031_object_storage_pricing.sql
Applying: 032_service_type.sql
Applying: 033_invoice_pdf_url.sql
Applying: 035_customer_fractional_egress_carryforward.sql
Applying: 036_per_mb_pricing.sql
Applying: 037_add_local_provider.sql
Applying: 038_replica_suspended_status.sql
Applying: 039_fix_invoice_unit_check.sql
Applying: 040_customers_deleted_at.sql
Applying: 041_audit_log.sql
Applying: 042_align_launch_rate_card_marketing_contract.sql
Applying: 043_email_log.sql
Applying: 044_email_suppression.sql
Applying: 045_email_log_suppressed_status.sql
Applying: 046_drop_subscriptions.sql
Applying: 047_resend_verification_cooldown.sql
Applying: 048_oauth_identities.sql
Applying: 049_free_plan_zero_minimum_spend.sql
Applying: 050_quota_warnings_sent_jsonb.sql
Applying: 051_customer_subscription_cycle_anchor.sql
Applying: 052_auth_lockout_state.sql
Applying: 053_disputes.sql
Applying: 054_password_reset_resend_cooldown.sql
Applying: 055_api_keys_managed_key_parity.sql
Applying: 056_algolia_import_jobs.sql
Applying: 057_catalog_lifecycle_intent_tiers.sql
Applying: 058_deployment_failure_reason.sql
Applying: 059_vm_inventory_reference_guard.sql
psql:<repo>/infra/migrations/059_vm_inventory_reference_guard.sql:187: NOTICE:  identifier "trg_algolia_import_jobs_destination_vm_id_vm_inventory_reference_guard" will be truncated to "trg_algolia_import_jobs_destination_vm_id_vm_inventory_referenc"
Applying: 060_algolia_import_erased_ack_checks.sql
Applying: 061_vm_host_metrics.sql
Applying: 062_algolia_erased_vm_retirement_blocker.sql
Applying: 063_algolia_create_terminal_deployment.sql
Applying: 064_vm_lifecycle_events.sql
Applying: 065_lifecycle_contract_repairs.sql
Applying: 066_algolia_import_terminal_outcome_presence.sql
Applying: 067_algolia_erased_tombstone_compaction.sql
All migrations applied (66 new, 0 skipped)
no local schema drift
[local-dev-migrate] Done

```

Command: `bash scripts/tests/probe_local_schema_drift_test.sh`

Exit code: `0`

Output:
```text
=== probe_local_schema_drift.sh tests ===

PASS: identical schemas should exit 0
PASS: identical schemas should emit clean verdict
PASS: identical schemas should not emit fatal drift
PASS: identical case should inspect scratch oracle schema
PASS: identical case should inspect target schema
PASS: identical success cleanup should create a scratch database
PASS: identical success cleanup should drop a scratch database
PASS: identical success cleanup should use a simple scratch database name
PASS: identical success cleanup should drop the created scratch database
PASS: missing target column should exit 1
PASS: missing target column should name exact table.column
PASS: missing target column should explain missing status
PASS: missing target column should not emit clean verdict
PASS: unexpected target column should exit 1
PASS: unexpected target column should name exact table.column
PASS: unexpected target column should include unexpected
PASS: target-only table should exit 0
PASS: target-only table should be reported for operator context
PASS: target-only table should be informational
PASS: target-only table should still emit clean verdict
PASS: multiple column differences should exit 1
PASS: multiple differences should include accounts.email
PASS: multiple differences should include accounts.legacy_code
PASS: multiple differences should include invoices.total_cents
PASS: multiple differences should include usage_records.quantity
PASS: multiple differences should sort accounts.email before accounts.legacy_code
PASS: multiple differences should sort accounts before invoices
PASS: multiple differences should sort invoices before usage_records
PASS: scratch migration failure should exit 1
PASS: scratch migration failure should name scratch/oracle build
PASS: scratch migration failure should name oracle build
PASS: scratch migration failure should not emit clean verdict
PASS: oracle failure cleanup should create a scratch database
PASS: oracle failure cleanup should drop a scratch database
PASS: oracle failure cleanup should use a simple scratch database name
PASS: oracle failure cleanup should drop the created scratch database
PASS: first run should create a scratch database
PASS: second run should create a scratch database
PASS: first run should drop its own scratch database
PASS: second run should drop its own scratch database
PASS: scratch database names should be unique per invocation
PASS: detector script should exist
PASS: detector should cleanup on normal exit
PASS: detector should cleanup on interrupt
PASS: detector should cleanup on termination
PASS: detector should install normal-exit cleanup before creating scratch database
PASS: detector should install interrupt cleanup before creating scratch database

=== Results: 47 passed, 0 failed ===

```

Command: `bash scripts/tests/migrate_test.sh`

Exit code: `0`

Output:
```text
=== migrate.sh tests ===

PASS: run_migrations should return 0 on success
PASS: should apply all 3 migration files
PASS: first migration should be 001
PASS: last migration should be 003
PASS: log should mention first migration
PASS: log should mention last migration
PASS: run_migrations returns non-zero on psql failure
PASS: log should mention the failed migration
PASS: run_migrations should stop after the failed migration
PASS: first psql argument should be the database URL
PASS: custom runner should prefix every migration command
PASS: custom runner should receive the runner-visible migration path
PASS: pre-tracking legacy seed should complete successfully
PASS: legacy seed path should warn when user tables predate migration tracking
PASS: legacy seed warning should name the local schema drift probe remediation
PASS: legacy seed should record every existing migration filename
PASS: failed legacy seed insert should return non-zero
PASS: failed legacy seed insert should explain that seeding failed
PASS: failed legacy seed insert should not continue to apply loop
PASS: run_migrations returns non-zero when no SQL files are present
PASS: run_migrations should explain when the migration directory is empty
PASS: 045 migration should quote delivery_status literals to keep the CHECK constraint valid SQL

=== Results: 22 passed, 0 failed ===

```

Command: `bash scripts/tests/local_dev_migrate_test.sh`

Exit code: `0`

Output:
```text
=== local-dev-migrate.sh tests ===

PASS: host psql path should succeed
PASS: host psql should receive DATABASE_URL
PASS: host psql should apply migrations from repo infra/migrations
PASS: output should redact database URL password
PASS: output should not leak the raw password
PASS: missing host psql should fall back to docker runner
PASS: docker fallback should run psql through compose exec with parsed DB fields
PASS: fallback mode should not instruct host psql install
PASS: docker fallback should complete migration run
PASS: docker apply calls should use /migrations/<filename>.sql
PASS: docker apply calls should not use repo-host file paths
PASS: docker fallback should succeed with parse-focused DATABASE_URL
PASS: docker runner should use parsed user/password/database values
PASS: stdout/stderr should not leak the raw password
PASS: missing DATABASE_URL should fail
PASS: missing DATABASE_URL should report an actionable DATABASE_URL error
PASS: missing DATABASE_URL should not suggest host psql install
PASS: malformed DATABASE_URL should fail
PASS: malformed DATABASE_URL should report actionable parse guidance
PASS: malformed DATABASE_URL should not degrade to host psql install hint
PASS: malformed DATABASE_URL errors should not leak the raw password
PASS: malformed DATABASE_URL should fail before docker availability checks
PASS: malformed DATABASE_URL should remain a configuration error even without docker
PASS: malformed DATABASE_URL should not degrade into a docker tooling hint
PASS: malformed DATABASE_URL errors should not leak raw password when docker is absent
PASS: tracked migrations should not fail fallback runner
PASS: should report already-applied migrations as skipped
PASS: should not re-apply tracked migrations
PASS: missing host psql + unavailable docker should fail
PASS: failure should mention host psql availability
PASS: failure should mention docker/postgres access path
PASS: failure output should not leak DATABASE_URL password
PASS: successful migration plus drift probe should exit 0
PASS: local-dev-migrate should invoke schema drift probe with DATABASE_URL
PASS: schema drift probe should run after migration apply
PASS: schema drift probe output should appear before Done
PASS: migration failure should exit non-zero
PASS: migration failure should skip schema drift probe
PASS: migration failure should not print Done
PASS: schema drift probe failure should propagate as local-dev-migrate failure
PASS: schema drift probe failure path should invoke the probe
PASS: schema drift probe failure should explain failed post-migration validation
PASS: schema drift probe failure should not print Done

=== Results: 43 passed, 0 failed ===

```

Command: `bash scripts/local-ci.sh --gate local-schema-drift-contract`

Exit code: `0`

Output:
```text
Running 1 gate(s): local-schema-drift-contract
Mode: fast  Max parallel: 8


=== local-ci summary (wall 45s) ===
GATE                STATUS   SECS  LOG
----                ------   ----  ---
local-schema-drift-contract  PASS       45  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/local-schema-drift-contract.log

## Prod deploy drift (informational — does not affect exit code)
Prod deploy drift:
  dev_sha:            0905a617243b0153504de62a54b5d32ccece60a1
  build_time:         2026-07-26T11:50:21Z (30h 58m ago)
  commits_behind:     323
  deployable_drift:   true (behind)
  doc_only_ahead:     false
  dev_main_sha:       a4f5b8c207ab

Totals: pass=1 fail=0 skip=0
Result: PASS

```

## Mutation Proof

Command: `psql "$DATABASE_URL" -tAc SELECT...fjcloud_drift_mutation_check`

Exit code: `0`

Output:
```text

```

Command: `psql "$DATABASE_URL" -c CREATE DATABASE fjcloud_drift_mutation_check`

Exit code: `0`

Output:
```text
CREATE DATABASE

```

Command: `run_migrations_with_runner "<repo>/infra/migrations" "<repo>/infra/migrations" psql "<mutation_url>"`

Exit code: `0`

Output:
```text
Applying: 001_customers.sql
Applying: 002_deployments.sql
Applying: 003_usage_records.sql
Applying: 004_rate_cards.sql
Applying: 005_invoices.sql
Applying: 006_auth.sql
Applying: 007_stripe_integration.sql
Applying: 008_api_keys.sql
Applying: 009_deployment_extensions.sql
Applying: 010_alerts.sql
Applying: 011_vm_inventory.sql
Applying: 012_tenant_multitenant.sql
Applying: 013_index_migrations.sql
Applying: 014_billing_mode.sql
Applying: 015_cold_tier.sql
Applying: 016_cold_storage_pricing.sql
Applying: 017_fix_restore_idempotency.sql
Applying: 018_backfill_last_accessed.sql
Applying: 019_hetzner_region_pricing.sql
Applying: 020_add_oci_provider.sql
Applying: 021_index_replicas.sql
Applying: 022_canonicalize_replica_status.sql
Applying: 023_drop_billing_mode.sql
Applying: 024_billing_plan.sql
Applying: 025_quota_warning_sent_at.sql
Applying: 026_load_scraped_at.sql
Applying: 027_add_cold_gb_months_unit.sql
Applying: 028_subscriptions.sql
Applying: 029_subscription_resubscribe_and_enterprise_price.sql
Applying: 030_storage_service.sql
Applying: 031_object_storage_pricing.sql
Applying: 032_service_type.sql
Applying: 033_invoice_pdf_url.sql
Applying: 035_customer_fractional_egress_carryforward.sql
Applying: 036_per_mb_pricing.sql
Applying: 037_add_local_provider.sql
Applying: 038_replica_suspended_status.sql
Applying: 039_fix_invoice_unit_check.sql
Applying: 040_customers_deleted_at.sql
Applying: 041_audit_log.sql
Applying: 042_align_launch_rate_card_marketing_contract.sql
Applying: 043_email_log.sql
Applying: 044_email_suppression.sql
Applying: 045_email_log_suppressed_status.sql
Applying: 046_drop_subscriptions.sql
Applying: 047_resend_verification_cooldown.sql
Applying: 048_oauth_identities.sql
Applying: 049_free_plan_zero_minimum_spend.sql
Applying: 050_quota_warnings_sent_jsonb.sql
Applying: 051_customer_subscription_cycle_anchor.sql
Applying: 052_auth_lockout_state.sql
Applying: 053_disputes.sql
Applying: 054_password_reset_resend_cooldown.sql
Applying: 055_api_keys_managed_key_parity.sql
Applying: 056_algolia_import_jobs.sql
Applying: 057_catalog_lifecycle_intent_tiers.sql
Applying: 058_deployment_failure_reason.sql
Applying: 059_vm_inventory_reference_guard.sql
psql:<repo>/infra/migrations/059_vm_inventory_reference_guard.sql:187: NOTICE:  identifier "trg_algolia_import_jobs_destination_vm_id_vm_inventory_reference_guard" will be truncated to "trg_algolia_import_jobs_destination_vm_id_vm_inventory_referenc"
Applying: 060_algolia_import_erased_ack_checks.sql
Applying: 061_vm_host_metrics.sql
Applying: 062_algolia_erased_vm_retirement_blocker.sql
Applying: 063_algolia_create_terminal_deployment.sql
Applying: 064_vm_lifecycle_events.sql
Applying: 065_lifecycle_contract_repairs.sql
Applying: 066_algolia_import_terminal_outcome_presence.sql
Applying: 067_algolia_erased_tombstone_compaction.sql
All migrations applied (66 new, 0 skipped)

```

Command: `psql "<mutation_url>" -tAc SELECT column_name...customers`

Exit code: `0`

Output:
```text
billing_plan
created_at
deleted_at
email
email_verified_at
email_verify_expires_at
email_verify_token
failed_login_count
failed_login_window_start
failed_reset_count
failed_reset_window_start
failed_verify_count
failed_verify_window_start
id
lifecycle_generation
login_locked_until
name
object_storage_egress_carryforward_cents
password_hash
password_reset_expires_at
password_reset_token
quota_warning_sent_at
quota_warnings_sent
resend_password_reset_sent_at
resend_verification_sent_at
reset_locked_until
status
stripe_customer_id
subscription_cycle_anchor_at
updated_at
verify_locked_until

```

Command: `bash scripts/probe_local_schema_drift.sh`

Exit code: `1`

Output:
```text
Applying: 001_customers.sql
Applying: 002_deployments.sql
Applying: 003_usage_records.sql
Applying: 004_rate_cards.sql
Applying: 005_invoices.sql
Applying: 006_auth.sql
Applying: 007_stripe_integration.sql
Applying: 008_api_keys.sql
Applying: 009_deployment_extensions.sql
Applying: 010_alerts.sql
Applying: 011_vm_inventory.sql
Applying: 012_tenant_multitenant.sql
Applying: 013_index_migrations.sql
Applying: 014_billing_mode.sql
Applying: 015_cold_tier.sql
Applying: 016_cold_storage_pricing.sql
Applying: 017_fix_restore_idempotency.sql
Applying: 018_backfill_last_accessed.sql
Applying: 019_hetzner_region_pricing.sql
Applying: 020_add_oci_provider.sql
Applying: 021_index_replicas.sql
Applying: 022_canonicalize_replica_status.sql
Applying: 023_drop_billing_mode.sql
Applying: 024_billing_plan.sql
Applying: 025_quota_warning_sent_at.sql
Applying: 026_load_scraped_at.sql
Applying: 027_add_cold_gb_months_unit.sql
Applying: 028_subscriptions.sql
Applying: 029_subscription_resubscribe_and_enterprise_price.sql
Applying: 030_storage_service.sql
Applying: 031_object_storage_pricing.sql
Applying: 032_service_type.sql
Applying: 033_invoice_pdf_url.sql
Applying: 035_customer_fractional_egress_carryforward.sql
Applying: 036_per_mb_pricing.sql
Applying: 037_add_local_provider.sql
Applying: 038_replica_suspended_status.sql
Applying: 039_fix_invoice_unit_check.sql
Applying: 040_customers_deleted_at.sql
Applying: 041_audit_log.sql
Applying: 042_align_launch_rate_card_marketing_contract.sql
Applying: 043_email_log.sql
Applying: 044_email_suppression.sql
Applying: 045_email_log_suppressed_status.sql
Applying: 046_drop_subscriptions.sql
Applying: 047_resend_verification_cooldown.sql
Applying: 048_oauth_identities.sql
Applying: 049_free_plan_zero_minimum_spend.sql
Applying: 050_quota_warnings_sent_jsonb.sql
Applying: 051_customer_subscription_cycle_anchor.sql
Applying: 052_auth_lockout_state.sql
Applying: 053_disputes.sql
Applying: 054_password_reset_resend_cooldown.sql
Applying: 055_api_keys_managed_key_parity.sql
Applying: 056_algolia_import_jobs.sql
Applying: 057_catalog_lifecycle_intent_tiers.sql
Applying: 058_deployment_failure_reason.sql
Applying: 059_vm_inventory_reference_guard.sql
psql:<repo>/infra/migrations/059_vm_inventory_reference_guard.sql:187: NOTICE:  identifier "trg_algolia_import_jobs_destination_vm_id_vm_inventory_reference_guard" will be truncated to "trg_algolia_import_jobs_destination_vm_id_vm_inventory_referenc"
Applying: 060_algolia_import_erased_ack_checks.sql
Applying: 061_vm_host_metrics.sql
Applying: 062_algolia_erased_vm_retirement_blocker.sql
Applying: 063_algolia_create_terminal_deployment.sql
Applying: 064_vm_lifecycle_events.sql
Applying: 065_lifecycle_contract_repairs.sql
Applying: 066_algolia_import_terminal_outcome_presence.sql
Applying: 067_algolia_erased_tombstone_compaction.sql
All migrations applied (66 new, 0 skipped)
missing customers.billing_plan

```

Command: `psql "$DATABASE_URL" -c DROP DATABASE IF EXISTS fjcloud_drift_mutation_check`

Exit code: `0`

Output:
```text
DROP DATABASE

```

Chosen mutation column proof:
```text
chosen=billing_plan rc=0
```

Required assertion: `DATABASE_URL=<mutation_url> bash scripts/probe_local_schema_drift.sh` exited `1` and emitted `missing customers.billing_plan`.

## Local Verdict And Closeout

Command: `bash scripts/probe_local_schema_drift.sh`

Exit code: `0`

Output:
```text
Applying: 001_customers.sql
Applying: 002_deployments.sql
Applying: 003_usage_records.sql
Applying: 004_rate_cards.sql
Applying: 005_invoices.sql
Applying: 006_auth.sql
Applying: 007_stripe_integration.sql
Applying: 008_api_keys.sql
Applying: 009_deployment_extensions.sql
Applying: 010_alerts.sql
Applying: 011_vm_inventory.sql
Applying: 012_tenant_multitenant.sql
Applying: 013_index_migrations.sql
Applying: 014_billing_mode.sql
Applying: 015_cold_tier.sql
Applying: 016_cold_storage_pricing.sql
Applying: 017_fix_restore_idempotency.sql
Applying: 018_backfill_last_accessed.sql
Applying: 019_hetzner_region_pricing.sql
Applying: 020_add_oci_provider.sql
Applying: 021_index_replicas.sql
Applying: 022_canonicalize_replica_status.sql
Applying: 023_drop_billing_mode.sql
Applying: 024_billing_plan.sql
Applying: 025_quota_warning_sent_at.sql
Applying: 026_load_scraped_at.sql
Applying: 027_add_cold_gb_months_unit.sql
Applying: 028_subscriptions.sql
Applying: 029_subscription_resubscribe_and_enterprise_price.sql
Applying: 030_storage_service.sql
Applying: 031_object_storage_pricing.sql
Applying: 032_service_type.sql
Applying: 033_invoice_pdf_url.sql
Applying: 035_customer_fractional_egress_carryforward.sql
Applying: 036_per_mb_pricing.sql
Applying: 037_add_local_provider.sql
Applying: 038_replica_suspended_status.sql
Applying: 039_fix_invoice_unit_check.sql
Applying: 040_customers_deleted_at.sql
Applying: 041_audit_log.sql
Applying: 042_align_launch_rate_card_marketing_contract.sql
Applying: 043_email_log.sql
Applying: 044_email_suppression.sql
Applying: 045_email_log_suppressed_status.sql
Applying: 046_drop_subscriptions.sql
Applying: 047_resend_verification_cooldown.sql
Applying: 048_oauth_identities.sql
Applying: 049_free_plan_zero_minimum_spend.sql
Applying: 050_quota_warnings_sent_jsonb.sql
Applying: 051_customer_subscription_cycle_anchor.sql
Applying: 052_auth_lockout_state.sql
Applying: 053_disputes.sql
Applying: 054_password_reset_resend_cooldown.sql
Applying: 055_api_keys_managed_key_parity.sql
Applying: 056_algolia_import_jobs.sql
Applying: 057_catalog_lifecycle_intent_tiers.sql
Applying: 058_deployment_failure_reason.sql
Applying: 059_vm_inventory_reference_guard.sql
psql:<repo>/infra/migrations/059_vm_inventory_reference_guard.sql:187: NOTICE:  identifier "trg_algolia_import_jobs_destination_vm_id_vm_inventory_reference_guard" will be truncated to "trg_algolia_import_jobs_destination_vm_id_vm_inventory_referenc"
Applying: 060_algolia_import_erased_ack_checks.sql
Applying: 061_vm_host_metrics.sql
Applying: 062_algolia_erased_vm_retirement_blocker.sql
Applying: 063_algolia_create_terminal_deployment.sql
Applying: 064_vm_lifecycle_events.sql
Applying: 065_lifecycle_contract_repairs.sql
Applying: 066_algolia_import_terminal_outcome_presence.sql
Applying: 067_algolia_erased_tombstone_compaction.sql
All migrations applied (66 new, 0 skipped)
no local schema drift

```

Command: `bash scripts/local-ci.sh --fast`

Exit code: `1`

Output:
```text
Running 35 gate(s): check-sizes script-exec-bits port-collision-diagnose compose-project mirror-sync-contract deploy-currency-check-contract rc-wrapper-contract ses-coverage-a1 wave3-phase-receipt launch-closeout debbie-dry-run source-pollution stripe-checks status-doc-consistency roadmap-v2-shape package-manager-consistency dirmap-merge-driver secret-scan evidence-secret-hygiene web-lint index-export-clientside-contract rust-lint migration-test validate-bootstrap-parser validate-bootstrap-env-local publish-scripts-buildx algolia-safety-probe-contract flapjack-ami-pointer-contract engine-exposure-probe-contract fleet-dataplane-probe-contract usage-rollup-freshness-contract local-real-pipeline-contract local-schema-drift-contract local-multinode-migration-contract web-test (sequential)
Mode: fast  Max parallel: 8


=== local-ci summary (wall 398s) ===
GATE                STATUS   SECS  LOG
----                ------   ----  ---
algolia-safety-probe-contract  PASS        5  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/algolia-safety-probe-contract.log
check-sizes         PASS        4  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/check-sizes.log
compose-project     FAIL        0  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/compose-project.log
debbie-dry-run      PASS        3  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/debbie-dry-run.log
deploy-currency-check-contract  PASS        7  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/deploy-currency-check-contract.log
dirmap-merge-driver  PASS        0  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/dirmap-merge-driver.log
engine-exposure-probe-contract  PASS        2  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/engine-exposure-probe-contract.log
evidence-secret-hygiene  PASS        8  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/evidence-secret-hygiene.log
flapjack-ami-pointer-contract  PASS       35  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/flapjack-ami-pointer-contract.log
fleet-dataplane-probe-contract  PASS        4  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/fleet-dataplane-probe-contract.log
index-export-clientside-contract  PASS        1  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/index-export-clientside-contract.log
launch-closeout     PASS        4  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/launch-closeout.log
local-multinode-migration-contract  PASS        8  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/local-multinode-migration-contract.log
local-real-pipeline-contract  FAIL        0  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/local-real-pipeline-contract.log
local-schema-drift-contract  PASS       44  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/local-schema-drift-contract.log
migration-test      PASS        1  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/migration-test.log
mirror-sync-contract  PASS       19  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/mirror-sync-contract.log
package-manager-consistency  PASS        0  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/package-manager-consistency.log
port-collision-diagnose  PASS        5  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/port-collision-diagnose.log
publish-scripts-buildx  PASS        0  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/publish-scripts-buildx.log
rc-wrapper-contract  FAIL       62  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/rc-wrapper-contract.log
roadmap-v2-shape    PASS        0  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/roadmap-v2-shape.log
rust-lint           FAIL       35  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/rust-lint.log
script-exec-bits    PASS        1  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/script-exec-bits.log
secret-scan         PASS        1  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/secret-scan.log
ses-coverage-a1     PASS       49  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/ses-coverage-a1.log
source-pollution    FAIL        2  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/source-pollution.log
status-doc-consistency  PASS        0  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/status-doc-consistency.log
stripe-checks       PASS       12  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/stripe-checks.log
usage-rollup-freshness-contract  PASS      383  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/usage-rollup-freshness-contract.log
validate-bootstrap-env-local  PASS        2  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/validate-bootstrap-env-local.log
validate-bootstrap-parser  PASS        0  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/validate-bootstrap-parser.log
wave3-phase-receipt  PASS        3  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/wave3-phase-receipt.log
web-lint            FAIL        0  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/web-lint.log
web-test            FAIL        0  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/web-test.log

=== FAIL tails ===

--- compose-project (0s) ---
=== compose_project_test.sh ===

FAIL: expected fjcloud_gridl-infra-dev_fjcloud_dev, got 'fjcloud_jul27_pm_3_local_schema_drift_detector_fjcloud_dev'
FAIL: main and parallel worktrees collided on 'fjcloud_jul27_pm_3_local_schema_drift_detector_fjcloud_dev'
PASS: uppercase/punctuated path sanitizes to 'fjcloud_jul27_pm_3_local_schema_drift_detector_fjcloud_dev'
PASS: explicit COMPOSE_PROJECT_NAME overrides the path-derived default
PASS: local-dev-up.sh sources/uses the resolver
PASS: local-dev-up.sh exports COMPOSE_PROJECT_NAME so docker compose picks it up
PASS: local-dev-down.sh uses the resolver (so it tears down the SAME project the up script started)

=== Results: 5 passed, 2 failed ===

--- local-real-pipeline-contract (0s) ---
ERROR: web/node_modules missing — run 'cd web && npm ci' first

--- rc-wrapper-contract (62s) ---
PASS: browser_portal_cancel should pass when delegated browser lane succeeds
PASS: browser_portal_cancel should not expose placeholder critical skip reason
PASS: paid-beta-rc should report ready=true when Tier-1 registry proofs pass
PASS: paid-beta-rc should preserve Stage 1 plus Tier-1 registry cardinality
PASS: canary_outside_aws zero exit should map to pass
FAIL: canary_customer_loop should use --credential-env-file secrets and execute delegated canary owner (expected='pass' actual='')
PASS: ses_inbound exit code 21 should map to fail
PASS: ses_inbound exit code 21 should map to deterministic reason
PASS: ses_inbound exit code 22 should map to fail
PASS: ses_inbound exit code 22 should map to deterministic reason
FAIL: ses_inbound exit code 1 should map to fail (expected='fail' actual='')
FAIL: ses_inbound exit code 1 should map to deterministic reason (expected='ses_inbound_roundtrip_runtime_failed' actual='')
PASS: ses_inbound exit code 2 should map to fail
PASS: ses_inbound exit code 2 should map to deterministic reason
PASS: canary_customer_loop non-zero exit should map to fail
PASS: canary_customer_loop non-zero exit should map to deterministic reason
PASS: canary_customer_loop exit 100 should map to canonical skip
PASS: canary_customer_loop exit 100 should preserve canonical skip token
PASS: prod_full_vm_lifecycle should pass when the delegated data-plane owner succeeds
PASS: prod_full_vm_lifecycle should report pass on delegated success
PASS: prod_full_vm_lifecycle must invoke the lifecycle owner in data-plane mode
PASS: prod_full_vm_lifecycle must forward the credential env file as FJCLOUD_SECRET_FILE
PASS: prod_full_vm_lifecycle must place evidence under a per-step RC artifact directory
PASS: prod_full_vm_lifecycle should keep using the coordinator per-step log writer
PASS: missing credential env file must classify prod_full_vm_lifecycle as external_secret_missing
PASS: missing credential env file must not invoke the live lifecycle owner
PASS: malformed credential env file must classify prod_full_vm_lifecycle as external_secret_missing
PASS: malformed credential env file must record the parse-failed reason
PASS: malformed credential env file must not invoke the live lifecycle owner
PASS: credential env file missing admin credentials must classify prod_full_vm_lifecycle as external_secret_missing
PASS: credential env file missing admin credentials must record the missing-admin reason
PASS: credential env file missing admin credentials must not invoke the live lifecycle owner
PASS: FLAPJACK_ADMIN_KEY fallback should let prod_full_vm_lifecycle run
PASS: FLAPJACK_ADMIN_KEY fallback should satisfy prod_full_vm_lifecycle admin credential requirements
PASS: FLAPJACK_ADMIN_KEY fallback should still invoke the lifecycle owner in data-plane mode
PASS: staging-only prod_full_vm_lifecycle must be skipped
PASS: staging-only prod_full_vm_lifecycle must record the production-surface skip reason
PASS: staging-only mode must not invoke the prod lifecycle owner

=== Results: 108 passed, 5 failed ===

--- rust-lint (35s) ---
1785178250 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178250 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178250 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178250 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178250 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178250 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178250 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178250 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178250 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178250 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178250 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178250 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178250 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178251 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178251 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178251 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178251 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178251 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178251 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178251 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178251 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178251 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178251 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178251 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178251 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178251 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178251 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178252 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178252 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178252 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178252 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178252 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178252 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178252 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178252 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178252 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
1785178252 repo_env foreign checksum=11c44fee6fc1f49374b994d92b0bd030de1c59715dffd2f3cfd94a55451fbc93 expected=e31437a6fac5159da22faccb09c1d2121651fa95b36aa692c6acf9e3b231f491
FAIL: e2e_preflight_test.sh mutates checkout env/Vite shared state (bad_reads=125 changed_paths=repo_env)

=== Results: 0 passed, 1 failed ===

--- source-pollution (2s) ---
[sanitize] would rewrite .scrai/codemap_graph_cache.json
[sanitize] CHECK: run 'bash scripts/sanitize_worktree_paths.sh --write' to scrub rewritable files

--- web-lint (0s) ---
ERROR: web/node_modules missing — run 'cd web && npm ci' first

--- web-test (0s) ---
ERROR: web/node_modules has no npm install marker (.package-lock.json).
       It is missing or was installed by another package manager.
       Run 'cd web && rm -rf node_modules && npm ci'

## Prod deploy drift (informational — does not affect exit code)
Prod deploy drift:
  dev_sha:            0905a617243b0153504de62a54b5d32ccece60a1
  build_time:         2026-07-26T11:50:21Z (31h 6m ago)
  commits_behind:     323
  deployable_drift:   true (behind)
  doc_only_ahead:     false
  dev_main_sha:       a4f5b8c207ab

Totals: pass=28 fail=7 skip=0
Result: FAIL

```

Command: `git diff --check`

Exit code: `0`

Output:
```text

```

Scoped local schema verdict: `clean`; complete difference list: none (`no local schema drift`).

The `migration-test` gate in `local-ci --fast` ran and passed; it did not report SKIPPED.

Final cleanup query command: `psql "$DATABASE_URL" -tAc "SELECT datname FROM pg_database WHERE datname LIKE '%drift%' OR datname LIKE 'fjcloud\_schema\_oracle\_%'"`

Exit code: `0`

Output:
```text
health=healthy
rc=0
```

Teardown: stopped and removed only the exact stage-owned Postgres service/container/volume after the final cleanup probe.

## Secret Hygiene

The explicit grep gate checks for URL userinfo passwords. `scripts/check_evidence_secret_hygiene.sh` scans Stripe/AWS/Flapjack key shapes and is not by itself a Postgres-password check.

Command: `grep -nE '<URL_USERINFO_PASSWORD_REGEX>' docs/runbooks/evidence/local-schema-drift/20260727T190355Z/receipt.md`

Exit code: `1` (pass condition: no matches)

Output:
```text

```

Command: `bash scripts/check_evidence_secret_hygiene.sh`

Exit code: `0`

Output:
```text
Evidence secret hygiene passed
```

Note: the live command logs were first redacted with `redact_db_url`; the committed receipt then strips password userinfo entirely (`postgres://griddle@...`) so the URL-userinfo grep can fail closed on any remaining password-shaped URL.
