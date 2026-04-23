#!/usr/bin/env bash
# Focused tests for scripts/chaos/restart-region.sh.
# Uses mock binaries and temp directories; does not touch real services.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/local_dev_test_state.sh
source "$SCRIPT_DIR/lib/local_dev_test_state.sh"
# shellcheck source=lib/chaos_test_helpers.sh
source "$SCRIPT_DIR/lib/chaos_test_helpers.sh"

test_restart_region_fails_without_region_argument() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_restart_region_test_root "$tmp_dir"

    local output exit_code=0
    output=$(bash "$tmp_dir/scripts/chaos/restart-region.sh" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "1" "restart-region should fail without region argument"
}


test_restart_region_fails_when_region_not_in_flapjack_regions() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_restart_region_test_root "$tmp_dir"
    write_test_database_env_file "$tmp_dir"

    local output exit_code=0
    output=$(
        FLAPJACK_REGIONS="us-east-1:7700 eu-west-1:7701" \
        bash "$tmp_dir/scripts/chaos/restart-region.sh" "ap-southeast-1" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" "restart-region should fail when region is not in FLAPJACK_REGIONS"
    assert_contains "$output" "not found in FLAPJACK_REGIONS" \
        "should report that the region is not configured"
}


test_restart_region_fails_when_flapjack_binary_missing() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_restart_region_test_root "$tmp_dir"
    write_test_database_env_file "$tmp_dir"

    local output exit_code=0
    output=$(
        FLAPJACK_DEV_DIR="/nonexistent" \
        FLAPJACK_DEV_DIR_CANDIDATES="$tmp_dir/no_candidate" \
        FLAPJACK_REGIONS="us-east-1:7700" \
        bash "$tmp_dir/scripts/chaos/restart-region.sh" "us-east-1" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" "restart-region should fail when flapjack binary is missing"
    assert_contains "$output" "Flapjack binary not found" \
        "should report that the flapjack binary was not found"
}


test_restart_region_falls_back_to_path_flapjack_binary() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_restart_region_test_root "$tmp_dir"
    mkdir -p "$tmp_dir/bin"
    write_test_database_env_file "$tmp_dir"

    local call_log="$tmp_dir/calls.log"
    local empty_candidate="$tmp_dir/empty_candidate"
    mkdir -p "$empty_candidate"

    write_mock_script "$tmp_dir/bin/flapjack" \
        'echo "path-flapjack $@" >> "'"$call_log"'"; sleep 60'
    write_mock_script "$tmp_dir/bin/curl" \
        'echo "curl $@" >> "'"$call_log"'"; exit 0'
    write_mock_script "$tmp_dir/bin/nohup" \
        'exec "$@"'
    write_mock_lsof_for_pid_file "$tmp_dir/bin/lsof" "$tmp_dir/.local/flapjack-us-east-1.pid"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR_CANDIDATES="$empty_candidate" \
        FLAPJACK_REGIONS="us-east-1:7700" \
        bash "$tmp_dir/scripts/chaos/restart-region.sh" "us-east-1" 2>&1
    ) || exit_code=$?

    # Wait for the backgrounded mock flapjack to write its invocation.
    sleep 0.5

    local pid_file="$tmp_dir/.local/flapjack-us-east-1.pid"
    kill_process_from_pid_file_if_present "$pid_file"

    assert_eq "$exit_code" "0" \
        "restart-region should use flapjack from PATH when FLAPJACK_DEV_DIR has no binary"
    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    assert_contains "$calls" "path-flapjack --port 7700" \
        "should invoke the PATH flapjack binary with the selected region port"
}


