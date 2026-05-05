#!/usr/bin/env bash
# Tests for scripts/live-backend-gate.sh: Backend launch gate orchestration.
# Validates gate script logic using mock check functions — no real infra needed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE_SCRIPT="$REPO_ROOT/scripts/live-backend-gate.sh"
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

assert_not_contains() {
    local actual="$1" unexpected_substr="$2" msg="$3"
    if [[ "$actual" == *"$unexpected_substr"* ]]; then
        fail "$msg (unexpected substring '$unexpected_substr' found in '$actual')"
    else
        pass "$msg"
    fi
}

# Helper: extract a JSON field value (simple string/number/bool/array).
# Uses python3 for reliable parsing — no jq dependency.
json_field() {
    local json="$1" field="$2"
    python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(json.dumps(d['$field']))" <<< "$json"
}

# Helper: extract a field from a check_result entry by check name.
# Returns "MISSING" if the field doesn't exist, "NOT_FOUND" if the check name isn't found,
# or "PARSE_ERROR" if JSON parsing fails.
check_result_field() {
    local json="$1" check_name="$2" field="$3"
    python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    for r in d.get('check_results', []):
        if r.get('name') == sys.argv[1]:
            print(r.get(sys.argv[2], 'MISSING'))
            break
    else:
        print('NOT_FOUND')
except:
    print('PARSE_ERROR')
" "$check_name" "$field" <<< "$json"
}

# ============================================================================
# Core structure and subshell isolation
# ============================================================================

test_gate_sources_libs_and_exports_gate_env() {
    # Gate script should source the three libs and export BACKEND_LIVE_GATE=1.
    # We verify by sourcing the gate script in a controlled env and checking
    # that BACKEND_LIVE_GATE=1 is set, and that the check functions exist.
    local output exit_code

    # Create mock dir to prevent real check execution
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    output="$(PATH="$mock_dir:$PATH" bash -c "
        # Source the gate script without running main
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'

        # Verify BACKEND_LIVE_GATE is exported
        echo \"GATE=\$BACKEND_LIVE_GATE\"

        # Verify check functions are defined
        type check_stripe_key_present >/dev/null 2>&1 && echo 'FN:check_stripe_key_present'
        type check_stripe_key_live >/dev/null 2>&1 && echo 'FN:check_stripe_key_live'
        type check_stripe_webhook_secret_present >/dev/null 2>&1 && echo 'FN:check_stripe_webhook_secret_present'
        type check_stripe_webhook_forwarding >/dev/null 2>&1 && echo 'FN:check_stripe_webhook_forwarding'
        type check_usage_records_populated >/dev/null 2>&1 && echo 'FN:check_usage_records_populated'
        type check_rollup_current >/dev/null 2>&1 && echo 'FN:check_rollup_current'
        type live_gate_require >/dev/null 2>&1 && echo 'FN:live_gate_require'
    " 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "sourcing gate script should succeed"
    assert_contains "$output" "GATE=1" "BACKEND_LIVE_GATE should be 1"
    assert_contains "$output" "FN:check_stripe_key_present" "check_stripe_key_present should be defined"
    assert_contains "$output" "FN:check_stripe_key_live" "check_stripe_key_live should be defined"
    assert_contains "$output" "FN:check_stripe_webhook_secret_present" "check_stripe_webhook_secret_present should be defined"
    assert_contains "$output" "FN:check_stripe_webhook_forwarding" "check_stripe_webhook_forwarding should be defined"
    assert_contains "$output" "FN:check_usage_records_populated" "check_usage_records_populated should be defined"
    assert_contains "$output" "FN:check_rollup_current" "check_rollup_current should be defined"
    assert_contains "$output" "FN:live_gate_require" "live_gate_require should be defined"
}

test_gate_respects_backend_live_gate_override_when_sourced() {
    # Explicit BACKEND_LIVE_GATE should be preserved when sourcing.
    local output exit_code

    output="$(bash -c "
        export BACKEND_LIVE_GATE=0
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'
        echo \"GATE=\$BACKEND_LIVE_GATE\"
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "0" "sourcing gate script with override should succeed"
    assert_contains "$output" "GATE=0" "BACKEND_LIVE_GATE override should be preserved when sourcing"
}

test_gate_runs_all_checks_even_when_early_ones_fail() {
    # Mock first check to fail, verify all checks still run (run-all + subshell isolation).
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    local stdout stderr exit_code
    stdout="$(PATH="$mock_dir:$PATH" bash -c "
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'

        # Override all checks: first one fails, rest pass
        check_stripe_key_present() { exit 1; }
        check_stripe_key_live() { return 0; }
        check_stripe_webhook_secret_present() { return 0; }
        check_stripe_webhook_forwarding() { return 0; }
        check_usage_records_populated() { return 0; }
        check_rollup_current() { return 0; }

        run_gate --skip-rust-tests
    " 2>"$mock_dir/stderr")" || exit_code=$?

    stderr="$(cat "$mock_dir/stderr")"

    # Should have run all 6 checks despite first one failing
    local checks_run
    checks_run="$(json_field "$stdout" checks_run)"

    rm -rf "$mock_dir"

    assert_eq "$checks_run" "6" "all 6 checks should run even when first fails (run-all behavior)"
    assert_eq "${exit_code:-0}" "1" "exit code should be non-zero when a check fails"
}

# ============================================================================
# Check orchestration
# ============================================================================

test_gate_runs_all_6_bash_checks_in_order() {
    # Mock all checks to pass, verify checks_run=6 and correct names in JSON.
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    local stdout stderr exit_code
    stdout="$(PATH="$mock_dir:$PATH" bash -c "
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'

        # Override all checks to pass
        check_stripe_key_present() { return 0; }
        check_stripe_key_live() { return 0; }
        check_stripe_webhook_secret_present() { return 0; }
        check_stripe_webhook_forwarding() { return 0; }
        check_usage_records_populated() { return 0; }
        check_rollup_current() { return 0; }

        run_gate --skip-rust-tests
    " 2>"$mock_dir/stderr")" || exit_code=$?

    stderr="$(cat "$mock_dir/stderr")"

    local checks_run
    checks_run="$(json_field "$stdout" checks_run)"

    rm -rf "$mock_dir"

    assert_eq "$checks_run" "6" "checks_run should be 6 when all bash checks run"
    assert_eq "${exit_code:-0}" "0" "exit code should be 0 when all checks pass"

    # Verify check names appear in stderr progress output
    assert_contains "$stderr" "check_stripe_key_present" "stderr should show check_stripe_key_present"
    assert_contains "$stderr" "check_stripe_key_live" "stderr should show check_stripe_key_live"
    assert_contains "$stderr" "check_stripe_webhook_secret_present" "stderr should show check_stripe_webhook_secret_present"
    assert_contains "$stderr" "check_stripe_webhook_forwarding" "stderr should show check_stripe_webhook_forwarding"
    assert_contains "$stderr" "check_usage_records_populated" "stderr should show check_usage_records_populated"
    assert_contains "$stderr" "check_rollup_current" "stderr should show check_rollup_current"
}

