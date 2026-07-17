# Stage 3 Prod Canary Summary

- Bundle: 20260518T040918Z_prod_e2e_GREEN
- Overall verdict: RED

| Check | Evidence | Verdict |
|---|---|---|
| Mirror CI staging at run time | `preflight_staging_ci.json` conclusion is empty (in progress) | RISK |
| Mirror CI prod at run time | `preflight_prod_ci.json` conclusion is empty (in progress) | RISK |
| Support-email image pointer updated | `support_email_image_uri_after_tagged_apply_v2.json` points to `:05b6e65d459c` | GREEN |
| Customer-loop image pointer updated | `customer_loop_image_uri_after_tagged_apply_v2.json` points to `:05b6e65d459c` | GREEN |
| Support-email invoke API status | `support_email_invoke_meta_after_tagged_apply_v2.json` StatusCode 200 with `FunctionError=Unhandled` | RED |
| Support-email runtime seam | `support_email_invoke_log_tail_after_tagged_apply_v2.txt` shows SES send failure + Slack 400 alert path | RED |
| Customer-loop invoke API status | `invoke_meta_after_tagged_apply_v2.json` StatusCode 200 with `FunctionError=Unhandled` | RED |
| Customer-loop success marker | `assertions_after_tagged_apply_v2.txt` has `success_marker=absent` | RED |
| Customer-loop failure marker | `assertions_after_tagged_apply_v2.txt` has `failure_marker=present` | RED |
| Customer-loop runtime seam | `invoke_log_tail_after_tagged_apply_v2.txt` shows `stripe_request.sh: Permission denied` | RED |

## Result
Stage 3 remains open. The current prod customer-loop canary is not GREEN after redeploy/invoke.
