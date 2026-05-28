#!/usr/bin/env bash
# Contract test for the post-migration `infra/api/tests/` integration-test
# layout. This is the shell-side owner of the layout invariants; the exact
# module inventory is owned by `scripts/dev/regenerate_integration_test_root.py
# --check` (added in Stage 2), and this script delegates the inventory check
# to that generator instead of duplicating the list here.
#
# Invariants asserted (each checked independently so the red phase surfaces
# every drift in one run):
#   1. `infra/api/tests/` contains exactly one top-level `.rs` file and it is
#      `integration.rs`.
#   2. `infra/api/tests/integration/` exists and contains at least one `.rs`
#      file.
#   3. `python3 scripts/dev/regenerate_integration_test_root.py --check`
#      succeeds (i.e. the generated `integration.rs` matches the current
#      `tests/integration/*.rs` inventory).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TESTS_DIR="$REPO_ROOT/infra/api/tests"
INTEGRATION_DIR="$TESTS_DIR/integration"
GENERATOR="$REPO_ROOT/scripts/dev/regenerate_integration_test_root.py"

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

count_top_level_rs() {
    # Top-level only: do not descend into subdirectories. Use `find` with
    # `-maxdepth 1` so subdir contents (`common/`, `support/`, future
    # `integration/`) are excluded.
    find "$TESTS_DIR" -maxdepth 1 -mindepth 1 -type f -name '*.rs' | wc -l | tr -d ' '
}

list_top_level_rs() {
    find "$TESTS_DIR" -maxdepth 1 -mindepth 1 -type f -name '*.rs' \
        -exec basename {} \;
}

test_exactly_one_top_level_rs_file() {
    local count
    count="$(count_top_level_rs)"

    if [ "$count" -ne 1 ]; then
        fail "infra/api/tests/ must contain exactly 1 top-level .rs file (found $count). Stage 2 consolidates these into infra/api/tests/integration/<module>.rs."
        return
    fi
    pass "infra/api/tests/ has exactly 1 top-level .rs file"
}

test_sole_top_level_rs_is_integration_rs() {
    local count
    count="$(count_top_level_rs)"

    if [ "$count" -ne 1 ]; then
        # Skip secondary assertion; first check already surfaced the count
        # drift. Re-asserting here would print a redundant FAIL for the
        # same underlying drift.
        fail "cannot verify sole top-level test file is integration.rs (found $count top-level .rs files; expected 1)"
        return
    fi

    local sole_file
    sole_file="$(list_top_level_rs)"
    if [ "$sole_file" != "integration.rs" ]; then
        fail "sole top-level .rs file in infra/api/tests/ must be integration.rs (found '$sole_file')"
        return
    fi
    pass "sole top-level .rs file in infra/api/tests/ is integration.rs"
}

test_integration_subdir_exists_with_rs_files() {
    if [ ! -d "$INTEGRATION_DIR" ]; then
        fail "infra/api/tests/integration/ directory does not exist; Stage 2 must create it as the new home for individual integration test modules"
        return
    fi

    local rs_count
    rs_count="$(find "$INTEGRATION_DIR" -maxdepth 1 -mindepth 1 -type f -name '*.rs' | wc -l | tr -d ' ')"
    if [ "$rs_count" -lt 1 ]; then
        fail "infra/api/tests/integration/ exists but contains 0 .rs files; expected at least one module"
        return
    fi
    pass "infra/api/tests/integration/ exists and contains $rs_count .rs file(s)"
}

test_generator_check_passes() {
    if [ ! -f "$GENERATOR" ]; then
        fail "scripts/dev/regenerate_integration_test_root.py is missing; Stage 2 must add it as the inventory owner"
        return
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        fail "python3 not found on PATH; required to run regenerate_integration_test_root.py --check"
        return
    fi

    local out
    local status=0
    out="$(python3 "$GENERATOR" --check 2>&1)" || status=$?
    if [ "$status" -ne 0 ]; then
        fail "python3 scripts/dev/regenerate_integration_test_root.py --check returned $status. Output: $out"
        return
    fi
    pass "python3 scripts/dev/regenerate_integration_test_root.py --check passes"
}

main() {
    echo "=== integration_test_layout_test ==="
    echo ""

    test_exactly_one_top_level_rs_file
    test_sole_top_level_rs_is_integration_rs
    test_integration_subdir_exists_with_rs_files
    test_generator_check_passes

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
