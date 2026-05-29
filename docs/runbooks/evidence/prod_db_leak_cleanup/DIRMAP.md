<!-- [scrai:start] -->
## prod_db_leak_cleanup

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| 20260521T172106Z_stage1_inventory | — |
| 20260521T180304Z_stage2_refund_proposal | — |
| 20260521T182407Z_stage3_refund_execution | — |
| 20260521T191408Z_stage4_deployment_termination | Stage 4 terminates exact-cohort deployments via the admin API for every customer in the Stage 1 cleanup CSVs, then validates reproducibility (primary and rerun must not both mutate the same deployments) and captures pre-delete state for the next stage. |
| 20260521T193529Z_stage5_tenant_soft_delete | Stage 5 executes tenant soft-deletes via the `/admin/tenants/{id}` DELETE endpoint against an exact cohort validated in Stage 4, with strict fail-closed checks that customer sets match between Stage 1 and Stage 4, and includes reproducibility validation to confirm reruns produce no new deletes and customer dispositions remain stable. |
| 20260521T191408Z_stage4_deployment_termination | Stage 4 terminates customer deployments via admin API endpoints for exact-cohort customers identified in Stage 1 CSVs, then validates reproducibility across primary and rerun executions to ensure zero contract violations and completeness before Stage 5 consumes the summary artifact. |
| 20260521T193529Z_stage5_tenant_soft_delete | Stage 5 executes soft-deletes of customers via the admin API based on stage 1-4 cohort membership and eligibility, with fail-closed contracts when cohorts disagree, then validates idempotency via a reproducibility check and builds a cross-run summary for stage 6. |
| 20260521T201128Z_stage6_closeout | — |
<!-- [scrai:end] -->
