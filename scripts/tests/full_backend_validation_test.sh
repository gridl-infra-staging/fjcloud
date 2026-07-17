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
assert_not_contains() {
    local actual="$1" unexpected_substr="$2" msg="$3"
    if [[ "$actual" == *"$unexpected_substr"* ]]; then
        fail "$msg (unexpected substring '$unexpected_substr' found in '$actual')"
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
normalize_json() {
    local json="$1"
    python3 -c 'import json,sys; print(json.dumps(json.loads(sys.stdin.read()), sort_keys=True))' <<< "$json" 2>/dev/null || echo ""
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
write_mock_web_playwright_runtime() {
    local root="$1"
    mkdir -p "$root/web/node_modules/@playwright/test"
    cat > "$root/web/node_modules/@playwright/test/package.json" <<'EOF'
{
  "name": "@playwright/test",
  "version": "0.0.0-test"
}
EOF
}
run_orchestrator() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local stdout_file="$tmp_dir/stdout"
    local stderr_file="$tmp_dir/stderr"
    local default_outside_aws_script="$tmp_dir/mock_default_outside_aws.sh"
    local default_browser_lane_script="$tmp_dir/mock_default_browser_lane.sh"
    local default_browser_auth_setup_script="$tmp_dir/mock_default_browser_auth_setup.sh"
    local default_stripe_validation_script="$tmp_dir/mock_default_validate_stripe.sh"
    local default_web_runtime_root="$tmp_dir/default_web_runtime"
    write_mock_script "$default_outside_aws_script" 'exit 0'
    write_mock_script "$default_browser_lane_script" 'exit 0'
    write_mock_script "$default_browser_auth_setup_script" '
if [ -n "${INVOCATION_LOG_FILE:-}" ]; then
    printf "browser_auth_setup|%s|%s|remote=%s\n" "$PWD" "$*" "${PLAYWRIGHT_TARGET_REMOTE:-}" >> "$INVOCATION_LOG_FILE"
fi
exit 0'
    write_mock_script "$default_stripe_validation_script" '
if [ "$*" != "--test-clock" ]; then
    echo "validate-stripe should be delegated with --test-clock" >&2
    exit 88
fi
exit 0'
    write_mock_web_playwright_runtime "$default_web_runtime_root"
    local exit_code=0
    # browser_auth_setup now fails closed unless the deployed staging targets are
    # hydrated (matching the real hydrate_env_from_ssm path). Provide them here as
    # command-scoped defaults so registry runs exercise the staging proof; callers
    # that need a different value can still override via their own `env` prefix.
    if FULL_VALIDATION_OUTSIDE_AWS_HEALTH_SCRIPT="$default_outside_aws_script" \
        FULL_VALIDATION_BROWSER_LANE_SCRIPT="$default_browser_lane_script" \
        FULL_VALIDATION_PLAYWRIGHT_BIN="$default_browser_auth_setup_script" \
        FULL_VALIDATION_STRIPE_VALIDATION_SCRIPT="$default_stripe_validation_script" \
        FULL_VALIDATION_WEB_RUNTIME_REPO_ROOT="$default_web_runtime_root" \
        STAGING_CLOUD_URL="${STAGING_CLOUD_URL:-https://cloud.staging.flapjack.foo}" \
        STAGING_API_URL="${STAGING_API_URL:-https://api.staging.flapjack.foo}" \
        "$@" >"$stdout_file" 2>"$stderr_file"; then
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
    assert_contains "$RUN_STDOUT$RUN_STDERR" "--staging-smoke-api-ami-id=<ami-id>" "help output should include staging API smoke AMI flag"
    assert_contains "$RUN_STDOUT$RUN_STDERR" "--staging-smoke-flapjack-ami-id=<ami-id>" "help output should include staging Flapjack smoke AMI flag"
    assert_not_contains "$RUN_STDOUT$RUN_STDERR" "--staging-smoke-ami-id=<ami-id>" "help output should not advertise the removed coupled staging smoke AMI flag"
    assert_contains "$RUN_STDOUT$RUN_STDERR" "--staging-only" "help output should include staging-only flag"
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
test_paid_beta_rc_writes_step_stderr_to_artifact_dir_on_cargo_failure() {
    # Regression: prior versions of run_full_backend_validation.sh redirected step
    # stderr to /dev/null, which made every RC failure diagnostically blind. The
    # operator could see "cargo_workspace_tests fail" in summary.json but had no
    # way to recover the actual cargo error without re-running the step manually.
    # This test pins the contract that step stderr now lands in $ARTIFACT_DIR/<step>.log
    # whenever an artifact dir is provided (which paid-beta-rc always does).
    local tmp_dir artifact_dir
    tmp_dir="$(mktemp -d)"
    artifact_dir="$tmp_dir/artifacts"
    # Mock cargo emits a unique sentinel string to stderr so we can assert the log
    # captured the right stream (not stdout, not silently empty).
    write_mock_script "$tmp_dir/mock_cargo.sh" 'echo "cargo_diagnostic_sentinel_abc123" >&2; exit 1'
    write_mock_script "$tmp_dir/mock_backend_gate.sh" 'echo "{\"verdict\":\"pass\"}"; exit 0'
    write_mock_script "$tmp_dir/mock_local_signoff.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_browser_preflight.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_tf_static_stage7.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_tf_static_stage8.sh" 'exit 0'
    run_orchestrator env \
        FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
        FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
        FULL_VALIDATION_LOCAL_SIGNOFF_SCRIPT="$tmp_dir/mock_local_signoff.sh" \
        FULL_VALIDATION_BROWSER_PREFLIGHT_SCRIPT="$tmp_dir/mock_browser_preflight.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE7_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage7.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE8_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage8.sh" \
        FULL_VALIDATION_WEB_RUNTIME_REPO_ROOT="$tmp_dir" \
        bash "$ORCH_SCRIPT" --paid-beta-rc --sha=aabbccddee00112233445566778899aabbccddee \
            --artifact-dir="$artifact_dir"
    local cargo_log_path cargo_log_content cargo_log_existed
    cargo_log_path="$artifact_dir/cargo_workspace_tests.log"
    # Capture file state BEFORE rm -rf wipes tmp_dir, otherwise the existence
    # check would always fail regardless of the script's behavior.
    if [ -f "$cargo_log_path" ]; then
        cargo_log_existed="yes"
    else
        cargo_log_existed="no"
    fi
    cargo_log_content="$(cat "$cargo_log_path" 2>/dev/null || true)"
    rm -rf "$tmp_dir"
    assert_eq "$(json_step_status "$RUN_STDOUT" "cargo_workspace_tests")" "fail" "cargo step should fail on RC stderr-capture path"
    # The load-bearing assertions: the log file exists AND contains the stderr
    # content. A pass here proves the operator can diagnose the failure from
    # artifact_dir without re-running anything.
    assert_eq "$cargo_log_existed" "yes" "cargo_workspace_tests.log should exist in artifact dir after step failure"
    assert_contains "$cargo_log_content" "cargo_diagnostic_sentinel_abc123" "step log should capture stderr content for diagnosis"
}
test_cargo_workspace_step_does_not_inherit_db_url_from_parent_env() {
    # Regression: cargo test --workspace is intended as a "does the workspace
    # build and unit-test cleanly" smoke. Tests that need a live DB are opt-in
    # via paid-beta-rc rust steps (admin_broadcast, billing_health_last_activity,
    # audit_timeline) which use --ignored and set their own env. When an
    # operator runs the RC with DATABASE_URL hydrated from SSM (staging host
    # not reachable from a dev laptop), pg_customer_repo_test panics on DNS
    # resolve and the workspace step false-fails. Pin the contract: the cargo
    # step must run in an env where DATABASE_URL/INTEGRATION_DB_URL are unset,
    # regardless of what the operator exported.
    local tmp_dir log_path log_content
    tmp_dir="$(mktemp -d)"
    # Mock cargo writes a marker line capturing the values of the DB env vars
    # it sees. We assert these are empty/unset in the captured log.
    write_mock_script "$tmp_dir/mock_cargo.sh" 'echo "DATABASE_URL_SEEN=[${DATABASE_URL:-<unset>}]"; echo "INTEGRATION_DB_URL_SEEN=[${INTEGRATION_DB_URL:-<unset>}]"; exit 0'
    write_mock_script "$tmp_dir/mock_backend_gate.sh" 'echo "{\"verdict\":\"pass\"}"; exit 0'
    write_mock_script "$tmp_dir/mock_local_signoff.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_browser_preflight.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_tf_static_stage7.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_tf_static_stage8.sh" 'exit 0'
    run_orchestrator env \
        DATABASE_URL="postgres://leaked.example.invalid:5432/leaked" \
        INTEGRATION_DB_URL="postgres://leaked.example.invalid:5432/leaked" \
        DRY_RUN=1 \
        FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
        FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
        FULL_VALIDATION_LOCAL_SIGNOFF_SCRIPT="$tmp_dir/mock_local_signoff.sh" \
        FULL_VALIDATION_BROWSER_PREFLIGHT_SCRIPT="$tmp_dir/mock_browser_preflight.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE7_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage7.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE8_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage8.sh" \
        FULL_VALIDATION_WEB_RUNTIME_REPO_ROOT="$tmp_dir" \
        bash "$ORCH_SCRIPT" --paid-beta-rc --sha=aabbccddee00112233445566778899aabbccddee \
            --artifact-dir="$tmp_dir/artifacts"
    log_path="$tmp_dir/artifacts/cargo_workspace_tests.log"
    log_content="$(cat "$log_path" 2>/dev/null || true)"
    rm -rf "$tmp_dir"
    # Both vars must show as <unset> in the cargo subshell. If they showed the
    # leaked values, the cargo step is inheriting parent env (the bug).
    assert_contains "$log_content" "DATABASE_URL_SEEN=[<unset>]" "cargo step must run with DATABASE_URL unset to avoid pg_customer_repo_test panicking on a host it cannot reach"
    assert_contains "$log_content" "INTEGRATION_DB_URL_SEEN=[<unset>]" "cargo step must run with INTEGRATION_DB_URL unset for the same reason"
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
    run_orchestrator bash "$ORCH_SCRIPT" --paid-beta-rc --sha=aabbccddee00112233445566778899aabbccddee --staging-smoke-api-ami-id=invalid-ami
    assert_eq "$RUN_EXIT_CODE" "2" "invalid --staging-smoke-api-ami-id should fail with usage error"
    assert_contains "$RUN_STDERR" "--staging-smoke-api-ami-id must use AMI ID format" "invalid --staging-smoke-api-ami-id should mention strict format"

    run_orchestrator bash "$ORCH_SCRIPT" --paid-beta-rc --sha=aabbccddee00112233445566778899aabbccddee --staging-smoke-flapjack-ami-id=invalid-ami
    assert_eq "$RUN_EXIT_CODE" "2" "invalid --staging-smoke-flapjack-ami-id should fail with usage error"
    assert_contains "$RUN_STDERR" "--staging-smoke-flapjack-ami-id must use AMI ID format" "invalid --staging-smoke-flapjack-ami-id should mention strict format"

    run_orchestrator bash "$ORCH_SCRIPT" --paid-beta-rc --sha=aabbccddee00112233445566778899aabbccddee --staging-smoke-ami-id=ami-12345678
    assert_eq "$RUN_EXIT_CODE" "2" "removed --staging-smoke-ami-id should fail with usage error"
    assert_contains "$RUN_STDERR" "--staging-smoke-ami-id was removed; pass --staging-smoke-api-ami-id and --staging-smoke-flapjack-ami-id" "removed staging smoke AMI flag should point to split flags"
}
test_orchestrator_rejects_staging_only_without_paid_beta_rc() {
    run_orchestrator bash "$ORCH_SCRIPT" --staging-only --sha=aabbccddee00112233445566778899aabbccddee
    assert_eq "$RUN_EXIT_CODE" "2" "standalone --staging-only should fail with usage error"
    assert_contains "$RUN_STDERR" "--staging-only requires --paid-beta-rc" "standalone --staging-only should explain required mode pairing"
}
test_orchestrator_rejects_staging_only_with_dry_run() {
    run_orchestrator bash "$ORCH_SCRIPT" --dry-run --staging-only --sha=aabbccddee00112233445566778899aabbccddee
    assert_eq "$RUN_EXIT_CODE" "2" "--staging-only with --dry-run should fail with usage error"
    assert_contains "$RUN_STDERR" "--staging-only requires --paid-beta-rc" "--staging-only with --dry-run should explain incompatible modes"
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
test_paid_beta_rc_replaces_legacy_blocked_emissions() {
    local blocked_step_hits
    blocked_step_hits="$(grep -n 'append_step .*\"blocked\"' "$ORCH_SCRIPT" || true)"
    assert_eq "$blocked_step_hits" "" "coordinator should remove legacy blocked status emissions from append_step callsites"
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
    assert_json_bool_field "$RUN_STDOUT" "ready" "false" "paid-beta-rc should report ready=false when required proofs are missing"
    assert_json_field "$RUN_STDOUT" "verdict" "fail" "paid-beta-rc should preserve fail verdict when required proofs are missing"
    assert_eq "$(json_step_status "$RUN_STDOUT" "local_signoff")" "pass" "local_signoff should run and pass when mocked"
    assert_eq "$(json_step_status "$RUN_STDOUT" "ses_readiness")" "external_secret_missing" "ses_readiness should report missing live secret without identity input"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "ses_readiness")" "credentialed_ses_identity_missing" "ses_readiness should report credentialed_ses_identity_missing"
    assert_eq "$(json_step_status "$RUN_STDOUT" "staging_billing_rehearsal")" "external_secret_missing" "staging_billing_rehearsal should report missing live secret without billing env inputs"
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
    assert_eq "$(json_step_status "$RUN_STDOUT" "staging_billing_rehearsal")" "live_evidence_gap" "staging_billing_rehearsal should report live evidence gap when month is missing"
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
        bash "$ORCH_SCRIPT" --paid-beta-rc --sha=aabbccddee00112233445566778899aabbccddee --billing-month=2026-03 --staging-smoke-api-ami-id=ami-12345678
    local runtime_invocations
    runtime_invocations="$(cat "$runtime_invocations_file" 2>/dev/null || true)"
    rm -rf "$tmp_dir"
    assert_eq "$RUN_EXIT_CODE" "1" "paid-beta-rc should fail when staging runtime smoke prerequisites are missing"
    assert_json_bool_field "$RUN_STDOUT" "ready" "false" "paid-beta-rc should keep ready=false when staging runtime smoke is not yet credentialed"
    assert_json_field "$RUN_STDOUT" "verdict" "fail" "paid-beta-rc should preserve fail verdict when staging runtime smoke is not yet credentialed"
    assert_eq "$(json_step_status "$RUN_STDOUT" "staging_runtime_smoke")" "live_evidence_gap" "staging_runtime_smoke should report live_evidence_gap when explicit inputs are missing"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "staging_runtime_smoke")" "credentialed_staging_smoke_inputs_missing" "staging_runtime_smoke should report credentialed_staging_smoke_inputs_missing"
    assert_eq "$runtime_invocations" "" "staging_runtime_smoke should not invoke runtime script when explicit inputs are missing"
}
test_paid_beta_rc_propagates_delegated_billing_live_evidence_gap() {
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
    assert_json_bool_field "$RUN_STDOUT" "ready" "false" "paid-beta-rc should keep ready=false when delegated billing proof has a live evidence gap"
    assert_json_field "$RUN_STDOUT" "verdict" "fail" "paid-beta-rc should preserve fail verdict when delegated billing proof has a live evidence gap"
    assert_eq "$(json_step_status "$RUN_STDOUT" "local_signoff")" "pass" "local_signoff pass should not mask delegated billing live evidence gap classification"
    assert_eq "$(json_step_status "$RUN_STDOUT" "ses_readiness")" "pass" "ses_readiness pass should not mask delegated billing live evidence gap classification"
    assert_eq "$(json_step_status "$RUN_STDOUT" "staging_billing_rehearsal")" "live_evidence_gap" "staging_billing_rehearsal should map delegated blocked result to live_evidence_gap"
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
    assert_eq "$(json_step_status "$RUN_STDOUT" "staging_billing_rehearsal")" "external_secret_missing" "staging_billing_rehearsal should report external_secret_missing when env file is missing"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "staging_billing_rehearsal")" "credentialed_billing_env_file_missing" "staging_billing_rehearsal should report credentialed_billing_env_file_missing"
    assert_contains "$ses_args" "--identity shell-beta@example.com" "ses_readiness should delegate shell-provided identity"
}
test_paid_beta_rc_pass_path_reports_ready_true() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local credential_env_file artifact_dir invocation_log_file stripe_args_file stripe_env_file
    credential_env_file="$tmp_dir/credentials.env"
    artifact_dir="$tmp_dir/artifacts"
    invocation_log_file="$tmp_dir/invocations.log"
    stripe_args_file="$tmp_dir/stripe_args.txt"
    stripe_env_file="$tmp_dir/stripe_env.txt"
    cat > "$credential_env_file" <<'EOF'
