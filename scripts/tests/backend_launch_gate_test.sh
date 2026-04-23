#!/usr/bin/env bash
# Tests for scripts/launch/backend_launch_gate.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE_SCRIPT="$REPO_ROOT/scripts/launch/backend_launch_gate.sh"

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

assert_regex() {
    local actual="$1" pattern="$2" msg="$3"
    if ! printf '%s' "$actual" | grep -Eq "$pattern"; then
        fail "$msg (expected regex '$pattern' in '$actual')"
    else
        pass "$msg"
    fi
}

_json_field() {
    local json="$1" field="$2"
    python3 -c "import json,sys; print(json.dumps(json.loads(sys.stdin.read())['$field']))" <<< "$json"
}

_json_gate_field() {
    local json="$1" gate_name="$2" field="$3"
    python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
for gate in data.get('gates', []):
    if gate.get('name') == '$gate_name':
        print(json.dumps(gate.get('$field')))
        break
else:
    print('null')
" <<< "$json"
}

_normalized_gate_json() {
    local json="$1"
    python3 -c '
import json, sys
data = json.loads(sys.stdin.read())
data["timestamp"] = "NORMALIZED"
for gate in data.get("gates", []):
    gate["duration_ms"] = 0
print(json.dumps(data, sort_keys=True, separators=(",", ":")))
' <<< "$json"
}

_top_level_key_order() {
    local json="$1"
    python3 -c '
import json, sys
pairs = json.loads(sys.stdin.read(), object_pairs_hook=list)
print(",".join(k for k, _ in pairs))
' <<< "$json"
}

_first_gate_key_order() {
    local json="$1"
    python3 -c '
import json, sys
data = json.loads(sys.stdin.read(), object_pairs_hook=list)
for key, value in data:
    if key == "gates" and value:
        first_gate = value[0]
        print(",".join(k for k, _ in first_gate))
        break
else:
    print("MISSING")
' <<< "$json"
}

_run_gate() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    local evidence_dir
    if [ -n "${LAUNCH_GATE_EVIDENCE_DIR:-}" ]; then
        evidence_dir="$LAUNCH_GATE_EVIDENCE_DIR"
    else
        evidence_dir="$tmpdir/evidence"
    fi
    mkdir -p "$evidence_dir"

cat > "$tmpdir/harness.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

export __BACKEND_LAUNCH_GATE_SOURCED=1
source "$GATE_SCRIPT_PATH"

default_pass_json='{"passed": true, "failures": []}'

if [ "${OVERRIDE_RELIABILITY:-1}" = "1" ]; then
    _invoke_reliability_gate() {
        printf '%s\n' "${MOCK_RELIABILITY_JSON:-$default_pass_json}"
        return "${MOCK_RELIABILITY_EXIT:-0}"
    }
fi

if [ "${OVERRIDE_SECURITY:-1}" = "1" ]; then
    _invoke_security_gate() {
        printf '%s\n' "${MOCK_SECURITY_JSON:-$default_pass_json}"
        return "${MOCK_SECURITY_EXIT:-0}"
    }
fi

if [ "${OVERRIDE_LOAD:-1}" = "1" ]; then
    _invoke_load_gate() {
        printf '%s\n' "${MOCK_LOAD_JSON:-$default_pass_json}"
        return "${MOCK_LOAD_EXIT:-0}"
    }
fi

if [ "${OVERRIDE_COMMERCE:-1}" = "1" ]; then
    _invoke_commerce_gate() {
        printf '%s\n' "${MOCK_COMMERCE_JSON:-$default_pass_json}"
        return "${MOCK_COMMERCE_EXIT:-0}"
    }
fi

if [ "${OVERRIDE_CI_CD:-1}" = "1" ]; then
    _invoke_ci_cd_gate() {
        printf '%s\n' "${MOCK_CI_CD_JSON:-$default_pass_json}"
        return "${MOCK_CI_CD_EXIT:-0}"
    }
fi

