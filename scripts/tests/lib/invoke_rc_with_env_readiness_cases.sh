#!/usr/bin/env bash
# Readiness taxonomy cases sourced by invoke_rc_with_env_test.sh.

classify_manifest_summary() {
    local summary_path="$1" verdict_path="$2" section1_manifest="$3" artifact_dir="$4"
    _run_facade --classify-existing \
        --summary="$summary_path" \
        --verdict-output="$verdict_path" \
        --sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        --billing-month=2026-06 \
        --artifact-dir="$artifact_dir" \
        --section1-manifest="$section1_manifest"
}

setup_manifest_case() {
    local shape="$1" summary_path="$2" section1_manifest="$3"
    write_paid_beta_full_pass_summary "$summary_path"
    write_section1_manifest_with_shape "$section1_manifest" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "2026-06" "$shape"
}

assert_green_manifest_metadata() {
    local verdict_path="$1"
    assert_jq_eq "$verdict_path" ".section_impact[\"1\"]" "green" "green section1 manifest should mark section 1 green"
    assert_jq_eq "$verdict_path" ".section1_manifest.probe_count" "6" "classifier should record the complete six-row section1 shape"
    assert_jq_eq "$verdict_path" ".section1_manifest.all_green" "true" "classifier should record all_green semantics"
}

test_classify_existing_green_section1_manifest_with_full_summary_can_launch_ready() {
    setup_workspace
    local fixture_dir="$TEST_WORKSPACE/fixtures/green-section1"
    local summary_path="$fixture_dir/summary.json"
    local artifact_dir="$TEST_WORKSPACE/artifacts"
    local verdict_path="$artifact_dir/green-section1-verdict.json"
    local section1_manifest="$TEST_WORKSPACE/section1_bundle/run_manifest.json"
    setup_manifest_case "green" "$summary_path" "$section1_manifest"

    classify_manifest_summary "$summary_path" "$verdict_path" "$section1_manifest" "$artifact_dir"

    assert_eq "$RUN_EXIT_CODE" "0" "green section1 manifest classify-existing should exit 0"
    assert_jq_eq "$verdict_path" ".verdict" "LAUNCH-READY" "green section1 plus full green coordinator summary should launch ready"
    assert_jq_eq "$verdict_path" ".pre_authorized_shape_match" "true" "launch-ready all-green shape should be pre-authorized"
    assert_green_manifest_metadata "$verdict_path"
    assert_rc_run_receipt_common "$artifact_dir/rc_run_receipt.json" "<artifact_dir>" "0" "$(section1_manifest_digest "$artifact_dir/section1_manifest_validation.json")" "classify-existing"
    assert_jq_eq "$artifact_dir/rc_run_receipt.json" ".summary_digest" "$(summary_digest "$summary_path")" "classify-existing receipt should record summary digest"
    _run_facade --validate-existing --run-receipt="$artifact_dir/rc_run_receipt.json" \
        --sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --billing-month=2026-06 \
        --section1-manifest="$section1_manifest" --summary="$summary_path"
    assert_eq "$RUN_EXIT_CODE" "0" "validate-existing should accept matching receipt, summary, manifest, SHA, and billing month"
    assert_no_side_effect_calls "classify-existing with section1 manifest should not invoke coordinator or external/bootstrap tools"
}

test_classify_existing_green_section1_manifest_with_filtered_summary_is_not_launch_ready() {
    setup_workspace
    local fixture_dir="$TEST_WORKSPACE/fixtures/filtered-section1"
    local summary_path="$fixture_dir/summary.json"
    local artifact_dir="$TEST_WORKSPACE/artifacts"
    local verdict_path="$artifact_dir/filtered-section1-verdict.json"
    local section1_manifest="$TEST_WORKSPACE/section1_bundle/run_manifest.json"
    write_summary_fixture "$summary_path" <<'JSON'
{"mode":"paid_beta_rc","ready":true,"verdict":"pass","steps":[{"name":"browser_signup_paid","status":"pass","reason":""}]}
JSON
    write_section1_manifest_with_shape "$section1_manifest" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "2026-06" "green"

    classify_manifest_summary "$summary_path" "$verdict_path" "$section1_manifest" "$artifact_dir"

    assert_eq "$RUN_EXIT_CODE" "0" "filtered summary classify-existing should exit 0"
    assert_jq_eq "$verdict_path" ".verdict" "NOT-READY" "filtered --only-steps summary must not masquerade as launch-ready"
    assert_jq_eq "$verdict_path" ".summary_required_set_complete" "false" "classifier should expose incomplete coordinator summary"
    assert_jq_eq "$verdict_path" ".pre_authorized_shape_match" "false" "filtered summary is not pre-authorized"
    assert_green_manifest_metadata "$verdict_path"
}

