#!/usr/bin/env bash
# Tests for scripts/launch/collect_evidence.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COLLECT_SCRIPT="$REPO_ROOT/scripts/launch/collect_evidence.sh"

PASS_COUNT=0
FAIL_COUNT=0
RUN_STDOUT=""
RUN_STDERR=""
RUN_EXIT_CODE=0

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

_run_collect() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    cat > "$tmpdir/harness.sh" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail

export __COLLECT_EVIDENCE_SOURCED=1
source "$COLLECT_SCRIPT_PATH"

if [ "${OVERRIDE_RUN_CARGO_TESTS:-1}" = "1" ]; then
_run_cargo_tests() {
    if [ -n "${MOCK_RUST_JSON+x}" ]; then
        printf '%s\n' "$MOCK_RUST_JSON"
    else
        cat <<'JSON'
[{"name":"api","passed":10,"failed":0},{"name":"billing","passed":5,"failed":0},{"name":"metering-agent","passed":8,"failed":0},{"name":"aggregation-job","passed":3,"failed":0}]
JSON
    fi
    return "${MOCK_RUST_EXIT:-0}"
}
fi

if [ "${OVERRIDE_RUN_SHELL_SUITES:-1}" = "1" ]; then
_run_shell_suites() {
    if [ -n "${MOCK_SHELL_JSON+x}" ]; then
        printf '%s\n' "$MOCK_SHELL_JSON"
    else
        cat <<'JSON'
[{"name":"backend_launch_gate_test.sh","passed":12,"failed":0},{"name":"live_gate_test.sh","passed":9,"failed":0}]
JSON
    fi
    return "${MOCK_SHELL_EXIT:-0}"
}
fi

if [ "${OVERRIDE_RUN_BACKEND_GATE:-1}" = "1" ]; then
run_backend_launch_gate() {
    if [ -n "${MOCK_GATE_JSON+x}" ]; then
        printf '%s\n' "$MOCK_GATE_JSON"
    else
        cat <<'JSON'
{"verdict":"pass","timestamp":"2026-03-01T00:00:00Z","gates":[{"name":"reliability","status":"pass","reason":""},{"name":"security","status":"pass","reason":""},{"name":"commerce","status":"pass","reason":""},{"name":"load","status":"pass","reason":""},{"name":"ci_cd","status":"pass","reason":""}]}
JSON
    fi
    return "${MOCK_GATE_EXIT:-0}"
}
fi

collect_evidence "$@"
HARNESS

    chmod +x "$tmpdir/harness.sh"

    local exit_code=0
    if COLLECT_SCRIPT_PATH="$COLLECT_SCRIPT" "$tmpdir/harness.sh" "$@" >"$tmpdir/stdout" 2>"$tmpdir/stderr"; then
        exit_code=0
    else
        exit_code=$?
    fi

    RUN_EXIT_CODE="$exit_code"
    RUN_STDOUT="$(cat "$tmpdir/stdout")"
    RUN_STDERR="$(cat "$tmpdir/stderr")"
    rm -rf "$tmpdir"
}

_valid_sha() {
    printf '%s' 'aabbccddee00112233445566778899aabbccddee'
}

test_script_exists_and_executable() {
    local exists="no"
    local executable="no"

    if [ -f "$COLLECT_SCRIPT" ]; then
        exists="yes"
    fi
    if [ -x "$COLLECT_SCRIPT" ]; then
        executable="yes"
    fi

    assert_eq "$exists" "yes" "collect_evidence.sh should exist"
    assert_eq "$executable" "yes" "collect_evidence.sh should be executable"
}

test_sourcing_exports_collect_evidence_function_without_execution() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    local out_file err_file
    out_file="$tmpdir/out"
    err_file="$tmpdir/err"

    local exit_code=0
    if __COLLECT_EVIDENCE_SOURCED=1 COLLECT_SCRIPT_PATH="$COLLECT_SCRIPT" bash -c 'set -euo pipefail; source "$COLLECT_SCRIPT_PATH"; declare -F collect_evidence >/dev/null' >"$out_file" 2>"$err_file"; then
        exit_code=0
    else
        exit_code=$?
    fi

    assert_eq "$exit_code" "0" "sourcing should export collect_evidence function"
    assert_eq "$(cat "$out_file")" "" "sourcing should not print to stdout"

    rm -rf "$tmpdir"
}

