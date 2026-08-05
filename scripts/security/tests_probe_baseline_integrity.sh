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

add_raw_verify_row() {
    local control_name="$1"
    local verify_cell="$2"

    printf "| %s | IMPLEMENTED | \`fixture/owner\` | %s |\n" \
        "$control_name" "$verify_cell" >> "$BASELINE_FILE"
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
{
    printf 'ARGV_BEGIN\\n'
    printf '%s\\n' "\$@"
    printf 'ARGV_END\\n'
} >> "$invocation_file"
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

install_cargo_mixed_inventory_shim() {
    local selected_test_count="$1"
    local selected_test_name_prefix="$2"
    local invocation_file="$CASE_DIR/cargo_invocations"

    mkdir -p "$CASE_DIR/bin"
    : > "$invocation_file"
    cat > "$CASE_DIR/bin/cargo" <<EOF
#!/usr/bin/env bash
{
    printf 'ARGV_BEGIN\\n'
    printf '%s\\n' "\$@"
    printf 'ARGV_END\\n'
} >> "$invocation_file"
for index in \$(seq 1 "$selected_test_count"); do
    printf '${selected_test_name_prefix}::selected_%02d: test\\n' "\$index"
done
printf 'unrelated_fixture::not_selected: test\\n'
EOF
    chmod +x "$CASE_DIR/bin/cargo"
    RUN_PATH="$CASE_DIR/bin:$PATH"
}

install_npx_vitest_total_shim() {
    local test_count="$1"
    local invocation_file="$CASE_DIR/npx_invocations"

    mkdir -p "$CASE_DIR/bin"
    : > "$invocation_file"
    cat > "$CASE_DIR/bin/npx" <<EOF
#!/usr/bin/env bash
{
    printf 'ARGV_BEGIN\\n'
    printf '%s\\n' "\$@"
    printf 'ARGV_END\\n'
} >> "$invocation_file"
printf 'Tests (%s)\\n' "$test_count"
EOF
    chmod +x "$CASE_DIR/bin/npx"
    RUN_PATH="$CASE_DIR/bin:$PATH"
}

make_physical_tmpdir() {
    python3 - "$TEST_ROOT" <<'PY'
import os
import sys
import tempfile

print(os.path.realpath(tempfile.mkdtemp(dir=sys.argv[1])))
PY
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
    printf '| %s | IMPLEMENTED | `fixture/owner` | `%s` (4 approximate tests) |\n' \
        "runner-with-unsupported-count-label" \
        "cd web && npx vitest run src/lib/server/auth-cookies.test.ts" >> "$BASELINE_FILE"
    printf '| %s | IMPLEMENTED | `fixture/owner` | `%s` (4 tests) (4 selected tests) |\n' \
        "runner-with-ambiguous-counts" \
        "cd web && npx vitest run src/lib/server/auth-cookies.test.ts" >> "$BASELINE_FILE"
    run_case

    assert_ne "$RUN_EXIT_CODE" "0" "a malformed inline count is fail-loud"
    assert_contains "$RUN_OUTPUT" "runner-with-malformed-count" \
        "malformed-count failure names the offending baseline row"
    assert_contains "$RUN_OUTPUT" "runner-with-unsupported-count-label" \
        "unsupported count-label failure names the offending baseline row"
    assert_contains "$RUN_OUTPUT" "runner-with-ambiguous-counts" \
        "ambiguous-count failure names the offending baseline row"
    assert_contains "$RUN_OUTPUT" "UNPARSEABLE" \
        "a malformed inline count is unparseable"
    assert_contains "$RUN_OUTPUT" "SUMMARY found=3 verified=0 failed=3" \
        "malformed count labels remain in the denominator"
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

test_vitest_symlink_escape_is_runner_error() {
    local probe_root copied_script copied_baseline npx_invocations output exit_code

    probe_root="$(make_physical_tmpdir)"
    copied_script="$probe_root/scripts/security/probe_baseline_integrity.sh"
    copied_baseline="$probe_root/control_baseline.md"
    npx_invocations="$probe_root/npx_invocations"

    mkdir -p \
        "$probe_root/scripts/security" \
        "$probe_root/web/src/lib/server" \
        "$probe_root/outside" \
        "$probe_root/bin"
    cp "$TARGET_SCRIPT" "$copied_script"

    cat > "$copied_baseline" <<'EOF'
| Control | Status | Owner | Verify |
| --- | --- | --- | --- |
| symlink-escape | IMPLEMENTED | `fixture/owner` | `cd web && npx vitest run src/lib/server/link.test.ts` (1 test) |
EOF
    cat > "$probe_root/outside/real.test.ts" <<'EOF'
export const escaped = true;
EOF
    ln -s ../../../../outside/real.test.ts \
        "$probe_root/web/src/lib/server/link.test.ts"
    : > "$npx_invocations"
    cat > "$probe_root/bin/npx" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$npx_invocations"
printf 'Tests (1)\n'
EOF
    chmod +x "$probe_root/bin/npx"

    set +e
    output="$(PATH="$probe_root/bin:$PATH" bash "$copied_script" \
        --baseline-file "$copied_baseline" 2>&1)"
    exit_code=$?
    set -e

    assert_ne "$exit_code" "0" \
        "a symlinked Vitest path that escapes web root is fail-loud"
    assert_contains "$output" "symlink-escape" \
        "symlink escape failure names the offending baseline row"
    assert_contains "$output" "RUNNER_ERROR" \
        "a symlinked Vitest path escape is classified as a runner error"
    assert_eq "$(wc -l < "$npx_invocations" | tr -d ' ')" "0" \
        "escaped symlink is rejected before invoking Vitest"
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
    install_cargo_mixed_inventory_shim 1 fixture
    add_verify_row \
        "unsupported-cargo-option" \
        "cd infra && cargo test -p api --doc" \
        "1"
    add_verify_row \
        "unsupported-cargo-runner-option" \
        "cd infra && cargo test -p api --test auth_admin operator_identity -- --ignored --nocapture --show-output" \
        "1"
    add_verify_row \
        "unsupported-vitest-option" \
        "cd web && npx vitest run --coverage src/lib/server/auth-cookies.test.ts" \
        "4"
    run_case

    assert_ne "$RUN_EXIT_CODE" "0" "unsupported runner tokens are fail-loud"
    assert_contains "$RUN_OUTPUT" "unsupported-cargo-option" \
        "unsupported Cargo syntax names its row"
    assert_contains "$RUN_OUTPUT" "unsupported-cargo-runner-option" \
        "unsupported post-separator Cargo syntax names its row"
    assert_contains "$RUN_OUTPUT" "unsupported-vitest-option" \
        "unsupported Vitest syntax names its row"
    assert_contains "$RUN_OUTPUT" "SUMMARY found=3 verified=0 failed=3" \
        "unsupported known runners remain in the denominator"
    assert_eq "$(count_literal "ARGV_BEGIN" "$CASE_DIR/cargo_invocations")" "0" \
        "unsupported Cargo syntax is rejected before invoking Cargo"
}

test_recorded_ignored_nocapture_cargo_shape_counts_admin_session_token_tests() {
    local invocation_count invocation_args expected_args

    create_case admin_session_token_cargo_shape
    install_cargo_mixed_inventory_shim 25 admin_operator_identity_test
    add_raw_verify_row \
        "Admin session token shape" \
        "\`cd infra && cargo test -p api --test auth_admin admin_operator_identity_test -- --ignored --nocapture\` (25 selected tests)"
    run_case

    invocation_count="$(count_literal "ARGV_BEGIN" "$CASE_DIR/cargo_invocations")"
    invocation_args="$(cat "$CASE_DIR/cargo_invocations")"
    expected_args="$(printf '%s\n' \
        "ARGV_BEGIN" \
        "test" \
        "-p" \
        "api" \
        "--test" \
        "auth_admin" \
        "--" \
        "--list" \
        "ARGV_END")"
    assert_eq "$RUN_EXIT_CODE" "0" \
        "ignored/nocapture Cargo baseline row for admin session token shape verifies"
    assert_contains "$RUN_OUTPUT" \
        'RESULT control="Admin session token shape" runner=CARGO status=VERIFIED recorded=25 actual=25' \
        "ignored/nocapture Cargo row reports the recorded selected-test count"
    assert_eq "$invocation_count" "1" \
        "ignored/nocapture Cargo row invokes Cargo exactly once"
    assert_eq "$invocation_args" "$expected_args" \
        "admin session token Cargo row uses the canonical inventory argv"
}

test_recorded_ignored_nocapture_cargo_shape_counts_operator_identity_tests() {
    local invocation_count invocation_args expected_args

    create_case operator_identity_cargo_shape
    install_cargo_mixed_inventory_shim 25 operator_identity
    add_raw_verify_row \
        "Admin API authentication" \
        "\`cd infra && cargo test -p api --test auth_admin operator_identity -- --ignored --nocapture\` (25 selected ignored DB tests)"
    run_case

    invocation_count="$(count_literal "ARGV_BEGIN" "$CASE_DIR/cargo_invocations")"
    invocation_args="$(cat "$CASE_DIR/cargo_invocations")"
    expected_args="$(printf '%s\n' \
        "ARGV_BEGIN" \
        "test" \
        "-p" \
        "api" \
        "--test" \
        "auth_admin" \
        "--" \
        "--list" \
        "ARGV_END")"
    assert_eq "$RUN_EXIT_CODE" "0" \
        "ignored/nocapture Cargo baseline row for operator identity verifies"
    assert_contains "$RUN_OUTPUT" \
        'RESULT control="Admin API authentication" runner=CARGO status=VERIFIED recorded=25 actual=25' \
        "operator identity Cargo row reports the recorded selected ignored DB test count"
    assert_eq "$invocation_count" "1" \
        "operator identity Cargo row invokes Cargo exactly once"
    assert_eq "$invocation_args" "$expected_args" \
        "operator identity Cargo row uses the canonical inventory argv"
}

test_recorded_ignored_nocapture_cargo_shape_counts_webhook_event_tests() {
    local invocation_count invocation_args expected_args

    create_case webhook_events_cargo_shape
    install_cargo_mixed_inventory_shim 2 system_actor
    add_raw_verify_row \
        "Actor attribution" \
        "\`cd infra && cargo test -p api --test auth_admin system_actor -- --ignored --nocapture\` (2 selected ignored DB tests)"
    run_case

    invocation_count="$(count_literal "ARGV_BEGIN" "$CASE_DIR/cargo_invocations")"
    invocation_args="$(cat "$CASE_DIR/cargo_invocations")"
    expected_args="$(printf '%s\n' \
        "ARGV_BEGIN" \
        "test" \
        "-p" \
        "api" \
        "--test" \
        "auth_admin" \
        "--" \
        "--list" \
        "ARGV_END")"
    assert_eq "$RUN_EXIT_CODE" "0" \
        "ignored/nocapture Cargo baseline row for webhook events verifies"
    assert_contains "$RUN_OUTPUT" \
        'RESULT control="Actor attribution" runner=CARGO status=VERIFIED recorded=2 actual=2' \
        "system actor Cargo row reports the recorded selected ignored DB test count"
    assert_eq "$invocation_count" "1" \
        "webhook events Cargo row invokes Cargo exactly once"
    assert_eq "$invocation_args" "$expected_args" \
        "webhook events Cargo row uses the canonical inventory argv"
}

test_recorded_ignored_nocapture_cargo_shape_reports_count_mismatch() {
    create_case ignored_nocapture_cargo_count_mismatch
    install_cargo_mixed_inventory_shim 25 operator_identity
    add_raw_verify_row \
        "Admin API authentication" \
        "\`cd infra && cargo test -p api --test auth_admin operator_identity -- --ignored --nocapture\` (24 selected ignored DB tests)"
    run_case

    assert_ne "$RUN_EXIT_CODE" "0" \
        "ignored/nocapture Cargo rows fail when the recorded count is stale"
    assert_contains "$RUN_OUTPUT" \
        'RESULT control="Admin API authentication" runner=CARGO status=COUNT_MISMATCH recorded=24 actual=25' \
        "ignored/nocapture Cargo rows report stale counts as COUNT_MISMATCH"
}

test_recorded_multi_spec_vitest_shape_aggregates_total() {
    local invocation_count invocation_args expected_args

    create_case multi_spec_vitest_shape
    install_npx_vitest_total_shim 80
    add_verify_row \
        "Admin session token shape" \
        "cd web && npx vitest run src/lib/server/admin-session.test.ts src/routes/admin/admin-layout.test.ts src/routes/admin/login/admin-login.server.test.ts" \
        "80"
    run_case

    invocation_count="$(count_literal "ARGV_BEGIN" "$CASE_DIR/npx_invocations")"
    invocation_args="$(cat "$CASE_DIR/npx_invocations")"
    expected_args="$(printf '%s\n' \
        "ARGV_BEGIN" \
        "--no-install" \
        "vitest" \
        "run" \
        "$REPO_ROOT/web/src/lib/server/admin-session.test.ts" \
        "$REPO_ROOT/web/src/routes/admin/admin-layout.test.ts" \
        "$REPO_ROOT/web/src/routes/admin/login/admin-login.server.test.ts" \
        "ARGV_END")"
    assert_eq "$RUN_EXIT_CODE" "0" \
        "multi-spec Vitest baseline row verifies"
    assert_contains "$RUN_OUTPUT" \
        'RESULT control="Admin session token shape" runner=VITEST status=VERIFIED recorded=80 actual=80' \
        "multi-spec Vitest row aggregates the recorded total"
    assert_eq "$invocation_count" "1" \
        "multi-spec Vitest row invokes Vitest exactly once"
    assert_eq "$invocation_args" "$expected_args" \
        "multi-spec Vitest row forwards exact argv tokens"
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

    invocation_count="$(count_literal "ARGV_BEGIN" "$CASE_DIR/cargo_invocations")"
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
test_vitest_symlink_escape_is_runner_error
test_invalid_arguments_exit_two
test_unsupported_runner_tokens_are_unparseable
test_recorded_ignored_nocapture_cargo_shape_counts_admin_session_token_tests
test_recorded_ignored_nocapture_cargo_shape_counts_operator_identity_tests
test_recorded_ignored_nocapture_cargo_shape_counts_webhook_event_tests
test_recorded_ignored_nocapture_cargo_shape_reports_count_mismatch
test_recorded_multi_spec_vitest_shape_aggregates_total
test_cargo_inventory_is_cached_per_target
test_non_existent_rust_target_fails
test_zero_test_selection_fails
test_recorded_count_mismatch_fails
test_no_in_scope_runner_is_vacuous
test_local_ci_registers_baseline_integrity_gate

run_test_summary