test_validate_existing_requires_summary_when_receipt_records_digest() {
    setup_workspace
    local fixture_dir="$TEST_WORKSPACE/fixtures/validate-existing-summary-required"
    local summary_path="$fixture_dir/summary.json"
    local artifact_dir="$TEST_WORKSPACE/artifacts"
    local verdict_path="$artifact_dir/validate-existing-summary-required-verdict.json"
    local section1_manifest="$TEST_WORKSPACE/section1_bundle/run_manifest.json"
    setup_manifest_case "green" "$summary_path" "$section1_manifest"

    classify_manifest_summary "$summary_path" "$verdict_path" "$section1_manifest" "$artifact_dir"
    assert_eq "$RUN_EXIT_CODE" "0" "classify-existing should create a receipt before validate-existing summary checks"

    _run_facade --validate-existing --run-receipt="$artifact_dir/rc_run_receipt.json" \
        --sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --billing-month=2026-06 \
        --section1-manifest="$section1_manifest"

    assert_eq "$RUN_EXIT_CODE" "1" "validate-existing should fail closed when a summary digest exists but --summary is omitted"
    assert_contains "$RUN_STDERR" "summary is required when run receipt records a summary digest" "validate-existing should report the missing summary requirement explicitly"
    assert_no_side_effect_calls "validate-existing summary checks should not invoke coordinator or external/bootstrap tools"
}

test_validate_existing_emits_closeout_validation_receipt() {
    setup_workspace
    local fixture_dir="$TEST_WORKSPACE/fixtures/validate-existing-output"
    local summary_path="$fixture_dir/summary.json"
    local artifact_dir="$TEST_WORKSPACE/artifacts"
    local verdict_path="$artifact_dir/verdict.json"
    local validation_path="$artifact_dir/validation.json"
    local section1_manifest="$TEST_WORKSPACE/section1_bundle/run_manifest.json"
    setup_manifest_case "green" "$summary_path" "$section1_manifest"

    classify_manifest_summary "$summary_path" "$verdict_path" "$section1_manifest" "$artifact_dir"
    assert_eq "$RUN_EXIT_CODE" "0" "classify-existing should create the canonical verdict tuple"

    _run_facade --validate-existing --run-receipt="$artifact_dir/rc_run_receipt.json" \
        --summary="$summary_path" --verdict="$verdict_path" \
        --validation-output="$validation_path" \
        --sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --billing-month=2026-06 \
        --section1-manifest="$section1_manifest"

    assert_eq "$RUN_EXIT_CODE" "0" "validate-existing should emit a closeout validation receipt"
    assert_file_exists "$validation_path" "validate-existing should write the requested validation receipt"
    assert_jq_eq "$validation_path" ".status" "validated" "validation receipt should report validated status"
    assert_jq_eq "$validation_path" ".sha" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "validation receipt should bind the requested SHA"
    assert_jq_eq "$validation_path" ".section1_manifest_digest" "$(section1_manifest_digest "$artifact_dir/section1_manifest_validation.json")" "validation receipt should bind the Section 1 manifest bytes"
    assert_jq_eq "$validation_path" ".verdict_digest" "$(summary_digest "$verdict_path")" "validation receipt should bind the canonical verdict bytes"
    assert_no_side_effect_calls "validate-existing receipt output should not invoke coordinator or external/bootstrap tools"
}