run_backend_launch_gate "$@"
EOF

    chmod +x "$tmpdir/harness.sh"

    local exit_code=0
    if GATE_SCRIPT_PATH="$GATE_SCRIPT" LAUNCH_GATE_EVIDENCE_DIR="$evidence_dir" "$tmpdir/harness.sh" "$@" >"$tmpdir/stdout" 2>"$tmpdir/stderr"; then
        exit_code=0
    else
        exit_code=$?
    fi

    RUN_EXIT_CODE="$exit_code"
    RUN_STDOUT="$(cat "$tmpdir/stdout")"
    RUN_STDERR="$(cat "$tmpdir/stderr")"
    rm -rf "$tmpdir"
}

test_run_backend_launch_gate_all_pass_happy_path() {
    _run_gate --sha=aabbccddee00112233445566778899aabbccddee --env=staging

    assert_eq "$RUN_EXIT_CODE" "0" "all-pass run should exit 0"
    assert_eq "$(_json_field "$RUN_STDOUT" verdict)" '"pass"' "verdict should be pass"
    assert_eq "$(_json_field "$RUN_STDOUT" gates | python3 -c 'import json,sys; print(len(json.loads(sys.stdin.read())))')" "5" "gates array should have 5 entries"
    assert_eq "$(_json_gate_field "$RUN_STDOUT" reliability status)" '"pass"' "reliability gate status should be pass"
    assert_eq "$(_json_gate_field "$RUN_STDOUT" security status)" '"pass"' "security gate status should be pass"
    assert_eq "$(_json_gate_field "$RUN_STDOUT" load status)" '"pass"' "load gate status should be pass"
    assert_eq "$(_json_gate_field "$RUN_STDOUT" commerce status)" '"pass"' "commerce gate status should be pass"
    assert_eq "$(_json_gate_field "$RUN_STDOUT" ci_cd status)" '"pass"' "ci_cd gate status should be pass"
    assert_regex "$(_json_field "$RUN_STDOUT" timestamp)" '"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"' "timestamp should be ISO 8601 UTC"
}

test_run_gate_default_does_not_write_real_evidence_dir() {
    local real_evidence_dir="$REPO_ROOT/docs/launch/evidence"
    local before_count after_count
    before_count="$(find "$real_evidence_dir" -maxdepth 1 -type f -name 'backend_gate_*.json' | wc -l | tr -d ' ')"

    _run_gate --sha=aabbccddee00112233445566778899aabbccddee --env=staging

    after_count="$(find "$real_evidence_dir" -maxdepth 1 -type f -name 'backend_gate_*.json' | wc -l | tr -d ' ')"
    assert_eq "$RUN_EXIT_CODE" "0" "default _run_gate invocation should pass"
    assert_eq "$after_count" "$before_count" "default _run_gate should not write to docs/launch/evidence"
}

test_run_backend_launch_gate_single_failure_propagates_reason() {
    MOCK_RELIABILITY_JSON='{"passed": false, "failures": ["reliability_scheduler_tests"], "checks_failed": 1}' \
    _run_gate --sha=aabbccddee00112233445566778899aabbccddee --env=staging

    assert_eq "$RUN_EXIT_CODE" "1" "single failing sub-gate should exit 1"
    assert_eq "$(_json_field "$RUN_STDOUT" verdict)" '"fail"' "verdict should be fail"
    assert_eq "$(_json_gate_field "$RUN_STDOUT" reliability status)" '"fail"' "reliability gate status should be fail"
    assert_contains "$(_json_gate_field "$RUN_STDOUT" reliability reason)" 'reliability_scheduler_tests' "reliability reason should include failure name"
    assert_eq "$(_json_gate_field "$RUN_STDOUT" security status)" '"pass"' "security gate should still run and pass"
    assert_eq "$(_json_gate_field "$RUN_STDOUT" load status)" '"pass"' "load gate should still run and pass"
    assert_eq "$(_json_gate_field "$RUN_STDOUT" commerce status)" '"pass"' "commerce gate should still run and pass"
    assert_eq "$(_json_gate_field "$RUN_STDOUT" ci_cd status)" '"pass"' "ci_cd gate should still run and pass"
}

