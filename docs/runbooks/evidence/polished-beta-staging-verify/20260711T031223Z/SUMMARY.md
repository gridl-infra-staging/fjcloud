# Stage 2 Polished Beta Staging Verify Summary

- evidence_dir: docs/runbooks/evidence/polished-beta-staging-verify/20260711T031223Z
- product_sha: 873f39ef4a375e69f81fcb021f0297fd75381708
- stage1_mirror_sha: bd4fdada14a87295cd52393aca6f531978498249
- api_version_dev_sha: 873f39ef4a375e69f81fcb021f0297fd75381708
- api_version_mirror_sha: bd4fdada14a87295cd52393aca6f531978498249
- readiness_classification: ready_with_first_pass_flakes
- ready: true
- verdict_shape: browser_precondition_green_after_canonical_reruns
- source_of_truth: classification.json, rerun_verdicts.json, lane_verdicts_first_pass.json, PRECONDITION.md, and staging_version_stage2.json

## Deployment Currency

- stage_1_precondition: proceed_yes
- stage_2_currency: current
- stage_2_version_grep: contains product SHA prefix 873f39ef
- stale_currency_verdict: none

The Stage 2 `/version` probe returned the Stage 1 product SHA
`873f39ef4a375e69f81fcb021f0297fd75381708` and mirror SHA
`bd4fdada14a87295cd52393aca6f531978498249`, so the browser evidence was
collected against the Stage 1-proven staging surface.

## Browser Lane Verification

- lane_verification: run
- first_pass_exit_code: 1
- first_pass_count: 7
- first_pass_pass_count: 1
- first_pass_non_passed_count: 6
- first_pass_pass_lanes: G
- first_pass_non_passed_lanes: A, B, C, D, E, F
- rerun_driver_exit_code: 0
- reruns_run: 6
- rerun_flake_count: 6
- rerun_real_bug_count: 0
- final_pass_including_flakes: 7 / 7
- lane_count: 7

Per-lane classification:

| Lane | First-pass status | Final classification | Scenario |
| --- | --- | --- | --- |
| A | failed | flake | Merchandising hub renders rules and no legacy search canvas |
| B | failed | flake | Rules tab slug lands on merchandising hub |
| C | failed | flake | Unified Search renders image-backed document cards |
| D | failed | flake | Display Preferences exposes document card controls |
| E | failed | flake | Query metrics report hit count and processing time |
| F | failed | flake | Numbered pagination reaches first, second, and last pages |
| G | passed | passed_first_pass | Merch mode pin controls are deferred to follow-up contract |

## Readiness Classification

- ready: true
- readiness_classification: ready_with_first_pass_flakes
- real_bug_count: 0
- final_pass_ge_4: true
- final_pass_including_flakes: 7 / 7

The browser-ready precondition in `classification.json` is satisfied:
`real_bug_after_reruns = []`, `ready_precondition.real_bug_count = 0`,
`final_pass_ge_4 = true`, and `final_pass_including_flakes = 7`.

## Artifact Index

- docs/runbooks/evidence/polished-beta-staging-verify/20260711T031223Z/PRECONDITION.md
- docs/runbooks/evidence/polished-beta-staging-verify/20260711T031223Z/stage2_inputs.env
- docs/runbooks/evidence/polished-beta-staging-verify/20260711T031223Z/staging_version_stage2.json
- docs/runbooks/evidence/polished-beta-staging-verify/20260711T031223Z/playwright_first_pass.json
- docs/runbooks/evidence/polished-beta-staging-verify/20260711T031223Z/playwright_first_pass.stderr.log
- docs/runbooks/evidence/polished-beta-staging-verify/20260711T031223Z/playwright_first_pass.exit_code
- docs/runbooks/evidence/polished-beta-staging-verify/20260711T031223Z/lane_verdicts_first_pass.json
- docs/runbooks/evidence/polished-beta-staging-verify/20260711T031223Z/rerun_driver.log
- docs/runbooks/evidence/polished-beta-staging-verify/20260711T031223Z/rerun_driver.exit_code
- docs/runbooks/evidence/polished-beta-staging-verify/20260711T031223Z/rerun_verdicts.json
- docs/runbooks/evidence/polished-beta-staging-verify/20260711T031223Z/classification.json
- docs/runbooks/evidence/polished-beta-staging-verify/20260711T031223Z/first_pass_outcome.md
- docs/runbooks/evidence/polished-beta-staging-verify/20260711T031223Z/SUMMARY.md