test_restart_region_uses_flapjack_dev_dir_candidates_when_unset() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_restart_region_test_root "$tmp_dir"
    write_test_database_env_file "$tmp_dir"

    local first_candidate="$tmp_dir/alt_flapjack/engine"
    local second_candidate="$tmp_dir/alt_flapjack"
    local first_candidate_bin="$first_candidate/target/debug/flapjack"
    local second_candidate_bin="$second_candidate/target/debug/flapjack"
    mkdir -p "$(dirname "$first_candidate_bin")" "$(dirname "$second_candidate_bin")"
    local call_log="$tmp_dir/calls.log"
    write_mock_script "$first_candidate_bin" \
        'echo "candidate-flapjack $@" >> "'"$call_log"'"; sleep 60'
    write_mock_script "$second_candidate_bin" \
        'echo "second-candidate-flapjack $@" >> "'"$call_log"'"; sleep 60'

    mkdir -p "$tmp_dir/bin"
    write_mock_script "$tmp_dir/bin/flapjack" \
        'echo "path-flapjack $@" >> "'"$call_log"'"; sleep 60'
    write_mock_script "$tmp_dir/bin/curl" \
        'echo "curl $@" >> "'"$call_log"'"; exit 0'
    write_mock_script "$tmp_dir/bin/nohup" \
        'exec "$@"'
    write_mock_lsof_for_pid_file "$tmp_dir/bin/lsof" "$tmp_dir/.local/flapjack-us-east-1.pid"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR_CANDIDATES="$first_candidate $second_candidate" \
        FLAPJACK_REGIONS="us-east-1:7700" \
        bash "$tmp_dir/scripts/chaos/restart-region.sh" "us-east-1" 2>&1
    ) || exit_code=$?

    sleep 0.5

    local pid_file="$tmp_dir/.local/flapjack-us-east-1.pid"
    kill_process_from_pid_file_if_present "$pid_file"

    assert_eq "$exit_code" "0" \
        "restart-region should discover flapjack from candidate dirs when FLAPJACK_DEV_DIR is unset"
    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    assert_contains "$calls" "candidate-flapjack --port 7700" \
        "should invoke the candidate flapjack binary with the selected region port"
    assert_not_contains "$calls" "second-candidate-flapjack" \
        "should prefer the first existing candidate directory before later candidates"
    assert_not_contains "$calls" "path-flapjack" \
        "should not fall back to PATH when candidate directories already provide a binary"
}


test_restart_region_uses_default_repo_candidates_when_both_env_vars_unset() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_restart_region_test_root "$tmp_dir"
    mkdir -p "$tmp_dir/bin"
    write_test_database_env_file "$tmp_dir"

    # Mirror the fresh-host checkout fallback shape:
    #   $REPO_ROOT/../../gridl-dev/flapjack_dev/engine/target/debug/flapjack
    local default_engine_candidate
    default_engine_candidate="$tmp_dir/../../gridl-dev/flapjack_dev/engine"
    local default_engine_bin="$default_engine_candidate/target/debug/flapjack"
    local default_root_bin="$tmp_dir/../../gridl-dev/flapjack_dev/target/debug/flapjack"
    local call_log="$tmp_dir/calls.log"
    mkdir -p "$(dirname "$default_engine_bin")" "$(dirname "$default_root_bin")"
    write_mock_script "$default_engine_bin" \
        'echo "default-engine-flapjack $@" >> "'"$call_log"'"; sleep 60'
    write_mock_script "$default_root_bin" \
        'echo "default-root-flapjack $@" >> "'"$call_log"'"; sleep 60'

    write_mock_script "$tmp_dir/bin/flapjack" \
        'echo "path-flapjack $@" >> "'"$call_log"'"; sleep 60'
    write_mock_script "$tmp_dir/bin/curl" \
        'echo "curl $@" >> "'"$call_log"'"; exit 0'
    write_mock_script "$tmp_dir/bin/nohup" \
        'exec "$@"'
    write_mock_lsof_for_pid_file "$tmp_dir/bin/lsof" "$tmp_dir/.local/flapjack-us-east-1.pid"

    local output exit_code=0
    output=$(
        env -u FLAPJACK_DEV_DIR -u FLAPJACK_DEV_DIR_CANDIDATES \
            PATH="$tmp_dir/bin:$PATH" \
            FLAPJACK_REGIONS="us-east-1:7700" \
            bash "$tmp_dir/scripts/chaos/restart-region.sh" "us-east-1" 2>&1
    ) || exit_code=$?

    sleep 0.5

    local pid_file="$tmp_dir/.local/flapjack-us-east-1.pid"
    kill_process_from_pid_file_if_present "$pid_file"

    assert_eq "$exit_code" "0" \
        "restart-region should discover flapjack from default repo-relative candidates when both discovery env vars are unset"
    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    assert_contains "$calls" "default-engine-flapjack --port 7700" \
        "should prefer ../../gridl-dev/flapjack_dev/engine before ../../gridl-dev/flapjack_dev"
    assert_not_contains "$calls" "default-root-flapjack" \
        "should not use later default candidates when an earlier one resolves"
    assert_not_contains "$calls" "path-flapjack" \
        "should not fall back to PATH when default repo candidates already provide a binary"
}


