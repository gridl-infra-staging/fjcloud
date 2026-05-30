<!-- [scrai:start] -->
## prod_db_leak_cleanup

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| 20260521T172106Z_stage1_inventory | — |
| 20260521T180304Z_stage2_refund_proposal | — |
| 20260521T182407Z_stage3_refund_execution | — |
| 20260521T191408Z_stage4_deployment_termination | Stage 4 executes deployment terminations for exact-cohort customers via the canonical admin API routes, verifies that a rerun produces no new mutations and maintains contract integrity, then builds a summary artifact for Stage 5. |
| 20260521T193529Z_stage5_tenant_soft_delete | Stage 5 of a tenant soft-delete pipeline that executes DELETE /admin/tenants/{id} for exact-cohort customers with no_deployments disposition, enforcing fail-closed agreement between Stage 1 input CSVs and Stage 4 eligibility data, with reproducibility validation and a summary artifact for Stage 6 handoff. |
| 20260521T191408Z_stage4_deployment_termination | Stage 4 terminates exact-cohort deployments through canonical admin API routes for customers listed in Stage 1 inventory CSVs, with reproducibility checks to ensure the rerun doesn't produce new mutations and a summary builder for Stage 5 consumption. |
| 20260521T193529Z_stage5_tenant_soft_delete | Stage 5 executes exact-cohort soft-deletes via the admin DELETE tenant endpoint, enforcing fail-closed validation against Stage 1 and Stage 4 inputs and verifying idempotency across reruns. |
| 20260521T201128Z_stage6_closeout | — |
<!-- [scrai:end] -->
