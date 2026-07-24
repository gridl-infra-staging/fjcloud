#!/usr/bin/env bash
# Tests for scripts/check-sizes.sh hard-size enforcement.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECK_SCRIPT="$REPO_ROOT/scripts/check-sizes.sh"
source "$SCRIPT_DIR/lib/assertions.sh"

PASS_COUNT=0
FAIL_COUNT=0
INDEX_DETAIL_PATH="web/src/routes/console/indexes/[name]/IndexDetailShell.svelte"
EXPECTED_INDEX_DETAIL_LIMIT=828
COUNTER_PATH="infra/metering-agent/src/counter.rs"
EXPECTED_COUNTER_LIMIT=959

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

run_index_detail_override_guard() {
    local check_script="$1"
    local fixture_root="$2"
    local output="" exit_code=0

    write_lines "$fixture_root/$INDEX_DETAIL_PATH" "$EXPECTED_INDEX_DETAIL_LIMIT"
    output="$("$check_script" "$fixture_root" 2>&1)" || exit_code=$?
    if [[ "$exit_code" != "0" || "$output" != "" ]]; then
        return 1
    fi

    local oversized_count=$((EXPECTED_INDEX_DETAIL_LIMIT + 1))
    output=""
    exit_code=0
    write_lines "$fixture_root/$INDEX_DETAIL_PATH" "$oversized_count"
    output="$("$check_script" "$fixture_root" 2>&1)" || exit_code=$?
    if [[ "$exit_code" != "1" ]]; then
        return 1
    fi
    if [[ "$output" != *"FAIL: $INDEX_DETAIL_PATH ($oversized_count lines, limit $EXPECTED_INDEX_DETAIL_LIMIT)"* ]]; then
        return 1
    fi
}

bump_index_detail_override_limit() {
    local check_script="$1"
    local inflated_limit=$((EXPECTED_INDEX_DETAIL_LIMIT + 100))

    python3 - "$check_script" "$INDEX_DETAIL_PATH" "$EXPECTED_INDEX_DETAIL_LIMIT" "$inflated_limit" <<'PY'
import sys

path, override_path, old_limit, new_limit = sys.argv[1:]
with open(path, "r", encoding="utf-8") as handle:
    content = handle.read()

old = f"{override_path}|{old_limit}|"
new = f"{override_path}|{new_limit}|"
if old not in content:
    raise SystemExit(f"expected override token not found: {old}")

with open(path, "w", encoding="utf-8") as handle:
    handle.write(content.replace(old, new, 1))
PY
}

run_counter_override_guard() {
    local check_script="$1"
    local fixture_root="$2"
    local output="" exit_code=0

    write_lines "$fixture_root/$COUNTER_PATH" "$EXPECTED_COUNTER_LIMIT"
    output="$("$check_script" "$fixture_root" 2>&1)" || exit_code=$?
    if [[ "$exit_code" != "0" || "$output" != "" ]]; then
        return 1
    fi

    local oversized_count=$((EXPECTED_COUNTER_LIMIT + 1))
    output=""
    exit_code=0
    write_lines "$fixture_root/$COUNTER_PATH" "$oversized_count"
    output="$("$check_script" "$fixture_root" 2>&1)" || exit_code=$?
    if [[ "$exit_code" != "1" ]]; then
        return 1
    fi
    if [[ "$output" != *"FAIL: $COUNTER_PATH ($oversized_count lines, limit $EXPECTED_COUNTER_LIMIT)"* ]]; then
        return 1
    fi
}

bump_counter_override_limit() {
    local check_script="$1"
    local inflated_limit=$((EXPECTED_COUNTER_LIMIT + 100))

    python3 - "$check_script" "$COUNTER_PATH" "$EXPECTED_COUNTER_LIMIT" "$inflated_limit" <<'PY'
import sys

path, override_path, old_limit, new_limit = sys.argv[1:]
with open(path, "r", encoding="utf-8") as handle:
    content = handle.read()

old = f"{override_path}|{old_limit}|"
new = f"{override_path}|{new_limit}|"
if old not in content:
    raise SystemExit(f"expected override token not found: {old}")

with open(path, "w", encoding="utf-8") as handle:
    handle.write(content.replace(old, new, 1))
PY
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

test_index_detail_override_is_ratcheted_and_guarded() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    local copied_script="$tmpdir/scripts/check-sizes.sh"
    local fixture_root="$tmpdir/repo"
    mkdir -p "$(dirname "$copied_script")" "$fixture_root"
    cp "$CHECK_SCRIPT" "$copied_script"
    chmod +x "$copied_script"

    local guard_exit=0
    run_index_detail_override_guard "$copied_script" "$fixture_root" || guard_exit=$?
    assert_eq "$guard_exit" "0" "index-detail override accepts only the honest ratcheted cap"

    bump_index_detail_override_limit "$copied_script"

    guard_exit=0
    run_index_detail_override_guard "$copied_script" "$fixture_root" || guard_exit=$?
    assert_ne "$guard_exit" "0" "index-detail override guard fails after a +100 cap bump"

    rm -rf "$tmpdir"
}

