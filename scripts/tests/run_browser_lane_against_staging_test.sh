#!/usr/bin/env bash
# Contract tests for scripts/launch/run_browser_lane_against_staging.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/launch/run_browser_lane_against_staging.sh"

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
  "export API_URL=https://api.flapjack.foo" \
  "export STRIPE_SECRET_KEY=sk_test_staging_browser_contract" \
  "export STRIPE_WEBHOOK_SECRET=whsec_staging_browser_contract"
EOF
    chmod +x "$root/scripts/launch/hydrate_seeder_env_from_ssm.sh"
}

write_mock_hydrator_without_stripe() {
    local root="$1"
    mkdir -p "$root/scripts/launch"
    cat > "$root/scripts/launch/hydrate_seeder_env_from_ssm.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' \
  "export ADMIN_KEY=mock-admin-key" \
  "export API_URL=https://api.flapjack.foo"
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

init_test_repo() {
    local root="$1"
    git -C "$root" init >/dev/null 2>&1
    git -C "$root" config user.email "tests@example.com"
    git -C "$root" config user.name "Test Runner"
    echo "fixture" > "$root/README.md"
    git -C "$root" add README.md
    git -C "$root" commit -m "fixture commit" >/dev/null 2>&1
}

run_browser_lane_script() {
    local workspace="$1"
    local stdout_file="$workspace/stdout.txt"
    local stderr_file="$workspace/stderr.txt"
    local exit_code=0
    (
        cd "$workspace"
        env -i \
            HOME="$workspace" \
            PATH="$workspace/bin:/usr/bin:/bin:/usr/local/bin" \
            TEST_NPX_COUNTER_FILE="$workspace/npx_counter.txt" \
            BROWSER_LANE_TIMEOUT_SECONDS=1 \
            bash "$workspace/scripts/launch/run_browser_lane_against_staging.sh" \
                --lane both \
                --evidence-dir "$workspace/evidence"
    ) >"$stdout_file" 2>"$stderr_file" || exit_code=$?
    RUN_EXIT_CODE="$exit_code"
    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
}

test_both_lane_timeout_still_emits_both_lane_logs() {
    local workspace
    workspace="$(mktemp -d)"
    mkdir -p "$workspace/scripts/launch" "$workspace/web/tests/fixtures/.auth"
    cp "$TARGET_SCRIPT" "$workspace/scripts/launch/run_browser_lane_against_staging.sh"
    chmod +x "$workspace/scripts/launch/run_browser_lane_against_staging.sh"
    write_mock_hydrator_with_stripe "$workspace"
    write_mock_npx "$workspace"
    init_test_repo "$workspace"

    run_browser_lane_script "$workspace"

    local first_lane_log second_lane_log
    first_lane_log="$workspace/evidence/signup_to_paid_invoice.txt"
    second_lane_log="$workspace/evidence/billing_portal_payment_method_update.txt"
    local first_lane_content second_lane_content
    first_lane_content="$(cat "$first_lane_log" 2>/dev/null || true)"
    second_lane_content="$(cat "$second_lane_log" 2>/dev/null || true)"

    assert_eq "$RUN_EXIT_CODE" "124" "both-lane run should exit 124 when a lane times out"
    assert_file_exists "$first_lane_log" "signup lane log should be created even on timeout"
    assert_file_exists "$second_lane_log" "billing portal lane log should still be created after first-lane timeout"
    assert_contains "$first_lane_content" "timed out after 1s" "signup lane log should record deterministic timeout reason"
    assert_contains "$first_lane_content" "exit=124" "signup lane log should persist timeout exit code"
    assert_contains "$second_lane_content" "mock second lane executed" "second lane should execute after first-lane timeout"
    assert_contains "$second_lane_content" "exit=0" "second lane log should include its exit code"

    rm -rf "$workspace"
}

test_missing_stripe_contract_fails_closed_before_playwright() {
    local workspace
    workspace="$(mktemp -d)"
    mkdir -p "$workspace/scripts/launch" "$workspace/web/tests/fixtures/.auth"
    cp "$TARGET_SCRIPT" "$workspace/scripts/launch/run_browser_lane_against_staging.sh"
    chmod +x "$workspace/scripts/launch/run_browser_lane_against_staging.sh"
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

echo "=== run_browser_lane_against_staging contract tests ==="
test_both_lane_timeout_still_emits_both_lane_logs
test_missing_stripe_contract_fails_closed_before_playwright
echo "Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
if [ "$FAIL_COUNT" -ne 0 ]; then
    exit 1
fi
