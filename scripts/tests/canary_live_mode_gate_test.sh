#!/usr/bin/env bash
# Red contract test for live-mode gate around Stripe-mutating canary steps.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CANARY_SCRIPT="$REPO_ROOT/scripts/canary/customer_loop_synthetic.sh"

PASS_COUNT=0
FAIL_COUNT=0
RUN_EXIT_CODE=0

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "FAIL: $*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

if [ ! -f "$CANARY_SCRIPT" ]; then
    fail "canary script exists at scripts/canary/customer_loop_synthetic.sh"
    exit 1
fi

# shellcheck source=scripts/canary/customer_loop_synthetic.sh
source "$CANARY_SCRIPT"

LIVE_BRANCH_CALL_COUNT=0

load_canary_env() {
    CANARY_LIVE_MODE="${CANARY_LIVE_MODE:-0}"
    export CANARY_LIVE_MODE
}

quiet_window_active() {
    return 1
}

dispatch_failure_alert() {
    :
}

cleanup_after_flow() {
    :
}

run_signup_step() {
    CANARY_NONCE="canary-test"
    CANARY_TOKEN="token-test"
    return 0
}

run_verify_email_step() { return 0; }
run_index_create_step() { return 0; }
run_index_batch_step() { return 0; }
run_index_search_step() { return 0; }
run_delete_index_step() { return 0; }
run_delete_account_step() { return 0; }
run_admin_cleanup_step() { return 0; }

run_live_stripe_branch() {
    LIVE_BRANCH_CALL_COUNT=$((LIVE_BRANCH_CALL_COUNT + 1))
    return 0
}

reset_flow_state() {
    FLOW_FAILED=0
    FLOW_FAILURE_STEP=""
    FLOW_FAILURE_DETAIL=""
    LIVE_BRANCH_CALL_COUNT=0
}

run_main_case() {
    reset_flow_state
    RUN_EXIT_CODE=0
    main "$@" >/dev/null 2>&1 || RUN_EXIT_CODE=$?
}

test_default_invocation_skips_live_branch() {
    unset CANARY_LIVE_MODE
    run_main_case
    assert_eq "$RUN_EXIT_CODE" "0" "default invocation exits 0"
    assert_eq "$LIVE_BRANCH_CALL_COUNT" "0" "default invocation skips live stripe branch"
}

test_explicit_dry_run_skips_live_branch() {
    unset CANARY_LIVE_MODE
    run_main_case --dry-run
    assert_eq "$RUN_EXIT_CODE" "0" "--dry-run exits 0"
    assert_eq "$LIVE_BRANCH_CALL_COUNT" "0" "--dry-run skips live stripe branch"
}

test_live_flag_enables_live_branch() {
    unset CANARY_LIVE_MODE
    run_main_case --live
    assert_eq "$RUN_EXIT_CODE" "0" "--live exits 0"
    assert_eq "$LIVE_BRANCH_CALL_COUNT" "1" "--live enters live stripe branch exactly once"
}

test_env_bridge_enables_live_branch() {
    CANARY_LIVE_MODE=1
    export CANARY_LIVE_MODE
    run_main_case
    assert_eq "$RUN_EXIT_CODE" "0" "CANARY_LIVE_MODE=1 exits 0"
    assert_eq "$LIVE_BRANCH_CALL_COUNT" "1" "CANARY_LIVE_MODE=1 enters live stripe branch exactly once"
}

test_dry_run_flag_overrides_live_env() {
    CANARY_LIVE_MODE=1
    export CANARY_LIVE_MODE
    run_main_case --dry-run
    assert_eq "$RUN_EXIT_CODE" "0" "--dry-run with CANARY_LIVE_MODE=1 exits 0"
    assert_eq "$LIVE_BRANCH_CALL_COUNT" "0" "--dry-run takes precedence over CANARY_LIVE_MODE=1"
}

main_test() {
    echo "=== canary_live_mode_gate_test.sh ==="
    echo ""

    test_default_invocation_skips_live_branch
    test_explicit_dry_run_skips_live_branch
    test_live_flag_enables_live_branch
    test_env_bridge_enables_live_branch
    test_dry_run_flag_overrides_live_env

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main_test "$@"
