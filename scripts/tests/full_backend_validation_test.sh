#!/usr/bin/env bash
# Tests for scripts/launch/run_full_backend_validation.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ORCH_SCRIPT="$REPO_ROOT/scripts/launch/run_full_backend_validation.sh"
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
assert_json_field() {
    local json="$1" field="$2" expected="$3" msg="$4"
    local actual
    if ! actual="$(python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('$field'))" <<< "$json" 2>/dev/null)"; then
        fail "$msg (output was not valid JSON)"
        return
    fi
    assert_eq "$actual" "$expected" "$msg"
}
assert_json_bool_field() {
    local json="$1" field="$2" expected="$3" msg="$4"
    local actual
    if ! actual="$(python3 -c "import json,sys; val=json.loads(sys.stdin.read()).get('$field'); print('true' if val is True else ('false' if val is False else ''))" <<< "$json" 2>/dev/null)"; then
        fail "$msg (output was not valid JSON)"
        return
    fi
    assert_eq "$actual" "$expected" "$msg"
}
assert_json_missing_field() {
    local json="$1" field="$2" msg="$3"
    local actual
    if ! actual="$(python3 -c "import json,sys; print('true' if '$field' in json.loads(sys.stdin.read()) else 'false')" <<< "$json" 2>/dev/null)"; then
        fail "$msg (output was not valid JSON)"
        return
    fi
    assert_eq "$actual" "false" "$msg"
}
json_step_status() {
    local json="$1" step_name="$2"
    python3 -c "
import json,sys
data=json.loads(sys.stdin.read())
for step in data.get('steps', []):
    if step.get('name') == '$step_name':
        print(step.get('status', ''))
        break
else:
    print('')
" <<< "$json" 2>/dev/null || echo ""
}
json_step_reason() {
    local json="$1" step_name="$2"
    python3 -c "
import json,sys
data=json.loads(sys.stdin.read())
for step in data.get('steps', []):
    if step.get('name') == '$step_name':
        print(step.get('reason', ''))
        break
else:
    print('')
" <<< "$json" 2>/dev/null || echo ""
}
json_step_count() {
    local json="$1"
    python3 -c "import json,sys; print(len(json.loads(sys.stdin.read()).get('steps', [])))" <<< "$json" 2>/dev/null || echo "0"
}
write_mock_script() {
    local path="$1"
    local body="$2"
    cat > "$path" <<EOF
#!/usr/bin/env bash
$body
EOF
    chmod +x "$path"
}
run_orchestrator() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local stdout_file="$tmp_dir/stdout"
    local stderr_file="$tmp_dir/stderr"
    local exit_code=0
    if "$@" >"$stdout_file" 2>"$stderr_file"; then
        exit_code=0
    else
        exit_code=$?
    fi
    RUN_EXIT_CODE="$exit_code"
    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
    rm -rf "$tmp_dir"
}
function_line_count() {
    local file_path="$1"
    local function_name="$2"
    awk -v name="$function_name" '
        $0 ~ "^" name "[[:space:]]*\\(\\)[[:space:]]*\\{" {
            in_function=1
            start_line=NR
            depth=0
        }
        in_function {
            open_count=gsub(/\{/, "{")
            close_count=gsub(/\}/, "}")
            depth += open_count - close_count
            if (depth == 0) {
                print NR - start_line + 1
                exit
            }
        }
    ' "$file_path"
}
test_run_full_backend_validation_function_size_limit() {
    local line_count
    line_count="$(function_line_count "$ORCH_SCRIPT" "run_full_backend_validation")"
    if [ -z "$line_count" ]; then
        fail "run_full_backend_validation should exist for function-size limit enforcement"
        return
    fi
    if [ "$line_count" -le 100 ]; then
        pass "run_full_backend_validation should stay within 100 lines (actual=$line_count)"
    else
        fail "run_full_backend_validation exceeded 100-line hard limit (actual=$line_count)"
    fi
}
test_orchestrator_help_flag() {
    run_orchestrator bash "$ORCH_SCRIPT" --help
    assert_eq "$RUN_EXIT_CODE" "0" "help flag should exit 0"
    assert_contains "$RUN_STDOUT$RUN_STDERR" "Usage:" "help output should include usage text"
    assert_contains "$RUN_STDOUT$RUN_STDERR" "--paid-beta-rc" "help output should include paid beta RC flag"
    assert_contains "$RUN_STDOUT$RUN_STDERR" "--artifact-dir=<dir>" "help output should include artifact-dir flag"
    assert_contains "$RUN_STDOUT$RUN_STDERR" "--credential-env-file=<path>" "help output should include credential env file flag"
    assert_contains "$RUN_STDOUT$RUN_STDERR" "--billing-month=<YYYY-MM>" "help output should include billing month flag"
    assert_contains "$RUN_STDOUT$RUN_STDERR" "--staging-smoke-ami-id=<ami-id>" "help output should include staging smoke AMI flag"
}
test_orchestrator_dry_run_produces_valid_json() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    write_mock_script "$tmp_dir/mock_cargo.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_backend_gate.sh" 'echo "{\"verdict\":\"pass\"}"; exit 0'
    run_orchestrator env \
        DRY_RUN=1 \
        FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
        FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
        bash "$ORCH_SCRIPT"
    rm -rf "$tmp_dir"
    assert_eq "$RUN_EXIT_CODE" "0" "dry-run orchestrator should exit 0 on pass path"
    assert_eq "$(python3 -m json.tool <<< "$RUN_STDOUT" >/dev/null 2>&1; echo $?)" "0" "dry-run output should be valid JSON"
    assert_json_field "$RUN_STDOUT" "mode" "dry_run" "mode should be dry_run"
    assert_contains "$RUN_STDOUT" "\"verdict\"" "output should include verdict"
    assert_contains "$RUN_STDOUT" "\"timestamp\"" "output should include timestamp"
    assert_contains "$RUN_STDOUT" "\"elapsed_ms\"" "output should include elapsed_ms"
    assert_contains "$RUN_STDOUT" "\"steps\"" "output should include steps"
    assert_json_missing_field "$RUN_STDOUT" "preflight_failures" "dry-run pass path should omit preflight_failures when there are no failures"
}
test_orchestrator_dry_run_sha_cli_pass_path() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    write_mock_script "$tmp_dir/mock_cargo.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_backend_gate.sh" 'echo "{\"verdict\":\"pass\"}"; exit 0'
    run_orchestrator env \
        FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
        FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
        bash "$ORCH_SCRIPT" --dry-run --sha=aabbccddee00112233445566778899aabbccddee
    rm -rf "$tmp_dir"
    assert_eq "$RUN_EXIT_CODE" "0" "dry-run --sha cli pass path should exit 0"
    assert_json_field "$RUN_STDOUT" "mode" "dry_run" "dry-run --sha cli pass path should report dry_run mode"
    assert_json_field "$RUN_STDOUT" "verdict" "pass" "dry-run --sha cli pass path should preserve pass verdict"
    assert_eq "$(json_step_status "$RUN_STDOUT" "cargo_workspace_tests")" "pass" "dry-run --sha cli pass path should keep cargo step behavior"
    assert_eq "$(json_step_status "$RUN_STDOUT" "backend_launch_gate")" "pass" "dry-run --sha cli pass path should keep backend gate step behavior"
}
test_orchestrator_fails_on_cargo_test_failure() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    write_mock_script "$tmp_dir/mock_cargo.sh" 'exit 1'
    write_mock_script "$tmp_dir/mock_backend_gate.sh" 'echo "{\"verdict\":\"pass\"}"; exit 0'
    run_orchestrator env \
        DRY_RUN=1 \
        FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
        FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
        bash "$ORCH_SCRIPT"
    rm -rf "$tmp_dir"
    assert_eq "$RUN_EXIT_CODE" "1" "orchestrator should fail when cargo tests fail"
    assert_json_field "$RUN_STDOUT" "verdict" "fail" "verdict should be fail on cargo test failure"
    assert_eq "$(json_step_status "$RUN_STDOUT" "cargo_workspace_tests")" "fail" "cargo step should be marked fail"
}
test_orchestrator_fails_on_backend_gate_failure() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    write_mock_script "$tmp_dir/mock_cargo.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_backend_gate.sh" 'echo "{\"verdict\":\"fail\",\"reason\":\"backend failed\"}"; exit 1'
    run_orchestrator env \
        DRY_RUN=1 \
        FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
        FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
        bash "$ORCH_SCRIPT"
    rm -rf "$tmp_dir"
    assert_eq "$RUN_EXIT_CODE" "1" "orchestrator should fail when backend gate fails"
    assert_json_field "$RUN_STDOUT" "verdict" "fail" "verdict should be fail on backend gate failure"
    assert_eq "$(json_step_status "$RUN_STDOUT" "backend_launch_gate")" "fail" "backend gate step should be marked fail"
}
test_orchestrator_fails_on_backend_gate_invalid_json() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    write_mock_script "$tmp_dir/mock_cargo.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_backend_gate.sh" 'echo "not-json"; exit 0'
    run_orchestrator env \
        DRY_RUN=1 \
        FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
        FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
        bash "$ORCH_SCRIPT"
    rm -rf "$tmp_dir"
    assert_eq "$RUN_EXIT_CODE" "1" "orchestrator should fail when backend gate output is invalid JSON"
    assert_json_field "$RUN_STDOUT" "verdict" "fail" "verdict should be fail on invalid backend gate JSON"
    assert_eq "$(json_step_status "$RUN_STDOUT" "backend_launch_gate")" "fail" "backend gate step should be marked fail on invalid JSON"
    assert_contains "$(json_step_reason "$RUN_STDOUT" "backend_launch_gate")" "invalid JSON" "backend gate reason should report invalid JSON"
}
test_orchestrator_rejects_invalid_sha_argument() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    write_mock_script "$tmp_dir/mock_cargo.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_backend_gate.sh" 'echo "{\"verdict\":\"pass\"}"; exit 0'
    run_orchestrator env \
        DRY_RUN=1 \
        FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
        FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
        bash "$ORCH_SCRIPT" --dry-run --sha=not-a-valid-sha
    rm -rf "$tmp_dir"
    assert_eq "$RUN_EXIT_CODE" "2" "invalid --sha should fail with usage error"
    assert_contains "$RUN_STDERR" "40-character lowercase hexadecimal" "invalid --sha should mention strict format"
}
test_orchestrator_rejects_invalid_billing_month_argument() {
    run_orchestrator bash "$ORCH_SCRIPT" --billing-month=2026-99
    assert_eq "$RUN_EXIT_CODE" "2" "invalid --billing-month should fail with usage error"
    assert_contains "$RUN_STDERR" "--billing-month must use YYYY-MM format" "invalid --billing-month should mention strict format"
}
test_orchestrator_rejects_invalid_staging_smoke_ami_argument() {
    run_orchestrator bash "$ORCH_SCRIPT" --paid-beta-rc --sha=aabbccddee00112233445566778899aabbccddee --staging-smoke-ami-id=invalid-ami
    assert_eq "$RUN_EXIT_CODE" "2" "invalid --staging-smoke-ami-id should fail with usage error"
    assert_contains "$RUN_STDERR" "--staging-smoke-ami-id must use AMI ID format" "invalid --staging-smoke-ami-id should mention strict format"
}
test_orchestrator_collects_all_results_even_on_failure() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    write_mock_script "$tmp_dir/mock_cargo.sh" 'exit 1'
    write_mock_script "$tmp_dir/mock_backend_gate.sh" 'echo "{\"verdict\":\"pass\"}"; exit 0'
    run_orchestrator env \
        DRY_RUN=1 \
        FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
        FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
        bash "$ORCH_SCRIPT"
    rm -rf "$tmp_dir"
    assert_eq "$RUN_EXIT_CODE" "1" "orchestrator should fail overall when any step fails"
    assert_eq "$(json_step_count "$RUN_STDOUT")" "2" "orchestrator should include both steps even when cargo fails"
    assert_eq "$(json_step_status "$RUN_STDOUT" "cargo_workspace_tests")" "fail" "cargo step should be fail"
    assert_eq "$(json_step_status "$RUN_STDOUT" "backend_launch_gate")" "pass" "backend gate step should still run and be recorded"
}
test_paid_beta_rc_blocks_missing_credentialed_inputs() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    write_mock_script "$tmp_dir/mock_cargo.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_backend_gate.sh" 'echo "{\"verdict\":\"pass\"}"; exit 0'
    write_mock_script "$tmp_dir/mock_local_signoff.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_ses.sh" 'echo "ses should not run" >&2; exit 99'
    write_mock_script "$tmp_dir/mock_billing.sh" 'echo "billing should not run" >&2; exit 99'
    run_orchestrator env \
        SES_FROM_ADDRESS="" \
        SES_REGION="" \
        FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
        FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
        FULL_VALIDATION_LOCAL_SIGNOFF_SCRIPT="$tmp_dir/mock_local_signoff.sh" \
        FULL_VALIDATION_SES_READINESS_SCRIPT="$tmp_dir/mock_ses.sh" \
        FULL_VALIDATION_STAGING_BILLING_REHEARSAL_SCRIPT="$tmp_dir/mock_billing.sh" \
        bash "$ORCH_SCRIPT" --paid-beta-rc --sha=aabbccddee00112233445566778899aabbccddee
    rm -rf "$tmp_dir"
    assert_eq "$RUN_EXIT_CODE" "1" "paid-beta-rc should fail when required credentialed inputs are missing"
    assert_json_field "$RUN_STDOUT" "mode" "paid_beta_rc" "paid-beta-rc output mode should be paid_beta_rc"
    assert_json_bool_field "$RUN_STDOUT" "ready" "false" "paid-beta-rc should report ready=false when required proofs are blocked"
    assert_json_field "$RUN_STDOUT" "verdict" "fail" "paid-beta-rc should preserve fail verdict when blocked"
    assert_eq "$(json_step_status "$RUN_STDOUT" "local_signoff")" "pass" "local_signoff should run and pass when mocked"
    assert_eq "$(json_step_status "$RUN_STDOUT" "ses_readiness")" "blocked" "ses_readiness should be blocked without identity input"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "ses_readiness")" "credentialed_ses_identity_missing" "ses_readiness should report credentialed_ses_identity_missing"
    assert_eq "$(json_step_status "$RUN_STDOUT" "staging_billing_rehearsal")" "blocked" "staging_billing_rehearsal should be blocked without billing inputs"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "staging_billing_rehearsal")" "credentialed_billing_env_file_missing" "staging_billing_rehearsal should report credentialed_billing_env_file_missing"
}
test_paid_beta_rc_blocks_when_billing_month_missing() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local credential_env_file
    credential_env_file="$tmp_dir/credentials.env"
    cat > "$credential_env_file" <<'EOF'
