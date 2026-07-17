hypothesis: at the Stage 1 mirror SHA, the seven @staging_verify lanes render the polished-beta UI as designed.
first_pass_pass: 7 / 7
non_passed_lanes: none
decision: proceed_to_stage_3_classification
stage3_next_command: EVIDENCE_DIR=docs/runbooks/evidence/polished-beta-staging-verify/20260708T082333Z bash scripts/verify/rerun_failing_lanes.sh
note: Stage 2 did not author SUMMARY.md or the Stage 4 launch gate line.