test_collect_requires_sha() {
    _run_collect

    assert_eq "$RUN_EXIT_CODE" "2" "missing --sha should exit 2"
    assert_contains "$RUN_STDERR" "Usage:" "missing --sha should print usage"
}

test_collect_rejects_invalid_sha() {
    _run_collect --sha=not-a-valid-sha

    assert_eq "$RUN_EXIT_CODE" "2" "invalid sha should exit 2"
    assert_contains "$RUN_STDERR" "40-character" "invalid sha should explain required format"
}

test_output_is_valid_json() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    _run_collect --sha="$(_valid_sha)" --evidence-dir="$tmpdir"

    local valid_json="no"
    if python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<< "$RUN_STDOUT" >/dev/null 2>&1; then
        valid_json="yes"
    fi

    assert_eq "$RUN_EXIT_CODE" "0" "successful run should exit 0"
    assert_eq "$valid_json" "yes" "stdout should be parseable JSON"

    rm -rf "$tmpdir"
}

test_json_has_required_top_level_keys() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    _run_collect --sha="$(_valid_sha)" --evidence-dir="$tmpdir"

    local has_keys="no"
    if python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); req=["git","rust_workspace","shell_tests","gates","overall_verdict","external_blockers"]; assert all(k in d for k in req)' <<< "$RUN_STDOUT" >/dev/null 2>&1; then
        has_keys="yes"
    fi

    assert_eq "$has_keys" "yes" "json should contain all required top-level keys"

    rm -rf "$tmpdir"
}

test_git_object_has_sha_branch_timestamp() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    _run_collect --sha="$(_valid_sha)" --evidence-dir="$tmpdir"

    local has_fields="no"
    if python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); g=d.get("git", {}); assert all(k in g for k in ["sha","branch","timestamp"])' <<< "$RUN_STDOUT" >/dev/null 2>&1; then
        has_fields="yes"
    fi

    assert_eq "$has_fields" "yes" "git object should include sha, branch, timestamp"

    rm -rf "$tmpdir"
}

test_rust_workspace_shape() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    _run_collect --sha="$(_valid_sha)" --evidence-dir="$tmpdir"

    local valid_shape="no"
    if python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); rows=d.get("rust_workspace"); assert isinstance(rows,list); assert rows; assert all(isinstance(r,dict) and all(k in r for k in ["name","passed","failed"]) for r in rows)' <<< "$RUN_STDOUT" >/dev/null 2>&1; then
        valid_shape="yes"
    fi

    assert_eq "$valid_shape" "yes" "rust_workspace should be array of name/passed/failed objects"

    rm -rf "$tmpdir"
}

test_shell_tests_shape() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    _run_collect --sha="$(_valid_sha)" --evidence-dir="$tmpdir"

    local valid_shape="no"
    if python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); rows=d.get("shell_tests"); assert isinstance(rows,list); assert rows; assert all(isinstance(r,dict) and all(k in r for k in ["name","passed","failed"]) for r in rows)' <<< "$RUN_STDOUT" >/dev/null 2>&1; then
        valid_shape="yes"
    fi

    assert_eq "$valid_shape" "yes" "shell_tests should be array of name/passed/failed objects"

    rm -rf "$tmpdir"
}

test_gates_shape() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    _run_collect --sha="$(_valid_sha)" --evidence-dir="$tmpdir"

    local valid_shape="no"
    if python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); rows=d.get("gates"); assert isinstance(rows,list); assert rows; assert all(isinstance(r,dict) and all(k in r for k in ["name","status","reason"]) for r in rows)' <<< "$RUN_STDOUT" >/dev/null 2>&1; then
        valid_shape="yes"
    fi

    assert_eq "$valid_shape" "yes" "gates should be array of name/status/reason objects"

    rm -rf "$tmpdir"
}