SES_FROM_ADDRESS=beta@example.com
SES_REGION=us-east-1
FLAPJACK_ADMIN_KEY=file_admin_key
STRIPE_TEST_SECRET_KEY=sk_test_from_file
AWS_ACCESS_KEY_ID=credential_file_access_key
AWS_SECRET_ACCESS_KEY=credential_file_secret_key
AWS_DEFAULT_REGION=us-east-2
STRIPE_SECRET_KEY=sk_test_from_file
STAGING_API_URL=https://api.drifted.example.invalid
EOF
    local ses_args_file billing_args_file staging_smoke_api_ami_id staging_smoke_flapjack_ami_id backend_gate_args_file
    ses_args_file="$tmp_dir/ses_args.txt"
    billing_args_file="$tmp_dir/billing_args.txt"
    backend_gate_args_file="$tmp_dir/backend_gate_args.txt"
    local ses_inbound_probe_file canary_probe_file
    ses_inbound_probe_file="$tmp_dir/ses_inbound_probe.txt"
    canary_probe_file="$tmp_dir/canary_probe.txt"
    staging_smoke_api_ami_id="ami-12345678"
    staging_smoke_flapjack_ami_id="ami-87654321"
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
printf "%s\n" "$*" > "${BACKEND_GATE_ARGS_FILE:?}"
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
    write_mock_script "$tmp_dir/mock_browser_lane.sh" '
if [ "${AWS_ACCESS_KEY_ID:-}" != "credential_file_access_key" ]; then
    echo "AWS_ACCESS_KEY_ID was not loaded from credential env file" >&2
    exit 91
fi
if [ "${AWS_SECRET_ACCESS_KEY:-}" != "credential_file_secret_key" ]; then
    echo "AWS_SECRET_ACCESS_KEY was not loaded from credential env file" >&2
    exit 92
fi
if [ "${AWS_DEFAULT_REGION:-}" != "us-east-2" ]; then
    echo "AWS_DEFAULT_REGION was not loaded from credential env file" >&2
    exit 93
fi
if [ -n "${STRIPE_SECRET_KEY:-}" ]; then
    echo "STRIPE_SECRET_KEY leaked from credential env file into browser lane" >&2
    exit 94
fi
if [ "${STAGING_API_URL:-}" = "https://api.drifted.example.invalid" ]; then
    echo "STAGING_API_URL leaked from credential env file into browser lane" >&2
    exit 95
fi
printf "browser_lane|%s|%s|aws=%s/%s\n" "$PWD" "$*" "$AWS_ACCESS_KEY_ID" "$AWS_DEFAULT_REGION" >> "${INVOCATION_LOG_FILE:?}"
exit 0'
    write_mock_script "$tmp_dir/mock_ses_inbound_roundtrip.sh" '
if [ -z "${SES_FROM_ADDRESS:-}" ] || [ -z "${SES_REGION:-}" ]; then
    echo "SES_FROM_ADDRESS and SES_REGION are required" >&2
    exit 96
fi
printf "from=%s region=%s\n" "$SES_FROM_ADDRESS" "$SES_REGION" > "${SES_INBOUND_PROBE_FILE:?}"
exit 0'
    write_mock_script "$tmp_dir/mock_canary_customer_loop.sh" '
if [ "${CANARY_RC_READINESS_MODE:-0}" != "1" ]; then
    echo "CANARY_RC_READINESS_MODE=1 is required in RC delegation mode" >&2
    exit 97
fi
if [ -z "${ADMIN_KEY:-}" ] || [ -z "${STRIPE_SECRET_KEY:-}" ]; then
    echo "ADMIN_KEY and STRIPE_SECRET_KEY are required" >&2
    exit 98
fi
printf "admin=%s stripe=%s readiness=%s\n" "$ADMIN_KEY" "$STRIPE_SECRET_KEY" "$CANARY_RC_READINESS_MODE" > "${CANARY_PROBE_FILE:?}"
exit 0'
    write_mock_script "$tmp_dir/mock_validate_stripe.sh" '
printf "%s\n" "$*" > "${STRIPE_ARGS_FILE:?}"
printf "%s\n" "${STRIPE_SECRET_KEY:-}" > "${STRIPE_ENV_FILE:?}"
exit 0'
    write_mock_script "$tmp_dir/bin/npx" '
