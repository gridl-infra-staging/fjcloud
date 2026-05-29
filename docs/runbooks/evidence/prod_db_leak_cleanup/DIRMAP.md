<!-- [scrai:start] -->
## prod_db_leak_cleanup

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| 20260521T172106Z_stage1_inventory | — |
| 20260521T180304Z_stage2_refund_proposal | — |
| 20260521T182407Z_stage3_refund_execution | — |
| 20260521T191408Z_stage4_deployment_termination | Stage 4 terminates exact-cohort deployments via admin API routes for customers specified in Stage 1 CSVs, then validates reproducibility between primary and rerun runs before building the summary artifact for Stage 5 consumption. |
| 20260521T193529Z_stage5_tenant_soft_delete | Stage 5 executes soft-deletes of eligible tenants via the HTTP admin endpoint based on Stage 4 eligibility criteria, with scripts to verify reproducibility, idempotency, and build a cross-run summary for Stage 6 consumption. |
| 20260521T201128Z_stage6_closeout | — |
<!-- [scrai:end] -->
