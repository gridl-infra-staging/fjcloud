#!/usr/bin/env bash
# Static contract test for .github/workflows/outside_aws_health.yml.
#
# Red-stage expectation before implementation:
# - .github/workflows/outside_aws_health.yml does not exist yet.
# - This test must fail for that missing owner.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW_FILE="$REPO_ROOT/.github/workflows/outside_aws_health.yml"

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

_grep() {
    local flags=()
    while [[ $# -gt 1 && "$1" == -* ]]; do
        flags+=("$1")
        shift
    done

    local pattern="$1"
    shift

    pattern="${pattern//\\s/[[:space:]]}"
    if [[ ${#flags[@]} -gt 0 ]]; then
        grep -E "${flags[@]}" -- "$pattern" "$@"
    else
        grep -E -- "$pattern" "$@"
    fi
}

assert_file_exists() {
    local path="$1"
    local msg="$2"
    if [[ -f "$path" ]]; then
        pass "$msg"
    else
        fail "$msg (missing file: $path)"
    fi
}

assert_contains_regex() {
    local pattern="$1"
    local msg="$2"
    if _grep -n "$pattern" "$WORKFLOW_FILE" >/dev/null 2>&1; then
        pass "$msg"
    else
        fail "$msg (pattern not found: $pattern)"
    fi
}

assert_not_contains_regex() {
    local pattern="$1"
    local msg="$2"
    if _grep -n "$pattern" "$WORKFLOW_FILE" >/dev/null 2>&1; then
        fail "$msg (unexpected pattern found: $pattern)"
    else
        pass "$msg"
    fi
}

main() {
    echo "=== outside_aws_health_workflow_test.sh ==="
    echo ""

    assert_file_exists "$WORKFLOW_FILE" "outside-AWS workflow file exists"
    assert_contains_regex '^on:' "workflow declares trigger section"
    assert_contains_regex '^\s*schedule:' "workflow has schedule trigger"
    assert_contains_regex "cron:\s*'\*/5 \* \* \* \*'" "workflow runs on 5-minute schedule"
    assert_contains_regex '^\s*workflow_dispatch:' "workflow has workflow_dispatch trigger"
    assert_contains_regex 'uses:\s+actions/checkout@' "workflow checks out repository"
    assert_contains_regex 'run:\s+bash scripts/canary/outside_aws_health_check\.sh' "workflow runs outside-AWS owner script"
    assert_not_contains_regex 'curl\s+https://cloud\.flapjack\.foo/health' "workflow must not inline cloud curl logic"
    assert_not_contains_regex 'curl\s+https://api\.flapjack\.foo/health' "workflow must not inline api curl logic"

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    [[ "$FAIL_COUNT" -eq 0 ]]
}

main "$@"
