# Stage 3 gap-spec outcome

## Commands

- `bash scripts/validate_staging_dunning_delivery.sh --env-file /Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret --month 2026-07 --confirm-live-mutation`
  - rc: `1`
  - stdout: `validator.out`
  - stderr: `validator.err`
  - summary: `validator_summary.json`
- `gh run view 29211645943 --repo gridl-infra-staging/fjcloud --json status,conclusion,headSha,createdAt,updatedAt,url,jobs`
  - rc: `0`
  - captured: `staging_ci_status.json`
- `bash scripts/deploy_status.sh --json --env staging`
  - rc: `0`
  - captured: `deploy_status_after_sync.out`
- `bash scripts/check_evidence_secret_hygiene.sh`
  - rc: `0`
  - stdout: `secret_hygiene.out`
  - stderr: `secret_hygiene.err`

## Result

- Validator result: `failed`
- Validator classification: `rehearsal_failed`
- Validator failing step: `run_rehearsal`
- Nested rehearsal classification: `deployable_currency_drift`
- Reset gate: passed
- Live mutation reached: no
- Inbox probe rerun after sync: not run; staging deploy was still in progress and staging still reported deployable drift.
- Secret hygiene: passed

## Diagnosis

The repo-owned validator replay issue was fixed and proved locally by `bash scripts/tests/validate_staging_dunning_delivery_test.sh` at clean HEAD `2ceac5415a43bf836728a0b0daef924e192604c4`.

The live Stage 3 acceptance probes remain blocked by staging deploy state, not by the validator replay seam. After syncing canonical dev main to staging, staging CI run `29211645943` was still `in_progress` at `2026-07-12T22:50:02Z`; the `deploy-staging` job was running step 5, `Build release binaries in Amazon Linux 2023`. The deploy-status probe still reported `deployable_drift=true` and `commits_behind_main=26`, so rerunning the live probes again would reproduce the same reset/rehearsal guard failure.
