# Stage 3 verdicts — synthetic seeder dry-run + post-lane canary guard

## Provenance
- target_env: staging
- HEAD_SHA: 7e5db7f560177fd99358d7ba34810f5afa24a91e
- ORIGIN_MAIN_SHA: 7e5db7f560177fd99358d7ba34810f5afa24a91e
- Source: `provenance.env`

## Seeder dry-run (tenant A)
- Command: `bash scripts/launch/seed_synthetic_traffic.sh --tenant A --dry-run`
- Artifact: `seed_synthetic_dry_run_tenant_a.{stdout,stderr,exitcode}.log`
- SEED_DRY_RUN_RC: 0
- SEED_DRY_RUN_DISPOSITION: non_mutating_cli_evidence_only
- Evidence scope: proves CLI argument parsing, tenant definition loading, and the
  safety-gate enforcement (DRY_RUN defaults to "true"; preflight_env() only runs
  when DRY_RUN != "true"; run_tenant() returns early with `[dry-run] skipping
  mutations`). Does NOT prove live synthetic traffic mutation, usage_records
  attribution, or any staging state change. See
  `docs/launch/synthetic_traffic_seeder_plan.md` for the remaining live-proof seam.

## Post-lane canary guard (staging)
- Command: `bash scripts/probe_canary_live_state.sh staging --json`
- Artifact: `probe_canary_post_lane_staging.{json,stderr.log,exitcode}`
- POST_LANE_CANARY_RC: 1
- POST_LANE_CANARY_JSON_FOUND: 1
- POST_LANE_CANARY_JSON_VALID: 1
- POST_LANE_CANARY_READY: 0
- POST_LANE_CANARY_ALARMS_STATUS: pass
- POST_LANE_CANARY_ALL_CHECKS_PASS: 0
- POST_LANE_CANARY_FAILED_CHECKS: errors_24h

## Combined disposition
- Seeder dry-run exited 0: green.
- Post-lane canary not ready (errors_24h fails — 1.0 error in last 24h window).
- COMBINED_DISPOSITION: **blocked on canary**

This matches the Stage 2 baseline canary signal (errors_24h failed there as well),
so the lane did not regress the canary further during Stage 2/Stage 3 evidence
capture. The canary blocker remains a live-state condition external to this
stage's owned files; Stage 4 owns the final evidence bundle and ROADMAP.md update.
