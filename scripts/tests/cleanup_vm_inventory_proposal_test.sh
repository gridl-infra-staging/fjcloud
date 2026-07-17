#!/usr/bin/env bash
# Contract tests for scripts/reliability/cleanup_vm_inventory_proposal.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/reliability/cleanup_vm_inventory_proposal.sh"
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
RUN_STDERR=""

REQUIRED_FILES=(
    "inventory_rows.json"
    "deployment_rows.json"
    "reconciliation_summary.json"
    "vm_inventory_status_counts.csv"
    "customer_deployments_status_counts.csv"
    "provisioning_age_distribution.csv"
    "provisioning_rows_detailed.csv"
    "provisioning_by_customer_cohort.csv"
    "billing_accuracy_impact.csv"
)

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

build_fixture_evidence_dir() {
    local destination_dir="$1"
    local include_ec2="${2:-yes}"

    mkdir -p "$destination_dir"
    cp "$FIXTURE_DIR/inventory_rows.json" "$destination_dir/inventory_rows.json"
    cp "$FIXTURE_DIR/deployment_rows.json" "$destination_dir/deployment_rows.json"
    cp "$FIXTURE_DIR/reconciliation_summary.json" "$destination_dir/reconciliation_summary.json"
    cp "$FIXTURE_DIR/vm_inventory_status_counts.csv" "$destination_dir/vm_inventory_status_counts.csv"
    cp "$FIXTURE_DIR/customer_deployments_status_counts.csv" "$destination_dir/customer_deployments_status_counts.csv"
    cp "$FIXTURE_DIR/provisioning_age_distribution.csv" "$destination_dir/provisioning_age_distribution.csv"
    cp "$FIXTURE_DIR/provisioning_rows_detailed.csv" "$destination_dir/provisioning_rows_detailed.csv"
    cp "$FIXTURE_DIR/provisioning_by_customer_cohort.csv" "$destination_dir/provisioning_by_customer_cohort.csv"
    cp "$FIXTURE_DIR/billing_accuracy_impact.csv" "$destination_dir/billing_accuracy_impact.csv"

    if [ "$include_ec2" = "yes" ]; then
        cp "$FIXTURE_DIR/ec2_instances.json" "$destination_dir/ec2_instances.json"
    fi
}

run_script_capture() {
    RUN_EXIT_CODE=0
    RUN_STDOUT=""
    RUN_STDERR=""

    RUN_STDOUT="$({
        bash "$TARGET_SCRIPT" "$@"
    } 2>"$TEST_TMP_DIR/run.stderr")" || RUN_EXIT_CODE=$?
    RUN_STDERR="$(cat "$TEST_TMP_DIR/run.stderr")"
}

assert_first_and_last_sql_lines() {
    local output="$1"
    local first_line
    local last_line

    first_line="$(printf '%s\n' "$output" | sed -n '1p')"
    last_line="$(printf '%s\n' "$output" | awk 'NF { line = $0 } END { print line }')"

    assert_eq "$first_line" "BEGIN;" "first SQL line should be BEGIN;"
    assert_eq "$last_line" "ROLLBACK;" "last SQL line should be ROLLBACK;"
}

assert_missing_required_files_fail() {
    local file_name

    for file_name in "${REQUIRED_FILES[@]}"; do
        make_test_tmp_dir
        local evidence_dir="$TEST_TMP_DIR/evidence"

        build_fixture_evidence_dir "$evidence_dir"
        rm -f "$evidence_dir/$file_name"

        run_script_capture --evidence-dir "$evidence_dir"

        assert_eq "$RUN_EXIT_CODE" "2" "missing $file_name should return exit 2"
        assert_contains "$RUN_STDERR" "$file_name" "missing $file_name error should name the file"
    done
}

test_input_contract_failures() {
    make_test_tmp_dir

    run_script_capture
    assert_eq "$RUN_EXIT_CODE" "2" "missing --evidence-dir should return exit 2"
    assert_contains "$RUN_STDERR" "--evidence-dir is required" "missing --evidence-dir should explain required flag"

    run_script_capture --unknown-flag
    assert_eq "$RUN_EXIT_CODE" "2" "unknown flags should return exit 2"
    assert_contains "$RUN_STDERR" "unknown argument" "unknown flag error should be explicit"

    assert_missing_required_files_fail
}

