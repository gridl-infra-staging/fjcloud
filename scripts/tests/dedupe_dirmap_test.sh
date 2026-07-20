#!/usr/bin/env bash
# Contract tests for scripts/dedupe_dirmap.py.
#
# WHY THIS EXISTS (measured 2026-07-19):
# `.gitattributes` set `**/DIRMAP.md merge=union`. Union merge keeps the
# differing lines from BOTH sides of a merge, so when two branches each
# regenerated a DIRMAP with different LLM-authored prose, every differing row
# accumulated instead of one winning. infra/api/src/DIRMAP.md ended up with the
# `models` row five times over, each with a different summary. Measured damage
# across the tree: 58 files, 557 surplus rows.
#
# The dangerous part of healing this is that DIRMAP summary cells contain
# EMBEDDED NEWLINES — a row is not a line. A naive line-based dedupe would
# silently shred the 197 uncorrupted files. The byte-identical test below is
# the guard against that.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEDUPE="$REPO_ROOT/scripts/dedupe_dirmap.py"

source "$SCRIPT_DIR/lib/test_runner.sh"
source "$SCRIPT_DIR/lib/assertions.sh"

run_dedupe() {
    RUN_EXIT_CODE=0
    RUN_OUTPUT="$(python3 "$DEDUPE" "$@" 2>&1)" || RUN_EXIT_CODE=$?
}

test_removes_duplicate_single_line_rows_keeping_first() {
    local tmpdir; tmpdir="$(mktemp -d)"
    cat > "$tmpdir/DIRMAP.md" <<'FIXTURE'
<!-- [scrai:start] -->
## src

| File | Summary |
| --- | --- |
| models | FIRST summary. |
| other.rs | Untouched. |
| models | SECOND summary. |
| models | THIRD summary. |
<!-- [scrai:end] -->
FIXTURE

    run_dedupe "$tmpdir/DIRMAP.md"

    assert_eq "$RUN_EXIT_CODE" "0" "dedupe exits 0"
    # Keep-first is the policy: all competing summaries are equally plausible
    # LLM prose, so the tie-break must at least be deterministic.
    assert_contains "$(cat "$tmpdir/DIRMAP.md")" "FIRST summary." "first occurrence is kept"
    local models_count
    models_count="$(grep -c '^| models |' "$tmpdir/DIRMAP.md" || true)"
    assert_eq "$models_count" "1" "exactly one models row survives"
    assert_contains "$(cat "$tmpdir/DIRMAP.md")" "Untouched." "unrelated rows survive"
    assert_contains "$(cat "$tmpdir/DIRMAP.md")" "[scrai:end]" "trailing scrai marker survives"
    rm -rf "$tmpdir"
}

# THE DANGEROUS CASE: summary cells span multiple lines. A row is not a line.
test_preserves_multiline_cells() {
    local tmpdir; tmpdir="$(mktemp -d)"
    cat > "$tmpdir/DIRMAP.md" <<'FIXTURE'
<!-- [scrai:start] -->
## lib

| File | Summary |
| --- | --- |
| assertions.sh | Shared assertions.

Callers must define:
  pass "<message>"
  fail "<message>". |
| helper.sh | Simple one-liner. |
| assertions.sh | A DIFFERENT competing summary. |
<!-- [scrai:end] -->
FIXTURE

    run_dedupe "$tmpdir/DIRMAP.md"

    # Assert the script actually RAN. Without this, a missing/broken script
    # leaves the fixture untouched and every "is preserved" assertion below
    # passes for the wrong reason.
    assert_eq "$RUN_EXIT_CODE" "0" "dedupe exits 0 on a multi-line-cell file"
    local body; body="$(cat "$tmpdir/DIRMAP.md")"
    assert_contains "$body" 'pass "<message>"' "multi-line cell body is preserved verbatim"
    assert_contains "$body" 'fail "<message>". |' "multi-line cell terminator is preserved"
    assert_contains "$body" "Simple one-liner." "following row survives"
    assert_not_contains "$body" "A DIFFERENT competing summary." "later duplicate is dropped"
    rm -rf "$tmpdir"
}

# THE REGRESSION GUARD: a clean file must come back byte-for-byte identical.
test_clean_file_is_byte_identical() {
    local tmpdir; tmpdir="$(mktemp -d)"
    cat > "$tmpdir/DIRMAP.md" <<'FIXTURE'
<!-- [scrai:start] -->
## src

| File | Summary |
| --- | --- |
| a.rs | Summary A.

With a continuation line. |
| b.rs | Summary B. |
<!-- [scrai:end] -->
FIXTURE
    cp "$tmpdir/DIRMAP.md" "$tmpdir/expected.md"

    run_dedupe "$tmpdir/DIRMAP.md"

    # Same false-positive guard: a script that never ran trivially "preserves"
    # the file. Require a real successful run before crediting the result.
    assert_eq "$RUN_EXIT_CODE" "0" "dedupe exits 0 on a clean file"
    if diff -q "$tmpdir/DIRMAP.md" "$tmpdir/expected.md" >/dev/null 2>&1; then
        pass "an uncorrupted DIRMAP is returned byte-identical"
    else
        fail "dedupe mutated a clean file: $(diff "$tmpdir/expected.md" "$tmpdir/DIRMAP.md" | head -10)"
    fi
    rm -rf "$tmpdir"
}

test_reports_what_it_changed() {
    local tmpdir; tmpdir="$(mktemp -d)"
    cat > "$tmpdir/DIRMAP.md" <<'FIXTURE'
<!-- [scrai:start] -->
| File | Summary |
| --- | --- |
| x | one |
| x | two |
<!-- [scrai:end] -->
FIXTURE

    run_dedupe "$tmpdir/DIRMAP.md"

    # A silent bulk rewrite is unauditable; the script must say what it removed.
    assert_contains "$RUN_OUTPUT" "1" "output reports the number of rows removed"
    rm -rf "$tmpdir"
}

test_check_mode_does_not_modify() {
    local tmpdir; tmpdir="$(mktemp -d)"
    cat > "$tmpdir/DIRMAP.md" <<'FIXTURE'
<!-- [scrai:start] -->
| File | Summary |
| --- | --- |
| x | one |
| x | two |
<!-- [scrai:end] -->
FIXTURE
    cp "$tmpdir/DIRMAP.md" "$tmpdir/expected.md"

    run_dedupe --check "$tmpdir/DIRMAP.md"

    assert_eq "$RUN_EXIT_CODE" "1" "--check exits non-zero when duplicates exist"
    if diff -q "$tmpdir/DIRMAP.md" "$tmpdir/expected.md" >/dev/null 2>&1; then
        pass "--check leaves the file untouched"
    else
        fail "--check modified the file"
    fi
    rm -rf "$tmpdir"
}

test_removes_duplicate_single_line_rows_keeping_first
test_preserves_multiline_cells
test_clean_file_is_byte_identical
test_reports_what_it_changed
test_check_mode_does_not_modify

run_test_summary