test_run_backend_launch_gate_multi_failure_records_all_reasons() {
    MOCK_RELIABILITY_JSON='{"passed": false, "failures": ["reliability_scheduler_tests"], "checks_failed": 1}' \
    MOCK_SECURITY_JSON='{"passed": false, "failures": ["security_cmd_injection"], "checks_failed": 1}' \
    _run_gate --sha=aabbccddee00112233445566778899aabbccddee --env=staging

    assert_eq "$RUN_EXIT_CODE" "1" "multiple failing sub-gates should exit 1"
    assert_eq "$(_json_field "$RUN_STDOUT" verdict)" '"fail"' "verdict should be fail when any gate fails"
    assert_eq "$(_json_gate_field "$RUN_STDOUT" reliability status)" '"fail"' "reliability status should be fail"
    assert_eq "$(_json_gate_field "$RUN_STDOUT" security status)" '"fail"' "security status should be fail"
    assert_contains "$(_json_gate_field "$RUN_STDOUT" reliability reason)" 'reliability_scheduler_tests' "reliability reason should include reliability failure"
    assert_contains "$(_json_gate_field "$RUN_STDOUT" security reason)" 'security_cmd_injection' "security reason should include security failure"
}

test_ci_cd_gate_passes_in_mock_mode() {
    DEPLOY_GATE_MODE=mock DEPLOY_GATE_MOCK_CI_STATUS=pass \
    OVERRIDE_RELIABILITY=1 OVERRIDE_SECURITY=1 OVERRIDE_LOAD=1 OVERRIDE_COMMERCE=1 OVERRIDE_CI_CD=0 \
    _run_gate --sha=aabbccddee00112233445566778899aabbccddee --env=staging

    assert_eq "$RUN_EXIT_CODE" "0" "ci_cd pass in mock mode should keep gate passing"
    assert_eq "$(_json_gate_field "$RUN_STDOUT" ci_cd status)" '"pass"' "ci_cd status should be pass when ci_status_is_passing passes"
}

test_ci_cd_gate_fails_in_mock_mode_when_ci_fails() {
    DEPLOY_GATE_MODE=mock DEPLOY_GATE_MOCK_CI_STATUS=fail \
    OVERRIDE_RELIABILITY=1 OVERRIDE_SECURITY=1 OVERRIDE_LOAD=1 OVERRIDE_COMMERCE=1 OVERRIDE_CI_CD=0 \
    _run_gate --sha=aabbccddee00112233445566778899aabbccddee --env=staging

    assert_eq "$RUN_EXIT_CODE" "1" "ci_cd fail in mock mode should fail aggregate gate"
    assert_eq "$(_json_gate_field "$RUN_STDOUT" ci_cd status)" '"fail"' "ci_cd status should be fail when CI is not passing"
    assert_contains "$(_json_gate_field "$RUN_STDOUT" ci_cd reason)" 'CI' "ci_cd failure reason should mention CI"
}

test_run_backend_launch_gate_requires_sha() {
    _run_gate --env=staging

    assert_eq "$RUN_EXIT_CODE" "2" "missing --sha should fail with usage error"
    assert_contains "$RUN_STDERR" '--sha' "missing --sha should print usage guidance"
}

test_run_backend_launch_gate_rejects_invalid_sha() {
    _run_gate --sha=not-a-valid-sha --env=staging
    assert_eq "$RUN_EXIT_CODE" "2" "invalid --sha format should fail with exit code 2"
    assert_contains "$RUN_STDERR" '40-character' "invalid --sha should mention 40-character requirement"
}

test_run_backend_launch_gate_rejects_uppercase_sha() {
    _run_gate --sha=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA --env=staging
    assert_eq "$RUN_EXIT_CODE" "2" "uppercase hex --sha should fail (must be lowercase)"
}

test_evidence_archival_writes_to_custom_directory() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    LAUNCH_GATE_EVIDENCE_DIR="$tmpdir" \
    _run_gate --sha=aabbccddee00112233445566778899aabbccddee --env=staging

    local evidence_file
    evidence_file="$(find "$tmpdir" -maxdepth 1 -type f -name 'backend_gate_*.json' | head -n1 || true)"
    local has_file="no"
    if [ -n "$evidence_file" ]; then
        has_file="yes"
    fi

    assert_eq "$RUN_EXIT_CODE" "0" "evidence archival happy path should pass"
    assert_eq "$has_file" "yes" "evidence file should be archived to LAUNCH_GATE_EVIDENCE_DIR"
    assert_regex "$(basename "$evidence_file")" '^backend_gate_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}\.json$' "evidence filename should match timestamp pattern"
    assert_eq "$(python3 -m json.tool < "$evidence_file" >/dev/null 2>&1; echo $?)" "0" "evidence file should contain valid JSON"
    assert_contains "$(cat "$evidence_file")" '"verdict"' "evidence file should include verdict"
    assert_contains "$(cat "$evidence_file")" '"gates"' "evidence file should include gates"

    rm -rf "$tmpdir"
}