test_gate_runs_cargo_rust_tests_as_composite_check() {
    # Mock cargo to succeed → check passes, and ensure run_gate executes
    # rust validation from infra/ with INTEGRATION=1.
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    local stdout exit_code
    stdout="$(PATH="$mock_dir:$PATH" bash -c "
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'

        # Override all bash checks to pass
        check_stripe_key_present() { return 0; }
        check_stripe_key_live() { return 0; }
        check_stripe_webhook_secret_present() { return 0; }
        check_stripe_webhook_forwarding() { return 0; }
        check_usage_records_populated() { return 0; }
        check_rollup_current() { return 0; }

        run_gate
    " 2>/dev/null)" || exit_code=$?

    local checks_run
    checks_run="$(json_field "$stdout" checks_run)"
    local cargo_invocation=""
    [ -f "$mock_dir/cargo_invocations.log" ] && cargo_invocation="$(cat "$mock_dir/cargo_invocations.log")"

    # cargo should have been invoked
    local cargo_calls="0"
    [ -f "$mock_dir/cargo_invocations.log" ] && \
        cargo_calls="$(grep -c '^cargo invoked ' "$mock_dir/cargo_invocations.log" || true)"
    assert_eq "$cargo_calls" "1" "cargo should be invoked once"
    assert_eq "$checks_run" "7" "checks_run should be 7 (6 bash + 1 cargo)"
    assert_contains "$cargo_invocation" "/infra" "rust validation should run cargo from infra workspace"
    assert_contains "$cargo_invocation" "integration=1" "rust validation should force INTEGRATION=1"
    assert_contains "$cargo_invocation" "args=test -p api --test integration_metering_pipeline_test -- --test-threads=1" \
        "rust validation should run the full integration_metering_pipeline_test target"
    assert_not_contains "$cargo_invocation" " validate_" \
        "rust validation should not use a name filter that skips all metering tests"
    assert_eq "${exit_code:-0}" "0" "exit code should be 0 when all pass"

    rm -rf "$mock_dir"
}

test_gate_cargo_failure_appears_in_failures() {
    # Mock cargo to fail → should appear in failures array
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" fail

    local stdout exit_code
    stdout="$(PATH="$mock_dir:$PATH" bash -c "
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'

        # Override all bash checks to pass
        check_stripe_key_present() { return 0; }
        check_stripe_key_live() { return 0; }
        check_stripe_webhook_secret_present() { return 0; }
        check_stripe_webhook_forwarding() { return 0; }
        check_usage_records_populated() { return 0; }
        check_rollup_current() { return 0; }

        run_gate
    " 2>/dev/null)" || exit_code=$?

    local failures checks_failed
    failures="$(json_field "$stdout" failures)"
    checks_failed="$(json_field "$stdout" checks_failed)"

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "exit code should be non-zero when cargo fails"
    assert_eq "$checks_failed" "1" "checks_failed should be 1"
    assert_contains "$failures" "rust_validation_tests" "failures should contain rust_validation_tests"
}

# ============================================================================
# JSON summary output
# ============================================================================

test_json_all_pass_structure() {
    # When all checks pass, verify full JSON structure.
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    local stdout exit_code
    stdout="$(PATH="$mock_dir:$PATH" bash -c "
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'

        check_stripe_key_present() { return 0; }
        check_stripe_key_live() { return 0; }
        check_stripe_webhook_secret_present() { return 0; }
        check_stripe_webhook_forwarding() { return 0; }
        check_usage_records_populated() { return 0; }
        check_rollup_current() { return 0; }

        run_gate
    " 2>/dev/null)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "exit code should be 0 when all pass"

    # Validate JSON is parseable
    local valid
    valid="$(echo "$stdout" | python3 -m json.tool >/dev/null 2>&1&& echo "yes" || echo "no")"
    assert_eq "$valid" "yes" "JSON output should be parseable by python3 json.tool"

    local passed checks_run checks_failed failures elapsed
    passed="$(json_field "$stdout" passed)"
    checks_run="$(json_field "$stdout" checks_run)"
    checks_failed="$(json_field "$stdout" checks_failed)"
    failures="$(json_field "$stdout" failures)"
    elapsed="$(json_field "$stdout" elapsed_ms)"

    assert_eq "$passed" "true" "passed should be true"
    assert_eq "$checks_run" "7" "checks_run should be 7"
    assert_eq "$checks_failed" "0" "checks_failed should be 0"
    assert_eq "$failures" "[]" "failures should be empty array"

    # elapsed_ms should be a positive number
    local elapsed_positive
    elapsed_positive="$(python3 -c "print('yes' if $elapsed > 0 else 'no')")"
    assert_eq "$elapsed_positive" "yes" "elapsed_ms should be > 0"
}

test_json_partial_fail_structure() {
    # When 2 of 7 checks fail, verify JSON structure.
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" fail  # cargo fails = 1 failure

    local stdout exit_code
    stdout="$(PATH="$mock_dir:$PATH" bash -c "
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'

        # 1 bash failure + 1 cargo failure = 2 failures
        check_stripe_key_present() { exit 1; }
        check_stripe_key_live() { return 0; }
        check_stripe_webhook_secret_present() { return 0; }
        check_stripe_webhook_forwarding() { return 0; }
        check_usage_records_populated() { return 0; }
        check_rollup_current() { return 0; }

        run_gate
    " 2>/dev/null)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "exit code should be non-zero when checks fail"

    local passed checks_run checks_failed failures
    passed="$(json_field "$stdout" passed)"
    checks_run="$(json_field "$stdout" checks_run)"
    checks_failed="$(json_field "$stdout" checks_failed)"
    failures="$(json_field "$stdout" failures)"

    assert_eq "$passed" "false" "passed should be false"
    assert_eq "$checks_run" "7" "checks_run should still be 7 (run-all)"
    assert_eq "$checks_failed" "2" "checks_failed should be 2"
    assert_contains "$failures" "check_stripe_key_present" "failures should contain check_stripe_key_present"
    assert_contains "$failures" "rust_validation_tests" "failures should contain rust_validation_tests"
}

# ============================================================================
# Optional flags
# ============================================================================