test_overall_verdict_is_pass_or_fail() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    _run_collect --sha="$(_valid_sha)" --evidence-dir="$tmpdir"

    local valid_verdict="no"
    if python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); v=d.get("overall_verdict"); assert v in ("pass", "fail")' <<< "$RUN_STDOUT" >/dev/null 2>&1; then
        valid_verdict="yes"
    fi

    assert_eq "$valid_verdict" "yes" "overall_verdict should be pass or fail"

    rm -rf "$tmpdir"
}

test_external_blockers_is_array() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    _run_collect --sha="$(_valid_sha)" --evidence-dir="$tmpdir"

    local blockers_array="no"
    if python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert isinstance(d.get("external_blockers"), list)' <<< "$RUN_STDOUT" >/dev/null 2>&1; then
        blockers_array="yes"
    fi

    assert_eq "$blockers_array" "yes" "external_blockers should be an array"

    rm -rf "$tmpdir"
}

test_gate_failure_reason_populates_external_blocker() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    MOCK_GATE_JSON='{"verdict":"fail","timestamp":"2026-03-01T00:00:00Z","gates":[{"name":"security","status":"fail","reason":"security_dep_audit"}]}' \
    _run_collect --sha="$(_valid_sha)" --evidence-dir="$tmpdir"

    local blocker owner command
    blocker="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); rows=d.get("external_blockers", []); print(rows[0].get("blocker", "") if rows else "")' <<< "$RUN_STDOUT")"
    owner="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); rows=d.get("external_blockers", []); print(rows[0].get("owner", "") if rows else "")' <<< "$RUN_STDOUT")"
    command="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); rows=d.get("external_blockers", []); print(rows[0].get("command", "") if rows else "")' <<< "$RUN_STDOUT")"

    assert_eq "$RUN_EXIT_CODE" "1" "failed gate verdict should fail collect_evidence run"
    assert_eq "$blocker" "security_dep_audit" "security_dep_audit gate reason should map to external blocker"
    assert_eq "$owner" "Stuart" "external blocker should include owner"
    assert_contains "$command" "cargo audit" "external blocker should include remediation command"

    rm -rf "$tmpdir"
}

test_parse_suite_results_line_parses_summary() {
    local tmpdir out_file err_file exit_code
    tmpdir="$(mktemp -d)"
    out_file="$tmpdir/out"
    err_file="$tmpdir/err"

    if COLLECT_SCRIPT_PATH="$COLLECT_SCRIPT" bash -lc 'set -euo pipefail
export __COLLECT_EVIDENCE_SOURCED=1
source "$COLLECT_SCRIPT_PATH"
printf "%s\n" "=== Results: 7 passed, 2 failed ===" | _parse_suite_results_line' >"$out_file" 2>"$err_file"; then
        exit_code=0
    else
        exit_code=$?
    fi

    assert_eq "$exit_code" "0" "suite results parser should successfully parse summary line"
    assert_eq "$(cat "$out_file")" "7 2" "suite results parser should return passed/failed counts"

    rm -rf "$tmpdir"
}

test_parse_pass_fail_from_test_output_sums_lines() {
    local tmpdir out_file err_file exit_code
    tmpdir="$(mktemp -d)"
    out_file="$tmpdir/out"
    err_file="$tmpdir/err"

    if COLLECT_SCRIPT_PATH="$COLLECT_SCRIPT" bash -lc 'set -euo pipefail
export __COLLECT_EVIDENCE_SOURCED=1
source "$COLLECT_SCRIPT_PATH"
cat <<'"'"'EOF'"'"' | _parse_pass_fail_from_test_output
test result: ok. 3 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
EOF' >"$out_file" 2>"$err_file"; then
        exit_code=0
    else
        exit_code=$?
    fi

    assert_eq "$exit_code" "0" "cargo test result parser should execute successfully"
    assert_eq "$(cat "$out_file")" "5 1" "cargo test result parser should sum passed/failed counts"

    rm -rf "$tmpdir"
}