test_restart_region_parses_correct_port_from_flapjack_regions() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_restart_region_test_root "$tmp_dir"
    write_test_database_env_file "$tmp_dir"

    # Create a mock flapjack binary that logs its arguments.
    local flapjack_dir="$tmp_dir/flapjack_dev/engine/target/debug"
    mkdir -p "$flapjack_dir"
    local call_log="$tmp_dir/calls.log"
    write_mock_script "$flapjack_dir/flapjack" \
        'echo "flapjack $@" >> "'"$call_log"'"; sleep 60'

    # Mock curl for health check (succeed immediately).
    mkdir -p "$tmp_dir/bin"
    write_mock_script "$tmp_dir/bin/curl" \
        'echo "curl $@" >> "'"$call_log"'"; exit 0'
    # Mock nohup by replacing itself with the target command. The script under
    # test already adds the outer background operator, so this keeps `$!`
    # pointing at the mock Flapjack process instead of a short-lived wrapper.
    write_mock_script "$tmp_dir/bin/nohup" \
        'exec "$@"'
    write_mock_lsof_for_pid_file "$tmp_dir/bin/lsof" "$tmp_dir/.local/flapjack-eu-west-1.pid"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="$tmp_dir/flapjack_dev" \
        FLAPJACK_REGIONS="us-east-1:7700 eu-west-1:7701 eu-central-1:7702" \
        bash "$tmp_dir/scripts/chaos/restart-region.sh" "eu-west-1" 2>&1
    ) || exit_code=$?

    # Wait for backgrounded process to write to log.
    sleep 0.5

    # Clean up the backgrounded mock flapjack.
    local pid_file="$tmp_dir/.local/flapjack-eu-west-1.pid"
    kill_process_from_pid_file_if_present "$pid_file"

    assert_eq "$exit_code" "0" "restart-region should succeed with valid config"

    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    # Verify it started flapjack with the correct port for eu-west-1 (7701).
    assert_contains "$calls" "--port 7701" \
        "should start flapjack on the correct port for eu-west-1"
    assert_contains "$output" "eu-west-1" \
        "should mention the restarted region"
}


test_restart_region_creates_pid_file() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_restart_region_test_root "$tmp_dir"
    write_test_database_env_file "$tmp_dir"

    # Create a mock flapjack binary.
    local flapjack_dir="$tmp_dir/flapjack_dev/engine/target/debug"
    mkdir -p "$flapjack_dir"
    write_mock_script "$flapjack_dir/flapjack" 'sleep 60'

    mkdir -p "$tmp_dir/bin"
    write_mock_script "$tmp_dir/bin/curl" 'sleep 0.2; exit 0'
    write_mock_script "$tmp_dir/bin/nohup" 'exec "$@"'
    write_mock_lsof_for_pid_file "$tmp_dir/bin/lsof" "$tmp_dir/.local/flapjack-us-east-1.pid"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="$tmp_dir/flapjack_dev" \
        FLAPJACK_REGIONS="us-east-1:7700" \
        bash "$tmp_dir/scripts/chaos/restart-region.sh" "us-east-1" 2>&1
    ) || exit_code=$?

    # Clean up the backgrounded mock.
    local pid_file="$tmp_dir/.local/flapjack-us-east-1.pid"
    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file")
        kill "$pid" 2>/dev/null || true
        pass "PID file was created for restarted region"
    else
        fail "PID file should have been created at $pid_file"
    fi

    assert_eq "$exit_code" "0" "restart-region should succeed"
}


test_restart_region_fails_when_health_comes_from_different_listener() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_restart_region_test_root "$tmp_dir"
    write_test_database_env_file "$tmp_dir"

    local flapjack_dir="$tmp_dir/flapjack_dev/engine/target/debug"
    mkdir -p "$flapjack_dir"
    # The launched process stays alive, but the mocked port listener belongs to
    # a different PID. That models a stale listener satisfying the health probe.
    write_mock_script "$flapjack_dir/flapjack" 'sleep 60'

    mkdir -p "$tmp_dir/bin"
    write_mock_script "$tmp_dir/bin/curl" 'exit 0'
    write_mock_script "$tmp_dir/bin/nohup" 'exec "$@"'
    write_mock_lsof_static_pid "$tmp_dir/bin/lsof" "999999"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="$tmp_dir/flapjack_dev" \
        FLAPJACK_REGIONS="us-east-1:7700" \
        bash "$tmp_dir/scripts/chaos/restart-region.sh" "us-east-1" 2>&1
    ) || exit_code=$?

    local pid_file="$tmp_dir/.local/flapjack-us-east-1.pid"
    kill_process_from_pid_file_if_present "$pid_file"

    assert_eq "$exit_code" "1" \
        "restart-region should fail when health is served by a different listener PID"
    assert_contains "$output" "not listening on port 7700" \
        "restart-region should explain that the launched PID is not the listener"
}


