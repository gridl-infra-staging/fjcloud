#!/usr/bin/env bash
# Tests for scripts/check-sizes.sh hard-size enforcement.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECK_SCRIPT="$REPO_ROOT/scripts/check-sizes.sh"
source "$SCRIPT_DIR/lib/assertions.sh"

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

assert_not_contains() {
    local actual="$1" unexpected_substr="$2" msg="$3"
    if [[ "$actual" == *"$unexpected_substr"* ]]; then
        fail "$msg (unexpected substring '$unexpected_substr' found in '$actual')"
    else
        pass "$msg"
    fi
}

write_lines() {
    local path="$1"
    local count="$2"
    mkdir -p "$(dirname "$path")"
    : > "$path"
    local i
    for ((i = 1; i <= count; i++)); do
        echo "line $i" >> "$path"
    done
}

test_script_accepts_limits_and_passes_at_boundaries() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    write_lines "$tmpdir/infra/api/src/a.rs" 850
    write_lines "$tmpdir/infra/metering-agent/src/b.ts" 850
    write_lines "$tmpdir/infra/billing/src/c.rs" 1
    write_lines "$tmpdir/web/src/App.svelte" 700

    local output="" exit_code=0
    output="$("$CHECK_SCRIPT" "$tmpdir" 2>&1)" || exit_code=$?

    assert_eq "$exit_code" "0" "script exits 0 when files are at or below hard limits"
    assert_eq "$output" "" "script prints no FAIL lines when there are no violations"

    rm -rf "$tmpdir"
}

test_script_fails_for_oversized_files_and_ignores_excluded_paths() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    write_lines "$tmpdir/infra/api/src/too_big.rs" 851
    write_lines "$tmpdir/web/src/TooBig.svelte" 701
    write_lines "$tmpdir/infra/api/src/tests/ignore_me.rs" 5000
    write_lines "$tmpdir/web/src/node_modules/ignore_me.ts" 5000

    local output="" exit_code=0
    output="$("$CHECK_SCRIPT" "$tmpdir" 2>&1)" || exit_code=$?

    assert_eq "$exit_code" "1" "script exits 1 when hard limits are exceeded"
    assert_contains "$output" "FAIL: infra/api/src/too_big.rs (851 lines, limit 850)" "reports oversized Rust files"
    assert_contains "$output" "FAIL: web/src/TooBig.svelte (701 lines, limit 700)" "reports oversized Svelte files"
    assert_not_contains "$output" "ignore_me.rs" "ignores infra tests directories"
    assert_not_contains "$output" "ignore_me.ts" "ignores node_modules directories"

    rm -rf "$tmpdir"
}

test_now_doc_passes_at_30_lines() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    # Source dirs need to exist to keep the source-file scan happy.
    mkdir -p "$tmpdir/infra/api/src" "$tmpdir/infra/metering-agent/src" \
        "$tmpdir/infra/billing/src" "$tmpdir/web/src"
    write_lines "$tmpdir/docs/NOW.md" 30

    local output="" exit_code=0
    output="$("$CHECK_SCRIPT" "$tmpdir" 2>&1)" || exit_code=$?

    assert_eq "$exit_code" "0" "docs/NOW.md at exactly 30 lines passes"
    assert_not_contains "$output" "NOW.md" "no NOW.md FAIL line at boundary"

    rm -rf "$tmpdir"
}

test_now_doc_fails_above_30_lines() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    mkdir -p "$tmpdir/infra/api/src" "$tmpdir/infra/metering-agent/src" \
        "$tmpdir/infra/billing/src" "$tmpdir/web/src"
    write_lines "$tmpdir/docs/NOW.md" 31

    local output="" exit_code=0
    output="$("$CHECK_SCRIPT" "$tmpdir" 2>&1)" || exit_code=$?

    assert_eq "$exit_code" "1" "docs/NOW.md at 31 lines fails"
    assert_contains "$output" "FAIL: docs/NOW.md (31 lines, limit 30)" "reports oversized NOW.md"

    rm -rf "$tmpdir"
}

test_now_doc_absent_does_not_fail() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    mkdir -p "$tmpdir/infra/api/src" "$tmpdir/infra/metering-agent/src" \
        "$tmpdir/infra/billing/src" "$tmpdir/web/src"
    # No docs/NOW.md created.

    local output="" exit_code=0
    output="$("$CHECK_SCRIPT" "$tmpdir" 2>&1)" || exit_code=$?

    assert_eq "$exit_code" "0" "missing docs/NOW.md is not a violation"
    assert_not_contains "$output" "NOW.md" "no NOW.md FAIL line when absent"

    rm -rf "$tmpdir"
}

echo ""
echo "=== check-sizes script tests ==="
echo ""

test_script_accepts_limits_and_passes_at_boundaries
test_script_fails_for_oversized_files_and_ignores_excluded_paths
test_now_doc_passes_at_30_lines
test_now_doc_fails_above_30_lines
test_now_doc_absent_does_not_fail

echo ""
echo "Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"

[[ "$FAIL_COUNT" -eq 0 ]]
