#!/usr/bin/env bash
# Tests for scripts/reliability/run_backend_reliability_gate.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE_SCRIPT="$REPO_ROOT/scripts/reliability/run_backend_reliability_gate.sh"
source "$SCRIPT_DIR/lib/mock_cargo.sh"

PASS_COUNT=0
FAIL_COUNT=0

fail() {
    echo "FAIL: $*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

assert_eq() {
    local actual="$1" expected="$2" msg="$3"
    if [ "$actual" != "$expected" ]; then
        fail "$msg (expected='$expected' actual='$actual')"
    else
        pass "$msg"
    fi
}

assert_contains() {
    local actual="$1" expected_substr="$2" msg="$3"
    if [[ "$actual" != *"$expected_substr"* ]]; then
        fail "$msg (expected substring '$expected_substr' in '$actual')"
    else
        pass "$msg"
    fi
}

json_field() {
    local json="$1" field="$2"
    python3 -c "import json,sys; print(json.dumps(json.loads(sys.stdin.read()).get('$field')))" <<< "$json"
}

json_check_field() {
    local json="$1" check_name="$2" field="$3"
    python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
for r in d.get('check_results', []):
    if r.get('name') == '$check_name':
        print(r.get('$field', ''))
        break
else:
    print('')
" <<< "$json"
}

run_gate_with_mocks() {
    local mock_dir="$1"
    local fail_list="$2"
    shift 2
    local gate_args=("$@")

    local run_output
    local exit_code=0

    cat > "$mock_dir/harness.sh" <<EOF
set -euo pipefail
export __RUN_BACKEND_RELIABILITY_GATE_SOURCED=1
source '$GATE_SCRIPT'

LOG_FILE='$mock_dir/calls.log'
FAIL_LIST="\${FAIL_LIST:-}"
FORCE_DEP_AUDIT_MISSING="\${FORCE_DEP_AUDIT_MISSING:-0}"
FORCE_DEP_AUDIT_FAIL="\${FORCE_DEP_AUDIT_FAIL:-0}"

run_mock_check() {
    local check_name="\$1"
    local pass_reason="\$2"
    local fail_reason="\$3"

    echo "\$check_name" >> "\$LOG_FILE"

    if [[ ",\$FAIL_LIST," == *",\${check_name},"* ]]; then
        echo "\$fail_reason" >&2
        return 1
    fi

    echo "\$pass_reason" >&2
    return 0
}

run_reliability_profile_tests() {
    run_mock_check "reliability_profile_tests" "REASON: RELIABILITY_PROFILE_TESTS_PASS" "REASON: RELIABILITY_PROFILE_TESTS_FAIL"
}

run_reliability_scheduler_tests() {
    run_mock_check "reliability_scheduler_tests" "REASON: RELIABILITY_SCHEDULER_TESTS_PASS" "REASON: RELIABILITY_SCHEDULER_TESTS_FAIL"
}

run_reliability_replication_tests() {
    run_mock_check "reliability_replication_tests" "REASON: RELIABILITY_REPLICATION_TESTS_PASS" "REASON: RELIABILITY_REPLICATION_TESTS_FAIL"
}

run_reliability_api_crash_tests() {
    run_mock_check "reliability_api_crash_tests" "REASON: RELIABILITY_API_CRASH_TESTS_PASS" "REASON: RELIABILITY_API_CRASH_TESTS_FAIL"
}

run_reliability_cold_tier_tests() {
    run_mock_check "reliability_cold_tier_tests" "REASON: RELIABILITY_COLD_TIER_TESTS_PASS" "REASON: RELIABILITY_COLD_TIER_TESTS_FAIL"
}

run_reliability_metering_tests() {
    run_mock_check "reliability_metering_tests" "REASON: RELIABILITY_METERING_TESTS_PASS" "REASON: RELIABILITY_METERING_TESTS_FAIL"
}

run_compile_check() {
    run_mock_check "compile_check" "REASON: COMPILE_CHECK_PASS" "REASON: COMPILE_CHECK_FAIL"
}

run_clippy_check() {
    run_mock_check "clippy_check" "REASON: CLIPPY_CHECK_PASS" "REASON: CLIPPY_CHECK_FAIL"
}

run_reliability_sql_guard_test() {
    run_mock_check "security_sql_guard_tests" "REASON: RELIABILITY_SQL_GUARD_TESTS_PASS" "REASON: RELIABILITY_SQL_GUARD_TESTS_FAIL"
}

run_security_secret_scan() {
    run_mock_check "security_secret_scan" "REASON: SECURITY_SECRET_CLEAN" "REASON: SECURITY_SECRET_FOUND"
}

run_security_dep_audit() {
    if [ "\$FORCE_DEP_AUDIT_MISSING" = "1" ]; then
        echo "REASON: SECURITY_DEP_AUDIT_SKIP_TOOL_MISSING" >&2
        echo "security_dep_audit" >> "\$LOG_FILE"
        # Real run_security_dep_audit promotes tool-missing to failure (exit 1).
        return 1
    fi

    if [ "\$FORCE_DEP_AUDIT_FAIL" = "1" ]; then
        echo "REASON: SECURITY_DEP_AUDIT_FAIL" >&2
        echo "security_dep_audit" >> "\$LOG_FILE"
        return 1
    fi

    run_mock_check "security_dep_audit" "REASON: SECURITY_DEP_AUDIT_PASS" "REASON: SECURITY_DEP_AUDIT_FAIL"
}

run_security_sql_guard() {
    run_mock_check "security_sql_guard" "REASON: SECURITY_SQL_CLEAN" "REASON: SECURITY_SQL_UNSAFE"
}

run_security_cmd_injection() {
    run_mock_check "security_cmd_injection" "REASON: SECURITY_CMD_CLEAN" "REASON: SECURITY_CMD_INJECTION_FOUND"
}

run_load_gate_check() {
    run_mock_check "load_gate" "REASON: LOAD_BASELINE_PASS" "REASON: LOAD_REGRESSION_FAILURE"
}

check_stripe_key_present() {
    run_mock_check "check_stripe_key_present" "REASON: LIVE_CHECK_PASS" "REASON: LIVE_CHECK_FAIL"
}

check_stripe_key_live() {
    run_mock_check "check_stripe_key_live" "REASON: LIVE_CHECK_PASS" "REASON: LIVE_CHECK_FAIL"
}

check_stripe_webhook_secret_present() {
    run_mock_check "check_stripe_webhook_secret_present" "REASON: LIVE_CHECK_PASS" "REASON: LIVE_CHECK_FAIL"
}

check_stripe_webhook_forwarding() {
    run_mock_check "check_stripe_webhook_forwarding" "REASON: LIVE_CHECK_PASS" "REASON: LIVE_CHECK_FAIL"
}

check_usage_records_populated() {
    run_mock_check "check_usage_records_populated" "REASON: LIVE_CHECK_PASS" "REASON: LIVE_CHECK_FAIL"
}

check_rollup_current() {
    run_mock_check "check_rollup_current" "REASON: LIVE_CHECK_PASS" "REASON: LIVE_CHECK_FAIL"
}

run_live_rust_validation_tests() {
    run_mock_check "rust_validation_tests" "REASON: LIVE_RUST_VALIDATION_TESTS_PASS" "REASON: LIVE_RUST_VALIDATION_TESTS_FAIL"
}

run_backend_reliability_gate "\$@"
EOF

    if [ "${#gate_args[@]}" -eq 0 ]; then
        if FAIL_LIST="$fail_list" bash "$mock_dir/harness.sh" >"$mock_dir/stdout" 2>"$mock_dir/stderr"; then
            exit_code=0
        else
            exit_code=$?
        fi
    else
        if FAIL_LIST="$fail_list" bash "$mock_dir/harness.sh" "${gate_args[@]}" >"$mock_dir/stdout" 2>"$mock_dir/stderr"; then
            exit_code=0
        else
            exit_code=$?
        fi
    fi

    run_output="$(cat "$mock_dir/stdout")"

    echo "$run_output"
    return "$exit_code"
}

test_gate_default_mode_runs_all_checks_in_expected_order() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    local stdout exit_code=0

    stdout="$(run_gate_with_mocks "$mock_dir" "")" || exit_code="$?"

    assert_eq "${exit_code}" "0" "default mode should succeed with mocked passing checks"

    local checks_run
    checks_run="$(json_field "$stdout" checks_run)"
    assert_eq "$checks_run" "21" "default mode should run 21 checks"

    local check_names
    check_names="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print(','.join(item['name'] for item in d['check_results']))
" <<< "$stdout")"
    assert_eq "$check_names" "compile_check,clippy_check,reliability_profile_tests,reliability_scheduler_tests,reliability_replication_tests,reliability_api_crash_tests,reliability_cold_tier_tests,reliability_metering_tests,security_secret_scan,security_dep_audit,security_sql_guard,security_cmd_injection,security_sql_guard_tests,load_gate,check_stripe_key_present,check_stripe_key_live,check_stripe_webhook_secret_present,check_stripe_webhook_forwarding,check_usage_records_populated,check_rollup_current,rust_validation_tests" \
        "default mode should keep stable grouped check order"

    rm -rf "$mock_dir"
}

