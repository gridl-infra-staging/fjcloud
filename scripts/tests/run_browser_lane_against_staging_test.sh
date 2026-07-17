#!/usr/bin/env bash
# Contract tests for scripts/launch/run_browser_lane_against_staging.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/launch/run_browser_lane_against_staging.sh"
WEB_RUNTIME_LIB="$REPO_ROOT/scripts/lib/web_runtime.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "FAIL: $*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

assert_eq() {
    local actual="$1"
    local expected="$2"
    local message="$3"
    if [ "$actual" = "$expected" ]; then
        pass "$message"
    else
        fail "$message (expected='$expected' actual='$actual')"
    fi
}

assert_contains() {
    local actual="$1"
    local expected_substring="$2"
    local message="$3"
    if [[ "$actual" == *"$expected_substring"* ]]; then
        pass "$message"
    else
        fail "$message (missing substring '$expected_substring')"
    fi
}

assert_lt() {
    local actual="$1"
    local expected="$2"
    local message="$3"
    if [ "$actual" -lt "$expected" ]; then
        pass "$message"
    else
        fail "$message (expected <$expected actual=$actual)"
    fi
}

assert_not_contains() {
    local actual="$1"
    local forbidden_substring="$2"
    local message="$3"
    if [[ "$actual" != *"$forbidden_substring"* ]]; then
        pass "$message"
    else
        fail "$message (found forbidden substring '$forbidden_substring')"
    fi
}

assert_file_exists() {
    local path="$1"
    local message="$2"
    if [ -f "$path" ]; then
        pass "$message"
    else
        fail "$message (missing file: $path)"
    fi
}

write_mock_hydrator_with_stripe() {
    local root="$1"
    mkdir -p "$root/scripts/launch"
    cat > "$root/scripts/launch/hydrate_seeder_env_from_ssm.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' \
  "export ADMIN_KEY=mock-admin-key" \
  "export API_URL=https://api.staging.flapjack.foo" \
  "export STAGING_API_URL=https://api.staging.flapjack.foo" \
  "export STAGING_CLOUD_URL=https://cloud.staging.flapjack.foo" \
  "export SES_REGION=us-east-1" \
  "export STRIPE_SECRET_KEY=sk_test_staging_browser_contract" \
  "export STRIPE_WEBHOOK_SECRET=whsec_staging_browser_contract"
EOF
    chmod +x "$root/scripts/launch/hydrate_seeder_env_from_ssm.sh"
}

install_mock_playwright_test_runtime() {
    local root="$1"
    mkdir -p "$root/web/node_modules/@playwright/test"
    cat > "$root/web/node_modules/@playwright/test/package.json" <<'EOF'
{
  "name": "@playwright/test",
  "version": "0.0.0-test"
}
EOF
}

write_mock_hydrator_without_stripe() {
    local root="$1"
    mkdir -p "$root/scripts/launch"
    cat > "$root/scripts/launch/hydrate_seeder_env_from_ssm.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' \
  "export ADMIN_KEY=mock-admin-key" \
  "export API_URL=https://api.staging.flapjack.foo" \
  "export STAGING_API_URL=https://api.staging.flapjack.foo" \
  "export SES_REGION=us-east-1"
EOF
    chmod +x "$root/scripts/launch/hydrate_seeder_env_from_ssm.sh"
}

write_mock_npx() {
    local root="$1"
    mkdir -p "$root/bin"
    cat > "$root/bin/npx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
counter_file="${TEST_NPX_COUNTER_FILE:?}"
count=0
if [ -f "$counter_file" ]; then
    count="$(cat "$counter_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$counter_file"

if [ "$count" -eq 1 ]; then
    echo "mock first lane start"
    sleep 5
    echo "mock first lane finished"
    exit 0
fi

echo "mock second lane executed"
exit 0
EOF
    chmod +x "$root/bin/npx"
}

write_mock_npx_fail_fast() {
    local root="$1"
    mkdir -p "$root/bin"
    cat > "$root/bin/npx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "mock fast-fail lane"
exit 1
EOF
    chmod +x "$root/bin/npx"
}

