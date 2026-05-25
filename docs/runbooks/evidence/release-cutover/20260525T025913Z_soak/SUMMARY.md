# Stage 4 Production Soak Summary

- Verdict: **NOT-GREEN**
- Window (UTC): 2026-05-25T02:59:13Z to 2026-05-25T03:19:57Z
- Bundle: `docs/runbooks/evidence/release-cutover/20260525T025913Z_soak/`

## Conditions and Evidence

1. CloudWatch prod alarm probe (`aws cloudwatch describe-alarms ... fjcloud-prod-*`)
   - 2026-05-25T02:59:13Z: empty output (no ALARM rows).
   - 2026-05-25T02:59:55Z: empty output (no ALARM rows).
   - 2026-05-25T03:09:56Z: empty output (no ALARM rows).
   - 2026-05-25T03:19:57Z: `fjcloud-prod-customer-loop-canary-lambda-errors` in ALARM.
   - Per stage rule, this ALARM is an immediate NOT-GREEN stop.

2. Customer-loop canary (`ENVIRONMENT=prod API_URL=https://api.flapjack.foo bash scripts/canary/customer_loop_synthetic.sh`)
   - Exit: non-zero.
   - Failure point: `create_index` returned HTTP 503 (`{"error":"backend temporarily unavailable"}`).
   - Success marker `customer loop canary completed successfully` was not emitted.

3. `/status` public path (`curl https://cloud.flapjack.foo/status`)
   - PASS on each sample in this window (`All Systems Operational`; `Last updated` present and current-date).

4. `/signup` public path (`SIGNUP_URL=https://cloud.flapjack.foo/signup bash scripts/probe_deployed_signup_renders.sh`)
   - PASS on each sample in this window (`OK ... markers=all-present`).

## Gap Spec

Release is NOT-GREEN and not announce-ready due to production health-owner failures:
- CloudWatch alarm state entered ALARM for `fjcloud-prod-customer-loop-canary-lambda-errors`.
- Prod customer-loop canary failed (`create_index` HTTP 503) and did not emit success marker.

Follow-on work should focus on restoring canary/index backend health and clearing the CloudWatch ALARM, then rerunning Stage 4 soak owners in a fresh evidence bundle.
