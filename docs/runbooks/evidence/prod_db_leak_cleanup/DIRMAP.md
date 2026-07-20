<!-- [scrai:start] -->
## prod_db_leak_cleanup

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| 20260521T172106Z_stage1_inventory | — |
| 20260521T180304Z_stage2_refund_proposal | — |
| 20260521T182407Z_stage3_refund_execution | — |
| 20260521T191408Z_stage4_deployment_termination | This stage terminates exact-cohort deployments through canonical admin API routes (/admin/tenants and /admin/deployments) for customers specified in Stage 1 inventory CSVs, with reproducibility verification to ensure no duplicate mutations and summary building for Stage 5 consumption. |
| 20260521T193529Z_stage5_tenant_soft_delete | Stage 5 tenant soft-delete runner that executes DELETE operations via the admin API against eligible customers (those with no_deployments disposition from Stage 4), with reproducibility checks and summary aggregation for handoff to Stage 6. |
| 20260521T201128Z_stage6_closeout | — |
<!-- [scrai:end] -->
