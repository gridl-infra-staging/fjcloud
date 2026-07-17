#!/usr/bin/env bash
# Tests for scripts/reliability/run_backend_reliability_gate.sh
# Validates gate orchestration, JSON output structure, flag behavior,
# and strict-mode invariants.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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

# Helper to extract a JSON field via python3
json_field() {
    local json="$1" field="$2"
    echo "$json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('$field',''))" 2>/dev/null
}

json_field_type() {
    local json="$1" field="$2"
    echo "$json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(type(d.get('$field')).__name__)" 2>/dev/null
}

json_array_len() {
    local json="$1" field="$2"
    echo "$json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('$field',[])))" 2>/dev/null
}

json_check_name_at() {
    local json="$1" index="$2"
    echo "$json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['check_results'][$index]['name'])" 2>/dev/null
}

json_check_has_field() {
    local json="$1" index="$2" field="$3"
    echo "$json" | python3 -c "import json,sys; d=json.load(sys.stdin); print('yes' if '$field' in d['check_results'][$index] else 'no')" 2>/dev/null
}

json_check_field_by_name() {
    local json="$1" name="$2" field="$3"
    echo "$json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for cr in d.get('check_results', []):
    if cr.get('name') == '$name':
        print(cr.get('$field', ''))
        break
" 2>/dev/null
}

# ============================================================================
# Test: sourcing defines expected functions
# ============================================================================

test_sourcing_defines_functions() {
    local output exit_code=0
    output="$(bash -c "
        __RUN_BACKEND_RELIABILITY_GATE_SOURCED=1
        source '$REPO_ROOT/scripts/reliability/run_backend_reliability_gate.sh'
        type run_compile_check >/dev/null 2>&1 && echo 'run_compile_check=yes' || echo 'run_compile_check=no'
        type run_backend_reliability_gate >/dev/null 2>&1 && echo 'run_backend_reliability_gate=yes' || echo 'run_backend_reliability_gate=no'
        type run_check_or_skip >/dev/null 2>&1 && echo 'run_check_or_skip=yes' || echo 'run_check_or_skip=no'
    " 2>&1)" || exit_code=$?

    assert_contains "$output" "run_compile_check=yes" "sourcing should define run_compile_check"
    assert_contains "$output" "run_backend_reliability_gate=yes" "sourcing should define run_backend_reliability_gate"
    assert_contains "$output" "run_check_or_skip=yes" "sourcing should define run_check_or_skip"
}

# ============================================================================
# Test: full gate run produces valid JSON with required fields
# ============================================================================

test_full_run_produces_valid_json() {
    local output exit_code=0
    # Run the gate; it will exit 1 because cargo-audit is not installed (skip counts as non-pass)
    output="$(BACKEND_LIVE_GATE=1 bash "$REPO_ROOT/scripts/reliability/run_backend_reliability_gate.sh" 2>/dev/null)" || exit_code=$?

    # Extract the last line (the JSON summary)
    local json
    json="$(echo "$output" | tail -1)"

    # Verify valid JSON
    local valid=0
    echo "$json" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null || valid=1
    assert_eq "$valid" "0" "gate output should be valid JSON"

    # Verify required top-level fields
    local has_passed has_checks_run has_checks_failed has_checks_skipped has_elapsed has_failures has_results
    has_passed="$(json_field_type "$json" "passed")"
    has_checks_run="$(json_field_type "$json" "checks_run")"
    has_checks_failed="$(json_field_type "$json" "checks_failed")"
    has_checks_skipped="$(json_field_type "$json" "checks_skipped")"
    has_elapsed="$(json_field_type "$json" "elapsed_ms")"
    has_failures="$(json_field_type "$json" "failures")"
    has_results="$(json_field_type "$json" "check_results")"

    assert_eq "$has_passed" "bool" "JSON should have bool 'passed' field"
    assert_eq "$has_checks_run" "int" "JSON should have int 'checks_run' field"
    assert_eq "$has_checks_failed" "int" "JSON should have int 'checks_failed' field"
    assert_eq "$has_checks_skipped" "int" "JSON should have int 'checks_skipped' field"
    assert_eq "$has_elapsed" "int" "JSON should have int 'elapsed_ms' field"
    assert_eq "$has_failures" "list" "JSON should have list 'failures' field"
    assert_eq "$has_results" "list" "JSON should have list 'check_results' field"

    # check_results should contain all 21 gate checks
    local results_len
    results_len="$(json_array_len "$json" "check_results")"
    assert_eq "$results_len" "21" "check_results should have 21 entries"
}

# ============================================================================
# Test: --skip-rust-tests records skips and passed=false
# ============================================================================

test_skip_rust_tests_flag() {
    local output exit_code=0
    output="$(BACKEND_LIVE_GATE=1 bash "$REPO_ROOT/scripts/reliability/run_backend_reliability_gate.sh" --skip-rust-tests 2>/dev/null)" || exit_code=$?

    local json
    json="$(echo "$output" | tail -1)"

    local checks_skipped passed
    checks_skipped="$(json_field "$json" "checks_skipped")"
    passed="$(json_field "$json" "passed")"

    # At least 1 skipped (rust_validation_tests)
    local skipped_gte_1=0
    [ "$checks_skipped" -ge 1 ] || skipped_gte_1=1
    assert_eq "$skipped_gte_1" "0" "--skip-rust-tests should skip at least 1 check (got $checks_skipped)"
    assert_eq "$passed" "False" "--skip-rust-tests should make passed=false (strict mode)"
}