test_run_cargo_tests_skips_api_indexes_suite() {
    local tmpdir out_file err_file log_file exit_code
    tmpdir="$(mktemp -d)"
    out_file="$tmpdir/out"
    err_file="$tmpdir/err"
    log_file="$tmpdir/cargo_invocations.log"

    if COLLECT_SCRIPT_PATH="$COLLECT_SCRIPT" CARGO_INVOCATION_LOG="$log_file" bash -lc 'set -euo pipefail
export __COLLECT_EVIDENCE_SOURCED=1
source "$COLLECT_SCRIPT_PATH"
cargo() {
  echo "$*" >> "$CARGO_INVOCATION_LOG"
  cat <<'"'"'EOF'"'"'
test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
EOF
}
_run_cargo_tests >/dev/null' >"$out_file" 2>"$err_file"; then
        exit_code=0
    else
        exit_code=$?
    fi

    local api_cmd
    api_cmd="$(rg '^test -p api' "$log_file" -n --no-line-number | head -n1 || true)"

    assert_eq "$exit_code" "0" "_run_cargo_tests should complete when cargo invocations are mocked"
    assert_contains "$api_cmd" "--lib" "api cargo test invocation should run library tests only in evidence collection"

    rm -rf "$tmpdir"
}

test_invalid_runner_json_fails_closed() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    MOCK_RUST_JSON='not-json' \
    _run_collect --sha="$(_valid_sha)" --evidence-dir="$tmpdir"

    local verdict blocker
    verdict="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("overall_verdict", ""))' <<< "$RUN_STDOUT")"
    blocker="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); b=d.get("external_blockers", []); print("yes" if any(item.get("blocker") == "rust_workspace_invalid_json" for item in b if isinstance(item, dict)) else "no")' <<< "$RUN_STDOUT")"

    assert_eq "$RUN_EXIT_CODE" "1" "invalid rust runner JSON should fail closed"
    assert_eq "$verdict" "fail" "invalid rust runner JSON should force fail verdict"
    assert_eq "$blocker" "yes" "invalid rust runner JSON should be recorded in external_blockers"

    rm -rf "$tmpdir"
}

test_non_list_rust_json_fails_closed() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    MOCK_RUST_JSON='{"name":"api","passed":10,"failed":0}' \
    _run_collect --sha="$(_valid_sha)" --evidence-dir="$tmpdir"

    local verdict blocker
    verdict="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("overall_verdict", ""))' <<< "$RUN_STDOUT")"
    blocker="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); b=d.get("external_blockers", []); print("yes" if any(item.get("blocker") == "rust_workspace_invalid_json" for item in b if isinstance(item, dict)) else "no")' <<< "$RUN_STDOUT")"

    assert_eq "$RUN_EXIT_CODE" "1" "non-list rust runner JSON should fail closed"
    assert_eq "$verdict" "fail" "non-list rust runner JSON should force fail verdict"
    assert_eq "$blocker" "yes" "non-list rust runner JSON should be recorded in external_blockers"

    rm -rf "$tmpdir"
}

test_non_list_shell_json_fails_closed() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    MOCK_SHELL_JSON='{"name":"collect_evidence_test.sh","passed":10,"failed":0}' \
    _run_collect --sha="$(_valid_sha)" --evidence-dir="$tmpdir"

    local verdict blocker
    verdict="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("overall_verdict", ""))' <<< "$RUN_STDOUT")"
    blocker="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); b=d.get("external_blockers", []); print("yes" if any(item.get("blocker") == "shell_tests_invalid_json" for item in b if isinstance(item, dict)) else "no")' <<< "$RUN_STDOUT")"

    assert_eq "$RUN_EXIT_CODE" "1" "non-list shell runner JSON should fail closed"
    assert_eq "$verdict" "fail" "non-list shell runner JSON should force fail verdict"
    assert_eq "$blocker" "yes" "non-list shell runner JSON should be recorded in external_blockers"

    rm -rf "$tmpdir"
}

