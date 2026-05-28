#!/usr/bin/env bash
# Tests for scripts/check_status_doc_consistency.sh
#
# The check asserts: NOW.md's "Last updated:" date is at least as recent as
# the most recent ### YYYY-MM-DD heading under LAUNCH.md's ## STATUS section.
#
# Why this matters: the project had drift where NOW.md was stale relative to
# a fresher LAUNCH.md ## STATUS entry (e.g. NOW.md saying announce-gate
# READY while LAUNCH.md's most recent verdict was NOT-READY). That's exactly
# the doc-SSOT smell this gate catches.
#
# The check is content-deterministic (no AWS / no network), so testing it is
# pure filesystem isolation. Each test stages a temporary repo-like dir with
# crafted NOW.md and LAUNCH.md, runs the script with FJCLOUD_DOC_DIR pointed
# at it, and asserts the expected exit code + stderr.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECK_SCRIPT="$REPO_ROOT/scripts/check_status_doc_consistency.sh"

source "$SCRIPT_DIR/lib/test_runner.sh"
source "$SCRIPT_DIR/lib/assertions.sh"

# Build a tmpdir with `docs/NOW.md` and `LAUNCH.md` under given content.
# `now_date`: ISO date string (or any text) for NOW.md's "Last updated:" line.
# `status_date`: ISO date string for LAUNCH.md's most recent ### YYYY-MM-DD heading.
build_doc_fixture() {
    local now_date="$1" status_date="$2"
    local tmpdir; tmpdir="$(mktemp -d)"
    mkdir -p "$tmpdir/docs"
    cat > "$tmpdir/docs/NOW.md" <<NOW
# What to work on next

**Last updated:** $now_date (test fixture)

## Stage
test fixture stage line
NOW
    cat > "$tmpdir/LAUNCH.md" <<LAUNCH
# LAUNCH.md — test fixture

## STATUS — append at end of each work session

### $status_date (B1 verdict fixture)
- fixture entry

### 2026-05-01 (earlier entry)
- earlier fixture entry
LAUNCH
    echo "$tmpdir"
}

run_check() {
    local doc_root="$1"
    RUN_EXIT_CODE=0
    RUN_STDERR="$(FJCLOUD_DOC_ROOT="$doc_root" bash "$CHECK_SCRIPT" 2>&1 1>/dev/null)" || RUN_EXIT_CODE=$?
    RUN_STDOUT="$(FJCLOUD_DOC_ROOT="$doc_root" bash "$CHECK_SCRIPT" 2>/dev/null)" || true
}

# ============================================================
# Test 1 — NOW.md fresher than LAUNCH.md STATUS → pass.
# ============================================================
test_now_fresher_passes() {
    local dir; dir="$(build_doc_fixture "2026-05-28 PM" "2026-05-27")"
    run_check "$dir"
    assert_eq "$RUN_EXIT_CODE" "0" "NOW newer than STATUS should pass"
}

# ============================================================
# Test 2 — NOW.md same-date as LAUNCH.md STATUS → pass (boundary).
# ============================================================
test_now_same_date_passes() {
    local dir; dir="$(build_doc_fixture "2026-05-27 PM" "2026-05-27")"
    run_check "$dir"
    assert_eq "$RUN_EXIT_CODE" "0" "NOW same date as STATUS should pass"
}

# ============================================================
# Test 3 — NOW.md older than LAUNCH.md STATUS → fail with explanation.
# ============================================================
test_now_older_fails() {
    local dir; dir="$(build_doc_fixture "2026-05-25 PM" "2026-05-27")"
    run_check "$dir"
    assert_eq "$RUN_EXIT_CODE" "1" "NOW older than STATUS should exit 1"
    assert_contains "$RUN_STDERR" "NOW.md" "failure message should name NOW.md"
    assert_contains "$RUN_STDERR" "2026-05-25" "failure message should surface NOW's date"
    assert_contains "$RUN_STDERR" "2026-05-27" "failure message should surface STATUS's date"
}

# ============================================================
# Test 4 — missing NOW.md fails with a usable message (not a stack trace).
# ============================================================
test_missing_now_fails_cleanly() {
    local tmpdir; tmpdir="$(mktemp -d)"
    mkdir -p "$tmpdir/docs"
    cat > "$tmpdir/LAUNCH.md" <<'LAUNCH'
## STATUS
### 2026-05-27 (fixture)
LAUNCH
    run_check "$tmpdir"
    assert_eq "$RUN_EXIT_CODE" "1" "missing NOW.md should exit 1"
    assert_contains "$RUN_STDERR" "NOW.md" "missing-NOW.md error should mention NOW.md"
}

# ============================================================
# Test 5 — LAUNCH.md without ## STATUS section fails clearly.
# ============================================================
test_missing_status_section_fails() {
    local tmpdir; tmpdir="$(mktemp -d)"
    mkdir -p "$tmpdir/docs"
    cat > "$tmpdir/docs/NOW.md" <<'NOW'
**Last updated:** 2026-05-27 PM
NOW
    cat > "$tmpdir/LAUNCH.md" <<'LAUNCH'
# LAUNCH.md
no STATUS section here
LAUNCH
    run_check "$tmpdir"
    assert_eq "$RUN_EXIT_CODE" "1" "missing STATUS section should exit 1"
    assert_contains "$RUN_STDERR" "STATUS" "error should mention STATUS section"
}

# ============================================================
# Test 6 — NOW.md missing 'Last updated:' line fails clearly.
# ============================================================
test_missing_last_updated_fails() {
    local tmpdir; tmpdir="$(mktemp -d)"
    mkdir -p "$tmpdir/docs"
    cat > "$tmpdir/docs/NOW.md" <<'NOW'
# What to work on next
no last updated line
NOW
    cat > "$tmpdir/LAUNCH.md" <<'LAUNCH'
## STATUS
### 2026-05-27 (fixture)
LAUNCH
    run_check "$tmpdir"
    assert_eq "$RUN_EXIT_CODE" "1" "missing Last updated line should exit 1"
    assert_contains "$RUN_STDERR" "Last updated" "error should mention the missing field"
}

# ============================================================
# Test 7 — script runs against the ACTUAL repo and currently passes.
# This is the canary: if I land an edit that breaks consistency, this test
# fails *here*, before reaching CI. Self-host check.
# ============================================================
test_repo_actual_state_passes() {
    RUN_EXIT_CODE=0
    RUN_STDERR="$(bash "$CHECK_SCRIPT" 2>&1 1>/dev/null)" || RUN_EXIT_CODE=$?
    assert_eq "$RUN_EXIT_CODE" "0" "actual repo state should pass the gate"
}

test_now_fresher_passes
test_now_same_date_passes
test_now_older_fails
test_missing_now_fails_cleanly
test_missing_status_section_fails
test_missing_last_updated_fails
test_repo_actual_state_passes

run_test_summary
