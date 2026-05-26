#!/usr/bin/env bash
# Contract tests for .debbie/post-sync.sh commit/push behavior after strip.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK_SCRIPT="$REPO_ROOT/.debbie/post-sync.sh"

source "$REPO_ROOT/scripts/tests/lib/assertions.sh"
source "$REPO_ROOT/scripts/tests/lib/test_runner.sh"

new_mock_tools_dir() {
    local mock_dir
    mock_dir="$(mktemp -d)"

    cat > "$mock_dir/git" <<'MOCK_GIT'
#!/usr/bin/env bash
set -euo pipefail

echo "git:$*" >> "${POST_SYNC_HOOK_CALL_LOG:?}"
"${REAL_GIT_BIN:?}" "$@"
MOCK_GIT

    cat > "$mock_dir/python3" <<'MOCK_PYTHON3'
#!/usr/bin/env bash
set -euo pipefail

echo "python3:$*" >> "${POST_SYNC_HOOK_CALL_LOG:?}"

if [[ "${1:-}" == "-m" && "${2:-}" == "matt" && "${3:-}" == "scrai" && "${4:-}" == "strip" && "${5:-}" == "--help" ]]; then
    exit 0
fi

if [[ "${1:-}" == "-m" && "${2:-}" == "matt" && "${3:-}" == "scrai" && "${4:-}" == "strip" ]]; then
    target_root="${5:?}"
    if [[ "${MOCK_STRIP_MODE:-noop}" == "dirty" ]]; then
        printf "strip mutation\n" > "$target_root/.strip_generated_change"
    fi
    exit 0
fi

echo "unexpected python3 invocation: $*" >&2
exit 97
MOCK_PYTHON3

    cat > "$mock_dir/matt" <<'MOCK_MATT'
#!/usr/bin/env bash
set -euo pipefail

echo "matt:$*" >> "${POST_SYNC_HOOK_CALL_LOG:?}"

if [[ "${1:-}" == "scrai" && "${2:-}" == "strip" && "${3:-}" == "--help" ]]; then
    exit 0
fi

if [[ "${1:-}" == "scrai" && "${2:-}" == "strip" ]]; then
    target_root="${3:?}"
    if [[ "${MOCK_STRIP_MODE:-noop}" == "dirty" ]]; then
        printf "strip mutation\n" > "$target_root/.strip_generated_change"
    fi
    exit 0
fi

echo "unexpected matt invocation: $*" >&2
exit 98
MOCK_MATT

    chmod +x "$mock_dir/git" "$mock_dir/python3" "$mock_dir/matt"
    echo "$mock_dir"
}

create_git_fixture() {
    local root_dir="$1"
    local target_repo="$root_dir/target"
    local bare_remote="$root_dir/remote.git"

    git init -b main "$target_repo" >/dev/null 2>&1
    git -C "$target_repo" config user.name "Test User"
    git -C "$target_repo" config user.email "test@example.com"
    printf "baseline\n" > "$target_repo/tracked.txt"
    git -C "$target_repo" add tracked.txt
    git -C "$target_repo" commit -m "initial" >/dev/null 2>&1

    git init --bare "$bare_remote" >/dev/null 2>&1
    git -C "$target_repo" remote add origin "$bare_remote"
    git -C "$target_repo" push -u origin main >/dev/null 2>&1

    echo "$target_repo|$bare_remote"
}

run_hook_with_mocks() {
    local target_repo="$1"
    local strip_mode="$2"
    local call_log="$3"
    local mock_dir="$4"

    POST_SYNC_HOOK_CALL_LOG="$call_log" \
    REAL_GIT_BIN="$(command -v git)" \
    MOCK_STRIP_MODE="$strip_mode" \
    MATT_REPO_ROOT="/nonexistent" \
    DEBBIE_DEV_ROOT="$REPO_ROOT" \
    DEBBIE_TARGET_ROOT="$target_repo" \
    DEBBIE_TARGET="staging" \
    PATH="$mock_dir:$PATH" \
    bash "$HOOK_SCRIPT" >/dev/null 2>&1
}

read_calls() {
    local call_log="$1"
    if [[ -f "$call_log" ]]; then
        cat "$call_log"
    fi
}

assert_strip_invoked_for_target() {
    local calls="$1"
    local target_repo="$2"
    local message="$3"
    local python3_strip_call="python3:-m matt scrai strip $target_repo"
    local matt_strip_call="matt:scrai strip $target_repo"

    if [[ "$calls" == *"$python3_strip_call"* || "$calls" == *"$matt_strip_call"* ]]; then
        pass "$message"
    else
        fail "$message (expected '$python3_strip_call' or '$matt_strip_call')"
    fi
}

