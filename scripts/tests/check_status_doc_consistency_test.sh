#!/usr/bin/env bash
# Tests for scripts/check_status_doc_consistency.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECK_SCRIPT="$REPO_ROOT/scripts/check_status_doc_consistency.sh"

source "$SCRIPT_DIR/lib/test_runner.sh"
source "$SCRIPT_DIR/lib/assertions.sh"

build_doc_fixture() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    cat > "$tmpdir/LAUNCH.md" <<'LAUNCH'
# LAUNCH.md

## STATUS

### 2026-06-04 (fixture)
- fixture entry
LAUNCH
    cat > "$tmpdir/ROADMAP.md" <<'ROADMAP'
# Roadmap

**Launch gate:** [LAUNCH.md](LAUNCH.md) owns the v1 launch sentence, blocker interpretation,
and current launch verdict.
ROADMAP
    cat > "$tmpdir/PROJECT_OVERVIEW.md" <<'OVERVIEW'
# Project Overview

`ROADMAP.md` owns the active and planned work ledger.
OVERVIEW
    echo "$tmpdir"
}

run_check() {
    local doc_root="$1"
    RUN_EXIT_CODE=0
    RUN_STDERR="$(FJCLOUD_DOC_ROOT="$doc_root" bash "$CHECK_SCRIPT" 2>&1 1>/dev/null)" || RUN_EXIT_CODE=$?
    RUN_STDOUT="$(FJCLOUD_DOC_ROOT="$doc_root" bash "$CHECK_SCRIPT" 2>/dev/null)" || true
}

test_v2_owner_surface_passes() {
    local dir
    dir="$(build_doc_fixture)"
    run_check "$dir"
    assert_eq "$RUN_EXIT_CODE" "0" "collapsed v2 owner surface should pass"
    assert_contains "$RUN_STDOUT" "retired mutable-owner docs absent" "success output should name retired-doc absence"
    rm -rf "$dir"
}

test_retired_docs_fail() {
    local retired_path
    for retired_path in "docs/NO""W.md" "PRIOR""ITIES.md" "docs/LOCAL_LAUNCH_READ""INESS.md"; do
        local dir
        dir="$(build_doc_fixture)"
        mkdir -p "$dir/$(dirname "$retired_path")"
        touch "$dir/$retired_path"
        run_check "$dir"
        assert_eq "$RUN_EXIT_CODE" "1" "retired doc $retired_path should fail"
        assert_contains "$RUN_STDERR" "$retired_path" "failure should name retired doc $retired_path"
        rm -rf "$dir"
    done
}

test_missing_required_owner_fails() {
    local dir
    dir="$(build_doc_fixture)"
    rm "$dir/PROJECT_OVERVIEW.md"
    run_check "$dir"
    assert_eq "$RUN_EXIT_CODE" "1" "missing PROJECT_OVERVIEW.md should fail"
    assert_contains "$RUN_STDERR" "PROJECT_OVERVIEW.md" "failure should name missing overview"
    rm -rf "$dir"
}

test_missing_launch_status_fails() {
    local dir
    dir="$(build_doc_fixture)"
    cat > "$dir/LAUNCH.md" <<'LAUNCH'
# LAUNCH.md
no status section here
LAUNCH
    run_check "$dir"
    assert_eq "$RUN_EXIT_CODE" "1" "missing LAUNCH STATUS section should fail"
    assert_contains "$RUN_STDERR" "STATUS" "failure should name STATUS section"
    rm -rf "$dir"
}

test_repo_actual_state_passes() {
    RUN_EXIT_CODE=0
    RUN_STDERR="$(bash "$CHECK_SCRIPT" 2>&1 1>/dev/null)" || RUN_EXIT_CODE=$?
    assert_eq "$RUN_EXIT_CODE" "0" "actual repo state should pass the gate"
}

test_v2_owner_surface_passes
test_retired_docs_fail
test_missing_required_owner_fails
test_missing_launch_status_fails
test_repo_actual_state_passes

run_test_summary
