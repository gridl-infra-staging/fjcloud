# may16_pm_3 Stage 2 Deploy-Ancestry Verdict
- Source raw deploy status: `may16_pm_2_stage4.stdout`
- Source raw /version fallback: `version_direct_fallback.json`
- Source raw ancestor transcript: `ancestor_checks.txt`
- Source row CI transcript: `may16_pm_3_stage3.stdout`
- Source pipeline run JSON/logs: `staging_run_26011767092.{json,txt}`, `staging_run_26061903895.{json,txt}`, `prod_run_26061910339.{json,txt}`

## Deploy-ancestry dependency for row classification
- This row reuses the shared Stage 2 deploy-ancestry owner proof from `may16_pm_2_deploy_ancestry_verdict.md`.
- Shared deploy ancestry remains `FAIL` for this snapshot because staging mirror SHA is `pre-wave` and prod `/version` stayed `unknown`.
- Therefore, Playwright red jobs in wave runs are classified as part of the deploy-blocking failure set for this snapshot (deploy jobs skipped before wave reached live binary).

- VERDICT: `FAIL` (deploy ancestry proof is not wave/descendant for all live owners)
