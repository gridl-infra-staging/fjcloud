#!/usr/bin/env bash
# Tests for scripts/lib/live_gate.sh: live_gate_require function.
# These tests verify the BACKEND_LIVE_GATE enforcement mechanism.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0

fail() {
    echo "FAIL: $*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

assert_eq() {
    local actual="$1" expected="$2" msg="$3"
    if [ "$actual" != "$expected" ]; then
        fail "$msg (expected='$expected' actual='$actual')"
    else
        pass "$msg"
    fi
}

assert_contains() {
    local actual="$1" expected_substr="$2" msg="$3"
    if [[ "$actual" != *"$expected_substr"* ]]; then
        fail "$msg (expected substring '$expected_substr' in '$actual')"
    else
        pass "$msg"
    fi
}

# ============================================================================
# Test: live_gate_require exits 1 with message when gate is ON and condition fails
# ============================================================================

test_live_gate_require_fails_when_gate_on_and_condition_fails() {
    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 bash -c "
        source '$REPO_ROOT/scripts/lib/live_gate.sh'
        live_gate_require false 'STRIPE_TEST_SECRET_KEY not set'
        echo 'SHOULD_NOT_REACH'
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "live_gate_require should exit 1 when gate is on and condition fails"
    assert_contains "$output" "BACKEND_LIVE_GATE" "output should mention BACKEND_LIVE_GATE"
    assert_contains "$output" "STRIPE_TEST_SECRET_KEY not set" "output should contain the failure reason"

    # Should NOT have continued past the gate
    if [[ "$output" == *"SHOULD_NOT_REACH"* ]]; then
        fail "execution should not continue after live_gate_require fails"
    else
        pass "execution stopped after live_gate_require failure"
    fi
}

# ============================================================================
# Test: live_gate_require returns 0 (skip) when gate is OFF and condition fails
# ============================================================================

test_live_gate_require_skips_when_gate_off_and_condition_fails() {
    local output exit_code
    output="$(unset BACKEND_LIVE_GATE; bash -c "
        unset BACKEND_LIVE_GATE
        source '$REPO_ROOT/scripts/lib/live_gate.sh'
        live_gate_require false 'some precondition missing'
        echo 'CONTINUED_AFTER_SKIP'
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "0" "live_gate_require should return 0 when gate is off"
    assert_contains "$output" "[skip]" "output should contain [skip] marker"
    assert_contains "$output" "some precondition missing" "output should contain the skip reason"
    assert_contains "$output" "CONTINUED_AFTER_SKIP" "execution should continue after skip"
}

# ============================================================================
# Test: live_gate_require continues silently when condition succeeds (gate on)
# ============================================================================

test_live_gate_require_continues_when_condition_true_gate_on() {
    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 bash -c "
        source '$REPO_ROOT/scripts/lib/live_gate.sh'
        live_gate_require true 'this should not appear'
        echo 'CONTINUED_OK'
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "0" "live_gate_require should return 0 when condition is true (gate on)"
    assert_contains "$output" "CONTINUED_OK" "execution should continue after passing gate"

    # Should NOT print skip or failure messages
    if [[ "$output" == *"[skip]"* ]] || [[ "$output" == *"BACKEND_LIVE_GATE"* ]]; then
        fail "should not print gate messages when condition is true"
    else
        pass "no gate messages when condition is true"
    fi
}

# ============================================================================
# Test: live_gate_require continues silently when condition succeeds (gate off)
# ============================================================================

test_live_gate_require_continues_when_condition_true_gate_off() {
    local output exit_code
    output="$(unset BACKEND_LIVE_GATE; bash -c "
        unset BACKEND_LIVE_GATE
        source '$REPO_ROOT/scripts/lib/live_gate.sh'
        live_gate_require true 'this should not appear'
        echo 'CONTINUED_OK'
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "0" "live_gate_require should return 0 when condition is true (gate off)"
    assert_contains "$output" "CONTINUED_OK" "execution should continue after passing gate"
}

# ============================================================================
# Test: live_gate_require supports direct command+args (no eval needed)
# ============================================================================

test_live_gate_require_supports_command_with_args() {
    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 bash -c "
        source '$REPO_ROOT/scripts/lib/live_gate.sh'
        live_gate_require test -n 'ok' 'test command should pass'
        echo 'CONTINUED_OK'
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "0" "live_gate_require should support command+args invocation"
    assert_contains "$output" "CONTINUED_OK" "execution should continue after command+args condition succeeds"
}

# ============================================================================
# Test: live_gate_require does not eval shell metacharacters in condition arg
# ============================================================================

test_live_gate_require_does_not_eval_condition_string() {
    local output exit_code tmp_flag
    tmp_flag="$(mktemp)"
    rm -f "$tmp_flag"
    output="$(BACKEND_LIVE_GATE=1 INJECTION_FLAG="$tmp_flag" bash -c "
        source '$REPO_ROOT/scripts/lib/live_gate.sh'
        live_gate_require \"false; touch \$INJECTION_FLAG\" 'should not eval'
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "live_gate_require should fail closed when condition command is invalid"
    assert_contains "$output" "BACKEND_LIVE_GATE" "output should still use gate failure message"

    if [ -e "$tmp_flag" ]; then
        fail "condition string must not be eval'd"
    else
        pass "condition string was not eval'd"
    fi

    rm -f "$tmp_flag"
}

# ============================================================================
# Test: live_gate_require handles BACKEND_LIVE_GATE=0 as off
# ============================================================================

test_live_gate_require_treats_zero_as_off() {
    local output exit_code
    output="$(BACKEND_LIVE_GATE=0 bash -c "
        source '$REPO_ROOT/scripts/lib/live_gate.sh'
        live_gate_require false 'precondition missing'
        echo 'CONTINUED_AFTER_SKIP'
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "0" "BACKEND_LIVE_GATE=0 should be treated as off"
    assert_contains "$output" "[skip]" "should skip when gate is 0"
    assert_contains "$output" "CONTINUED_AFTER_SKIP" "execution should continue after skip"
}

# ============================================================================
# Test: live_gate_enabled returns correct status
# ============================================================================

test_live_gate_enabled_returns_true_when_set() {
    local exit_code
    BACKEND_LIVE_GATE=1 bash -c "
        source '$REPO_ROOT/scripts/lib/live_gate.sh'
        live_gate_enabled
    " 2>/dev/null || exit_code=$?

    assert_eq "${exit_code:-0}" "0" "live_gate_enabled should return 0 (true) when BACKEND_LIVE_GATE=1"
}

test_live_gate_enabled_returns_false_when_unset() {
    local exit_code
    bash -c "
        unset BACKEND_LIVE_GATE
        source '$REPO_ROOT/scripts/lib/live_gate.sh'
        live_gate_enabled
    " 2>/dev/null || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "live_gate_enabled should return 1 (false) when BACKEND_LIVE_GATE is unset"
}

# ============================================================================
# Test: live_gate_fail_with_reason emits REASON and fails when gate is ON
# ============================================================================

test_live_gate_fail_with_reason_fails_when_gate_on() {
    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 bash -c "
        source '$REPO_ROOT/scripts/lib/live_gate.sh'
        live_gate_fail_with_reason 'stripe_key_unset' 'STRIPE_TEST_SECRET_KEY is not set'
        echo 'SHOULD_NOT_REACH'
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "live_gate_fail_with_reason should exit 1 when gate is on"
    assert_contains "$output" "REASON: stripe_key_unset" "output should include structured REASON line"
    assert_contains "$output" "BACKEND_LIVE_GATE" "output should include gate failure message"
}

# ============================================================================
# Test: live_gate_fail_with_reason emits REASON and skips when gate is OFF
# ============================================================================

test_live_gate_fail_with_reason_skips_when_gate_off() {
    local output exit_code
    output="$(bash -c "
        unset BACKEND_LIVE_GATE
        source '$REPO_ROOT/scripts/lib/live_gate.sh'
        live_gate_fail_with_reason 'db_url_missing' 'No database URL set'
        echo 'CONTINUED_AFTER_SKIP'
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "0" "live_gate_fail_with_reason should return 0 when gate is off"
    assert_contains "$output" "REASON: db_url_missing" "output should include structured REASON line"
    assert_contains "$output" "[skip]" "output should include skip message"
    assert_contains "$output" "CONTINUED_AFTER_SKIP" "execution should continue when gate is off"
}

# ============================================================================
# Test: live_gate_require must not execute injected shell fragments
# ============================================================================

test_live_gate_require_rejects_injected_condition_expression() {
    local marker output exit_code
    marker="$(mktemp)"
    rm -f "$marker"

    output="$(BACKEND_LIVE_GATE=1 MARKER_PATH="$marker" bash -c "
        source '$REPO_ROOT/scripts/lib/live_gate.sh'
        live_gate_require 'false; touch \"\$MARKER_PATH\"' 'injected condition must not execute'
        echo 'SHOULD_NOT_REACH'
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "injected condition expression should fail closed in live mode"
    if [ -f "$marker" ]; then
        fail "injected condition expression should not execute shell commands"
    else
        pass "injected condition expression was not executed"
    fi
    if [[ "$output" == *"SHOULD_NOT_REACH"* ]]; then
        fail "execution should stop after rejected condition in live mode"
    else
        pass "execution stopped after rejected condition in live mode"
    fi

    rm -f "$marker"
}

# ============================================================================
# Run tests
# ============================================================================

echo "=== live_gate.sh tests ==="
test_live_gate_require_fails_when_gate_on_and_condition_fails
test_live_gate_require_skips_when_gate_off_and_condition_fails
test_live_gate_require_continues_when_condition_true_gate_on
test_live_gate_require_continues_when_condition_true_gate_off
test_live_gate_require_supports_command_with_args
test_live_gate_require_does_not_eval_condition_string
test_live_gate_require_treats_zero_as_off
test_live_gate_enabled_returns_true_when_set
test_live_gate_enabled_returns_false_when_unset
test_live_gate_fail_with_reason_fails_when_gate_on
test_live_gate_fail_with_reason_skips_when_gate_off
test_live_gate_require_rejects_injected_condition_expression
echo ""
echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