test_restart_region_fails_when_launched_process_exits_after_health() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_restart_region_test_root "$tmp_dir"
    write_test_database_env_file "$tmp_dir"

    local flapjack_dir="$tmp_dir/flapjack_dev/engine/target/debug"
    mkdir -p "$flapjack_dir"
    # This captures the post-run failure class: a transient health response is
    # not enough if the PID file already points at a dead process.
    write_mock_script "$flapjack_dir/flapjack" 'exit 0'

    mkdir -p "$tmp_dir/bin"
    write_mock_script "$tmp_dir/bin/curl" 'sleep 0.2; exit 0'
    write_mock_script "$tmp_dir/bin/nohup" 'exec "$@"'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="$tmp_dir/flapjack_dev" \
        FLAPJACK_REGIONS="us-east-1:7700" \
        bash "$tmp_dir/scripts/chaos/restart-region.sh" "us-east-1" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" \
        "restart-region should fail when the launched process exits after health succeeds"
    assert_contains "$output" "exited after health check" \
        "restart-region should explain that the PID no longer points at a live process"
}

# ============================================================================
# kill-region.sh messaging-contract tests
# ============================================================================


test_restart_region_uses_config_aware_timing_message() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_restart_region_test_root "$tmp_dir"
    write_test_database_env_file "$tmp_dir"

    local flapjack_dir="$tmp_dir/flapjack_dev/engine/target/debug"
    mkdir -p "$flapjack_dir"
    write_mock_script "$flapjack_dir/flapjack" 'sleep 60'

    mkdir -p "$tmp_dir/bin"
    write_mock_script "$tmp_dir/bin/curl" 'exit 0'
    write_mock_script "$tmp_dir/bin/nohup" 'exec "$@"'
    write_mock_lsof_for_pid_file "$tmp_dir/bin/lsof" "$tmp_dir/.local/flapjack-us-east-1.pid"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="$tmp_dir/flapjack_dev" \
        FLAPJACK_REGIONS="us-east-1:7700" \
        REGION_FAILOVER_CYCLE_INTERVAL_SECS=10 \
        REGION_FAILOVER_RECOVERY_THRESHOLD=4 \
        bash "$tmp_dir/scripts/chaos/restart-region.sh" "us-east-1" 2>&1
    ) || exit_code=$?

    # Clean up backgrounded mock.
    local pid_file="$tmp_dir/.local/flapjack-us-east-1.pid"
    kill_process_from_pid_file_if_present "$pid_file"

    assert_eq "$exit_code" "0" "restart-region config-aware messaging should succeed"
    assert_contains "$output" "40s" \
        "restart-region should display computed timing (10*4=40s)"
    assert_not_contains "$output" "60s" \
        "restart-region should NOT contain old hardcoded 60s"
    assert_contains "$output" "10s interval" \
        "restart-region should display the configured interval"
}

# ============================================================================
# ha-failover-proof.sh CLI contract tests
# ============================================================================


main() {
    echo "=== chaos restart-region tests ==="
    echo ""

    test_restart_region_fails_without_region_argument
    test_restart_region_fails_when_region_not_in_flapjack_regions
    test_restart_region_fails_when_flapjack_binary_missing
    test_restart_region_falls_back_to_path_flapjack_binary
    test_restart_region_uses_flapjack_dev_dir_candidates_when_unset
    test_restart_region_uses_default_repo_candidates_when_both_env_vars_unset
    test_restart_region_parses_correct_port_from_flapjack_regions
    test_restart_region_creates_pid_file
    test_restart_region_fails_when_health_comes_from_different_listener
    test_restart_region_fails_when_launched_process_exits_after_health
    test_restart_region_uses_config_aware_timing_message

    run_test_summary
}

main "$@"
