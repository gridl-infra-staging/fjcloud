# Stage 4 Production Soak Summary

- Verdict: **NOT-GREEN**
- Window (UTC): 2026-05-25T02:24:52Z to 2026-05-25T02:55:51Z (30m59s)
- Bundle: `docs/runbooks/evidence/release-cutover/20260525T022452Z_soak/`

## Conditions and Evidence

1. CloudWatch prod alarm probe (`aws cloudwatch describe-alarms ... fjcloud-prod-*`)
   - Result: **FAILED TO EVALUATE** for all samples due to `InvalidClientTokenId`.
   - Evidence: `cloudwatch_20260525T022452Z.txt`, `cloudwatch_20260525T022548Z.txt`, `cloudwatch_20260525T023549Z.txt`, `cloudwatch_20260525T024550Z.txt`, `cloudwatch_20260525T025551Z.txt`.

2. Customer-loop canary (`ENVIRONMENT=prod API_URL=https://api.flapjack.foo bash scripts/canary/customer_loop_synthetic.sh`)
   - Exit: non-zero.
   - Result: **FAILED** at email verification because AWS S3 inbox lookup failed with invalid token path.
   - Evidence: `canary_20260525T022452Z.stdout.txt`, `canary_20260525T022452Z.stderr.txt`.

3. `/status` public path (`curl https://cloud.flapjack.foo/status`)
   - Result: **PASS** for all samples (`All Systems Operational`; `Last updated` present with current date).
   - Evidence: `status_*.txt`, `status_*.stderr`.

4. `/signup` public path (`SIGNUP_URL=https://cloud.flapjack.foo/signup bash scripts/probe_deployed_signup_renders.sh`)
   - Result: **PASS** for all samples (`OK ... markers=all-present`).
   - Evidence: `signup_*.txt`.

## Gap Spec

Release remains non-ready because required prod-health owners could not be verified end-to-end:
- CloudWatch alarm check is blocked by invalid AWS auth token.
- Canary email verification step is blocked by invalid AWS auth token when reading S3 inbox objects.

Required follow-on:
- Restore valid prod-read AWS credentials in this execution environment, then rerun Stage 4 soak owners over a fresh 30-60 minute window.
