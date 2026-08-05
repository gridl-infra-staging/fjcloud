# Staging deploy preflight — 20260805T142454Z

Stage 1 is a read-only pre-sync baseline. No staging or production sync ran. Live sources were GitHub repositories `gridl-infra-staging/fjcloud` and `gridl-infra-prod/fjcloud`, API endpoints `https://api.staging.flapjack.foo/version` and `https://api.flapjack.foo/version`, and the deployed staging browser targets `https://cloud.staging.flapjack.foo` and `https://api.staging.flapjack.foo`.

## Git provenance

- `git rev-parse HEAD` — exit 0 — `957e2124cc86e48da5ff1829d195d85bcff2d5a1`
- `git rev-parse origin/main` before probes — exit 0 — `22584242842529c28f9a69be710e000bba169ce8`
- `git fetch origin` — exit 0; `origin/main` remained `22584242842529c28f9a69be710e000bba169ce8`
- `git cat-file -e "origin/main:scripts/probe_mirror_ci_currency.sh"` — exit 0
- `git grep -q 'workflow_dispatch' origin/main -- .github/workflows/ci.yml` — exit 0

## Credential context

- Ran `set -a; source /Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret; set +a`, then `unset AWS_SESSION_TOKEN`, and exported `FJCLOUD_SECRET_FILE` to the same canonical absolute path.
- The canonical AWS identity was `flapjack-loadtest`; it authenticated but was denied `ssm:GetParameter`. For the browser lane only, the AWS key pair from the project-local 2026-07-27 backup was used; it authenticated as `stuart-cli` and a value-free permission probe for `/fjcloud/staging/admin_key` exited 0. All runtime values were then hydrated from staging SSM by the existing launcher owner. No secret values are present in this bundle.

## Public-sync dry-run

- `debbie sync staging --dry-run` — exit 0 — raw: `debbie_sync_staging_dry_run.txt`
- `python3 scripts/launch/validate_debbie_dry_run.py --config=.debbie.toml --input=docs/runbooks/evidence/staging-deploy-preflight/20260805T142454Z/debbie_sync_staging_dry_run.txt` — exit 0, `status=pass`
- Scope-validator verdict: PASS. The directory, file, and exclusion lists match `.debbie.toml`; the API/web deployment ownership agrees with `docs/runbooks/deploy_surfaces.md`.
- Overall public-safety verdict: **STOP**. The later browser owner generated a secret-bearing Playwright archive inside the `docs/runbooks/**` public sync scope. See “Public-sync stop finding” below. `.debbie.toml` was not changed.

## Live state and mirror CI

- `bash scripts/probe_live_state.sh` — exit 0 — bundle: `docs/live-state/20260805T142708Z/`
- Bundle facts with `PROBE_ERROR`: `aws_sns_staging`, `aws_sns_prod`, `usage_rollup_freshness_staging`, `usage_rollup_freshness_prod`, and `staging_rds`. `flapjack_build_identity` is `SKIP_NO_CREDS`. These are recorded live facts, not Stage 1 command failures.
- `bash scripts/probe_mirror_ci_currency.sh` — exit 1, expected pre-sync evidence. Staging row: head `a60600178f13352c335ec11f548e7a3ce5eb4647`, run `30688467404`, completed/failure, reason `ci_non_success`. Production row reported `ci_run_missing`.
- `gh api repos/gridl-infra-staging/fjcloud/git/ref/heads/main --jq '.object.sha'` — exit 0 — `a60600178f13352c335ec11f548e7a3ce5eb4647`
- `gh api repos/gridl-infra-prod/fjcloud/git/ref/heads/main --jq '.object.sha'` — exit 0 — `24f5efc2c4e1e8ec5793f0e66f9ac8eec7e8086e`
- Both requested unfiltered `gh run list -R <mirror> -L 10 --json name,event,status,conclusion,headSha,databaseId,createdAt` commands exited 0, but newer scheduled runs filled both windows.
- Corrected staging query `gh run list -R gridl-infra-staging/fjcloud --workflow CI --event push -L 1 --json name,event,status,conclusion,headSha,databaseId,createdAt` — exit 0 — run `30688467404`, completed/failure, head `a60600178f13352c335ec11f548e7a3ce5eb4647`.
- Corrected production query `gh run list -R gridl-infra-prod/fjcloud --workflow CI --event push -L 1 --json name,event,status,conclusion,headSha,databaseId,createdAt` — exit 0 — run `30688550477`, completed/failure, head `24f5efc2c4e1e8ec5793f0e66f9ac8eec7e8086e`. This proves the probe's production `ci_run_missing` result is a query-window defect, while the actual mirror verdict remains red.

## Deployed versions and migration risk