SES_FROM_ADDRESS=beta@example.com
SES_REGION=us-east-1
EOF
    write_mock_script "$tmp_dir/mock_cargo.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_backend_gate.sh" 'echo "{\"verdict\":\"pass\"}"; exit 0'
    write_mock_script "$tmp_dir/mock_local_signoff.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_ses.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_billing.sh" 'echo "billing should not run without month" >&2; exit 99'
    run_orchestrator env \
        FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
        FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
        FULL_VALIDATION_LOCAL_SIGNOFF_SCRIPT="$tmp_dir/mock_local_signoff.sh" \
        FULL_VALIDATION_SES_READINESS_SCRIPT="$tmp_dir/mock_ses.sh" \
        FULL_VALIDATION_STAGING_BILLING_REHEARSAL_SCRIPT="$tmp_dir/mock_billing.sh" \
        bash "$ORCH_SCRIPT" --paid-beta-rc --sha=aabbccddee00112233445566778899aabbccddee --credential-env-file="$credential_env_file"
    rm -rf "$tmp_dir"
    assert_eq "$RUN_EXIT_CODE" "1" "paid-beta-rc should fail when billing month is missing"
    assert_json_bool_field "$RUN_STDOUT" "ready" "false" "paid-beta-rc should report ready=false when billing month is missing"
    assert_json_field "$RUN_STDOUT" "verdict" "fail" "paid-beta-rc should preserve fail verdict when billing month is missing"
    assert_eq "$(json_step_status "$RUN_STDOUT" "ses_readiness")" "pass" "ses_readiness should pass with identity loaded from env file"
    assert_eq "$(json_step_status "$RUN_STDOUT" "staging_billing_rehearsal")" "blocked" "staging_billing_rehearsal should be blocked when month is missing"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "staging_billing_rehearsal")" "credentialed_billing_month_missing" "staging_billing_rehearsal should report credentialed_billing_month_missing"
}
test_paid_beta_rc_blocks_staging_runtime_smoke_without_opt_in_inputs() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local runtime_invocations_file
    runtime_invocations_file="$tmp_dir/runtime_invocations.log"
    write_mock_script "$tmp_dir/mock_cargo.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_backend_gate.sh" 'echo "{\"verdict\":\"pass\"}"; exit 0'
    write_mock_script "$tmp_dir/mock_local_signoff.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_ses.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_billing.sh" 'echo "{\"result\":\"blocked\",\"classification\":\"billing_env_file_missing\"}"; exit 1'
    write_mock_script "$tmp_dir/mock_browser_preflight.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_tf_static_stage7.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_tf_static_stage8.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_runtime_smoke.sh" '