test_metering_counter_override_is_ratcheted_and_guarded() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    local copied_script="$tmpdir/scripts/check-sizes.sh"
    local fixture_root="$tmpdir/repo"
    mkdir -p "$(dirname "$copied_script")" "$fixture_root"
    cp "$CHECK_SCRIPT" "$copied_script"
    chmod +x "$copied_script"

    local guard_exit=0
    run_counter_override_guard "$copied_script" "$fixture_root" || guard_exit=$?
    assert_eq "$guard_exit" "0" "metering counter override accepts only the current stage cap"

    bump_counter_override_limit "$copied_script"

    guard_exit=0
    run_counter_override_guard "$copied_script" "$fixture_root" || guard_exit=$?
    assert_ne "$guard_exit" "0" "metering counter override guard fails after a +100 cap bump"

    rm -rf "$tmpdir"
}

test_duplicate_override_paths_are_rejected() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    local copied_script="$tmpdir/scripts/check-sizes.sh"
    local fixture_root="$tmpdir/repo"
    mkdir -p "$(dirname "$copied_script")" "$fixture_root/infra/metering-agent/src"
    cp "$CHECK_SCRIPT" "$copied_script"
    chmod +x "$copied_script"

    # A second entry for a path already overridden must fail loudly: the lookup
    # breaks on the first match, so a duplicate silently pins the wrong cap.
    python3 - "$copied_script" "$COUNTER_PATH" <<'PY'
import sys
script, counter_path = sys.argv[1], sys.argv[2]
with open(script, encoding="utf-8") as handle:
    text = handle.read()
marker = f'    "{counter_path}|'
index = text.index(marker)
end = text.index("\n", index) + 1
injected = f'    "{counter_path}|123|injected duplicate"\n'
with open(script, "w", encoding="utf-8") as handle:
    handle.write(text[:end] + injected + text[end:])
PY

    local output="" exit_code=0
    output="$("$copied_script" "$fixture_root" 2>&1)" || exit_code=$?

    assert_ne "$exit_code" "0" "duplicate override path is rejected"
    assert_contains "$output" "duplicate PER_FILE_OVERRIDES" \
        "duplicate override failure names the offending list"

    rm -rf "$tmpdir"
}

test_lifecycle_override_is_retired() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    local copied_script="$tmpdir/scripts/check-sizes.sh"
    local fixture_root="$tmpdir/repo"
    local lifecycle_path="infra/api/src/routes/indexes/lifecycle.rs"
    mkdir -p "$(dirname "$copied_script")" "$fixture_root"
    cp "$CHECK_SCRIPT" "$copied_script"
    chmod +x "$copied_script"
    write_lines "$fixture_root/$lifecycle_path" 851

    local output="" exit_code=0
    output="$("$copied_script" "$fixture_root" 2>&1)" || exit_code=$?

    assert_eq "$exit_code" "1" "retired lifecycle override restores the normal Rust limit"
    assert_eq "$output" "FAIL: $lifecycle_path (851 lines, limit 850)" "reports the exact lifecycle size failure"

    rm -rf "$tmpdir"
}

test_retired_now_doc_is_not_part_of_size_gate() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    mkdir -p "$tmpdir/infra/api/src" "$tmpdir/infra/metering-agent/src" \
        "$tmpdir/infra/billing/src" "$tmpdir/web/src"
    write_lines "$tmpdir/docs/NO""W.md" 500

    local output="" exit_code=0
    output="$("$CHECK_SCRIPT" "$tmpdir" 2>&1)" || exit_code=$?

    assert_eq "$exit_code" "0" "retired active-gate doc is not checked by size gate"
    assert_not_contains "$output" "NO""W.md" "no retired active-gate FAIL line after retired-doc gate moved elsewhere"

    rm -rf "$tmpdir"
}

echo ""
echo "=== check-sizes script tests ==="
echo ""

test_script_accepts_limits_and_passes_at_boundaries
test_script_fails_for_oversized_files_and_ignores_excluded_paths
test_index_detail_override_is_ratcheted_and_guarded
test_metering_counter_override_is_ratcheted_and_guarded
test_duplicate_override_paths_are_rejected
test_lifecycle_override_is_retired
test_retired_now_doc_is_not_part_of_size_gate

echo ""
echo "Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"

[[ "$FAIL_COUNT" -eq 0 ]]