test_gate_reliability_only() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    local stdout exit_code=0

    stdout="$(run_gate_with_mocks "$mock_dir" "" --reliability-only)" || exit_code="$?"

    assert_eq "$exit_code" "0" "reliability-only should succeed"

    local checks_run
    checks_run="$(json_field "$stdout" checks_run)"
    assert_eq "$checks_run" "6" "reliability-only mode should run only 6 checks"

    rm -rf "$mock_dir"
}

test_gate_security_only() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    local stdout exit_code=0

    stdout="$(run_gate_with_mocks "$mock_dir" "" --security-only)" || exit_code="$?"
    assert_eq "$exit_code" "0" "security-only should succeed"

    local checks_run
    checks_run="$(json_field "$stdout" checks_run)"
    assert_eq "$checks_run" "5" "security-only mode should run only 5 checks"

    rm -rf "$mock_dir"
}

test_gate_live_only_skips_rust_validation_with_flag() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    local stdout exit_code=0

    stdout="$(run_gate_with_mocks "$mock_dir" "" --live-only --skip-rust-tests)" || exit_code="$?"
    assert_eq "$exit_code" "0" "live-only with --skip-rust-tests should succeed"

    local checks_run
    checks_run="$(json_field "$stdout" checks_run)"
    assert_eq "$checks_run" "6" "live-only with skip-rust-tests should run 6 live checks"

    local checks_skipped
    checks_skipped="$(json_field "$stdout" checks_skipped)"
    assert_eq "$checks_skipped" "1" "live-only with skip-rust-tests should report one skipped check"

    local rust_status rust_reason
    rust_status="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
