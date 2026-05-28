# A1 In-VPC Probe Rerun — Stage 1 Pre-flight Evidence

**Generated:** 2026-05-28T02:23:38Z
**Branch:** batman/may26_5pm_1_a1_in_vpc_probe_rerun
**Billing month:** 2026-05
**Stage start epoch:** 1779935018

## Lane Necessity

- `docs/launch_verification_matrix.md` §1 status: **pending** (verified at execution time)
- `stages.md` Stage 1: read-only pre-flight gate (no mutation)
- Known gap: in-VPC clickthrough/dunning/suppression probe rerun required

## Script Owner Verification

All 8 required script owners present and executable:

| Script | Status |
|---|---|
| `scripts/probe_live_state.sh` | present (35023 bytes) |
| `scripts/launch/hydrate_seeder_env_from_ssm.sh` | present (7620 bytes) |
| `scripts/launch/ssm_exec_staging.sh` | present (3527 bytes) |
| `scripts/probe_verify_email_clickthrough_e2e.sh` | present (4410 bytes) |
| `scripts/probe_password_reset_clickthrough_e2e.sh` | present (6077 bytes) |
| `scripts/probe_dunning_email_inbox_e2e.sh` | present (4734 bytes) |
| `scripts/probe_ses_bounce_complaint_e2e.sh` | present (15200 bytes) |
| `scripts/validate_staging_dunning_delivery.sh` | present (12127 bytes) |

## CI Health

- Staging CI: **success** (SHA d05072c9, 2026-05-28T01:36:28Z)
- Prod CI: in-progress (SHA b271feba, 2026-05-28T02:02:52Z) — not blocking (staging-only lane)

## Credential Probes

### AWS STS
- Identity: `arn:aws:iam::213880904778:user/stuart-cli`
- Result: **PASS**

### S3 put/delete (fjcloud-releases-staging)
- PUT `preflight-test-1779935038.txt`: **PASS**
- DELETE `preflight-test-1779935038.txt`: **PASS**

### Cloudflare account read-only
- Auth: X-Auth-Email + X-Auth-Key (global key)
- Account: Stuart.clifford@gmail.com's Account
- `enforce_twofactor`: false
- Result: **PASS**

## Live State Probe

- Timestamp: `docs/live-state/20260528T022432Z/SUMMARY.md`
- All checks: **OK** (stripe, aws_sns, aws_ssm, cloudflare_dns, cloudflare_pages, api_health, staging_rds, privacy_com)
- No A1-blocking anomalies

## SSM Environment Hydration

### From SSM (`hydrate_seeder_env_from_ssm.sh staging`)
- `ADMIN_KEY`: present
- `DATABASE_URL`: present
- `API_URL`: present
- `STRIPE_SECRET_KEY`: present, shape `sk_test_*`
- `SES_FROM_ADDRESS`: present (`noreply@flapjack.foo`)
- `STRIPE_WEBHOOK_SECRET`: present

### From SSM (direct fetch)
- `SES_REGION`: present in SSM at `/fjcloud/staging/ses_region` = `us-east-1`
  - NOTE: not exported by `hydrate_seeder_env_from_ssm.sh`; Stage 2 must set explicitly via `export SES_REGION=us-east-1`

### Not in SSM (operator-provided)
- `FJCLOUD_TEST_TENANT_IDS`: NOT PRESENT in `.env.secret` or SSM
  - Required only by `validate_staging_dunning_delivery.sh` (billing mutation allowlist)
  - Per source lane: operator must add to `.env.secret` before Stage 2 dunning probe
  - The other 4 probes (email clickthrough, password reset, dunning inbox, bounce/complaint) do NOT require this var

## SSM Transport Smoke Probe

- Command: `echo SSM_SMOKE_OK; pwd; whoami; date -u`
- Instance: `fjcloud-api-staging` (resolved via tag)
- Output: `SSM_SMOKE_OK`, `/usr/bin`, `root`, `Thu May 28 02:28:10 UTC 2026`
- Result: **PASS**

## Wall-Clock Gate

- Stage start: 1779935018 (2026-05-28T02:23:38Z)
- 6-hour cap: 21600 seconds
- Deadline: 1779956618 (2026-05-28T08:23:38Z)
- Status: **within budget**

## Pre-flight Verdict

**PASS** — all prerequisites validated. Stage 2 is executable with the following notes:
1. `SES_REGION` must be set explicitly (`export SES_REGION=us-east-1`) since the hydrator does not export it
2. `FJCLOUD_TEST_TENANT_IDS` is required only for the dunning delivery probe; operator must populate in `.env.secret` before that specific probe runs
