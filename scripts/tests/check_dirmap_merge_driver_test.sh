#!/usr/bin/env bash
# Contract tests for scripts/check_dirmap_merge_driver.sh and
# scripts/setup_git_merge_drivers.sh.
#
# WHY THIS EXISTS (2026-07-19):
# `.gitattributes` sets `**/DIRMAP.md merge=ours` to stop union-merge from
# accumulating contradictory DIRMAP rows (see the 557-row heal commit). But a
# custom merge driver named in .gitattributes does NOTHING unless the driver is
# registered in the clone's git config — git will not run an undefined driver
# and instead falls back to a normal 3-way merge, which CONFLICTS on every
# divergent DIRMAP. Empirically confirmed 2026-07-19: an unregistered `merge=ours`
# produces exit-1 conflicts with markers; a registered one resolves cleanly.
#
# So the .gitattributes line and the git-config registration are two halves of
# one mechanism, and a clone with only the first half is WORSE off than plain
# union. This guard fails when the two halves disagree; setup_git_merge_drivers.sh
# is the one-command fix.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECK="$REPO_ROOT/scripts/check_dirmap_merge_driver.sh"
SETUP="$REPO_ROOT/scripts/setup_git_merge_drivers.sh"

source "$SCRIPT_DIR/lib/test_runner.sh"
source "$SCRIPT_DIR/lib/assertions.sh"

# Build a throwaway git repo whose .gitattributes we control. Git config is
# per-repo, so the driver state is fully isolated from the real clone.
make_repo() {
    local dir="$1" attr_line="$2"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" config user.email t@t.com
    git -C "$dir" config user.name t
    printf '%s\n' "$attr_line" > "$dir/.gitattributes"
}

run_check() {
    local dir="$1"
    RUN_EXIT_CODE=0
    RUN_OUTPUT="$(FJCLOUD_REPO_ROOT="$dir" bash "$CHECK" 2>&1)" || RUN_EXIT_CODE=$?
}

test_passes_when_declared_and_registered() {
    local d; d="$(mktemp -d)"
    make_repo "$d" '**/DIRMAP.md merge=ours'
    git -C "$d" config merge.ours.driver true

    run_check "$d"

    assert_eq "$RUN_EXIT_CODE" "0" "declared in .gitattributes AND registered in config passes"
    assert_contains "$RUN_OUTPUT" "OK" "success output is affirmative"
    rm -rf "$d"
}

# THE CORE REGRESSION: declared but not registered = silent-conflict trap.
test_fails_when_declared_but_not_registered() {
    local d; d="$(mktemp -d)"
    make_repo "$d" '**/DIRMAP.md merge=ours'
    # deliberately do NOT register the driver

    run_check "$d"

    assert_eq "$RUN_EXIT_CODE" "1" "declared without registration must fail"
    assert_contains "$RUN_OUTPUT" "setup_git_merge_drivers.sh" "failure names the one-command fix"
    rm -rf "$d"
}

# Guards against a future revert of the .gitattributes line: the whole heal
# depends on that line existing, so its absence is itself a regression.
test_fails_when_gitattributes_line_missing() {
    local d; d="$(mktemp -d)"
    make_repo "$d" '# no DIRMAP rule here'
    git -C "$d" config merge.ours.driver true

    run_check "$d"

    assert_eq "$RUN_EXIT_CODE" "1" "missing merge=ours declaration must fail"
    assert_contains "$RUN_OUTPUT" "DIRMAP" "failure explains the missing declaration"
    rm -rf "$d"
}

# The setup script is the remediation; prove it actually registers the driver
# and that running it twice is safe (idempotent).
test_setup_registers_driver_idempotently() {
    local d; d="$(mktemp -d)"
    make_repo "$d" '**/DIRMAP.md merge=ours'

    FJCLOUD_REPO_ROOT="$d" bash "$SETUP" >/dev/null 2>&1
    local first; first="$(git -C "$d" config --get merge.ours.driver || true)"
    assert_eq "$first" "true" "setup registers merge.ours.driver=true"

    # Second run must not error and must leave the value unchanged.
    local rc=0
    FJCLOUD_REPO_ROOT="$d" bash "$SETUP" >/dev/null 2>&1 || rc=$?
    assert_eq "$rc" "0" "setup is idempotent (second run exits 0)"
    local second; second="$(git -C "$d" config --get merge.ours.driver || true)"
    assert_eq "$second" "true" "value unchanged after second run"

    # And after setup, the check passes end-to-end.
    run_check "$d"
    assert_eq "$RUN_EXIT_CODE" "0" "check passes after setup runs"
    rm -rf "$d"
}

test_passes_when_declared_and_registered
test_fails_when_declared_but_not_registered
test_fails_when_gitattributes_line_missing
test_setup_registers_driver_idempotently

run_test_summary