test_skip_rust_tests_flag() {
    # --skip-rust-tests should skip cargo execution entirely.
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    local stdout exit_code
    stdout="$(PATH="$mock_dir:$PATH" bash -c "
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'

        check_stripe_key_present() { return 0; }
        check_stripe_key_live() { return 0; }
        check_stripe_webhook_secret_present() { return 0; }
        check_stripe_webhook_forwarding() { return 0; }
        check_usage_records_populated() { return 0; }
        check_rollup_current() { return 0; }

        run_gate --skip-rust-tests
    " 2>/dev/null)" || exit_code=$?

    # cargo should NOT have been invoked
    local cargo_calls
    if [ -f "$mock_dir/cargo_invocations.log" ]; then
        cargo_calls="$(grep -c '^cargo invoked ' "$mock_dir/cargo_invocations.log" || true)"
    else
        cargo_calls="0"
    fi

    local checks_run
    checks_run="$(json_field "$stdout" checks_run)"

    rm -rf "$mock_dir"

    assert_eq "$cargo_calls" "0" "cargo should NOT be invoked with --skip-rust-tests"
    assert_eq "$checks_run" "6" "checks_run should be 6 (skip rust = 7-1)"
    assert_eq "${exit_code:-0}" "0" "exit code should be 0 when all bash checks pass"
}

test_fail_fast_flag() {
    # --fail-fast should stop on first failure.
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    local stdout stderr exit_code
    stdout="$(PATH="$mock_dir:$PATH" bash -c "
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'

        # Second check fails — later checks should NOT run
        check_stripe_key_present() { return 0; }
        check_stripe_key_live() { exit 1; }
        check_stripe_webhook_secret_present() { return 0; }
        check_stripe_webhook_forwarding() { return 0; }
        check_usage_records_populated() { return 0; }
        check_rollup_current() { return 0; }

        run_gate --fail-fast --skip-rust-tests
    " 2>"$mock_dir/stderr")" || exit_code=$?

    stderr="$(cat "$mock_dir/stderr")"

    local checks_run
    checks_run="$(json_field "$stdout" checks_run)"

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "exit code should be non-zero on failure"

    # checks_run should be less than 6 (stopped early)
    local ran_fewer
    ran_fewer="$(python3 -c "print('yes' if $checks_run < 6 else 'no')")"
    assert_eq "$ran_fewer" "yes" "checks_run ($checks_run) should be < 6 (fail-fast stopped early)"
}

test_staging_only_flag_soft_skips_commerce_checks() {
    # Staging-only should force BACKEND_LIVE_GATE=0 for commerce checks and
    # report explicit skip metadata without dry-run wording.
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    local stdout exit_code
    stdout="$(PATH="$mock_dir:$PATH" bash -c "
        export BACKEND_LIVE_GATE=1
        export __LIVE_BACKEND_GATE_SOURCED=1
        unset STRIPE_SECRET_KEY STRIPE_TEST_SECRET_KEY STRIPE_WEBHOOK_SECRET DATABASE_URL INTEGRATION_DB_URL
        source '$GATE_SCRIPT'
        run_gate --skip-rust-tests --staging-only
    " 2>/dev/null)" || exit_code=$?

    local checks_skipped stripe_status stripe_reason
    checks_skipped="$(json_field "$stdout" checks_skipped)"
    stripe_status="$(check_result_field "$stdout" "check_stripe_key_present" "status")"
    stripe_reason="$(check_result_field "$stdout" "check_stripe_key_present" "reason")"

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "staging-only run should pass with soft-skipped commerce preconditions"
    assert_eq "$(json_field "$stdout" passed)" "true" "staging-only run should report passed=true"
    assert_eq "$stripe_status" "skipped" "staging-only run should record skipped stripe checks"
    assert_contains "$stripe_reason" "STRIPE_SECRET_KEY" "staging-only skip reason should preserve helper-owned precondition text"
    assert_not_contains "$stripe_reason" "dry_run" "staging-only skip metadata should not reuse dry-run wording"
    assert_eq "$checks_skipped" "7" "staging-only + --skip-rust-tests should skip all seven checks in commerce mode"
}

# ============================================================================
# Stage 1: Silent-skip detection in launch mode
# ============================================================================

test_skip_rust_tests_surfaces_skip_in_json() {
    # RED: --skip-rust-tests should record an explicit skip entry in check_results,
    # not silently omit the check. Currently no check_results field exists.
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    local stdout exit_code
    stdout="$(PATH="$mock_dir:$PATH" bash -c "
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'

        check_stripe_key_present() { return 0; }
        check_stripe_key_live() { return 0; }
        check_stripe_webhook_secret_present() { return 0; }
        check_stripe_webhook_forwarding() { return 0; }
        check_usage_records_populated() { return 0; }
        check_rollup_current() { return 0; }

        run_gate --skip-rust-tests
    " 2>/dev/null)" || exit_code=$?

    rm -rf "$mock_dir"

    # JSON must contain a check_results array
    local has_check_results
    has_check_results="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print('yes' if 'check_results' in d else 'no')
" <<< "$stdout")"
    assert_eq "$has_check_results" "yes" "JSON should contain check_results array"

    # check_results should have a skip entry for rust_validation_tests
    local has_skip_entry
    has_skip_entry="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
results = d.get('check_results', [])
skip_entries = [r for r in results if r.get('name') == 'rust_validation_tests' and r.get('status') == 'skipped']
print('yes' if skip_entries else 'no')
" <<< "$stdout")"
    assert_eq "$has_skip_entry" "yes" "check_results should have a skipped entry for rust_validation_tests"
}

test_json_has_checks_skipped_count() {
    # RED: JSON output should include a checks_skipped integer.
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    local stdout exit_code
    stdout="$(PATH="$mock_dir:$PATH" bash -c "
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'

        check_stripe_key_present() { return 0; }
        check_stripe_key_live() { return 0; }
        check_stripe_webhook_secret_present() { return 0; }
        check_stripe_webhook_forwarding() { return 0; }
        check_usage_records_populated() { return 0; }
        check_rollup_current() { return 0; }

        run_gate --skip-rust-tests
    " 2>/dev/null)" || exit_code=$?

    rm -rf "$mock_dir"

    local checks_skipped
    checks_skipped="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print(d.get('checks_skipped', 'MISSING'))
" <<< "$stdout")"
    assert_eq "$checks_skipped" "1" "checks_skipped should be 1 when rust tests are skipped"
}

test_skip_pass_distinguishable_from_real_pass() {
    # RED: run_check must distinguish a real pass from a check that internally
    # skipped its validation. Currently run_check treats exit 0 as "pass" always.
    # A check that has a skip marker in its output should be recorded differently.
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    local stdout exit_code
    stdout="$(PATH="$mock_dir:$PATH" bash -c "
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'

        # This check 'passes' but prints a skip marker — gate OFF in subshell
        check_stripe_key_present() {
            echo '[skip] STRIPE_TEST_SECRET_KEY is not set' >&2
            return 0
        }
        check_stripe_key_live() { return 0; }
        check_stripe_webhook_secret_present() { return 0; }
        check_stripe_webhook_forwarding() { return 0; }
        check_usage_records_populated() { return 0; }
        check_rollup_current() { return 0; }

        run_gate --skip-rust-tests
    " 2>/dev/null)" || exit_code=$?

    rm -rf "$mock_dir"

    # The check that printed [skip] should NOT be recorded as "pass"
    local first_status
    first_status="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
results = d.get('check_results', [])
for r in results:
    if r.get('name') == 'check_stripe_key_present':
        print(r.get('status', 'MISSING'))
        break
else:
    print('NOT_FOUND')
" <<< "$stdout")"
    assert_eq "$first_status" "skipped" "check with [skip] in output should be recorded as skipped, not pass"
}

