#!/usr/bin/env bash
# Contract tests for scripts/check_doc_surface_allowlist.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECK_SCRIPT="$REPO_ROOT/scripts/check_doc_surface_allowlist.sh"

source "$SCRIPT_DIR/lib/test_runner.sh"
source "$SCRIPT_DIR/lib/assertions.sh"

run_check() {
    local doc_root="$1"
    RUN_EXIT_CODE=0
    RUN_OUTPUT="$(FJCLOUD_DOC_ROOT="$doc_root" bash "$CHECK_SCRIPT" 2>&1)" || RUN_EXIT_CODE=$?
}

write_allowlist() {
    local doc_root="$1"
    shift
    mkdir -p "$doc_root/.scrai"
    printf '%s\n' "$@" > "$doc_root/.scrai/allowed_top_docs.txt"
}

test_allows_canonical_root_docs_and_disciplines_exception() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    write_allowlist "$tmpdir" \
        "README.md" \
        "PROJECT_OVERVIEW.md" \
        "ROADMAP.md" \
        "LAUNCH.md" \
        "docs/disciplines/"
    touch "$tmpdir/README.md" "$tmpdir/PROJECT_OVERVIEW.md" "$tmpdir/ROADMAP.md" "$tmpdir/LAUNCH.md"
    mkdir -p "$tmpdir/docs/disciplines" "$tmpdir/docs/private" "$tmpdir/docs/live-state" "$tmpdir/docs/runbooks/evidence"
    touch "$tmpdir/docs/disciplines/recommending_followups.md"
    touch "$tmpdir/docs/private/secret.md" "$tmpdir/docs/live-state/current.md" "$tmpdir/docs/runbooks/evidence/proof.md"

    run_check "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "0" "canonical root docs and explicit docs/disciplines exception pass"
    assert_contains "$RUN_OUTPUT" "OK: doc surface matches .scrai/allowed_top_docs.txt" "success output should name allowlist"
    rm -rf "$tmpdir"
}

test_rejects_unallowlisted_root_doc() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    write_allowlist "$tmpdir" "README.md" "PROJECT_OVERVIEW.md"
    touch "$tmpdir/README.md" "$tmpdir/PROJECT_OVERVIEW.md" "$tmpdir/PRIOR""ITIES.md"

    run_check "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" "unallowlisted root doc should fail"
    assert_contains "$RUN_OUTPUT" "unexpected doc surface PRIOR""ITIES.md" "failure should name unexpected root doc"
    rm -rf "$tmpdir"
}

test_rejects_missing_allowlisted_doc() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    write_allowlist "$tmpdir" "README.md" "PROJECT_OVERVIEW.md"
    touch "$tmpdir/README.md"

    run_check "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" "missing allowlisted doc should fail"
    assert_contains "$RUN_OUTPUT" "allowlisted doc is missing PROJECT_OVERVIEW.md" "failure should name missing allowlist entry"
    rm -rf "$tmpdir"
}

test_rejects_retired_root_allowlist_owner() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    cat > "$tmpdir/allowed_top_docs.txt" <<'EOF_ALLOWLIST'
README.md
EOF_ALLOWLIST
    touch "$tmpdir/README.md"

    run_check "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" "root allowlist owner should not be accepted"
    assert_contains "$RUN_OUTPUT" ".scrai/allowed_top_docs.txt" "failure should name canonical allowlist owner"
    rm -rf "$tmpdir"
}

echo "=== doc surface allowlist tests ==="
test_allows_canonical_root_docs_and_disciplines_exception
test_rejects_unallowlisted_root_doc
test_rejects_missing_allowlisted_doc
test_rejects_retired_root_allowlist_owner
run_test_summary
