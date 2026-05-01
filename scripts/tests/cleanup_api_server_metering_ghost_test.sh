#!/usr/bin/env bash
# Contract test for ops/scripts/cleanup_api_server_metering_ghost.sh.
#
# This is a dry-run-only suite. It locks the operator-visible cleanup plan
# before the live mutation path is introduced.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLEANUP_SCRIPT="$REPO_ROOT/ops/scripts/cleanup_api_server_metering_ghost.sh"

# shellcheck source=scripts/tests/lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=scripts/tests/lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

RUN_STDOUT=""
RUN_EXIT_CODE=0
TEST_TMP_DIR=""

cleanup_test_tmp_dir() {
    if [ -n "${TEST_TMP_DIR:-}" ] && [ -d "$TEST_TMP_DIR" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap cleanup_test_tmp_dir EXIT

make_test_tmp_dir() {
    cleanup_test_tmp_dir
    TEST_TMP_DIR="$(mktemp -d)"
    mkdir -p \
        "$TEST_TMP_DIR/root/etc/systemd/system" \
        "$TEST_TMP_DIR/root/etc/fjcloud" \
        "$TEST_TMP_DIR/root/usr/local/bin"
}

seed_fixture_root() {
    printf '%s\n' '[Unit]' > "$TEST_TMP_DIR/root/etc/systemd/system/fj-metering-agent.service"
    printf '%s\n' 'CUSTOMER_ID=staging' > "$TEST_TMP_DIR/root/etc/fjcloud/metering-env"
    printf '%s\n' 'binary' > "$TEST_TMP_DIR/root/usr/local/bin/fj-metering-agent"
    printf '%s\n' 'backup' > "$TEST_TMP_DIR/root/usr/local/bin/fj-metering-agent.old"
}

run_cleanup_script() {
    RUN_EXIT_CODE=0
    RUN_STDOUT="$(
        env -i \
            PATH="/usr/bin:/bin:/usr/local/bin" \
            HOME="$TEST_TMP_DIR" \
            TMPDIR="$TEST_TMP_DIR" \
            FJCLOUD_API_SERVER_ROOT="$TEST_TMP_DIR/root" \
            bash "$CLEANUP_SCRIPT" --dry-run 2>&1
    )" || RUN_EXIT_CODE=$?
}

test_dry_run_prints_full_cleanup_plan_against_fixture_tree() {
    make_test_tmp_dir
    seed_fixture_root
    run_cleanup_script

    assert_eq "$RUN_EXIT_CODE" "0" "dry-run should exit successfully on a fixture tree"
    assert_contains "$RUN_STDOUT" "dry-run mode" "dry-run output should declare dry-run mode"
    assert_contains "$RUN_STDOUT" "verify API-server host identity via IMDSv2 + ec2:DescribeTags" "dry-run should name the host-identity preflight"
    assert_contains "$RUN_STDOUT" "verify deployed SHA gate" "dry-run should name the deployed-SHA preflight"
    assert_contains "$RUN_STDOUT" "$TEST_TMP_DIR/root/etc/systemd/system/fj-metering-agent.service" "dry-run should name the service unit path"
    assert_contains "$RUN_STDOUT" "$TEST_TMP_DIR/root/etc/fjcloud/metering-env" "dry-run should name the metering-env path"
    assert_contains "$RUN_STDOUT" "$TEST_TMP_DIR/root/usr/local/bin/fj-metering-agent" "dry-run should name the metering binary path"
    assert_contains "$RUN_STDOUT" "$TEST_TMP_DIR/root/usr/local/bin/fj-metering-agent.old" "dry-run should name the metering backup binary path"
    assert_contains "$RUN_STDOUT" "stop fj-metering-agent.service" "dry-run should include the stop action"
    assert_contains "$RUN_STDOUT" "disable fj-metering-agent.service" "dry-run should include the disable action"
    assert_contains "$RUN_STDOUT" "remove service unit" "dry-run should include the unit-file removal action"
    assert_contains "$RUN_STDOUT" "systemctl daemon-reload" "dry-run should include the daemon-reload action"
    assert_contains "$RUN_STDOUT" "remove metering env file" "dry-run should include the metering-env removal action"
    assert_contains "$RUN_STDOUT" "remove metering binary" "dry-run should include the binary removal action"
    assert_contains "$RUN_STDOUT" "remove metering backup binary" "dry-run should include the backup-binary removal action"
    assert_contains "$RUN_STDOUT" "dry-run does not create an evidence log" "dry-run should explain log behavior"
}

test_script_documents_ssm_invocation_contract() {
    local content
    content="$(cat "$CLEANUP_SCRIPT" 2>/dev/null || true)"

    assert_contains "$content" "aws ssm send-command" "script should document the SSM send-command invocation"
    assert_contains "$content" "EXPECTED_DEPLOYED_SHA" "script should document the deployed-SHA gate input"
}

test_dry_run_plan_is_non_mutating_for_fixture_files() {
    make_test_tmp_dir
    seed_fixture_root
    run_cleanup_script

    assert_eq "$RUN_EXIT_CODE" "0" "dry-run should stay successful for non-mutation check"
    assert_contains "$(cat "$TEST_TMP_DIR/root/etc/systemd/system/fj-metering-agent.service")" "[Unit]" "dry-run should not modify the service unit fixture"
    assert_contains "$(cat "$TEST_TMP_DIR/root/etc/fjcloud/metering-env")" "CUSTOMER_ID=staging" "dry-run should not modify the metering-env fixture"
    assert_contains "$(cat "$TEST_TMP_DIR/root/usr/local/bin/fj-metering-agent")" "binary" "dry-run should not modify the metering binary fixture"
    assert_contains "$(cat "$TEST_TMP_DIR/root/usr/local/bin/fj-metering-agent.old")" "backup" "dry-run should not modify the backup binary fixture"
}

test_dry_run_prints_expected_sha_floor() {
    make_test_tmp_dir
    seed_fixture_root
    run_cleanup_script

    assert_eq "$RUN_EXIT_CODE" "0" "dry-run should stay successful for SHA messaging"
    assert_contains "$RUN_STDOUT" "2b4cfaae3ada8e61cd2721966cb3bb55a38fddf0" "dry-run should print the cleanup deploy SHA floor"
}

test_dry_run_prints_summary_footer() {
    make_test_tmp_dir
    seed_fixture_root
    run_cleanup_script

    assert_eq "$RUN_EXIT_CODE" "0" "dry-run should stay successful for summary footer"
    assert_contains "$RUN_STDOUT" "planned cleanup complete" "dry-run should print a summary footer"
}

test_dry_run_prints_describe_tags_iam_warning() {
    make_test_tmp_dir
    seed_fixture_root
    run_cleanup_script

    assert_eq "$RUN_EXIT_CODE" "0" "dry-run should stay successful for IAM warning"
    assert_contains "$RUN_STDOUT" "live run requires ec2:DescribeTags" "dry-run should surface the DescribeTags prerequisite"
}

test_dry_run_keeps_fixture_paths_separate_from_real_root() {
    make_test_tmp_dir
    seed_fixture_root
    run_cleanup_script

    assert_eq "$RUN_EXIT_CODE" "0" "dry-run should stay successful for fixture-root isolation"
    assert_not_contains "$RUN_STDOUT" $'\n/etc/systemd/system/fj-metering-agent.service' "dry-run should render the fixture-root path rather than the live root path"
}

test_cleanup_script_is_shell_executable() {
    if [[ -x "$CLEANUP_SCRIPT" ]]; then
        pass "cleanup script should be executable"
    else
        fail "cleanup script should be executable"
    fi
}

test_dry_run_prints_all_actions_once() {
    make_test_tmp_dir
    seed_fixture_root
    run_cleanup_script

    assert_eq "$RUN_EXIT_CODE" "0" "dry-run should stay successful for action-count check"
    local action_count
    action_count="$(printf '%s\n' "$RUN_STDOUT" | grep -c '^\[dry-run\]')"
    assert_eq "$action_count" "9" "dry-run should print one line per preflight/action item"
}

test_dry_run_prints_expected_service_name() {
    make_test_tmp_dir
    seed_fixture_root
    run_cleanup_script

    assert_eq "$RUN_EXIT_CODE" "0" "dry-run should stay successful for service-name check"
    assert_contains "$RUN_STDOUT" "fj-metering-agent.service" "dry-run should reference the exact service name"
}

test_dry_run_marks_existing_fixture_files_as_active_work() {
    make_test_tmp_dir
    seed_fixture_root
    run_cleanup_script

    assert_eq "$RUN_EXIT_CODE" "0" "dry-run should stay successful for active-work labeling"
    assert_contains "$RUN_STDOUT" "remove service unit [would-change]" "dry-run should mark the unit-file removal as active work"
    assert_contains "$RUN_STDOUT" "remove metering env file [would-change]" "dry-run should mark the env-file removal as active work"
    assert_contains "$RUN_STDOUT" "remove metering binary [would-change]" "dry-run should mark the binary removal as active work"
    assert_contains "$RUN_STDOUT" "remove metering backup binary [would-change]" "dry-run should mark the backup-binary removal as active work"
}

test_dry_run_marks_missing_service_state_checks_as_planned() {
    make_test_tmp_dir
    seed_fixture_root
    run_cleanup_script

    assert_eq "$RUN_EXIT_CODE" "0" "dry-run should stay successful for service-state labeling"
    assert_contains "$RUN_STDOUT" "stop fj-metering-agent.service [planned]" "dry-run should mark stop as a planned runtime action"
    assert_contains "$RUN_STDOUT" "disable fj-metering-agent.service [planned]" "dry-run should mark disable as a planned runtime action"
    assert_contains "$RUN_STDOUT" "systemctl daemon-reload [planned]" "dry-run should mark daemon-reload as a planned runtime action"
}

test_dry_run_leaves_no_evidence_log_file() {
    make_test_tmp_dir
    seed_fixture_root
    run_cleanup_script

    assert_eq "$RUN_EXIT_CODE" "0" "dry-run should stay successful for evidence-log check"
    local log_count
    log_count="$(ls "$TEST_TMP_DIR" | grep -c '^api_server_metering_cleanup_' || true)"
    assert_eq "$log_count" "0" "dry-run should not create an evidence log file"
}

test_dry_run_usage_rejects_unknown_flag() {
    local stdout exit_code
    exit_code=0
    stdout="$(
        env -i PATH="/usr/bin:/bin:/usr/local/bin" HOME="${TMPDIR:-/tmp}" TMPDIR="${TMPDIR:-/tmp}" \
        bash "$CLEANUP_SCRIPT" --bogus 2>&1
    )" || exit_code=$?

    assert_eq "$exit_code" "1" "unknown flag should fail"
    assert_contains "$stdout" "Usage:" "unknown flag failure should print usage"
}