printf "runtime-smoke-invoked %s\n" "$*" >> "${RUNTIME_INVOCATIONS_FILE:?}"
exit 99'
    run_orchestrator env \
        SES_FROM_ADDRESS="beta@example.com" \
        SES_REGION="us-east-1" \
        RUNTIME_INVOCATIONS_FILE="$runtime_invocations_file" \
        FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
        FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
        FULL_VALIDATION_LOCAL_SIGNOFF_SCRIPT="$tmp_dir/mock_local_signoff.sh" \
        FULL_VALIDATION_SES_READINESS_SCRIPT="$tmp_dir/mock_ses.sh" \
        FULL_VALIDATION_STAGING_BILLING_REHEARSAL_SCRIPT="$tmp_dir/mock_billing.sh" \
        FULL_VALIDATION_BROWSER_PREFLIGHT_SCRIPT="$tmp_dir/mock_browser_preflight.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE7_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage7.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE8_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage8.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE7_RUNTIME_SMOKE_SCRIPT="$tmp_dir/mock_runtime_smoke.sh" \
        bash "$ORCH_SCRIPT" --paid-beta-rc --sha=aabbccddee00112233445566778899aabbccddee --billing-month=2026-03 --staging-smoke-ami-id=ami-12345678
    local runtime_invocations
    runtime_invocations="$(cat "$runtime_invocations_file" 2>/dev/null || true)"
    rm -rf "$tmp_dir"
    assert_eq "$RUN_EXIT_CODE" "1" "paid-beta-rc should fail when staging runtime smoke prerequisites are missing"
    assert_json_bool_field "$RUN_STDOUT" "ready" "false" "paid-beta-rc should keep ready=false when staging runtime smoke is blocked"
    assert_json_field "$RUN_STDOUT" "verdict" "fail" "paid-beta-rc should preserve fail verdict when staging runtime smoke is blocked"
    assert_eq "$(json_step_status "$RUN_STDOUT" "staging_runtime_smoke")" "blocked" "staging_runtime_smoke should be blocked when explicit inputs are missing"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "staging_runtime_smoke")" "credentialed_staging_smoke_inputs_missing" "staging_runtime_smoke should report credentialed_staging_smoke_inputs_missing"
    assert_eq "$runtime_invocations" "" "staging_runtime_smoke should not invoke runtime script when explicit inputs are missing"
}
test_paid_beta_rc_propagates_delegated_billing_blocked_state() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local credential_env_file
    credential_env_file="$tmp_dir/credentials.env"
    cat > "$credential_env_file" <<'EOF'
