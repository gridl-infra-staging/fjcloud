#!/usr/bin/env bash
# Tests for Stage 1: Gate Strictness and Determinism (Stream H)
#
# Field naming convention (aligned with live_backend_gate_test.sh):
#   check_results  — per-check detail array
#   status         — "pass" | "fail" | "skipped"
#   reason         — human-readable reason (empty string for passes)
#   checks_skipped — top-level integer count
#   GATE_CHECK_TIMEOUT_SEC — per-check timeout env var

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE_SCRIPT="$REPO_ROOT/scripts/live-backend-gate.sh"

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
    python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(json.dumps(d['$field']))" <<< "$json"
}

# Helper: extract a nested JSON field via dotted path (returns "MISSING" on error)
json_path() {
    local json="$1" path="$2"
    python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    for key in '$path'.split('.'):
        if key.isdigit():
            d = d[int(key)]
        else:
            d = d[key]
    print(json.dumps(d))
except (KeyError, IndexError, TypeError):
    print('MISSING')
" <<< "$json"
}

setup_mock_cargo() {
    local mock_dir="$1" behavior="${2:-pass}"
    cat > "$mock_dir/cargo" <<MOCK
#!/usr/bin/env bash
echo "cargo invoked" >> "$mock_dir/cargo_invocations.log"
if [ "$behavior" = "fail" ]; then
    echo "test result: FAILED" >&2
    exit 1
fi
echo "test result: ok. 3 passed; 0 failed"
exit 0
MOCK
    chmod +x "$mock_dir/cargo"
}

# ============================================================================
# 1. Launch mode must not silently skip critical checks
# ============================================================================

test_skip_rust_in_launch_mode_records_explicit_skip() {
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

    # check_results must contain a skipped entry for rust_validation_tests
    local rust_status
    rust_status="$(python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    for r in d.get('check_results', []):
        if r.get('name') == 'rust_validation_tests':
            print(r.get('status', 'MISSING'))
            break
    else:
        print('NOT_FOUND')
except: print('PARSE_ERROR')
" <<< "$stdout")"
    assert_eq "$rust_status" "skipped" \
        "rust_validation_tests must show status=skipped when --skip-rust-tests is used"

    # checks_skipped should be 1
    local skipped
    skipped="$(python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(d.get('checks_skipped', 'MISSING'))
except: print('PARSE_ERROR')
" <<< "$stdout")"
    assert_eq "$skipped" "1" \
        "checks_skipped should be 1 when rust tests are skipped"
}

test_launch_mode_gate_fails_when_stripe_check_skipped() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    local stdout exit_code
    stdout="$(PATH="$mock_dir:$PATH" bash -c "
        export BACKEND_LIVE_GATE=1
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'

        check_stripe_key_present() {
            echo '[skip] stripe key check skipped' >&2
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

    assert_eq "${exit_code:-0}" "1" \
        "launch mode should fail when stripe check is skipped"
    assert_eq "$(json_path "$stdout" "passed")" "false" \
        "launch mode skipped stripe check should set passed=false"
}

test_launch_mode_gate_fails_when_metering_check_skipped() {
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
            echo '[skip] usage_records unavailable' >&2
            return 0
        }
        check_rollup_current() { return 0; }

        run_gate --skip-rust-tests
    " 2>/dev/null)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" \
        "launch mode should fail when metering check is skipped"
    assert_eq "$(json_path "$stdout" "passed")" "false" \
        "launch mode skipped metering check should set passed=false"
}

test_dev_mode_allows_skipped_checks_with_warning() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    local stdout exit_code
    stdout="$(PATH="$mock_dir:$PATH" bash -c "
        export BACKEND_LIVE_GATE=0
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'

        check_stripe_key_present() {
            echo '[skip] stripe key check skipped in dev mode' >&2
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

    assert_eq "${exit_code:-0}" "0" \
        "dev mode should allow skipped checks"
    assert_eq "$(json_path "$stdout" "passed")" "true" \
        "dev mode skipped checks should keep passed=true"

    local has_skip
    has_skip="$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
print('yes' if data.get('checks_skipped', 0) >= 1 else 'no')
" <<< "$stdout")"
    assert_eq "$has_skip" "yes" \
        "dev mode should still report checks_skipped >= 1"
}