test_dry_run_without_fixture_files_marks_file_removals_as_noop() {
    make_test_tmp_dir
    run_cleanup_script

    assert_eq "$RUN_EXIT_CODE" "0" "dry-run should succeed with an empty fixture tree"
    assert_contains "$RUN_STDOUT" "remove service unit [no-op]" "dry-run should mark missing unit-file removal as no-op"
    assert_contains "$RUN_STDOUT" "remove metering env file [no-op]" "dry-run should mark missing env-file removal as no-op"
    assert_contains "$RUN_STDOUT" "remove metering binary [no-op]" "dry-run should mark missing binary removal as no-op"
    assert_contains "$RUN_STDOUT" "remove metering backup binary [no-op]" "dry-run should mark missing backup-binary removal as no-op"
}

test_dry_run_still_mentions_live_log_path() {
    make_test_tmp_dir
    seed_fixture_root
    run_cleanup_script

    assert_eq "$RUN_EXIT_CODE" "0" "dry-run should stay successful for live-log-path messaging"
    assert_contains "$RUN_STDOUT" "/tmp/api_server_metering_cleanup_" "dry-run should mention the live evidence-log prefix"
}

test_dry_run_prints_completion_guidance() {
    make_test_tmp_dir
    seed_fixture_root
    run_cleanup_script

    assert_eq "$RUN_EXIT_CODE" "0" "dry-run should stay successful for completion guidance"
    assert_contains "$RUN_STDOUT" "re-run without --dry-run on the API server after the cleanup deploy is live" "dry-run should print completion guidance"
}