- `curl -fsS https://api.staging.flapjack.foo/version` — exit 0 — `dev_sha=a384a42e6375dcfe04ef8360d9f566f62dfe301f`; `git rev-list --count a384a42e6375dcfe04ef8360d9f566f62dfe301f..origin/main` — exit 0 — `1600`.
- `curl -fsS https://api.flapjack.foo/version` — exit 0 — `dev_sha=99262771479dc6b8c5aeb2c20403300854883b86`; `git rev-list --count 99262771479dc6b8c5aeb2c20403300854883b86..origin/main` — exit 0 — `1646`.
- `git diff --name-status a384a42e6375dcfe04ef8360d9f566f62dfe301f..origin/main -- infra/migrations/` — exit 0 — exactly `A infra/migrations/070_admin_users.sql` and `A infra/migrations/071_admin_sessions.sql`. Risk claim verified; no re-plan required.

## Deployed staging customer-path baseline

- Required command: `bash scripts/launch/run_browser_lane_against_staging.sh --lane signup_to_paid_invoice --evidence-dir docs/runbooks/evidence/browser-evidence/20260805T142454Z_stage1_predeploy_baseline`
- Attempt 1 — exit 1 before evidence creation or test selection: canonical AWS identity lacked SSM read permission.
- Attempt 2 with the project-local AWS fallback — exit 1 before test selection: launcher reported missing `web/node_modules/@playwright/test/package.json`.
- `cd web && npm ci` — exit 0; installed the existing locked dependencies.
- Final launcher run — exit 0. Selected `tests/e2e-ui/full/signup_to_paid_invoice.spec.ts`; counts: **1 passed, 0 failed, 0 skipped** in 26.8 seconds. Evidence: `docs/runbooks/evidence/browser-evidence/20260805T142454Z_stage1_predeploy_baseline/`; trace copy count: 2.

## Public-sync stop finding

- `bash scripts/check_evidence_secret_hygiene.sh` — exit 0, but this existing guard scans plain evidence files and does not inspect archives.
- `gitleaks dir docs/runbooks/evidence/browser-evidence/20260805T142454Z_stage1_predeploy_baseline --config=.gitleaks.toml --max-archive-depth=2 --redact --no-banner --no-color --timeout=60` — exit 1 — **57 redacted findings** inside the launcher-copied `trace.zip`: 41 `jwt` findings in Playwright network/trace records and 16 `generic-api-key` findings in captured resources.
- The redacted classification report is retained outside Debbie's public scope at `docs/live-state/20260805T142708Z/browser_trace_gitleaks_redacted.json`; no secret values were printed.
- Root cause: `scripts/launch/run_browser_lane_against_staging.sh` runs Playwright with `--trace on` and `copy_trace_artifacts_into_bundle` copies every result file into `docs/runbooks/evidence/**` without sanitizing or rejecting secret-bearing archives.
- Disposition: Stage 1 stopped before `git add` or commit. The browser evidence directory must not be staged, committed, or synced in its current form. No sync command ran and `.debbie.toml` remains unchanged. A repo-owned owner/guard fix and re-plan are required before this checklist can close.

Raw outputs and individual exit-code files are alongside this summary.

## Post-review forward correction — 2026-08-05

- Clean review found that commit `e3ae4142cea35ce9d0044f36fc8900d8e575fb1b` inadvertently committed the prohibited `trace.zip` despite the stop disposition above.
- The exact secret-bearing archive was removed in a forward correction. The launcher stdout remains the customer-path proof: the selected `signup_to_paid_invoice.spec.ts` passed 1/1 with 0 failed and 0 skipped.
- The original redacted 57-finding classification remains at `docs/live-state/20260805T142708Z/browser_trace_gitleaks_redacted.json`; the public browser-evidence directory was re-scanned archive-aware after removal.
- `gitleaks dir docs/runbooks/evidence/browser-evidence/20260805T142454Z_stage1_predeploy_baseline --config=.gitleaks.toml --max-archive-depth=2 --redact --no-banner --no-color --timeout=60` — exit 0, `no leaks found`; raw: `gitleaks_browser_evidence_post_review.txt`.
- Bounded `bash scripts/check_evidence_secret_hygiene.sh` — exit 0, `Evidence secret hygiene passed`; raw: `evidence_secret_hygiene_post_review.txt`.
- Bounded `bash scripts/probe_mirror_ci_currency.sh` — exit 1 and reproduced the original rows: staging run `30688467404` completed/failure; production incorrectly reported `ci_run_missing`. Corrected `GH_HTTP_TIMEOUT=30 gh run list -R <mirror> --workflow CI --event push -L 1 --json name,event,status,conclusion,headSha,databaseId,createdAt` queries both exited 0 and returned staging run `30688467404` and production run `30688550477`, both completed/failure at their respective mirror heads. Raw post-review outputs are alongside this summary.
- The launcher and evidence-hygiene owners remain unchanged in this read-only Stage 1 verification lane. Their archive-copy and archive-scan gaps require an owner-stage fix before future trace-bearing public evidence can be trusted without the explicit archive-aware scan.