write_mock_npx_with_trace_artifacts() {
    local root="$1"
    mkdir -p "$root/bin"
    cat > "$root/bin/npx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${TEST_NPX_ARGS_FILE:?}"

output_dir=""
previous=""
for arg in "$@"; do
    if [ "$previous" = "--output" ]; then
        output_dir="$arg"
        break
    fi
    previous="$arg"
done

if [ -z "$output_dir" ]; then
    output_dir="$PWD/test-results/default"
fi

mkdir -p "$output_dir"
printf 'trace artifact for %s\n' "$*" > "$output_dir/trace.zip"
printf 'screenshot artifact for %s\n' "$*" > "$output_dir/test-failed-1.png"
echo "mock trace artifacts created at $output_dir"
exit 0
EOF
    chmod +x "$root/bin/npx"
}

init_test_repo() {
    local root="$1"
    git -C "$root" init >/dev/null 2>&1
    git -C "$root" config user.email "tests@example.com"
    git -C "$root" config user.name "Test Runner"
    echo "fixture" > "$root/README.md"
    git -C "$root" add README.md
    git -C "$root" commit -m "fixture commit" >/dev/null 2>&1
}

setup_workspace_runner() {
    local workspace="$1"
    mkdir -p "$workspace/scripts/launch" "$workspace/scripts/lib"
    cp "$TARGET_SCRIPT" "$workspace/scripts/launch/run_browser_lane_against_staging.sh"
    cp "$WEB_RUNTIME_LIB" "$workspace/scripts/lib/web_runtime.sh"
    cp "$REPO_ROOT/scripts/lib/hydrate_staging_env.sh" "$workspace/scripts/lib/hydrate_staging_env.sh"
    chmod +x "$workspace/scripts/launch/run_browser_lane_against_staging.sh"
}

run_browser_lane_script() {
    local workspace="$1"
    local lane="${2:-both}"
    local stdout_file="$workspace/stdout.txt"
    local stderr_file="$workspace/stderr.txt"
    local exit_code=0
    (
        cd "$workspace"
        env -i \
            HOME="$workspace" \
            PATH="$workspace/bin:/usr/bin:/bin:/usr/local/bin" \
            TEST_NPX_COUNTER_FILE="$workspace/npx_counter.txt" \
            TEST_NPX_ARGS_FILE="$workspace/npx_args.txt" \
            BROWSER_LANE_TIMEOUT_SECONDS=1 \
            bash "$workspace/scripts/launch/run_browser_lane_against_staging.sh" \
                --lane "$lane" \
                --evidence-dir "$workspace/evidence"
    ) >"$stdout_file" 2>"$stderr_file" || exit_code=$?
    RUN_EXIT_CODE="$exit_code"
    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
}

run_browser_lane_script_with_pipe_capture() {
    local workspace="$1"
    local stdout_file="$workspace/piped_stdout.txt"
    local stderr_file="$workspace/piped_stderr.txt"
    local exit_code=0
    local start_seconds="$SECONDS"
    set +e
    (
        cd "$workspace"
        env -i \
            HOME="$workspace" \
            PATH="$workspace/bin:/usr/bin:/bin:/usr/local/bin" \
            BROWSER_LANE_TIMEOUT_SECONDS=4 \
            bash "$workspace/scripts/launch/run_browser_lane_against_staging.sh" \
                --lane signup_to_paid_invoice \
                --evidence-dir "$workspace/evidence" \
                2>&1 | cat
    ) >"$stdout_file" 2>"$stderr_file"
    exit_code=$?
    set -e

    RUN_EXIT_CODE="$exit_code"
    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
    RUN_ELAPSED_SECONDS="$((SECONDS - start_seconds))"
}

