#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="$SCRIPT_DIR/probe_baseline_integrity.sh"
LOCAL_CI_SCRIPT="$REPO_ROOT/scripts/local-ci.sh"

# shellcheck source=../tests/lib/test_runner.sh disable=SC1091
source "$REPO_ROOT/scripts/tests/lib/test_runner.sh"
# shellcheck source=../tests/lib/assertions.sh disable=SC1091
source "$REPO_ROOT/scripts/tests/lib/assertions.sh"

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

CASE_DIR=""
BASELINE_FILE=""
RUN_OUTPUT=""
RUN_EXIT_CODE=0
RUN_PATH="$PATH"

create_case() {
    local case_name="$1"

    CASE_DIR="$TEST_ROOT/$case_name"
    BASELINE_FILE="$CASE_DIR/control_baseline.md"
    RUN_PATH="$PATH"
    mkdir -p "$CASE_DIR"
    cat > "$BASELINE_FILE" <<'EOF'
# Fixture Security Control Baseline

| Control | Status | Owner | Verify |
| --- | --- | --- | --- |
EOF
}

add_verify_row() {
    local control_name="$1"
    local command="$2"
    local recorded_count="$3"
    local count_label="tests"

    if [ "$recorded_count" = "1" ]; then
        count_label="test"
    fi

    printf "| %s | IMPLEMENTED | \`fixture/owner\` | \`%s\` (%s %s) |\n" \
        "$control_name" "$command" "$recorded_count" "$count_label" >> "$BASELINE_FILE"
}

write_matching_fixture() {
    add_verify_row \
        "matching-rust-runner" \
        "cd infra && cargo test -p api --lib password:: -- --list" \
        "7"
    add_verify_row \
        "matching-vitest-runner" \
        "cd web && npx vitest run src/lib/server/auth-cookies.test.ts" \
        "4"
}

write_out_of_scope_only_fixture() {
    # grep, sed, cat, dig, and aws are intentionally outside the denominator.
    add_verify_row "out-of-scope-grep" "grep -n password infra/api/src/password.rs" "1"
    add_verify_row "out-of-scope-sed" "sed -n 1,20p infra/api/src/password.rs" "1"
    add_verify_row "out-of-scope-cat" "cat infra/api/src/password.rs" "1"
    add_verify_row "out-of-scope-dig" "dig TXT example.test" "1"
    add_verify_row "out-of-scope-aws" "aws ec2 describe-instances" "1"
}

run_case() {
    set +e
    RUN_OUTPUT="$(cd "$TEST_ROOT" && PATH="$RUN_PATH" bash "$TARGET_SCRIPT" \
        --baseline-file "$BASELINE_FILE" 2>&1)"
    RUN_EXIT_CODE=$?
    set -e
}

count_literal() {
    local needle="$1"
    local file_path="$2"

    python3 - "$needle" "$file_path" <<'PY'
import sys
needle = sys.argv[1]
with open(sys.argv[2], encoding="utf-8") as handle:
    print(handle.read().count(needle))
PY
}

count_help_literal() {
    local needle="$1"

    python3 - "$needle" "$LOCAL_CI_SCRIPT" <<'PY'
import sys
needle, path = sys.argv[1:]
in_block = False
content = []
with open(path, encoding="utf-8") as handle:
    for line in handle:
        if line.startswith("## HELP-TEXT-END"):
            break
        if in_block:
            content.append(line)
        if line.startswith("## HELP-TEXT-BEGIN"):
            in_block = True
print("".join(content).count(needle))
PY
}

count_line_literal() {
    local starts_with="$1"
    local contains="$2"
    local needle="$3"

    python3 - "$starts_with" "$contains" "$needle" "$LOCAL_CI_SCRIPT" <<'PY'
import sys
starts_with, contains, needle, path = sys.argv[1:]
total = 0
with open(path, encoding="utf-8") as handle:
    for line in handle:
        if line.startswith(starts_with) and contains in line:
            total += line.count(needle)
print(total)
PY
}

count_regex() {
    local regex="$1"

    python3 - "$regex" "$LOCAL_CI_SCRIPT" <<'PY'
import re
import sys
regex, path = sys.argv[1:]
total = 0
with open(path, encoding="utf-8") as handle:
    for line in handle:
        if re.search(regex, line):
            total += 1
print(total)
PY
}

install_cargo_inventory_shim() {
    local invocation_file="$CASE_DIR/cargo_invocations"

    mkdir -p "$CASE_DIR/bin"
    : > "$invocation_file"
    cat > "$CASE_DIR/bin/cargo" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$invocation_file"
cat <<'LIST'
password::alpha: test
password::beta: test
other::gamma: test
helper::benchmark: benchmark
LIST
EOF
    chmod +x "$CASE_DIR/bin/cargo"
    RUN_PATH="$CASE_DIR/bin:$PATH"
}

test_matching_count_fixture_passes() {
    create_case matching_counts
    write_matching_fixture
    run_case

    assert_eq "$RUN_EXIT_CODE" "0" \
        "matching cargo and Vitest recorded counts pass"
    assert_contains "$RUN_OUTPUT" "SUMMARY found=2 verified=2 failed=0" \
        "matching fixture reports its exact two-runner denominator"
}

