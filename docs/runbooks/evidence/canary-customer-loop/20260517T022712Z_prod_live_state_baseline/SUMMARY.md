# Prod Live State Baseline (Customer Loop Canary)

Bundle: `docs/runbooks/evidence/canary-customer-loop/20260517T022712Z_prod_live_state_baseline/`
Captured at: `2026-05-17T02:27:12Z`

## Owner Comparison Surface (re-read before AWS calls)
- Runtime env expectations owner: `scripts/canary/customer_loop_synthetic.sh::load_canary_env()`.
  - Expected runtime keys include: `ENVIRONMENT`, `API_URL`, `ADMIN_KEY`, `CANARY_AWS_REGION`, `CANARY_TEST_INBOX_DOMAIN`, `CANARY_TEST_INBOX_S3_URI`, `CANARY_INBOX_MAX_ATTEMPTS`, `CANARY_INBOX_SLEEP_SECONDS`, `CANARY_INDEX_REGION`, `STRIPE_API_BASE`, `STRIPE_SECRET_KEY(_EFFECTIVE)`, `CANARY_LIVE_MODE`.
- Lambda/ECR/schedule wiring owner: `ops/terraform/monitoring/main.tf`.
  - Function name local: `fjcloud-${var.env}-customer-loop-canary`.
  - Image URI local: `${aws_ecr_repository.customer_loop_canary.repository_url}:${var.canary_image.tag}`.
  - Schedule owner: `aws_cloudwatch_event_rule.customer_loop_canary` (`schedule_expression = var.canary_schedule.expression`).
  - Parameter-name wiring in env map: `ADMIN_KEY`, `STRIPE_SECRET_KEY`, `SLACK_WEBHOOK_URL`, `DISCORD_WEBHOOK_URL` plus inbox/API vars.
- Canonical exported identifiers owner: `ops/terraform/monitoring/outputs.tf`.
  - `customer_loop_canary_ecr_repository_url`, `customer_loop_canary_image_uri`, `customer_loop_canary_lambda_function_arn`, `customer_loop_canary_schedule_rule_name`.
- Publish contract owner: `ops/terraform/publish_customer_loop_canary_image.sh` + `ops/terraform/publish_canary_image_shared.sh::publish_canary_image()`.
  - Repository naming contract: `fjcloud-${env_name}-customer-loop-canary`.
  - Tag contract: `resolve_canary_image_tag` (explicit override or `git rev-parse --short=12 HEAD`).

## Drift Table (by owner seam)
| Seam | Expected owner contract | Live readback | Drift / Stage 2 input |
| --- | --- | --- | --- |
| Mirror CI status | `AGENTS.md` preflight expects latest `--workflow=CI` conclusion `success` on staging and prod mirrors before deploy-dependent lanes. | staging: `failure` (run `25973577841`), prod: `failure` (run `25973577376`). | P0 pipeline blocker present on both mirrors; Stage 2 must include CI repair or explicitly run in manual-deploy-risk mode. |
| AWS account identity | Stage must prove which account produced readbacks. | Account `213880904778`, ARN `arn:aws:iam::213880904778:user/stuart-cli`. | No drift; capture is attributable. |
| Lambda function/image/schedule | Function/rule names should match `fjcloud-prod-customer-loop-canary`; image should align with monitoring ECR + canary tag contract; schedule should be configured by Terraform. | Function name matches. Code image is `.../fjcloud-prod-customer-loop-canary:pending-publication` (resolved digest `sha256:4ea714...eb5f`). Rule name matches, expression `rate(15 minutes)`, state `DISABLED`. | Schedule is disabled; Stage 2 must decide if this is intentional or drift. |
| Env-var coverage vs `load_canary_env()` and main.tf env map | Runtime requires inbox/API/admin/stripe + canary defaults; monitoring env map wires parameter-name variables and inbox/API vars. | Live Lambda env variables present: `ENVIRONMENT=prod`, `CANARY_AWS_REGION=us-east-1`, `CANARY_LIVE_MODE=0`. Missing from live env: `CANARY_TEST_INBOX_DOMAIN`, `CANARY_TEST_INBOX_S3_URI`, `ADMIN_KEY`, `STRIPE_SECRET_KEY`, `SLACK_WEBHOOK_URL`, `DISCORD_WEBHOOK_URL`, and `API_URL`. | Critical env coverage drift; Stage 2 must reconcile missing keys before any canary publish/invoke lane. |
| ECR image snapshot vs publish contract | Repo name must be `fjcloud-prod-customer-loop-canary`; deployed image tag/digest should exist in that repo. | ECR repo contains digest `sha256:4ea714...eb5f` with tags `ad592f80c25d`, `latest`, `pending-publication` (pushed `2026-05-13T23:15:52-04:00`). Lambda resolved digest matches this digest. | Deployed artifact exists and matches ECR. Tag `pending-publication` is not a commit-derived tag from `resolve_canary_image_tag`; Stage 2 should confirm whether this temporary tag is intended for prod steady state. |

Stage 2 decision: reconcile required
Reason: mirror CI is red on both mirrors and live Lambda config is missing required env wiring with schedule disabled.
