#!/usr/bin/env bash
# Shared test-runner boilerplate: pass/fail counters and summary helper.
#
# Source this BEFORE assertions.sh — it provides the pass() and fail()
# functions that assertions.sh requires callers to define.

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "FAIL: $*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

run_test_summary() {
    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}
