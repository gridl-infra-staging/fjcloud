#!/usr/bin/env bash
# Regression tests for scripts/reliability/validate_vm_inventory_ec2_consistency.sh.
#
# Validates Stage 3 contract behavior with deterministic fixtures:
# - inventory rows lacking non-terminated managed EC2 match fail
# - non-shared managed EC2 hosts are excluded from shared inventory drift
# - provider-qualified deployment ids normalize to raw provider ids
# - shared-placement deployment ids using vm_inventory UUID reconcile via inventory/hostname
# - non-AWS provider-qualified active deployment rows are excluded from EC2-only linkage checks
# - fresh provisioning-lock rows are in-flight; aged lock rows are drift

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/reliability/validate_vm_inventory_ec2_consistency.sh"
FIXTURE_DIR="$REPO_ROOT/scripts/reliability/fixtures/vm_inventory_ec2_consistency"

# shellcheck source=scripts/tests/lib/test_runner.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=scripts/tests/lib/assertions.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/assertions.sh"

TEST_TMP_DIR=""
RUN_EXIT_CODE=0
RUN_STDOUT=""

cleanup_test_tmp_dir() {
    if [ -n "${TEST_TMP_DIR:-}" ] && [ -d "$TEST_TMP_DIR" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap cleanup_test_tmp_dir EXIT

make_test_tmp_dir() {
    cleanup_test_tmp_dir
    TEST_TMP_DIR="$(mktemp -d)"
}

run_probe_with_fixtures() {
    local evidence_dir="$TEST_TMP_DIR/evidence"
    mkdir -p "$evidence_dir"

    RUN_EXIT_CODE=0
    RUN_STDOUT="$(
        bash "$TARGET_SCRIPT" \
            --inventory-json "$FIXTURE_DIR/inventory_rows.json" \
            --deployment-json "$FIXTURE_DIR/deployment_rows.json" \
            --ec2-json "$FIXTURE_DIR/ec2_instances.json" \
            --now-epoch 1779238800 \
            --evidence-dir "$evidence_dir" \
            2>"$TEST_TMP_DIR/probe.stderr"
    )" || RUN_EXIT_CODE=$?
}

json_eval() {
    local summary_json="$1"
    local code="$2"
    python3 - "$summary_json" "$code" <<'PY'
import json
import sys

summary = json.loads(sys.argv[1])
code = sys.argv[2]
print(eval(code, {"__builtins__": {}}, {"summary": summary}))
PY
}

test_fixture_contract_behavior() {
    make_test_tmp_dir
    run_probe_with_fixtures

    assert_eq "$RUN_EXIT_CODE" "1" "probe should exit 1 when mismatch buckets are nonzero"
    assert_valid_json "$RUN_STDOUT" "probe should emit valid JSON summary"

    assert_eq "$(json_eval "$RUN_STDOUT" "summary['inventory_rows_without_nonterminated_ec2_match']")" "1" \
        "active inventory rows without non-terminated EC2 matches should be counted"
    assert_eq "$(json_eval "$RUN_STDOUT" "summary['managed_instances_without_inventory_match']")" "1" \
        "managed EC2 rows without active inventory matches should be counted"
    assert_eq "$(json_eval "$RUN_STDOUT" "summary['deployment_linkage_mismatches']")" "1" \
        "only aged provisioning locks should count as linkage mismatches in fixture"
    assert_eq "$(json_eval "$RUN_STDOUT" "summary['stuck_shared_provisioning_rows']")" "1" \
        "only aged provisioning-lock rows should count as stuck shared provisioning"

    assert_eq "$(json_eval "$RUN_STDOUT" "'dep-provider-qualified' in [r['deployment_id'] for r in summary['raw_records']['deployment_linkage_mismatches']]")" "False" \
        "provider-qualified deployment ids should normalize and avoid mismatch classification"
    assert_eq "$(json_eval "$RUN_STDOUT" "'dep-shared-placement' in [r['deployment_id'] for r in summary['raw_records']['deployment_linkage_mismatches']]")" "False" \
        "shared-placement vm_inventory-id linkage should reconcile via inventory/hostname fallback"
    assert_eq "$(json_eval "$RUN_STDOUT" "'dep-fresh-lock' in [r['deployment_id'] for r in summary['raw_records']['deployment_linkage_mismatches']]")" "False" \
        "fresh provisioning-lock rows should be excluded from drift buckets"
    assert_eq "$(json_eval "$RUN_STDOUT" "'dep-aged-lock' in [r['deployment_id'] for r in summary['raw_records']['deployment_linkage_mismatches']]")" "True" \
        "aged provisioning-lock rows should be flagged as linkage drift"
    assert_eq "$(json_eval "$RUN_STDOUT" "'dep-provisioning-bare-metal-non-lock' in summary['deployment_evaluations']")" "False" \
        "non-AWS provisioning rows without lock markers should be excluded from EC2-only reconciliation"
    assert_eq "$(json_eval "$RUN_STDOUT" "'dep-provisioning-bare-metal-non-lock' in [r['deployment_id'] for r in summary['raw_records']['deployment_linkage_mismatches']]")" "False" \
        "non-AWS provisioning rows without lock markers should not be counted as EC2 linkage mismatches"
    assert_eq "$(json_eval "$RUN_STDOUT" "'dep-terminated-provider-qualified' in summary['deployment_evaluations']")" "False" \
        "terminated deployment rows should be excluded from active-deployment reconciliation"
    assert_eq "$(json_eval "$RUN_STDOUT" "'dep-running-non-provider-qualified' in summary['deployment_evaluations']")" "False" \
        "non-provisioning rows without provider-qualified ids should be excluded from replay reconciliation"
    assert_eq "$(json_eval "$RUN_STDOUT" "'dep-running-non-provider-qualified' in [r['deployment_id'] for r in summary['raw_records']['deployment_linkage_mismatches']]")" "False" \
        "non-provisioning rows without provider-qualified ids should not be counted as deployment mismatches"
    assert_eq "$(json_eval "$RUN_STDOUT" "'dep-running-bare-metal-provider-qualified' in summary['deployment_evaluations']")" "False" \
        "non-AWS provider-qualified rows should be excluded from EC2-only reconciliation"
    assert_eq "$(json_eval "$RUN_STDOUT" "'dep-running-bare-metal-provider-qualified' in [r['deployment_id'] for r in summary['raw_records']['deployment_linkage_mismatches']]")" "False" \
        "non-AWS provider-qualified rows should not be counted as EC2 linkage mismatches"
    assert_eq "$(json_eval "$RUN_STDOUT" "'55555555-5555-5555-5555-555555555555' in [r['vm_inventory_id'] for r in summary['raw_records']['inventory_rows_without_nonterminated_ec2_match']]")" "False" \
        "non-AWS active inventory rows should be excluded from EC2-only inventory drift buckets"
    assert_eq "$(json_eval "$RUN_STDOUT" "'vm-customer-a.flapjack.foo' in [r['hostname'] for r in summary['raw_records']['managed_instances_without_inventory_match']]")" "False" \
        "non-shared managed EC2 rows should be excluded from shared inventory drift buckets"
    assert_eq "$(json_eval "$RUN_STDOUT" "'vm-shared-untracked.flapjack.foo' in [r['hostname'] for r in summary['raw_records']['managed_instances_without_inventory_match']]")" "True" \
        "shared managed EC2 rows without inventory matches should still be counted"

    assert_eq "$(json_eval "$RUN_STDOUT" "summary['deployment_evaluations']['dep-provider-qualified']['provider_vm_id_normalized']")" "i-provider-match" \
        "deployment evaluation should expose provider-qualified normalization"
    assert_eq "$(json_eval "$RUN_STDOUT" "summary['deployment_evaluations']['dep-shared-placement']['match_source']")" "inventory_hostname" \
        "shared-placement reconciliation should use inventory hostname fallback"
    assert_eq "$(json_eval "$RUN_STDOUT" "summary['deployment_evaluations']['dep-fresh-lock']['classification']")" "inflight_provisioning_lock" \
        "fresh provisioning-lock rows should be marked in-flight"

    assert_file_exists "$TEST_TMP_DIR/evidence/inventory_rows.json" "evidence inventory_rows.json should be written"
    assert_file_exists "$TEST_TMP_DIR/evidence/deployment_rows.json" "evidence deployment_rows.json should be written"
    assert_file_exists "$TEST_TMP_DIR/evidence/ec2_instances.json" "evidence ec2_instances.json should be written"
}

test_help_contract() {
    local help_output
    help_output="$(bash "$TARGET_SCRIPT" --help 2>&1 || true)"

    assert_contains "$help_output" "--evidence-dir" "help output should document --evidence-dir"
    assert_contains "$help_output" "inventory_rows_without_nonterminated_ec2_match" "help output should document required summary bucket"
    assert_contains "$help_output" "shared vm-shared-* managed EC2 only" \
        "help output should document the shared-fleet-only managed EC2 bucket scope"
}

test_deployment_scope_behavior_contract() {
    make_test_tmp_dir
    run_probe_with_fixtures

    assert_eq "$(json_eval "$RUN_STDOUT" "summary['deployment_evaluations'].__len__()")" "4" \
        "deployment scope contract should evaluate exactly four fixture rows"
    assert_eq "$(json_eval "$RUN_STDOUT" "'dep-provider-qualified' in summary['deployment_evaluations']")" "True" \
        "deployment scope contract should include provisioning AWS rows"
    assert_eq "$(json_eval "$RUN_STDOUT" "'dep-shared-placement' in summary['deployment_evaluations']")" "True" \
        "deployment scope contract should include provisioning shared-placement rows"
    assert_eq "$(json_eval "$RUN_STDOUT" "'dep-fresh-lock' in summary['deployment_evaluations']")" "True" \
        "deployment scope contract should include provisioning lock rows"
    assert_eq "$(json_eval "$RUN_STDOUT" "'dep-aged-lock' in summary['deployment_evaluations']")" "True" \
        "deployment scope contract should include aged provisioning lock rows"
}

test_missing_fixture_input_is_system_error() {
    make_test_tmp_dir
    local missing_inventory="$TEST_TMP_DIR/missing_inventory_rows.json"
    local output=""
    local exit_code=0

    output="$(
        bash "$TARGET_SCRIPT" \
            --inventory-json "$missing_inventory" \
            --deployment-json "$FIXTURE_DIR/deployment_rows.json" \
            --ec2-json "$FIXTURE_DIR/ec2_instances.json" \
            --now-epoch 1779238800 \
            2>"$TEST_TMP_DIR/missing_input.stderr"
    )" || exit_code=$?

    assert_eq "$exit_code" "2" "missing fixture inputs should return exit 2"
    assert_contains "$(cat "$TEST_TMP_DIR/missing_input.stderr")" "ERROR:" \
        "missing fixture input failure should emit an explicit error"
    assert_eq "${#output}" "0" "system-input failures should not emit summary JSON"
}

test_live_capture_uses_paginated_db_owner_seam() {
    local script_content
    script_content="$(cat "$TARGET_SCRIPT")"

    assert_contains "$script_content" "staging_db_run_sql_json_array_paginated" \
        "live capture path should page JSON capture through staging_db.sh owner seam"
}

test_fixture_contract_behavior
test_help_contract
test_deployment_scope_behavior_contract
test_missing_fixture_input_is_system_error
test_live_capture_uses_paginated_db_owner_seam
run_test_summary