test_optional_ec2_file_contract() {
    make_test_tmp_dir
    local evidence_dir="$TEST_TMP_DIR/evidence"

    build_fixture_evidence_dir "$evidence_dir" "no"
    run_script_capture --evidence-dir "$evidence_dir"

    assert_eq "$RUN_EXIT_CODE" "0" "missing ec2_instances.json should still succeed"
    assert_first_and_last_sql_lines "$RUN_STDOUT"
}

test_success_output_contract() {
    make_test_tmp_dir
    local evidence_dir="$TEST_TMP_DIR/evidence"

    build_fixture_evidence_dir "$evidence_dir"
    run_script_capture --evidence-dir "$evidence_dir"

    assert_eq "$RUN_EXIT_CODE" "0" "fixture-backed run should succeed"
    assert_first_and_last_sql_lines "$RUN_STDOUT"

    assert_contains "$RUN_STDOUT" "-- Evidence bucket: reconciliation inventory rows missing EC2 backing" \
        "output should include reconciliation inventory-drift header"
    assert_contains "$RUN_STDOUT" "-- Evidence bucket: shared EC2 instances missing inventory rows" \
        "output should include shared-EC2 drift header"
    assert_contains "$RUN_STDOUT" "-- Evidence bucket: aged provisioning backlog" \
        "output should include provisioning-backlog header"
    assert_contains "$RUN_STDOUT" "-- Evidence bucket: billing exposure counts" \
        "output should include billing-impact header"
    assert_contains "$RUN_STDOUT" "-- no-op: no cohort had provisioning_count > customer_count" \
        "output should include at least one bucket-level no-op path"

    assert_contains "$RUN_STDOUT" "UPDATE vm_inventory" \
        "output should include at least one reconciliation-drift candidate statement"
    assert_contains "$RUN_STDOUT" "UPDATE customer_deployments" \
        "output should include at least one provisioning/billing candidate statement"
    assert_not_contains "$RUN_STDOUT" "provider_vm_id LIKE 'provisioning-lock:%'" \
        "output should not include untargeted provisioning-lock sweeps outside evidence-scoped drift rows"
}

test_non_live_behavior_contract() {
    make_test_tmp_dir
    local evidence_dir="$TEST_TMP_DIR/evidence"
    local bin_dir="$TEST_TMP_DIR/bin"

    build_fixture_evidence_dir "$evidence_dir"
    mkdir -p "$bin_dir"

    cat > "$bin_dir/aws" <<EOS
#!/usr/bin/env bash
echo aws-called > "$TEST_TMP_DIR/aws_called"
exit 97
EOS

    cat > "$bin_dir/psql" <<EOS
#!/usr/bin/env bash
echo psql-called > "$TEST_TMP_DIR/psql_called"
exit 97
EOS

    chmod +x "$bin_dir/aws" "$bin_dir/psql"

    RUN_EXIT_CODE=0
    RUN_STDOUT=""
    RUN_STDERR=""
    RUN_STDOUT="$({
        PATH="$bin_dir:$PATH" bash "$TARGET_SCRIPT" --evidence-dir "$evidence_dir"
    } 2>"$TEST_TMP_DIR/nonlive.stderr")" || RUN_EXIT_CODE=$?
    RUN_STDERR="$(cat "$TEST_TMP_DIR/nonlive.stderr")"

    assert_eq "$RUN_EXIT_CODE" "0" "fixture-backed run should not require aws/psql"
    if [ -f "$TEST_TMP_DIR/aws_called" ]; then
        fail "aws stub should never be invoked"
    else
        pass "aws stub should never be invoked"
    fi
    if [ -f "$TEST_TMP_DIR/psql_called" ]; then
        fail "psql stub should never be invoked"
    else
        pass "psql stub should never be invoked"
    fi

    local script_content
    script_content="$(cat "$TARGET_SCRIPT")"
    assert_not_contains "$script_content" "staging_db_run_sql" \
        "proposal script should not reference staging_db_run_sql owner seam"
    assert_not_contains "$script_content" "scripts/lib/staging_db.sh" \
        "proposal script should not source scripts/lib/staging_db.sh"
}

test_input_contract_failures
test_optional_ec2_file_contract
test_success_output_contract
test_non_live_behavior_contract
run_test_summary
