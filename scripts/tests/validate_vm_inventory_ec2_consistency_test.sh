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

run_probe_with_input_files() {
    local inventory_json="$1"
    local deployment_json="$2"
    local ec2_json="$3"
    local evidence_dir="$TEST_TMP_DIR/evidence"
    mkdir -p "$evidence_dir"

    RUN_EXIT_CODE=0
    RUN_STDOUT="$(
        bash "$TARGET_SCRIPT" \
            --inventory-json "$inventory_json" \
            --deployment-json "$deployment_json" \
            --ec2-json "$ec2_json" \
            --now-epoch 1779238800 \
            --evidence-dir "$evidence_dir" \
            2>"$TEST_TMP_DIR/probe.stderr"
    )" || RUN_EXIT_CODE=$?
}

run_probe_with_fixtures() {
    run_probe_with_input_files \
        "$FIXTURE_DIR/inventory_rows.json" \
        "$FIXTURE_DIR/deployment_rows.json" \
        "$FIXTURE_DIR/ec2_instances.json"
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

required_gate_keys() {
    python3 - "$TARGET_SCRIPT" <<'PY'
import ast
import re
import sys
from pathlib import Path

script_content = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(r"required = \[(.*?)\]", script_content, re.DOTALL)
if not match:
    raise SystemExit("required list not found")
for key in ast.literal_eval("[" + match.group(1) + "]"):
    print(key)
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
    assert_eq "$(json_eval "$RUN_STDOUT" "summary['dedicated_managed_instances_without_inventory_match']")" "1" \
        "dedicated managed EC2 rows without active inventory matches should be reported without failing the shared drift gate"
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
    assert_eq "$(json_eval "$RUN_STDOUT" "summary['raw_records']['dedicated_managed_instances_without_inventory_match'][0]['instance_id']")" "i-dedicated-customer-a" \
        "dedicated raw record should include the fixture instance id"
    assert_eq "$(json_eval "$RUN_STDOUT" "summary['raw_records']['dedicated_managed_instances_without_inventory_match'][0]['customer_id']")" "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" \
        "dedicated raw record should include the customer_id tag value"
    assert_eq "$(json_eval "$RUN_STDOUT" "summary['raw_records']['dedicated_managed_instances_without_inventory_match'][0]['node_id']")" "node-bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb" \
        "dedicated raw record should include the node_id tag value"
    assert_eq "$(json_eval "$RUN_STDOUT" "summary['raw_records']['dedicated_managed_instances_without_inventory_match'][0]['hostname']")" "vm-customer-a.flapjack.foo" \
        "dedicated raw record should include the normalized hostname"
    assert_eq "$(json_eval "$RUN_STDOUT" "summary['raw_records']['dedicated_managed_instances_without_inventory_match'][0]['state']")" "running" \
        "dedicated raw record should include instance state"
    assert_eq "$(json_eval "$RUN_STDOUT" "summary['raw_records']['dedicated_managed_instances_without_inventory_match'][0]['launch_time']")" "2026-05-19T00:04:00Z" \
        "dedicated raw record should include launch time"

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
    assert_contains "$help_output" "dedicated_managed_instances_without_inventory_match" \
        "help output should document the dedicated reporting bucket"
    assert_contains "$help_output" "reported only; not a mismatch gate" \
        "help output should document dedicated reporting as non-fail-closed"
    assert_contains "$help_output" "shared vm-shared-* managed EC2 only" \
        "help output should document the shared-fleet-only managed EC2 bucket scope"
    assert_contains "$help_output" "all fail-closed mismatch buckets are zero; reporting-only buckets may be nonzero" \
        "help output should document that reporting-only buckets do not force exit 1"
    assert_contains "$help_output" "one or more fail-closed mismatch buckets are nonzero" \
        "help output should document that only fail-closed buckets drive exit 1"
}

test_dedicated_reporting_bucket_does_not_fail_probe() {
    make_test_tmp_dir

    local inventory_json="$TEST_TMP_DIR/dedicated_only_inventory.json"
    local deployment_json="$TEST_TMP_DIR/dedicated_only_deployments.json"
    local ec2_json="$TEST_TMP_DIR/dedicated_only_ec2.json"

    printf '[]\n' > "$inventory_json"
    printf '[]\n' > "$deployment_json"
    cat > "$ec2_json" <<'JSON'
[
  {
    "InstanceId": "i-dedicated-only",
    "State": "running",
    "LaunchTime": "2026-05-19T00:05:00Z",
    "Tags": [
      {"Key": "managed-by", "Value": "fjcloud"},
      {"Key": "customer_id", "Value": "cccccccc-cccc-4ccc-8ccc-cccccccccccc"},
      {"Key": "node_id", "Value": "node-dddddddd-dddd-4ddd-8ddd-dddddddddddd"},
      {"Key": "Name", "Value": "fj-vm-customer-only.flapjack.foo"}
    ]
  }
]
JSON

    run_probe_with_input_files "$inventory_json" "$deployment_json" "$ec2_json"

    assert_eq "$RUN_EXIT_CODE" "0" \
        "dedicated reporting bucket alone should not fail the probe"
    assert_eq "$(json_eval "$RUN_STDOUT" "summary['dedicated_managed_instances_without_inventory_match']")" "1" \
        "dedicated-only fixture should populate the dedicated reporting count"
    assert_eq "$(json_eval "$RUN_STDOUT" "summary['inventory_rows_without_nonterminated_ec2_match']")" "0" \
        "dedicated-only fixture should not create inventory drift"
    assert_eq "$(json_eval "$RUN_STDOUT" "summary['managed_instances_without_inventory_match']")" "0" \
        "dedicated-only fixture should not create shared managed-instance drift"
    assert_eq "$(json_eval "$RUN_STDOUT" "summary['deployment_linkage_mismatches']")" "0" \
        "dedicated-only fixture should not create deployment linkage drift"
    assert_eq "$(json_eval "$RUN_STDOUT" "summary['stuck_shared_provisioning_rows']")" "0" \
        "dedicated-only fixture should not create stuck shared provisioning drift"
}

test_nil_customer_id_is_not_dedicated_reporting() {
    make_test_tmp_dir

    local inventory_json="$TEST_TMP_DIR/nil_customer_inventory.json"
    local deployment_json="$TEST_TMP_DIR/nil_customer_deployments.json"
    local ec2_json="$TEST_TMP_DIR/nil_customer_ec2.json"

    printf '[]\n' > "$inventory_json"
    printf '[]\n' > "$deployment_json"
    cat > "$ec2_json" <<'JSON'
[
  {
    "InstanceId": "i-nil-customer",
    "State": "running",
    "LaunchTime": "2026-05-19T00:06:00Z",
    "Tags": [
      {"Key": "managed-by", "Value": "fjcloud"},
      {"Key": "customer_id", "Value": "00000000-0000-0000-0000-000000000000"},
      {"Key": "node_id", "Value": "node-eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"},
      {"Key": "Name", "Value": "fj-vm-customer-nil.flapjack.foo"}
    ]
  }
]
JSON

    run_probe_with_input_files "$inventory_json" "$deployment_json" "$ec2_json"

    assert_eq "$RUN_EXIT_CODE" "0" \
        "nil customer_id fixture should not fail the probe"
    assert_eq "$(json_eval "$RUN_STDOUT" "summary['dedicated_managed_instances_without_inventory_match']")" "0" \
        "nil customer_id should not satisfy the dedicated reporting classifier"
}

test_required_mismatch_gate_excludes_dedicated_reporting_bucket() {
    assert_eq "$(required_gate_keys)" "inventory_rows_without_nonterminated_ec2_match
managed_instances_without_inventory_match
deployment_linkage_mismatches
stuck_shared_provisioning_rows" \
        "required mismatch gate should stay limited to fail-closed buckets"
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
test_dedicated_reporting_bucket_does_not_fail_probe
test_nil_customer_id_is_not_dedicated_reporting
test_required_mismatch_gate_excludes_dedicated_reporting_bucket
test_deployment_scope_behavior_contract
test_missing_fixture_input_is_system_error
test_live_capture_uses_paginated_db_owner_seam
run_test_summary