test_known_runner_without_count_is_unparseable() {
    create_case runner_without_count
    printf '| %s | IMPLEMENTED | `fixture/owner` | `%s` |\n' \
        "runner-without-count" \
        "cd web && npx vitest run src/lib/server/auth-cookies.test.ts" >> "$BASELINE_FILE"
    run_case

    assert_ne "$RUN_EXIT_CODE" "0" "a known runner without an inline count is fail-loud"
    assert_contains "$RUN_OUTPUT" "runner-without-count" \
        "missing-count failure names the offending baseline row"
    assert_contains "$RUN_OUTPUT" "UNPARSEABLE" \
        "a known runner without an inline count is unparseable"
    assert_contains "$RUN_OUTPUT" "SUMMARY found=1 verified=0 failed=1" \
        "unparseable known runners remain in the denominator"
}

test_known_runner_with_malformed_count_is_unparseable() {
    create_case runner_with_malformed_count
    printf '| %s | IMPLEMENTED | `fixture/owner` | `%s` (four tests) |\n' \
        "runner-with-malformed-count" \
        "cd web && npx vitest run src/lib/server/auth-cookies.test.ts" >> "$BASELINE_FILE"
    run_case

    assert_ne "$RUN_EXIT_CODE" "0" "a malformed inline count is fail-loud"
    assert_contains "$RUN_OUTPUT" "runner-with-malformed-count" \
        "malformed-count failure names the offending baseline row"
    assert_contains "$RUN_OUTPUT" "UNPARSEABLE" \
        "a malformed inline count is unparseable"
}

test_missing_vitest_file_is_runner_error() {
    create_case missing_vitest_file
    add_verify_row \
        "missing-vitest-file" \
        "cd web && npx vitest run src/lib/server/baseline-integrity-missing.test.ts" \
        "1"
    run_case

    assert_ne "$RUN_EXIT_CODE" "0" "a missing Vitest file is fail-loud"
    assert_contains "$RUN_OUTPUT" "missing-vitest-file" \
        "missing Vitest file names the offending baseline row"
    assert_contains "$RUN_OUTPUT" "RUNNER_ERROR" \
        "a missing Vitest file is classified as a runner error"
}

test_invalid_arguments_exit_two() {
    local output exit_code

    set +e
    output="$(bash "$TARGET_SCRIPT" --unknown-option 2>&1)"
    exit_code=$?
    set -e
    assert_eq "$exit_code" "2" "an unknown argument exits two"
    assert_contains "$output" "unknown argument" "an unknown argument is diagnosed"

    set +e
    output="$(bash "$TARGET_SCRIPT" --baseline-file 2>&1)"
    exit_code=$?
    set -e
    assert_eq "$exit_code" "2" "a missing baseline-file value exits two"
    assert_contains "$output" "requires a path" "a missing baseline-file value is diagnosed"

    set +e
    output="$(bash "$TARGET_SCRIPT" --baseline-file "$TEST_ROOT/missing.md" 2>&1)"
    exit_code=$?
    set -e
    assert_eq "$exit_code" "2" "a missing baseline file exits two"
    assert_contains "$output" "baseline file not found" "a missing baseline file is diagnosed"
}

test_unsupported_runner_tokens_are_unparseable() {
    create_case unsupported_runner_tokens
    add_verify_row \
        "unsupported-cargo-option" \
        "cd infra && cargo test -p api --doc" \
        "1"
    add_verify_row \
        "unsupported-vitest-option" \
        "cd web && npx vitest run --coverage src/lib/server/auth-cookies.test.ts" \
        "4"
    run_case

    assert_ne "$RUN_EXIT_CODE" "0" "unsupported runner tokens are fail-loud"
    assert_contains "$RUN_OUTPUT" "unsupported-cargo-option" \
        "unsupported Cargo syntax names its row"
    assert_contains "$RUN_OUTPUT" "unsupported-vitest-option" \
        "unsupported Vitest syntax names its row"
    assert_contains "$RUN_OUTPUT" "SUMMARY found=2 verified=0 failed=2" \
        "unsupported known runners remain in the denominator"
}

test_cargo_inventory_is_cached_per_target() {
    local invocation_count

    create_case cached_cargo_inventory
    install_cargo_inventory_shim
    add_verify_row \
        "cached-password-filter" \
        "cd infra && cargo test -p api --lib password:: -- --list" \
        "2"
    add_verify_row \
        "cached-other-filter" \
        "cd infra && cargo test -p api --lib other:: -- --list" \
        "1"
    run_case

    invocation_count="$(wc -l < "$CASE_DIR/cargo_invocations" | tr -d ' ')"
    assert_eq "$RUN_EXIT_CODE" "0" "two filters over one Rust target both verify"
    assert_eq "$invocation_count" "1" \
        "two filters over one Rust target invoke Cargo exactly once"
    assert_contains "$RUN_OUTPUT" "SUMMARY found=2 verified=2 failed=0" \
        "cached Cargo fixture reports both verified invocations"
}

