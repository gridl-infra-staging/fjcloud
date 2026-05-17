#!/usr/bin/env bash
# Contract tests for scripts/git_push_with_sync.sh and its runbook adoption markers.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER_SCRIPT="$REPO_ROOT/scripts/git_push_with_sync.sh"
RUNBOOK_PATH="$REPO_ROOT/docs/runbooks/git_push_with_sync.md"
INFRA_DEPLOY_RUNBOOK_PATH="$REPO_ROOT/docs/runbooks/infra-deploy.md"

source "$REPO_ROOT/scripts/tests/lib/assertions.sh"
source "$REPO_ROOT/scripts/tests/lib/test_runner.sh"

load_required_file() {
    local path="$1"
    local description="$2"

    if [[ ! -f "$path" ]]; then
        fail "$description"
        return 1
    fi

    cat "$path"
}

new_mock_tools_dir() {
    local mock_dir
    mock_dir="$(mktemp -d)"

    cat > "$mock_dir/git" <<'MOCK_GIT'
#!/usr/bin/env bash
set -euo pipefail

log_path="${GIT_PUSH_WITH_SYNC_CALL_LOG:?}"

echo "git:$*" >> "$log_path"

if [[ "${1:-}" == "rev-parse" && "${2:-}" == "--abbrev-ref" && "${3:-}" == "HEAD" ]]; then
    echo "${MOCK_GIT_BRANCH:-main}"
    exit 0
fi

if [[ "${1:-}" == "push" ]]; then
    exit "${MOCK_GIT_PUSH_EXIT:-0}"
fi

echo "unexpected git invocation: $*" >&2
exit 99
MOCK_GIT

    cat > "$mock_dir/debbie" <<'MOCK_DEBBIE'
#!/usr/bin/env bash
set -euo pipefail

log_path="${GIT_PUSH_WITH_SYNC_CALL_LOG:?}"
echo "debbie:$*" >> "$log_path"

if [[ "${1:-}" == "sync" && "${2:-}" == "staging" && "${MOCK_DEBBIE_FAIL_STAGING:-0}" == "1" ]]; then
    exit 41
fi

if [[ "${1:-}" == "sync" && "${2:-}" == "prod" && "${MOCK_DEBBIE_FAIL_PROD:-0}" == "1" ]]; then
    exit 42
fi

exit 0
MOCK_DEBBIE

    chmod +x "$mock_dir/git" "$mock_dir/debbie"
    echo "$mock_dir"
}

run_wrapper_with_mocks() {
    local branch="$1"
    local git_push_exit="$2"
    local debbie_fail_staging="$3"
    local debbie_fail_prod="$4"
    local skip_sync="$5"
    local call_log="$6"
    local debbie_bin_override="$7"
    shift 7

    local mock_dir
    mock_dir="$(new_mock_tools_dir)"

    local exit_code=0
    GIT_PUSH_WITH_SYNC_CALL_LOG="$call_log" \
    MOCK_GIT_BRANCH="$branch" \
    MOCK_GIT_PUSH_EXIT="$git_push_exit" \
    MOCK_DEBBIE_FAIL_STAGING="$debbie_fail_staging" \
    MOCK_DEBBIE_FAIL_PROD="$debbie_fail_prod" \
    SKIP_DEBBIE_SYNC="$skip_sync" \
    DEBBIE_BIN="$debbie_bin_override" \
    PATH="$mock_dir:$PATH" \
    bash "$WRAPPER_SCRIPT" "$@" >/dev/null 2>&1 || exit_code=$?

    rm -rf "$mock_dir"
    return "$exit_code"
}

read_calls() {
    local call_log="$1"
    if [[ -f "$call_log" ]]; then
        cat "$call_log"
    fi
}