test_gate_fails_when_stripe_check_skipped() {
    # Checklist Stage 1 RED: skipped stripe check in launch mode must fail gate.
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    local stdout exit_code
    stdout="$(PATH="$mock_dir:$PATH" bash -c "
        export BACKEND_LIVE_GATE=1
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'

        check_stripe_key_present() {
            echo '[skip] stripe key intentionally skipped' >&2
            return 0
        }
        check_stripe_key_live() { return 0; }
        check_stripe_webhook_secret_present() { return 0; }
        check_stripe_webhook_forwarding() { return 0; }
        check_usage_records_populated() { return 0; }
        check_rollup_current() { return 0; }

        run_gate --skip-rust-tests
    " 2>/dev/null)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "launch mode should fail when stripe check is skipped"
    assert_eq "$(json_field "$stdout" passed)" "false" "JSON passed should be false when stripe check is skipped"
}

test_gate_fails_when_metering_check_skipped() {
    # Checklist Stage 1 RED: skipped metering check in launch mode must fail gate.
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    local stdout exit_code
    stdout="$(PATH="$mock_dir:$PATH" bash -c "
        export BACKEND_LIVE_GATE=1
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'

        check_stripe_key_present() { return 0; }
        check_stripe_key_live() { return 0; }
        check_stripe_webhook_secret_present() { return 0; }
        check_stripe_webhook_forwarding() { return 0; }
        check_usage_records_populated() {
            echo '[skip] usage records check intentionally skipped' >&2
            return 0
        }
        check_rollup_current() { return 0; }

        run_gate --skip-rust-tests
    " 2>/dev/null)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "launch mode should fail when metering check is skipped"
    assert_eq "$(json_field "$stdout" passed)" "false" "JSON passed should be false when metering check is skipped"
}

test_gate_fails_when_multiple_checks_skipped() {
    # Checklist Stage 1 RED: two skipped checks should fail gate and count skips.
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    local stdout exit_code
    stdout="$(PATH="$mock_dir:$PATH" bash -c "
        export BACKEND_LIVE_GATE=1
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'

        check_stripe_key_present() {
            echo '[skip] skipped stripe precondition' >&2
            return 0
        }
        check_stripe_key_live() { return 0; }
        check_stripe_webhook_secret_present() { return 0; }
        check_stripe_webhook_forwarding() { return 0; }
        check_usage_records_populated() {
            echo '[skip] skipped metering precondition' >&2
            return 0
        }
        check_rollup_current() { return 0; }

        run_gate --skip-rust-tests
    " 2>/dev/null)" || exit_code=$?

    local checks_skipped
    checks_skipped="$(json_field "$stdout" checks_skipped)"

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "launch mode should fail when multiple checks are skipped"
    assert_eq "$(json_field "$stdout" passed)" "false" "JSON passed should be false when multiple checks are skipped"

    local at_least_two
    at_least_two="$(python3 -c "print('yes' if int($checks_skipped) >= 2 else 'no')")"
    assert_eq "$at_least_two" "yes" "checks_skipped should be >= 2 when multiple checks are skipped"
}

test_json_passed_true_when_only_exempt_skip() {
    # Checklist Stage 1 RED: rust_validation_tests skip_rust_tests_flag is exempt.
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    local stdout exit_code
    stdout="$(PATH="$mock_dir:$PATH" bash -c "
        export BACKEND_LIVE_GATE=1
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'

        check_stripe_key_present() { return 0; }
        check_stripe_key_live() { return 0; }
        check_stripe_webhook_secret_present() { return 0; }
        check_stripe_webhook_forwarding() { return 0; }
        check_usage_records_populated() { return 0; }
        check_rollup_current() { return 0; }

        run_gate --skip-rust-tests
    " 2>/dev/null)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "gate should pass when only rust skip exemption is used"
    assert_eq "$(json_field "$stdout" passed)" "true" "JSON passed should be true for exempt rust skip only"
}

# ============================================================================
# Stage 1: Reason codes for skip/fail paths
# ============================================================================

test_failures_include_reason_in_check_results() {
    # RED: Each failed check should have a reason string in check_results.
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    local stdout exit_code
    stdout="$(PATH="$mock_dir:$PATH" bash -c "
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'

        check_stripe_key_present() {
            echo 'STRIPE_TEST_SECRET_KEY is not set' >&2
            exit 1
        }
        check_stripe_key_live() { return 0; }
        check_stripe_webhook_secret_present() { return 0; }
        check_stripe_webhook_forwarding() { return 0; }
        check_usage_records_populated() { return 0; }
        check_rollup_current() { return 0; }

        run_gate --skip-rust-tests
    " 2>/dev/null)" || exit_code=$?

    rm -rf "$mock_dir"

    local reason
    reason="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
results = d.get('check_results', [])
for r in results:
    if r.get('name') == 'check_stripe_key_present' and r.get('status') == 'fail':
        print(r.get('reason', 'MISSING'))
        break
else:
    print('NOT_FOUND')
" <<< "$stdout")"

    # reason should not be MISSING or empty
    if [ "$reason" = "MISSING" ] || [ "$reason" = "NOT_FOUND" ] || [ -z "$reason" ]; then
        fail "check_results entry for failed check should include a non-empty reason (got: '$reason')"
    else
        pass "failed check has reason in check_results"
    fi
}

test_failure_reason_captured_from_stderr() {
    # RED: live_gate_require prints reason to stderr. run_check should capture
    # it and surface it in the JSON check_results reason field.
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    local stdout exit_code
    stdout="$(PATH="$mock_dir:$PATH" bash -c "
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'

        check_stripe_key_present() {
            echo '[BACKEND_LIVE_GATE] required precondition failed: STRIPE key missing' >&2
            exit 1
        }
        check_stripe_key_live() { return 0; }
        check_stripe_webhook_secret_present() { return 0; }
        check_stripe_webhook_forwarding() { return 0; }
        check_usage_records_populated() { return 0; }
        check_rollup_current() { return 0; }

        run_gate --skip-rust-tests
    " 2>/dev/null)" || exit_code=$?

    rm -rf "$mock_dir"

    local reason
    reason="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
results = d.get('check_results', [])
for r in results:
    if r.get('name') == 'check_stripe_key_present':
        print(r.get('reason', 'MISSING'))
        break
else:
    print('NOT_FOUND')
" <<< "$stdout")"
    assert_contains "$reason" "STRIPE key missing" "reason should contain the live_gate_require failure text"
}

