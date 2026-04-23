#!/usr/bin/env bash
# Aggregate backend reliability gate.
#
# Runs Stage 1-4 reliability/security checks plus the existing
# `live-backend-gate.sh` checks as a single machine-readable JSON summary.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIVE_GATE_SCRIPT="$REPO_ROOT/scripts/live-backend-gate.sh"

: "${GATE_CHECK_TIMEOUT_SEC:=120}"
export GATE_CHECK_TIMEOUT_SEC

# Reuse the existing gate framework (`run_check`, `record_skip`, `build_json`,
# error classification, etc.) without executing `run_gate` itself.
export __LIVE_BACKEND_GATE_SOURCED=1
source "$LIVE_GATE_SCRIPT"
unset __LIVE_BACKEND_GATE_SOURCED

# Security checks used by the gate.
source "$REPO_ROOT/scripts/reliability/lib/security_checks.sh"

PASS=0
FAIL=1

# ---------------------------------------------------------------------------
# _wrap_test_check — run a command, emit REASON on pass/fail
#
# Arguments:
#   $1 — pass reason code
#   $2 — fail reason code
#   $3… — command and arguments (runs in a subshell via $())
# ---------------------------------------------------------------------------
_wrap_test_check() {
    local pass_reason="$1" fail_reason="$2"
    shift 2
    local output exit_code=$PASS
    output="$("$@" 2>&1)" || exit_code=$?
    echo "$output" >&2
    if [ "$exit_code" -eq "$PASS" ]; then
        echo "REASON: $pass_reason" >&2
        return "$PASS"
    fi
    echo "REASON: $fail_reason" >&2
    return "$FAIL"
}

# Helper: run cargo test under infra/ (cd happens inside command substitution subshell).
_cargo_test() {
    cd "$REPO_ROOT/infra" && cargo test "$@"
}

_integration_cargo_test() {
    INTEGRATION=1 _cargo_test "$@"
}

_cargo_check() {
    cd "$REPO_ROOT/infra" && cargo check "$@"
}

_cargo_clippy() {
    cd "$REPO_ROOT/infra" && cargo clippy "$@"
}

run_compile_check() {
    _wrap_test_check "COMPILE_CHECK_PASS" "COMPILE_CHECK_FAIL" \
        _cargo_check -p api
}

run_clippy_check() {
    _wrap_test_check "CLIPPY_CHECK_PASS" "CLIPPY_CHECK_FAIL" \
        _cargo_clippy -p api
}

run_compile_group() {
    run_check_or_skip "compile_check" "run_compile_check"
    run_check_or_skip "clippy_check" "run_clippy_check"
}

run_reliability_profile_tests() {
    _wrap_test_check "RELIABILITY_PROFILE_TESTS_PASS" "RELIABILITY_PROFILE_TESTS_FAIL" \
        env RELIABILITY_STALENESS_DAYS=30 \
        bash "$REPO_ROOT/scripts/tests/reliability_profile_test.sh"
}

run_reliability_scheduler_tests() {
    _wrap_test_check "RELIABILITY_SCHEDULER_TESTS_PASS" "RELIABILITY_SCHEDULER_TESTS_FAIL" \
        _cargo_test -p api --test scheduler_test
}

run_reliability_replication_tests() {
    _wrap_test_check "RELIABILITY_REPLICATION_TESTS_PASS" "RELIABILITY_REPLICATION_TESTS_FAIL" \
        _cargo_test -p api --test reliability_replication_test
}

run_reliability_api_crash_tests() {
    _wrap_test_check "RELIABILITY_API_CRASH_TESTS_PASS" "RELIABILITY_API_CRASH_TESTS_FAIL" \
        _cargo_test -p api --test reliability_api_crash_test
}

run_reliability_cold_tier_tests() {
    _wrap_test_check "RELIABILITY_COLD_TIER_TESTS_PASS" "RELIABILITY_COLD_TIER_TESTS_FAIL" \
        _cargo_test -p api --test reliability_cold_tier_test
}