# ============================================================================
# Test: check_results entries have required fields and canonical ordering
# ============================================================================

test_check_results_structure_and_ordering() {
    local output exit_code=0
    output="$(BACKEND_LIVE_GATE=1 bash "$REPO_ROOT/scripts/reliability/run_backend_reliability_gate.sh" 2>/dev/null)" || exit_code=$?

    local json
    json="$(echo "$output" | tail -1)"

    # Verify canonical check names at key positions (21 checks total):
    # 0=compile_check, 1=clippy_check, 2=reliability_profile_tests, ...
    # 8=security_secret_scan, 9=security_dep_audit, 13=load_gate, 20=rust_validation_tests
    assert_eq "$(json_check_name_at "$json" 0)" "compile_check" "check 0 should be compile_check"
    assert_eq "$(json_check_name_at "$json" 1)" "clippy_check" "check 1 should be clippy_check"
    assert_eq "$(json_check_name_at "$json" 2)" "reliability_profile_tests" "check 2 should be reliability_profile_tests"
    assert_eq "$(json_check_name_at "$json" 8)" "security_secret_scan" "check 8 should be security_secret_scan"
    assert_eq "$(json_check_name_at "$json" 13)" "load_gate" "check 13 should be load_gate"
    assert_eq "$(json_check_name_at "$json" 20)" "rust_validation_tests" "check 20 should be rust_validation_tests"

    # Verify each entry has required fields (spot check first 5 + last)
    for i in 0 1 2 3 4 20; do
        local has_name has_status has_elapsed has_reason
        has_name="$(json_check_has_field "$json" "$i" "name")"
        has_status="$(json_check_has_field "$json" "$i" "status")"
        has_elapsed="$(json_check_has_field "$json" "$i" "elapsed_ms")"
        has_reason="$(json_check_has_field "$json" "$i" "reason")"

        assert_eq "$has_name" "yes" "check_results[$i] should have 'name' field"
        assert_eq "$has_status" "yes" "check_results[$i] should have 'status' field"
        assert_eq "$has_elapsed" "yes" "check_results[$i] should have 'elapsed_ms' field"
        assert_eq "$has_reason" "yes" "check_results[$i] should have 'reason' field"
    done
}

# ============================================================================
# Test: real codebase non-cargo-audit checks pass
# ============================================================================

test_real_codebase_checks_pass() {
    local output exit_code=0
    output="$(BACKEND_LIVE_GATE=1 bash "$REPO_ROOT/scripts/reliability/run_backend_reliability_gate.sh" 2>/dev/null)" || exit_code=$?

    local json
    json="$(echo "$output" | tail -1)"

    # Extract per-check statuses
    local statuses
    statuses="$(echo "$json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for cr in d['check_results']:
    print(cr['name'] + '=' + cr['status'])
" 2>/dev/null)"

    # Compile group should pass
    assert_contains "$statuses" "compile_check=pass" "compile check should pass"
    assert_contains "$statuses" "clippy_check=pass" "clippy check should pass"

    # Reliability test suites should pass
    assert_contains "$statuses" "reliability_profile_tests=pass" "reliability profile tests should pass"
    assert_contains "$statuses" "reliability_scheduler_tests=pass" "reliability scheduler tests should pass"

    # Security gate tests should pass
    assert_contains "$statuses" "security_sql_guard_tests=pass" "security sql guard tests should pass"

    # security_dep_audit is environment-dependent:
    # - when cargo-audit is unavailable, the aggregate gate upgrades the skip to fail
    # - when cargo-audit is installed, the check should pass
    # Verify both supported branches produce coherent structured output.
    local sec_status sec_reason
    sec_status="$(json_check_field_by_name "$json" "security_dep_audit" "status")"
    sec_reason="$(json_check_field_by_name "$json" "security_dep_audit" "reason")"

    case "$sec_status" in
        fail)
            assert_eq "$sec_reason" "SECURITY_DEP_AUDIT_SKIP_TOOL_MISSING" \
                "security_dep_audit should propagate tool missing reason when cargo-audit is unavailable"
            ;;
        pass)
            pass "security_dep_audit should pass when cargo-audit is installed"
            ;;
        *)
            fail "security_dep_audit should resolve to pass or fail (actual='$sec_status' reason='$sec_reason')"
            ;;
    esac
}

# ============================================================================
# Run tests
# ============================================================================

echo "=== reliability_gate.sh tests ==="
echo ""
echo "--- sourcing & functions ---"
test_sourcing_defines_functions
echo ""
echo "--- full run JSON structure ---"
test_full_run_produces_valid_json
echo ""
echo "--- --skip-rust-tests flag ---"
test_skip_rust_tests_flag
echo ""
echo "--- check_results structure & ordering ---"
test_check_results_structure_and_ordering
echo ""
echo "--- real codebase checks ---"
test_real_codebase_checks_pass
echo ""
echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