test_both_lane_timeout_still_emits_both_lane_logs() {
    local workspace
    workspace="$(mktemp -d)"
    mkdir -p "$workspace/web/tests/fixtures/.auth"
    setup_workspace_runner "$workspace"
    install_mock_playwright_test_runtime "$workspace"
    write_mock_hydrator_with_stripe "$workspace"
    write_mock_npx "$workspace"
    init_test_repo "$workspace"

    run_browser_lane_script "$workspace"

    local first_lane_log second_lane_log
    first_lane_log="$workspace/evidence/signup_to_paid_invoice.txt"
    second_lane_log="$workspace/evidence/billing_portal_payment_method_update.txt"
    local first_lane_content second_lane_content summary_content
    first_lane_content="$(cat "$first_lane_log" 2>/dev/null || true)"
    second_lane_content="$(cat "$second_lane_log" 2>/dev/null || true)"
    summary_content="$(cat "$workspace/evidence/SUMMARY.md" 2>/dev/null || true)"

    assert_eq "$RUN_EXIT_CODE" "124" "both-lane run should exit 124 when a lane times out"
    assert_file_exists "$first_lane_log" "signup lane log should be created even on timeout"
    assert_file_exists "$second_lane_log" "billing portal lane log should still be created after first-lane timeout"
    assert_contains "$first_lane_content" "timed out after 1s" "signup lane log should record deterministic timeout reason"
    assert_contains "$first_lane_content" "exit=124" "signup lane log should persist timeout exit code"
    assert_contains "$second_lane_content" "mock second lane executed" "second lane should execute after first-lane timeout"
    assert_contains "$second_lane_content" "exit=0" "second lane log should include its exit code"
    assert_contains "$summary_content" "- **API_URL:** https://api.staging.flapjack.foo" "summary should reflect hydrated staging API_URL without prod-host override"
    assert_contains "$summary_content" "- **BASE_URL:** https://cloud.staging.flapjack.foo" "summary should reflect hydrated STAGING_CLOUD_URL instead of prod cloud host"

    rm -rf "$workspace"
}

test_launcher_copies_trace_artifacts_into_evidence_bundle() {
    local workspace
    workspace="$(mktemp -d)"
    mkdir -p "$workspace/web/tests/fixtures/.auth"
    setup_workspace_runner "$workspace"
    install_mock_playwright_test_runtime "$workspace"
    write_mock_hydrator_with_stripe "$workspace"
    write_mock_npx_with_trace_artifacts "$workspace"
    init_test_repo "$workspace"

    run_browser_lane_script "$workspace"

    local sentinel_path trace_root sentinel_content
    sentinel_path="$workspace/evidence/trace_copy_summary.json"
    trace_root="$workspace/evidence/playwright-traces"
    sentinel_content="$(cat "$sentinel_path" 2>/dev/null || true)"

    assert_eq "$RUN_EXIT_CODE" "0" "trace artifact fixture run should exit 0"
    assert_file_exists "$sentinel_path" "launcher should emit machine-readable trace copy sentinel"
    assert_file_exists "$trace_root/signup_to_paid_invoice/trace.zip" "signup lane trace should be copied into evidence bundle"
    assert_file_exists "$trace_root/billing_portal_payment_method_update/trace.zip" "billing lane trace should be copied into evidence bundle"
    assert_contains "$sentinel_content" "\"trace_files_copied\": 4" "sentinel should report number of copied trace artifacts"
    assert_contains "$sentinel_content" "\"source_directories\": [" "sentinel should record inspected source directories"

    rm -rf "$workspace"
}

test_launcher_requests_deterministic_trace_and_lane_output() {
    local workspace
    workspace="$(mktemp -d)"
    mkdir -p "$workspace/web/tests/fixtures/.auth"
    setup_workspace_runner "$workspace"
    install_mock_playwright_test_runtime "$workspace"
    write_mock_hydrator_with_stripe "$workspace"
    write_mock_npx_with_trace_artifacts "$workspace"
    init_test_repo "$workspace"

    run_browser_lane_script "$workspace"

    local npx_args
    npx_args="$(cat "$workspace/npx_args.txt" 2>/dev/null || true)"
    assert_contains "$npx_args" "--trace on" "launcher should request deterministic trace capture in run_one_lane"
    assert_contains "$npx_args" "--output test-results/signup_to_paid_invoice" "signup lane should use deterministic lane-scoped output directory"
    assert_contains "$npx_args" "--output test-results/billing_portal_payment_method_update" "billing lane should use deterministic lane-scoped output directory"

    rm -rf "$workspace"
}