run_reliability_metering_tests() {
    _wrap_test_check "RELIABILITY_METERING_TESTS_PASS" "RELIABILITY_METERING_TESTS_FAIL" \
        _cargo_test -p metering-agent
}

run_reliability_sql_guard_test() {
    _wrap_test_check "RELIABILITY_SQL_GUARD_TESTS_PASS" "RELIABILITY_SQL_GUARD_TESTS_FAIL" \
        _cargo_test -p api --test reliability_security_test
}

run_security_secret_scan() {
    local output exit_code=$PASS
    output="$(check_secret_scan "$REPO_ROOT" 2>&1)" || exit_code=$?
    echo "$output" >&2
    return "$exit_code"
}

run_security_dep_audit() {
    local output exit_code=$PASS
    output="$(check_dep_audit 2>&1)" || exit_code=$?
    echo "$output" >&2
    # Treat missing cargo-audit as an actionable gate failure in CI.
    if [ "$exit_code" -eq "$PASS" ] && [[ "$output" == *"SECURITY_DEP_AUDIT_SKIP_TOOL_MISSING"* ]]; then
        return "$FAIL"
    fi
    return "$exit_code"
}

run_security_sql_guard() {
    local output exit_code=$PASS
    output="$(check_sql_guard "$REPO_ROOT/infra" 2>&1)" || exit_code=$?
    echo "$output" >&2
    return "$exit_code"
}

run_security_cmd_injection() {
    local output exit_code=$PASS
    output="$(check_cmd_injection "$REPO_ROOT/infra" 2>&1)" || exit_code=$?
    echo "$output" >&2
    return "$exit_code"
}

run_load_gate_check() {
    source "$REPO_ROOT/scripts/load/lib/load_checks.sh"
    local output exit_code=$PASS
    output="$(run_load_gate 2>&1)" || exit_code=$?
    echo "$output" >&2
    return "$exit_code"
}

run_live_rust_validation_tests() {
    _wrap_test_check "LIVE_RUST_VALIDATION_TESTS_PASS" "LIVE_RUST_VALIDATION_TESTS_FAIL" \
        _integration_cargo_test --test integration_metering_pipeline_test validate_
}

run_check_or_skip() {
    local name="$1"
    local check_cmd="$2"

    if [ "$FAIL_FAST" = "true" ] && [ "$HIT_FAILURE" = "true" ]; then
        record_skip "$name" "fail_fast"
        return "$PASS"
    fi

    run_check "$name" "$check_cmd"

    local last_idx=$(( ${#_CHECK_RESULTS[@]} - 1 ))
    if [ "${_CHECK_RESULTS[$last_idx]}" = "fail" ]; then
        HIT_FAILURE="true"
    fi
}

run_reliability_group() {
    run_check_or_skip "reliability_profile_tests" "run_reliability_profile_tests"
    run_check_or_skip "reliability_scheduler_tests" "run_reliability_scheduler_tests"
    run_check_or_skip "reliability_replication_tests" "run_reliability_replication_tests"
    run_check_or_skip "reliability_api_crash_tests" "run_reliability_api_crash_tests"
    run_check_or_skip "reliability_cold_tier_tests" "run_reliability_cold_tier_tests"
    run_check_or_skip "reliability_metering_tests" "run_reliability_metering_tests"
}

run_security_group() {
    run_check_or_skip "security_secret_scan" "run_security_secret_scan"
    run_check_or_skip "security_dep_audit" "run_security_dep_audit"
    run_check_or_skip "security_sql_guard" "run_security_sql_guard"
    run_check_or_skip "security_cmd_injection" "run_security_cmd_injection"
    run_check_or_skip "security_sql_guard_tests" "run_reliability_sql_guard_test"
}

run_load_group() {
    run_check_or_skip "load_gate" "run_load_gate_check"
}

run_live_group() {
    run_check_or_skip "check_stripe_key_present" "check_stripe_key_present"
    run_check_or_skip "check_stripe_key_live" "check_stripe_key_live"
    run_check_or_skip "check_stripe_webhook_secret_present" "check_stripe_webhook_secret_present"
    run_check_or_skip "check_stripe_webhook_forwarding" "check_stripe_webhook_forwarding"
    run_check_or_skip "check_usage_records_populated" "check_usage_records_populated"
    run_check_or_skip "check_rollup_current" "check_rollup_current"

    if [ "$SKIP_RUST_TESTS" = "true" ]; then
        record_skip "rust_validation_tests" "skip_rust_tests_flag"
    else
        run_check_or_skip "rust_validation_tests" "run_live_rust_validation_tests"
    fi
}

run_backend_reliability_gate() {
    local run_compile=true
    local run_reliability=true
    local run_security=true
    local run_load=true
    local run_live=true
    local mode_selected_count=0
    local arg
    FAIL_FAST="false"
    SKIP_RUST_TESTS="false"
    HIT_FAILURE="false"

    for arg in "$@"; do
        case "$arg" in
            --reliability-only)
                mode_selected_count=$((mode_selected_count + 1))
                run_compile=false
                run_reliability=true
                run_security=false
                run_load=false
                run_live=false
                ;;
            --security-only)
                mode_selected_count=$((mode_selected_count + 1))
                run_compile=false
                run_reliability=false
                run_security=true
                run_load=false
                run_live=false
                ;;
            --live-only)
                mode_selected_count=$((mode_selected_count + 1))
                run_compile=false
                run_reliability=false
                run_security=false
                run_load=false
                run_live=true
                ;;
            --load-only)
                mode_selected_count=$((mode_selected_count + 1))
                run_compile=false
                run_reliability=false
                run_security=false
                run_load=true
                run_live=false
                ;;
            --skip-rust-tests)
                SKIP_RUST_TESTS=true
                ;;
            --fail-fast)
                FAIL_FAST="true"
                ;;
            --help)
                cat <<'USAGE'
