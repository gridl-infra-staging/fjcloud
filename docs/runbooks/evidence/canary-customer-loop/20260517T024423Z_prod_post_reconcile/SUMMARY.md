# Stage 2 — Prod Customer-Loop Canary Post-Reconcile

Bundle: `docs/runbooks/evidence/canary-customer-loop/20260517T024423Z_prod_post_reconcile/`
Captured at: `2026-05-17T02:44:23Z` (apply completion: `2026-05-17T02:46:16Z`)
Stage 1 baseline: `docs/runbooks/evidence/canary-customer-loop/20260517T022712Z_prod_live_state_baseline/`

## Verdict: reconcile applied

All Stage 1 drift rows are now GREEN against owner intent. No drift rows
remain. Schedule is ENABLED for the first time on prod.

## Drift Resolution Table (field-by-field, Stage 1 → post-reconcile)

| Field | Owner contract source | Stage 1 (baseline) | Post-reconcile (now) | Status |
| --- | --- | --- | --- | --- |
| Lambda `Architectures` | `ops/terraform/monitoring/main.tf::aws_lambda_function.customer_loop_canary` (newly set `architectures = ["arm64"]`) + publish script builds `linux/arm64` | `["x86_64"]` (image was arm64 — mismatch would fail at invoke) | `["arm64"]` | GREEN |
| Lambda `image_uri` tag | `local.customer_loop_canary_image_uri` derives from `var.canary_image.tag`; publish-script contract emits commit-tagged image via `resolve_canary_image_tag` | `:pending-publication` (digest `sha256:4ea714…eb5f`) | `:ad592f80c25d` (same digest `sha256:4ea714…eb5f` — image-content identical; tag now matches publish contract) | GREEN |
| Lambda env `ENVIRONMENT` | `monitoring/main.tf` env map | `prod` | `prod` | GREEN (unchanged) |
| Lambda env `CANARY_AWS_REGION` | `monitoring/main.tf` env map | `us-east-1` | `us-east-1` | GREEN (unchanged) |
| Lambda env `CANARY_LIVE_MODE` | `monitoring/main.tf` env map (driven by `var.canary_live_mode`) | `0` | `0` | GREEN (unchanged) |
| Lambda env `API_URL` | `monitoring/main.tf` env map (`https://api.${var.domain}`) | MISSING | `https://api.flapjack.foo` | GREEN (added) |
| Lambda env `CANARY_TEST_INBOX_DOMAIN` | `monitoring/main.tf` env map | MISSING | `test.flapjack.foo` | GREEN (added) |
| Lambda env `CANARY_TEST_INBOX_S3_URI` | `monitoring/main.tf` env map | MISSING | `s3://flapjack-cloud-releases/e2e-emails/` | GREEN (added) |
| Lambda env `ADMIN_KEY` | `monitoring/main.tf` env map (parameter name) | MISSING | `/fjcloud/prod/admin_key` | GREEN (added) |
| Lambda env `STRIPE_SECRET_KEY` | `monitoring/main.tf` env map (parameter name) | MISSING | `/fjcloud/prod/stripe_secret_key` | GREEN (added) |
| Lambda env `SLACK_WEBHOOK_URL` | `monitoring/main.tf` env map (parameter name) | MISSING | `/fjcloud/prod/slack_webhook_url` | GREEN (added) |
| Lambda env `DISCORD_WEBHOOK_URL` | `monitoring/main.tf` env map (parameter name) | MISSING | `/fjcloud/prod/discord_webhook_url` | GREEN (added) |
| EventBridge `State` | `monitoring/main.tf::aws_cloudwatch_event_rule.customer_loop_canary.is_enabled = var.canary_schedule.enabled` | `DISABLED` | `ENABLED` | GREEN (apply set `enabled=true`) |
| EventBridge `ScheduleExpression` | `var.canary_schedule.expression` | `rate(15 minutes)` | `rate(15 minutes)` | GREEN (unchanged) |
| Function name | `local.customer_loop_canary_function_name` | `fjcloud-prod-customer-loop-canary` | `fjcloud-prod-customer-loop-canary` | GREEN (unchanged) |
| Rule name | `local.customer_loop_canary_schedule_rule_name` | `fjcloud-prod-customer-loop-canary` | `fjcloud-prod-customer-loop-canary` | GREEN (unchanged) |
| ECR digest | `aws_ecr_repository.customer_loop_canary` + publish contract | `sha256:4ea714…eb5f` (3 tags) | `sha256:4ea714…eb5f` (3 tags, unchanged) | GREEN (image content unchanged; only Lambda tag pointer rewritten) |
| AWS account identity | Stage attribution | `213880904778` / `arn:aws:iam::213880904778:user/stuart-cli` | `213880904778` / `arn:aws:iam::213880904778:user/stuart-cli` | GREEN (capture attributable) |

