# Terminal §1 Six-Row In-VPC Bundle — 20260713T004742Z

- Bundle: `docs/runbooks/evidence/ses-coverage-a1/20260713T004742Z_jul12_pm_in_vpc_rerun`
- Reference bundle: `docs/runbooks/evidence/ses-coverage-a1/20260711T221212Z_in_vpc_rerun`
- Run UTC: `20260713T004742Z`
- Local HEAD SHA: `2082afdf59ff2386f0c1aef4a964d216c0bbc15f`
- Staging deployed dev SHA: `81a1c486f7b52638af445b34fcf9e22f8c857cfa` (== merged `origin/main`)
- Deployable drift: `false`; commits behind main: `0` (Stage 1 parity re-confirmed, not re-litigated)
- Scope: staging only; billing month `2026-06`
- Execution locality: all six probe owners ran **on the staging host** (`fjcloud-api-staging`,
  `i-0fbc6d6bbbc8bdc6d`) via `scripts/launch/ssm_exec_staging.sh` against a current-HEAD script
  checkout, with `.runtime/host.env` hydrated on-host from staging SSM parameters plus the
  authorized test-tenant allowlist.

## Result: `all_green.txt = 0` (4 / 6 green)

| probe_id | rc | pass | vs reference |
| --- | --- | --- | --- |
| verify_email_clickthrough | 0 | ✅ | **improved** (was ❌) |
| password_reset_clickthrough | 0 | ✅ | **improved** (was ❌) |
| dunning_email_inbox | 1 | ❌ | still ❌, new gate |
| ses_bounce | 0 | ✅ | ✅ (unchanged) |
| ses_complaint | 0 | ✅ | ✅ (unchanged) |
| staging_dunning_delivery | 1 | ❌ | still ❌, new gate |

## Headline findings

1. **Both probe-side residuals cleared.** `verify_email_clickthrough` and
   `password_reset_clickthrough` now pass against the deployed merged-`main` SHA
   (each verified on DB poll attempt 1). In the reference bundle both failed. Per the
   reference branch rule, these residuals retire only when a deployed six-row bundle
   records `all_green.txt=1`; this run is not all-green, so they are not yet retired,
   but they are green here.

2. **The merged Stripe-JSON fix cleared the original dunning blocker.** The reference
   bundle's `staging_dunning_delivery` failed at `reset_test_state` with
   `reset_stripe_list_invalid — Stripe invoice list returned invalid JSON`. On this
   deployed rerun the reset step **passes** ("Reset completed for 2 allowlisted
   tenant(s)"), and the rehearsal advances through `preflight` (ready),
   `metering_evidence` (usage_records + usage_daily passed), and `live_mutation_guard`
   (passed).

3. **New terminal gate: instance-role CloudWatch Logs IAM gap.** Both dunning rows now
   fail one step later, at `live_mutation_attempt` email-evidence capture, with
   classification `invoice_email_ses_query_failed`. Root cause is an IAM gap, not a
   product regression: the staging EC2 instance role `fjcloud-instance-role` is denied
   `logs:FilterLogEvents` / `logs:DescribeLogGroups` on `/fjcloud/staging/ses/send-events`.
   The log group exists and is populated (verified operator-side). See `GAP_SPEC.md`.

## §1 disposition

Not all-green → §1 stays `partial` under the pre-authorized `NOT-READY-on-section-1`
verdict. Evidence pointer repointed to this bundle. Per-row gap specs recorded in
`GAP_SPEC.md` and `failure_classifications.json`. No P0/P1 gap downgraded; the dunning
gap is reclassified from a product logic bug (Stripe JSON, now fixed) to an ops/IAM
prerequisite.
