# Panics Alarm Deploy Evidence

UTC bundle: `docs/runbooks/evidence/panics-alarm/20260710T210400Z/`

HEAD SHA: `4e1581fe0cf762187e00d7a79491a20dd10074b0`

Newest live-state snapshot: `docs/live-state/20260710T202637Z/`

This bundle preserves the staging and prod Terraform apply evidence for the
`PanicsPerPeriod` CloudWatch alarm. The application metric counter remains
`panics_total`; the Terraform alarm watches the renamed `PanicsPerPeriod`
metric.

## Environment Status

| Environment | Status | Evidence |
| --- | --- | --- |
| staging | PASS | [`plan.txt`](staging/plan.txt), [`plan_show.txt`](staging/plan_show.txt), [`apply.txt`](staging/apply.txt), [`describe_alarms.json`](staging/describe_alarms.json) |
| prod | PASS | [`plan.txt`](prod/plan.txt), [`plan_show.txt`](prod/plan_show.txt), [`apply.txt`](prod/apply.txt), [`describe_alarms.json`](prod/describe_alarms.json) |

## Readback

- staging alarm: `fjcloud-staging-api-panics-high`; namespace `fjcloud/api`; action `arn:aws:sns:us-east-1:213880904778:fjcloud-alerts-staging`
- prod alarm: `fjcloud-prod-api-panics-high`; namespace `fjcloud/api`; action `arn:aws:sns:us-east-1:213880904778:fjcloud-alerts-prod`

No environment gap file is present because both environments have the required
plan, plan-show, apply, and CloudWatch readback artifacts.
