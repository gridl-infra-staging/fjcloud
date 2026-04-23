#!/usr/bin/env bash
# Focused tests for scripts/chaos/ha-failover-proof.sh.
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

test_ha_failover_proof_usage_on_no_args() {
    local exit_code=0
    local output
    output=$(bash "$REPO_ROOT/scripts/chaos/ha-failover-proof.sh" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "1" "ha-failover-proof should exit non-zero with no args"
    assert_contains "$output" "Usage" \
        "ha-failover-proof should print usage when called with no args"
}


test_ha_failover_proof_fails_when_api_unhealthy() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    # Mock curl to simulate an unhealthy API (non-zero exit).
    mkdir -p "$tmp_dir/bin"
    write_mock_script "$tmp_dir/bin/curl" 'exit 1'

    local exit_code=0
    local output
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        bash "$REPO_ROOT/scripts/chaos/ha-failover-proof.sh" "eu-west-1" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" "ha-failover-proof should fail when API health check fails"
    assert_contains "$output" "health" \
        "ha-failover-proof should mention health check failure"
}


test_ha_failover_proof_rejects_non_loopback_api_url_before_network_calls() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    write_mock_script "$tmp_dir/bin/curl" \
        'echo "curl $@" >> "'"$call_log"'"; exit 99'

    local exit_code=0
    local output
    output=$(
        PATH="$tmp_dir/bin:/usr/bin:/bin" \
        API_URL="https://api.example.com" \
        bash "$REPO_ROOT/scripts/chaos/ha-failover-proof.sh" "eu-west-1" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" \
        "ha-failover-proof should fail closed when API_URL is not loopback"
    assert_contains "$output" "loopback http(s) base URL" \
        "ha-failover-proof should explain the local-only API_URL contract"

    local calls
    calls="$(cat "$call_log" 2>/dev/null || true)"
    assert_eq "$calls" "" \
        "ha-failover-proof should reject non-loopback API_URL before any curl call"
}


test_ha_failover_proof_fails_when_no_failover_target() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    # Mock curl to return healthy API but no valid failover target.
    mkdir -p "$tmp_dir/bin"
    write_mock_script "$tmp_dir/bin/curl" 'echo "{\"status\":\"ok\"}"; exit 0'

    local exit_code=0
    local output
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_REGIONS="us-east-1:7700" \
        bash "$REPO_ROOT/scripts/chaos/ha-failover-proof.sh" "us-east-1" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" "ha-failover-proof should fail when no failover target exists"
    assert_contains "$output" "No valid failover candidate" \
        "ha-failover-proof should mention failover target issue"
}


test_ha_failover_proof_fails_before_kill_when_flapjack_binary_missing() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    local alert_state_dir="$tmp_dir/state"
    local call_log="$tmp_dir/calls.log"
    local ambient_host_bin="$tmp_dir/ambient-host/bin"
    mkdir -p \
        "$tmp_dir/bin" \
        "$alert_state_dir" \
        "$ambient_host_bin"

    setup_ha_failover_test_root "$tmp_dir"
    write_successful_restart_region_stub "$tmp_dir/scripts/chaos/restart-region.sh"
    write_minimal_ha_failover_curl_mock "$tmp_dir/bin/curl" "$alert_state_dir" "$call_log"
    write_mock_script "$ambient_host_bin/flapjack" \
        "echo 'ambient-host-flapjack' >> \"$call_log\"; exit 0"

    local output exit_code=0
    output=$(
        (
            export PATH="$ambient_host_bin:/usr/bin:/bin"
            PATH="$tmp_dir/bin:/usr/bin:/bin" \
            FLAPJACK_DEV_DIR="/nonexistent" \
            FLAPJACK_DEV_DIR_CANDIDATES="$tmp_dir/no_candidate" \
            bash "$tmp_dir/scripts/chaos/ha-failover-proof.sh" "us-east-1"
        ) 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" \
        "ha-failover-proof should fail when no restart-ready flapjack binary resolves"
    assert_contains "$output" "Flapjack binary not found" \
        "missing restart-ready flapjack binary should be surfaced before kill"
    local calls
    calls="$(cat "$call_log" 2>/dev/null || true)"
    assert_not_contains "$calls" "ambient-host-flapjack" \
        "missing-binary guard test should not inherit ambient PATH flapjack binaries"
    assert_not_contains "$calls" "POST http://localhost:3001/admin/vms/11111111-1111-1111-1111-111111111111/kill" \
        "ha-failover-proof should fail before mutating kill call when flapjack binary is missing"
}