SES_FROM_ADDRESS=beta@example.com
SES_REGION=us-east-1
EOF
    write_mock_script "$tmp_dir/mock_cargo.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_backend_gate.sh" 'echo "{\"verdict\":\"pass\"}"; exit 0'
    write_mock_script "$tmp_dir/mock_local_signoff.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_ses.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_billing.sh" '
echo "{\"result\":\"blocked\",\"classification\":\"repo_default_env_file_rejected\",\"detail\":\"repo default env file was rejected\"}"
exit 1'
    run_orchestrator env \
        FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
        FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
        FULL_VALIDATION_LOCAL_SIGNOFF_SCRIPT="$tmp_dir/mock_local_signoff.sh" \
        FULL_VALIDATION_SES_READINESS_SCRIPT="$tmp_dir/mock_ses.sh" \
        FULL_VALIDATION_STAGING_BILLING_REHEARSAL_SCRIPT="$tmp_dir/mock_billing.sh" \
        bash "$ORCH_SCRIPT" --paid-beta-rc --sha=aabbccddee00112233445566778899aabbccddee \
            --credential-env-file="$credential_env_file" --billing-month=2026-03
    rm -rf "$tmp_dir"
    assert_eq "$RUN_EXIT_CODE" "1" "paid-beta-rc should fail when delegated billing proof returns blocked"
    assert_json_bool_field "$RUN_STDOUT" "ready" "false" "paid-beta-rc should keep ready=false when delegated billing proof is blocked"
    assert_json_field "$RUN_STDOUT" "verdict" "fail" "paid-beta-rc should preserve fail verdict when delegated billing proof is blocked"
    assert_eq "$(json_step_status "$RUN_STDOUT" "local_signoff")" "pass" "local_signoff pass should not mask delegated billing blocked classification"
    assert_eq "$(json_step_status "$RUN_STDOUT" "ses_readiness")" "pass" "ses_readiness pass should not mask delegated billing blocked classification"
    assert_eq "$(json_step_status "$RUN_STDOUT" "staging_billing_rehearsal")" "blocked" "staging_billing_rehearsal should preserve delegated blocked result"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "staging_billing_rehearsal")" "repo_default_env_file_rejected" "staging_billing_rehearsal should preserve delegated blocked classification"
}
test_paid_beta_rc_uses_shell_identity_when_credential_file_missing() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local missing_credential_env_file ses_args_file ses_args
    missing_credential_env_file="$tmp_dir/credentials.env"
    ses_args_file="$tmp_dir/ses_args.txt"
    write_mock_script "$tmp_dir/mock_cargo.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_backend_gate.sh" 'echo "{\"verdict\":\"pass\"}"; exit 0'
    write_mock_script "$tmp_dir/mock_local_signoff.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_ses.sh" '
