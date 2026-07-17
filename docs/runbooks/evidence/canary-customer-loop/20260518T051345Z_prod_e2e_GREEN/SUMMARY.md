# Prod Customer-Loop Canary — Bundle of Record

This is the canonical (GREEN) bundle for `fjcloud-prod-customer-loop-canary`.
The active pointer at `docs/runbooks/evidence/canary-customer-loop/.current_bundle`
resolves to this directory.

## Bundle
- Name: `fjcloud-prod-customer-loop-canary`
- Path: `docs/runbooks/evidence/canary-customer-loop/20260518T051345Z_prod_e2e_GREEN`
- Captured at: 2026-05-18T05:13:45Z through 2026-05-18T05:44:38Z
- HEAD at capture: see `head_sha.txt`

## Pass criteria (from `scripts/canary/customer_loop_synthetic.sh`)
The contract is a real deployed-Lambda invoke against `fjcloud-prod-customer-loop-canary`
that exercises signup → email verification → index create/write/search/delete →
admin tenant cleanup. GREEN requires all of:
- `StatusCode=200` on the synchronous invoke
- `FunctionError` absent (i.e. no Lambda-side exception)
- log success marker `customer loop canary completed successfully` present
- no `step .* failed:` or `dispatch_failure_alert` markers in the log tail

This is the live behavior contract — not a smoke "did anything run" check.

## Decisive artifacts
- Contract invoke verdict: `contract_invoke_v_current.out`
  (`PASS: ... api_status=200, function_error=`, response `{"status":"ok"}`)
- Raw invoke metadata: `invoke_meta_v_current.json` (`StatusCode=200`, `FunctionError` absent)
- Payload verdict: `invoke_payload_v_current.json` (`{"status":"ok"}`)
- Lambda log tail: `invoke_log_tail_v_current.txt` and `cloudwatch_tail_15m_v_current.txt`
  (success marker present; no failure markers)
- Field-by-field assertions: `assertions_v_current.txt`

## Focused regressions GREEN at this HEAD
The following focused owner tests cover the red→green loop seams (verify_email
error surfacing, inbound-inbox IAM, bootstrap SSM hydration, and warm-invoke
double-resolution skip) and all pass on the HEAD captured in this bundle:

- `bash scripts/tests/customer_loop_verify_email_error_surface_test.sh` — 10 passed, 0 failed
- `bash scripts/tests/customer_loop_canary_inbox_iam_test.sh` — 7 passed, 0 failed
- `bash scripts/tests/customer_loop_bootstrap_ssm_hydration_test.sh` — 7 passed, 0 failed
- `bash scripts/tests/customer_loop_canary_skip_double_ssm_resolution_test.sh` — 3 passed, 0 failed

No standalone `create_index` regression script was added during the Stage 3
red→green loop; the create_index step is covered as part of the deployed-Lambda
contract invoke itself, whose log tail records `index created`, `index write
succeeded`, `index search succeeded`, and `index deleted` for this run.

## Verdict Table
| Check | Evidence | Verdict |
|---|---|---|
| Mirror CI staging at preflight | `preflight_staging_ci.json` (`conclusion` empty / in-progress, head `f32aa31eb67e7e8a37495e868a93cdc12159f3bd`) | RISK CONTEXT |
| Mirror CI prod at preflight | `preflight_prod_ci.json` (`conclusion` empty / in-progress, head `726fb4354ad0b7b1a694f4fe4f08d3ed85175e90`) | RISK CONTEXT |
| AWS identity captured | `preflight_aws_sts.json` | GREEN |
| Contract invoke | `contract_invoke_v_current.out` (`PASS`, `api_status=200`, `function_error=`) | GREEN |
| Raw invoke API status | `invoke_meta_v_current.json` (`StatusCode=200`) | GREEN |
| Raw invoke function error | `invoke_meta_v_current.json` (`FunctionError` absent) | GREEN |
| Payload verdict | `invoke_payload_v_current.json` (`{"status":"ok"}`) | GREEN |
| Log success marker | `invoke_log_tail_v_current.txt` contains `customer loop canary completed successfully` | GREEN |
| Log failure markers | `invoke_log_tail_v_current.txt` excludes `step .* failed:` and `dispatch_failure_alert` | GREEN |

## Overall
- **GREEN** for the prod customer-loop canary behavior contract.
- Mirror-CI status remains contextual risk only; canary verdict logic is based on live invoke behavior.

## Notes
- Deployment attempts to roll out `baf1dc9f` via local release build were blocked repeatedly by container compile SIGKILL at high-memory crates (`async-stripe`, then `aws-sdk-ec2`) and captured in `prod_release_build.log`, `prod_release_build_retry_jobs1.log`, and `prod_release_build_v2.log`.
- Host-level mitigation work captured in `colima_resize.log` and `colima_resize_v2.log` (4GiB -> 8GiB -> 12GiB).
- A third build attempt (`prod_release_build_v3.log`) advanced past prior OOM seams and was manually terminated for session checkpoint after extended compile runtime.

## Historical RED bundles
Prior bundle directories under `docs/runbooks/evidence/canary-customer-loop/`
that carry the `_prod_e2e_GREEN` suffix but were captured before this run
(`20260517T031727Z_…` through `20260518T045519Z_…`) are historical failure
captures, not the bundle of record. Their SUMMARYs (where present) record
overall verdict RED; the suffix is a Stage 3 naming convention rather than a
verdict. Raw CLI transcripts for those attempts live alongside their bundles —
do not promote them via `.current_bundle`.
