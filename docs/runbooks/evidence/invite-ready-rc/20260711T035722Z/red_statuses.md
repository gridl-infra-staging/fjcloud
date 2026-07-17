# Stage 2 Paid-Beta RC Red Statuses

- rc_command_exit_code: 1
- ready: false
- verdict: fail
- status_counts: external_secret_missing=1, fail=4, pass=16, skipped=1
- red_status_taxonomy: fail, external_secret_missing
- live_evidence_gap_count: 0

## Red Steps

| Step | Status | Reason | Evidence |
| --- | --- | --- | --- |
| ses_readiness | fail | ses_readiness_failed | `ses_readiness.log` reports `aws sesv2 get-account failed for region 'us-east-1'`. |
| browser_preflight | external_secret_missing | browser_preflight_env_gap | `browser_preflight.log` reports local API not ready at `http://localhost:9096/health`; this coordinator step is not satisfied by the deployed browser lane evidence. |
| browser_auth_setup | fail | browser_auth_setup_failed | `browser_auth_setup.log` reports `E2E_ADMIN_KEY must be set to run admin browser-unmocked tests`. |
| ses_inbound | fail | ses_inbound_roundtrip_runtime_failed | `ses_inbound.log` reports AWS SES `SendEmail` failed with `UnrecognizedClientException` / invalid security token. |
| canary_customer_loop | fail | canary_customer_loop_failed | `canary_customer_loop.log` reports `verify_email` failed because S3 inbox lookup failed for `s3://flapjack-cloud-releases/e2e-emails/`. |

Stage 3 should interpret this as a red RC coordinator verdict, not a product-code patch request from Stage 2.
