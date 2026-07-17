# GAP_SPEC — 20260713T004742Z in-VPC rerun

Two non-green rows. Both trace to a single repo-owned-prerequisite ops/IAM gap.

## Gap 1 (P1) — staging_dunning_delivery

- **probe_id:** `staging_dunning_delivery`
- **owner path:** `scripts/validate_staging_dunning_delivery.sh`
- **rc:** 1 · **classification:** `invoice_email_ses_query_failed`
- **observed detail:** Rehearsal `reset_test_state`, `preflight` (ready),
  `metering_evidence`, and `live_mutation_guard` all pass; `live_mutation_attempt`
  fails at email-evidence capture — "CloudWatch Logs SES send-events query failed
  while checking invoice email evidence. (attempts=1)."
- **root cause:** The staging EC2 instance role `arn:aws:iam::213880904778:role/fjcloud-instance-role`
  is denied `logs:FilterLogEvents` and `logs:DescribeLogGroups` on
  `arn:aws:logs:us-east-1:213880904778:log-group:/fjcloud/staging/ses/send-events`.
  `ops/iam/fjcloud-instance-role.tf` grants only CloudWatch Logs **write** actions
  (`logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:DescribeLogStreams`,
  `logs:PutLogEvents`) for the CloudWatch Agent — never read/query actions. The on-host
  billing-rehearsal email-evidence step
  (`scripts/lib/staging_billing_rehearsal_email_evidence.sh::run_ses_cloudwatch_logs_lookup`)
  requires `logs:FilterLogEvents`. The log group exists and is populated (operator-side
  `aws logs describe-log-groups` reports `storedBytes=8088216`, `retentionInDays=14`).
- **disposition:** Repo-owned-prerequisite ops/IAM fix, **out of scope for this
  verify-only stage** (stage charter: no product/infra code change; failing rows yield a
  gap spec, not a patch). Fix owner: `ops/iam/fjcloud-instance-role.tf` — add a policy
  granting `logs:FilterLogEvents`, `logs:GetLogEvents`, `logs:DescribeLogGroups` on
  `arn:aws:logs:*:*:log-group:/fjcloud/staging/ses/send-events*`, then `terraform apply`
  staging. The email SEND path is unaffected (`ses:SendEmail`/`ses:SendRawEmail` are
  granted); only the on-host evidence QUERY is IAM-blocked.
- **severity:** P1 · **regression:** no (newly surfaced behind the now-fixed Stripe blocker)

## Gap 2 (P1, dependent) — dunning_email_inbox

- **probe_id:** `dunning_email_inbox`
- **owner path:** `scripts/probe_dunning_email_inbox_e2e.sh`
- **rc:** 1 · **classification:** `rehearsal_failed` ("dunning owner script exited 1")
- **observed detail:** This probe wraps `scripts/validate_staging_dunning_delivery.sh`
  and only polls the inbox for the hosted-invoice URL after the validator returns
  `result=passed`. Because the validator is blocked by Gap 1, the inbox assertion never runs.
- **root cause:** Dependent on Gap 1 — the same instance-role `logs:FilterLogEvents` denial.
- **disposition:** No independent fix. Clears automatically once Gap 1's IAM read policy
  is added and applied.
- **severity:** P1 (dependent) · **regression:** no

## Verdict-ladder note

Prior terminal gap for these rows was `reset_stripe_list_invalid` (a Stripe-JSON product
bug), now fixed and merged. This bundle does **not** downgrade that history: it records
that the product bug is cleared and the remaining blocker moved downstream to an ops/IAM
prerequisite. No P0/P1 gap is downgraded; §1 remains `NOT-READY-on-section-1` (partial).