test_real_stripe_contract_reason_propagates_to_gate_json_and_stderr() {
    # Stage 2 RED: gate should surface helper-owned canonical key wording.
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    local stdout stderr exit_code=0
    stdout="$(PATH="$mock_dir:$PATH" bash -c "
        export BACKEND_LIVE_GATE=1
        export __LIVE_BACKEND_GATE_SOURCED=1
        unset STRIPE_SECRET_KEY STRIPE_TEST_SECRET_KEY
        export STRIPE_WEBHOOK_SECRET='whsec_stage2_contract'
        source '$GATE_SCRIPT'

        # Keep Stripe key checks real; isolate unrelated checks.
        check_stripe_webhook_forwarding() { return 0; }
        check_usage_records_populated() { return 0; }
        check_rollup_current() { return 0; }

        run_gate --skip-rust-tests
    " 2>"$mock_dir/stderr")" || exit_code=$?

    stderr="$(cat "$mock_dir/stderr")"

    local key_reason
    key_reason="$(check_result_field "$stdout" "check_stripe_key_present" "reason")"
    local first_two
    first_two="$(python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
names=[r.get('name','') for r in d.get('check_results', [])[:2]]
print(' '.join(names))
" <<< "$stdout")"

    rm -rf "$mock_dir"

    assert_eq "$first_two" "check_stripe_key_present check_stripe_key_live" \
        "gate check ordering should keep stripe key checks first and unchanged"
    assert_eq "${exit_code:-0}" "1" "gate should fail when Stripe key contract precondition fails"
    assert_eq "$key_reason" "stripe_key_unset" \
        "gate JSON reason should preserve the helper-owned machine-readable reason code"
    assert_contains "$stderr" "STRIPE_SECRET_KEY" \
        "gate stderr should propagate canonical Stripe key contract wording"
}

test_reason_prefix_without_space_is_supported() {
    # Some checks may emit REASON without a space after the colon. Ensure
    # _extract_reason still strips the prefix correctly.
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    local stdout
    stdout="$(PATH="$mock_dir:$PATH" bash -c "
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'

        check_stripe_key_present() { echo 'REASON:SECURITY_SECRET_FOUND' >&2; return 1; }
        check_stripe_key_live() { return 0; }
        check_stripe_webhook_secret_present() { return 0; }
        check_stripe_webhook_forwarding() { return 0; }
        check_usage_records_populated() { return 0; }
        check_rollup_current() { return 0; }

        run_gate --skip-rust-tests
    " 2>/dev/null)" || true

    local reason
    reason="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
for r in d.get('check_results', []):
    if r.get('name') == 'check_stripe_key_present':
        print(r.get('reason', 'MISSING'))
        break
else:
    print('NOT_FOUND')
" <<< "$stdout")"

    rm -rf "$mock_dir"

    assert_eq "$reason" "SECURITY_SECRET_FOUND" "reason parser should support REASON without trailing space"
}

# ============================================================================
# Stage 2: command invocation hardening
# ============================================================================

test_run_check_does_not_eval_metacharacters() {
    # run_check should execute a command symbol directly, not eval arbitrary
    # shell syntax from a string argument.
    local mock_dir
    mock_dir="$(mktemp -d)"
    local marker="$mock_dir/pwned"

    local status
    status="$(bash -c "
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'

        _CHECK_NAMES=()
        _CHECK_RESULTS=()
        _CHECK_ELAPSED=()
        _CHECK_REASONS=()
        _CHECK_ERROR_CLASS=()

        run_check 'injection_probe' 'echo injected; touch $marker'
        printf '%s\n' \"\${_CHECK_RESULTS[0]:-missing}\"
    " 2>/dev/null)"

    local marker_exists="no"
    if [ -e "$marker" ]; then
        marker_exists="yes"
    fi

    rm -rf "$mock_dir"

    assert_eq "$status" "fail" "run_check should fail when command symbol is invalid"
    assert_eq "$marker_exists" "no" "run_check should not execute metacharacters from command string"
}

# ============================================================================
# Stage 2: inner timeout helper and reason priority
# ============================================================================

test_gate_timeout_returns_124_on_timeout() {
    local timeout_exit
    timeout_exit="$(bash -c "
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'
        set +e
        _gate_timeout 1 sleep 60 >/dev/null 2>&1
        echo \$?
    " 2>/dev/null)"

    assert_eq "$timeout_exit" "124" "_gate_timeout should return 124 on timeout"
}

test_gate_timeout_passes_through_normal_exit() {
    local passthrough_exit
    passthrough_exit="$(bash -c "
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'
        set +e
        _gate_timeout 10 bash -c 'exit 42' >/dev/null 2>&1
        echo \$?
    " 2>/dev/null)"

    assert_eq "$passthrough_exit" "42" "_gate_timeout should pass through normal command exit code"
}

test_gate_timeout_passes_through_stdout() {
    local output
    output="$(bash -c "
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'
        _gate_timeout 10 echo hello
    " 2>/dev/null)"

    assert_eq "$output" "hello" "_gate_timeout should pass through command stdout"
}

test_extract_reason_prefers_reason_line_over_timeout_generic() {
    local reason
    reason="$(bash -c "
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'
        payload=\$(printf 'REASON: stripe_api_timeout\nsome other output')
        _extract_reason 124 \"\$payload\"
    " 2>/dev/null)"

    assert_eq "$reason" "stripe_api_timeout" \
        "_extract_reason should prefer REASON line over generic timeout message"
}

test_inner_timeout_produces_specific_reason_in_gate_json() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass
    cat > "$mock_dir/psql" <<'MOCK'
#!/usr/bin/env bash
exec sleep 60
MOCK
    chmod +x "$mock_dir/psql"

    local stdout exit_code
    stdout="$(PATH="$mock_dir:$PATH" bash -c "
        export __LIVE_BACKEND_GATE_SOURCED=1
        export GATE_INNER_TIMEOUT_SEC=1
        export GATE_CHECK_TIMEOUT_SEC=10
        export INTEGRATION_DB_URL='postgres://localhost/test'
        source '$GATE_SCRIPT'

        check_stripe_key_present() { return 0; }
        check_stripe_key_live() { return 0; }
        check_stripe_webhook_secret_present() { return 0; }
        check_stripe_webhook_forwarding() { return 0; }
        check_rollup_current() { return 0; }

        run_gate --skip-rust-tests
    " 2>/dev/null)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "gate should fail when inner timeout occurs"
    assert_eq "$(check_result_field "$stdout" "check_usage_records_populated" "status")" "fail" \
        "usage records check should be recorded as fail"
    assert_eq "$(check_result_field "$stdout" "check_usage_records_populated" "error_class")" "timeout" \
        "inner timeout should classify as timeout"
    assert_eq "$(check_result_field "$stdout" "check_usage_records_populated" "reason")" "db_connection_timeout" \
        "inner timeout should preserve specific db_connection_timeout reason"
}

