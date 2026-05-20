# may16_pm_2 Stage 2 Closeout
- Verdict: `FAIL`
- Deploy proof owner artifacts: `may16_pm_2_stage4.{stdout,stderr,exit}`, `version_direct_fallback.json`, `ancestor_checks.txt`
- CI owner artifacts: `gh_run_list_gridl-infra-staging_fjcloud.json`, `gh_run_list_gridl-infra-prod_fjcloud.json`, per-run `*_run_<id>.json` and `*_log_failed.txt`

## Explicit CI runs used in this closeout
- Staging canonical-wave run: `26061903895` (`2026-05-18T21:36:40Z`)
  - URL: https://github.com/gridl-infra-staging/fjcloud/actions/runs/26061903895
- Prod canonical-wave run: `26061910339` (`2026-05-18T21:36:49Z`)
  - URL: https://github.com/gridl-infra-prod/fjcloud/actions/runs/26061910339

## Deploy-ancestry classification
- staging `/version` response (captured 2026-05-18): `dev_sha=67d48abce51678885b86b248d1c449756fd9206d`, `mirror_sha=fa64aba192866d5aa72e6409b3ec04fe6375ea16`.
- Canonical staging wave SHA: `3d179dd0ea6d0f9bb4879bf4dcb7c24166346d9e`.
- Staging mirror ancestry command exited `1` (`pre-wave`):
  - `git -C /Users/stuart/repos/gridl-infra-staging/fjcloud merge-base --is-ancestor 3d179dd0ea6d0f9bb4879bf4dcb7c24166346d9e fa64aba192866d5aa72e6409b3ec04fe6375ea16`
- Staging dev_sha ancestry command exited `128`; classify as `unknown` (no valid ancestry verdict from that comparison):
  - `git merge-base --is-ancestor 3d179dd0ea6d0f9bb4879bf4dcb7c24166346d9e 67d48abce51678885b86b248d1c449756fd9206d`
- Prod `/version` probe returned `unknown` in this run, so prod ancestry is `unknown` from owner probe output.

## Mirror-CI deploy correctness effect
- Staging run `26061903895` failed jobs: `rust-test`, `rust-lint`, `secret-scan`, `playwright`; `deploy-staging` and `deploy-prod` were skipped.
- Prod run `26061910339` failed jobs: `rust-test`, `rust-lint`, `secret-scan`, `playwright`; `deploy-staging` and `deploy-prod` were skipped.
- Because deploy jobs were skipped on canonical wave SHAs, these CI failures are deploy-correctness-breaking for wave rollout in this snapshot.
