# Stage 3 gap-spec outcome

Live product probes did not reach green after the reset gate passed.

## Commands

- `bash scripts/validate_staging_dunning_delivery.sh --env-file /Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret --month 2026-07 --confirm-live-mutation`
  - rc: 1
  - top_level_result: failed
  - top_level_classification: rehearsal_failed
  - failing_step: run_rehearsal
  - nested_result: blocked
  - nested_classification: deployable_currency_drift
  - nested_detail: Staging deploy is behind deployable dev changes; deploy staging before running billing rehearsal.
- `bash scripts/probe_dunning_email_inbox_e2e.sh --env-file /Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret`
  - rc: 1
  - result: failed
  - classification: rehearsal_failed
  - detail: dunning owner script exited 1

## Reset gate

- guard: passed=True detail=Explicit staging env file, SSM hydration, and hostname checks passed.
- reset_test_state: passed=True detail=Reset completed for 2 allowlisted tenant(s).

## Deployable currency diagnosis

- dev_main_sha=1029bedb76a0501809f24b5f451b1c7390d55345
- staging.dev_sha=55757a6e01ea527a56d4fd53c4b35edcddb55861
- staging.commits_behind_main=29
- staging.deployable_drift=true
- staging.doc_only_ahead=false
- Diagnostic command evidence: `deploy_status.out`, `deploy_status.err`, `deploy_status.rc`, `deploy_status_staging_json.out`, `deploy_status_staging_json.err`, `deploy_status_staging_json.rc`.

## Hygiene

- `bash scripts/check_evidence_secret_hygiene.sh` rc=0
Evidence secret hygiene passed