test_skip_rust_exemption_still_works_in_launch_mode() {
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

    assert_eq "${exit_code:-0}" "0" \
        "launch mode should allow explicit rust skip exemption"
    assert_eq "$(json_path "$stdout" "passed")" "true" \
        "rust skip exemption should keep passed=true"
}

# ============================================================================
# 2. JSON output must include per-check detail array
# ============================================================================

test_json_has_check_results_array() {
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

    # Validate check_results exists with 7 entries
    local count
    count="$(python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(len(d.get('check_results', [])))
except: print('0')
" <<< "$stdout")"
    assert_eq "$count" "7" \
        "check_results array should have 7 entries (6 bash + 1 cargo)"

    # Each entry must have name, status, reason, elapsed_ms
    local fields_ok
    fields_ok="$(python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    required = {'name', 'status', 'reason', 'elapsed_ms'}
    for c in d.get('check_results', []):
        missing = required - set(c.keys())
        if missing:
            print('missing: ' + str(missing))
            sys.exit(0)
    print('ok')
except: print('PARSE_ERROR')
" <<< "$stdout")"
    assert_eq "$fields_ok" "ok" \
        "each check_results entry must have name, status, reason, elapsed_ms"

    # First entry must be check_stripe_key_present (ordering)
    local first_name
    first_name="$(json_path "$stdout" "check_results.0.name")"
    assert_eq "$first_name" '"check_stripe_key_present"' \
        "first check_results entry should be check_stripe_key_present"
}

test_check_results_shows_failure_with_reason() {
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

        run_gate
    " 2>/dev/null)" || exit_code=$?

    rm -rf "$mock_dir"

    local first_status
    first_status="$(json_path "$stdout" "check_results.0.status")"
    assert_eq "$first_status" '"fail"' \
        "failed check should have status=fail"

    local first_reason
    first_reason="$(python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    r = d['check_results'][0].get('reason', '')
    print('non_empty' if r else 'empty')
except: print('empty')
" <<< "$stdout")"
    assert_eq "$first_reason" "non_empty" \
        "failed check should have a non-empty reason"
}

# ============================================================================
# 3. Timeout protection for external dependencies
# ============================================================================

test_run_check_times_out_slow_check() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    local stdout exit_code
    stdout="$(PATH="$mock_dir:$PATH" bash -c "
        export __LIVE_BACKEND_GATE_SOURCED=1
        export GATE_CHECK_TIMEOUT_SEC=2
        source '$GATE_SCRIPT'

        check_stripe_key_present() { sleep 60; }
        check_stripe_key_live() { return 0; }
        check_stripe_webhook_secret_present() { return 0; }
        check_stripe_webhook_forwarding() { return 0; }
        check_usage_records_populated() { return 0; }
        check_rollup_current() { return 0; }

        run_gate --skip-rust-tests
    " 2>/dev/null)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" \
        "gate should fail when a check times out"

    local timeout_reason
    timeout_reason="$(python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    for r in d.get('check_results', []):
        if r.get('name') == 'check_stripe_key_present':
            print(r.get('reason', 'MISSING'))
            break
    else:
        print('NOT_FOUND')
except: print('PARSE_ERROR')
" <<< "$stdout")"
    assert_contains "$timeout_reason" "timeout" \
        "timed-out check reason should contain 'timeout'"
}

test_default_timeout_is_30s() {
    local timeout_val
    timeout_val="$(bash -c "
        unset GATE_CHECK_TIMEOUT_SEC
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'
        echo \"\${GATE_CHECK_TIMEOUT_SEC:-unset}\"
    " 2>/dev/null)"

    assert_eq "$timeout_val" "30" \
        "default GATE_CHECK_TIMEOUT_SEC should be 30"
}

# ============================================================================
# 4. Determinism
# ============================================================================

