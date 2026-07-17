#!/usr/bin/env bash
# Contract test for the generated grouped `infra/api/tests/` integration-test
# roots. This is the shell-side owner of the top-level layout invariants; the
# exact module inventory is owned by `scripts/dev/regenerate_integration_test_root.py
# --check`, and this script delegates the inventory check to that generator
# instead of duplicating the list here.
#
# Invariants asserted (each checked independently so the red phase surfaces
# every drift in one run):
#   1. `infra/api/tests/` contains exactly four top-level generated `.rs`
#      roots: `auth_admin.rs`, `billing.rs`, `indexes.rs`, and `platform.rs`.
#   2. `infra/api/tests/integration/` exists and contains at least one `.rs`
#      file.
#   3. `python3 scripts/dev/regenerate_integration_test_root.py --check`
#      succeeds (i.e. the generated grouped roots match the current
#      `tests/integration/*.rs` inventory and grouping table).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TESTS_DIR="$REPO_ROOT/infra/api/tests"
INTEGRATION_DIR="$TESTS_DIR/integration"
GENERATOR="$REPO_ROOT/scripts/dev/regenerate_integration_test_root.py"
EXPECTED_ROOTS=("auth_admin.rs" "billing.rs" "indexes.rs" "platform.rs")
PLATFORM_OWNER_SUITES=("replica_service_test" "restore_test")

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

test_exactly_four_grouped_top_level_rs_files() {
    local count
    count="$(count_top_level_rs)"

    if [ "$count" -ne 4 ]; then
        fail "infra/api/tests/ must contain exactly 4 generated grouped top-level .rs files (found $count)."
        return
    fi
    pass "infra/api/tests/ has exactly 4 generated grouped top-level .rs files"
}

test_top_level_rs_files_are_grouped_roots() {
    local count
    count="$(count_top_level_rs)"

    if [ "$count" -ne 4 ]; then
        fail "cannot verify grouped top-level test files (found $count top-level .rs files; expected 4)"
        return
    fi

    local actual expected
    actual="$(list_top_level_rs | sort | tr '\n' ' ' | sed 's/ $//')"
    expected="$(printf '%s\n' "${EXPECTED_ROOTS[@]}" | sort | tr '\n' ' ' | sed 's/ $//')"
    if [ "$actual" != "$expected" ]; then
        fail "top-level .rs files in infra/api/tests/ must be exactly: $expected (found: $actual)"
        return
    fi
    pass "top-level .rs files in infra/api/tests/ are exactly the grouped roots"
}

test_no_legacy_integration_root() {
    if [ -e "$TESTS_DIR/integration.rs" ]; then
        fail "legacy generated root must be removed: infra/api/tests/integration.rs"
        return
    fi
    pass "legacy generated integration.rs root is absent"
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

test_stage2_owner_suites_compile_through_platform_root() {
    local platform_root="$TESTS_DIR/platform.rs"
    if [ ! -f "$platform_root" ]; then
        fail "platform integration root is missing: infra/api/tests/platform.rs"
        return
    fi

    local suite
    for suite in "${PLATFORM_OWNER_SUITES[@]}"; do
        if ! grep -q "mod ${suite};" "$platform_root"; then
            fail "Stage 2 owner suite must compile through platform root: ${suite}"
            return
        fi
    done
    pass "Stage 2 owner suites compile through platform root"
}

main() {
    echo "=== integration_test_layout_test ==="
    echo ""

    test_exactly_four_grouped_top_level_rs_files
    test_top_level_rs_files_are_grouped_roots
    test_no_legacy_integration_root
    test_integration_subdir_exists_with_rs_files
    test_generator_check_passes
    test_stage2_owner_suites_compile_through_platform_root

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