test_non_numeric_rust_failed_count_fails_closed() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    MOCK_RUST_JSON='[{"name":"api","passed":10,"failed":"not-a-number"}]' \
    _run_collect --sha="$(_valid_sha)" --evidence-dir="$tmpdir"

    local valid_json verdict blocker
    valid_json="no"
    if python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<< "$RUN_STDOUT" >/dev/null 2>&1; then
        valid_json="yes"
    fi
    verdict="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("overall_verdict", ""))' <<< "$RUN_STDOUT" 2>/dev/null || true)"
    blocker="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); b=d.get("external_blockers", []); print("yes" if any(item.get("blocker") == "rust_workspace_invalid_counts" for item in b if isinstance(item, dict)) else "no")' <<< "$RUN_STDOUT" 2>/dev/null || true)"

    assert_eq "$RUN_EXIT_CODE" "1" "non-numeric rust failed count should fail closed"
    assert_eq "$valid_json" "yes" "non-numeric rust failed count should still return JSON output"
    assert_eq "$verdict" "fail" "non-numeric rust failed count should force fail verdict"
    assert_eq "$blocker" "yes" "non-numeric rust failed count should be recorded in external_blockers"

    rm -rf "$tmpdir"
}

test_non_numeric_shell_failed_count_fails_closed() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    MOCK_SHELL_JSON='[{"name":"collect_evidence_test.sh","passed":10,"failed":"not-a-number"}]' \
    _run_collect --sha="$(_valid_sha)" --evidence-dir="$tmpdir"

    local valid_json verdict blocker
    valid_json="no"
    if python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<< "$RUN_STDOUT" >/dev/null 2>&1; then
        valid_json="yes"
    fi
    verdict="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("overall_verdict", ""))' <<< "$RUN_STDOUT" 2>/dev/null || true)"
    blocker="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); b=d.get("external_blockers", []); print("yes" if any(item.get("blocker") == "shell_tests_invalid_counts" for item in b if isinstance(item, dict)) else "no")' <<< "$RUN_STDOUT" 2>/dev/null || true)"

    assert_eq "$RUN_EXIT_CODE" "1" "non-numeric shell failed count should fail closed"
    assert_eq "$valid_json" "yes" "non-numeric shell failed count should still return JSON output"
    assert_eq "$verdict" "fail" "non-numeric shell failed count should force fail verdict"
    assert_eq "$blocker" "yes" "non-numeric shell failed count should be recorded in external_blockers"

    rm -rf "$tmpdir"
}

test_non_numeric_rust_passed_count_fails_closed() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    MOCK_RUST_JSON='[{"name":"api","passed":"not-a-number","failed":0}]' \
    _run_collect --sha="$(_valid_sha)" --evidence-dir="$tmpdir"

    local valid_json verdict blocker
    valid_json="no"
    if python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<< "$RUN_STDOUT" >/dev/null 2>&1; then
        valid_json="yes"
    fi
    verdict="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("overall_verdict", ""))' <<< "$RUN_STDOUT" 2>/dev/null || true)"
    blocker="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); b=d.get("external_blockers", []); print("yes" if any(item.get("blocker") == "rust_workspace_invalid_counts" for item in b if isinstance(item, dict)) else "no")' <<< "$RUN_STDOUT" 2>/dev/null || true)"

    assert_eq "$RUN_EXIT_CODE" "1" "non-numeric rust passed count should fail closed"
    assert_eq "$valid_json" "yes" "non-numeric rust passed count should still return JSON output"
    assert_eq "$verdict" "fail" "non-numeric rust passed count should force fail verdict"
    assert_eq "$blocker" "yes" "non-numeric rust passed count should be recorded in external_blockers"

    rm -rf "$tmpdir"
}

test_non_numeric_shell_passed_count_fails_closed() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    MOCK_SHELL_JSON='[{"name":"collect_evidence_test.sh","passed":"not-a-number","failed":0}]' \
    _run_collect --sha="$(_valid_sha)" --evidence-dir="$tmpdir"

    local valid_json verdict blocker
    valid_json="no"
    if python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<< "$RUN_STDOUT" >/dev/null 2>&1; then
        valid_json="yes"
    fi
    verdict="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("overall_verdict", ""))' <<< "$RUN_STDOUT" 2>/dev/null || true)"
    blocker="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); b=d.get("external_blockers", []); print("yes" if any(item.get("blocker") == "shell_tests_invalid_counts" for item in b if isinstance(item, dict)) else "no")' <<< "$RUN_STDOUT" 2>/dev/null || true)"

    assert_eq "$RUN_EXIT_CODE" "1" "non-numeric shell passed count should fail closed"
    assert_eq "$valid_json" "yes" "non-numeric shell passed count should still return JSON output"
    assert_eq "$verdict" "fail" "non-numeric shell passed count should force fail verdict"
    assert_eq "$blocker" "yes" "non-numeric shell passed count should be recorded in external_blockers"

    rm -rf "$tmpdir"
}

