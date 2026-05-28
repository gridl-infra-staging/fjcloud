<!-- [scrai:start] -->
## prod_db_leak_cleanup

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| 20260521T172106Z_stage1_inventory | — |
| 20260521T180304Z_stage2_refund_proposal | — |
| 20260521T182407Z_stage3_refund_execution | — |
| 20260521T191408Z_stage4_deployment_termination | Stage 4 terminates exact-cohort customer deployments via the admin API endpoint using inventory CSV files from Stage 1, then validates that primary and rerun runs produce consistent results (primary completes all terminations, rerun produces no duplicate mutations) before building a summary artifact for Stage 5 consumption. |
| 20260521T193529Z_stage5_tenant_soft_delete | Stage 5 executes tenant soft-deletes via the admin API endpoint using Stage 1 cohort membership and Stage 4 disposition data, with reproducibility checks to ensure idempotency and a cross-run summary builder for Stage 6 consumption. |
| 20260521T201128Z_stage6_closeout | — |
<!-- [scrai:end] -->
