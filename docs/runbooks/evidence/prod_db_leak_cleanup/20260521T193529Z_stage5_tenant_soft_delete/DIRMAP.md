<!-- [scrai:start] -->
## 20260521T193529Z_stage5_tenant_soft_delete

| File | Summary |
| --- | --- |
| 00_commands.sh | Stub summary for 00_commands.sh. |
| 50_reproducibility_check.sh | Stage 5 reproducibility/idempotency check.

Asserts:
  - primary and rerun summary violations are empty
  - rerun makes zero new soft-deletes via admin route
  - per-customer terminal disposition remains stable across runs. |
| 60_build_stage5_summary.sh | Build the single Stage 5 cross-run summary artifact consumed by Stage 6. |
<!-- [scrai:end] -->