test_wrapper_forwards_git_push_args_and_skips_sync_off_main() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local call_log="$tmp_dir/calls.log"

    local exit_code=0
    run_wrapper_with_mocks "feature/demo" "0" "0" "0" "0" "$call_log" "" origin HEAD:main --force-with-lease || exit_code=$?

    local calls
    calls="$(read_calls "$call_log")"

    assert_eq "$exit_code" "0" "wrapper should preserve successful git push exit code"
    assert_contains "$calls" "git:push origin HEAD:main --force-with-lease" "wrapper should forward git push arguments unchanged"
    assert_not_contains "$calls" "debbie:sync staging" "wrapper should not sync mirrors off main branch"
    assert_not_contains "$calls" "debbie:sync prod" "wrapper should not sync mirrors off main branch"

    rm -rf "$tmp_dir"
}

test_wrapper_runs_staging_then_prod_sync_on_main() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local call_log="$tmp_dir/calls.log"

    local exit_code=0
    run_wrapper_with_mocks "main" "0" "0" "0" "0" "$call_log" "" origin main || exit_code=$?

    local calls
    calls="$(read_calls "$call_log")"

    assert_eq "$exit_code" "0" "wrapper should exit 0 when push and sync succeed on main"
    assert_contains "$calls" "git:push origin main" "wrapper should execute git push before sync steps"
    assert_contains "$calls" "debbie:sync staging" "wrapper should sync staging mirror on main"
    assert_contains "$calls" "debbie:sync prod" "wrapper should sync prod mirror on main"

    local staging_line
    local prod_line
    if [[ -f "$call_log" ]]; then
        staging_line="$(grep -n "debbie:sync staging" "$call_log" | cut -d: -f1 | head -n 1)"
        prod_line="$(grep -n "debbie:sync prod" "$call_log" | cut -d: -f1 | head -n 1)"
    else
        staging_line=""
        prod_line=""
    fi
    if [[ -n "$staging_line" && -n "$prod_line" && "$staging_line" -lt "$prod_line" ]]; then
        pass "wrapper should run debbie sync staging before debbie sync prod"
    else
        fail "wrapper should run debbie sync staging before debbie sync prod"
    fi

    rm -rf "$tmp_dir"
}

test_wrapper_supports_skip_debbie_sync_opt_out() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local call_log="$tmp_dir/calls.log"

    local exit_code=0
    run_wrapper_with_mocks "main" "0" "0" "0" "1" "$call_log" "" origin main || exit_code=$?

    local calls
    calls="$(read_calls "$call_log")"

    assert_eq "$exit_code" "0" "SKIP_DEBBIE_SYNC=1 should not change successful push exit code"
    assert_contains "$calls" "git:push origin main" "wrapper should still run git push when sync is skipped"
    assert_not_contains "$calls" "debbie:sync staging" "SKIP_DEBBIE_SYNC=1 should skip staging sync"
    assert_not_contains "$calls" "debbie:sync prod" "SKIP_DEBBIE_SYNC=1 should skip prod sync"

    rm -rf "$tmp_dir"
}

test_wrapper_keeps_git_push_exit_contract_when_sync_fails_best_effort() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"

    local push_fail_calls="$tmp_dir/push-fail.log"
    local exit_code=0
    run_wrapper_with_mocks "main" "17" "0" "0" "0" "$push_fail_calls" "" origin main || exit_code=$?

    local calls
    calls="$(read_calls "$push_fail_calls")"

    assert_eq "$exit_code" "17" "wrapper should propagate git push non-zero exit code"
    assert_not_contains "$calls" "debbie:sync staging" "wrapper should not sync when git push fails"
    assert_not_contains "$calls" "debbie:sync prod" "wrapper should not sync when git push fails"

    local sync_fail_calls="$tmp_dir/sync-fail.log"
    exit_code=0
    run_wrapper_with_mocks "main" "0" "1" "0" "0" "$sync_fail_calls" "" origin main || exit_code=$?

    calls="$(read_calls "$sync_fail_calls")"

    assert_eq "$exit_code" "0" "wrapper should remain successful when debbie sync fails"
    assert_contains "$calls" "debbie:sync staging" "wrapper should attempt staging sync even when it fails"
    assert_contains "$calls" "debbie:sync prod" "wrapper should continue to prod sync after staging sync failure"

    rm -rf "$tmp_dir"
}

