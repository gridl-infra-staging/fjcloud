#!/usr/bin/env bash
# Tests for scripts/lib/security_checks.sh.

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

test_check_secret_scan_finds_markdown_secret_in_tracked_files() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    (
        cd "$tmpdir"
        git init -q
        git config user.email "security-test@example.com"
        git config user.name "Security Test"
        mkdir -p docs
        printf 'Leaked key: AKIA1234567890ABCDEF\n' > docs/leaked-key.md
        git add docs/leaked-key.md
    )

    local output exit_code=0
    output="$(bash -c "
        source '$REPO_ROOT/scripts/lib/security_checks.sh'
        check_secret_scan '$tmpdir'
    " 2>&1)" || exit_code=$?

    rm -rf "$tmpdir"

    assert_eq "$exit_code" "1" "check_secret_scan should fail when tracked markdown contains a key"
    assert_contains "$output" "\"check\":\"secret_scan\",\"status\":\"fail\",\"reason\":\"secret_leaked\"" \
        "check_secret_scan should report secret_leaked for markdown findings"
}

echo "=== security_checks_lib.sh tests ==="
echo ""
test_check_secret_scan_finds_markdown_secret_in_tracked_files
echo ""
echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