printf "%s\n" "$*" > "${SES_ARGS_FILE:?}"
exit 0'
    write_mock_script "$tmp_dir/mock_billing.sh" 'echo "billing should remain blocked when env file is missing" >&2; exit 99'
    run_orchestrator env \
        SES_FROM_ADDRESS="shell-beta@example.com" \
        SES_REGION="" \
        SES_ARGS_FILE="$ses_args_file" \
        FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
        FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
        FULL_VALIDATION_LOCAL_SIGNOFF_SCRIPT="$tmp_dir/mock_local_signoff.sh" \
        FULL_VALIDATION_SES_READINESS_SCRIPT="$tmp_dir/mock_ses.sh" \
        FULL_VALIDATION_STAGING_BILLING_REHEARSAL_SCRIPT="$tmp_dir/mock_billing.sh" \
        bash "$ORCH_SCRIPT" --paid-beta-rc --sha=aabbccddee00112233445566778899aabbccddee \
            --credential-env-file="$missing_credential_env_file" --billing-month=2026-03
    ses_args="$(cat "$ses_args_file" 2>/dev/null || true)"
    rm -rf "$tmp_dir"
    assert_eq "$RUN_EXIT_CODE" "1" "paid-beta-rc should still fail overall when billing env file is missing"
    assert_json_bool_field "$RUN_STDOUT" "ready" "false" "paid-beta-rc should remain not ready when billing env file is missing"
    assert_json_field "$RUN_STDOUT" "verdict" "fail" "paid-beta-rc should preserve fail verdict when billing env file is missing"
    assert_eq "$(json_step_status "$RUN_STDOUT" "ses_readiness")" "pass" "ses_readiness should pass with shell-provided identity even when credential env file is missing"
    assert_eq "$(json_step_status "$RUN_STDOUT" "staging_billing_rehearsal")" "blocked" "staging_billing_rehearsal should stay blocked when env file is missing"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "staging_billing_rehearsal")" "credentialed_billing_env_file_missing" "staging_billing_rehearsal should report credentialed_billing_env_file_missing"
    assert_contains "$ses_args" "--identity shell-beta@example.com" "ses_readiness should delegate shell-provided identity"
}
test_paid_beta_rc_pass_path_reports_ready_true() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local credential_env_file artifact_dir invocation_log_file
    credential_env_file="$tmp_dir/credentials.env"
    artifact_dir="$tmp_dir/artifacts"
    invocation_log_file="$tmp_dir/invocations.log"
    cat > "$credential_env_file" <<'EOF'
SES_FROM_ADDRESS=beta@example.com
SES_REGION=us-east-1
EOF
    local ses_args_file billing_args_file staging_smoke_ami_id
    ses_args_file="$tmp_dir/ses_args.txt"
    billing_args_file="$tmp_dir/billing_args.txt"
    staging_smoke_ami_id="ami-12345678"
    mkdir -p "$tmp_dir/bin"
    write_mock_script "$tmp_dir/mock_cargo.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_backend_gate.sh" '
if [ "${LAUNCH_GATE_EVIDENCE_DIR:-}" != "${EXPECTED_ARTIFACT_DIR:-}" ]; then
    echo "unexpected LAUNCH_GATE_EVIDENCE_DIR=${LAUNCH_GATE_EVIDENCE_DIR:-}" >&2
    exit 77