for r in d['check_results']:
    if r['name'] == 'rust_validation_tests':
        print(r['status'])
        print(r.get('reason', ''))
        break
" <<< "$stdout")"
    assert_contains "$rust_status" "skipped" "rust_validation_tests should be skipped when --skip-rust-tests is used"
    assert_contains "$rust_status" "skip_rust_tests_flag" "skip reason should be skip_rust_tests_flag"

    rm -rf "$mock_dir"
}

test_gate_live_rust_validation_uses_integration_mode() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    local stdout exit_code=0
    stdout="$(PATH="$mock_dir:$PATH" bash -c "
        export __RUN_BACKEND_RELIABILITY_GATE_SOURCED=1
        source '$GATE_SCRIPT'

        check_stripe_key_present() { return 0; }
        check_stripe_key_live() { return 0; }
        check_stripe_webhook_secret_present() { return 0; }
        check_stripe_webhook_forwarding() { return 0; }
        check_usage_records_populated() { return 0; }
        check_rollup_current() { return 0; }

        run_backend_reliability_gate --live-only
    " 2>/dev/null)" || exit_code="$?"

    local checks_run cargo_invocation
    checks_run="$(json_field "$stdout" checks_run)"
    cargo_invocation="$(cat "$mock_dir/cargo_invocations.log")"

    assert_eq "$exit_code" "0" "live-only should succeed with mocked passing rust validation"
    assert_eq "$checks_run" "7" "live-only should run all 7 live checks"
    assert_contains "$cargo_invocation" "/infra" "aggregate gate should run rust validation from infra workspace"
    assert_contains "$cargo_invocation" "integration=1" "aggregate gate should force INTEGRATION=1 for rust validation"

    rm -rf "$mock_dir"
}