test_single_lane_run_excludes_stale_opposite_lane_trace_artifacts() {
    local workspace
    workspace="$(mktemp -d)"
    mkdir -p "$workspace/web/tests/fixtures/.auth"
    setup_workspace_runner "$workspace"
    install_mock_playwright_test_runtime "$workspace"
    write_mock_hydrator_with_stripe "$workspace"
    write_mock_npx_with_trace_artifacts "$workspace"
    init_test_repo "$workspace"

    mkdir -p "$workspace/web/test-results/billing_portal_payment_method_update/stale"
    printf 'stale billing lane artifact\n' > "$workspace/web/test-results/billing_portal_payment_method_update/stale/trace.zip"

    run_browser_lane_script "$workspace" "signup_to_paid_invoice"

    local sentinel_path sentinel_content
    sentinel_path="$workspace/evidence/trace_copy_summary.json"
    sentinel_content="$(cat "$sentinel_path" 2>/dev/null || true)"

    assert_eq "$RUN_EXIT_CODE" "0" "single-lane trace fixture run should exit 0"
    assert_file_exists "$workspace/evidence/playwright-traces/signup_to_paid_invoice/trace.zip" "single-lane run should still copy active lane traces"
    if [ -e "$workspace/evidence/playwright-traces/billing_portal_payment_method_update/stale/trace.zip" ]; then
        fail "single-lane run must not copy stale opposite-lane traces from previous runs"
    else
        pass "single-lane run excludes stale opposite-lane traces"
    fi
    assert_contains "$sentinel_content" "\"trace_files_copied\": 2" "single-lane sentinel should only count copied files from the requested lane"

    rm -rf "$workspace"
}

test_missing_stripe_contract_fails_closed_before_playwright() {
    local workspace
    workspace="$(mktemp -d)"
    mkdir -p "$workspace/web/tests/fixtures/.auth"
    setup_workspace_runner "$workspace"
    install_mock_playwright_test_runtime "$workspace"
    write_mock_hydrator_without_stripe "$workspace"
    write_mock_npx "$workspace"
    init_test_repo "$workspace"

    run_browser_lane_script "$workspace"

    assert_eq "$RUN_EXIT_CODE" "1" "run should fail closed when hydrator omits Stripe contract values"
    assert_contains "$RUN_STDERR" "ERROR: STRIPE_SECRET_KEY not hydrated from SSM" "missing Stripe key should fail with explicit owner message"

    local npx_counter
    npx_counter="$(cat "$workspace/npx_counter.txt" 2>/dev/null || true)"
    assert_eq "$npx_counter" "" "playwright should not run when Stripe contract hydration fails"

    rm -rf "$workspace"
}

test_evidence_dir_outside_repo_is_rejected() {
    local workspace outside_dir
    workspace="$(mktemp -d)"
    outside_dir="$(mktemp -d)"
    mkdir -p "$workspace/web/tests/fixtures/.auth"
    setup_workspace_runner "$workspace"
    install_mock_playwright_test_runtime "$workspace"
    write_mock_hydrator_with_stripe "$workspace"
    write_mock_npx_with_trace_artifacts "$workspace"
    init_test_repo "$workspace"

    local stdout_file="$workspace/outside_stdout.txt"
    local stderr_file="$workspace/outside_stderr.txt"
    local exit_code=0
    (
        cd "$workspace"
        env -i \
            HOME="$workspace" \
            PATH="$workspace/bin:/usr/bin:/bin:/usr/local/bin" \
            TEST_NPX_COUNTER_FILE="$workspace/npx_counter.txt" \
            TEST_NPX_ARGS_FILE="$workspace/npx_args.txt" \
            BROWSER_LANE_TIMEOUT_SECONDS=1 \
            bash "$workspace/scripts/launch/run_browser_lane_against_staging.sh" \
                --lane signup_to_paid_invoice \
                --evidence-dir "$outside_dir/outside-evidence"
    ) >"$stdout_file" 2>"$stderr_file" || exit_code=$?

    RUN_EXIT_CODE="$exit_code"
    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"

    assert_eq "$RUN_EXIT_CODE" "1" "launcher rejects evidence dirs outside repo root"
    assert_contains "$RUN_STDERR" "evidence dir must stay within repo root" "launcher explains repo-owned evidence-dir requirement"

    rm -rf "$workspace" "$outside_dir"
}

