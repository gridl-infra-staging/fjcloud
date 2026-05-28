<!-- [scrai:start] -->
## 20260521T193529Z_stage5_tenant_soft_delete

| File | Summary |
| --- | --- |
| 00_commands.sh | Stage 5 exact-cohort tenant soft-delete runner.

Mutation owner:
  DELETE /admin/tenants/{id}
    -> infra/api/src/routes/admin/tenants.rs::delete_tenant
    -> CustomerRepo::soft_delete

Input SSOT:
  - Stage 1 exact CSVs (cohort membership owner)
  - Stage 4 40_stage4_summary.json (delete-eligibility/disposition owner)

Contract:
  - Fail closed if Stage 1 and Stage 4 customer sets disagree for any env.
  - DELETE only rows whose Stage 4 customer_disposition == no_deployments.
  - Staging list_http_404 rows are verification-only until read-only DB proof
    confirms status='deleted' and deleted_at is non-null.

Test mode:
  STAGE5_TEST_MODE=1 bypasses .env/SSM resolution and uses STAGE5_* overrides. |
| 50_reproducibility_check.sh | Stage 5 reproducibility/idempotency check.

Asserts:
  - primary and rerun summary violations are empty
  - rerun makes zero new soft-deletes via admin route
  - per-customer terminal disposition remains stable across runs. |
| 60_build_stage5_summary.sh | Build the single Stage 5 cross-run summary artifact consumed by Stage 6. |
<!-- [scrai:end] -->