test_gate_profile_freshness_enforces_30_days() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    local profile_script backup_script restore_needed
    profile_script="$REPO_ROOT/scripts/tests/reliability_profile_test.sh"
    backup_script="$mock_dir/reliability_profile_test.sh.bak"
    restore_needed=0

    cleanup_profile_script() {
        if [ "$restore_needed" = "1" ] && [ -f "$backup_script" ]; then
            cp "$backup_script" "$profile_script"
        fi
        rm -rf "$mock_dir"
    }
    trap cleanup_profile_script RETURN

    cp "$profile_script" "$backup_script"
    restore_needed=1
    cat > "$profile_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "RELIABILITY_STALENESS_DAYS=${RELIABILITY_STALENESS_DAYS:-}" > "${PROFILE_ENV_LOG:?}"
exit 0
EOF
    chmod +x "$profile_script"

    local profile_env_log="$mock_dir/profile_env.log"
    local run_output exit_code=0
    run_output="$(
        PROFILE_ENV_LOG="$profile_env_log" bash -c "
            export __RUN_BACKEND_RELIABILITY_GATE_SOURCED=1
            source '$GATE_SCRIPT'
            run_reliability_profile_tests
        " 2>&1
    )" || exit_code="$?"

    assert_eq "$exit_code" "0" "profile check wrapper should execute successfully"
    assert_contains "$run_output" "REASON: RELIABILITY_PROFILE_TESTS_PASS" "profile check should emit PASS reason"

    local env_line
    env_line="$(head -n1 "$profile_env_log")"
    assert_eq "$env_line" "RELIABILITY_STALENESS_DAYS=30" "gate should enforce 30-day profile staleness threshold"
}

test_gate_profile_check_bootstraps_missing_artifacts() {
    local profiles_dir backup_dir had_profiles tmp_dir
    profiles_dir="$REPO_ROOT/scripts/reliability/profiles"
    tmp_dir="$(mktemp -d)"
    backup_dir="$tmp_dir/profiles.backup"
    had_profiles=0

    cleanup_profiles_dir() {
        rm -rf "$profiles_dir"
        if [ "$had_profiles" -eq 1 ] && [ -d "$backup_dir" ]; then
            mv "$backup_dir" "$profiles_dir"
        fi
        rm -rf "$tmp_dir"
    }
    trap cleanup_profiles_dir RETURN

    if [ -d "$profiles_dir" ]; then
        mv "$profiles_dir" "$backup_dir"
        had_profiles=1
    fi

    local run_output exit_code=0
    run_output="$(
        bash -c "
            export __RUN_BACKEND_RELIABILITY_GATE_SOURCED=1
            source '$GATE_SCRIPT'
            run_reliability_profile_tests
        " 2>&1
    )" || exit_code="$?"

    assert_eq "$exit_code" "0" "profile check should succeed by bootstrapping missing artifacts"
    assert_contains "$run_output" "REASON: RELIABILITY_PROFILE_TESTS_PASS" "bootstrapped profile check should emit PASS reason"
    assert_contains "$run_output" "profile artifacts bootstrapped via seed-test-profiles.sh" \
        "profile check should report bootstrap path when artifacts are missing"
}

