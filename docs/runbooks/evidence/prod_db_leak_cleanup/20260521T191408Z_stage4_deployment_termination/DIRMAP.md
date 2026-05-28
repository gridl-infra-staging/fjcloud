<!-- [scrai:start] -->
## 20260521T191408Z_stage4_deployment_termination

| File | Summary |
| --- | --- |
| 00_commands.sh | Stage 4 admin-route deployment termination runner.

Purpose
  Terminate exact-cohort deployments through the canonical admin route
      /admin/tenants/{customer_id}/deployments       (list, pre-mutation)
      /admin/deployments/{deployment_id}             (DELETE, mutation)
  for every customer in the Stage 1 exact CSV pair:
      docs/runbooks/evidence/prod_db_leak_cleanup/20260521T172106Z_stage1_inventory/10_prod_exact_cleanup.csv
      docs/runbooks/evidence/prod_db_leak_cleanup/20260521T172106Z_stage1_inventory/11_staging_exact_cleanup.csv

Source of truth
  The Stage 1 exact CSVs are the ONLY input set this runner ever queries.
  No customer ID is touched unless it appears in those CSVs. |
| 50_reproducibility_check.sh | Stage 4 reproducibility check.

Compares primary and rerun disposition summaries and asserts:
  - All terminating customers in primary are NOT also terminating in rerun
    (the rerun must not produce new mutations — every running deployment
    should have been terminated in primary).
  - Both runs end with zero contract violations.
  - Pre-delete capture is complete for every Stage 1 exact-cohort customer
    in BOTH runs (so Stage 5 has a frozen pre-delete deployment record). |
| 60_build_stage4_summary.sh | Build the single Stage 4 summary artifact that Stage 5 consumes.
Derived only from the primary run disposition table — no parallel list. |
<!-- [scrai:end] -->