### `load_canary_env()` per-key coverage (post-reconcile)

Runtime expectations from `scripts/canary/customer_loop_synthetic.sh::load_canary_env()`:

| Key | Live Lambda env | Status |
| --- | --- | --- |
| `ENVIRONMENT` | `prod` | PRESENT |
| `API_URL` | `https://api.flapjack.foo` | PRESENT |
| `ADMIN_KEY` | `/fjcloud/prod/admin_key` (parameter name; resolved from SSM by canary at invoke) | PRESENT |
| `CANARY_AWS_REGION` | `us-east-1` | PRESENT |
| `CANARY_TEST_INBOX_DOMAIN` | `test.flapjack.foo` | PRESENT |
| `CANARY_TEST_INBOX_S3_URI` | `s3://flapjack-cloud-releases/e2e-emails/` | PRESENT |
| `CANARY_INBOX_MAX_ATTEMPTS` | (defaulted in `load_canary_env()` — not a Lambda-env requirement) | DEFAULTED-BY-OWNER |
| `CANARY_INBOX_SLEEP_SECONDS` | (defaulted in `load_canary_env()`) | DEFAULTED-BY-OWNER |
| `CANARY_INDEX_REGION` | (defaulted in `load_canary_env()` to `CANARY_AWS_REGION`) | DEFAULTED-BY-OWNER |
| `STRIPE_API_BASE` | (defaulted in `load_canary_env()` to `https://api.stripe.com`) | DEFAULTED-BY-OWNER |
| `STRIPE_SECRET_KEY` | `/fjcloud/prod/stripe_secret_key` (parameter name) | PRESENT |
| `CANARY_LIVE_MODE` | `0` (live-mode gated to test-mode Stripe) | PRESENT |
| `SLACK_WEBHOOK_URL` | `/fjcloud/prod/slack_webhook_url` (parameter name) | PRESENT |
| `DISCORD_WEBHOOK_URL` | `/fjcloud/prod/discord_webhook_url` (parameter name) | PRESENT |

All keys that `monitoring/main.tf` is responsible for wiring are PRESENT.
Defaults handled by `load_canary_env()` itself are not Lambda-env
requirements and are intentionally absent from the env map.

## Owner-Path Commands Executed (single source of truth)

All operations went through the canonical owners only. No ad-hoc
`aws lambda update-function-configuration` / `aws events enable-rule` /
console edits.

1. Re-init prod backend (read-only):
   ```bash
   cd ops/terraform/_shared
   terraform init -backend-config="bucket=fjcloud-tfstate-prod" \
                  -backend-config="key=terraform.tfstate" \
                  -backend-config="region=us-east-1" \
                  -backend-config="dynamodb_table=fjcloud-tflock" \
                  -reconfigure
   ```
2. Targeted plan on the two reconcile resources (captured in
   `10_terraform_plan_targeted.txt`):
   ```bash
   terraform plan -input=false \
     -var="env=prod" \
     -var="ami_id=<ssm:/fjcloud/prod/aws_ami_id>" \
     -var="domain=flapjack.foo" \
     -var="cloudflare_zone_id=$CLOUDFLARE_ZONE_ID" \
     -var='alert_emails=["stuart@gridl.cloud"]' \
     -var='canary_image={tag="ad592f80c25d"}' \
     -var='canary_schedule={expression="rate(15 minutes)",enabled=true}' \
     -target=module.monitoring.aws_lambda_function.customer_loop_canary \
     -target=module.monitoring.aws_cloudwatch_event_rule.customer_loop_canary \
     -out=/tmp/stage2_canary.tfplan
   ```
   Reported `Plan: 0 to add, 2 to change, 0 to destroy.`
3. Targeted apply (captured in `11_terraform_apply_targeted.txt`):
   ```bash
   terraform apply -auto-approve -input=false /tmp/stage2_canary.tfplan
   ```
   Reported `Apply complete! Resources: 0 added, 2 changed, 0 destroyed.`
4. Live AWS readback (captured in `01_..04_*.json`):
   ```bash
   aws lambda get-function --function-name fjcloud-prod-customer-loop-canary --region us-east-1
   aws lambda get-function-configuration --function-name fjcloud-prod-customer-loop-canary --region us-east-1
   aws events describe-rule --name fjcloud-prod-customer-loop-canary --region us-east-1
   aws ecr describe-images --repository-name fjcloud-prod-customer-loop-canary --region us-east-1
   ```

### Scope guard

- No edits outside the canary deploy owners.
  - Code change: one block in `ops/terraform/monitoring/main.tf`
    (`aws_lambda_function.customer_loop_canary` gained
    `architectures = ["arm64"]`).
  - No new wrappers, side scripts, parameter sources, or env paths added.