printf "browser_auth_setup|%s|%s|remote=%s\n" "$PWD" "$*" "${PLAYWRIGHT_TARGET_REMOTE:-}" >> "${INVOCATION_LOG_FILE:?}"
exit 0'
    write_mock_web_playwright_runtime "$tmp_dir"
    run_orchestrator env \
        AWS_ACCESS_KEY_ID="stale_parent_access_key" \
        AWS_SECRET_ACCESS_KEY="stale_parent_secret_key" \
        AWS_DEFAULT_REGION="us-west-1" \
        SES_FROM_ADDRESS="" \
        SES_REGION="" \
        ADMIN_KEY="" \
        FLAPJACK_ADMIN_KEY="" \
        STRIPE_SECRET_KEY="" \
        STRIPE_TEST_SECRET_KEY="" \
        PATH="$tmp_dir/bin:$PATH" \
        BACKEND_GATE_ARGS_FILE="$backend_gate_args_file" \
        EXPECTED_ARTIFACT_DIR="$artifact_dir" \
        SES_ARGS_FILE="$ses_args_file" \
        BILLING_ARGS_FILE="$billing_args_file" \
        SES_INBOUND_PROBE_FILE="$ses_inbound_probe_file" \
        CANARY_PROBE_FILE="$canary_probe_file" \
        INVOCATION_LOG_FILE="$invocation_log_file" \
        STRIPE_ARGS_FILE="$stripe_args_file" \
        STRIPE_ENV_FILE="$stripe_env_file" \
        FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
        FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
        FULL_VALIDATION_LOCAL_SIGNOFF_SCRIPT="$tmp_dir/mock_local_signoff.sh" \
        FULL_VALIDATION_SES_READINESS_SCRIPT="$tmp_dir/mock_ses.sh" \
        FULL_VALIDATION_STAGING_BILLING_REHEARSAL_SCRIPT="$tmp_dir/mock_billing.sh" \
        FULL_VALIDATION_BROWSER_PREFLIGHT_SCRIPT="$tmp_dir/mock_browser_preflight.sh" \
        FULL_VALIDATION_PLAYWRIGHT_BIN="$tmp_dir/bin/npx" \
        FULL_VALIDATION_TERRAFORM_STAGE7_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage7.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE8_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage8.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE7_RUNTIME_SMOKE_SCRIPT="$tmp_dir/mock_runtime_smoke.sh" \
        FULL_VALIDATION_BROWSER_LANE_SCRIPT="$tmp_dir/mock_browser_lane.sh" \
        FULL_VALIDATION_STRIPE_VALIDATION_SCRIPT="$tmp_dir/mock_validate_stripe.sh" \
        FULL_VALIDATION_SES_INBOUND_ROUNDTRIP_SCRIPT="$tmp_dir/mock_ses_inbound_roundtrip.sh" \
        FULL_VALIDATION_CANARY_CUSTOMER_LOOP_SCRIPT="$tmp_dir/mock_canary_customer_loop.sh" \
        FULL_VALIDATION_WEB_RUNTIME_REPO_ROOT="$tmp_dir" \
        bash "$ORCH_SCRIPT" --paid-beta-rc --sha=aabbccddee00112233445566778899aabbccddee \
            --credential-env-file="$credential_env_file" --billing-month=2026-03 --artifact-dir="$artifact_dir" \
            --staging-smoke-api-ami-id="$staging_smoke_api_ami_id" \
            --staging-smoke-flapjack-ami-id="$staging_smoke_flapjack_ami_id"
    local ses_args billing_args invocation_log summary_json normalized_stdout normalized_summary backend_gate_args
    local browser_filtered_env_files browser_artifact_secret_values
    local ses_inbound_probe canary_probe signup_browser_log portal_browser_log stripe_args stripe_env
    ses_args="$(cat "$ses_args_file" 2>/dev/null || true)"
    billing_args="$(cat "$billing_args_file" 2>/dev/null || true)"
    ses_inbound_probe="$(cat "$ses_inbound_probe_file" 2>/dev/null || true)"
    canary_probe="$(cat "$canary_probe_file" 2>/dev/null || true)"
    stripe_args="$(cat "$stripe_args_file" 2>/dev/null || true)"
    stripe_env="$(cat "$stripe_env_file" 2>/dev/null || true)"
    invocation_log="$(cat "$invocation_log_file" 2>/dev/null || true)"
    backend_gate_args="$(cat "$backend_gate_args_file" 2>/dev/null || true)"
    summary_json="$(cat "$artifact_dir/summary.json" 2>/dev/null || true)"
    signup_browser_log="$(cat "$artifact_dir/browser_signup_paid.log" 2>/dev/null || true)"
    portal_browser_log="$(cat "$artifact_dir/browser_portal_cancel.log" 2>/dev/null || true)"
    browser_filtered_env_files="$(ls "$artifact_dir"/*_credential_env.filtered 2>/dev/null || true)"
    browser_artifact_secret_values="$(grep -R 'credential_file_access_key\|credential_file_secret_key' "$artifact_dir" 2>/dev/null || true)"
    normalized_stdout="$(normalize_json "$RUN_STDOUT")"
    normalized_summary="$(normalize_json "$summary_json")"
    rm -rf "$tmp_dir"
    assert_eq "$RUN_EXIT_CODE" "0" "paid-beta-rc should pass when every required proof passes"
    assert_json_field "$RUN_STDOUT" "mode" "paid_beta_rc" "paid-beta-rc output mode should be paid_beta_rc"
    assert_json_bool_field "$RUN_STDOUT" "ready" "true" "paid-beta-rc should report ready=true when every required proof passes"
    assert_json_field "$RUN_STDOUT" "verdict" "pass" "paid-beta-rc should report pass verdict when every required proof passes"
    assert_eq "$(json_step_status "$RUN_STDOUT" "cargo_workspace_tests")" "pass" "cargo step should pass on RC pass path"
    assert_eq "$(json_step_status "$RUN_STDOUT" "backend_launch_gate")" "pass" "backend launch gate should pass on RC pass path"
    assert_eq "$(json_step_status "$RUN_STDOUT" "local_signoff")" "pass" "local_signoff should pass on RC pass path"
    assert_eq "$(json_step_status "$RUN_STDOUT" "ses_readiness")" "pass" "ses_readiness should pass on RC pass path"
    assert_eq "$(json_step_status "$RUN_STDOUT" "staging_billing_rehearsal")" "pass" "staging_billing_rehearsal should pass on RC pass path"
    assert_eq "$(json_step_status "$RUN_STDOUT" "browser_preflight")" "pass" "browser_preflight should pass on RC pass path"
    assert_eq "$(json_step_status "$RUN_STDOUT" "browser_auth_setup")" "pass" "browser_auth_setup should pass on RC pass path"
    assert_eq "$(json_step_status "$RUN_STDOUT" "terraform_static_guardrails")" "pass" "terraform_static_guardrails should pass on RC pass path"
    assert_eq "$(json_step_status "$RUN_STDOUT" "staging_runtime_smoke")" "pass" "staging_runtime_smoke should pass on RC path with explicit inputs"
    assert_eq "$(json_step_status "$RUN_STDOUT" "admin_broadcast")" "pass" "Tier-1 admin_broadcast should be recorded on RC path"
    assert_eq "$(json_step_status "$RUN_STDOUT" "billing_health_last_activity")" "pass" "Tier-1 billing_health_last_activity should be recorded on RC path"
    assert_eq "$(json_step_status "$RUN_STDOUT" "audit_timeline")" "pass" "Tier-1 audit_timeline should be recorded on RC path"
    assert_eq "$(json_step_status "$RUN_STDOUT" "status_runtime")" "pass" "Tier-1 status_runtime should be recorded on RC path"
    assert_eq "$(json_step_status "$RUN_STDOUT" "ses_inbound")" "pass" "Tier-1 ses_inbound should pass when delegated roundtrip owner succeeds"
    assert_eq "$(json_step_status "$RUN_STDOUT" "canary_customer_loop")" "pass" "Tier-1 canary_customer_loop should pass when delegated owner succeeds"
    assert_eq "$(json_step_status "$RUN_STDOUT" "canary_outside_aws")" "pass" "Tier-1 canary_outside_aws should run as direct readiness probe"
    assert_eq "$(json_step_status "$RUN_STDOUT" "stripe_webhook_signature_matrix_idempotency")" "pass" "Tier-1 webhook matrix step should be recorded on RC path"
    assert_eq "$(json_step_status "$RUN_STDOUT" "test_clock")" "pass" "Tier-1 test_clock should pass in paid-beta-rc readiness mode"
    assert_eq "$(json_step_status "$RUN_STDOUT" "tenant_isolation")" "pass" "Tier-1 tenant_isolation should be recorded on RC path"
    assert_eq "$(json_step_status "$RUN_STDOUT" "signup_abuse")" "pass" "Tier-1 signup_abuse should be recorded on RC path"
    assert_eq "$(json_step_status "$RUN_STDOUT" "browser_signup_paid")" "pass" "Tier-1 browser_signup_paid should pass when delegated browser lane succeeds"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "browser_signup_paid")" "" "Tier-1 browser_signup_paid should not keep placeholder critical skip reason"
    assert_eq "$(json_step_status "$RUN_STDOUT" "browser_portal_cancel")" "pass" "Tier-1 browser_portal_cancel should pass when delegated browser lane succeeds"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "browser_portal_cancel")" "" "Tier-1 browser_portal_cancel should not keep placeholder critical skip reason"
    assert_eq "$(json_step_count "$RUN_STDOUT")" "22" "paid-beta-rc path should include Stage 1 plus Tier-1 proof rows"
    assert_not_contains "$RUN_STDOUT" '"blocked"' "paid-beta-rc pass payload should not include legacy blocked status"
    assert_eq "$normalized_stdout" "$normalized_summary" "paid-beta-rc should write summary.json with the same final JSON emitted to stdout"
    assert_contains "$ses_args" "--identity beta@example.com" "ses_readiness should receive resolved identity"
    assert_contains "$ses_args" "--region us-east-1" "ses_readiness should receive resolved region"
    assert_contains "$billing_args" "--env-file $credential_env_file" "billing rehearsal should receive env file"
    assert_contains "$billing_args" "--month 2026-03" "billing rehearsal should receive billing month"
    assert_contains "$billing_args" "--confirm-live-mutation" "billing rehearsal should require live mutation confirmation flag"
    assert_contains "$ses_inbound_probe" "from=beta@example.com region=us-east-1" "ses_inbound delegated owner should receive resolved SES credentials"
    assert_contains "$canary_probe" "admin=file_admin_key stripe=sk_test_from_file readiness=1" "canary delegated owner should receive resolved credentials and RC readiness flag"
    assert_eq "$stripe_args" "--test-clock" "test_clock should delegate to validate-stripe --test-clock"
    assert_eq "$stripe_env" "sk_test_from_file" "test_clock should receive the credential-owner resolved Stripe test key"
    assert_contains "$invocation_log" "browser_preflight|$PWD|" "browser preflight should run from repo root without extra args"
    assert_contains "$invocation_log" "browser_auth_setup|$REPO_ROOT/web|playwright test -c playwright.config.ts tests/fixtures/auth.setup.ts tests/fixtures/admin.auth.setup.ts --project=setup:user --project=setup:admin --reporter=line" "browser auth setup should delegate exact playwright command in web dir"
    assert_contains "$invocation_log" "browser_lane|$PWD|--lane signup_to_paid_invoice --evidence-dir $artifact_dir/browser_signup_paid|aws=credential_file_access_key/us-east-2" "browser_signup_paid should delegate canonical signup lane from repo root with credential-file AWS env"
    assert_contains "$invocation_log" "browser_lane|$PWD|--lane billing_portal_payment_method_update --evidence-dir $artifact_dir/browser_portal_cancel|aws=credential_file_access_key/us-east-2" "browser_portal_cancel should delegate canonical portal lane from repo root with credential-file AWS env"
    assert_contains "$signup_browser_log" "$tmp_dir/mock_browser_lane.sh --lane signup_to_paid_invoice" "browser_signup_paid log should record delegated browser runner path and canonical lane"
    assert_contains "$portal_browser_log" "$tmp_dir/mock_browser_lane.sh --lane billing_portal_payment_method_update" "browser_portal_cancel log should record delegated browser runner path and canonical lane"
    assert_eq "$browser_filtered_env_files" "" "browser delegated credential env files should not be persisted in the RC artifact bundle"
    assert_not_contains "$browser_artifact_secret_values" "credential_file_secret_key" "browser artifact bundle should not contain filtered AWS secret values"
    assert_not_contains "$browser_artifact_secret_values" "credential_file_access_key" "browser artifact bundle should not contain filtered AWS access key values"
    assert_contains "$invocation_log" "terraform_stage7_static|$PWD|" "terraform stage7 static guardrail should delegate without extra args"
    assert_contains "$invocation_log" "terraform_stage8_static|$PWD|" "terraform stage8 static guardrail should delegate without extra args"
    assert_contains "$invocation_log" "staging_runtime_smoke|$PWD|--env-file $credential_env_file --api-ami-id $staging_smoke_api_ami_id --flapjack-ami-id $staging_smoke_flapjack_ami_id --env staging" "staging runtime smoke should delegate exact split opt-in command"
    assert_not_contains "$invocation_log" "--ami-id" "staging runtime smoke delegation must not use removed single-AMI option"
    assert_contains "$backend_gate_args" "--staging-only" "paid-beta-rc should forward staging-only to backend gate unconditionally"
}
test_paid_beta_rc_test_clock_rejects_live_key_before_delegation() {
    local tmp_dir credential_env_file artifact_dir
    tmp_dir="$(mktemp -d)"
    credential_env_file="$tmp_dir/credentials.env"
    artifact_dir="$tmp_dir/artifacts"
    cat > "$credential_env_file" <<'EOF'
SES_FROM_ADDRESS=beta@example.com
SES_REGION=us-east-1
FLAPJACK_ADMIN_KEY=file_admin_key
STRIPE_TEST_SECRET_KEY=sk_live_from_file
EOF
    write_mock_script "$tmp_dir/mock_cargo.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_backend_gate.sh" 'echo "{\"verdict\":\"pass\"}"; exit 0'
    write_mock_script "$tmp_dir/mock_local_signoff.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_ses.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_billing.sh" 'echo "{\"result\":\"passed\"}"; exit 0'
    write_mock_script "$tmp_dir/mock_browser_preflight.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_tf_static_stage7.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_tf_static_stage8.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_runtime_smoke.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_ses_inbound_roundtrip.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_canary_customer_loop.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_validate_stripe.sh" 'echo "validate-stripe should not run with a live key" >&2; exit 99'
    write_mock_web_playwright_runtime "$tmp_dir"
    run_orchestrator env \
        ADMIN_KEY="" \
        FLAPJACK_ADMIN_KEY="" \
        STRIPE_SECRET_KEY="" \
        STRIPE_TEST_SECRET_KEY="" \
        FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
        FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
        FULL_VALIDATION_LOCAL_SIGNOFF_SCRIPT="$tmp_dir/mock_local_signoff.sh" \
        FULL_VALIDATION_SES_READINESS_SCRIPT="$tmp_dir/mock_ses.sh" \
        FULL_VALIDATION_STAGING_BILLING_REHEARSAL_SCRIPT="$tmp_dir/mock_billing.sh" \
        FULL_VALIDATION_BROWSER_PREFLIGHT_SCRIPT="$tmp_dir/mock_browser_preflight.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE7_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage7.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE8_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage8.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE7_RUNTIME_SMOKE_SCRIPT="$tmp_dir/mock_runtime_smoke.sh" \
        FULL_VALIDATION_SES_INBOUND_ROUNDTRIP_SCRIPT="$tmp_dir/mock_ses_inbound_roundtrip.sh" \
        FULL_VALIDATION_CANARY_CUSTOMER_LOOP_SCRIPT="$tmp_dir/mock_canary_customer_loop.sh" \
        FULL_VALIDATION_STRIPE_VALIDATION_SCRIPT="$tmp_dir/mock_validate_stripe.sh" \
        FULL_VALIDATION_WEB_RUNTIME_REPO_ROOT="$tmp_dir" \
        bash "$ORCH_SCRIPT" --paid-beta-rc --sha=aabbccddee00112233445566778899aabbccddee \
            --credential-env-file="$credential_env_file" --billing-month=2026-03 --artifact-dir="$artifact_dir" \
            --staging-smoke-api-ami-id=ami-12345678 --staging-smoke-flapjack-ami-id=ami-87654321
    local test_clock_log
    test_clock_log="$(cat "$artifact_dir/test_clock.log" 2>/dev/null || true)"
    rm -rf "$tmp_dir"
    assert_eq "$RUN_EXIT_CODE" "1" "paid-beta-rc should fail when test_clock resolves a live Stripe key"
    assert_eq "$(json_step_status "$RUN_STDOUT" "test_clock")" "fail" "test_clock live-key guard should be an explicit failed proof"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "test_clock")" "paid_beta_rc_test_clock_live_key_rejected" "test_clock live-key guard should use deterministic failure reason"
    assert_contains "$test_clock_log" "resolved Stripe key is live-mode" "test_clock log should explain live-key rejection"
    assert_not_contains "$RUN_STDERR" "validate-stripe should not run with a live key" "test_clock should reject live keys before delegation"
}
test_paid_beta_rc_test_clock_prefers_credential_file_test_alias_over_shell_live_key() {
    local tmp_dir credential_env_file artifact_dir stripe_args_file stripe_env_file
    tmp_dir="$(mktemp -d)"
    credential_env_file="$tmp_dir/credentials.env"
    artifact_dir="$tmp_dir/artifacts"
    stripe_args_file="$tmp_dir/stripe_args.txt"
    stripe_env_file="$tmp_dir/stripe_env.txt"
    mkdir -p "$tmp_dir/bin"
    cat > "$credential_env_file" <<'EOF'
SES_FROM_ADDRESS=beta@example.com
SES_REGION=us-east-1
FLAPJACK_ADMIN_KEY=file_admin_key
STRIPE_TEST_SECRET_KEY=sk_test_from_file
EOF
    write_mock_script "$tmp_dir/mock_cargo.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_backend_gate.sh" 'echo "{\"verdict\":\"pass\"}"; exit 0'
    write_mock_script "$tmp_dir/mock_local_signoff.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_ses.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_billing.sh" 'echo "{\"result\":\"passed\"}"; exit 0'
    write_mock_script "$tmp_dir/mock_browser_preflight.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_tf_static_stage7.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_tf_static_stage8.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_runtime_smoke.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_ses_inbound_roundtrip.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_canary_customer_loop.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_validate_stripe.sh" '
printf "%s\n" "$*" > "${STRIPE_ARGS_FILE:?}"
printf "%s\n" "${STRIPE_SECRET_KEY:-}" > "${STRIPE_ENV_FILE:?}"
exit 0'
    write_mock_script "$tmp_dir/bin/npx" 'exit 0'
    write_mock_web_playwright_runtime "$tmp_dir"
    run_orchestrator env \
        PATH="$tmp_dir/bin:$PATH" \
        ADMIN_KEY="" \
        FLAPJACK_ADMIN_KEY="" \
        STRIPE_SECRET_KEY="sk_live_stale_parent" \
        STRIPE_TEST_SECRET_KEY="" \
        STRIPE_ARGS_FILE="$stripe_args_file" \
        STRIPE_ENV_FILE="$stripe_env_file" \
        FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
        FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
        FULL_VALIDATION_LOCAL_SIGNOFF_SCRIPT="$tmp_dir/mock_local_signoff.sh" \
        FULL_VALIDATION_SES_READINESS_SCRIPT="$tmp_dir/mock_ses.sh" \
        FULL_VALIDATION_STAGING_BILLING_REHEARSAL_SCRIPT="$tmp_dir/mock_billing.sh" \
        FULL_VALIDATION_BROWSER_PREFLIGHT_SCRIPT="$tmp_dir/mock_browser_preflight.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE7_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage7.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE8_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage8.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE7_RUNTIME_SMOKE_SCRIPT="$tmp_dir/mock_runtime_smoke.sh" \
        FULL_VALIDATION_SES_INBOUND_ROUNDTRIP_SCRIPT="$tmp_dir/mock_ses_inbound_roundtrip.sh" \
        FULL_VALIDATION_CANARY_CUSTOMER_LOOP_SCRIPT="$tmp_dir/mock_canary_customer_loop.sh" \
        FULL_VALIDATION_STRIPE_VALIDATION_SCRIPT="$tmp_dir/mock_validate_stripe.sh" \
        FULL_VALIDATION_WEB_RUNTIME_REPO_ROOT="$tmp_dir" \
        bash "$ORCH_SCRIPT" --paid-beta-rc --sha=aabbccddee00112233445566778899aabbccddee \
            --credential-env-file="$credential_env_file" --billing-month=2026-03 --artifact-dir="$artifact_dir" \
            --staging-smoke-api-ami-id=ami-12345678 --staging-smoke-flapjack-ami-id=ami-87654321
    local stripe_args stripe_env
    stripe_args="$(cat "$stripe_args_file" 2>/dev/null || true)"
    stripe_env="$(cat "$stripe_env_file" 2>/dev/null || true)"
    rm -rf "$tmp_dir"
    assert_eq "$RUN_EXIT_CODE" "0" "paid-beta-rc should pass test_clock with file-scoped test alias despite stale shell live key"
    assert_eq "$(json_step_status "$RUN_STDOUT" "test_clock")" "pass" "test_clock should not reject inherited live key when credential file provides test alias"
    assert_eq "$stripe_args" "--test-clock" "test_clock should still delegate to validate-stripe --test-clock"
    assert_eq "$stripe_env" "sk_test_from_file" "test_clock should pass the credential-file STRIPE_TEST_SECRET_KEY alias to validate-stripe"
}
test_paid_beta_rc_local_signoff_prerequisite_gap_is_mode_skip() {
    local tmp_dir auth_setup_invocation
    tmp_dir="$(mktemp -d)"
    auth_setup_invocation="$tmp_dir/auth_setup_invocation.log"
    write_mock_script "$tmp_dir/mock_cargo.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_backend_gate.sh" 'echo "{\"verdict\":\"pass\"}"; exit 0'
    write_mock_script "$tmp_dir/mock_local_signoff.sh" '
echo "REASON: prerequisite_missing" >&2
echo "Strict signoff prerequisites invalid" >&2
exit 1'
    write_mock_script "$tmp_dir/mock_ses.sh" 'echo "ses should not run without identity" >&2; exit 99'
    write_mock_script "$tmp_dir/mock_billing.sh" 'echo "billing should not run without env file" >&2; exit 99'
    write_mock_script "$tmp_dir/mock_browser_preflight.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_tf_static_stage7.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_tf_static_stage8.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_runtime_smoke.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_ses_inbound_roundtrip.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_canary_customer_loop.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_playwright_auth_setup.sh" '
printf "cwd=%s args=%s\n" "$PWD" "$*" > "${AUTH_SETUP_INVOCATION_FILE:?}"
exit 0'
    write_mock_web_playwright_runtime "$tmp_dir"
    run_orchestrator env \
        SES_FROM_ADDRESS="" \
        SES_REGION="" \
        AUTH_SETUP_INVOCATION_FILE="$auth_setup_invocation" \
        FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
        FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
        FULL_VALIDATION_LOCAL_SIGNOFF_SCRIPT="$tmp_dir/mock_local_signoff.sh" \
        FULL_VALIDATION_SES_READINESS_SCRIPT="$tmp_dir/mock_ses.sh" \
        FULL_VALIDATION_STAGING_BILLING_REHEARSAL_SCRIPT="$tmp_dir/mock_billing.sh" \
        FULL_VALIDATION_BROWSER_PREFLIGHT_SCRIPT="$tmp_dir/mock_browser_preflight.sh" \
        FULL_VALIDATION_PLAYWRIGHT_BIN="$tmp_dir/mock_playwright_auth_setup.sh" \
        FULL_VALIDATION_PLAYWRIGHT_WEB_DIR="$tmp_dir/web" \
        FULL_VALIDATION_WEB_RUNTIME_REPO_ROOT="$tmp_dir" \
        FULL_VALIDATION_TERRAFORM_STAGE7_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage7.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE8_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage8.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE7_RUNTIME_SMOKE_SCRIPT="$tmp_dir/mock_runtime_smoke.sh" \
        FULL_VALIDATION_SES_INBOUND_ROUNDTRIP_SCRIPT="$tmp_dir/mock_ses_inbound_roundtrip.sh" \
        FULL_VALIDATION_CANARY_CUSTOMER_LOOP_SCRIPT="$tmp_dir/mock_canary_customer_loop.sh" \
        bash "$ORCH_SCRIPT" --paid-beta-rc --sha=aabbccddee00112233445566778899aabbccddee --billing-month=2026-03
    local auth_setup_args
    auth_setup_args="$(cat "$auth_setup_invocation" 2>/dev/null || true)"
    rm -rf "$tmp_dir"
    assert_eq "$RUN_EXIT_CODE" "1" "paid-beta-rc should stay non-ready when later prerequisites are missing"
    assert_eq "$(json_step_status "$RUN_STDOUT" "local_signoff")" "skipped" "paid-beta-rc should skip local_signoff when local prerequisites are not applicable"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "local_signoff")" "local_signoff_not_applicable_in_paid_beta_rc_mode" "paid-beta-rc local_signoff skip should use deterministic mode reason"
    assert_eq "$(json_step_status "$RUN_STDOUT" "browser_auth_setup")" "pass" "paid-beta-rc local-signoff regression should use mocked browser auth setup"
    assert_contains "$auth_setup_args" "cwd=$tmp_dir/web args=playwright test -c playwright.config.ts tests/fixtures/auth.setup.ts tests/fixtures/admin.auth.setup.ts --project=setup:user --project=setup:admin --reporter=line" "paid-beta-rc local-signoff regression should not invoke host Playwright auth setup"
    assert_eq "$(json_step_status "$RUN_STDOUT" "ses_readiness")" "external_secret_missing" "ses_readiness should still classify its own missing identity gap"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "ses_readiness")" "credentialed_ses_identity_missing" "ses_readiness should preserve its missing identity reason"
    assert_eq "$(json_step_status "$RUN_STDOUT" "staging_billing_rehearsal")" "external_secret_missing" "staging_billing_rehearsal should still classify its own missing env file gap"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "staging_billing_rehearsal")" "credentialed_billing_env_file_missing" "staging_billing_rehearsal should preserve its missing env file reason"
}
test_paid_beta_rc_browser_lane_env_file_parse_failure_is_structured() {
    local tmp_dir credential_env_file artifact_dir
    tmp_dir="$(mktemp -d)"
    credential_env_file="$tmp_dir/credentials.env"
    artifact_dir="$tmp_dir/artifacts"
    cat > "$credential_env_file" <<'EOF'
SES_FROM_ADDRESS=beta@example.com
SES_REGION=us-east-1
AWS_ACCESS_KEY_ID=credential_file_access_key
not shell syntax
AWS_DEFAULT_REGION=us-east-2
EOF
    mkdir -p "$tmp_dir/bin"
    write_mock_script "$tmp_dir/mock_cargo.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_backend_gate.sh" 'echo "{\"verdict\":\"pass\"}"; exit 0'
    write_mock_script "$tmp_dir/mock_local_signoff.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_ses.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_billing.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_browser_preflight.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_tf_static_stage7.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_tf_static_stage8.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_runtime_smoke.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_ses_inbound_roundtrip.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_canary_customer_loop.sh" 'exit 0'
    write_mock_script "$tmp_dir/bin/npx" 'exit 0'
    write_mock_script "$tmp_dir/mock_browser_lane.sh" '
echo "browser lane should not run when credential env syntax is invalid" >&2
exit 94'
    write_mock_web_playwright_runtime "$tmp_dir"
    run_orchestrator env \
        -u AWS_ACCESS_KEY_ID \
        -u AWS_SECRET_ACCESS_KEY \
        -u AWS_DEFAULT_REGION \
        PATH="$tmp_dir/bin:$PATH" \
        FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
        FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
        FULL_VALIDATION_LOCAL_SIGNOFF_SCRIPT="$tmp_dir/mock_local_signoff.sh" \
        FULL_VALIDATION_SES_READINESS_SCRIPT="$tmp_dir/mock_ses.sh" \
        FULL_VALIDATION_STAGING_BILLING_REHEARSAL_SCRIPT="$tmp_dir/mock_billing.sh" \
        FULL_VALIDATION_BROWSER_PREFLIGHT_SCRIPT="$tmp_dir/mock_browser_preflight.sh" \
        FULL_VALIDATION_BROWSER_LANE_SCRIPT="$tmp_dir/mock_browser_lane.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE7_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage7.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE8_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage8.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE7_RUNTIME_SMOKE_SCRIPT="$tmp_dir/mock_runtime_smoke.sh" \
        FULL_VALIDATION_SES_INBOUND_ROUNDTRIP_SCRIPT="$tmp_dir/mock_ses_inbound_roundtrip.sh" \
        FULL_VALIDATION_CANARY_CUSTOMER_LOOP_SCRIPT="$tmp_dir/mock_canary_customer_loop.sh" \
        FULL_VALIDATION_WEB_RUNTIME_REPO_ROOT="$tmp_dir" \
        bash "$ORCH_SCRIPT" --paid-beta-rc --sha=aabbccddee00112233445566778899aabbccddee \
            --credential-env-file="$credential_env_file" --billing-month=2026-03 --artifact-dir="$artifact_dir" \
            --staging-smoke-api-ami-id=ami-12345678 --staging-smoke-flapjack-ami-id=ami-87654321
    local summary_json signup_log portal_log
    summary_json="$(cat "$artifact_dir/summary.json" 2>/dev/null || true)"
    signup_log="$(cat "$artifact_dir/browser_signup_paid.log" 2>/dev/null || true)"
    portal_log="$(cat "$artifact_dir/browser_portal_cancel.log" 2>/dev/null || true)"
    rm -rf "$tmp_dir"
    assert_eq "$RUN_EXIT_CODE" "1" "malformed browser credential env file should fail readiness without aborting coordinator"
    assert_eq "$(python3 -m json.tool <<< "$RUN_STDOUT" >/dev/null 2>&1; echo $?)" "0" "malformed browser credential env file should still emit final JSON"
    assert_eq "$(normalize_json "$RUN_STDOUT")" "$(normalize_json "$summary_json")" "malformed browser credential env file should still write summary.json"
    assert_eq "$(json_step_status "$RUN_STDOUT" "browser_signup_paid")" "external_secret_missing" "browser_signup_paid parse failure should stay inside step result contract"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "browser_signup_paid")" "credentialed_browser_env_file_parse_failed" "browser_signup_paid parse failure should use deterministic reason"
    assert_eq "$(json_step_status "$RUN_STDOUT" "browser_portal_cancel")" "external_secret_missing" "browser_portal_cancel parse failure should stay inside step result contract"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "browser_portal_cancel")" "credentialed_browser_env_file_parse_failed" "browser_portal_cancel parse failure should use deterministic reason"
    assert_contains "$signup_log" "Unsupported syntax" "browser_signup_paid parse failure should be diagnosable from its step log"
    assert_contains "$portal_log" "Unsupported syntax" "browser_portal_cancel parse failure should be diagnosable from its step log"
    assert_not_contains "$RUN_STDERR" "Unsupported syntax" "browser env-file parse failure should not bypass final JSON through coordinator stderr"
}
test_paid_beta_rc_default_artifact_dir_is_browser_runner_compatible() {
    local tmp_dir credential_env_file invocation_log_file
    tmp_dir="$(mktemp -d)"
    credential_env_file="$tmp_dir/credentials.env"
    invocation_log_file="$tmp_dir/invocations.log"
    cat > "$credential_env_file" <<'EOF'
SES_FROM_ADDRESS=beta@example.com
SES_REGION=us-east-1
FLAPJACK_ADMIN_KEY=file_admin_key
STRIPE_TEST_SECRET_KEY=sk_test_from_file
AWS_ACCESS_KEY_ID=credential_file_access_key
AWS_SECRET_ACCESS_KEY=credential_file_secret_key
AWS_DEFAULT_REGION=us-east-2
EOF
    mkdir -p "$tmp_dir/bin"
    write_mock_script "$tmp_dir/mock_cargo.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_backend_gate.sh" 'echo "{\"verdict\":\"pass\"}"; exit 0'
    local pass_mock
    for pass_mock in local_signoff ses billing browser_preflight tf_static_stage7 tf_static_stage8 runtime_smoke ses_inbound_roundtrip canary_customer_loop; do
        write_mock_script "$tmp_dir/mock_${pass_mock}.sh" 'exit 0'
    done
    write_mock_script "$tmp_dir/bin/npx" 'exit 0'
    write_mock_script "$tmp_dir/mock_browser_lane.sh" '
evidence_dir=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --evidence-dir)
            evidence_dir="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