test_gate_conflicting_mode_flags_fail() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    local stdout exit_code=0

    stdout="$(run_gate_with_mocks "$mock_dir" "" --reliability-only --security-only)" || exit_code="$?"
    assert_eq "$exit_code" "1" "conflicting mode flags should fail"

    local stderr
    stderr="$(cat "$mock_dir/stderr")"
    assert_contains "$stderr" "Only one mode may be selected" "conflicting mode flags should emit validation error"

    rm -rf "$mock_dir"
}

test_gate_unknown_flag_fails() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    local stdout exit_code=0

    stdout="$(run_gate_with_mocks "$mock_dir" "" --does-not-exist)" || exit_code="$?"
    assert_eq "$exit_code" "1" "unknown flags should fail"

    rm -rf "$mock_dir"
}

test_gate_fail_fast_stops_on_first_failure() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    local stdout exit_code=0

    stdout="$(run_gate_with_mocks "$mock_dir" "reliability_profile_tests" --reliability-only --fail-fast)" || exit_code="$?"
    assert_eq "$exit_code" "1" "fail-fast with an early failure should fail"

    local checks_run checks_failed
    checks_run="$(json_field "$stdout" checks_run)"
    checks_failed="$(json_field "$stdout" checks_failed)"
    assert_eq "$checks_run" "1" "fail-fast should run only one non-skipped check when failure happens"
    assert_eq "$checks_failed" "1" "fail-fast failure count should be 1"

    local called_count
    called_count="$(wc -l < "$mock_dir/calls.log" | tr -d ' ')"
    assert_eq "$called_count" "1" "fail-fast should not execute subsequent checks"

    rm -rf "$mock_dir"
}

test_gate_mock_helper_handles_posix_errexit_on_failure() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    local stdout exit_code=0
    local had_posix

    had_posix="$(set -o | awk '$1 == "posix" { print $2 }')"
    set -o posix

    stdout="$(run_gate_with_mocks "$mock_dir" "reliability_profile_tests" --reliability-only)" || exit_code="$?"

    if [ "$had_posix" = "on" ]; then
        set -o posix
    else
        set +o posix
    fi

    assert_eq "$exit_code" "1" "mock helper should return failing exit code with POSIX mode enabled"
    assert_contains "$stdout" "\"checks_failed\": 1" "mock helper should still emit JSON output on failure with POSIX mode enabled"

    rm -rf "$mock_dir"
}

test_gate_dep_audit_missing_tool_is_failure_reason() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    local stdout exit_code=0

    export FORCE_DEP_AUDIT_MISSING=1
    stdout="$(run_gate_with_mocks "$mock_dir" "" --security-only)" || exit_code="$?"
    unset FORCE_DEP_AUDIT_MISSING

    assert_eq "$exit_code" "1" "missing cargo-audit should fail aggregate gate"

    local failures
    failures="$(json_field "$stdout" failures)"
    assert_contains "$failures" "security_dep_audit" "security_dep_audit should be listed in failures when tool missing"

    local dep_reason
    dep_reason="$(json_check_field "$stdout" "security_dep_audit" "reason")"
    assert_contains "$dep_reason" "SECURITY_DEP_AUDIT_SKIP_TOOL_MISSING" "missing cargo-audit should surface SECURITY_DEP_AUDIT_SKIP_TOOL_MISSING reason"

    rm -rf "$mock_dir"
}

test_gate_failure_includes_error_class() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    local stdout exit_code=0

    stdout="$(run_gate_with_mocks "$mock_dir" "security_secret_scan" --security-only)" || exit_code="$?"
    assert_eq "$exit_code" "1" "security failure should fail gate"

    local secret_error_class
    secret_error_class="$(json_check_field "$stdout" "security_secret_scan" "error_class")"
    assert_eq "$secret_error_class" "runtime" "runtime failures should include error_class=runtime"

    rm -rf "$mock_dir"
}

