# SES IAM Read Policy Staging Apply Summary

- Branch: `batman/jul13_12pm_1_iam_ses_logs_read_apply`
- Pre-merge commit SHA: `49d3fb0a14b85e579eba9d1ca87637ba0137e186`
- Apply method: `terraform_apply`
- Policy name: `fjcloud-ses-send-events-read`
- Machine summary: `docs/runbooks/evidence/ses-iam-read/20260713T202728Z_staging_apply/summary.json`
- Account: `213880904778`
- Bound instance: `i-0fbc6d6bbbc8bdc6d`
- Bound instance profile: `fjcloud-instance-profile`
- Bound role: `fjcloud-instance-role`
- API probes:
  - `describe_log_groups`: `ok`
  - `filter_log_events`: `ok`
  - `describe_log_streams`: `ok`
  - `get_log_events`: `ok`
- Stream denominator: `5`
- State reconciliation: `not_needed`

Merge prep:

- Target: `main`
- Preferred merge style: rebase-and-merge.
- Serial Wave 1 has no sibling lane.
- Batman merge/push and the orchestration transition gate must pass before Wave 3 dispatch.
- The supervisor captures the actual post-merge SHA.