test_invalid_gate_json_fails_closed() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    MOCK_GATE_JSON='not-json' \
    _run_collect --sha="$(_valid_sha)" --evidence-dir="$tmpdir"

    local verdict blocker
    verdict="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("overall_verdict", ""))' <<< "$RUN_STDOUT")"
    blocker="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); b=d.get("external_blockers", []); print("yes" if any(item.get("blocker") == "gates_invalid_json" for item in b if isinstance(item, dict)) else "no")' <<< "$RUN_STDOUT")"

    assert_eq "$RUN_EXIT_CODE" "1" "invalid gate JSON should fail closed"
    assert_eq "$verdict" "fail" "invalid gate JSON should force fail verdict"
    assert_eq "$blocker" "yes" "invalid gate JSON should be recorded in external_blockers"

    rm -rf "$tmpdir"
}

test_non_object_gate_json_fails_closed() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    MOCK_GATE_JSON='[]' \
    _run_collect --sha="$(_valid_sha)" --evidence-dir="$tmpdir"

    local verdict blocker
    verdict="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("overall_verdict", ""))' <<< "$RUN_STDOUT")"
    blocker="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); b=d.get("external_blockers", []); print("yes" if any(item.get("blocker") == "gates_invalid_json" for item in b if isinstance(item, dict)) else "no")' <<< "$RUN_STDOUT")"

    assert_eq "$RUN_EXIT_CODE" "1" "non-object gate JSON should fail closed"
    assert_eq "$verdict" "fail" "non-object gate JSON should force fail verdict"
    assert_eq "$blocker" "yes" "non-object gate JSON should be recorded in external_blockers"

    rm -rf "$tmpdir"
}

test_shell_suite_crash_without_summary_counts_as_failed() {
    local tmpdir suite_dir
    tmpdir="$(mktemp -d)"
    suite_dir="$tmpdir/suites"
    mkdir -p "$suite_dir"

    cat > "$suite_dir/crash_test.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "intentional crash before summary" >&2
exit 42
EOF
    chmod +x "$suite_dir/crash_test.sh"

    OVERRIDE_RUN_SHELL_SUITES=0 \
    COLLECT_SHELL_TESTS_DIR="$suite_dir" \
    _run_collect --sha="$(_valid_sha)" --evidence-dir="$tmpdir"

    local shell_failed shell_skipped verdict
    shell_failed="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); rows=d.get("shell_tests", []); print(rows[0].get("failed", -1) if rows else -1)' <<< "$RUN_STDOUT")"
    shell_skipped="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); rows=d.get("shell_tests", []); print("true" if (rows and rows[0].get("skipped") is True) else "false")' <<< "$RUN_STDOUT")"
    verdict="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("overall_verdict", ""))' <<< "$RUN_STDOUT")"

    assert_eq "$RUN_EXIT_CODE" "1" "suite crash without summary should fail run"
    assert_eq "$shell_failed" "1" "suite crash without summary should count as failed=1"
    assert_eq "$shell_skipped" "false" "suite crash without summary should not be marked skipped"
    assert_eq "$verdict" "fail" "suite crash without summary should force fail verdict"

    rm -rf "$tmpdir"
}