test_dry_run_prints_root_prefix() {
    make_test_tmp_dir
    seed_fixture_root
    run_cleanup_script

    assert_eq "$RUN_EXIT_CODE" "0" "dry-run should stay successful for root-prefix messaging"
    assert_contains "$RUN_STDOUT" "target root: $TEST_TMP_DIR/root" "dry-run should print the target root"
}

test_dry_run_prints_expected_name_tag() {
    make_test_tmp_dir
    seed_fixture_root
    run_cleanup_script

    assert_eq "$RUN_EXIT_CODE" "0" "dry-run should stay successful for Name-tag guidance"
    assert_contains "$RUN_STDOUT" "expected Name tag pattern: fjcloud-api-<env>" "dry-run should print the Name-tag expectation"
}

test_dry_run_prints_sha_source() {
    make_test_tmp_dir
    seed_fixture_root
    run_cleanup_script

    assert_eq "$RUN_EXIT_CODE" "0" "dry-run should stay successful for SHA-source guidance"
    assert_contains "$RUN_STDOUT" "/fjcloud/<env>/last_deploy_sha" "dry-run should print the SSM SHA source"
}

main() {
    test_dry_run_prints_full_cleanup_plan_against_fixture_tree
    test_script_documents_ssm_invocation_contract
    test_dry_run_plan_is_non_mutating_for_fixture_files
    test_dry_run_prints_expected_sha_floor
    test_dry_run_prints_summary_footer
    test_dry_run_prints_describe_tags_iam_warning
    test_dry_run_keeps_fixture_paths_separate_from_real_root
    test_cleanup_script_is_shell_executable
    test_dry_run_prints_all_actions_once
    test_dry_run_prints_expected_service_name
    test_dry_run_marks_existing_fixture_files_as_active_work
    test_dry_run_marks_missing_service_state_checks_as_planned
    test_dry_run_leaves_no_evidence_log_file
    test_dry_run_usage_rejects_unknown_flag
    test_dry_run_without_fixture_files_marks_file_removals_as_noop
    test_dry_run_still_mentions_live_log_path
    test_dry_run_prints_completion_guidance
    test_dry_run_prints_root_prefix
    test_dry_run_prints_expected_name_tag
    test_dry_run_prints_sha_source
    run_test_summary
}

main "$@"
