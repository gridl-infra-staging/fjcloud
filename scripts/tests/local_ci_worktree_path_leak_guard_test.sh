#!/usr/bin/env bash
# Regression guard: tracked local-CI scope must not contain host-specific
# worktree-absolute paths.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0
WORKTREE_PATH_PREFIX="/Users/stuart/parallel""_development"

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

WORKTREE_PATH_LEAK_STATUS=0
WORKTREE_PATH_LEAK_FILES=""

capture_worktree_path_leaks() {
    local grep_output
    grep_output="$(
        git -C "$REPO_ROOT" grep -lE "$WORKTREE_PATH_PREFIX" -- \
            . \
            ':(exclude)decisions/**' \
            ':(exclude)docs/decisions/**' \
            ':(exclude)infra/pricing-calculator/stage_*_findings.md' \
            ':(exclude)chats/suggestions/**' \
            2>&1
    )"
    WORKTREE_PATH_LEAK_STATUS=$?
    WORKTREE_PATH_LEAK_FILES="$(printf '%s\n' "$grep_output" | sed '/^$/d')"
}

capture_fixture_worktree_path_leaks() {
    local leaked_file="$1"
    local original_repo_root="$REPO_ROOT"
    local temp_repo

    temp_repo="$(mktemp -d)"
    if [ -z "$temp_repo" ]; then
        fail "failed to create temporary git fixture"
        return
    fi

    (
        cd "$temp_repo" || exit 1
        git init -q || exit 1
        mkdir -p "$(dirname "$leaked_file")" || exit 1
        printf 'fixture leak: %s/fjcloud_dev\n' "$WORKTREE_PATH_PREFIX" > "$leaked_file" || exit 1
        git add "$leaked_file" || exit 1
    )
    if [ "$?" -ne 0 ]; then
        rm -rf "$temp_repo"
        fail "failed to initialize temporary git fixture for $leaked_file"
        return
    fi

    REPO_ROOT="$temp_repo"
    capture_worktree_path_leaks
    REPO_ROOT="$original_repo_root"
    rm -rf "$temp_repo"
}

assert_fixture_leak_is_captured() {
    local leaked_file="$1"

    capture_fixture_worktree_path_leaks "$leaked_file"

    if [ "$WORKTREE_PATH_LEAK_STATUS" -ne 0 ]; then
        fail "fixture leak scan for $leaked_file failed with status $WORKTREE_PATH_LEAK_STATUS:"
        printf '%s\n' "$WORKTREE_PATH_LEAK_FILES" >&2
        return
    fi

    if printf '%s\n' "$WORKTREE_PATH_LEAK_FILES" | grep -Fx "$leaked_file" >/dev/null; then
        pass "tracked fixture leak is reported for $leaked_file"
        return
    fi

    fail "tracked fixture leak was not reported for $leaked_file; got:"
    printf '%s\n' "$WORKTREE_PATH_LEAK_FILES" >&2
}

test_no_tracked_worktree_absolute_paths_in_local_ci_scope() {
    capture_worktree_path_leaks

    if [ "$WORKTREE_PATH_LEAK_STATUS" -eq 1 ]; then
        pass "tracked local-CI scope contains no host-specific worktree paths"
        return
    fi

    if [ "$WORKTREE_PATH_LEAK_STATUS" -ne 0 ]; then
        fail "git grep failed while checking for worktree-absolute path leaks (status $WORKTREE_PATH_LEAK_STATUS):"
        printf '%s\n' "$WORKTREE_PATH_LEAK_FILES" >&2
        return
    fi

    fail "tracked local-CI scope contains worktree-absolute path leaks:"
    printf '%s\n' "$WORKTREE_PATH_LEAK_FILES" >&2
}

main() {
    echo "=== local_ci_worktree_path_leak_guard_test ==="
    assert_fixture_leak_is_captured "chats/stage1_probe.md"
    assert_fixture_leak_is_captured "docs/stage1_probe.md"
    assert_fixture_leak_is_captured "web/tests/stage1_probe.spec.ts"
    test_no_tracked_worktree_absolute_paths_in_local_ci_scope
    echo
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -ne 0 ]; then
        exit 1
    fi
}

main "$@"
