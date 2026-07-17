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
| 20260521T191408Z_stage4_deployment_termination | Stage 4 terminates exact-cohort deployments via the admin API for every customer in the Stage 1 cleanup CSVs, validates reproducibility across primary and rerun executions, and produces a single summary artifact for Stage 5 to consume. |
| 20260521T193529Z_stage5_tenant_soft_delete | Stage 5 tenant soft-delete pipeline containing a runner that deletes eligible customers via the admin DELETE API (validated against Stage 1/4 cohort agreement), a reproducibility check ensuring idempotency, and a summary builder for Stage 6 consumption. |
| 20260521T191408Z_stage4_deployment_termination | Stage 4 terminates exact-cohort deployments via the admin API for every customer in the Stage 1 cleanup CSVs, then verifies reproducibility (rerun must not create new mutations) and builds the summary artifact for Stage 5 pre-delete capture. |
| 20260521T193529Z_stage5_tenant_soft_delete | Stage 5 soft-deletes eligible tenants via the admin API route using customer cohort membership and delete-disposition data from prior stages, with fail-closed validation that stage inputs remain consistent and reruns produce idempotent results (no duplicate deletes, stable per-customer disposition). |
| 20260521T191408Z_stage4_deployment_termination | Stage 4 executes deployment terminations for the exact-cohort customers identified in Stage 1 via the admin API routes, then verifies that the primary and rerun runs are consistent (no duplicate mutations, zero violations, complete capture) before building the summary artifact for Stage 5. |
| 20260521T193529Z_stage5_tenant_soft_delete | Stage 5 executes exact-cohort tenant soft-deletes via the admin DELETE endpoint against customers identified in Stage 1 CSVs and validated by Stage 4 disposition rules, with reproducibility checks ensuring idempotency and a final summary artifact for Stage 6. |
| 20260521T191408Z_stage4_deployment_termination | Stage 4 terminates exact-cohort customer deployments through canonical admin routes by querying Stage 1's CSV inventory, then validates the primary run against a rerun to ensure all mutations completed once and pre-delete records are frozen for Stage 5. |
| 20260521T193529Z_stage5_tenant_soft_delete | Stage 5 soft-deletes tenants eligible from Stage 4 (no_deployments disposition) via the admin API, validates reproducibility and stable customer disposition across reruns, and builds a cross-run summary for Stage 6. |
| 20260521T201128Z_stage6_closeout | — |
<!-- [scrai:end] -->