test_runbook_documents_wrapper_contract() {
    local content
    content="$(load_required_file "$RUNBOOK_PATH" "git push sync runbook should exist at docs/runbooks/git_push_with_sync.md")" || return

    assert_contains "$content" "scripts/git_push_with_sync.sh" "runbook should name the wrapper script path"
    assert_contains "$content" "git push" "runbook should state git push remains the authoritative action"
    assert_contains "$content" "SKIP_DEBBIE_SYNC=1" "runbook should document sync opt-out env var"
    assert_contains "$content" "DEBBIE_BIN=" "runbook should document debbie binary override"
    assert_contains "$content" "main" "runbook should describe main-only sync behavior"
    assert_contains "$content" "debbie sync staging" "runbook should document staging sync command"
    assert_contains "$content" "debbie sync prod" "runbook should document prod sync command"
    assert_contains "$content" "best-effort" "runbook should document best-effort sync warnings"
    assert_contains "$content" "does not use a client-side post-push hook" "runbook should document why post-push hooks are not used"
}

test_wrapper_uses_debbie_bin_override_when_debbie_not_on_path() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local mock_dir
    mock_dir="$(new_mock_tools_dir)"
    rm -f "$mock_dir/debbie"
    local fallback_debbie="$tmp_dir/fallback-debbie"
    local call_log="$tmp_dir/calls.log"

    cat > "$fallback_debbie" <<'MOCK_DEBBIE_FALLBACK'
#!/usr/bin/env bash
set -euo pipefail
log_path="${GIT_PUSH_WITH_SYNC_CALL_LOG:?}"
echo "debbie:$*" >> "$log_path"
exit 0
MOCK_DEBBIE_FALLBACK
    chmod +x "$fallback_debbie"

    local exit_code=0
    GIT_PUSH_WITH_SYNC_CALL_LOG="$call_log" \
    MOCK_GIT_BRANCH="main" \
    MOCK_GIT_PUSH_EXIT="0" \
    SKIP_DEBBIE_SYNC="0" \
    DEBBIE_BIN="$fallback_debbie" \
    PATH="$mock_dir:$PATH" \
    bash "$WRAPPER_SCRIPT" origin main >/dev/null 2>&1 || exit_code=$?

    local calls
    calls="$(read_calls "$call_log")"

    assert_eq "$exit_code" "0" "wrapper should succeed when using DEBBIE_BIN override"
    assert_contains "$calls" "git:push origin main" "wrapper should still execute git push"
    assert_contains "$calls" "debbie:sync staging" "wrapper should run staging sync through DEBBIE_BIN override"
    assert_contains "$calls" "debbie:sync prod" "wrapper should run prod sync through DEBBIE_BIN override"

    rm -rf "$mock_dir" "$tmp_dir"
}

test_infra_deploy_runbook_points_to_canonical_wrapper_contract() {
    local content
    content="$(load_required_file "$INFRA_DEPLOY_RUNBOOK_PATH" "infra deploy runbook should exist at docs/runbooks/infra-deploy.md")" || return

    assert_contains "$content" "docs/runbooks/git_push_with_sync.md" "infra deploy runbook should point to the canonical wrapper contract"
}

echo "=== git push with sync contract tests ==="
test_wrapper_forwards_git_push_args_and_skips_sync_off_main
test_wrapper_runs_staging_then_prod_sync_on_main
test_wrapper_supports_skip_debbie_sync_opt_out
test_wrapper_keeps_git_push_exit_contract_when_sync_fails_best_effort
test_wrapper_uses_debbie_bin_override_when_debbie_not_on_path
test_runbook_documents_wrapper_contract
test_infra_deploy_runbook_points_to_canonical_wrapper_contract
run_test_summary
