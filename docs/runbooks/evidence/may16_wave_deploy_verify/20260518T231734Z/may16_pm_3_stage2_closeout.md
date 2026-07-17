# may16_pm_3 Stage 2 Closeout
- Verdict: `FAIL`
- Row transcript owner artifacts: `may16_pm_3_stage3.{stdout,stderr,exit}`
- Deploy-ancestry owner note: `may16_pm_3_deploy_ancestry_verdict.md`
- Relevant run JSON/log artifacts: `staging_run_26011767092.{json,txt}`, `staging_run_26061903895.{json,txt}`, `prod_run_26061910339.{json,txt}`

## Explicit CI runs used in this closeout
- Staging run `26011767092` (`2026-05-18T03:23:27Z`)
  - URL: https://github.com/gridl-infra-staging/fjcloud/actions/runs/26011767092
- Staging canonical-wave run `26061903895` (`2026-05-18T21:36:40Z`)
  - URL: https://github.com/gridl-infra-staging/fjcloud/actions/runs/26061903895
- Prod canonical-wave run `26061910339` (`2026-05-18T21:36:49Z`)
  - URL: https://github.com/gridl-infra-prod/fjcloud/actions/runs/26061910339

## Playwright job classification
- staging run `26011767092`: `playwright=failure`, `deploy-staging=success` for headSha `fa64aba...`.
- staging run `26061903895`: `playwright=failure`, deploy jobs skipped due additional failed gates.
- prod run `26061910339`: `playwright=failure`, deploy jobs skipped due additional failed gates.
- Classification for this row: Playwright is a real red owner job; for canonical wave runs it is part of the deploy-blocking failure set because deploy jobs did not execute.