test_gate_default_mode_includes_compile_and_clippy() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    local stdout exit_code=0

    stdout="$(run_gate_with_mocks "$mock_dir" "")" || exit_code="$?"

    assert_eq "$exit_code" "0" "default mode with compile should succeed"

    local checks_run
    checks_run="$(json_field "$stdout" checks_run)"
    assert_eq "$checks_run" "21" "default mode should run 21 checks (compile=2 + reliability=6 + security=5 + load=1 + live=7)"

    local first_two
    first_two="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
names = [item['name'] for item in d['check_results']]
print(','.join(names[:2]))
" <<< "$stdout")"
    assert_eq "$first_two" "compile_check,clippy_check" "compile_check and clippy_check should be first two checks in default mode"

    rm -rf "$mock_dir"
}

test_gate_compile_check_ordering() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    local stdout exit_code=0

    stdout="$(run_gate_with_mocks "$mock_dir" "")" || exit_code="$?"

    local positions
    positions="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
names = [item['name'] for item in d['check_results']]
ci = names.index('compile_check') if 'compile_check' in names else -1
cli = names.index('clippy_check') if 'clippy_check' in names else -1
ri = names.index('reliability_profile_tests') if 'reliability_profile_tests' in names else -1
print(f'{ci},{cli},{ri}')
" <<< "$stdout")"
    local compile_idx clippy_idx rel_idx
    compile_idx="$(echo "$positions" | cut -d, -f1)"
    clippy_idx="$(echo "$positions" | cut -d, -f2)"
    rel_idx="$(echo "$positions" | cut -d, -f3)"

    assert_eq "$compile_idx" "0" "compile_check should be at position 0"
    assert_eq "$clippy_idx" "1" "clippy_check should be at position 1"
    assert_eq "$rel_idx" "2" "reliability_profile_tests should be at position 2 (after compile checks)"

    rm -rf "$mock_dir"
}

test_gate_fail_fast_compile_failure_skips_all() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    local stdout exit_code=0

    stdout="$(run_gate_with_mocks "$mock_dir" "compile_check" --fail-fast)" || exit_code="$?"

    assert_eq "$exit_code" "1" "fail-fast with compile_check failure should exit 1"

    local checks_run checks_skipped
    checks_run="$(json_field "$stdout" checks_run)"
    checks_skipped="$(json_field "$stdout" checks_skipped)"
    assert_eq "$checks_run" "1" "fail-fast compile failure should run only 1 check"
    assert_eq "$checks_skipped" "20" "fail-fast compile failure should skip remaining 20 checks"

    rm -rf "$mock_dir"
}

test_gate_modes_exclude_compile_checks() {
    local mock_dir exit_code stdout checks_run

    mock_dir="$(mktemp -d)"
    exit_code=0
    stdout="$(run_gate_with_mocks "$mock_dir" "" --reliability-only)" || exit_code="$?"
    checks_run="$(json_field "$stdout" checks_run)"
    assert_eq "$checks_run" "6" "--reliability-only should run exactly 6 checks (compile excluded)"
    rm -rf "$mock_dir"

    mock_dir="$(mktemp -d)"
    exit_code=0
    stdout="$(run_gate_with_mocks "$mock_dir" "" --security-only)" || exit_code="$?"
    checks_run="$(json_field "$stdout" checks_run)"
    assert_eq "$checks_run" "5" "--security-only should run exactly 5 checks (compile excluded)"
    rm -rf "$mock_dir"

    mock_dir="$(mktemp -d)"
    exit_code=0
    stdout="$(run_gate_with_mocks "$mock_dir" "" --live-only)" || exit_code="$?"
    checks_run="$(json_field "$stdout" checks_run)"
    assert_eq "$checks_run" "7" "--live-only should run exactly 7 checks (compile excluded)"
    rm -rf "$mock_dir"

    mock_dir="$(mktemp -d)"
    exit_code=0
    stdout="$(run_gate_with_mocks "$mock_dir" "" --load-only)" || exit_code="$?"
    checks_run="$(json_field "$stdout" checks_run)"
    assert_eq "$checks_run" "1" "--load-only should run exactly 1 check (compile excluded)"
    rm -rf "$mock_dir"
}

