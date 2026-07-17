# Stage 1 Inventory Diagnosis Findings (2026-05-21 UTC)

## Scope
- Objective: produce one frozen, read-only Stage 1 evidence bundle using existing owners only.
- Owner seams used:
  - `scripts/reliability/validate_vm_inventory_ec2_consistency.sh` (probe owner)
  - `scripts/lib/staging_db.sh::staging_db_run_sql` (remote DB-read owner)

## Sources
- `scripts/lib/staging_db.sh`
- `scripts/reliability/validate_vm_inventory_ec2_consistency.sh`
- `scripts/tests/staging_db_test.sh`
- `scripts/tests/validate_vm_inventory_ec2_consistency_test.sh`
- Evidence bundle: `docs/runbooks/evidence/fleet-recovery/20260521T172513Z_stage4_inventory_diagnosis/`

## Findings by Checklist Topic
1. Probe rerun now succeeds through canonical owner path.
- Evidence: `reconciliation_summary.json` present and parseable; `probe_exit_code.txt` contains `0`.

2. Raw probe capture filenames remain canonical and probe-owned.
- Evidence: `inventory_rows.json`, `deployment_rows.json`, `ec2_instances.json` all present with unchanged names.

3. Repo-owned truncation prerequisite is fixed.
- Evidence: `staging_db_run_sql_json_array_paginated` added in `scripts/lib/staging_db.sh`; live capture path switched to paginated calls in `scripts/reliability/validate_vm_inventory_ec2_consistency.sh`.
- Validation evidence: `scripts/tests/staging_db_test.sh` includes truncation-recovery test; focused suite passes.

4. Six canonical CSV exports are replayable and captured via owner seam.
- Evidence: `vm_inventory_status_counts.csv`, `customer_deployments_status_counts.csv`, `provisioning_age_distribution.csv`, `provisioning_rows_detailed.csv`, `provisioning_by_customer_cohort.csv`, `billing_accuracy_impact.csv`.
- Replay script evidence: `00_sql_commands.sh` present in the bundle root.

5. End-of-stage bundle validation passed.
- Evidence: JSON parse and `csv.DictReader` parse completed for all required artifacts in this bundle.

## Open Questions
- None for Stage 1 evidence-capture scope.