test_watchdog_does_not_delay_piped_execution_after_fast_failure() {
    local workspace
    workspace="$(mktemp -d)"
    mkdir -p "$workspace/web/tests/fixtures/.auth"
    setup_workspace_runner "$workspace"
    install_mock_playwright_test_runtime "$workspace"
    write_mock_hydrator_with_stripe "$workspace"
    write_mock_npx_fail_fast "$workspace"
    init_test_repo "$workspace"

    run_browser_lane_script_with_pipe_capture "$workspace"

    assert_eq "$RUN_EXIT_CODE" "1" "piped run should return lane failure exit code"
    assert_contains "$RUN_STDOUT" "Evidence bundle:" "piped run should still print evidence bundle location"
    assert_lt "$RUN_ELAPSED_SECONDS" "4" "piped run should not wait for watchdog timeout window after fast lane failure"

    rm -rf "$workspace"
}

test_missing_playwright_runtime_fails_closed_before_npx() {
    local workspace
    workspace="$(mktemp -d)"
    mkdir -p "$workspace/web/tests/fixtures/.auth"
    setup_workspace_runner "$workspace"
    write_mock_hydrator_with_stripe "$workspace"
    write_mock_npx "$workspace"
    init_test_repo "$workspace"

    run_browser_lane_script "$workspace"

    assert_eq "$RUN_EXIT_CODE" "1" "run should fail closed when local @playwright/test runtime is missing"
    assert_contains "$RUN_STDERR" "web/node_modules/@playwright/test/package.json is missing" "missing local playwright runtime should report owner-path error"

    local npx_counter
    npx_counter="$(cat "$workspace/npx_counter.txt" 2>/dev/null || true)"
    assert_eq "$npx_counter" "" "playwright should not run when local @playwright/test runtime is missing"

    rm -rf "$workspace"
}

test_evidence_artifacts_use_relative_paths() {
    local workspace
    workspace="$(mktemp -d)"
    mkdir -p "$workspace/web/tests/fixtures/.auth"
    setup_workspace_runner "$workspace"
    install_mock_playwright_test_runtime "$workspace"
    write_mock_hydrator_with_stripe "$workspace"
    write_mock_npx_with_trace_artifacts "$workspace"
    init_test_repo "$workspace"

    run_browser_lane_script "$workspace"

    local sentinel_path sentinel_content
    sentinel_path="$workspace/evidence/trace_copy_summary.json"
    sentinel_content="$(cat "$sentinel_path" 2>/dev/null || true)"

    assert_eq "$RUN_EXIT_CODE" "0" "evidence path fixture run should exit 0"
    assert_not_contains "$sentinel_content" "$workspace" "trace_copy_summary.json must not contain workspace-absolute paths"
    assert_contains "$sentinel_content" "\"web/test-results/" "trace_copy_summary.json should contain repo-relative source directories"

    local signup_log billing_log
    signup_log="$(cat "$workspace/evidence/signup_to_paid_invoice.txt" 2>/dev/null || true)"
    billing_log="$(cat "$workspace/evidence/billing_portal_payment_method_update.txt" 2>/dev/null || true)"
    assert_not_contains "$signup_log" "$workspace" "signup lane stdout must not contain workspace-absolute paths"
    assert_not_contains "$billing_log" "$workspace" "billing lane stdout must not contain workspace-absolute paths"

    rm -rf "$workspace"
}

test_default_lane_timeout_fails_closed_contract() {
    local launcher_source
    launcher_source="$(cat "$TARGET_SCRIPT")"
    assert_contains "$launcher_source" "BROWSER_LANE_TIMEOUT_SECONDS:-480" "default lane timeout should fail closed at 480 seconds for deterministic non-terminal stall handling"
}

echo "=== run_browser_lane_against_staging contract tests ==="
test_both_lane_timeout_still_emits_both_lane_logs
test_launcher_copies_trace_artifacts_into_evidence_bundle
test_launcher_requests_deterministic_trace_and_lane_output
test_single_lane_run_excludes_stale_opposite_lane_trace_artifacts
test_missing_stripe_contract_fails_closed_before_playwright
test_evidence_dir_outside_repo_is_rejected
test_watchdog_does_not_delay_piped_execution_after_fast_failure
test_missing_playwright_runtime_fails_closed_before_npx
test_evidence_artifacts_use_relative_paths
test_default_lane_timeout_fails_closed_contract
echo "Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
if [ "$FAIL_COUNT" -ne 0 ]; then
    exit 1
fi
