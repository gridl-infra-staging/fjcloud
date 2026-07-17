# Staging browser rerun evidence summary — 2026-05-21

branch=batman/may21_12pm_4_browser_lane_rerun
head_sha=eabe2b62198a164458040212e37fa31d8c71a5e9
stage1_verdict=PASS
stage0_ts=2026-05-21T22:23:24Z
prod_leak_audit_count=0
stage2_gate=FAIL
stage2_gate_reason=both attempts non-zero (missing @playwright/test dependency in web/playwright.config.ts import path)
stage3_gate=FAIL
stage3_gate_reason=attempt1 preflight failed (web/node_modules missing @playwright/test); attempt2 ran the spec and failed on /dashboard/billing missing 'Billing' heading visibility
stage4_gate=PASS
stage4_gate_reason=no_prod_fixture_leak_since_stage0_baseline
lb2_attempt1_exit=1
lb2_attempt2_exit=1
lb3_attempt1_exit=1
lb3_attempt2_exit=1

Run shape extends scripts/launch/run_browser_lane_against_staging.sh summary ownership, but this committed summary is Stage 5 owner-only at docs/runbooks/evidence/launch-verification/2026_05_21_stage1_preflight_20260521T222302Z_rerun/SUMMARY.md.

Scope notes:
- This rerun proves no prod fixture leak since the Stage 1 baseline.
- This rerun does not recover the failed staging-browser gates (Stage 2 and Stage 3 remain FAIL).
- This summary is for the rerun evidence bundle only; it is not a LAUNCH.md or PRIORITIES.md status rewrite.
- Historical bundle docs/runbooks/evidence/launch-verification/2026-05-21/ remains untouched.