test_ha_failover_proof_accepts_later_candidate_binary_after_empty_dirs() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    local alert_state_dir="$tmp_dir/state"
    local call_log="$tmp_dir/calls.log"
    local ambient_host_bin="$tmp_dir/ambient-host/bin"
    mkdir -p \
        "$tmp_dir/bin" \
        "$alert_state_dir" \
        "$ambient_host_bin"

    setup_ha_failover_test_root "$tmp_dir"
    write_successful_restart_region_stub "$tmp_dir/scripts/chaos/restart-region.sh"
    write_minimal_ha_failover_curl_mock "$tmp_dir/bin/curl" "$alert_state_dir" "$call_log"
    write_mock_script "$ambient_host_bin/flapjack" \
        "echo 'ambient-host-flapjack' >> \"$call_log\"; exit 99"

    local explicit_dir="$tmp_dir/explicit_flapjack"
    local empty_candidate="$tmp_dir/empty_candidate"
    local candidate_dir="$tmp_dir/candidate_flapjack/engine/target/debug"
    mkdir -p "$explicit_dir" "$empty_candidate" "$candidate_dir"
    write_mock_script "$candidate_dir/flapjack" 'exit 0'

    local output exit_code=0
    output=$(
        (
            export PATH="$ambient_host_bin:/usr/bin:/bin"
            PATH="$tmp_dir/bin:/usr/bin:/bin" \
            FLAPJACK_DEV_DIR="$explicit_dir" \
            FLAPJACK_DEV_DIR_CANDIDATES="$empty_candidate $tmp_dir/candidate_flapjack/engine" \
            bash "$tmp_dir/scripts/chaos/ha-failover-proof.sh" "us-east-1"
        ) 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" \
        "later candidate flapjack binary should satisfy guard after empty explicit/candidate dirs"
    local calls
    calls="$(cat "$call_log" 2>/dev/null || true)"
    assert_not_contains "$calls" "ambient-host-flapjack" \
        "later-candidate guard test should not inherit ambient PATH flapjack binaries"
    assert_contains "$calls" "POST http://localhost:3001/admin/vms/11111111-1111-1111-1111-111111111111/kill" \
        "later candidate flapjack binary should allow mutating kill call to proceed"
}


test_ha_failover_proof_verifies_lowest_lag_replica() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    local primary_vm_id="11111111-1111-1111-1111-111111111111"
    local alert_state_dir="$tmp_dir/state"
    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin" "$alert_state_dir"
    setup_ha_failover_test_root "$tmp_dir"
    write_successful_restart_region_stub "$tmp_dir/scripts/chaos/restart-region.sh"

    write_lowest_lag_ha_failover_curl_mock "$tmp_dir/bin/curl" "$alert_state_dir" "$call_log"
    write_mock_script "$tmp_dir/bin/flapjack" 'exit 0'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        bash "$tmp_dir/scripts/chaos/ha-failover-proof.sh" "us-east-1" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" \
        "ha-failover-proof should ignore baseline alerts and verify the lowest-lag replica"
    assert_contains "$output" "no automatic switchback" \
        "ha-failover-proof should report successful no-switchback verification"
    local calls
    calls="$(cat "$call_log" 2>/dev/null || true)"
    assert_contains "$calls" "POST http://localhost:3001/admin/vms/${primary_vm_id}/kill" \
        "PATH flapjack binary should satisfy guard and allow mutating kill call to proceed"
}

# ============================================================================
# Run all tests
# ============================================================================


main() {
    echo "=== chaos ha-failover-proof tests ==="
    echo ""

    test_ha_failover_proof_usage_on_no_args
    test_ha_failover_proof_fails_when_api_unhealthy
    test_ha_failover_proof_rejects_non_loopback_api_url_before_network_calls
    test_ha_failover_proof_fails_when_no_failover_target
    test_ha_failover_proof_fails_before_kill_when_flapjack_binary_missing
    test_ha_failover_proof_accepts_later_candidate_binary_after_empty_dirs
    test_ha_failover_proof_verifies_lowest_lag_replica

    run_test_summary
}

main "$@"
