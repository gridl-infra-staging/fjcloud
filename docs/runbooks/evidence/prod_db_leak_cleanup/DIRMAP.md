<!-- [scrai:start] -->
## prod_db_leak_cleanup

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| 20260521T172106Z_stage1_inventory | — |
| 20260521T180304Z_stage2_refund_proposal | — |
| 20260521T182407Z_stage3_refund_execution | — |
| 20260521T191408Z_stage4_deployment_termination | Stage 4 deployment termination runner and validators: terminates exact-cohort deployments via admin API routes for customers listed in Stage 1 CSVs, validates reproducibility across primary and rerun executions, and builds a summary for Stage 5 consumption. |
| 20260521T193529Z_stage5_tenant_soft_delete | Stage 5 of an automated tenant deletion workflow that soft-deletes a specific customer cohort via the admin API, verifying deletion eligibility against Stage 4 disposition data and ensuring idempotency through reproducibility checks before handing off to Stage 6. |
| 20260521T201128Z_stage6_closeout | — |
<!-- [scrai:end] -->
