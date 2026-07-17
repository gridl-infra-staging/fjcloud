#!/usr/bin/env bash
# compose_project_test.sh — Coverage for the COMPOSE_PROJECT_NAME helper.
#
# Failure mode (anchored 2026-05-31): docker compose defaults
# COMPOSE_PROJECT_NAME to the basename of the working directory. Two
# fjcloud worktrees both at `/.../fjcloud_dev` therefore named their
# stacks `fjcloud_dev` and silently clobbered each other on `docker
# compose up` — even though port ranges were different. The fix is to
# derive the project name from the FULL worktree path so different
# worktrees never share a name.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

test_main_worktree_produces_a_predictable_name() {
    # shellcheck disable=SC1091
    source "$REPO_ROOT/scripts/lib/compose_project.sh"
    local result
    result=$(resolve_compose_project_name "/Users/stuart/repos/gridl-infra-dev/fjcloud_dev")
    case "$result" in
        fjcloud_gridl-infra-dev_fjcloud_dev) pass "main worktree resolves to fjcloud_gridl-infra-dev_fjcloud_dev" ;;
        *) fail "expected fjcloud_gridl-infra-dev_fjcloud_dev, got '$result'" ;;
    esac
}

test_parallel_worktree_produces_a_different_name() {
    # shellcheck disable=SC1091
    source "$REPO_ROOT/scripts/lib/compose_project.sh"
    local main_name parallel_name
    main_name=$(resolve_compose_project_name "/Users/stuart/repos/gridl-infra-dev/fjcloud_dev")
    parallel_name=$(resolve_compose_project_name "/tmp/parallel_development_fixture/fjcloud_dev/may25_151pm_wave_b_2g/fjcloud_dev")
    if [ "$main_name" = "$parallel_name" ]; then
        fail "main and parallel worktrees collided on '$main_name'"
    else
        pass "parallel worktree gets a distinct name (got '$parallel_name')"
    fi
}

# Docker compose project names must match `[a-z0-9][a-z0-9_-]*`. Names
# with uppercase, dots, or spaces would silently fall back to "_" in
# container names — losing the diagnostic value of the rename.
test_resolved_name_is_lowercase_and_safe() {
    # shellcheck disable=SC1091
    source "$REPO_ROOT/scripts/lib/compose_project.sh"
    local result
    result=$(resolve_compose_project_name "/Users/Stuart/Some Repo (test)/Fjcloud_DEV")
    case "$result" in
        [a-z0-9]*)
            # ok, first char is lowercase or digit
            ;;
        *)
            fail "name '$result' must start with [a-z0-9]"
            return
            ;;
    esac
    # Reject any char outside [a-z0-9_-].
    if printf '%s' "$result" | grep -qE '[^a-z0-9_-]'; then
        fail "name '$result' contains chars outside [a-z0-9_-]"
        return
    fi
    pass "uppercase/punctuated path sanitizes to '$result'"
}

# Operator override path: callers may force a specific COMPOSE_PROJECT_NAME
# (e.g. to share a stack across worktrees). Honor it instead of overwriting.
test_explicit_compose_project_name_is_respected() {
    # shellcheck disable=SC1091
    source "$REPO_ROOT/scripts/lib/compose_project.sh"
    local result
    result=$(COMPOSE_PROJECT_NAME=my_custom_name resolve_compose_project_name "/Users/stuart/repos/gridl-infra-dev/fjcloud_dev")
    case "$result" in
        my_custom_name) pass "explicit COMPOSE_PROJECT_NAME overrides the path-derived default" ;;
        *) fail "expected 'my_custom_name', got '$result'" ;;
    esac
}

# Wiring assertion: local-dev-up.sh must export COMPOSE_PROJECT_NAME via
# resolve_compose_project_name BEFORE any `docker compose` call. Without
# the export, the helper exists but isn't used.
test_local_dev_up_exports_compose_project_name() {
    local script
    script="$(cat "$REPO_ROOT/scripts/local-dev-up.sh")"

    assert_contains_helper() {
        local hay="$1" needle="$2" msg="$3"
        case "$hay" in
            *"$needle"*) pass "$msg" ;;
            *) fail "$msg — expected '$needle' in script" ;;
        esac
    }

    assert_contains_helper "$script" "resolve_compose_project_name" \
        "local-dev-up.sh sources/uses the resolver"
    assert_contains_helper "$script" "export COMPOSE_PROJECT_NAME" \
        "local-dev-up.sh exports COMPOSE_PROJECT_NAME so docker compose picks it up"
}

test_local_dev_down_exports_compose_project_name() {
    local script
    script="$(cat "$REPO_ROOT/scripts/local-dev-down.sh")"
    case "$script" in
        *"resolve_compose_project_name"*) pass "local-dev-down.sh uses the resolver (so it tears down the SAME project the up script started)" ;;
        *) fail "local-dev-down.sh does not source resolve_compose_project_name — it would tear down a different project" ;;
    esac
}

main() {
    echo "=== compose_project_test.sh ==="
    echo ""

    test_main_worktree_produces_a_predictable_name
    test_parallel_worktree_produces_a_different_name
    test_resolved_name_is_lowercase_and_safe
    test_explicit_compose_project_name_is_respected
    test_local_dev_up_exports_compose_project_name
    test_local_dev_down_exports_compose_project_name

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
