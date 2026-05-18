# Stage 3 Prod Customer-Loop Canary Evidence — 20260518T045519Z (unstuck session)

## Overall verdict

RED on customer-loop end-to-end, GREEN on the warm-invoke bootstrap fix that was the prior session's stuck blocker.

This bundle proves the bootstrap-warm-invoke regression (SSM AccessDenied on already-resolved env vars) is fixed at image tag `2a94dacf868a`. Both cold and warm invokes now progress past signup + email verification with no SSM hydration errors. Customer-loop still fails RED at the next downstream seam: `step 'create_index' failed: create index returned HTTP 504`.

## What this session unblocked

- Prior session ended with image `2a94dacf868a` published to ECR but `_shared` Terraform never re-applied to flip the Lambda `image_uri` pointer. Lambda was still serving `dbf5318d6756`, which had the warm-invoke bootstrap bug.
- This session ran the missing targeted `_shared` apply (`-var canary_image={tag=\"2a94dacf868a\"}`), pointer is now `213880904778.dkr.ecr.us-east-1.amazonaws.com/fjcloud-prod-customer-loop-canary:2a94dacf868a`.
- Cold + warm synchronous invokes both show `ssm_hydration_error=0` and `email_verification_succeeded=1`; the bootstrap-rehydration code path is confirmed correct on a warm container.

## Field-level verdict table

| Field | Cold invoke | Warm invoke |
|---|---|---|
| StatusCode | 200 | 200 |
| FunctionError | Unhandled | Unhandled |
| email_verification_succeeded | 1 | 1 |
| ssm_hydration_error | 0 | 0 |
| step 'verify_email' failed | absent | absent |
| step 'create_index' failed (HTTP 504) | present | present |
| success marker `customer loop canary completed successfully` | absent | absent |
| Lambda image_uri | `...customer-loop-canary:2a94dacf868a` | `...customer-loop-canary:2a94dacf868a` |
| Mirror-CI staging at preflight | conclusion="" (in-progress) | RISK CONTEXT |
| Mirror-CI prod at preflight | conclusion="" (in-progress) | RISK CONTEXT |

## Root cause of the remaining RED seam (`create_index` 504)

API logs (`api_create_index_logs.txt`) show the canary's `POST /indexes` triggers `api::services::provisioning::auto_provision` which provisions a fresh `vm-shared-*.flapjack.foo` host, then `api::routes::indexes::shared_vm` repeatedly retries (`fresh shared VM not reachable yet; retrying index create`) — 20 attempts × 3s backoff. The new VM does not become reachable within the canary's HTTP timeout window so the API ultimately returns 504.

This is a real seam in the API VM-provisioning path, not a canary bug:
- Owner: `infra/api/src/routes/indexes/shared_vm.rs` (retry budget / pre-warmed VM pool / longer client timeout)
- Adjacent observable: API scheduler scrape logs show many `vm-shared-*` instances are unreachable (`http timeout` / `Invalid Application-ID or API key`), suggesting the shared-VM fleet has unhealthy nodes that auto-provision keeps trying to add to.
- Repo-owned-prerequisite per blocker_discipline.md — not external-unreachable.

## Evidence pointers in this bundle

- Preflight: `preflight_staging_ci.json`, `preflight_prod_ci.json`, `preflight_aws_sts.json`
- Terraform: `terraform_plan_unstick.txt`, `terraform_apply_unstick.txt`
- Lambda image confirmation: `customer_loop_image_uri.json`
- Invokes: `invoke_meta_cold.json` + `invoke_payload_cold.json` + `invoke_log_tail_cold.txt`; same for `_warm`
- Assertions: `assertions.txt`
- CloudWatch tail (10m): `cloudwatch_tail_10m.txt`
- API root-cause logs: `api_create_index_logs.txt`

## Next session's concrete actions

1. Investigate `infra/api/src/routes/indexes/shared_vm.rs::POST /indexes` provisioning path — either pre-warm a shared VM, lengthen the per-attempt timeout, or short-circuit to an already-healthy node before triggering auto_provision.
2. Add a failing API integration test in `infra/api/tests/` for the fresh-VM-not-reachable path (red), then minimal fix in `shared_vm.rs` (green).
3. Redeploy fjcloud-api-prod via existing owner path; rerun canary cold+warm to fresh `<timestamp>_prod_e2e_GREEN/` bundle and require both invokes show `customer loop canary completed successfully`.
