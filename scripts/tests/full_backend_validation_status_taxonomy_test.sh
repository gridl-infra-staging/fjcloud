#!/usr/bin/env bash
# Focused Stage 1 taxonomy/owner hard-limit regression tests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ORCH_SCRIPT="$REPO_ROOT/scripts/launch/run_full_backend_validation.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "FAIL: $1" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

script_line_count() {
    wc -l < "$1" | tr -d " "
}

test_rc_coordinator_stays_within_800_line_limit() {
    local line_count
    line_count="$(script_line_count "$ORCH_SCRIPT")"
    if [ "$line_count" -le 800 ]; then
        pass "run_full_backend_validation.sh should stay at or below the 800-line hard limit (actual=$line_count)"
    else
        fail "run_full_backend_validation.sh exceeded the 800-line hard limit (actual=$line_count)"
    fi
}

echo "=== full backend validation taxonomy contract tests ==="
test_rc_coordinator_stays_within_800_line_limit

echo "Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
[[ "$FAIL_COUNT" -eq 0 ]]