test_non_existent_rust_target_fails() {
    create_case missing_rust_target
    add_verify_row \
        "missing-rust-target" \
        "cd infra && cargo test -p api --test baseline_integrity_missing_target -- --list" \
        "1"
    add_verify_row \
        "matching-vitest-runner" \
        "cd web && npx vitest run src/lib/server/auth-cookies.test.ts" \
        "4"
    run_case

    assert_ne "$RUN_EXIT_CODE" "0" "a non-existent Rust target is fail-loud"
    assert_contains "$RUN_OUTPUT" "missing-rust-target" \
        "runner failure names the offending baseline row"
    assert_contains "$RUN_OUTPUT" "RUNNER_ERROR" \
        "a non-existent Rust target is classified as a runner error"
}

test_zero_test_selection_fails() {
    create_case zero_test_selection
    add_verify_row \
        "zero-test-selection" \
        "cd infra && cargo test -p api --test auth_admin baseline_integrity_filter_that_does_not_exist -- --list" \
        "0"
    run_case

    assert_ne "$RUN_EXIT_CODE" "0" "a zero-test selection is fail-loud"
    assert_contains "$RUN_OUTPUT" "zero-test-selection" \
        "zero-test failure names the offending baseline row"
    assert_contains "$RUN_OUTPUT" "ZERO_SELECTION" \
        "zero selected tests use the explicit zero-selection classification"
    assert_not_contains "$RUN_OUTPUT" "COUNT_MISMATCH" \
        "zero selected tests are not reduced to a count mismatch"
}

test_recorded_count_mismatch_fails() {
    create_case recorded_count_mismatch
    add_verify_row \
        "recorded-count-mismatch" \
        "cd web && npx vitest run src/lib/server/auth-cookies.test.ts" \
        "99"
    run_case

    assert_ne "$RUN_EXIT_CODE" "0" "a recorded-count mismatch is fail-loud"
    assert_contains "$RUN_OUTPUT" "recorded-count-mismatch" \
        "count mismatch names the offending baseline row"
    assert_contains "$RUN_OUTPUT" "COUNT_MISMATCH" \
        "a non-zero recorded-count drift uses the mismatch classification"
    assert_not_contains "$RUN_OUTPUT" "ZERO_SELECTION" \
        "a non-zero count mismatch is not classified as zero selection"
}

test_no_in_scope_runner_is_vacuous() {
    create_case no_in_scope_runner
    write_out_of_scope_only_fixture
    run_case

    assert_ne "$RUN_EXIT_CODE" "0" "a corpus without an in-scope runner is fail-loud"
    assert_contains "$RUN_OUTPUT" "VACUOUS" \
        "a corpus containing only non-test commands is explicitly VACUOUS"
}

test_local_ci_registers_baseline_integrity_gate() {
    local gate_definition_count
    local delegate_count
    local help_count
    local schedule_count
    local dispatch_count
    local summary_known_count
    local unknown_known_count

    gate_definition_count="$(count_regex '^gate_baseline_integrity\(\) \{')"
    delegate_count="$(count_literal 'bash "$REPO_ROOT/scripts/security/probe_baseline_integrity.sh" --baseline-file "$REPO_ROOT/docs/security/control_baseline.md" || return $?' "$LOCAL_CI_SCRIPT")"
    help_count="$(count_help_literal 'baseline-integrity')"
    schedule_count="$(count_regex '^schedule baseline-integrity$')"
    dispatch_count="$(count_literal 'baseline-integrity) run_gate baseline-integrity gate_baseline_integrity ;;' "$LOCAL_CI_SCRIPT")"
    summary_known_count="$(count_line_literal "    printf 'Known gates:" "" "baseline-integrity")"
    unknown_known_count="$(count_line_literal '        echo "Known gates:' '>&2' 'baseline-integrity')"

    assert_eq "$gate_definition_count" "1" \
        "local-ci defines exactly one baseline-integrity gate"
    assert_eq "$delegate_count" "1" \
        "baseline-integrity delegates exactly once to the production probe"
    assert_eq "$help_count" "1" \
        "local-ci help documents baseline-integrity exactly once"
    assert_eq "$schedule_count" "1" \
        "baseline-integrity is scheduled in the measured fast lane"
    assert_eq "$dispatch_count" "1" \
        "local-ci dispatches baseline-integrity exactly once"
    assert_eq "$summary_known_count" "1" \
        "summary-only known gates list baseline-integrity exactly once"
    assert_eq "$unknown_known_count" "1" \
        "unknown-gate known gates list baseline-integrity exactly once"
}

test_matching_count_fixture_passes
test_known_runner_without_count_is_unparseable
test_known_runner_with_malformed_count_is_unparseable
test_missing_vitest_file_is_runner_error
test_invalid_arguments_exit_two
test_unsupported_runner_tokens_are_unparseable
test_cargo_inventory_is_cached_per_target
test_non_existent_rust_target_fails
test_zero_test_selection_fails
test_recorded_count_mismatch_fails
test_no_in_scope_runner_is_vacuous
test_local_ci_registers_baseline_integrity_gate

run_test_summary