test_gate_output_is_deterministic() {
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

    local norm1 norm2
    norm1="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
d['elapsed_ms'] = 0
for r in d.get('check_results', []):
    r['elapsed_ms'] = 0
print(json.dumps(d, sort_keys=True))
" <<< "$stdout1")"

    norm2="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
d['elapsed_ms'] = 0
for r in d.get('check_results', []):
    r['elapsed_ms'] = 0
print(json.dumps(d, sort_keys=True))
" <<< "$stdout2")"

    assert_eq "$norm1" "$norm2" \
        "gate output should be deterministic across runs (excluding elapsed_ms)"
}

test_check_ordering_is_fixed() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    local stdout
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
    " 2>/dev/null)" || true

    rm -rf "$mock_dir"

    local names_csv
    names_csv="$(python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    names = [c['name'] for c in d.get('check_results', [])]
    print(','.join(names))
except: print('')
" <<< "$stdout")"

    local expected="check_stripe_key_present,check_stripe_key_live,check_stripe_webhook_secret_present,check_stripe_webhook_forwarding,check_usage_records_populated,check_rollup_current,rust_validation_tests"
    assert_eq "$names_csv" "$expected" \
        "check ordering must be fixed: stripe -> metering -> rust"
}

test_concurrent_gate_runs_no_interference() {
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

    local rc1 rc2
    BACKEND_LIVE_GATE=1 bash "$tmpdir/run_gate_once.sh" >"$tmpdir/out1.json" 2>"$tmpdir/err1.log" &
    local pid1=$!
    BACKEND_LIVE_GATE=1 bash "$tmpdir/run_gate_once.sh" >"$tmpdir/out2.json" 2>"$tmpdir/err2.log" &
    local pid2=$!

    if wait "$pid1"; then rc1=0; else rc1=$?; fi
    if wait "$pid2"; then rc2=0; else rc2=$?; fi

    assert_eq "$rc1" "0" "first concurrent gate run should succeed"
    assert_eq "$rc2" "0" "second concurrent gate run should succeed"

    local out1_ok out2_ok
    out1_ok="$(python3 -c "
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data = json.load(f)
print('ok' if len(data.get('check_results', [])) == 7 and data.get('checks_skipped') == 1 else 'bad')
" "$tmpdir/out1.json")"
    out2_ok="$(python3 -c "
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data = json.load(f)
print('ok' if len(data.get('check_results', [])) == 7 and data.get('checks_skipped') == 1 else 'bad')
" "$tmpdir/out2.json")"
    assert_eq "$out1_ok" "ok" "first concurrent run should produce independent complete JSON"
    assert_eq "$out2_ok" "ok" "second concurrent run should produce independent complete JSON"

    rm -rf "$tmpdir"
}

# ============================================================================
# 5. Error classification
# ============================================================================

test_passing_check_has_empty_reason() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    local stdout
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
    " 2>/dev/null)" || true

    rm -rf "$mock_dir"

    local reason
    reason="$(python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(d['check_results'][0].get('reason', 'MISSING'))
except: print('MISSING')
" <<< "$stdout")"

    assert_eq "$reason" "" \
        "passing check should have empty reason"
}

test_skip_pass_detected_from_stderr() {
    # A check that exits 0 but prints [skip] to stderr should be recorded as skipped.
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    local stdout exit_code
    stdout="$(PATH="$mock_dir:$PATH" bash -c "
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'

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

    local first_status
    first_status="$(python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    for r in d.get('check_results', []):
        if r.get('name') == 'check_stripe_key_present':
            print(r.get('status', 'MISSING'))
            break
    else:
        print('NOT_FOUND')
except: print('PARSE_ERROR')
" <<< "$stdout")"
    assert_eq "$first_status" "skipped" \
        "check with [skip] in stderr should be recorded as skipped, not pass"
}

test_skipped_check_has_error_class_skipped() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    local stdout
    stdout="$(PATH="$mock_dir:$PATH" bash -c "
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'

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
    " 2>/dev/null)" || true

    rm -rf "$mock_dir"

    local error_class
    error_class="$(python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    for r in d.get('check_results', []):
        if r.get('name') == 'check_stripe_key_present':
            print(r.get('error_class', 'MISSING'))
            break
    else:
        print('NOT_FOUND')
