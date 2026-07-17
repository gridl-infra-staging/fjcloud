# Stage 4 Polished Beta Staging Verify Summary

- evidence_dir: docs/runbooks/evidence/polished-beta-staging-verify/20260706T202049Z
- head_sha: cfc14f0114cd9f1a6fcf3fe612d7488c3840e777
- readiness_classification: not_ready_real_bugs
- ready: false
- source_of_truth: classification.json, rerun_verdicts.json, and parity_result.env

## Deployment Parity

- parity_ok: 0
- control_plane_ready: 0
- deploy_status_attempts_used: 40
- remaining_attempts: 0
- final_staging_gap: 10
- final_staging_dev_sha: 44435bed4729f4040e1285cf3122187e4b3e77ea
- final_staging_mirror_sha: 4fd2559c170fede7d64ad3ee16d6a7506d13d468
- final_prod_gap: 0
- final_prod_dev_sha: cfc14f0114cd9f1a6fcf3fe612d7488c3840e777
- final_prod_mirror_sha: 0bd64b2009ae340a0ef312ccbc8f63e6f610ad6c
- pages_ready: false
- pages_skipped_reason: parity timeout — staging did not converge within 40 polls (20-min cap)
- failing_env: staging

Debbie mirror sync completed successfully for staging and prod on the first
attempt. Control-plane parity did not converge on staging: the live staging API
`/version` endpoint remained at `44435bed4729f4040e1285cf3122187e4b3e77ea`, 10
commits behind `cfc14f0114cd9f1a6fcf3fe612d7488c3840e777`, for the full 40-poll
budget. Prod control-plane parity did converge (`FINAL_PROD_GAP=0`). Pages
parity was skipped because control-plane parity never reached `PARITY_OK=1`.

Browser lane verification proceeded against staging despite the parity gap
because the Wave 3 stage-2 lane driver executes on Stage 1's evidence directory
independent of the `PARITY_OK` verdict; the 10-commit staging gap is captured
here as context for interpreting lane failures rather than as a suppression
gate.

## Browser Lane Verification

- lane_verification: run
- stage_02_first_pass: run
- stage_03_rerun_classification: run
- first_pass_count: 0
- rerun_flake_count: 0
- rerun_real_bug_count: 7
- final_pass_including_flakes: 0
- lane_count: 7

Stage 2 first-pass Playwright execution produced 0 passes and 7 failures across
lanes A–G against the deployed staging environment. Stage 3 re-ran each failed
lane twice (14 rerun attempts total); every rerun attempt for every lane
remained `failed`, so all 7 lanes classify as `real_bug` and none classify as
`flake`. The final pass count including flakes is 0, which is below the
`final_pass_ge_4` threshold; combined with `real_bug_count = 7`, the readiness
precondition evaluates to `ready: false`.

Per-lane classification:

- Lane A — Merchandising hub renders rules and no legacy search canvas: real_bug
- Lane B — Rules tab slug lands on merchandising hub: real_bug
- Lane C — Unified Search renders image-backed document cards: real_bug
- Lane D — Display Preferences exposes document card controls: real_bug
- Lane E — Query metrics report hit count and processing time: real_bug
- Lane F — Numbered pagination reaches first second and last pages: real_bug
- Lane G — Merch mode pin controls are deferred to follow-up contract: real_bug

## Published Follow-Ups

- published_stubs:
  - chats/icg/stubs/jun11_pm_9_lane_a_merchandising_hub_renders_rules_real_defect.md
  - chats/icg/stubs/jun11_pm_9_lane_b_rules_tab_slug_lands_on_merch_hub_real_defect.md
  - chats/icg/stubs/jun11_pm_9_lane_c_unified_search_renders_document_cards_real_defect.md
  - chats/icg/stubs/jun11_pm_9_lane_d_display_preferences_document_card_controls_real_defect.md
  - chats/icg/stubs/jun11_pm_9_lane_e_query_metrics_report_hit_count_real_defect.md
  - chats/icg/stubs/jun11_pm_9_lane_f_numbered_pagination_reaches_pages_real_defect.md
  - chats/icg/stubs/jun11_pm_9_lane_g_merch_mode_pin_controls_deferred_real_defect.md

## Artifact Index

- docs/runbooks/evidence/polished-beta-staging-verify/20260706T202049Z/head_sha.txt
- docs/runbooks/evidence/polished-beta-staging-verify/20260706T202049Z/debbie_sync.log
- docs/runbooks/evidence/polished-beta-staging-verify/20260706T202049Z/deploy_status_poll.jsonl
- docs/runbooks/evidence/polished-beta-staging-verify/20260706T202049Z/parity_poll.log
- docs/runbooks/evidence/polished-beta-staging-verify/20260706T202049Z/pages_parity_output.env
- docs/runbooks/evidence/polished-beta-staging-verify/20260706T202049Z/pages_parity.log
- docs/runbooks/evidence/polished-beta-staging-verify/20260706T202049Z/parity_result.env
- docs/runbooks/evidence/polished-beta-staging-verify/20260706T202049Z/parity_verdict.md
- docs/runbooks/evidence/polished-beta-staging-verify/20260706T202049Z/playwright-results.json
- docs/runbooks/evidence/polished-beta-staging-verify/20260706T202049Z/playwright-html
- docs/runbooks/evidence/polished-beta-staging-verify/20260706T202049Z/lane_verdicts_first_pass.json
- docs/runbooks/evidence/polished-beta-staging-verify/20260706T202049Z/rerun_A_1.json
- docs/runbooks/evidence/polished-beta-staging-verify/20260706T202049Z/rerun_A_2.json
- docs/runbooks/evidence/polished-beta-staging-verify/20260706T202049Z/rerun_B_1.json
- docs/runbooks/evidence/polished-beta-staging-verify/20260706T202049Z/rerun_B_2.json
- docs/runbooks/evidence/polished-beta-staging-verify/20260706T202049Z/rerun_C_1.json
- docs/runbooks/evidence/polished-beta-staging-verify/20260706T202049Z/rerun_C_2.json
- docs/runbooks/evidence/polished-beta-staging-verify/20260706T202049Z/rerun_D_1.json
- docs/runbooks/evidence/polished-beta-staging-verify/20260706T202049Z/rerun_D_2.json
- docs/runbooks/evidence/polished-beta-staging-verify/20260706T202049Z/rerun_E_1.json
- docs/runbooks/evidence/polished-beta-staging-verify/20260706T202049Z/rerun_E_2.json
- docs/runbooks/evidence/polished-beta-staging-verify/20260706T202049Z/rerun_F_1.json
- docs/runbooks/evidence/polished-beta-staging-verify/20260706T202049Z/rerun_F_2.json
- docs/runbooks/evidence/polished-beta-staging-verify/20260706T202049Z/rerun_G_1.json
- docs/runbooks/evidence/polished-beta-staging-verify/20260706T202049Z/rerun_G_2.json
- docs/runbooks/evidence/polished-beta-staging-verify/20260706T202049Z/rerun_verdicts.json
- docs/runbooks/evidence/polished-beta-staging-verify/20260706T202049Z/authored_stubs.json
- docs/runbooks/evidence/polished-beta-staging-verify/20260706T202049Z/classification.json