# ============================================================================
# Stage 1: Timeout and determinism
# ============================================================================

test_run_check_timeout_kills_hanging_command() {
    # RED: A check that hangs should be killed after GATE_CHECK_TIMEOUT_SEC
    # and recorded as a timeout failure. Currently hangs forever.
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    local stdout exit_code
    stdout="$(PATH="$mock_dir:$PATH" bash -c "
        export __LIVE_BACKEND_GATE_SOURCED=1
        export GATE_CHECK_TIMEOUT_SEC=2
        source '$GATE_SCRIPT'

        check_stripe_key_present() { sleep 999; }
        check_stripe_key_live() { return 0; }
        check_stripe_webhook_secret_present() { return 0; }
        check_stripe_webhook_forwarding() { return 0; }
        check_usage_records_populated() { return 0; }
        check_rollup_current() { return 0; }

        run_gate --skip-rust-tests
    " 2>/dev/null)" || exit_code=$?

    rm -rf "$mock_dir"

    # Should complete (not hang) and report a failure
    assert_eq "${exit_code:-0}" "1" "gate should fail when a check times out"

    local timeout_reason
    timeout_reason="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
results = d.get('check_results', [])
for r in results:
    if r.get('name') == 'check_stripe_key_present':
        print(r.get('reason', 'MISSING'))
        break
else:
    print('NOT_FOUND')
" <<< "$stdout")"
    assert_contains "$timeout_reason" "timeout" "timed-out check reason should contain 'timeout'"
}

test_gate_timeout_env_var_overrides_default() {
    # RED: GATE_CHECK_TIMEOUT_SEC should control the timeout.
    # With a very short timeout (1s) a sleep 5 check should timeout.
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    local stdout exit_code
    stdout="$(PATH="$mock_dir:$PATH" bash -c "
        export __LIVE_BACKEND_GATE_SOURCED=1
        export GATE_CHECK_TIMEOUT_SEC=1
        source '$GATE_SCRIPT'

        # All checks pass quickly except one
        check_stripe_key_present() { return 0; }
        check_stripe_key_live() { sleep 5; }
        check_stripe_webhook_secret_present() { return 0; }
        check_stripe_webhook_forwarding() { return 0; }
        check_usage_records_populated() { return 0; }
        check_rollup_current() { return 0; }

        run_gate --skip-rust-tests
    " 2>/dev/null)" || exit_code=$?

    rm -rf "$mock_dir"

    local check_live_status
    check_live_status="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
results = d.get('check_results', [])
for r in results:
    if r.get('name') == 'check_stripe_key_live':
        print(r.get('status', 'MISSING'))
        break
else:
    print('NOT_FOUND')
" <<< "$stdout")"
    assert_eq "$check_live_status" "fail" "check exceeding GATE_CHECK_TIMEOUT_SEC should fail"
}

test_deterministic_json_across_runs() {
    # RED: Two consecutive runs with identical inputs should produce
    # structurally identical JSON (after zeroing elapsed_ms fields).
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    local run_cmd="
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'

        check_stripe_key_present() { return 0; }
        check_stripe_key_live() { return 0; }
        check_stripe_webhook_secret_present() { return 0; }
        check_stripe_webhook_forwarding() { return 0; }
        check_usage_records_populated() { return 0; }
        check_rollup_current() { return 0; }

        run_gate --skip-rust-tests
    "

    local stdout1 stdout2
    stdout1="$(PATH="$mock_dir:$PATH" bash -c "$run_cmd" 2>/dev/null)" || true
    stdout2="$(PATH="$mock_dir:$PATH" bash -c "$run_cmd" 2>/dev/null)" || true

    rm -rf "$mock_dir"

    # Normalize: zero out all elapsed_ms values, then compare
    local norm1 norm2
    norm1="$(python3 -c "
import json, sys, re
d = json.loads(sys.stdin.read())
d['elapsed_ms'] = 0
for r in d.get('check_results', []):
    r['elapsed_ms'] = 0
print(json.dumps(d, sort_keys=True))
" <<< "$stdout1")"
    norm2="$(python3 -c "
import json, sys, re
d = json.loads(sys.stdin.read())
d['elapsed_ms'] = 0
for r in d.get('check_results', []):
    r['elapsed_ms'] = 0
print(json.dumps(d, sort_keys=True))
" <<< "$stdout2")"

    assert_eq "$norm1" "$norm2" "two consecutive gate runs should produce identical JSON (after normalizing elapsed_ms)"
}

test_fail_fast_records_skipped_checks() {
    # RED: When fail-fast stops early, remaining checks should appear as
    # "skipped" entries in check_results, not just be absent.
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    local stdout exit_code
    stdout="$(PATH="$mock_dir:$PATH" bash -c "
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'

        check_stripe_key_present() { return 0; }
        check_stripe_key_live() { exit 1; }
        check_stripe_webhook_secret_present() { return 0; }
        check_stripe_webhook_forwarding() { return 0; }
        check_usage_records_populated() { return 0; }
        check_rollup_current() { return 0; }

        run_gate --fail-fast --skip-rust-tests
    " 2>/dev/null)" || exit_code=$?

    rm -rf "$mock_dir"

    # check_results should contain all 6 bash checks + 1 rust = 7 entries total
    # (even with fail-fast, remaining should be recorded as skipped)
    local total_entries skipped_count
    total_entries="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
results = d.get('check_results', [])
print(len(results))
" <<< "$stdout")"
    skipped_count="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
results = d.get('check_results', [])
print(sum(1 for r in results if r.get('status') == 'skipped'))
" <<< "$stdout")"

    # With fail-fast on check 2 + skip-rust: 1 pass + 1 fail + 4 bash skipped + 1 rust skipped = 7
    assert_eq "$total_entries" "7" "check_results should list all 7 checks even with fail-fast"

    local skipped_at_least_4
    skipped_at_least_4="$(python3 -c "print('yes' if $skipped_count >= 4 else 'no')")"
    assert_eq "$skipped_at_least_4" "yes" "at least 4 checks should be skipped after fail-fast at check 2 (got $skipped_count)"
}

# ============================================================================
# Stage 2: Watchdog lifecycle and PID-reuse safety
# ============================================================================

count_sleep_processes_by_duration() {
    local duration="$1"
    local count=0
    count="$(pgrep -f "sleep $duration" 2>/dev/null | wc -l | tr -d ' ')" || count=0
    echo "$count"
}

cleanup_sleep_processes_by_duration() {
    local duration="$1"
    pkill -f "sleep $duration" 2>/dev/null || true
}