except: print('PARSE_ERROR')
" <<< "$stdout")"

    assert_eq "$error_class" "skipped" \
        "skipped checks should include error_class=skipped"
}

test_library_timeout_has_error_class_runtime() {
    # Library-level timeout paths return a specific REASON code (for example
    # stripe_api_timeout) but do not use watchdog timeout exit codes (124/137/143),
    # so error_class should remain "runtime".
    # Gate-watchdog timeouts are different: they produce generic timeout reasons
    # and error_class "timeout".
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    local stdout
    stdout="$(PATH="$mock_dir:$PATH" bash -c "
        export __LIVE_BACKEND_GATE_SOURCED=1
        source '$GATE_SCRIPT'

        check_stripe_key_present() {
            echo 'REASON: stripe_api_timeout' >&2
            return 1
        }
        check_stripe_key_live() { return 0; }
        check_stripe_webhook_secret_present() { return 0; }
        check_stripe_webhook_forwarding() { return 0; }
        check_usage_records_populated() { return 0; }
        check_rollup_current() { return 0; }

        run_gate --skip-rust-tests
    " 2>/dev/null)" || true

    rm -rf "$mock_dir"

    local error_class
    error_class="$(python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    for r in d.get('check_results', []):
        if r.get('name') == 'check_stripe_key_present':
            print(r.get('error_class', 'MISSING'))
            break
    else:
        print('NOT_FOUND')
except: print('PARSE_ERROR')
" <<< "$stdout")"

    assert_eq "$error_class" "runtime" \
        "library-level timeout reason should classify as runtime, not watchdog timeout"
}

# ============================================================================
# 6. Backward compatibility
# ============================================================================

test_json_preserves_existing_fields() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    local stdout
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
    " 2>/dev/null)" || true

    rm -rf "$mock_dir"

    local fields_present
    fields_present="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
required = ['passed', 'checks_run', 'checks_failed', 'failures', 'elapsed_ms']
missing = [f for f in required if f not in d]
print('ok' if not missing else 'missing: ' + ','.join(missing))
" <<< "$stdout")"

    assert_eq "$fields_present" "ok" \
        "original JSON fields must be preserved (backward compatible)"
}

test_all_check_results_have_error_class_field() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    setup_mock_cargo "$mock_dir" pass

    local stdout
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
    " 2>/dev/null)" || true

    rm -rf "$mock_dir"

    local all_have_error_class
    all_have_error_class="$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
results = data.get('check_results', [])
print('yes' if results and all('error_class' in r for r in results) else 'no')
" <<< "$stdout")"

    assert_eq "$all_have_error_class" "yes" \
        "all check_results entries should include error_class key"
}

test_fail_fast_records_remaining_as_skipped() {
    # When fail-fast stops early, remaining checks appear as skipped in check_results.
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

    local total_entries
    total_entries="$(python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(len(d.get('check_results', [])))
except: print('0')
" <<< "$stdout")"
    assert_eq "$total_entries" "7" \
        "check_results should list all 7 checks even with fail-fast"

    local skipped_count
    skipped_count="$(python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(sum(1 for r in d.get('check_results', []) if r.get('status') == 'skipped'))
except: print('0')
" <<< "$stdout")"

    local enough_skipped
    enough_skipped="$(python3 -c "print('yes' if $skipped_count >= 4 else 'no')")"
    assert_eq "$enough_skipped" "yes" \
        "at least 4 checks should be skipped after fail-fast at check 2 (got $skipped_count)"
}