test_validate_existing_rejects_noncanonical_verdict_without_receipt() {
    setup_workspace
    local fixture_dir="$TEST_WORKSPACE/fixtures/validate-existing-verdict-drift"
    local summary_path="$fixture_dir/summary.json"
    local artifact_dir="$TEST_WORKSPACE/artifacts"
    local verdict_path="$artifact_dir/verdict.json"
    local validation_path="$artifact_dir/validation.json"
    local section1_manifest="$TEST_WORKSPACE/section1_bundle/run_manifest.json"
    setup_manifest_case "green" "$summary_path" "$section1_manifest"

    classify_manifest_summary "$summary_path" "$verdict_path" "$section1_manifest" "$artifact_dir"
    assert_eq "$RUN_EXIT_CODE" "0" "classify-existing should create the canonical verdict tuple"
    jq '.other_real_count = 1' "$verdict_path" > "$verdict_path.tmp"
    mv "$verdict_path.tmp" "$verdict_path"

    _run_facade --validate-existing --run-receipt="$artifact_dir/rc_run_receipt.json" \
        --summary="$summary_path" --verdict="$verdict_path" \
        --validation-output="$validation_path" \
        --sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --billing-month=2026-06 \
        --section1-manifest="$section1_manifest"

    assert_eq "$RUN_EXIT_CODE" "1" "validate-existing should reject a verdict that contradicts canonical classification"
    assert_contains "$RUN_STDERR" "verdict does not match canonical RC classification" "verdict drift failure should identify canonical classification"
    assert_file_missing "$validation_path" "verdict drift must not leave a closeout validation receipt"
    assert_no_side_effect_calls "verdict drift validation should not invoke coordinator or external/bootstrap tools"
}

test_classify_existing_complete_red_section1_manifest_is_only_preauthorized_non_green() {
    setup_workspace
    local fixture_dir="$TEST_WORKSPACE/fixtures/complete-red-section1"
    local summary_path="$fixture_dir/summary.json"
    local artifact_dir="$TEST_WORKSPACE/artifacts"
    local verdict_path="$artifact_dir/complete-red-section1-verdict.json"
    local section1_manifest="$TEST_WORKSPACE/section1_bundle/run_manifest.json"
    setup_manifest_case "complete_red" "$summary_path" "$section1_manifest"

    classify_manifest_summary "$summary_path" "$verdict_path" "$section1_manifest" "$artifact_dir"

    assert_eq "$RUN_EXIT_CODE" "0" "complete-red section1 manifest classify-existing should exit 0"
    assert_jq_eq "$verdict_path" ".verdict" "NOT-READY-on-section-1" "complete-red section1 manifest should use the section1 preauth verdict"
    assert_jq_eq "$verdict_path" ".section_impact[\"1\"]" "red" "complete-red section1 manifest should mark section 1 red"
    assert_jq_eq "$verdict_path" ".section1_manifest.complete_red" "true" "classifier should identify literal complete-red"
    assert_jq_eq "$verdict_path" ".pre_authorized_shape_match" "true" "literal complete-red is the only preauthorized non-green section1 shape"
    assert_no_side_effect_calls "classify-existing with complete-red section1 manifest should not invoke coordinator or external/bootstrap tools"
}

test_classify_existing_structural_section1_gap_is_not_preauthorized() {
    setup_workspace
    local fixture_dir="$TEST_WORKSPACE/fixtures/structural-section1"
    local summary_path="$fixture_dir/summary.json"
    local artifact_dir="$TEST_WORKSPACE/artifacts"
    local verdict_path="$artifact_dir/structural-section1-verdict.json"
    local section1_manifest="$TEST_WORKSPACE/section1_bundle/run_manifest.json"
    setup_manifest_case "structural_gap" "$summary_path" "$section1_manifest"

    classify_manifest_summary "$summary_path" "$verdict_path" "$section1_manifest" "$artifact_dir"

    assert_eq "$RUN_EXIT_CODE" "0" "structural section1 manifest classify-existing should exit 0"
    assert_jq_eq "$verdict_path" ".verdict" "NOT-READY" "structural section1 gaps should fail closed without real-defect labeling"
    assert_jq_eq "$verdict_path" ".section_impact[\"1\"]" "structural_gap" "structural section1 gaps should not masquerade as green or complete-red"
    assert_jq_eq "$verdict_path" ".section1_manifest.probe_count" "5" "classifier should expose incomplete section1 row count"
    assert_jq_eq "$verdict_path" ".pre_authorized_shape_match" "false" "structural section1 gaps are not preauthorized"
}