test_evidence_archival_avoids_overwriting_existing_file() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    local existing_file
    existing_file="$tmpdir/backend_gate_$(date +%Y-%m-%d_%H%M%S).json"
    printf '%s\n' '{"existing": true}' > "$existing_file"

    LAUNCH_GATE_EVIDENCE_DIR="$tmpdir" \
    _run_gate --sha=aabbccddee00112233445566778899aabbccddee --env=staging

    local file_count
    file_count="$(find "$tmpdir" -maxdepth 1 -type f -name 'backend_gate_*.json' | wc -l | tr -d ' ')"

    assert_eq "$RUN_EXIT_CODE" "0" "evidence archival should still pass when a colliding filename exists"
    assert_eq "$file_count" "2" "evidence archival should create a second file instead of overwriting"
    assert_contains "$(cat "$existing_file")" '"existing"' "pre-existing evidence file should remain unchanged"

    rm -rf "$tmpdir"
}

test_commerce_gate_calls_live_backend_gate() {
    OVERRIDE_RELIABILITY=1 OVERRIDE_SECURITY=1 OVERRIDE_LOAD=1 OVERRIDE_CI_CD=1 OVERRIDE_COMMERCE=0 \
    BACKEND_LIVE_GATE=0 \
    _run_gate --sha=aabbccddee00112233445566778899aabbccddee --env=staging

    assert_eq "$RUN_EXIT_CODE" "0" "commerce gate invocation should pass in BACKEND_LIVE_GATE=0 mode"
    assert_eq "$(_json_gate_field "$RUN_STDOUT" commerce status)" '"pass"' "commerce status should be pass"
    assert_not_contains "$(_json_gate_field "$RUN_STDOUT" commerce reason)" 'commerce stub' "commerce reason should no longer be the placeholder stub reason"
    assert_regex "$(_json_gate_field "$RUN_STDOUT" commerce checks_run)" '^[0-9]+$' "commerce gate should expose checks_run metadata from live-backend-gate output"
}

test_dry_run_commerce_gate_skips_external_checks() {
    OVERRIDE_RELIABILITY=1 OVERRIDE_SECURITY=1 OVERRIDE_LOAD=1 OVERRIDE_CI_CD=1 OVERRIDE_COMMERCE=0 \
    DRY_RUN=1 \
    _run_gate --sha=aabbccddee00112233445566778899aabbccddee --env=staging

    assert_eq "$RUN_EXIT_CODE" "0" "dry-run commerce gate should pass by skipping external checks"
    assert_eq "$(_json_gate_field "$RUN_STDOUT" commerce status)" '"pass"' "commerce gate should pass in dry-run mode"
    assert_regex "$(_json_gate_field "$RUN_STDOUT" commerce reason)" 'dry_run|skip' "commerce reason should include dry-run/skip marker"
}

test_dry_run_ci_cd_gate_returns_stub() {
    OVERRIDE_RELIABILITY=1 OVERRIDE_SECURITY=1 OVERRIDE_LOAD=1 OVERRIDE_COMMERCE=1 OVERRIDE_CI_CD=0 \
    DRY_RUN=1 \
    _run_gate --sha=aabbccddee00112233445566778899aabbccddee --env=staging

    assert_eq "$RUN_EXIT_CODE" "0" "dry-run ci_cd gate should pass with stub"
    assert_eq "$(_json_gate_field "$RUN_STDOUT" ci_cd status)" '"pass"' "ci_cd gate should pass in dry-run mode"
    assert_regex "$(_json_gate_field "$RUN_STDOUT" ci_cd reason)" 'dry_run|skipped' "ci_cd reason should include dry-run skipped marker"
}

