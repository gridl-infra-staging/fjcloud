# Stage 2 First-Pass Browser Outcome

- evidence_dir: docs/runbooks/evidence/polished-beta-staging-verify/20260711T031223Z
- product_sha: 873f39ef4a375e69f81fcb021f0297fd75381708
- first_pass_command: `PLAYWRIGHT_TARGET_REMOTE=1 PLAYWRIGHT_JSON_OUTPUT_NAME="../$BUNDLE/playwright_first_pass.json" pnpm exec playwright test -c playwright.config.ts tests/e2e-ui/full/polished_beta_staging_verify.spec.ts --grep @staging_verify --reporter=json,line 2> "../$BUNDLE/playwright_first_pass.stderr.log"; echo $? > "../$BUNDLE/playwright_first_pass.exit_code"`
- first_pass_exit_code: 1
- first_pass_pass_count: 1
- first_pass_non_passed_count: 6
- first_pass_pass_lanes: G
- first_pass_non_passed_lanes: A, B, C, D, E, F
- rerun_driver_command: `set -o pipefail; EVIDENCE_DIR="$BUNDLE" bash scripts/verify/rerun_failing_lanes.sh 2>&1 | tee "$BUNDLE/rerun_driver.log"`
- rerun_driver_invocation_note: exact driver command first exited 78 without sourced credentials, then exited 78 at Lane C on shared auth-budget 429; the successful owner rerun used the driver's `RERUN_AUTH_ATTEMPT_COOLDOWN_SECONDS=60` harness knob after sourcing the repo-authorized credential file.
- rerun_driver_exit_code: 0
- reruns_run: 6
- rerun_flake_lanes: A, B, C, D, E, F
- real_bug_after_reruns: none
- final_pass_including_flakes: 7
- decision: proceed_to_stage_3_classification

## First-Pass Non-Passed Lanes

| Lane | Raw status | Title |
| --- | --- | --- |
| A | failed | Lane A - Merchandising hub renders rules and no legacy search canvas @staging_verify |
| B | failed | Lane B - Rules tab slug lands on merchandising hub @staging_verify |
| C | failed | Lane C - Unified Search renders image-backed document cards @staging_verify |
| D | failed | Lane D - Display Preferences exposes document card controls @staging_verify |
| E | failed | Lane E - Query metrics report hit count and processing time @staging_verify |
| F | failed | Lane F - Numbered pagination reaches first second and last pages @staging_verify |

## Rerun Classification

`scripts/verify/rerun_failing_lanes.sh` classified lanes A-F as flakes after each passed on the first rerun attempt. Lane G passed first pass. `classification.json` reports `ready_precondition.real_bug_count == 0`, `final_pass_including_flakes == 7`, and all lanes A-G are represented in `lane_verdicts_first_pass.json`.