test_classify_existing_taxonomy_rows_fail_closed_without_real_defects() {
    setup_workspace
    local fixture_dir="$TEST_WORKSPACE/fixtures/taxonomy"
    local summary_path="$fixture_dir/summary.json"
    local artifact_dir="$TEST_WORKSPACE/artifacts"
    local verdict_path="$artifact_dir/taxonomy-verdict.json"
    local section1_manifest="$TEST_WORKSPACE/section1_bundle/run_manifest.json"
    write_paid_beta_summary_with_step "$summary_path" "browser_preflight" "setup_infra" "browser_preflight_prerequisites_unsatisfied"
    python3 - "$summary_path" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    payload = json.load(fh)
updates = {
    "browser_auth_setup": ("external_secret_missing", "browser_auth_setup_env_gap"),
    "browser_portal_cancel": ("fail", "browser_portal_cancel_failed"),
    "local_signoff": ("skipped", "local_signoff_not_applicable_in_paid_beta_rc_mode"),
    "staging_runtime_smoke": ("investigate", "staging_runtime_smoke_unknown_state"),
}
for step in payload["steps"]:
    if step["name"] in updates:
        step["status"], step["reason"] = updates[step["name"]]
with open(path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2)
    fh.write("\n")
PY
    write_portal_card_rendered_artifacts "$fixture_dir"
    write_section1_manifest_with_shape "$section1_manifest" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "2026-06" "green"

    classify_manifest_summary "$summary_path" "$verdict_path" "$section1_manifest" "$artifact_dir"

    assert_eq "$RUN_EXIT_CODE" "0" "taxonomy summary classify-existing should exit 0"
    assert_jq_eq "$verdict_path" ".verdict" "NOT-READY" "non-real taxonomy rows should fail closed without launch readiness"
    assert_jq_eq "$verdict_path" ".pre_authorized_shape_match" "false" "taxonomy gaps are not pre-authorized with green section1"
    assert_jq_eq "$verdict_path" ".other_real_count" "0" "taxonomy fixture should contain no real defects"
    assert_jq_eq "$verdict_path" ".non_pass_steps[] | select(.name == \"browser_auth_setup\") | .classification" "env_gap" "env gap branch should be explicit"
    assert_jq_eq "$verdict_path" ".non_pass_steps[] | select(.name == \"browser_portal_cancel\") | .classification" "harness_gap" "harness gap branch should be explicit"
    assert_jq_eq "$verdict_path" ".non_pass_steps[] | select(.name == \"local_signoff\") | .classification" "mode_skip" "mode skip branch should be explicit"
    assert_jq_eq "$verdict_path" ".non_pass_steps[] | select(.name == \"browser_preflight\") | .classification" "setup_infra" "setup infra branch should be explicit"
    assert_jq_eq "$verdict_path" ".non_pass_steps[] | select(.name == \"staging_runtime_smoke\") | .classification" "investigate" "investigate branch should be explicit"
}

test_classify_existing_real_defect_overrides_complete_red_section1_preauthorization() {
    setup_workspace
    local fixture_dir="$TEST_WORKSPACE/fixtures/complete-red-with-defect"
    local summary_path="$fixture_dir/summary.json"
    local artifact_dir="$TEST_WORKSPACE/artifacts"
    local verdict_path="$artifact_dir/complete-red-with-defect-verdict.json"
    local section1_manifest="$TEST_WORKSPACE/section1_bundle/run_manifest.json"
    write_paid_beta_summary_with_step "$summary_path" "cargo_workspace_tests" "fail" "cargo test --workspace failed"
    write_section1_manifest_with_shape "$section1_manifest" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "2026-06" "complete_red"

    classify_manifest_summary "$summary_path" "$verdict_path" "$section1_manifest" "$artifact_dir"

    assert_eq "$RUN_EXIT_CODE" "0" "complete-red plus real defect classify-existing should exit 0"
    assert_jq_eq "$verdict_path" ".verdict" "NOT-READY-real-defects" "real defects must override section1 preauthorization"
    assert_jq_eq "$verdict_path" ".pre_authorized_shape_match" "false" "real defects are not pre-authorized"
    assert_jq_eq "$verdict_path" ".non_pass_steps[] | select(.name == \"cargo_workspace_tests\") | .classification" "other_real" "cargo failure should remain a real defect"
}