- No re-publication of the image was needed — the existing digest
  `sha256:4ea714…eb5f` already had the commit-derived tag `ad592f80c25d`
  in ECR; the apply just retagged the Lambda pointer onto it.
  `publish_customer_loop_canary_image.sh` was therefore not invoked
  this stage; its contract was only re-confirmed (see "Owner
  contracts re-confirmed" below).
- `alert_emails` precondition (`var.env != "prod" || length > 0`) was
  satisfied with a non-empty placeholder for plan/validation purposes
  only; the targeted apply did not touch `aws_sns_topic_subscription.email`
  because it was not a target dependency. Post-apply SNS list still
  reports zero subscriptions (Stage 1 baseline) — out of scope for
  this stage's canary lane.

## Owner contracts re-confirmed (no new ownership added)

- `ops/terraform/monitoring/main.tf` — owns env map, ECR repo, Lambda,
  EventBridge rule + target + permission for the customer-loop canary.
  This stage added one argument (`architectures`) to the existing
  Lambda resource; all other contracts unchanged.
- `ops/terraform/monitoring/outputs.tf` — owns the four canonical
  exported identifiers; values post-apply are surfaced under
  "Changes to Outputs" in `10_terraform_plan_targeted.txt` and again
  in `11_terraform_apply_targeted.txt`.
- `ops/terraform/_shared/{main.tf,variables.tf}` — root composes
  `module.monitoring` and forwards `canary_image` / `canary_schedule`.
  No edits required.
- `ops/terraform/publish_customer_loop_canary_image.sh` +
  `ops/terraform/publish_canary_image_shared.sh::publish_canary_image()`
  — image-publication ownership. Re-read and re-confirmed: tag contract
  via `resolve_canary_image_tag`, repo naming
  `fjcloud-${env_name}-customer-loop-canary`, buildx `--platform linux/arm64`.
  Not invoked this stage; the in-tree commit tag `ad592f80c25d` already
  pointed at the running prod digest, so re-publication would have been
  a no-op rebuild.

## Mirror-CI Risk Decision

Stage 1 captured both mirrors as `failure` on latest `--workflow=CI`
runs (staging run `25973577841`, prod run `25973577376`). This stage
did NOT repair mirror CI. The reconcile path went through direct
`terraform apply` against the prod TF state, bypassing the
binary-deploy CI gate (the canary Lambda is image-based and does not
depend on `deploy-staging` / `deploy-prod` jobs). Recorded
manual-deploy-risk acknowledgment:

- Lambda image / env / schedule are now in sync with owner intent at
  this commit, captured via the direct prod `terraform apply` above.
- Mirror CI red on both sides means the next code push to dev that
  syncs to those mirrors will still dead-end at the failing CI jobs.
- Operator decision for repair (rust-lint / secret-scan / playwright
  on the mirrors) is out of scope for this Stage-2 canary reconcile
  lane and should be carved off as its own lane.

## Validation Gates Run (must all be exit 0)

| Gate | File | Exit | Evidence |
| --- | --- | --- | --- |
| Static: publish scripts use buildx with Lambda-compatible flags | `ops/terraform/tests_publish_scripts_buildx_static.sh` | 0 | `20_tests_publish_scripts_buildx_static.txt` |
| Static: stage 7 preflight contracts | `ops/terraform/tests_stage7_preflight_static.sh` | 0 | `21_tests_stage7_preflight_static.txt` |
| local-ci `--gate publish-scripts-buildx` | `scripts/local-ci.sh::gate_publish_scripts_buildx` | 0 | `22_local_ci_publish_scripts_buildx.txt` |
| local-ci `--gate validate-bootstrap-parser` | `scripts/local-ci.sh::gate_validate_bootstrap_parser` | 0 | `23_local_ci_validate_bootstrap_parser.txt` |

## Stage 3 Handoff Pointer

- Function ARN: `arn:aws:lambda:us-east-1:213880904778:function:fjcloud-prod-customer-loop-canary`
- Schedule rule: `fjcloud-prod-customer-loop-canary` (`ENABLED`, `rate(15 minutes)`)
- Image URI: `213880904778.dkr.ecr.us-east-1.amazonaws.com/fjcloud-prod-customer-loop-canary:ad592f80c25d`
  (digest `sha256:4ea714a45fcc188a45db22fc21ebdb059bbb6192c3ceefc71cfa45405545eb5f`)
- Architecture: `arm64` (matches image)
- `CANARY_LIVE_MODE=0` (Stripe test-mode). Prod live-mode invoke would
  require flipping `var.canary_live_mode=true` in a future lane.
- Stage 3 (prod invoke evidence) can begin from here. Suggested first
  invoke probe is the existing
  `scripts/canary/contracts/lambda_canary_invoke_contract.sh prod customer-loop`
  followed by an EventBridge-triggered run captured via CloudWatch logs.
