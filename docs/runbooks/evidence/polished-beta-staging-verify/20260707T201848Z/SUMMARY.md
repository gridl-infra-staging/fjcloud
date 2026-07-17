# Stage 4 Polished Beta Staging Verify Summary

- evidence_dir: docs/runbooks/evidence/polished-beta-staging-verify/20260707T201848Z
- head_sha: bdcad5a1aaf21ed6bb93cba5265db9a6b4ef5b1e
- readiness_classification: not_ready_parity_and_driver_gap
- ready: false
- verdict_shape: browser_precondition_green_but_parity_and_driver_gap_blocking
- source_of_truth: classification.json, rerun_verdicts.json, lane_verdicts_first_pass.json, parity_verdict.md, head_sha.txt

## Deployment Parity

- pages_ready: false
- control_plane_ready: false
- parity_status: parity_unconvergeable
- failing_leg: control_plane_version
- parity_context: Stage 1 published the staging mirror via `debbie sync staging`, but the deployed staging API `/version` endpoint did not converge to the captured target dev SHA within the 45-minute control-plane cap. The Cloudflare Pages leg was not started because the control-plane leg never reached readiness.
- target_dev_sha: bdcad5a1aaf21ed6bb93cba5265db9a6b4ef5b1e
- staging_dev_sha_final: e20c52c337da5af10defd250ce1339118d5db8c6
- staging_mirror_sha_final: d6d9be4c81567f0104cb7fbcd21fa32a9b7185e1
- commits_behind_main_final: 70
- parity_stub: chats/icg/stubs/jun11_pm_9_parity_unconvergeable_control_plane_timeout.md

The parity limitation affects deployment interpretation only; it does not
suppress the browser lane verdicts captured in this bundle.

## Browser Lane Verification

- lane_verification: run
- stage_02_first_pass: run
- stage_03_rerun_classification: run
- first_pass_count: 6
- first_pass_lanes: A, B, C, D, E, G
- rerun_flake_count: 0
- rerun_real_bug_count: 0
- setup_failure_inconclusive_lanes: F
- final_pass_including_flakes: 6 / 7
- lane_count: 7

Stage 2 first-pass Playwright execution produced 6 passes (A, B, C, D, E, G)
and 1 failure (F) against the deployed staging alias. Stage 3 re-ran Lane F
twice. Both rerun attempts failed inside `auth.setup.ts:154` (login timeout
at ~220s) before the Lane F pagination test ever executed; Lane F itself was
`skipped` in both rerun reporter JSONs. The rerun driver's
`is_auth_budget_setup_failure` guard only matches HTTP 429 patterns, so it
missed this non-429 timeout mode and initially classified Lane F as
`real_bug`. The classification was corrected to `setup_failure_inconclusive`
based on the reporter JSON evidence. `reruns.log` still reflects the
pre-correction `real_bug` output and must not be used as the classification
source for this bundle.

Per-lane classification:

| Lane | First-pass status | Final classification | Scenario |
| --- | --- | --- | --- |
| A | passed | passed_first_pass | Merchandising hub renders rules and no legacy search canvas |
| B | passed | passed_first_pass | Rules tab slug lands on merchandising hub |
| C | passed | passed_first_pass | Unified Search renders image-backed document cards |
| D | passed | passed_first_pass | Display Preferences exposes document card controls |
| E | passed | passed_first_pass | Query metrics report hit count and processing time |
| F | failed | setup_failure_inconclusive | Numbered pagination reaches first, second, and last pages |
| G | passed | passed_first_pass | Merch mode pin controls are deferred to follow-up contract |

## Readiness Classification

- ready: false
- readiness_classification: not_ready_parity_and_driver_gap
- verdict_shape: browser_precondition_green_but_parity_and_driver_gap_blocking
- real_bug_count: 0
- final_pass_ge_4: true
- final_pass_including_flakes: 6 / 7

The browser-ready precondition in `classification.json` is satisfied
(`real_bug_count = 0`, `final_pass_ge_4 = true`, `final_pass_including_flakes
= 6 / 7`, no lane classified as `real_bug` after reruns). However, the
overall Stage 4 verdict remains `ready: false` because:

1. `parity_verdict.md` records `ready: false` /
   `classification: parity_unconvergeable` on the Stage 1 control-plane
   `/version` leg; the Cloudflare Pages parity leg was never started.
2. `chats/icg/stubs/jun11_pm_9_rerun_driver_gap_setup_timeout.md` documents
   an unresolved classifier gap in the rerun driver that produced the
   corrected Lane F verdict; a full rerun driver contract cannot be
   asserted while that gap is open.

## Published Follow-Ups / Blockers

- chats/icg/stubs/jun11_pm_9_parity_unconvergeable_control_plane_timeout.md
- chats/icg/stubs/jun11_pm_9_rerun_driver_gap_setup_timeout.md
- chats/icg/stubs/jun11_pm_9_lane_f_real_defect.md
  (internal corrected classification is `setup_failure_inconclusive`; the
  legacy filename slug `_real_defect` is preserved as-is)

## Artifact Index

- docs/runbooks/evidence/polished-beta-staging-verify/20260707T201848Z/SUMMARY.md
- docs/runbooks/evidence/polished-beta-staging-verify/20260707T201848Z/classification.json
- docs/runbooks/evidence/polished-beta-staging-verify/20260707T201848Z/rerun_verdicts.json
- docs/runbooks/evidence/polished-beta-staging-verify/20260707T201848Z/lane_verdicts_first_pass.json
- docs/runbooks/evidence/polished-beta-staging-verify/20260707T201848Z/parity_verdict.md
- docs/runbooks/evidence/polished-beta-staging-verify/20260707T201848Z/head_sha.txt
- docs/runbooks/evidence/polished-beta-staging-verify/20260707T201848Z/first_pass.log
- docs/runbooks/evidence/polished-beta-staging-verify/20260707T201848Z/first_pass.exitcode
- docs/runbooks/evidence/polished-beta-staging-verify/20260707T201848Z/playwright-results.json
- docs/runbooks/evidence/polished-beta-staging-verify/20260707T201848Z/reruns.log
- docs/runbooks/evidence/polished-beta-staging-verify/20260707T201848Z/rerun_driver.exitcode
- chats/icg/stubs/jun11_pm_9_parity_unconvergeable_control_plane_timeout.md
- chats/icg/stubs/jun11_pm_9_rerun_driver_gap_setup_timeout.md
- chats/icg/stubs/jun11_pm_9_lane_f_real_defect.md
