# GAP SPEC

Bundle: `docs/runbooks/evidence/ses-inbox-canary-clean-env/20260709T104734Z/ses`
Live-state snapshot: `docs/live-state/20260709T104734Z/SUMMARY.md`

## Summary

STS succeeded with account `213880904778` and ARN `arn:aws:iam::213880904778:user/stuart-cli`, so this is not the prior stale ambient AWS credential failure. Both required SES modes failed before any live SES send because the probe preflight could not find `DATABASE_URL` or `INTEGRATION_DB_URL` after loading the canonical clean secret file.

## Non-Green Rows

- `ses_bounce`: rc=2 pass=0
  - Classification: `missing_database_url_in_clean_env_probe_contract`
  - Current owner: `scripts/probe_ses_bounce_complaint_e2e.sh::main`
  - Smallest unblocking owner: `scripts/probe_ses_bounce_complaint_e2e.sh::main` plus the existing staging env hydration contract in `scripts/launch/hydrate_seeder_env_from_ssm.sh`
  - Exact blocker: `preflight` reported `Missing required environment values: DATABASE_URL|INTEGRATION_DB_URL`.
  - Observed evidence: `ses_bounce.stdout` contains the probe JSON; `ses_bounce.stderr` is empty; `ses_bounce.exit` is `2`.
  - Proxy evidence and bias/tolerance: none. Because `first_live_send`, `poll_sns_side_effects`, `second_live_send`, and `cleanup_probe_customer` did not run, this bundle cannot infer SES suppression or audit success from exit status or prior evidence.
  - Conditional disposition: `repo_owned_prerequisite_for_clean_env_database_hydration`
- `ses_complaint`: rc=2 pass=0
  - Classification: `missing_database_url_in_clean_env_probe_contract`
  - Current owner: `scripts/probe_ses_bounce_complaint_e2e.sh::main`
  - Smallest unblocking owner: `scripts/probe_ses_bounce_complaint_e2e.sh::main` plus the existing staging env hydration contract in `scripts/launch/hydrate_seeder_env_from_ssm.sh`
  - Exact blocker: `preflight` reported `Missing required environment values: DATABASE_URL|INTEGRATION_DB_URL`.
  - Observed evidence: `ses_complaint.stdout` contains the probe JSON; `ses_complaint.stderr` is empty; `ses_complaint.exit` is `2`.
  - Proxy evidence and bias/tolerance: none. Because `first_live_send`, `poll_sns_side_effects`, `second_live_send`, and `cleanup_probe_customer` did not run, this bundle cannot infer SES suppression or audit success from exit status or prior evidence.
  - Conditional disposition: `repo_owned_prerequisite_for_clean_env_database_hydration`

## Prior Bundle Comparison

`docs/runbooks/evidence/ses-coverage-a1/20260612T003052Z_in_vpc_rerun/SUMMARY.md` records `ses_bounce` and `ses_complaint` as green (`rc=0`, `pass=1`) while unrelated verify/password-reset/dunning rows kept the aggregate bundle red. This Stage 1 failure is different: the fresh SES rows themselves are red at preflight, before the owner can prove suppression or audit side effects.

## Smallest Fix Surface

The clean secret file at `/Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret` provides the AWS/API/SES values needed to authenticate, but not a direct database URL. The repo already has a staging SSM hydrator that emits `DATABASE_URL` from `/fjcloud/staging/database_url`. The smallest repo-owned unblock is to align the SES probe owner with that existing staging hydration contract, or to make the stage command explicitly hydrate `DATABASE_URL` before invoking the unchanged `<bounce|complaint> <staging-env-file>` owner command.

## Open Questions

- none