test_pid_is_live_child_accepts_direct_child() {
    # RED: gate script should expose a helper that verifies a PID is still a
    # live direct child of the invoking shell. This is used to guard timeout
    # kills against recycled PIDs.
    local result
    result="$(bash -c "
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'
        sleep 60 &
        child_pid=\$!
        shell_pid=\"\${BASHPID:-\$\$}\"
        if _pid_is_live_child \"\$child_pid\" \"\$shell_pid\"; then
            status=0
        else
            status=1
        fi
        kill \"\$child_pid\" 2>/dev/null || true
        wait \"\$child_pid\" 2>/dev/null || true
        echo \"\$status\"
    " 2>/dev/null)" || true

    assert_eq "$result" "0" "_pid_is_live_child should accept a direct live child PID"
}

test_pid_is_live_child_rejects_non_child_pid() {
    # RED: helper should reject a PID that is not a direct child (using current
    # shell PID as a stable non-child input).
    local result
    result="$(bash -c "
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'
        shell_pid=\"\${BASHPID:-\$\$}\"
        if _pid_is_live_child \"\$\$\" \"\$shell_pid\"; then
            echo 0
        else
            echo 1
        fi
    " 2>/dev/null)" || true

    assert_eq "$result" "1" "_pid_is_live_child should reject non-child PID"
}

test_no_orphan_sleep_after_fast_check() {
    # Verifies run_check() fully cancels the watchdog's sleep child after the
    # check completes before the timeout. With the old implementation, killing
    # the watchdog subshell leaves its sleep child as an orphan process.
    # The fix must explicitly kill the sleep PID.
    #
    # Uses a large, unique timeout value (31337s) to distinguish our sleep
    # from any unrelated system sleep processes.
    local UNIQUE_TIMEOUT=31337

    # Baseline: count any pre-existing sleep 31337 processes (should be 0).
    # Use '|| true' so pgrep exit-1 (no matches) doesn't trigger set -e pipefail.
    local before_count
    before_count="$(count_sleep_processes_by_duration "$UNIQUE_TIMEOUT")"

    bash -c "
        export __LIVE_BACKEND_GATE_SOURCED=1
        export GATE_CHECK_TIMEOUT_SEC=$UNIQUE_TIMEOUT
        source '$GATE_SCRIPT'
        fast_check() { return 0; }
        run_check 'fast_check' 'fast_check'
    " 2>/dev/null || true

    # Allow cleanup to propagate
    sleep 0.2

    local after_count
    after_count="$(count_sleep_processes_by_duration "$UNIQUE_TIMEOUT")"

    # Kill any lingering processes regardless of assertion result (avoid pollution)
    cleanup_sleep_processes_by_duration "$UNIQUE_TIMEOUT"

    assert_eq "$after_count" "$before_count" \
        "no orphan 'sleep $UNIQUE_TIMEOUT' processes should remain after run_check() returns"
}

test_timeout_kills_check_child_processes() {
    # Verifies timeout cleanup kills child processes spawned by the check itself,
    # not just the watchdog's internal sleep process.
    local UNIQUE_CHECK_SLEEP=42424

    local before_count
    before_count="$(count_sleep_processes_by_duration "$UNIQUE_CHECK_SLEEP")"

    bash -c "
        export __LIVE_BACKEND_GATE_SOURCED=1
        export GATE_CHECK_TIMEOUT_SEC=1
        source '$GATE_SCRIPT'
        slow_check() { sleep $UNIQUE_CHECK_SLEEP; }
        run_check 'slow_check' 'slow_check'
    " 2>/dev/null || true

    sleep 0.2

    local after_count
    after_count="$(count_sleep_processes_by_duration "$UNIQUE_CHECK_SLEEP")"

    cleanup_sleep_processes_by_duration "$UNIQUE_CHECK_SLEEP"

    assert_eq "$after_count" "$before_count" \
        "timed-out checks must not leave child processes running"
}

test_sequential_run_checks_both_pass() {
    # Verifies two sequential run_check() calls both record status=pass.
    # Guards against the PID-reuse race: a lingering watchdog from check N
    # must not kill check N+1's process (even if the OS recycles the PID).
    local stdout exit_code=0
    stdout="$(bash -c "
        export __LIVE_BACKEND_GATE_SOURCED=1
        export GATE_CHECK_TIMEOUT_SEC=30
        source '$GATE_SCRIPT'

        first_check()  { return 0; }
        second_check() { return 0; }

        run_check 'first_check'  'first_check'
        run_check 'second_check' 'second_check'

        # Emit both results so the outer shell can assert on them
        printf '%s %s\n' \"\${_CHECK_RESULTS[0]}\" \"\${_CHECK_RESULTS[1]}\"
    " 2>/dev/null)" || exit_code=$?

    assert_eq "$stdout" "pass pass" \
        "both sequential run_check() calls should record status=pass (no cross-kill from watchdog)"
}

test_timeout_check_has_error_class_timeout() {
    # Verifies a timed-out check sets error_class=timeout in JSON output.
    # This field is consumed by gate_strictness_test.sh's error-classification
    # category and must survive any timeout-mechanism refactor.
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    local stdout exit_code=0
    stdout="$(PATH="$mock_dir:$PATH" bash -c "
        export __LIVE_BACKEND_GATE_SOURCED=1
        export GATE_CHECK_TIMEOUT_SEC=1
        source '$GATE_SCRIPT'

        check_stripe_key_present() { sleep 60; }
        check_stripe_key_live()             { return 0; }
        check_stripe_webhook_secret_present() { return 0; }
        check_stripe_webhook_forwarding()   { return 0; }
        check_usage_records_populated()     { return 0; }
        check_rollup_current()              { return 0; }

        run_gate --skip-rust-tests
    " 2>/dev/null)" || exit_code=$?

    rm -rf "$mock_dir"

    local timeout_status timeout_error_class timeout_reason
    timeout_status="$(check_result_field "$stdout" "check_stripe_key_present" "status")"
    timeout_error_class="$(check_result_field "$stdout" "check_stripe_key_present" "error_class")"
    timeout_reason="$(check_result_field "$stdout" "check_stripe_key_present" "reason")"

    assert_eq "$timeout_status" "fail" \
        "timed-out check should have status=fail"
    assert_eq "$timeout_error_class" "timeout" \
        "timed-out check should have error_class=timeout"
    assert_contains "$timeout_reason" "timeout" \
        "timed-out check reason should contain 'timeout'"
}