Usage:
  run_backend_reliability_gate.sh [--reliability-only] [--security-only] [--load-only] [--live-only] \
    [--skip-rust-tests] [--fail-fast]

  --reliability-only  Run Stage 1-3 checks only (profiles + reliability tests)
  --security-only     Run security checks only (secret scan, dep-audit, SQL guard)
  --load-only         Run load harness checks only
  --live-only         Run existing live-backend checks only
  --skip-rust-tests   Skip live Rust validation tests
  --fail-fast         Stop after the first check failure
USAGE
                return "$PASS"
                ;;
            *)
                echo "Unknown flag: $arg" >&2
                return "$FAIL"
                ;;
        esac
    done

    if [ "$mode_selected_count" -gt 1 ]; then
        echo "Only one mode may be selected: --reliability-only, --security-only, --load-only, or --live-only" >&2
        echo "Use --help for usage." >&2
        return "$FAIL"
    fi

    _CHECK_NAMES=()
    _CHECK_RESULTS=()
    _CHECK_ELAPSED=()
    _CHECK_REASONS=()
    _CHECK_ERROR_CLASS=()

    local gate_start_ms
    gate_start_ms="$(_ms_now)"

    if [ "$run_compile" = "true" ]; then
        run_compile_group
    fi

    if [ "$run_reliability" = "true" ]; then
        run_reliability_group
    fi

    if [ "$run_security" = "true" ]; then
        run_security_group
    fi

    if [ "$run_load" = "true" ]; then
        run_load_group
    fi

    if [ "$run_live" = "true" ]; then
        run_live_group
    fi

    local gate_end_ms
    gate_end_ms="$(_ms_now)"
    local total_elapsed=$((gate_end_ms - gate_start_ms))

    local gate_failed=0
    if _has_gate_failure; then
        gate_failed=1
    fi

    local json
    json="$(build_json "$total_elapsed" "$gate_failed")"
    echo "$json"

    if [ "$gate_failed" -eq 1 ]; then
        return "$FAIL"
    fi

    return "$PASS"
}

if [ -z "${__RUN_BACKEND_RELIABILITY_GATE_SOURCED:-}" ]; then
    run_backend_reliability_gate "$@"
fi