test_gate_compile_failure_json_contract() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    local stdout exit_code=0

    stdout="$(run_gate_with_mocks "$mock_dir" "compile_check")" || exit_code="$?"

    assert_eq "$exit_code" "1" "compile_check failure should exit 1"

    local compile_status
    compile_status="$(json_check_field "$stdout" "compile_check" "status")"
    assert_eq "$compile_status" "fail" "compile_check failure should have status=fail"

    local compile_error_class
    compile_error_class="$(json_check_field "$stdout" "compile_check" "error_class")"
    assert_eq "$compile_error_class" "runtime" "compile_check failure should have error_class=runtime"

    local compile_reason
    compile_reason="$(json_check_field "$stdout" "compile_check" "reason")"
    assert_contains "$compile_reason" "COMPILE_CHECK_FAIL" "compile_check failure reason should contain COMPILE_CHECK_FAIL"

    local failures
    failures="$(json_field "$stdout" failures)"
    assert_contains "$failures" "compile_check" "compile_check should appear in failures array"

    rm -rf "$mock_dir"
}

test_gate_stdout_json_only_after_compile_addition() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    local stdout exit_code=0

    stdout="$(run_gate_with_mocks "$mock_dir" "")" || exit_code="$?"

    local parse_exit=0
    python3 -c "
import json, sys
content = sys.stdin.read().strip()
if not content:
    print('stdout is empty', file=sys.stderr)
    sys.exit(1)
try:
    json.loads(content)
except json.JSONDecodeError as e:
    print(f'stdout is not valid JSON: {e}', file=sys.stderr)
    sys.exit(1)
" <<< "$stdout" || parse_exit=$?
    assert_eq "$parse_exit" "0" "stdout should be parseable as JSON (no non-JSON lines leaked from compile checks)"

    rm -rf "$mock_dir"
}

test_runbook_covers_stage6_failure_modes() {
    local runbook="$REPO_ROOT/docs/runbooks/incident-response.md"

    if grep -q "Profile freshness failure" "$runbook"; then
        pass "runbook covers 'Profile freshness failure'"
    else
        fail "runbook is missing 'Profile freshness failure' section"
    fi

    if grep -q "Replication auth revocation" "$runbook"; then
        pass "runbook covers 'Replication auth revocation'"
    else
        fail "runbook is missing 'Replication auth revocation' section"
    fi

    if grep -q "Scheduler no-capacity" "$runbook"; then
        pass "runbook covers 'Scheduler no-capacity'"
    else
        fail "runbook is missing 'Scheduler no-capacity' section"
    fi
}

for test_fn in \
    test_gate_default_mode_runs_all_checks_in_expected_order \
    test_gate_reliability_only \
    test_gate_security_only \
    test_gate_live_only_skips_rust_validation_with_flag \
    test_gate_live_rust_validation_uses_integration_mode \
    test_gate_profile_freshness_enforces_30_days \
    test_gate_profile_check_bootstraps_missing_artifacts \
    test_gate_conflicting_mode_flags_fail \
    test_gate_unknown_flag_fails \
    test_gate_fail_fast_stops_on_first_failure \
    test_gate_mock_helper_handles_posix_errexit_on_failure \
    test_gate_dep_audit_missing_tool_is_failure_reason \
    test_gate_failure_includes_error_class \
    test_gate_default_mode_includes_compile_and_clippy \
    test_gate_compile_check_ordering \
    test_gate_fail_fast_compile_failure_skips_all \
    test_gate_modes_exclude_compile_checks \
    test_gate_compile_failure_json_contract \
    test_gate_stdout_json_only_after_compile_addition \
    test_runbook_covers_stage6_failure_modes
do
    "$test_fn"
done

if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "All tests passed: $PASS_COUNT"
    exit 0
fi

echo "Tests failed: $FAIL_COUNT"
exit 1