test_concurrent_gate_runs_isolated() {
    # Checklist Stage 1 RED: concurrent gate invocations should not corrupt state.
    local tmpdir
    tmpdir="$(mktemp -d)"

    cat > "$tmpdir/run_gate_once.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export __LIVE_BACKEND_GATE_SOURCED=1
source '$GATE_SCRIPT'
check_stripe_key_present() { return 0; }
check_stripe_key_live() { return 0; }
check_stripe_webhook_secret_present() { return 0; }
check_stripe_webhook_forwarding() { return 0; }
check_usage_records_populated() { return 0; }
check_rollup_current() { return 0; }
run_gate --skip-rust-tests
EOF
    chmod +x "$tmpdir/run_gate_once.sh"

    bash "$tmpdir/run_gate_once.sh" > "$tmpdir/out1.json" 2> "$tmpdir/err1.log" &
    local pid1=$!
    bash "$tmpdir/run_gate_once.sh" > "$tmpdir/out2.json" 2> "$tmpdir/err2.log" &
    local pid2=$!

    local rc1=0 rc2=0
    wait "$pid1" || rc1=$?
    wait "$pid2" || rc2=$?

    assert_eq "$rc1" "0" "first concurrent gate run should exit 0"
    assert_eq "$rc2" "0" "second concurrent gate run should exit 0"

    local ok1 ok2
    ok1="$(python3 -c "
import json,sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data = json.load(f)
print('ok' if isinstance(data.get('check_results'), list) and data.get('checks_skipped') == 1 else 'bad')
" "$tmpdir/out1.json")"
    ok2="$(python3 -c "
import json,sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data = json.load(f)
print('ok' if isinstance(data.get('check_results'), list) and data.get('checks_skipped') == 1 else 'bad')
" "$tmpdir/out2.json")"
    assert_eq "$ok1" "ok" "first concurrent run should produce valid isolated JSON"
    assert_eq "$ok2" "ok" "second concurrent run should produce valid isolated JSON"

    rm -rf "$tmpdir"
}

test_every_check_fn_failure_has_reason_code() {
    # Checklist Stage 1 RED: each canonical check function emits REASON on failure.
    run_check_failure_output() {
        local lib_file="$1"
        local setup_snippet="$2"
        local fn_name="$3"
        local path_prefix="${4:-}"

        local effective_path="$PATH"
        if [ -n "$path_prefix" ]; then
            effective_path="$path_prefix:$PATH"
        fi

        PATH="$effective_path" bash -c "
            export BACKEND_LIVE_GATE=1
            source '$REPO_ROOT/scripts/lib/live_gate.sh'
            source '$REPO_ROOT/scripts/lib/$lib_file'
            $setup_snippet
            $fn_name
        " 2>&1 || true
    }

    local output
    output="$(run_check_failure_output "stripe_checks.sh" \
        "unset STRIPE_SECRET_KEY STRIPE_TEST_SECRET_KEY STRIPE_WEBHOOK_SECRET" \
        "check_stripe_key_present")"
    assert_contains "$output" "REASON:" "check_stripe_key_present failure should emit REASON"

    output="$(run_check_failure_output "stripe_checks.sh" \
        "unset STRIPE_SECRET_KEY STRIPE_TEST_SECRET_KEY" \
        "check_stripe_key_live")"
    assert_contains "$output" "REASON:" "check_stripe_key_live failure should emit REASON"

    output="$(run_check_failure_output "stripe_checks.sh" \
        "unset STRIPE_WEBHOOK_SECRET" \
        "check_stripe_webhook_secret_present")"
    assert_contains "$output" "REASON:" "check_stripe_webhook_secret_present failure should emit REASON"

    local mock_dir
    mock_dir="$(mktemp -d)"
    cat > "$mock_dir/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$mock_dir/pgrep"
    output="$(run_check_failure_output "stripe_checks.sh" \
        "" \
        "check_stripe_webhook_forwarding" \
        "$mock_dir")"
    rm -rf "$mock_dir"
    assert_contains "$output" "REASON:" "check_stripe_webhook_forwarding failure should emit REASON"

    output="$(run_check_failure_output "metering_checks.sh" \
        "unset INTEGRATION_DB_URL DATABASE_URL" \
        "check_usage_records_populated")"
    assert_contains "$output" "REASON:" "check_usage_records_populated failure should emit REASON"

    output="$(run_check_failure_output "metering_checks.sh" \
        "unset INTEGRATION_DB_URL DATABASE_URL" \
        "check_rollup_current")"
    assert_contains "$output" "REASON:" "check_rollup_current failure should emit REASON"
}

# ============================================================================
# Run tests
# ============================================================================

echo "=== live-backend-gate.sh tests ==="
echo ""
echo "--- core structure and subshell isolation ---"
test_gate_sources_libs_and_exports_gate_env
test_gate_respects_backend_live_gate_override_when_sourced
test_gate_runs_all_checks_even_when_early_ones_fail
echo ""
echo "--- check orchestration ---"
test_gate_runs_all_6_bash_checks_in_order
test_gate_runs_cargo_rust_tests_as_composite_check
test_gate_cargo_failure_appears_in_failures
echo ""
echo "--- JSON summary output ---"
test_json_all_pass_structure
test_json_partial_fail_structure
echo ""
echo "--- optional flags ---"
test_skip_rust_tests_flag
test_fail_fast_flag
test_staging_only_flag_soft_skips_commerce_checks
echo ""
echo "--- Stage 1: silent-skip detection ---"
test_skip_rust_tests_surfaces_skip_in_json
test_json_has_checks_skipped_count
test_skip_pass_distinguishable_from_real_pass
test_gate_fails_when_stripe_check_skipped
test_gate_fails_when_metering_check_skipped
test_gate_fails_when_multiple_checks_skipped
test_json_passed_true_when_only_exempt_skip
echo ""
echo "--- Stage 1: reason codes ---"
test_failures_include_reason_in_check_results
test_failure_reason_captured_from_stderr
test_real_stripe_contract_reason_propagates_to_gate_json_and_stderr
test_reason_prefix_without_space_is_supported
test_every_check_fn_failure_has_reason_code
echo ""
echo "--- Stage 2: command invocation hardening ---"
test_run_check_does_not_eval_metacharacters
echo ""
echo "--- Stage 2: inner timeout helper and reason priority ---"
test_gate_timeout_returns_124_on_timeout
test_gate_timeout_passes_through_normal_exit
test_gate_timeout_passes_through_stdout
test_extract_reason_prefers_reason_line_over_timeout_generic
test_inner_timeout_produces_specific_reason_in_gate_json
echo ""
echo "--- Stage 1: timeout and determinism ---"
test_run_check_timeout_kills_hanging_command
test_gate_timeout_env_var_overrides_default
test_deterministic_json_across_runs
test_fail_fast_records_skipped_checks
echo ""
echo "--- Stage 2: watchdog lifecycle and PID-reuse safety ---"
test_pid_is_live_child_accepts_direct_child
test_pid_is_live_child_rejects_non_child_pid
test_no_orphan_sleep_after_fast_check
test_timeout_kills_check_child_processes
test_sequential_run_checks_both_pass
test_timeout_check_has_error_class_timeout
test_concurrent_gate_runs_isolated
echo ""
echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
