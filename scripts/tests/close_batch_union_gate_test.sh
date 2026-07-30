#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/close_batch_union_gate.sh"

# shellcheck source=scripts/tests/lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=scripts/tests/lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

WORK_DIR=""
RUN_OUTPUT=""
RUN_EXIT_CODE=0

cleanup() {
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

make_fixture() {
    WORK_DIR="$(mktemp -d)"
    mkdir -p "$WORK_DIR/repo/scripts" "$WORK_DIR/repo/chatting"
    if [ -f "$TARGET_SCRIPT" ]; then
        cp "$TARGET_SCRIPT" "$WORK_DIR/repo/scripts/close_batch_union_gate.sh"
    fi
}

write_local_ci_stub() {
    local output="$1"
    local exit_code="$2"
    printf '#!/usr/bin/env bash\nprintf "%%s\\\\n" %q\nexit %s\n' \
        "$output" "$exit_code" > "$WORK_DIR/repo/scripts/local-ci.sh"
    chmod +x "$WORK_DIR/repo/scripts/local-ci.sh"
}

write_closeout() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    printf '# Batch closeout\n\nExisting evidence stays intact.\n' > "$path"
}

run_wrapper() {
    local -a args=("$@")
    set +e
    RUN_OUTPUT="$(
        cd "$WORK_DIR/repo" &&
            bash scripts/close_batch_union_gate.sh "${args[@]}" 2>&1
    )"
    RUN_EXIT_CODE=$?
    set -e
}

assert_gate_section_count() {
    local path="$1"
    local expected="$2"
    local message="$3"
    local actual
    actual="$(grep -c '^## Merged-union gate$' "$path" 2>/dev/null || true)"
    assert_eq "$actual" "$expected" "$message"
}

test_failed_gate_appends_output_and_returns_failure() {
    make_fixture
    local closeout="$WORK_DIR/repo/chatting/failed_closeout.md"
    write_closeout "$closeout"
    write_local_ci_stub $'fast gate started\nfailing owner: fixture\nfast gate finished' 17

    run_wrapper "chatting/failed_closeout.md"

    assert_eq "$RUN_EXIT_CODE" "17" "wrapper must preserve the failed local-ci exit code"
    assert_gate_section_count "$closeout" "1" "failed gate must append exactly one gate section"
    local contents
    contents="$(cat "$closeout")"
    assert_contains "$contents" $'fast gate started\nfailing owner: fixture\nfast gate finished' \
        "failed gate output must be appended verbatim"
    assert_contains "$contents" '- Exit code: `17`' "failed gate section must record the real exit code"
    cleanup
}

test_missing_argument_refuses_without_running_gate() {
    make_fixture
    write_local_ci_stub "must not run" 0

    run_wrapper

    assert_ne "$RUN_EXIT_CODE" "0" "missing closeout argument must fail"
    assert_contains "$RUN_OUTPUT" "usage:" "missing argument must report usage"
    cleanup
}

test_missing_file_refuses_without_appending() {
    make_fixture
    write_local_ci_stub "must not run" 0

    run_wrapper "chatting/missing.md"

    assert_ne "$RUN_EXIT_CODE" "0" "missing closeout file must fail"
    assert_not_contains "$RUN_OUTPUT" "must not run" "missing closeout must refuse before local-ci"
    cleanup
}

test_repo_relative_path_outside_chatting_refuses() {
    make_fixture
    local outside="$WORK_DIR/repo/outside.md"
    write_closeout "$outside"
    write_local_ci_stub "must not run" 0

    run_wrapper "outside.md"

    assert_ne "$RUN_EXIT_CODE" "0" "repo-relative path outside chatting must fail"
    assert_gate_section_count "$outside" "0" "outside path must not gain a gate section"
    cleanup
}

test_absolute_path_outside_temp_chatting_refuses() {
    make_fixture
    local outside="$WORK_DIR/outside/closeout.md"
    write_closeout "$outside"
    write_local_ci_stub "must not run" 0

    run_wrapper "$outside"

    assert_ne "$RUN_EXIT_CODE" "0" "absolute temp path outside chatting must fail"
    assert_gate_section_count "$outside" "0" "absolute outside path must not gain a gate section"
    cleanup
}

test_unwritable_target_refuses_without_appending() {
    make_fixture
    local closeout="$WORK_DIR/repo/chatting/unwritable.md"
    write_closeout "$closeout"
    chmod 0444 "$closeout"
    write_local_ci_stub "must not run" 0

    run_wrapper "chatting/unwritable.md"

    assert_ne "$RUN_EXIT_CODE" "0" "unwritable closeout must fail"
    assert_gate_section_count "$closeout" "0" "unwritable closeout must not gain a gate section"
    chmod 0644 "$closeout"
    cleanup
}

test_duplicate_gate_section_refuses() {
    make_fixture
    local closeout="$WORK_DIR/repo/chatting/duplicate.md"
    write_closeout "$closeout"
    printf '\n## Merged-union gate\n\nPrior gate evidence.\n' >> "$closeout"
    write_local_ci_stub "must not run" 0

    run_wrapper "chatting/duplicate.md"

    assert_ne "$RUN_EXIT_CODE" "0" "duplicate gate section must fail"
    assert_gate_section_count "$closeout" "1" "duplicate refusal must preserve one existing section"
    assert_not_contains "$(cat "$closeout")" "must not run" "duplicate refusal must happen before local-ci"
    cleanup
}

test_passing_gate_writes_one_complete_section() {
    make_fixture
    local closeout="$WORK_DIR/repo/chatting/passing.md"
    write_closeout "$closeout"
    write_local_ci_stub $'fast gate started\nall owners passed\nfast gate finished' 0

    run_wrapper "chatting/passing.md"

    assert_eq "$RUN_EXIT_CODE" "0" "passing local-ci must make the wrapper pass"
    assert_gate_section_count "$closeout" "1" "passing gate must append exactly one section"
    local contents
    contents="$(cat "$closeout")"
    assert_contains "$contents" '- Command: `bash scripts/local-ci.sh --fast`' \
        "gate section must record the exact delegated command"
    assert_contains "$contents" $'fast gate started\nall owners passed\nfast gate finished' \
        "gate section must record the captured tail"
    assert_contains "$contents" '- Exit code: `0`' "passing gate section must record exit code zero"
    cleanup
}

test_absolute_temp_root_chatting_path_is_supported() {
    make_fixture
    local temp_closeout_root
    temp_closeout_root="$(mktemp -d)"
    local closeout="$temp_closeout_root/chatting/absolute.md"
    write_closeout "$closeout"
    write_local_ci_stub "absolute path passed" 0

    run_wrapper "$closeout"

    assert_eq "$RUN_EXIT_CODE" "0" "absolute temp-root chatting path must be supported"
    assert_gate_section_count "$closeout" "1" "absolute temp closeout must gain one gate section"
    rm -rf "$temp_closeout_root"
    cleanup
}

test_failed_gate_appends_output_and_returns_failure
test_missing_argument_refuses_without_running_gate
test_missing_file_refuses_without_appending
test_repo_relative_path_outside_chatting_refuses
test_absolute_path_outside_temp_chatting_refuses
test_unwritable_target_refuses_without_appending
test_duplicate_gate_section_refuses
test_passing_gate_writes_one_complete_section
test_absolute_temp_root_chatting_path_is_supported

run_test_summary