repo_root="$(pwd)"
case "$evidence_dir" in
    "$repo_root" | "$repo_root"/*) ;;
    *)
        echo "ERROR: evidence dir must stay within repo root: $repo_root" >&2
        exit 88
        ;;
esac
printf "browser_lane|%s|%s\n" "$PWD" "$evidence_dir" >> "${INVOCATION_LOG_FILE:?}"
exit 0'
    write_mock_web_playwright_runtime "$tmp_dir"
    run_orchestrator env \
        -u AWS_ACCESS_KEY_ID \
        -u AWS_SECRET_ACCESS_KEY \
        -u AWS_DEFAULT_REGION \
        PATH="$tmp_dir/bin:$PATH" \
        INVOCATION_LOG_FILE="$invocation_log_file" \
        FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
        FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
        FULL_VALIDATION_LOCAL_SIGNOFF_SCRIPT="$tmp_dir/mock_local_signoff.sh" \
        FULL_VALIDATION_SES_READINESS_SCRIPT="$tmp_dir/mock_ses.sh" \
        FULL_VALIDATION_STAGING_BILLING_REHEARSAL_SCRIPT="$tmp_dir/mock_billing.sh" \
        FULL_VALIDATION_BROWSER_PREFLIGHT_SCRIPT="$tmp_dir/mock_browser_preflight.sh" \
        FULL_VALIDATION_BROWSER_LANE_SCRIPT="$tmp_dir/mock_browser_lane.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE7_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage7.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE8_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage8.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE7_RUNTIME_SMOKE_SCRIPT="$tmp_dir/mock_runtime_smoke.sh" \
        FULL_VALIDATION_SES_INBOUND_ROUNDTRIP_SCRIPT="$tmp_dir/mock_ses_inbound_roundtrip.sh" \
        FULL_VALIDATION_CANARY_CUSTOMER_LOOP_SCRIPT="$tmp_dir/mock_canary_customer_loop.sh" \
        FULL_VALIDATION_WEB_RUNTIME_REPO_ROOT="$tmp_dir" \
        bash "$ORCH_SCRIPT" --paid-beta-rc --sha=aabbccddee00112233445566778899aabbccddee \
            --credential-env-file="$credential_env_file" --billing-month=2026-03 \
            --staging-smoke-api-ami-id=ami-12345678 --staging-smoke-flapjack-ami-id=ami-87654321
    local invocation_log
    invocation_log="$(cat "$invocation_log_file" 2>/dev/null || true)"
    rm -rf "$tmp_dir"
    assert_eq "$(json_step_status "$RUN_STDOUT" "browser_signup_paid")" "pass" "default paid-beta-rc artifact dir should satisfy browser_signup_paid evidence contract"
    assert_eq "$(json_step_status "$RUN_STDOUT" "browser_portal_cancel")" "pass" "default paid-beta-rc artifact dir should satisfy browser_portal_cancel evidence contract"
    assert_contains "$invocation_log" "$REPO_ROOT/.local/paid_beta_rc_artifacts/" "default paid-beta-rc browser evidence should stay under repo-owned local artifacts"
    assert_not_contains "$RUN_STDERR" "evidence dir must stay within repo root" "default paid-beta-rc browser lane should not trip repo-owned evidence guard"
}
test_paid_beta_rc_browser_auth_setup_missing_runtime_is_env_gap() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local credential_env_file artifact_dir invocation_log_file npx_counter
    credential_env_file="$tmp_dir/credentials.env"
    artifact_dir="$tmp_dir/artifacts"
    invocation_log_file="$tmp_dir/invocations.log"
    npx_counter="$tmp_dir/npx_counter.txt"
    cat > "$credential_env_file" <<'EOF'
SES_FROM_ADDRESS=beta@example.com
SES_REGION=us-east-1
FLAPJACK_ADMIN_KEY=file_admin_key
STRIPE_TEST_SECRET_KEY=sk_test_from_file
EOF
    mkdir -p "$tmp_dir/bin"
    write_mock_script "$tmp_dir/mock_cargo.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_backend_gate.sh" 'echo "{\"verdict\":\"pass\"}"; exit 0'
    write_mock_script "$tmp_dir/mock_local_signoff.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_ses.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_billing.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_browser_preflight.sh" '
printf "browser_preflight|%s|%s\n" "$PWD" "$*" >> "${INVOCATION_LOG_FILE:?}"
exit 0'
    write_mock_script "$tmp_dir/mock_tf_static_stage7.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_tf_static_stage8.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_runtime_smoke.sh" 'exit 0'
    write_mock_script "$tmp_dir/bin/npx" '
printf "called\n" >> "${NPX_COUNTER:?}"
exit 0'
    run_orchestrator env \
        PATH="$tmp_dir/bin:$PATH" \
        INVOCATION_LOG_FILE="$invocation_log_file" \
        NPX_COUNTER="$npx_counter" \
        FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
        FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
        FULL_VALIDATION_LOCAL_SIGNOFF_SCRIPT="$tmp_dir/mock_local_signoff.sh" \
        FULL_VALIDATION_SES_READINESS_SCRIPT="$tmp_dir/mock_ses.sh" \
        FULL_VALIDATION_STAGING_BILLING_REHEARSAL_SCRIPT="$tmp_dir/mock_billing.sh" \
        FULL_VALIDATION_BROWSER_PREFLIGHT_SCRIPT="$tmp_dir/mock_browser_preflight.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE7_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage7.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE8_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage8.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE7_RUNTIME_SMOKE_SCRIPT="$tmp_dir/mock_runtime_smoke.sh" \
        FULL_VALIDATION_WEB_RUNTIME_REPO_ROOT="$tmp_dir" \
        bash "$ORCH_SCRIPT" --paid-beta-rc --staging-only --sha=aabbccddee00112233445566778899aabbccddee \
            --credential-env-file="$credential_env_file" --billing-month=2026-03 --artifact-dir="$artifact_dir" \
            --staging-smoke-api-ami-id=ami-12345678 --staging-smoke-flapjack-ami-id=ami-87654321
    local auth_log npx_calls
    auth_log="$(cat "$artifact_dir/browser_auth_setup.log" 2>/dev/null || true)"
    npx_calls="$(cat "$npx_counter" 2>/dev/null || true)"
    rm -rf "$tmp_dir"
    assert_eq "$RUN_EXIT_CODE" "1" "missing browser auth runtime should keep paid-beta-rc non-ready"
    assert_eq "$(json_step_status "$RUN_STDOUT" "browser_auth_setup")" "external_secret_missing" "missing browser auth runtime should be classified as harness env gap"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "browser_auth_setup")" "browser_auth_setup_env_gap" "missing browser auth runtime should use deterministic env-gap reason"
    assert_contains "$auth_log" "web/node_modules/@playwright/test/package.json is missing" "browser auth log should include shared local-runtime install hint"
    assert_eq "$npx_calls" "" "browser auth setup should not invoke npx when local Playwright runtime is absent"
}
test_paid_beta_rc_browser_auth_setup_loopback_contract_stays_fail() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local credential_env_file artifact_dir auth_log summary_json
    credential_env_file="$tmp_dir/credentials.env"
    artifact_dir="$tmp_dir/artifacts"
    cat > "$credential_env_file" <<'EOF'
SES_FROM_ADDRESS=beta@example.com
SES_REGION=us-east-1
FLAPJACK_ADMIN_KEY=file_admin_key
STRIPE_TEST_SECRET_KEY=sk_test_from_file
EOF
    mkdir -p "$tmp_dir/bin"
    write_mock_script "$tmp_dir/mock_cargo.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_backend_gate.sh" 'echo "{\"verdict\":\"pass\"}"; exit 0'
    write_mock_script "$tmp_dir/mock_local_signoff.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_ses.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_billing.sh" 'echo "{\"result\":\"passed\"}"; exit 0'
    write_mock_script "$tmp_dir/mock_browser_preflight.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_tf_static_stage7.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_tf_static_stage8.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_runtime_smoke.sh" 'exit 0'
    write_mock_script "$tmp_dir/bin/npx" '
echo "Error: API_URL must use a local loopback host (localhost, 127.0.0.1, or [::1]) for credentialed local browser runs" >&2
exit 1'
    write_mock_web_playwright_runtime "$tmp_dir"
    run_orchestrator env \
        PATH="$tmp_dir/bin:$PATH" \
        FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
        FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
        FULL_VALIDATION_LOCAL_SIGNOFF_SCRIPT="$tmp_dir/mock_local_signoff.sh" \
        FULL_VALIDATION_SES_READINESS_SCRIPT="$tmp_dir/mock_ses.sh" \
        FULL_VALIDATION_STAGING_BILLING_REHEARSAL_SCRIPT="$tmp_dir/mock_billing.sh" \
        FULL_VALIDATION_BROWSER_PREFLIGHT_SCRIPT="$tmp_dir/mock_browser_preflight.sh" \
        FULL_VALIDATION_PLAYWRIGHT_BIN="$tmp_dir/bin/npx" \
        FULL_VALIDATION_TERRAFORM_STAGE7_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage7.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE8_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage8.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE7_RUNTIME_SMOKE_SCRIPT="$tmp_dir/mock_runtime_smoke.sh" \
        FULL_VALIDATION_WEB_RUNTIME_REPO_ROOT="$tmp_dir" \
        bash "$ORCH_SCRIPT" --paid-beta-rc --staging-only --sha=aabbccddee00112233445566778899aabbccddee \
            --credential-env-file="$credential_env_file" --billing-month=2026-03 --artifact-dir="$artifact_dir" \
            --staging-smoke-api-ami-id=ami-12345678 --staging-smoke-flapjack-ami-id=ami-87654321
    auth_log="$(cat "$artifact_dir/browser_auth_setup.log" 2>/dev/null || true)"
    summary_json="$(cat "$artifact_dir/summary.json" 2>/dev/null || true)"
    rm -rf "$tmp_dir"
    assert_eq "$RUN_EXIT_CODE" "1" "loopback browser auth contract failure should keep paid-beta-rc non-ready"
    assert_eq "$(json_step_status "$RUN_STDOUT" "browser_auth_setup")" "fail" "loopback browser auth contract failure should stay fail"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "browser_auth_setup")" "browser_auth_setup_failed" "loopback browser auth contract failure should keep setup failure reason"
    assert_eq "$(json_step_status "$summary_json" "browser_auth_setup")" "fail" "summary.json should preserve loopback browser auth contract failure status"
    assert_eq "$(json_step_reason "$summary_json" "browser_auth_setup")" "browser_auth_setup_failed" "summary.json should preserve loopback browser auth setup reason"
    assert_contains "$auth_log" "API_URL must use a local loopback host" "browser auth log should keep the exact loopback contract error"
}
test_paid_beta_rc_staging_only_skips_production_surfaces() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local credential_env_file artifact_dir invocation_log_file backend_gate_args_file
    credential_env_file="$tmp_dir/credentials.env"
    artifact_dir="$tmp_dir/artifacts"
    invocation_log_file="$tmp_dir/invocations.log"
    backend_gate_args_file="$tmp_dir/backend_gate_args.txt"
    cat > "$credential_env_file" <<'EOF'
SES_FROM_ADDRESS=beta@example.com
SES_REGION=us-east-1
FLAPJACK_ADMIN_KEY=file_admin_key
STRIPE_TEST_SECRET_KEY=sk_test_from_file
EOF
    local ses_args_file billing_args_file staging_smoke_api_ami_id staging_smoke_flapjack_ami_id
    ses_args_file="$tmp_dir/ses_args.txt"
    billing_args_file="$tmp_dir/billing_args.txt"
    staging_smoke_api_ami_id="ami-12345678"
    staging_smoke_flapjack_ami_id="ami-87654321"
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
printf "%s\n" "$*" > "${BACKEND_GATE_ARGS_FILE:?}"
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
    # These fail hard if called; staging-only mode should skip them instead.
    write_mock_script "$tmp_dir/mock_ses_inbound_roundtrip.sh" 'exit 99'
    write_mock_script "$tmp_dir/mock_canary_customer_loop.sh" 'exit 99'
    write_mock_script "$tmp_dir/mock_outside_aws.sh" 'exit 99'
    write_mock_script "$tmp_dir/mock_browser_lane.sh" 'echo "browser lane should not run in staging-only mode" >&2; exit 99'
    write_mock_script "$tmp_dir/bin/npx" '
printf "browser_auth_setup|%s|%s|remote=%s\n" "$PWD" "$*" "${PLAYWRIGHT_TARGET_REMOTE:-}" >> "${INVOCATION_LOG_FILE:?}"
exit 0'
    write_mock_web_playwright_runtime "$tmp_dir"
    run_orchestrator env \
        SES_FROM_ADDRESS="" \
        SES_REGION="" \
        ADMIN_KEY="" \
        FLAPJACK_ADMIN_KEY="" \
        STRIPE_SECRET_KEY="" \
        STRIPE_TEST_SECRET_KEY="" \
        PATH="$tmp_dir/bin:$PATH" \
        BACKEND_GATE_ARGS_FILE="$backend_gate_args_file" \
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
        FULL_VALIDATION_BROWSER_LANE_SCRIPT="$tmp_dir/mock_browser_lane.sh" \
        FULL_VALIDATION_SES_INBOUND_ROUNDTRIP_SCRIPT="$tmp_dir/mock_ses_inbound_roundtrip.sh" \
        FULL_VALIDATION_CANARY_CUSTOMER_LOOP_SCRIPT="$tmp_dir/mock_canary_customer_loop.sh" \
        FULL_VALIDATION_OUTSIDE_AWS_HEALTH_SCRIPT="$tmp_dir/mock_outside_aws.sh" \
        FULL_VALIDATION_WEB_RUNTIME_REPO_ROOT="$tmp_dir" \
        bash "$ORCH_SCRIPT" --paid-beta-rc --staging-only --sha=aabbccddee00112233445566778899aabbccddee \
            --credential-env-file="$credential_env_file" --billing-month=2026-03 --artifact-dir="$artifact_dir" \
            --staging-smoke-api-ami-id="$staging_smoke_api_ami_id" \
            --staging-smoke-flapjack-ami-id="$staging_smoke_flapjack_ami_id"
    local backend_gate_args invocation_log
    backend_gate_args="$(cat "$backend_gate_args_file" 2>/dev/null || true)"
    invocation_log="$(cat "$invocation_log_file" 2>/dev/null || true)"
    rm -rf "$tmp_dir"
    assert_eq "$RUN_EXIT_CODE" "0" "paid-beta-rc staging-only should pass when staging proofs pass and production proofs are skipped"
    assert_json_bool_field "$RUN_STDOUT" "ready" "true" "paid-beta-rc staging-only should report ready=true when staging proofs pass"
    assert_json_field "$RUN_STDOUT" "verdict" "pass" "paid-beta-rc staging-only should report pass verdict when only production surfaces are skipped"
    assert_contains "$backend_gate_args" "--staging-only" "paid-beta-rc staging-only should forward staging-only flag to backend gate"
    assert_eq "$(json_step_status "$RUN_STDOUT" "staging_billing_rehearsal")" "pass" "staging-only mode should still run staging billing rehearsal"
    assert_eq "$(json_step_status "$RUN_STDOUT" "browser_preflight")" "pass" "staging-only mode should still run browser preflight"
    assert_eq "$(json_step_status "$RUN_STDOUT" "browser_auth_setup")" "pass" "staging-only mode should still run browser auth setup"
    assert_contains "$invocation_log" "browser_auth_setup|$REPO_ROOT/web|playwright test -c playwright.config.ts tests/fixtures/auth.setup.ts tests/fixtures/admin.auth.setup.ts --project=setup:user --project=setup:admin --reporter=line|remote=1" "staging-only auth setup should opt into allowlisted remote target mode"
    assert_eq "$(json_step_status "$RUN_STDOUT" "terraform_static_guardrails")" "pass" "staging-only mode should still run terraform static guardrails"
    assert_eq "$(json_step_status "$RUN_STDOUT" "staging_runtime_smoke")" "pass" "staging-only mode should still run staging runtime smoke"
    assert_eq "$(json_step_status "$RUN_STDOUT" "admin_broadcast")" "skipped" "staging-only mode should skip production admin broadcast proof"
    assert_eq "$(json_step_status "$RUN_STDOUT" "ses_inbound")" "skipped" "staging-only mode should skip production SES inbound proof"
    assert_eq "$(json_step_status "$RUN_STDOUT" "canary_customer_loop")" "skipped" "staging-only mode should skip production canary proof"
    assert_eq "$(json_step_status "$RUN_STDOUT" "canary_outside_aws")" "skipped" "staging-only mode should skip production outside-AWS canary proof"
    assert_eq "$(json_step_status "$RUN_STDOUT" "stripe_webhook_signature_matrix_idempotency")" "skipped" "staging-only mode should skip production webhook matrix proof"
    assert_eq "$(json_step_status "$RUN_STDOUT" "test_clock")" "skipped" "staging-only mode should skip production test_clock proof"
    assert_eq "$(json_step_status "$RUN_STDOUT" "browser_signup_paid")" "skipped" "staging-only mode should keep production signup browser proof skipped"
    assert_eq "$(json_step_status "$RUN_STDOUT" "browser_portal_cancel")" "skipped" "staging-only mode should keep production portal-cancel browser proof skipped"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "admin_broadcast")" "staging_only_production_surface" "staging-only skips should use deterministic coordinator reason code"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "browser_signup_paid")" "staging_only_production_surface" "staging-only browser signup skip should use deterministic coordinator reason code"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "browser_portal_cancel")" "staging_only_production_surface" "staging-only browser portal skip should use deterministic coordinator reason code"
    assert_eq "$(json_step_count "$RUN_STDOUT")" "22" "staging-only mode should preserve coordinator step cardinality"
    assert_contains "$invocation_log" "browser_preflight|$PWD|" "staging-only mode should still execute browser preflight"
    assert_contains "$invocation_log" "staging_runtime_smoke|$PWD|--env-file $credential_env_file --api-ami-id $staging_smoke_api_ami_id --flapjack-ami-id $staging_smoke_flapjack_ami_id --env staging" "staging-only mode should still execute runtime smoke with split AMI inputs"
    assert_not_contains "$invocation_log" "--ami-id" "staging-only runtime smoke delegation must not use removed single-AMI option"
    assert_not_contains "$RUN_STDERR" "browser lane should not run in staging-only mode" "staging-only mode must not invoke delegated production browser lane"
}
test_paid_beta_rc_browser_lane_env_gap_and_real_failure_classification() {
    local tmp_dir credential_env_file artifact_dir
    tmp_dir="$(mktemp -d)"
    credential_env_file="$tmp_dir/credentials.env"
    artifact_dir="$tmp_dir/artifacts"
    cat > "$credential_env_file" <<'EOF'
SES_FROM_ADDRESS=beta@example.com
SES_REGION=us-east-1
AWS_ACCESS_KEY_ID=credential_file_access_key
AWS_SECRET_ACCESS_KEY=credential_file_secret_key
AWS_DEFAULT_REGION=us-east-2
EOF
    mkdir -p "$tmp_dir/bin"
    write_mock_script "$tmp_dir/mock_cargo.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_backend_gate.sh" 'echo "{\"verdict\":\"pass\"}"; exit 0'
    write_mock_script "$tmp_dir/mock_local_signoff.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_ses.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_billing.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_browser_preflight.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_tf_static_stage7.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_tf_static_stage8.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_runtime_smoke.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_ses_inbound_roundtrip.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_canary_customer_loop.sh" 'exit 0'
    write_mock_script "$tmp_dir/bin/npx" 'exit 0'
    write_mock_web_playwright_runtime "$tmp_dir"

    write_mock_script "$tmp_dir/mock_browser_lane_env_gap.sh" '
echo "ERROR: ADMIN_KEY not hydrated from SSM" >&2
exit 86'
    run_orchestrator env \
        -u AWS_ACCESS_KEY_ID \
        -u AWS_SECRET_ACCESS_KEY \
        -u AWS_DEFAULT_REGION \
        PATH="$tmp_dir/bin:$PATH" \
        FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
        FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
        FULL_VALIDATION_LOCAL_SIGNOFF_SCRIPT="$tmp_dir/mock_local_signoff.sh" \
        FULL_VALIDATION_SES_READINESS_SCRIPT="$tmp_dir/mock_ses.sh" \
        FULL_VALIDATION_STAGING_BILLING_REHEARSAL_SCRIPT="$tmp_dir/mock_billing.sh" \
        FULL_VALIDATION_BROWSER_PREFLIGHT_SCRIPT="$tmp_dir/mock_browser_preflight.sh" \
        FULL_VALIDATION_BROWSER_LANE_SCRIPT="$tmp_dir/mock_browser_lane_env_gap.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE7_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage7.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE8_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage8.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE7_RUNTIME_SMOKE_SCRIPT="$tmp_dir/mock_runtime_smoke.sh" \
        FULL_VALIDATION_SES_INBOUND_ROUNDTRIP_SCRIPT="$tmp_dir/mock_ses_inbound_roundtrip.sh" \
        FULL_VALIDATION_CANARY_CUSTOMER_LOOP_SCRIPT="$tmp_dir/mock_canary_customer_loop.sh" \
        FULL_VALIDATION_WEB_RUNTIME_REPO_ROOT="$tmp_dir" \
        bash "$ORCH_SCRIPT" --paid-beta-rc --sha=aabbccddee00112233445566778899aabbccddee \
            --credential-env-file="$credential_env_file" --billing-month=2026-03 --artifact-dir="$artifact_dir" \
            --staging-smoke-api-ami-id=ami-12345678 --staging-smoke-flapjack-ami-id=ami-87654321
    assert_eq "$(json_step_status "$RUN_STDOUT" "browser_signup_paid")" "external_secret_missing" "browser_signup_paid should reclassify known browser env-gap fingerprints"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "browser_signup_paid")" "browser_signup_paid_env_gap" "browser_signup_paid should expose deterministic env-gap reason"
    assert_eq "$(json_step_status "$RUN_STDOUT" "browser_portal_cancel")" "external_secret_missing" "browser_portal_cancel should reclassify known browser env-gap fingerprints"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "browser_portal_cancel")" "browser_portal_cancel_env_gap" "browser_portal_cancel should expose deterministic env-gap reason"

    write_mock_script "$tmp_dir/mock_browser_lane_real_failure.sh" '
echo "checkout completed but invoice total was wrong" >&2
exit 87'
    run_orchestrator env \
        -u AWS_ACCESS_KEY_ID \
        -u AWS_SECRET_ACCESS_KEY \
        -u AWS_DEFAULT_REGION \
        PATH="$tmp_dir/bin:$PATH" \
        FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
        FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
        FULL_VALIDATION_LOCAL_SIGNOFF_SCRIPT="$tmp_dir/mock_local_signoff.sh" \
        FULL_VALIDATION_SES_READINESS_SCRIPT="$tmp_dir/mock_ses.sh" \
        FULL_VALIDATION_STAGING_BILLING_REHEARSAL_SCRIPT="$tmp_dir/mock_billing.sh" \
        FULL_VALIDATION_BROWSER_PREFLIGHT_SCRIPT="$tmp_dir/mock_browser_preflight.sh" \
        FULL_VALIDATION_BROWSER_LANE_SCRIPT="$tmp_dir/mock_browser_lane_real_failure.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE7_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage7.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE8_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage8.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE7_RUNTIME_SMOKE_SCRIPT="$tmp_dir/mock_runtime_smoke.sh" \
        FULL_VALIDATION_SES_INBOUND_ROUNDTRIP_SCRIPT="$tmp_dir/mock_ses_inbound_roundtrip.sh" \
        FULL_VALIDATION_CANARY_CUSTOMER_LOOP_SCRIPT="$tmp_dir/mock_canary_customer_loop.sh" \
        FULL_VALIDATION_WEB_RUNTIME_REPO_ROOT="$tmp_dir" \
        bash "$ORCH_SCRIPT" --paid-beta-rc --sha=aabbccddee00112233445566778899aabbccddee \
            --credential-env-file="$credential_env_file" --billing-month=2026-03 --artifact-dir="$artifact_dir" \
            --staging-smoke-api-ami-id=ami-12345678 --staging-smoke-flapjack-ami-id=ami-87654321
    rm -rf "$tmp_dir"
    assert_eq "$(json_step_status "$RUN_STDOUT" "browser_signup_paid")" "fail" "browser_signup_paid non-env browser defect should stay fail"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "browser_signup_paid")" "browser_signup_paid_failed" "browser_signup_paid real failure should keep fail reason"
    assert_eq "$(json_step_status "$RUN_STDOUT" "browser_portal_cancel")" "fail" "browser_portal_cancel non-env browser defect should stay fail"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "browser_portal_cancel")" "browser_portal_cancel_failed" "browser_portal_cancel real failure should keep fail reason"
}
test_paid_beta_rc_keeps_non_critical_skip_as_skipped() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local credential_env_file
    credential_env_file="$tmp_dir/credentials.env"
    cat > "$credential_env_file" <<'EOF'
SES_FROM_ADDRESS=beta@example.com
SES_REGION=us-east-1
EOF
    mkdir -p "$tmp_dir/bin"
    write_mock_script "$tmp_dir/mock_cargo.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_backend_gate.sh" 'echo "{\"verdict\":\"pass\"}"; exit 0'
    write_mock_script "$tmp_dir/mock_local_signoff.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_ses.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_billing.sh" 'echo "{\"result\":\"skipped\",\"classification\":\"operator_opt_out\"}"; exit 0'
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
            --credential-env-file="$credential_env_file" --billing-month=2026-03 --staging-smoke-api-ami-id=ami-12345678 --staging-smoke-flapjack-ami-id=ami-87654321
    rm -rf "$tmp_dir"
    assert_eq "$(json_step_status "$RUN_STDOUT" "staging_billing_rehearsal")" "skipped" "non-critical delegated skip should remain skipped"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "staging_billing_rehearsal")" "operator_opt_out" "non-critical delegated skip should preserve classification reason"
}
test_paid_beta_rc_promotes_critical_browser_skip_to_fail() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local credential_env_file
    credential_env_file="$tmp_dir/credentials.env"
    cat > "$credential_env_file" <<'EOF'
SES_FROM_ADDRESS=beta@example.com
SES_REGION=us-east-1
EOF
    mkdir -p "$tmp_dir/bin"
    write_mock_script "$tmp_dir/mock_cargo.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_backend_gate.sh" 'echo "{\"verdict\":\"pass\"}"; exit 0'
    write_mock_script "$tmp_dir/mock_local_signoff.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_ses.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_billing.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_browser_preflight.sh" 'exit 3'
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
            --credential-env-file="$credential_env_file" --billing-month=2026-03 --staging-smoke-api-ami-id=ami-12345678 --staging-smoke-flapjack-ami-id=ami-87654321
    rm -rf "$tmp_dir"
    assert_eq "$RUN_EXIT_CODE" "1" "critical browser skip should fail paid-beta-rc run"
    assert_eq "$(json_step_status "$RUN_STDOUT" "browser_preflight")" "fail" "critical browser skip should be promoted to fail"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "browser_preflight")" "critical_surface_skipped" "critical browser skip should expose a deterministic promoted reason"
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
            --credential-env-file="$credential_env_file" --billing-month=2026-03 --staging-smoke-api-ami-id=ami-12345678 --staging-smoke-flapjack-ami-id=ami-87654321
    after_count="$(find "$docs_evidence_dir" -maxdepth 1 -type f -name 'backend_gate_*.json' | wc -l | tr -d ' ')"
    rm -rf "$tmp_dir"
    assert_eq "$RUN_EXIT_CODE" "1" "paid-beta-rc should remain non-pass by default while Tier-1 critical surfaces are unproven"
    assert_eq "$before_count" "$after_count" "paid-beta-rc default artifact path should not create docs/launch/evidence backend files"
}
test_live_preflight_catches_all_missing_credentials() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    mkdir -p "$tmp_dir/bin"
    ln -sf /usr/bin/python3 "$tmp_dir/bin/python3"
    ln -sf /usr/bin/dirname "$tmp_dir/bin/dirname"
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
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    mkdir -p "$tmp_dir/bin"
    ln -sf /usr/bin/dirname "$tmp_dir/bin/dirname"
    run_orchestrator env \
        PATH="$tmp_dir/bin:/bin" \
        __RUN_FULL_BACKEND_VALIDATION_SOURCED=1 \
        ORCH_SCRIPT="$ORCH_SCRIPT" \
        bash -c '. "$ORCH_SCRIPT"'
    rm -rf "$tmp_dir"
    assert_eq "$RUN_EXIT_CODE" "0" "source-only mode should not require python3"
}
main() {
    echo "=== full_backend_validation tests ==="
    test_run_full_backend_validation_function_size_limit
    test_orchestrator_help_flag
    test_orchestrator_dry_run_produces_valid_json
    test_orchestrator_dry_run_sha_cli_pass_path
    test_orchestrator_fails_on_cargo_test_failure
    test_paid_beta_rc_writes_step_stderr_to_artifact_dir_on_cargo_failure
    test_cargo_workspace_step_does_not_inherit_db_url_from_parent_env
    test_orchestrator_fails_on_backend_gate_failure
    test_orchestrator_fails_on_backend_gate_invalid_json
    test_orchestrator_rejects_invalid_sha_argument
    test_orchestrator_rejects_invalid_billing_month_argument
    test_orchestrator_rejects_invalid_staging_smoke_ami_argument
    test_orchestrator_rejects_staging_only_without_paid_beta_rc
    test_orchestrator_rejects_staging_only_with_dry_run
    test_orchestrator_collects_all_results_even_on_failure
    test_paid_beta_rc_replaces_legacy_blocked_emissions
    test_paid_beta_rc_blocks_missing_credentialed_inputs
    test_paid_beta_rc_blocks_when_billing_month_missing
    test_paid_beta_rc_blocks_staging_runtime_smoke_without_opt_in_inputs
    test_paid_beta_rc_propagates_delegated_billing_live_evidence_gap
    test_paid_beta_rc_uses_shell_identity_when_credential_file_missing
    test_paid_beta_rc_pass_path_reports_ready_true
    test_paid_beta_rc_test_clock_rejects_live_key_before_delegation
    test_paid_beta_rc_test_clock_prefers_credential_file_test_alias_over_shell_live_key
    test_paid_beta_rc_local_signoff_prerequisite_gap_is_mode_skip
    test_paid_beta_rc_browser_lane_env_file_parse_failure_is_structured
    test_paid_beta_rc_default_artifact_dir_is_browser_runner_compatible
    test_paid_beta_rc_browser_auth_setup_missing_runtime_is_env_gap
    test_paid_beta_rc_browser_auth_setup_loopback_contract_stays_fail
    test_paid_beta_rc_staging_only_skips_production_surfaces
    test_paid_beta_rc_browser_lane_env_gap_and_real_failure_classification
    test_paid_beta_rc_keeps_non_critical_skip_as_skipped
    test_paid_beta_rc_promotes_critical_browser_skip_to_fail
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
