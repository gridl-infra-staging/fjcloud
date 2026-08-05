#!/usr/bin/env bash
# Guard the cargo-audit exception for RUSTSEC-2026-0235.
#
# cargo-audit reports rkyv from Cargo.lock package metadata, but this repo's
# resolved workspace tree must not compile rkyv unless rust_decimal's optional
# rkyv feature is enabled.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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

assert_eq() {
    local actual="$1" expected="$2" msg="$3"
    if [ "$actual" != "$expected" ]; then
        fail "$msg (expected='$expected' actual='$actual')"
    else
        pass "$msg"
    fi
}

test_rkyv_is_not_reachable_in_resolved_workspace_tree() {
    local tree_output rkyv_count

    cd "$REPO_ROOT/infra"
    tree_output="$(cargo tree)"
    rkyv_count="$(printf '%s\n' "$tree_output" | grep -c 'rkyv' || true)"

    assert_eq "$rkyv_count" "0" \
        "rkyv is absent from the resolved infra cargo tree"
}

main() {
    echo "=== rkyv_reachability_guard_test.sh ==="
    echo ""

    test_rkyv_is_not_reachable_in_resolved_workspace_tree

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
