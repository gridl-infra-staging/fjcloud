#!/usr/bin/env bash
# Contract tests for Stage 2 email/SES probes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/tests/lib/test_runner.sh"
source "$REPO_ROOT/scripts/tests/lib/assertions.sh"
source "$REPO_ROOT/scripts/tests/lib/test_helpers.sh"

run_command_capture() {
    local stdout_file stderr_file
    stdout_file="$(mktemp)"
    stderr_file="$(mktemp)"
    if "$@" >"$stdout_file" 2>"$stderr_file"; then
        RUN_EXIT_CODE=0
    else
        RUN_EXIT_CODE=$?
    fi
    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
    rm -f "$stdout_file" "$stderr_file"
}

main() {
    local verify_script="$REPO_ROOT/scripts/probe_verify_email_clickthrough_e2e.sh"
    local reset_script="$REPO_ROOT/scripts/probe_password_reset_clickthrough_e2e.sh"
    local dunning_script="$REPO_ROOT/scripts/probe_dunning_email_inbox_e2e.sh"
    local support_script="$REPO_ROOT/scripts/probe_inbound_support_routing_e2e.sh"
    local bounce_script="$REPO_ROOT/scripts/probe_bounce_alert_discord_readback.sh"
    local helper_script="$REPO_ROOT/scripts/lib/clickthrough_probe_common.sh"

    assert_file_exists "$verify_script" "verify clickthrough probe exists"
    assert_file_exists "$reset_script" "reset clickthrough probe exists"
    assert_file_exists "$dunning_script" "dunning inbox probe exists"
    assert_file_exists "$support_script" "support routing probe exists"
    assert_file_exists "$bounce_script" "bounce alert probe exists"
    assert_file_exists "$helper_script" "clickthrough shared helper exists"

    local helper_source
    helper_source="$(read_file_content "$helper_script")"
    assert_contains "$helper_source" "SSM_EXEC_STAGING_SCRIPT_DEFAULT" "clickthrough helper defines staging SSM owner seam default"
    assert_not_contains "$helper_source" 'psql -v ON_ERROR_STOP=1 -X -t -A "$DATABASE_URL"' "clickthrough helper avoids local psql direct DB reads"

    run_command_capture bash "$verify_script"
    assert_eq "$RUN_EXIT_CODE" "2" "verify probe enforces usage exit"

    run_command_capture bash "$verify_script" /tmp/does-not-exist
    assert_eq "$RUN_EXIT_CODE" "3" "verify probe precondition-fails when env file is missing"

    run_command_capture bash "$reset_script"
    assert_eq "$RUN_EXIT_CODE" "2" "reset probe enforces usage exit"

    run_command_capture bash "$reset_script" /tmp/does-not-exist
    assert_eq "$RUN_EXIT_CODE" "3" "reset probe precondition-fails when env file is missing"

    run_command_capture bash "$dunning_script"
    assert_eq "$RUN_EXIT_CODE" "2" "dunning probe enforces usage exit"

    run_command_capture bash "$dunning_script" /tmp/does-not-exist
    assert_eq "$RUN_EXIT_CODE" "3" "dunning probe precondition-fails when env file missing"

    run_command_capture bash "$support_script"
    assert_eq "$RUN_EXIT_CODE" "0" "support routing probe succeeds"
    assert_contains "$RUN_STDOUT" "TERMINUS: operator-only delegation to support_email_probe.md" "support probe prints required terminus line"

    local mock_dir
    mock_dir="$(mktemp -d)"
    write_mock_script "$mock_dir/mock_probe_alert_delivery.sh" "$(cat <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != "--readback" ]]; then
    echo "expected --readback arg" >&2
    exit 1
fi
echo "==> probe summary: nonce=nonce-from-alert-owner slack=skipped discord=ok env=staging"
MOCK
)"
    chmod 0644 "$mock_dir/mock_probe_alert_delivery.sh"
    run_command_capture env SES_FROM_ADDRESS="sender@example.com" SES_REGION="us-east-1" PROBE_ALERT_DELIVERY_SCRIPT="$mock_dir/mock_probe_alert_delivery.sh" bash "$bounce_script"
    rm -rf "$mock_dir"

    assert_eq "$RUN_EXIT_CODE" "0" "bounce alert probe succeeds when owner readback script is readable and confirms nonce"
    assert_contains "$RUN_STDOUT" "TERMINUS: discord message contains nonce" "bounce probe prints nonce terminus"
    assert_contains "$RUN_STDOUT" "nonce=nonce-from-alert-owner" "bounce probe surfaces nonce from probe_alert_delivery owner output"

    run_test_summary
}

main "$@"
