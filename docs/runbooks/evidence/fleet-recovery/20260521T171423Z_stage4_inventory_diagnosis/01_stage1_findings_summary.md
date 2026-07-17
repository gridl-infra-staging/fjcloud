# Stage 1 Inventory Diagnosis Findings (2026-05-21 UTC)

## Scope
- Goal: produce the canonical read-only evidence bundle for Stage 1 without introducing a new probe or DB-read path.
- Owner seams used: `scripts/reliability/validate_vm_inventory_ec2_consistency.sh` and `scripts/lib/staging_db.sh::staging_db_run_sql`.

## Item-by-item Findings
1. **Bundle bootstrap from bash + SSM param**
- Evidence: `00_sql_commands.sh` created at this bundle root; capture run exported `DATABASE_URL_SSM_PARAM=/fjcloud/prod/database_url`.
- Source: `docs/runbooks/evidence/fleet-recovery/20260521T171423Z_stage4_inventory_diagnosis/00_sql_commands.sh`, checklist note.

2. **Probe rerun through canonical owner**
- Evidence: Probe invoked with `--evidence-dir`; raw probe files and stderr were emitted.
- Source: `reconciliation_summary.stderr.txt`, `inventory_rows.json`, `deployment_rows.json`, `ec2_instances.json`.

3. **Exit-contract persistence (`0|1`)**
- Result: **not satisfiable in this run** because probe returned `2` (system-error path), matching owner test contract that `2` is the true error code.
- Source: `scripts/tests/validate_vm_inventory_ec2_consistency_test.sh` (exit assertions), `reconciliation_summary.stderr.txt`.

4. **Probe-owned raw captures preserved**
- Evidence: canonical raw filenames exist exactly as emitted by probe.
- Source: `inventory_rows.json`, `deployment_rows.json`, `ec2_instances.json`.

5. **Replayable SQL export script authored**
- Evidence: six canonical `COPY ... TO STDOUT WITH CSV HEADER` statements are present and wired via `staging_db_run_sql`.
- Source: `00_sql_commands.sh`.

6. **SQL export execution**
- Result: **not run** due prior probe system-error gate failure.

7. **Automated bundle validation**
- Result: **failed** because probe summary was empty/invalid after deployment JSON truncation.

## Root Cause Evidence
- `deployment_rows.json` size was 24,001 bytes and ended with `--output truncated--`, then probe JSON parser failed (`json.decoder.JSONDecodeError`) and exited `2`.
- Source: `deployment_rows.json`, `reconciliation_summary.stderr.txt`.
- External reference: AWS `GetCommandInvocation` documents `StandardOutputContent` max length 24,000 (`https://docs.aws.amazon.com/systems-manager/latest/APIReference/API_GetCommandInvocation.html`).

## Open Questions
- Can `staging_db_run_sql` be extended to use S3/CloudWatch output retrieval for large payloads while remaining the single DB-read owner seam?
- Should probe-side DB capture switch to bounded pagination to keep each `staging_db_run_sql` payload below SSM output limits?
