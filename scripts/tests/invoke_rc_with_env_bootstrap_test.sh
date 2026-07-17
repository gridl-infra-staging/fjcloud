#!/usr/bin/env bash
# Red-first contract tests for the web/node_modules bootstrap added to
# scripts/launch/invoke_rc_with_env.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/launch/invoke_rc_with_env.sh"

# shellcheck source=lib/invoke_rc_with_env_harness.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/invoke_rc_with_env_harness.sh"

install_empty_web_dir_without_vite() {
    # The wrapper's bootstrap runs `cd "$REPO_ROOT/web"`; the directory must
    # exist for the `cd` to succeed even though node_modules is intentionally
    # absent so the install path is exercised.
    mkdir -p "$TEST_WORKSPACE/web"
}

override_npm_mock_to_succeed() {
    # The shared mock exits 99 to trip set -euo pipefail and surface stray
    # tool invocations. The install-triggered bootstrap test needs a benign
    # npm that succeeds so main() proceeds past bootstrap and the assertions
    # can read TEST_CALL_LOG.
    write_mock_command "$TEST_WORKSPACE/bin/npm" "npm" 0
}

invoke_rc_with_env_after_setup() {
    install_successful_wrapper_preflight_stubs
}

call_log_contains_npm_ci() {
    grep -Fx 'npm|ci --no-audit --no-fund' "$TEST_CALL_LOG" >/dev/null 2>&1
}

call_log_has_any_npm_entry() {
    grep -E '^npm\|' "$TEST_CALL_LOG" >/dev/null 2>&1
}

valid_section1_manifest_arg() {
    local manifest_path="$TEST_WORKSPACE/section1_bundle/manifest.json"
    write_section1_manifest "$manifest_path" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "2026-06"
    printf '%s\n' "--section1-manifest=$manifest_path"
}

test_missing_vite_triggers_npm_ci_bootstrap() {
    setup_workspace
    install_empty_web_dir_without_vite
    override_npm_mock_to_succeed

    local credential_file="$TEST_WORKSPACE/inputs/credentials.env"
    write_safe_credentials_env "$credential_file"

    _run_facade --dry-run \
        --sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        --artifact-dir="$TEST_WORKSPACE/artifacts" \
        --credential-env-file="$credential_file" \
        --billing-month=2026-06 \
        "$(valid_section1_manifest_arg)" \
        --staging-smoke-api-ami-id=ami-0123456789abcdef0 --staging-smoke-flapjack-ami-id=ami-0fedcba9876543210

    assert_eq "$RUN_EXIT_CODE" "0" "missing-vite dry-run with succeeding npm bootstrap should exit 0"
    if call_log_contains_npm_ci; then
        pass "missing vite runtime should trigger npm ci --no-audit --no-fund"
    else
        fail "missing vite runtime should trigger npm ci --no-audit --no-fund (call log: $(cat "$TEST_CALL_LOG" 2>/dev/null || true))"
    fi
}

test_present_vite_runtime_is_no_op() {
    setup_workspace
    install_present_vite_stub

    local credential_file="$TEST_WORKSPACE/inputs/credentials.env"
    write_safe_credentials_env "$credential_file"

    _run_facade --dry-run \
        --sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        --artifact-dir="$TEST_WORKSPACE/artifacts" \
        --credential-env-file="$credential_file" \
        --billing-month=2026-06 \
        "$(valid_section1_manifest_arg)" \
        --staging-smoke-api-ami-id=ami-0123456789abcdef0 --staging-smoke-flapjack-ami-id=ami-0fedcba9876543210

    assert_eq "$RUN_EXIT_CODE" "0" "present-vite dry-run should exit 0 without invoking npm"
    if call_log_has_any_npm_entry; then
        fail "present vite runtime should be a no-op but npm was invoked (call log: $(cat "$TEST_CALL_LOG" 2>/dev/null || true))"
    else
        pass "present vite runtime is a bootstrap no-op (npm not invoked)"
    fi
}

test_invalid_input_does_not_bootstrap_missing_vite() {
    setup_workspace
    install_empty_web_dir_without_vite

    local credential_file="$TEST_WORKSPACE/inputs/credentials.env"
    write_safe_credentials_env "$credential_file"

    _run_facade --dry-run \
        --sha=not-a-valid-sha \
        --artifact-dir="$TEST_WORKSPACE/artifacts" \
        --credential-env-file="$credential_file" \
        --billing-month=2026-06 \
        "$(valid_section1_manifest_arg)" \
        --staging-smoke-api-ami-id=ami-0123456789abcdef0 --staging-smoke-flapjack-ami-id=ami-0fedcba9876543210

    assert_eq "$RUN_EXIT_CODE" "2" "invalid sha should fail wrapper validation before bootstrap"
    assert_contains "$(combined_output)" "--sha must be a 40-character lowercase hexadecimal commit SHA" "invalid sha should surface wrapper validation error"
    if call_log_has_any_npm_entry; then
        fail "invalid input must not invoke npm bootstrap (call log: $(cat "$TEST_CALL_LOG" 2>/dev/null || true))"
    else
        pass "invalid input does not invoke npm bootstrap"
    fi
}

test_unreadable_credential_env_does_not_bootstrap_missing_vite() {
    setup_workspace
    install_empty_web_dir_without_vite

    local credential_file="$TEST_WORKSPACE/inputs/unreadable-credentials.env"
    write_safe_credentials_env "$credential_file"
    chmod 000 "$credential_file"

    _run_facade --dry-run \
        --sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        --artifact-dir="$TEST_WORKSPACE/artifacts" \
        --credential-env-file="$credential_file" \
        --billing-month=2026-06 \
        "$(valid_section1_manifest_arg)" \
        --staging-smoke-api-ami-id=ami-0123456789abcdef0 --staging-smoke-flapjack-ami-id=ami-0fedcba9876543210

    assert_eq "$RUN_EXIT_CODE" "1" "unreadable credential env should fail before bootstrap"
    assert_contains "$(combined_output)" "credential env file is not readable: $credential_file" "unreadable credential env should surface wrapper credential error"
    if call_log_has_any_npm_entry; then
        fail "unreadable credential env must not invoke npm bootstrap (call log: $(cat "$TEST_CALL_LOG" 2>/dev/null || true))"
    else
        pass "unreadable credential env does not invoke npm bootstrap"
    fi

    chmod 600 "$credential_file"
}

test_missing_vite_triggers_npm_ci_bootstrap
test_present_vite_runtime_is_no_op
test_invalid_input_does_not_bootstrap_missing_vite
test_unreadable_credential_env_does_not_bootstrap_missing_vite

run_test_summary