first_strip_invocation_line() {
    local call_log="$1"
    local target_repo="$2"

    awk -v python3_call="python3:-m matt scrai strip $target_repo" -v matt_call="matt:scrai strip $target_repo" '
        index($0, python3_call) || index($0, matt_call) {
            print NR
            exit
        }
    ' "$call_log"
}

test_post_sync_hook_strip_then_dirty_commit_push_contract() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"

    local fixture
    fixture="$(create_git_fixture "$tmp_dir")"
    local target_repo="${fixture%%|*}"
    local bare_remote="${fixture##*|}"
    local call_log="$tmp_dir/calls.log"
    local mock_dir
    mock_dir="$(new_mock_tools_dir)"

    local baseline_count
    baseline_count="$(git -C "$target_repo" rev-list --count HEAD)"

    run_hook_with_mocks "$target_repo" "noop" "$call_log" "$mock_dir"

    local count_after_clean
    count_after_clean="$(git -C "$target_repo" rev-list --count HEAD)"
    local clean_calls
    clean_calls="$(read_calls "$call_log")"

    assert_eq "$count_after_clean" "$baseline_count" "clean target should not create a commit"
    assert_strip_invoked_for_target "$clean_calls" "$target_repo" "hook should invoke strip ownership for clean target"
    assert_contains "$clean_calls" "git:-C $target_repo status --porcelain" "hook should evaluate dirtiness after strip"
    assert_not_contains "$clean_calls" "git:-C $target_repo commit -m" "clean target should not commit"
    assert_not_contains "$clean_calls" "git:-C $target_repo push origin" "clean target should not push"

    : > "$call_log"
    run_hook_with_mocks "$target_repo" "dirty" "$call_log" "$mock_dir"

    local count_after_dirty
    count_after_dirty="$(git -C "$target_repo" rev-list --count HEAD)"
    local dirty_calls
    dirty_calls="$(read_calls "$call_log")"

    assert_eq "$count_after_dirty" "$((baseline_count + 1))" "dirty target should create exactly one sync commit"
    assert_strip_invoked_for_target "$dirty_calls" "$target_repo" "dirty run should still invoke strip"
    assert_contains "$dirty_calls" "git:-C $target_repo status --porcelain" "dirty run should check git dirtiness"
    assert_contains "$dirty_calls" "git:-C $target_repo add -A" "dirty run should stage all changes"
    assert_contains "$dirty_calls" "git:-C $target_repo commit -m chore: debbie post-sync mirror update" "dirty run should create deterministic commit"
    assert_contains "$dirty_calls" "git:-C $target_repo push origin main" "dirty run should push current branch"

    local strip_line
    local status_line
    strip_line="$(first_strip_invocation_line "$call_log" "$target_repo")"
    status_line="$(grep -n "git:-C $target_repo status --porcelain" "$call_log" | head -n 1 | cut -d: -f1)"
    if [[ -n "$strip_line" && -n "$status_line" && "$strip_line" -lt "$status_line" ]]; then
        pass "strip must run before git dirtiness evaluation"
    else
        fail "strip must run before git dirtiness evaluation"
    fi

    local local_head
    local remote_head
    local_head="$(git -C "$target_repo" rev-parse HEAD)"
    remote_head="$(git --git-dir "$bare_remote" rev-parse refs/heads/main)"
    assert_eq "$remote_head" "$local_head" "dirty run should push commit to remote"

    : > "$call_log"
    run_hook_with_mocks "$target_repo" "noop" "$call_log" "$mock_dir"

    local count_after_second
    count_after_second="$(git -C "$target_repo" rev-list --count HEAD)"
    local second_calls
    second_calls="$(read_calls "$call_log")"

    assert_eq "$count_after_second" "$count_after_dirty" "no-op second run should not create additional commits"
    assert_contains "$second_calls" "git:-C $target_repo status --porcelain" "second run should still evaluate dirtiness"
    assert_not_contains "$second_calls" "git:-C $target_repo commit -m" "no-op second run should not commit"
    assert_not_contains "$second_calls" "git:-C $target_repo push origin" "no-op second run should not push"

    rm -rf "$mock_dir" "$tmp_dir"
}

echo "=== post-sync hook contract tests ==="
test_post_sync_hook_strip_then_dirty_commit_push_contract
run_test_summary