scan_bare_exit_1_offenders() {
    local file_csv="$1"
    REPO_ROOT="$REPO_ROOT" FILE_CSV="$file_csv" python3 - <<'PY'
import os
import re

repo_root = os.environ["REPO_ROOT"]
files = [f for f in os.environ.get("FILE_CSV", "").split(",") if f]

func_pattern = re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{')
exit_pattern = re.compile(r'\bexit\s+1\b')
offenders = []

def code_for_exit_scan(line):
    out = []
    in_single = False
    in_double = False
    escaped = False

    for ch in line:
        if in_single:
            if ch == "'":
                in_single = False
            out.append(" ")
            continue

        if in_double:
            if escaped:
                escaped = False
                out.append(" ")
                continue
            if ch == "\\":
                escaped = True
                out.append(" ")
                continue
            if ch == '"':
                in_double = False
                out.append(" ")
                continue
            out.append(" ")
            continue

        if ch == "#":
            break
        if ch == "'":
            in_single = True
            out.append(" ")
            continue
        if ch == '"':
            in_double = True
            out.append(" ")
            continue
        out.append(ch)

    return "".join(out)

for rel_path in files:
    abs_path = os.path.join(repo_root, rel_path)
    current_func = None
    with open(abs_path, "r", encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, start=1):
            stripped = line.strip()
            match = func_pattern.match(line)
            if match:
                current_func = match.group(1)
            if stripped == "}":
                current_func = None
                continue
            if stripped.startswith("#"):
                continue
            code_part = code_for_exit_scan(line)
            if exit_pattern.search(code_part):
                if rel_path == "scripts/lib/live_gate.sh" and current_func == "live_gate_require":
                    continue
                offenders.append(f"{rel_path}:{line_no}:{stripped}")

print(len(offenders))
for offender in offenders:
    print(offender)
PY
}

test_no_bare_exit_1_in_gate_scripts() {
    local audit_output count details
    audit_output="$(scan_bare_exit_1_offenders "scripts/live-backend-gate.sh,scripts/lib/live_gate.sh,scripts/lib/stripe_checks.sh,scripts/lib/metering_checks.sh")"

    count="$(echo "$audit_output" | head -n1)"
    assert_eq "$count" "0" \
        "gate scripts should have zero bare 'exit 1' outside live_gate_require"

    if [ "$count" != "0" ]; then
        details="$(echo "$audit_output" | tail -n +2)"
        fail "bare exit 1 offenders: $details"
    fi
}

test_bare_exit_audit_ignores_quoted_exit_text() {
    local tmp_rel tmp_abs
    tmp_rel="scripts/tests/tmp_bare_exit_scanner_quoted.sh"
    tmp_abs="$REPO_ROOT/$tmp_rel"

    cat > "$tmp_abs" <<'EOF'
#!/usr/bin/env bash
demo_fn() {
    echo "documentation mentions exit 1 but does not execute it"
    return 0
}
EOF

    local audit_output count
    audit_output="$(scan_bare_exit_1_offenders "$tmp_rel")"
    count="$(echo "$audit_output" | head -n1)"

    rm -f "$tmp_abs"

    assert_eq "$count" "0" \
        "bare-exit audit should ignore 'exit 1' occurrences inside quoted strings"
}

# ============================================================================
# Run tests
# ============================================================================

echo "=== gate strictness and determinism tests (Stage 1) ==="
echo ""
echo "--- launch mode skip handling ---"
test_skip_rust_in_launch_mode_records_explicit_skip
test_launch_mode_gate_fails_when_stripe_check_skipped
test_launch_mode_gate_fails_when_metering_check_skipped
test_dev_mode_allows_skipped_checks_with_warning
test_skip_rust_exemption_still_works_in_launch_mode
echo ""
echo "--- per-check detail array ---"
test_json_has_check_results_array
test_check_results_shows_failure_with_reason
echo ""
echo "--- timeout protection ---"
test_run_check_times_out_slow_check
test_default_timeout_is_30s
echo ""
echo "--- determinism ---"
test_gate_output_is_deterministic
test_check_ordering_is_fixed
test_concurrent_gate_runs_no_interference
echo ""
echo "--- error classification ---"
test_passing_check_has_empty_reason
test_skip_pass_detected_from_stderr
test_skipped_check_has_error_class_skipped
test_library_timeout_has_error_class_runtime
echo ""
echo "--- backward compatibility ---"
test_json_preserves_existing_fields
test_all_check_results_have_error_class_field
test_fail_fast_records_remaining_as_skipped
echo ""
echo "--- reason code audit ---"
test_no_bare_exit_1_in_gate_scripts
test_bare_exit_audit_ignores_quoted_exit_text
echo ""
echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
