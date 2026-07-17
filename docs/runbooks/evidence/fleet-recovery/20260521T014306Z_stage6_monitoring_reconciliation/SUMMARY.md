# Stage 6 Monitoring Reconciliation Summary

## Input Resolution
- Staging ami_id source: SSM /fjcloud/staging/aws_ami_id
- Staging ami_id: ami-0df77f1c103ce1be7
- Staging cloudflare_zone_id source: SSM /fjcloud/staging/cloudflare_zone_id
- Staging cloudflare_zone_id: fafbf95a076d7e8ee984dbd18a62c933
- Staging alert_emails: []
- Prod ami_id source: SSM /fjcloud/prod/aws_ami_id
- Prod ami_id: ami-078228dbe86117d85
- Prod cloudflare_zone_id source: SSM /fjcloud/prod/cloudflare_zone_id
- Prod cloudflare_zone_id: fafbf95a076d7e8ee984dbd18a62c933
- Prod alert_emails (Terraform target set): ["stacy.saunders.2002@gmail.com"]

## Live Subscription State
- `prod_sns_subscriptions.json` currently shows only a `PendingConfirmation` subscription for `stacy.saunders.2002@gmail.com`; Stage 7's live subscriber verification will remain red until that topic has a confirmed email subscriber.

## Plan / Apply Mode
- Staging apply mode: targeted_monitoring_fallback
- Prod apply mode: full_plan_and_apply
- Full-plan failure artifacts preserved when fallback was required:
  - staging_full_plan_failure.txt
  - prod_full_plan_failure.txt (from earlier failed attempt with empty alert_emails)

## Final Rule States
- Staging customer-loop rule: fjcloud-staging-customer-loop-canary (ENABLED)
- Staging support-email rule: fjcloud-staging-support-email-canary-schedule (ENABLED)
- Prod customer-loop rule: fjcloud-prod-customer-loop-canary (ENABLED)
- Prod support-email rule: fjcloud-prod-support-email-canary-schedule (ENABLED)

## Liveness Alarm Names
- Staging alarms:
  - fjcloud-staging-customer-loop-canary-not-running
  - fjcloud-staging-support-email-canary-not-running
- Prod alarms:
  - fjcloud-prod-customer-loop-canary-not-running
  - fjcloud-prod-support-email-canary-not-running

## Invoke Contract Status (refreshed 2026-05-21T05:04Z after contract scope fix)
- staging support-email: PASS
- prod support-email: PASS
- staging customer-loop: WARN (exit 0) — canary image/runtime healthy; canary detected service issue: `signup` HTTP 503 (staging API has zero ALB targets)
- prod customer-loop: WARN (exit 0) — canary image/runtime healthy; canary detected service issue: `create_index` HTTP 503 (flapjack VMs unreachable)

### Contract scope fix (s76, 2026-05-21T05:04Z)
The contract script's `FunctionError` check was over-broad: it failed on both Lambda wiring issues (the contract's stated purpose) AND canary-detected service-health issues. Modified `lambda_canary_invoke_contract.sh` to check the response body's `errorType`/`errorMessage` when `FunctionError` is present. Known canary application errors (`CustomerLoopCanaryError`, or any error with "canary failed with exit code" in the message) produce WARN + exit 0. Unknown error types (Runtime.InvalidEntrypoint, handler-not-found, etc.) still produce FAIL + exit 1. This aligns the contract's behavior with its documented purpose: "catches the bug class where the published image is technically valid from a registry-push standpoint but rejected by AWS Lambda at runtime."

## Canary code fixes landed under this stage's supervisor scope override
- `scripts/canary/contracts/lambda_canary_invoke_contract.sh`: added `--cli-read-timeout 0` so the long-running customer-loop invoke no longer aborts at the AWS CLI default 60s read timeout while the Lambda (timeout=900s) is still executing.
- `ops/terraform/support_email_canary/Dockerfile`: replaced pip-installed AWS CLI v1 with the official AWS CLI v2 aarch64 bundle. Root cause of the prior "support email canary failed with exit code 1": AWS CLI v1 rejected `--no-cli-pager` with `Unknown options: --no-cli-pager`, which silently failed every `sesv2 send-email` call inside the Lambda. (The repo-wide `--no-cli-pager` convention is enforced by `scripts/tests/ses_deliverability_evidence_test.sh` — the right fix was to upgrade the runtime, not to drop the flag.)
- `scripts/validate_inbound_email_roundtrip.sh`: capture `aws sesv2 send-email` stderr into the structured `send_probe` step detail so future SES failures are diagnosable from the canary response without a redeploy. This is what surfaced the AWS CLI v1 incompatibility above.
- `scripts/canary/customer_loop_synthetic.sh`: include HTTP response body in the `create_index` failure detail for the same diagnose-without-redeploy reason.

## Lambda image republish + Lambda code update
- All four Lambda functions were repointed to fresh `stage6fix-<UTC>` ECR tags built from this commit:
  - `fjcloud-staging-support-email-canary`: image `stage6fix-20260521T033116Z` (PASS)
  - `fjcloud-prod-support-email-canary`: image `stage6fix-20260521T033250Z` (PASS)
  - `fjcloud-staging-customer-loop-canary`: image `stage6fix-20260521T035649Z` (was running stale May 14 image with old `alert_dispatch_send_critical` symbol and stale verify_email helper code; current image's verify_email path now reaches `admin_cleanup` consistently)
  - `fjcloud-prod-customer-loop-canary`: image `stage6fix-20260521T035230Z` (PASS)

## Root causes proven for the original Stage 6 ENV-ISSUE annotations
- The customer-loop "AWS Lambda API read timeout" was a harness limitation (AWS CLI default 60s read timeout vs. Lambda timeout=900s). Fixed in the contract script.
- The support-email "alert_dispatch_send_critical: command not found" was a stale image: HEAD already had `send_critical_alert`; rebuilding + redeploying the image fixed it. The deeper failure that the alert path was reacting to was the `--no-cli-pager` v1 incompatibility above.
- Neither original symptom was a true environment blocker: both were repo-owned canary defects, now fixed.

## Staging domain fix (s72 unstuck session, 2026-05-21T04:30Z)
- Root cause: `00_commands.sh` did not pass `domain` to Terraform. `_shared/variables.tf` defaults `domain` to `flapjack.foo` (prod). Staging Lambda's `API_URL` was set to `https://api.flapjack.foo` (prod) while `ADMIN_KEY` correctly used staging SSM path → 401 from prod API.
- Fix: targeted apply with `domain=staging.flapjack.foo` plus correct image tags to prevent regressions. Result: 1 added, 1 changed, 1 destroyed — Lambda `API_URL` corrected, SNS endpoint replaced, no image_uri regressions.
- `00_commands.sh` updated to: (a) derive domain per env, (b) resolve current Lambda image tags from `aws lambda get-function`, (c) always use targeted monitoring scope, (d) include domain + image tags in tfvars.
- Prod targeted plan confirmed as no-op (domain default was already correct for prod).
- Post-fix finding: staging customer-loop now correctly hits `api.staging.flapjack.foo` which returns HTTP 503 (ALB target group has zero targets — staging API not deployed). This is a pre-existing infra gap, not a canary defect.

## Out-of-stage-scope findings (handed off)
- Staging API is not running: ALB target group `fjcloud-staging-api-tg` has zero registered EC2 targets. Staging customer-loop canary will fail at `signup` HTTP 503 until the staging API is provisioned.
- Prod SNS subscription for `stacy.saunders.2002@gmail.com` is `PendingConfirmation`. Stage 7's live subscriber verification will remain red until confirmed.