test_run_sub_gate_rejects_command_injection_in_symbol() {
    local marker output exit_code
    marker="$(mktemp)"
    rm -f "$marker"

    output="$(bash -c "
        set -euo pipefail
        export __BACKEND_LAUNCH_GATE_SOURCED=1
        source '$GATE_SCRIPT'
        _GATE_NAMES=()
        _GATE_STATUSES=()
        _GATE_REASONS=()
        _GATE_DURATIONS=()
        _GATE_CHECKS_RUN=()
        _run_sub_gate 'security' 'touch $marker'
        echo \"\${_GATE_STATUSES[0]}\"
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "0" "_run_sub_gate injection harness should complete"
    assert_contains "$output" "fail" "_run_sub_gate should fail for invalid injected command symbol"
    if [ -f "$marker" ]; then
        fail "_run_sub_gate must not execute injected shell commands from command symbol"
    else
        pass "_run_sub_gate did not execute injected shell commands"
    fi
    rm -f "$marker"
}

test_aggregate_gate_json_key_ordering_stable() {
    _run_gate --sha=aabbccddee00112233445566778899aabbccddee --env=staging
    local stdout1="$RUN_STDOUT"

    _run_gate --sha=aabbccddee00112233445566778899aabbccddee --env=staging
    local stdout2="$RUN_STDOUT"

    local normalized1 normalized2
    normalized1="$(_normalized_gate_json "$stdout1")"
    normalized2="$(_normalized_gate_json "$stdout2")"
    assert_eq "$normalized1" "$normalized2" \
        "aggregate gate JSON should be stable across identical runs after timestamp normalization"

    local top_level_order
    top_level_order="$(_top_level_key_order "$stdout1")"
    assert_eq "$top_level_order" "gates,timestamp,verdict" \
        "aggregate gate top-level JSON keys should be lexicographically sorted"

    local gate_key_order
    gate_key_order="$(_first_gate_key_order "$stdout1")"
    assert_eq "$gate_key_order" "checks_run,duration_ms,name,reason,status" \
        "aggregate gate entry keys should be lexicographically sorted"
}

test_backend_launch_gate_json_keys_sorted() {
    _run_gate --sha=aabbccddee00112233445566778899aabbccddee --env=staging
    local stdout="$RUN_STDOUT"

    local top_level_order
    top_level_order="$(_top_level_key_order "$stdout")"
    assert_eq "$top_level_order" "gates,timestamp,verdict" \
        "backend launch gate top-level JSON keys should be sorted"

    local gate_key_order
    gate_key_order="$(_first_gate_key_order "$stdout")"
    assert_eq "$gate_key_order" "checks_run,duration_ms,name,reason,status" \
        "backend launch gate entry keys should be sorted"
}

test_backend_launch_gate_json_is_deterministic() {
    _run_gate --sha=aabbccddee00112233445566778899aabbccddee --env=staging
    local stdout1="$RUN_STDOUT"

    _run_gate --sha=aabbccddee00112233445566778899aabbccddee --env=staging
    local stdout2="$RUN_STDOUT"

    local normalized1 normalized2
    normalized1="$(_normalized_gate_json "$stdout1")"
    normalized2="$(_normalized_gate_json "$stdout2")"

    assert_eq "$normalized1" "$normalized2" \
        "backend launch gate JSON should be deterministic after normalization"
}

run_all_tests() {
    echo "=== backend_launch_gate tests ==="
    test_run_backend_launch_gate_all_pass_happy_path
    test_run_gate_default_does_not_write_real_evidence_dir
    test_run_backend_launch_gate_single_failure_propagates_reason
    test_run_backend_launch_gate_multi_failure_records_all_reasons
    test_ci_cd_gate_passes_in_mock_mode
    test_ci_cd_gate_fails_in_mock_mode_when_ci_fails
    test_run_backend_launch_gate_requires_sha
    test_run_backend_launch_gate_rejects_invalid_sha
    test_run_backend_launch_gate_rejects_uppercase_sha
    test_evidence_archival_writes_to_custom_directory
    test_evidence_archival_avoids_overwriting_existing_file
    test_commerce_gate_calls_live_backend_gate
    test_dry_run_commerce_gate_skips_external_checks
    test_dry_run_ci_cd_gate_returns_stub
    test_run_sub_gate_rejects_command_injection_in_symbol
    test_aggregate_gate_json_key_ordering_stable
    test_backend_launch_gate_json_keys_sorted
    test_backend_launch_gate_json_is_deterministic

    echo
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -ne 0 ]; then
        return 1
    fi
}

run_all_tests
