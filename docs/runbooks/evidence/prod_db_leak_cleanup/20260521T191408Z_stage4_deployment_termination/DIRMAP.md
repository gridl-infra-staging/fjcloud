<!-- [scrai:start] -->
## 20260521T191408Z_stage4_deployment_termination

| File | Summary |
| --- | --- |
| 00_commands.sh | Stub summary for 00_commands.sh. |
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