test_shell_suite_dependency_failure_without_summary_is_skipped() {
    local tmpdir suite_dir
    tmpdir="$(mktemp -d)"
    suite_dir="$tmpdir/suites"
    mkdir -p "$suite_dir"

    cat > "$suite_dir/dependency_test.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "source: missing.sh: No such file or directory" >&2
exit 1
EOF
    chmod +x "$suite_dir/dependency_test.sh"

    OVERRIDE_RUN_SHELL_SUITES=0 \
    COLLECT_SHELL_TESTS_DIR="$suite_dir" \
    _run_collect --sha="$(_valid_sha)" --evidence-dir="$tmpdir"

    local shell_failed shell_skipped verdict
    shell_failed="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); rows=d.get("shell_tests", []); print(rows[0].get("failed", -1) if rows else -1)' <<< "$RUN_STDOUT")"
    shell_skipped="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); rows=d.get("shell_tests", []); print("true" if (rows and rows[0].get("skipped") is True) else "false")' <<< "$RUN_STDOUT")"
    verdict="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("overall_verdict", ""))' <<< "$RUN_STDOUT")"

    assert_eq "$RUN_EXIT_CODE" "0" "dependency/source failure should be skipped and not fail run"
    assert_eq "$shell_failed" "0" "dependency/source failure should keep failed=0"
    assert_eq "$shell_skipped" "true" "dependency/source failure should be marked skipped"
    assert_eq "$verdict" "pass" "dependency/source skipped suite should not force fail verdict"

    rm -rf "$tmpdir"
}

test_evidence_file_written_to_target_directory() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    _run_collect --sha="$(_valid_sha)" --evidence-dir="$tmpdir"

    local evidence_file
    evidence_file="$(find "$tmpdir" -maxdepth 1 -type f -name 'evidence_*.json' | head -n1 || true)"
    local has_file="no"
    if [ -n "$evidence_file" ]; then
        has_file="yes"
    fi

    assert_eq "$RUN_EXIT_CODE" "0" "run with valid args should succeed"
    assert_eq "$has_file" "yes" "evidence file should be created"

    rm -rf "$tmpdir"
}

test_index_is_appended_not_overwritten() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    _run_collect --sha="$(_valid_sha)" --evidence-dir="$tmpdir"
    local first_exit="$RUN_EXIT_CODE"
    _run_collect --sha="$(_valid_sha)" --evidence-dir="$tmpdir"
    local second_exit="$RUN_EXIT_CODE"

    local index_file="$tmpdir/INDEX.md"
    local line_count="0"
    if [ -f "$index_file" ]; then
        line_count="$(wc -l < "$index_file" | tr -d ' ')"
    fi

    assert_eq "$first_exit" "0" "first run should succeed"
    assert_eq "$second_exit" "0" "second run should succeed"
    assert_eq "$line_count" "2" "index should contain one appended line per run"

    rm -rf "$tmpdir"
}

run_all_tests() {
    echo "=== collect_evidence tests ==="
    test_script_exists_and_executable
    test_sourcing_exports_collect_evidence_function_without_execution
    test_collect_requires_sha
    test_collect_rejects_invalid_sha
    test_output_is_valid_json
    test_json_has_required_top_level_keys
    test_git_object_has_sha_branch_timestamp
    test_rust_workspace_shape
    test_shell_tests_shape
    test_gates_shape
    test_overall_verdict_is_pass_or_fail
    test_external_blockers_is_array
    test_gate_failure_reason_populates_external_blocker
    test_parse_suite_results_line_parses_summary
    test_parse_pass_fail_from_test_output_sums_lines
    test_run_cargo_tests_skips_api_indexes_suite
    test_invalid_runner_json_fails_closed
    test_non_list_rust_json_fails_closed
    test_non_list_shell_json_fails_closed
    test_non_numeric_rust_failed_count_fails_closed
    test_non_numeric_shell_failed_count_fails_closed
    test_non_numeric_rust_passed_count_fails_closed
    test_non_numeric_shell_passed_count_fails_closed
    test_invalid_gate_json_fails_closed
    test_non_object_gate_json_fails_closed
    test_shell_suite_crash_without_summary_counts_as_failed
    test_shell_suite_dependency_failure_without_summary_is_skipped
    test_evidence_file_written_to_target_directory
    test_index_is_appended_not_overwritten

    echo
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -ne 0 ]; then
        return 1
    fi
}

run_all_tests
