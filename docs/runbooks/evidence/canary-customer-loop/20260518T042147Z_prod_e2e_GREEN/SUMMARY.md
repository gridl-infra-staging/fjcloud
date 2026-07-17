# Stage 3 Prod Customer-Loop Canary Evidence — 20260518T042147Z

## Overall verdict

GREEN on cold invoke at customer-loop image tag `dbf5318d6756` (full canary end-to-end success).

A subsequent warm contract invoke on the same image surfaced a warm-invoke bootstrap regression (bootstrap re-hydrated already-resolved env vars on container reuse). Root-cause fix landed in commit `2a94dacf868a`; image was published for that tag but Terraform was NOT applied with that tag before session end.

## Field-level verdict table

| Field | Value | Verdict |
|---|---|---|
| invoke API status (v5, cold) | `200` | GREEN |
| function error (v5, cold) | absent | GREEN |
| payload (v5) | `{"status":"ok"}` | GREEN |
| log success marker (v5) | `customer loop canary completed successfully` present | GREEN |
| log failure markers (v5) | absent | GREEN |
| Lambda image_uri at end | `213880904778.dkr.ecr.us-east-1.amazonaws.com/fjcloud-prod-customer-loop-canary:dbf5318d6756` | applied |
| Warm-invoke regression | bootstrap re-hydrates resolved env vars → SSM AccessDenied on `/uiaeMnmRzs...` | fixed in HEAD `2a94dacf868a`, image published, terraform apply not yet performed |
| Mirror-CI staging at preflight | failure (Sync Playwright fixture timeout and Stripe env) | RISK CONTEXT (manual deploy path used) |
| Mirror-CI prod at preflight | failure (Sync Playwright fixture timeout and Stripe env) | RISK CONTEXT (manual deploy path used) |

## Bugs fixed during this session (red→green per fix)

1. SSM double-resolution: `customer_loop_synthetic.sh::resolve_ssm_parameter_if_configured` re-resolved values starting with `/` after bootstrap already hydrated them. Fixed via `CANARY_SSM_HYDRATED` sentinel honored by canary load_canary_env path. Regression test `scripts/tests/customer_loop_canary_skip_double_ssm_resolution_test.sh`.
2. Inbox helper ARG_MAX: `scripts/lib/test_inbox_helpers.sh::test_inbox_find_matching_object_key` passed 100KB+ S3 list JSON as python argv → "Argument list too long" on Lambda → silently zero candidates → timeout. Fixed by writing list to a tempfile and passing the path. Regression test `scripts/tests/test_inbox_helpers_large_payload_test.sh`. Also added durable diagnostic on timeout exposing `attempts/last_list_count/candidates_scanned/fetch_failures` and surfaced helper output in canary timeout failure message.
3. Bootstrap warm-invoke rehydration: container caches env across invocations; bootstrap re-ran hydration treating resolved secret values as parameter paths. Fixed by short-circuiting hydration when `CANARY_SSM_HYDRATED=1` already set. Regression test extension in `customer_loop_bootstrap_ssm_hydration_test.sh`.

## Evidence pointers (under this bundle)

- Preflight: `preflight_staging_ci.json`, `preflight_prod_ci.json`, `preflight_aws_sts.json`
- Publish/apply (5 iterations as fixes landed): `publish_customer_loop_*.txt`, `terraform_plan_*.txt`, `terraform_apply_*.txt`
- Invokes: `invoke_meta_v{2..5}.json`, `invoke_payload_v{2..5}.json`, `invoke_log_tail_v{2..5}.txt`
- GREEN cold invoke proof: `invoke_meta_v5.json` (no FunctionError, payload `{"status":"ok"}`)
- Diagnostic showing original inbox-helper root cause: `invoke_log_tail_v4.txt` (Argument list too long)
- API/SES probes: `probe_register.txt`, `probe_resend.txt`, `api_env_check.json`, `ssm_ses_configuration_set.txt`, `ses_send_statistics.json`, `iam_role_policies.json`, `iam_policy_*.json`
- CloudWatch tail at session end: `cloudwatch_tail_5m_final.txt`

## What's NOT yet applied to prod at session end

- HEAD `2a94dacf868a` (bootstrap warm-invoke hydration fix) image was published to ECR but `_shared` Terraform was NOT re-applied to flip Lambda image_uri to that tag. Prod Lambda still on `dbf5318d6756` which has the warm-invoke regression. Next session must:
  - `cd ops/terraform/_shared && terraform plan/apply -target=module.monitoring.aws_lambda_function.customer_loop_canary -var=env=prod -var=cloudflare_zone_id=fafbf95a076d7e8ee984dbd18a62c933 -var=ami_id=ami-0c02fb55956c7d316 -var='canary_image={tag="2a94dacf868a"}' -var=support_email_canary_image_tag=2a94dacf868a`
  - Re-invoke twice (cold + warm) and confirm both GREEN.