fi
if [ "${COLLECT_EVIDENCE_DIR:-}" != "${EXPECTED_ARTIFACT_DIR:-}" ]; then
    echo "unexpected COLLECT_EVIDENCE_DIR=${COLLECT_EVIDENCE_DIR:-}" >&2
    exit 78
fi
echo "{\"verdict\":\"pass\"}"
exit 0'
    write_mock_script "$tmp_dir/mock_local_signoff.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_ses.sh" '
printf "%s\n" "$*" > "${SES_ARGS_FILE:?}"
exit 0'
    write_mock_script "$tmp_dir/mock_billing.sh" '
printf "%s\n" "$*" > "${BILLING_ARGS_FILE:?}"
exit 0'
    write_mock_script "$tmp_dir/mock_browser_preflight.sh" '
printf "browser_preflight|%s|%s\n" "$PWD" "$*" >> "${INVOCATION_LOG_FILE:?}"
exit 0'
    write_mock_script "$tmp_dir/mock_tf_static_stage7.sh" '
printf "terraform_stage7_static|%s|%s\n" "$PWD" "$*" >> "${INVOCATION_LOG_FILE:?}"
exit 0'
    write_mock_script "$tmp_dir/mock_tf_static_stage8.sh" '
printf "terraform_stage8_static|%s|%s\n" "$PWD" "$*" >> "${INVOCATION_LOG_FILE:?}"
exit 0'
    write_mock_script "$tmp_dir/mock_runtime_smoke.sh" '
printf "staging_runtime_smoke|%s|%s\n" "$PWD" "$*" >> "${INVOCATION_LOG_FILE:?}"
exit 0'
    write_mock_script "$tmp_dir/bin/npx" '
printf "browser_auth_setup|%s|%s\n" "$PWD" "$*" >> "${INVOCATION_LOG_FILE:?}"
exit 0'
    run_orchestrator env \
        SES_FROM_ADDRESS="" \
        SES_REGION="" \
        PATH="$tmp_dir/bin:$PATH" \
        EXPECTED_ARTIFACT_DIR="$artifact_dir" \
        SES_ARGS_FILE="$ses_args_file" \
        BILLING_ARGS_FILE="$billing_args_file" \
        INVOCATION_LOG_FILE="$invocation_log_file" \
        FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
        FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
        FULL_VALIDATION_LOCAL_SIGNOFF_SCRIPT="$tmp_dir/mock_local_signoff.sh" \
        FULL_VALIDATION_SES_READINESS_SCRIPT="$tmp_dir/mock_ses.sh" \
        FULL_VALIDATION_STAGING_BILLING_REHEARSAL_SCRIPT="$tmp_dir/mock_billing.sh" \
        FULL_VALIDATION_BROWSER_PREFLIGHT_SCRIPT="$tmp_dir/mock_browser_preflight.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE7_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage7.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE8_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage8.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE7_RUNTIME_SMOKE_SCRIPT="$tmp_dir/mock_runtime_smoke.sh" \
        bash "$ORCH_SCRIPT" --paid-beta-rc --sha=aabbccddee00112233445566778899aabbccddee \
            --credential-env-file="$credential_env_file" --billing-month=2026-03 --artifact-dir="$artifact_dir" \
            --staging-smoke-ami-id="$staging_smoke_ami_id"
    local ses_args billing_args invocation_log
    ses_args="$(cat "$ses_args_file" 2>/dev/null || true)"
    billing_args="$(cat "$billing_args_file" 2>/dev/null || true)"
    invocation_log="$(cat "$invocation_log_file" 2>/dev/null || true)"
    rm -rf "$tmp_dir"
    assert_eq "$RUN_EXIT_CODE" "0" "paid-beta-rc should exit 0 on full pass path"
    assert_json_field "$RUN_STDOUT" "mode" "paid_beta_rc" "paid-beta-rc output mode should be paid_beta_rc"
    assert_json_bool_field "$RUN_STDOUT" "ready" "true" "paid-beta-rc should report ready=true when all required proofs pass"
    assert_json_field "$RUN_STDOUT" "verdict" "pass" "paid-beta-rc should preserve pass verdict on pass path"
    assert_eq "$(json_step_status "$RUN_STDOUT" "cargo_workspace_tests")" "pass" "cargo step should pass on RC pass path"
    assert_eq "$(json_step_status "$RUN_STDOUT" "backend_launch_gate")" "pass" "backend launch gate should pass on RC pass path"
    assert_eq "$(json_step_status "$RUN_STDOUT" "local_signoff")" "pass" "local_signoff should pass on RC pass path"
    assert_eq "$(json_step_status "$RUN_STDOUT" "ses_readiness")" "pass" "ses_readiness should pass on RC pass path"
    assert_eq "$(json_step_status "$RUN_STDOUT" "staging_billing_rehearsal")" "pass" "staging_billing_rehearsal should pass on RC pass path"
    assert_eq "$(json_step_status "$RUN_STDOUT" "browser_preflight")" "pass" "browser_preflight should pass on RC pass path"
    assert_eq "$(json_step_status "$RUN_STDOUT" "browser_auth_setup")" "pass" "browser_auth_setup should pass on RC pass path"
    assert_eq "$(json_step_status "$RUN_STDOUT" "terraform_static_guardrails")" "pass" "terraform_static_guardrails should pass on RC pass path"
    assert_eq "$(json_step_status "$RUN_STDOUT" "staging_runtime_smoke")" "pass" "staging_runtime_smoke should pass on RC pass path with explicit inputs"
    assert_eq "$(json_step_count "$RUN_STDOUT")" "9" "paid-beta-rc pass path should include Stage 1 and Stage 2 required proof rows"
    assert_contains "$ses_args" "--identity beta@example.com" "ses_readiness should receive resolved identity"
    assert_contains "$ses_args" "--region us-east-1" "ses_readiness should receive resolved region"
    assert_contains "$billing_args" "--env-file $credential_env_file" "billing rehearsal should receive env file"
    assert_contains "$billing_args" "--month 2026-03" "billing rehearsal should receive billing month"
    assert_contains "$billing_args" "--confirm-live-mutation" "billing rehearsal should require live mutation confirmation flag"
    assert_contains "$invocation_log" "browser_preflight|$PWD|" "browser preflight should run from repo root without extra args"
    assert_contains "$invocation_log" "browser_auth_setup|$REPO_ROOT/web|playwright test -c playwright.config.ts tests/fixtures/auth.setup.ts tests/fixtures/admin.auth.setup.ts --project=setup:user --project=setup:admin --reporter=line" "browser auth setup should delegate exact playwright command in web dir"
    assert_contains "$invocation_log" "terraform_stage7_static|$PWD|" "terraform stage7 static guardrail should delegate without extra args"
    assert_contains "$invocation_log" "terraform_stage8_static|$PWD|" "terraform stage8 static guardrail should delegate without extra args"
    assert_contains "$invocation_log" "staging_runtime_smoke|$PWD|--env-file $credential_env_file --ami-id $staging_smoke_ami_id --env staging" "staging runtime smoke should delegate exact opt-in command"
}
test_paid_beta_rc_default_artifact_dir_does_not_touch_docs_evidence() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local credential_env_file docs_evidence_dir before_count after_count
    credential_env_file="$tmp_dir/credentials.env"
    docs_evidence_dir="$REPO_ROOT/docs/launch/evidence"
    cat > "$credential_env_file" <<'EOF'
