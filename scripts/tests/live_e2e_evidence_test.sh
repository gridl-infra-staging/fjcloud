#!/usr/bin/env bash
# Red-first contract tests for scripts/launch/live_e2e_evidence.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIVE_E2E_SCRIPT="$REPO_ROOT/scripts/launch/live_e2e_evidence.sh"
# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
RUN_STDOUT=""
RUN_STDERR=""
RUN_EXIT_CODE=0
TEST_WORKSPACE=""
TEST_CALL_LOG=""
CLEANUP_DIRS=()
cleanup_test_workspaces() {
    local d
    for d in "${CLEANUP_DIRS[@]:-}"; do
        [ -n "$d" ] && rm -rf "$d"
    done
}
trap cleanup_test_workspaces EXIT
shell_quote_for_script() {
    local quoted
    printf -v quoted '%q' "$1"
    printf '%s\n' "$quoted"
}
write_explicit_env_file() {
    local path="$1"
    cat > "$path" <<'ENVFILE'
AWS_ACCESS_KEY_ID=AKIATESTEVIDENCE
AWS_SECRET_ACCESS_KEY=test-live-e2e-secret
AWS_DEFAULT_REGION=us-east-1
CLOUDFLARE_API_TOKEN=test-cloudflare-token
CLOUDFLARE_ZONE_ID=test-zone-id
ENVFILE
}
write_secret_fixture_env_file() {
    local path="$1"
    cat > "$path" <<'ENVFILE'
AWS_ACCESS_KEY_ID=AKIAREDACTIONTEST
AWS_SECRET_ACCESS_KEY=super-secret-contract-value
AWS_DEFAULT_REGION=us-east-1
CLOUDFLARE_API_TOKEN=cf-secret-contract-value
CLOUDFLARE_ZONE_ID=cf-zone-secret-value
STRIPE_SECRET_KEY=stripe-live-secret-contract-value
STRIPE_TEST_SECRET_KEY=stripe-test-secret-contract-value
STRIPE_WEBHOOK_SECRET=stripe-webhook-secret-contract-value
ENVFILE
}
write_mock_runtime_smoke() {
    local quoted_log
    quoted_log="$(shell_quote_for_script "$TEST_CALL_LOG")"
    cat > "$TEST_WORKSPACE/ops/terraform/tests_stage7_runtime_smoke.sh" <<MOCK
#!/usr/bin/env bash
set -euo pipefail
CALL_LOG=$quoted_log
echo "runtime_smoke|\$*" >> "\$CALL_LOG"
if [ -n "\${RUNTIME_SMOKE_MOCK_STDOUT:-}" ]; then
    printf '%s\n' "\$RUNTIME_SMOKE_MOCK_STDOUT"
fi
if [ -n "\${RUNTIME_SMOKE_MOCK_STDERR:-}" ]; then
    printf '%s\n' "\$RUNTIME_SMOKE_MOCK_STDERR" >&2
fi
if [ "\${RUNTIME_SMOKE_MOCK_ECHO_ENV_SECRETS:-0}" = "1" ]; then
    [ -n "\${AWS_SECRET_ACCESS_KEY:-}" ] && printf '%s\n' "\$AWS_SECRET_ACCESS_KEY"
    [ -n "\${CLOUDFLARE_API_TOKEN:-}" ] && printf '%s\n' "\$CLOUDFLARE_API_TOKEN" >&2
fi
exit "\${RUNTIME_SMOKE_MOCK_EXIT_CODE:-0}"
MOCK
    chmod +x "$TEST_WORKSPACE/ops/terraform/tests_stage7_runtime_smoke.sh"
}
write_mock_billing_rehearsal() {
    local quoted_log
    quoted_log="$(shell_quote_for_script "$TEST_CALL_LOG")"
    cat > "$TEST_WORKSPACE/scripts/staging_billing_rehearsal.sh" <<MOCK
#!/usr/bin/env bash
set -euo pipefail
echo "billing_rehearsal|\$*" >> $quoted_log
if [ -n "\${BILLING_REHEARSAL_MOCK_STDOUT:-}" ]; then
    printf '%s\n' "\$BILLING_REHEARSAL_MOCK_STDOUT"
fi
if [ -n "\${BILLING_REHEARSAL_MOCK_STDERR:-}" ]; then
    printf '%s\n' "\$BILLING_REHEARSAL_MOCK_STDERR" >&2
fi
exit "\${BILLING_REHEARSAL_MOCK_EXIT_CODE:-0}"
MOCK
    chmod +x "$TEST_WORKSPACE/scripts/staging_billing_rehearsal.sh"
}
copy_optional_support_trees() {
    local source_dir dest_dir
    for source_dir in "$REPO_ROOT/scripts/lib" "$REPO_ROOT/ops/scripts/lib"; do
        [ -d "$source_dir" ] || continue
        case "$source_dir" in
            "$REPO_ROOT/scripts/lib")
                dest_dir="$TEST_WORKSPACE/scripts/lib"
                ;;
            "$REPO_ROOT/ops/scripts/lib")
                dest_dir="$TEST_WORKSPACE/ops/scripts/lib"
                ;;
        esac
        mkdir -p "$dest_dir"
        cp "$source_dir"/*.sh "$dest_dir/" 2>/dev/null || true
    done
}
setup_workspace() {
    TEST_WORKSPACE="$(mktemp -d)"
    CLEANUP_DIRS+=("$TEST_WORKSPACE")
    mkdir -p "$TEST_WORKSPACE/scripts/launch" \
             "$TEST_WORKSPACE/scripts/lib" \
             "$TEST_WORKSPACE/scripts" \
             "$TEST_WORKSPACE/ops/terraform" \
             "$TEST_WORKSPACE/ops/scripts/lib" \
             "$TEST_WORKSPACE/bin" \
             "$TEST_WORKSPACE/tmp" \
             "$TEST_WORKSPACE/artifacts" \
             "$TEST_WORKSPACE/inputs"
    TEST_CALL_LOG="$TEST_WORKSPACE/tmp/calls.log"
    : > "$TEST_CALL_LOG"
    [ -f "$LIVE_E2E_SCRIPT" ] && cp "$LIVE_E2E_SCRIPT" "$TEST_WORKSPACE/scripts/launch/" || true
    copy_optional_support_trees
    write_mock_runtime_smoke
    write_mock_billing_rehearsal
    write_explicit_env_file "$TEST_WORKSPACE/inputs/live_e2e.explicit.env"
    write_secret_fixture_env_file "$TEST_WORKSPACE/inputs/live_e2e.secrets.env"
}
require_live_e2e_script_for_contract() {
    local reason="$1"
    if [ ! -x "$LIVE_E2E_SCRIPT" ]; then
        fail "$reason requires executable scripts/launch/live_e2e_evidence.sh"
        return 1
    fi
    return 0
}
_run_live_e2e_evidence() {
    local cli_args=""
    local env_args=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --args)
                cli_args="$2"
                shift 2
                ;;
            *)
                env_args+=("$1")
                shift
                ;;
        esac
    done
    env_args+=("PATH=$TEST_WORKSPACE/bin:/usr/bin:/bin:/usr/local/bin")
    env_args+=("HOME=$TEST_WORKSPACE")
    env_args+=("TMPDIR=$TEST_WORKSPACE/tmp")
    local wrapper_script="$TEST_WORKSPACE/scripts/launch/live_e2e_evidence.sh"
    local stdout_file="$TEST_WORKSPACE/tmp/live_e2e_stdout.txt"
    local stderr_file="$TEST_WORKSPACE/tmp/live_e2e_stderr.txt"
    RUN_EXIT_CODE=0
    if [ -n "$cli_args" ]; then
        # shellcheck disable=SC2086
        (cd "$TEST_WORKSPACE" && env -i "${env_args[@]}" /bin/bash "$wrapper_script" $cli_args >"$stdout_file" 2>"$stderr_file") || RUN_EXIT_CODE=$?
    else
        (cd "$TEST_WORKSPACE" && env -i "${env_args[@]}" /bin/bash "$wrapper_script" >"$stdout_file" 2>"$stderr_file") || RUN_EXIT_CODE=$?
    fi
    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
}
json_field() {
    python3 - "$1" "$2" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
value = payload.get(sys.argv[2], "")
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
else:
    print(str(value))
PY
}
json_check_field_in_lane() {
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
lane = sys.argv[2]
check_name = sys.argv[3]
field = sys.argv[4]
for row in payload.get(lane, []):
    if isinstance(row, dict) and row.get("name") == check_name:
        value = row.get(field, "")
        if isinstance(value, bool):
            print("true" if value else "false")
        elif value is None:
            print("")
        else:
            print(str(value))
        raise SystemExit(0)
print("")
PY
}
json_check_field() {
    json_check_field_in_lane "$1" "checks" "$2" "$3"
}
json_credentialed_check_field() {
    json_check_field_in_lane "$1" "credentialed_checks" "$2" "$3"
}
run_artifact_dir_count() {
    local artifact_root="$1"
    local d count=0
    for d in "$artifact_root"/fjcloud_live_e2e_evidence_*; do
        [ -d "$d" ] || continue
        count=$((count + 1))
    done
    printf '%s\n' "$count"
}
find_run_artifact_dir() {
    local artifact_root="$1"
    local d
    for d in "$artifact_root"/fjcloud_live_e2e_evidence_*; do
        [ -d "$d" ] && { printf '%s\n' "$d"; return 0; }
    done
    printf '\n'
    return 0
}
read_file_or_empty() {
    local path="$1"
    if [ -f "$path" ]; then
        cat "$path"
    else
        printf '\n'
    fi
}
assert_no_billing_rehearsal_call() {
    local calls
    calls="$(read_file_or_empty "$TEST_CALL_LOG")"
    assert_not_contains "$calls" "billing_rehearsal|" "default live_e2e_evidence flow should not delegate to staging_billing_rehearsal.sh"
}
assert_runtime_smoke_called() {
    local msg="$1"
    local calls
    calls="$(read_file_or_empty "$TEST_CALL_LOG")"
    assert_contains "$calls" "runtime_smoke|" "$msg"
}
assert_no_runtime_smoke_call() {
    local msg="$1" calls
    calls="$(read_file_or_empty "$TEST_CALL_LOG")"
    assert_not_contains "$calls" "runtime_smoke|" "$msg"
}
assert_billing_opt_in_blocked_case() {
    local label="$1"
    local cli_args="$2"
    local detail_snippet="$3"
    local runtime_expected="$4"
    local runtime_call billing_call run_dir summary_payload logs_payload
    _run_live_e2e_evidence "RUNTIME_SMOKE_MOCK_ECHO_ENV_SECRETS=1" --args "$cli_args"
    runtime_call="$(grep '^runtime_smoke|' "$TEST_CALL_LOG" | head -1 || true)"
    billing_call="$(grep '^billing_rehearsal|' "$TEST_CALL_LOG" | head -1 || true)"
    run_dir="$(find_run_artifact_dir "$TEST_WORKSPACE/artifacts")"; summary_payload="$(read_file_or_empty "$run_dir/summary.json")"; logs_payload="$(cat "$run_dir"/logs/* 2>/dev/null || true)"
    assert_eq "$RUN_EXIT_CODE" "0" "$label should exit 0 with blocked credentialed result"
    assert_valid_json "$RUN_STDOUT" "$label should emit valid JSON"
    assert_eq "$(json_field "$RUN_STDOUT" "overall_verdict")" "blocked" "$label should set overall_verdict=blocked"
    assert_eq "$(json_credentialed_check_field "$RUN_STDOUT" "billing_rehearsal" "status")" "blocked" "$label should record status=blocked in credentialed_checks"
    assert_eq "$(json_credentialed_check_field "$RUN_STDOUT" "billing_rehearsal" "exit_code")" "0" "$label should keep blocked credentialed row exit_code machine-readable"; assert_eq "$(json_credentialed_check_field "$RUN_STDOUT" "billing_rehearsal" "artifact_path")" "" "$label should keep blocked credentialed row artifact_path machine-readable"
    assert_contains "$(json_credentialed_check_field "$RUN_STDOUT" "billing_rehearsal" "detail")" "missing credentialed billing proof:" "$label should call out missing credentialed proof explicitly"
    assert_contains "$(json_credentialed_check_field "$RUN_STDOUT" "billing_rehearsal" "detail")" "$detail_snippet" "$label should include expected blocked detail"
    assert_eq "$(json_field "$summary_payload" "overall_verdict")" "blocked" "$label should keep summary.json overall_verdict blocked"; assert_eq "$(json_credentialed_check_field "$summary_payload" "billing_rehearsal" "status")" "blocked" "$label should keep summary.json credentialed_checks blocked"
    if [ "$runtime_expected" = "yes" ]; then
        if [ -n "$runtime_call" ]; then
            pass "$label should keep runtime-smoke execution unchanged"
        else
            fail "$label should keep runtime-smoke execution unchanged"
        fi
        assert_eq "$(json_check_field "$RUN_STDOUT" "runtime_smoke" "status")" "pass" "$label should keep successful local/mock checks lane from upgrading blocked credentialed lane"; assert_not_contains "$RUN_STDOUT$summary_payload$logs_payload" "test-live-e2e-secret" "$label should redact AWS secret values across stdout/summary/logs"; assert_not_contains "$RUN_STDOUT$summary_payload$logs_payload" "test-cloudflare-token" "$label should redact Cloudflare secret values across stdout/summary/logs"
    else
        if [ -z "$runtime_call" ]; then
            pass "$label should keep runtime-smoke skip behavior unchanged"
        else
            fail "$label should keep runtime-smoke skip behavior unchanged"
        fi
    fi
    if [ -z "$billing_call" ]; then
        pass "$label should not invoke billing owner"
    else
        fail "$label should not invoke billing owner"
    fi
}
assert_nonzero_exit() {
    local actual="$1" msg="$2"
    if [ "$actual" -ne 0 ]; then
        pass "$msg"
    else
        fail "$msg (expected nonzero exit code, actual=$actual)"
    fi
}
assert_stdout_not_json() {
    local payload="$1" msg="$2"
    if [ -z "$payload" ]; then
        pass "$msg"
        return
    fi
    if python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<< "$payload" >/dev/null 2>&1; then
        fail "$msg (stdout unexpectedly contained JSON)"
    else
        pass "$msg"
    fi
}
script_line_count() {
    wc -l < "$1" | tr -d ' '
}
helper_function_limit_violations() {
    python3 - "$1" <<'PY'
import pathlib
import re
import sys
path = pathlib.Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()
start_re = re.compile(r"^([a-zA-Z_][a-zA-Z0-9_]*)\(\)\s*\{\s*$")
results = []
for idx, line in enumerate(lines):
    m = start_re.match(line)
    if not m:
        continue
    name = m.group(1)
    if name.startswith("test_") or name == "run_all_tests":
        continue
    brace_balance = 0
    end_idx = None
    for j in range(idx, len(lines)):
        brace_balance += lines[j].count("{")
        brace_balance -= lines[j].count("}")
        if brace_balance == 0:
            end_idx = j
            break
    if end_idx is None:
        continue
    line_count = end_idx - idx + 1
    if line_count > 100:
        results.append(f"{name}:{line_count}")
print("\n".join(results))
PY
}
assert_line_count_lte() {
    local measured="$1" max_allowed="$2" msg="$3"
    if [ -z "$measured" ]; then
        fail "$msg (line count not found)"
        return
    fi
    if [ "$measured" -le "$max_allowed" ]; then
        pass "$msg"
    else
        fail "$msg (max=$max_allowed actual=$measured)"
    fi
}
test_script_exists_and_executable() {
    local exists="no"
    local executable="no"
    [ -f "$LIVE_E2E_SCRIPT" ] && exists="yes"
    [ -x "$LIVE_E2E_SCRIPT" ] && executable="yes"
    assert_eq "$exists" "yes" "live_e2e_evidence.sh should exist"
    assert_eq "$executable" "yes" "live_e2e_evidence.sh should be executable"
}
test_help_exits_zero_without_creating_artifacts() {
    require_live_e2e_script_for_contract "help contract" || return 0
    setup_workspace
    _run_live_e2e_evidence --args "--help --artifact-dir $TEST_WORKSPACE/artifacts"
    assert_eq "$RUN_EXIT_CODE" "0" "--help should exit 0"
    assert_contains "$(printf '%s\n%s' "$RUN_STDOUT" "$RUN_STDERR")" "Usage:" "--help should print usage text"
    assert_eq "$(run_artifact_dir_count "$TEST_WORKSPACE/artifacts")" "0" "--help should not create run artifact directories"
}
test_cli_missing_env_exits_2_without_stdout_json() {
    require_live_e2e_script_for_contract "missing --env CLI contract" || return 0
    setup_workspace
    _run_live_e2e_evidence --args "--domain api.flapjack.foo --artifact-dir $TEST_WORKSPACE/artifacts"
    assert_eq "$RUN_EXIT_CODE" "2" "missing --env should exit 2"
    assert_contains "$RUN_STDERR" "--env" "missing --env should name required flag"
    assert_contains "$RUN_STDERR" "Usage:" "missing --env should print usage"
    assert_stdout_not_json "$RUN_STDOUT" "missing --env should not emit stdout JSON"
}
test_cli_invalid_env_value_exits_2_without_stdout_json() {
    require_live_e2e_script_for_contract "invalid --env CLI contract" || return 0
    setup_workspace
    _run_live_e2e_evidence --args "--env qa --domain api.flapjack.foo --artifact-dir $TEST_WORKSPACE/artifacts"
    assert_eq "$RUN_EXIT_CODE" "2" "invalid --env value should exit 2"
    assert_contains "$RUN_STDERR" "--env" "invalid --env value should name required flag"
    assert_contains "$RUN_STDERR" "staging|prod" "invalid --env value should show supported values"
    assert_contains "$RUN_STDERR" "Usage:" "invalid --env value should print usage"
    assert_stdout_not_json "$RUN_STDOUT" "invalid --env value should not emit stdout JSON"
}
test_cli_missing_domain_exits_2_without_stdout_json() {
    require_live_e2e_script_for_contract "missing --domain CLI contract" || return 0
    setup_workspace
    _run_live_e2e_evidence --args "--env staging --artifact-dir $TEST_WORKSPACE/artifacts"
    assert_eq "$RUN_EXIT_CODE" "2" "missing --domain should exit 2"
    assert_contains "$RUN_STDERR" "--domain" "missing --domain should name required flag"
    assert_contains "$RUN_STDERR" "Usage:" "missing --domain should print usage"
    assert_stdout_not_json "$RUN_STDOUT" "missing --domain should not emit stdout JSON"
}
test_cli_missing_artifact_dir_exits_2_without_stdout_json() {
    require_live_e2e_script_for_contract "missing --artifact-dir CLI contract" || return 0
    setup_workspace
    _run_live_e2e_evidence --args "--env staging --domain api.flapjack.foo"
    assert_eq "$RUN_EXIT_CODE" "2" "missing --artifact-dir should exit 2"
    assert_contains "$RUN_STDERR" "--artifact-dir" "missing --artifact-dir should name required flag"
    assert_contains "$RUN_STDERR" "Usage:" "missing --artifact-dir should print usage"
    assert_stdout_not_json "$RUN_STDOUT" "missing --artifact-dir should not emit stdout JSON"
}
test_cli_unknown_argument_exits_2_without_stdout_json() {
    require_live_e2e_script_for_contract "unknown-argument CLI contract" || return 0
    setup_workspace
    _run_live_e2e_evidence --args "--env staging --domain api.flapjack.foo --artifact-dir $TEST_WORKSPACE/artifacts --unknown-flag"
    assert_eq "$RUN_EXIT_CODE" "2" "unknown argument should exit 2"
    assert_contains "$RUN_STDERR" "Unknown argument" "unknown argument should print explicit error"
    assert_contains "$RUN_STDERR" "Usage:" "unknown argument should print usage"
    assert_stdout_not_json "$RUN_STDOUT" "unknown argument should not emit stdout JSON"
}
test_missing_env_file_and_ami_returns_blocked_json() {
    require_live_e2e_script_for_contract "blocked prerequisites contract" || return 0
    setup_workspace
    _run_live_e2e_evidence --args "--env staging --domain api.flapjack.foo --artifact-dir $TEST_WORKSPACE/artifacts"
    local blocker_details
    blocker_details="$(python3 - "$RUN_STDOUT" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
for row in payload.get("external_blockers", []):
    if isinstance(row, dict):
        print(f"{row.get('blocker','')}|{row.get('owner','')}|{row.get('command','')}")
PY
2>/dev/null || true)"
    assert_eq "$RUN_EXIT_CODE" "0" "missing env-file and ami should exit 0 with blocked summary"
    assert_valid_json "$RUN_STDOUT" "blocked prerequisites run should emit valid JSON"
    assert_eq "$RUN_STDERR" "" "blocked prerequisites run should keep stderr empty"
    assert_eq "$(json_field "$RUN_STDOUT" "overall_verdict")" "blocked" "missing live prerequisites should set overall_verdict=blocked"
    assert_contains "$blocker_details" "--env-file" "blocked prerequisites should include --env-file remediation"
    assert_contains "$blocker_details" "--ami-id" "blocked prerequisites should include --ami-id remediation"
    assert_no_runtime_smoke_call "blocked prerequisites should not delegate to runtime-smoke owner"
}
test_json_schema_contract_for_top_level_checks_and_blockers() {
    require_live_e2e_script_for_contract "JSON schema contract" || return 0
    setup_workspace
    _run_live_e2e_evidence --args "--env staging --domain api.flapjack.foo --artifact-dir $TEST_WORKSPACE/artifacts"
    local schema_ok="no"
    if python3 - "$RUN_STDOUT" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
required = [
    "run_id",
    "started_at",
    "env",
    "domain",
    "artifact_dir",
    "overall_verdict",
    "checks",
    "credentialed_checks",
    "external_blockers",
]
assert all(key in payload for key in required)
assert isinstance(payload["checks"], list)
assert isinstance(payload["credentialed_checks"], list)
assert isinstance(payload["external_blockers"], list)
for lane in ("checks", "credentialed_checks"):
    for row in payload[lane]:
        assert isinstance(row, dict)
        assert all(k in row for k in ["name", "status", "exit_code", "detail", "artifact_path"])
for row in payload["external_blockers"]:
    assert isinstance(row, dict)
    assert all(k in row for k in ["blocker", "owner", "command"])
PY
    then
        schema_ok="yes"
    fi
    assert_eq "$schema_ok" "yes" "stdout JSON should satisfy top-level/checks/blockers schema contract"
}
test_runtime_smoke_pass_normalizes_to_pass_verdict() {
    require_live_e2e_script_for_contract "runtime smoke pass normalization contract" || return 0
    setup_workspace
    _run_live_e2e_evidence --args "--env staging --domain api.flapjack.foo --artifact-dir $TEST_WORKSPACE/artifacts --env-file $TEST_WORKSPACE/inputs/live_e2e.explicit.env --ami-id ami-0123456789abcdef0"
    assert_eq "$RUN_EXIT_CODE" "0" "runtime smoke pass should exit 0"
    assert_valid_json "$RUN_STDOUT" "runtime smoke pass should emit valid JSON"
    assert_eq "$(json_field "$RUN_STDOUT" "overall_verdict")" "pass" "runtime smoke pass should set overall_verdict=pass"
    assert_eq "$(json_check_field "$RUN_STDOUT" "runtime_smoke" "status")" "pass" "runtime_smoke check should report status=pass"
    assert_eq "$(json_check_field "$RUN_STDOUT" "runtime_smoke" "exit_code")" "0" "runtime_smoke check should preserve owner exit_code=0"
}
test_runtime_smoke_failure_normalizes_to_fail_verdict() {
    require_live_e2e_script_for_contract "runtime smoke failure normalization contract" || return 0
    setup_workspace
    local env_file domain expected_command expected_command_json raw_command_json
    env_file="$TEST_WORKSPACE/inputs/runtime_\$(touch_should_not_run).env"
    cp "$TEST_WORKSPACE/inputs/live_e2e.explicit.env" "$env_file"
    domain='api.flapjack.foo$(touch_should_not_run)'
    _run_live_e2e_evidence \
        --args "--env staging --domain $domain --artifact-dir $TEST_WORKSPACE/artifacts --env-file $env_file --ami-id ami-0123456789abcdef0" \
        "RUNTIME_SMOKE_MOCK_EXIT_CODE=23" \
        "RUNTIME_SMOKE_MOCK_STDERR=runtime-smoke-mock-failure"
    expected_command="$(printf '%s %s %s %s %s %s %s %s %s' "$(shell_quote_for_script "$TEST_WORKSPACE/ops/terraform/tests_stage7_runtime_smoke.sh")" --env staging --domain "$(shell_quote_for_script "$domain")" --env-file "$(shell_quote_for_script "$env_file")" --ami-id ami-0123456789abcdef0)"
    expected_command_json="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$expected_command")"
    raw_command_json="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$TEST_WORKSPACE/ops/terraform/tests_stage7_runtime_smoke.sh --env staging --domain $domain --env-file $env_file --ami-id ami-0123456789abcdef0")"
    assert_nonzero_exit "$RUN_EXIT_CODE" "runtime smoke failure should exit nonzero"
    assert_valid_json "$RUN_STDOUT" "runtime smoke failure should still emit valid JSON"
    assert_eq "$(json_field "$RUN_STDOUT" "overall_verdict")" "fail" "runtime smoke failure should set overall_verdict=fail"
    assert_eq "$(json_check_field "$RUN_STDOUT" "runtime_smoke" "status")" "fail" "runtime_smoke check should report status=fail"
    assert_eq "$(json_check_field "$RUN_STDOUT" "runtime_smoke" "exit_code")" "23" "runtime_smoke check should preserve owner exit code"
    assert_contains "$RUN_STDOUT" "$expected_command_json" "runtime smoke failure should shell-escape blocker rerun commands before writing JSON"
    assert_not_contains "$RUN_STDOUT" "$raw_command_json" "runtime smoke failure should not write raw user-controlled blocker commands into JSON"
}
test_artifact_layout_and_summary_match_stdout_json() {
    require_live_e2e_script_for_contract "artifact layout contract" || return 0
    setup_workspace
    local run_dir run_count run_base logs_count summary_matches_stdout="no" private_modes_ok="no"
    local original_umask
    original_umask="$(umask)"
    umask 022
    _run_live_e2e_evidence --args "--env staging --domain api.flapjack.foo --artifact-dir $TEST_WORKSPACE/artifacts --env-file $TEST_WORKSPACE/inputs/live_e2e.explicit.env --ami-id ami-0123456789abcdef0"
    umask "$original_umask"
    run_dir="$(find_run_artifact_dir "$TEST_WORKSPACE/artifacts")"
    run_count="$(run_artifact_dir_count "$TEST_WORKSPACE/artifacts")"
    run_base="$(basename "$run_dir" 2>/dev/null || true)"
    logs_count="$(find "$run_dir/logs" -mindepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
    if python3 - "$RUN_STDOUT" "$run_dir/summary.json" <<'PY'
import json
import pathlib
import sys
stdout_obj = json.loads(sys.argv[1])
summary_obj = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
assert stdout_obj == summary_obj
PY
    then
        summary_matches_stdout="yes"
    fi
    if python3 - "$run_dir" <<'PY'
import pathlib
import stat
import sys
run_dir = pathlib.Path(sys.argv[1])
paths = [run_dir, run_dir / "logs", run_dir / "summary.json"]
paths.extend((run_dir / "logs").glob("*"))
for path in paths:
    mode = stat.S_IMODE(path.stat().st_mode)
    assert mode & 0o077 == 0, f"{path} mode {oct(mode)} exposes group/other bits"
PY
    then
        private_modes_ok="yes"
    fi
    assert_eq "$RUN_EXIT_CODE" "0" "successful contract run should exit 0"
    assert_eq "$run_count" "1" "wrapper should create exactly one run-scoped artifact directory"
    if [[ "$run_base" =~ ^fjcloud_live_e2e_evidence_[0-9]{8}T[0-9]{6}Z_[0-9]+$ ]]; then
        pass "artifact directory should match deterministic naming convention"
    else
        fail "artifact directory should match deterministic naming convention (actual='$run_base')"
    fi
    assert_valid_json "$(read_file_or_empty "$run_dir/summary.json")" "summary.json should be machine-readable JSON"
    assert_eq "$summary_matches_stdout" "yes" "summary.json should match stdout JSON exactly"
    assert_eq "$private_modes_ok" "yes" "run artifacts should be private to the current user even under permissive umask"
    if [ "$logs_count" -ge 1 ]; then
        pass "delegated owner logs should be stored under logs/"
    else
        fail "delegated owner logs should be stored under logs/ (found $logs_count files)"
    fi
}
test_artifact_dir_rejects_existing_file_without_partial_run_directory() {
    require_live_e2e_script_for_contract "artifact-dir existing-file contract" || return 0
    setup_workspace
    local artifact_file parent_dir
    artifact_file="$TEST_WORKSPACE/inputs/not_a_directory_path"
    parent_dir="$(dirname "$artifact_file")"
    printf '%s\n' 'file path sentinel' > "$artifact_file"
    _run_live_e2e_evidence --args "--env staging --domain api.flapjack.foo --artifact-dir $artifact_file --env-file $TEST_WORKSPACE/inputs/live_e2e.explicit.env --ami-id ami-0123456789abcdef0"
    assert_nonzero_exit "$RUN_EXIT_CODE" "artifact-dir file path should fail nonzero"
    assert_eq "$(run_artifact_dir_count "$parent_dir")" "0" "artifact-dir file path should not leave partial run-scoped directories"
}
test_default_run_is_non_mutating_and_never_calls_billing_rehearsal() {
    require_live_e2e_script_for_contract "non-mutating default contract" || return 0
    setup_workspace
    _run_live_e2e_evidence --args "--env staging --domain api.flapjack.foo --artifact-dir $TEST_WORKSPACE/artifacts --env-file $TEST_WORKSPACE/inputs/live_e2e.explicit.env --ami-id ami-0123456789abcdef0"
    local runtime_call
    runtime_call="$(grep '^runtime_smoke|' "$TEST_CALL_LOG" | head -1 || true)"
    if [ -n "$runtime_call" ]; then
        pass "default run should invoke runtime-smoke owner"
    else
        fail "default run should invoke runtime-smoke owner"
    fi
    assert_not_contains "$runtime_call" "--apply" "default run should not forward --apply"
    assert_not_contains "$runtime_call" "--run-deploy" "default run should not forward --run-deploy"
    assert_not_contains "$runtime_call" "--run-migrate" "default run should not forward --run-migrate"
    assert_not_contains "$runtime_call" "--run-rollback" "default run should not forward --run-rollback"
    assert_eq "$(json_credentialed_check_field "$RUN_STDOUT" "billing_rehearsal" "status")" "" "default run should keep credentialed_checks empty"
    assert_no_billing_rehearsal_call
}
test_run_billing_rehearsal_without_env_file_is_blocked_without_owner_call() {
    require_live_e2e_script_for_contract "billing opt-in matrix without env-file" || return 0
    setup_workspace
    assert_billing_opt_in_blocked_case \
        "billing opt-in without env-file" \
        "--env staging --domain api.flapjack.foo --artifact-dir $TEST_WORKSPACE/artifacts --ami-id ami-0123456789abcdef0 --run-billing-rehearsal --month 2026-03 --confirm-live-mutation" \
        "--env-file is required" \
        "no"
}
test_run_billing_rehearsal_without_month_is_blocked_without_owner_call() {
    require_live_e2e_script_for_contract "billing opt-in matrix without month" || return 0
    setup_workspace
    assert_billing_opt_in_blocked_case \
        "billing opt-in without month" \
        "--env staging --domain api.flapjack.foo --artifact-dir $TEST_WORKSPACE/artifacts --env-file $TEST_WORKSPACE/inputs/live_e2e.explicit.env --ami-id ami-0123456789abcdef0 --run-billing-rehearsal --confirm-live-mutation" \
        "--month is required" \
        "yes"
}
test_run_billing_rehearsal_without_confirm_is_blocked_without_owner_call() {
    require_live_e2e_script_for_contract "billing opt-in matrix without confirm-live-mutation" || return 0
    setup_workspace
    assert_billing_opt_in_blocked_case \
        "billing opt-in without confirm-live-mutation" \
        "--env staging --domain api.flapjack.foo --artifact-dir $TEST_WORKSPACE/artifacts --env-file $TEST_WORKSPACE/inputs/live_e2e.explicit.env --ami-id ami-0123456789abcdef0 --run-billing-rehearsal --month 2026-03" \
        "--confirm-live-mutation is required" \
        "yes"
}
test_billing_delegation_boundary_forwards_owner_args_only() {
    require_live_e2e_script_for_contract "delegation-boundary contract" || return 0
    setup_workspace
    local env_file
    env_file="$TEST_WORKSPACE/inputs/live_e2e.explicit.env"
    _run_live_e2e_evidence --args "--env staging --domain api.flapjack.foo --artifact-dir $TEST_WORKSPACE/artifacts --env-file $env_file --ami-id ami-0123456789abcdef0 --run-deploy --run-migrate --run-billing-rehearsal --month 2026-03 --confirm-live-mutation"
    local runtime_call billing_call
    runtime_call="$(grep '^runtime_smoke|' "$TEST_CALL_LOG" | head -1 || true)"
    billing_call="$(grep '^billing_rehearsal|' "$TEST_CALL_LOG" | head -1 || true)"
    if [ -n "$runtime_call" ]; then
        pass "delegation boundary test should capture runtime-smoke owner invocation"
    else
        fail "delegation boundary test should capture runtime-smoke owner invocation"
    fi
    if [ -n "$billing_call" ]; then
        pass "delegation boundary test should capture billing owner invocation"
    else
        fail "delegation boundary test should capture billing owner invocation"
    fi
    assert_contains "$runtime_call" "--env staging" "runtime smoke should receive --env unchanged"
    assert_contains "$runtime_call" "--domain api.flapjack.foo" "runtime smoke should receive --domain unchanged"
    assert_contains "$runtime_call" "--env-file $env_file" "runtime smoke should receive --env-file unchanged"
    assert_contains "$runtime_call" "--ami-id ami-0123456789abcdef0" "runtime smoke should receive --ami-id unchanged"
    assert_contains "$runtime_call" "--run-deploy" "runtime smoke should receive wrapper runtime flags"
    assert_contains "$runtime_call" "--run-migrate" "runtime smoke should receive wrapper runtime flags"
    assert_not_contains "$runtime_call" "--artifact-dir" "runtime smoke should not receive wrapper-only --artifact-dir"
    assert_not_contains "$runtime_call" "$TEST_WORKSPACE/artifacts" "runtime smoke should not receive wrapper artifact directory path"
    assert_contains "$billing_call" "--env-file $env_file" "billing owner should receive --env-file unchanged"
    assert_contains "$billing_call" "--month 2026-03" "billing owner should receive --month unchanged"
    assert_contains "$billing_call" "--confirm-live-mutation" "billing owner should receive --confirm-live-mutation unchanged"
    assert_not_contains "$billing_call" "--artifact-dir" "billing owner should not receive wrapper-only --artifact-dir"
    assert_not_contains "$billing_call" "--env staging" "billing owner should not receive runtime env flag"
    assert_not_contains "$billing_call" "--domain api.flapjack.foo" "billing owner should not receive runtime domain flag"
    assert_not_contains "$billing_call" "--ami-id" "billing owner should not receive runtime smoke AMI flag"
    assert_not_contains "$billing_call" "--run-deploy" "billing owner should not receive runtime flags"
    assert_not_contains "$billing_call" "--run-migrate" "billing owner should not receive runtime flags"
}
test_secret_redaction_in_stdout_summary_and_logs() {
    require_live_e2e_script_for_contract "secret-redaction contract" || return 0
    setup_workspace
    local env_file run_dir summary_payload logs_payload argv_payload python_argv_log
    env_file="$TEST_WORKSPACE/inputs/live_e2e.secrets.env"
    python_argv_log="$TEST_WORKSPACE/tmp/python3_argv.log"
    cat > "$TEST_WORKSPACE/bin/python3" <<'PYTHON3_WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${PYTHON3_ARGV_LOG_PATH:?}"
exec /usr/bin/python3 "$@"
PYTHON3_WRAPPER
    chmod +x "$TEST_WORKSPACE/bin/python3"
    _run_live_e2e_evidence \
        "PYTHON3_ARGV_LOG_PATH=$python_argv_log" \
        --args "--env staging --domain api.flapjack.foo --artifact-dir $TEST_WORKSPACE/artifacts --env-file $env_file --ami-id ami-0123456789abcdef0 --run-billing-rehearsal --month 2026-03 --confirm-live-mutation" \
        "RUNTIME_SMOKE_MOCK_STDOUT=runtime-owner-stdout super-secret-contract-value cf-secret-contract-value" \
        "RUNTIME_SMOKE_MOCK_STDERR=runtime-owner-stderr super-secret-contract-value cf-secret-contract-value" \
        "BILLING_REHEARSAL_MOCK_STDOUT=billing-owner-stdout stripe-live-secret-contract-value stripe-test-secret-contract-value" \
        "BILLING_REHEARSAL_MOCK_STDERR=billing-owner-stderr stripe-webhook-secret-contract-value" \
        "RUNTIME_SMOKE_MOCK_ECHO_ENV_SECRETS=1"
    run_dir="$(find_run_artifact_dir "$TEST_WORKSPACE/artifacts")"
    summary_payload="$(read_file_or_empty "$run_dir/summary.json")"
    logs_payload="$(cat "$run_dir"/logs/* 2>/dev/null || true)"
    argv_payload="$(read_file_or_empty "$python_argv_log")"
    assert_valid_json "$RUN_STDOUT" "secret-redaction run should emit valid stdout JSON"
    assert_not_contains "$RUN_STDOUT" "super-secret-contract-value" "stdout JSON should redact AWS secret value"
    assert_not_contains "$RUN_STDOUT" "cf-secret-contract-value" "stdout JSON should redact Cloudflare secret value"
    assert_contains "$RUN_STDOUT" "REDACTED" "stdout JSON should include stable redaction marker"
    assert_not_contains "$summary_payload" "super-secret-contract-value" "summary.json should redact AWS secret value"
    assert_not_contains "$summary_payload" "cf-secret-contract-value" "summary.json should redact Cloudflare secret value"
    assert_contains "$summary_payload" "REDACTED" "summary.json should include stable redaction marker"
    assert_not_contains "$logs_payload" "super-secret-contract-value" "delegated logs should redact AWS secret value"
    assert_not_contains "$logs_payload" "cf-secret-contract-value" "delegated logs should redact Cloudflare secret value"
    assert_not_contains "$logs_payload" "stripe-live-secret-contract-value" "delegated logs should redact Stripe secret value"
    assert_not_contains "$logs_payload" "stripe-test-secret-contract-value" "delegated logs should redact Stripe test secret value"
    assert_not_contains "$logs_payload" "stripe-webhook-secret-contract-value" "delegated logs should redact Stripe webhook secret value"
    assert_contains "$logs_payload" "REDACTED" "delegated logs should include stable redaction marker"
    assert_not_contains "$argv_payload" "super-secret-contract-value" "python argv should not contain AWS secret value during redaction"
    assert_not_contains "$argv_payload" "cf-secret-contract-value" "python argv should not contain Cloudflare secret value during redaction"
}
test_billing_owner_execution_normalizes_rows_and_logs() {
    require_live_e2e_script_for_contract "executed-owner normalization contract" || return 0
    local run_dir logs_payload
    setup_workspace
    _run_live_e2e_evidence \
        --args "--env staging --domain api.flapjack.foo --artifact-dir $TEST_WORKSPACE/artifacts --env-file $TEST_WORKSPACE/inputs/live_e2e.explicit.env --ami-id ami-0123456789abcdef0 --run-billing-rehearsal --month 2026-03 --confirm-live-mutation" \
        "BILLING_REHEARSAL_MOCK_STDOUT=billing-owner-stdout-success" \
        "BILLING_REHEARSAL_MOCK_STDERR=billing-owner-stderr-success"
    run_dir="$(find_run_artifact_dir "$TEST_WORKSPACE/artifacts")"
    logs_payload="$(cat "$run_dir"/logs/* 2>/dev/null || true)"
    assert_eq "$RUN_EXIT_CODE" "0" "billing owner success should exit 0"
    assert_valid_json "$RUN_STDOUT" "billing owner success should emit valid JSON"
    assert_eq "$(json_field "$RUN_STDOUT" "overall_verdict")" "pass" "billing owner success should keep overall_verdict=pass"
    assert_eq "$(json_credentialed_check_field "$RUN_STDOUT" "billing_rehearsal" "status")" "pass" "credentialed lane should normalize billing success to status=pass"
    assert_eq "$(json_credentialed_check_field "$RUN_STDOUT" "billing_rehearsal" "exit_code")" "0" "credentialed lane should preserve billing owner exit_code=0"
    assert_not_contains "$RUN_STDOUT" "billing-owner-stderr-success" "billing owner stderr should not leak to stdout JSON"
    assert_eq "$RUN_STDERR" "" "billing owner stderr should not leak to wrapper stderr"
    assert_contains "$logs_payload" "billing-owner-stdout-success" "billing owner success stdout should be captured in delegated logs"
    assert_contains "$logs_payload" "billing-owner-stderr-success" "billing owner success stderr should be captured in delegated logs"
    if python3 - "$RUN_STDOUT" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
required = {"name", "status", "exit_code", "detail", "artifact_path"}
for lane in ("checks", "credentialed_checks"):
    for row in payload.get(lane, []):
        assert isinstance(row, dict)
        assert required.issubset(set(row.keys()))
PY
    then
        pass "credentialed_checks should use canonical check-row fields"
    else
        fail "credentialed_checks should use canonical check-row fields"
    fi
    setup_workspace
    _run_live_e2e_evidence \
        --args "--env staging --domain api.flapjack.foo --artifact-dir $TEST_WORKSPACE/artifacts --env-file $TEST_WORKSPACE/inputs/live_e2e.explicit.env --ami-id ami-0123456789abcdef0 --run-billing-rehearsal --month 2026-03 --confirm-live-mutation" \
        "BILLING_REHEARSAL_MOCK_EXIT_CODE=41" \
        "BILLING_REHEARSAL_MOCK_STDERR=billing-owner-stderr-failure"
    run_dir="$(find_run_artifact_dir "$TEST_WORKSPACE/artifacts")"
    logs_payload="$(cat "$run_dir"/logs/* 2>/dev/null || true)"
    assert_nonzero_exit "$RUN_EXIT_CODE" "billing owner failure should exit nonzero"
    assert_valid_json "$RUN_STDOUT" "billing owner failure should emit valid JSON"
    assert_eq "$(json_field "$RUN_STDOUT" "overall_verdict")" "fail" "billing owner failure should normalize to overall_verdict=fail"
    assert_eq "$(json_credentialed_check_field "$RUN_STDOUT" "billing_rehearsal" "status")" "fail" "credentialed lane should normalize billing failure to status=fail"
    assert_eq "$(json_credentialed_check_field "$RUN_STDOUT" "billing_rehearsal" "exit_code")" "41" "credentialed lane should preserve billing owner failure exit code"
    assert_not_contains "$RUN_STDOUT" "billing-owner-stderr-failure" "billing owner stderr should not leak to stdout JSON on failure"
    assert_eq "$RUN_STDERR" "" "billing owner stderr should not leak to wrapper stderr on failure"
    assert_contains "$logs_payload" "billing-owner-stderr-failure" "billing owner failure stderr should be captured in delegated logs"
}
test_live_e2e_contract_test_file_stays_under_hard_limits() {
    local test_file helper_overages
    test_file="$REPO_ROOT/scripts/tests/live_e2e_evidence_test.sh"
    helper_overages="$(helper_function_limit_violations "$test_file")"
    assert_line_count_lte "$(script_line_count "$test_file")" "800" \
        "live_e2e_evidence_test.sh should stay at or below the 800-line hard limit"
    if [ -z "$helper_overages" ]; then
        pass "shell helper functions should stay at or below the 100-line hard limit"
    else
        fail "shell helper functions should stay at or below the 100-line hard limit (overages: $helper_overages)"
    fi
}
run_all_tests() {
    echo "=== live_e2e_evidence.sh contract tests ==="
    test_script_exists_and_executable
    test_help_exits_zero_without_creating_artifacts
    test_cli_missing_env_exits_2_without_stdout_json
    test_cli_invalid_env_value_exits_2_without_stdout_json
    test_cli_missing_domain_exits_2_without_stdout_json
    test_cli_missing_artifact_dir_exits_2_without_stdout_json
    test_cli_unknown_argument_exits_2_without_stdout_json
    test_missing_env_file_and_ami_returns_blocked_json
    test_json_schema_contract_for_top_level_checks_and_blockers
    test_runtime_smoke_pass_normalizes_to_pass_verdict
    test_runtime_smoke_failure_normalizes_to_fail_verdict
    test_artifact_layout_and_summary_match_stdout_json
    test_artifact_dir_rejects_existing_file_without_partial_run_directory
    test_default_run_is_non_mutating_and_never_calls_billing_rehearsal
    test_run_billing_rehearsal_without_env_file_is_blocked_without_owner_call
    test_run_billing_rehearsal_without_month_is_blocked_without_owner_call
    test_run_billing_rehearsal_without_confirm_is_blocked_without_owner_call
    test_billing_delegation_boundary_forwards_owner_args_only
    test_secret_redaction_in_stdout_summary_and_logs
    test_billing_owner_execution_normalizes_rows_and_logs
    test_live_e2e_contract_test_file_stays_under_hard_limits
    run_test_summary
}
run_all_tests