SES_FROM_ADDRESS=beta@example.com
SES_REGION=us-east-1
EOF
    mkdir -p "$tmp_dir/bin"
    before_count="$(find "$docs_evidence_dir" -maxdepth 1 -type f -name 'backend_gate_*.json' | wc -l | tr -d ' ')"
    write_mock_script "$tmp_dir/mock_cargo.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_backend_gate.sh" '
if [ -z "${LAUNCH_GATE_EVIDENCE_DIR:-}" ]; then
    echo "LAUNCH_GATE_EVIDENCE_DIR missing" >&2
    exit 71
fi
if [ -z "${COLLECT_EVIDENCE_DIR:-}" ]; then
    echo "COLLECT_EVIDENCE_DIR missing" >&2
    exit 72
fi
mkdir -p "${LAUNCH_GATE_EVIDENCE_DIR}"
touch "${LAUNCH_GATE_EVIDENCE_DIR}/mock_backend_gate_marker.json"
echo "{\"verdict\":\"pass\"}"
exit 0'
    write_mock_script "$tmp_dir/mock_local_signoff.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_ses.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_billing.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_browser_preflight.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_tf_static_stage7.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_tf_static_stage8.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_runtime_smoke.sh" 'exit 0'
    write_mock_script "$tmp_dir/bin/npx" 'exit 0'
    run_orchestrator env \
        PATH="$tmp_dir/bin:$PATH" \
        FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
        FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
        FULL_VALIDATION_LOCAL_SIGNOFF_SCRIPT="$tmp_dir/mock_local_signoff.sh" \
        FULL_VALIDATION_SES_READINESS_SCRIPT="$tmp_dir/mock_ses.sh" \
        FULL_VALIDATION_STAGING_BILLING_REHEARSAL_SCRIPT="$tmp_dir/mock_billing.sh" \
        FULL_VALIDATION_BROWSER_PREFLIGHT_SCRIPT="$tmp_dir/mock_browser_preflight.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE7_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage7.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE8_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage8.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE7_RUNTIME_SMOKE_SCRIPT="$tmp_dir/mock_runtime_smoke.sh" \
        bash "$ORCH_SCRIPT" --paid-beta-rc --sha=aabbccddee00112233445566778899aabbccddee \
            --credential-env-file="$credential_env_file" --billing-month=2026-03 --staging-smoke-ami-id=ami-12345678
    after_count="$(find "$docs_evidence_dir" -maxdepth 1 -type f -name 'backend_gate_*.json' | wc -l | tr -d ' ')"
    rm -rf "$tmp_dir"
    assert_eq "$RUN_EXIT_CODE" "0" "paid-beta-rc should pass without writing to docs evidence by default"
    assert_eq "$before_count" "$after_count" "paid-beta-rc default artifact path should not create docs/launch/evidence backend files"
}
test_live_preflight_catches_all_missing_credentials() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    mkdir -p "$tmp_dir/bin"
    ln -sf /usr/bin/python3 "$tmp_dir/bin/python3"
    write_mock_script "$tmp_dir/bin/cargo" 'exit 0'
    run_orchestrator env \
        PATH="$tmp_dir/bin:/bin" \
        bash "$ORCH_SCRIPT"
    rm -rf "$tmp_dir"
    assert_eq "$RUN_EXIT_CODE" "1" "live preflight should fail when credentials are missing"
    assert_contains "$RUN_STDOUT" "\"preflight_failures\"" "preflight failure output should include preflight_failures array"
    assert_contains "$RUN_STDOUT" "STRIPE_SECRET_KEY" "preflight should list missing canonical STRIPE_SECRET_KEY"
    assert_contains "$RUN_STDOUT" "STRIPE_WEBHOOK_SECRET" "preflight should list missing STRIPE_WEBHOOK_SECRET"
    assert_contains "$RUN_STDOUT" "DATABASE_URL or INTEGRATION_DB_URL" "preflight should list missing database env requirement"
    assert_contains "$RUN_STDOUT" "git SHA" "preflight should list missing SHA resolution"
}
test_live_preflight_passes_when_all_credentials_present() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    write_mock_script "$tmp_dir/mock_cargo.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_backend_gate.sh" 'echo "{\"verdict\":\"pass\"}"; exit 0'
    run_orchestrator env \
        STRIPE_SECRET_KEY="sk_test_mock" \
        STRIPE_WEBHOOK_SECRET="whsec_mock" \
        DATABASE_URL="postgres://user:pass@localhost:5432/db" \
        FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
        FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
        bash "$ORCH_SCRIPT" --sha=aabbccddee00112233445566778899aabbccddee
    rm -rf "$tmp_dir"
    assert_eq "$RUN_EXIT_CODE" "0" "live preflight should pass when all required inputs are present"
    assert_eq "$(json_step_status "$RUN_STDOUT" "cargo_workspace_tests")" "pass" "cargo step should run after preflight success"
    assert_eq "$(json_step_status "$RUN_STDOUT" "backend_launch_gate")" "pass" "backend gate step should run after preflight success"
}
test_live_preflight_alias_compatibility_when_canonical_missing() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    write_mock_script "$tmp_dir/mock_cargo.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_backend_gate.sh" 'echo "{\"verdict\":\"pass\"}"; exit 0'
    run_orchestrator env \
        STRIPE_TEST_SECRET_KEY="sk_test_alias_compat" \
        STRIPE_WEBHOOK_SECRET="whsec_mock" \
        DATABASE_URL="postgres://user:pass@localhost:5432/db" \
        FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
        FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
        bash "$ORCH_SCRIPT" --sha=aabbccddee00112233445566778899aabbccddee
    rm -rf "$tmp_dir"
    assert_eq "$RUN_EXIT_CODE" "0" "preflight alias compatibility path should pass when only STRIPE_TEST_SECRET_KEY is present"
    assert_eq "$(json_step_status "$RUN_STDOUT" "cargo_workspace_tests")" "pass" "cargo step should run in alias compatibility path"
    assert_eq "$(json_step_status "$RUN_STDOUT" "backend_launch_gate")" "pass" "backend gate step should run in alias compatibility path"
}
test_source_only_mode_does_not_require_python3() {
    run_orchestrator env \
        PATH="/bin" \
        __RUN_FULL_BACKEND_VALIDATION_SOURCED=1 \
        ORCH_SCRIPT="$ORCH_SCRIPT" \
        bash -c '. "$ORCH_SCRIPT"'
    assert_eq "$RUN_EXIT_CODE" "0" "source-only mode should not require python3"
}
main() {
    echo "=== full_backend_validation tests ==="
    test_run_full_backend_validation_function_size_limit
    test_orchestrator_help_flag
    test_orchestrator_dry_run_produces_valid_json
    test_orchestrator_dry_run_sha_cli_pass_path
    test_orchestrator_fails_on_cargo_test_failure
    test_orchestrator_fails_on_backend_gate_failure
    test_orchestrator_fails_on_backend_gate_invalid_json
    test_orchestrator_rejects_invalid_sha_argument
    test_orchestrator_rejects_invalid_billing_month_argument
    test_orchestrator_rejects_invalid_staging_smoke_ami_argument
    test_orchestrator_collects_all_results_even_on_failure
    test_paid_beta_rc_blocks_missing_credentialed_inputs
    test_paid_beta_rc_blocks_when_billing_month_missing
    test_paid_beta_rc_blocks_staging_runtime_smoke_without_opt_in_inputs
    test_paid_beta_rc_propagates_delegated_billing_blocked_state
    test_paid_beta_rc_uses_shell_identity_when_credential_file_missing
    test_paid_beta_rc_pass_path_reports_ready_true
    test_paid_beta_rc_default_artifact_dir_does_not_touch_docs_evidence
    test_live_preflight_catches_all_missing_credentials
    test_live_preflight_passes_when_all_credentials_present
    test_live_preflight_alias_compatibility_when_canonical_missing
    test_source_only_mode_does_not_require_python3
    echo
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -ne 0 ]; then
        exit 1
    fi
}
main "$@"
