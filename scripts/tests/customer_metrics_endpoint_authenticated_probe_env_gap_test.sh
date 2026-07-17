#!/usr/bin/env bash
# Regression test for the customer metrics authenticated probe's AWS-credential
# probe-env gap precheck. Missing AWS CLI availability must SKIP with the
# canonical token, while a successful default credential chain must return 0
# and proceed past the precheck.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROBE_SCRIPT="$REPO_ROOT/scripts/canary/contracts/customer_metrics_endpoint_authenticated_probe.sh"

source "$SCRIPT_DIR/lib/test_runner.sh"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/test_helpers.sh"

if [ ! -f "$PROBE_SCRIPT" ]; then
    fail "probe script exists at scripts/canary/contracts/customer_metrics_endpoint_authenticated_probe.sh"
    run_test_summary
    exit 1
fi

export ALERT_DISPATCH_HELPER="$REPO_ROOT/scripts/lib/alert_dispatch.sh"
# shellcheck source=scripts/canary/contracts/customer_metrics_endpoint_authenticated_probe.sh
source "$PROBE_SCRIPT"

run_prereq_case() {
    local aws_mode="$1"
    local access_key_id="$2"
    local secret_access_key="$3"
    local inbox_s3_uri="${4-s3://flapjack-cloud-releases/e2e-emails/}"
    local inbox_domain="${5-test.flapjack.foo}"
    local mock_dir aws_log output_file saved_path

    RUN_TMP_DIR="$(mktemp -d -t customer_metrics_probe_env_gap_XXXXXX)"
    mock_dir="$RUN_TMP_DIR/bin"
    aws_log="$RUN_TMP_DIR/aws.calls"
    output_file="$RUN_TMP_DIR/output.log"
    mkdir -p "$mock_dir"
    : > "$aws_log"

    # Point aws_identity's ambient->secret-file recovery at a KEYLESS file so it
    # is deterministically skipped here (no real .secret read). This keeps the
    # "invalid creds => exactly one sts preflight" contract stable on dev and CI
    # regardless of whether a real AWS key happens to exist on the host. The
    # pollution-recovery path itself is regression-tested in
    # scripts/tests/test_inbox_helpers_test.sh and scripts/tests/aws_identity_test.sh.
    local hermetic_secret_file="$RUN_TMP_DIR/keyless.env"
    printf 'ENVIRONMENT=staging\n' > "$hermetic_secret_file"
    export FJCLOUD_SECRET_FILE="$hermetic_secret_file"

    if [ "$aws_mode" != "missing_cli" ]; then
        write_mock_script "$mock_dir/aws" "$(cat <<'EOF_AWS'
set -euo pipefail
printf '%s\n' "$*" >> "${AWS_CALLS_LOG:?missing AWS_CALLS_LOG}"

if [[ "${1:-}" == "sts" && "${2:-}" == "get-caller-identity" ]]; then
    if [[ "${MOCK_AWS_STS_MODE:-ok}" == "ok" ]]; then
        printf '{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/probe-env-gap","UserId":"AIDAPROBE"}\n'
        exit 0
    fi
    echo "InvalidClientTokenId" >&2
    exit 255
fi

echo "unexpected aws invocation: $*" >&2
exit 99
EOF_AWS
)"
    fi

    saved_path="$PATH"
    PATH="$mock_dir:/usr/bin:/bin:/usr/sbin:/sbin"
    AWS_CALLS_LOG="$aws_log"
    MOCK_AWS_STS_MODE="$aws_mode"
    CANARY_TEST_INBOX_S3_URI="$inbox_s3_uri"
    CANARY_TEST_INBOX_DOMAIN="$inbox_domain"
    PROBE_SKIP_REASON=""
    PROBE_SKIP_DETAIL=""
    RUN_EXIT_CODE=0

    if [ -n "$access_key_id" ]; then
        AWS_ACCESS_KEY_ID="$access_key_id"
        export AWS_ACCESS_KEY_ID
    else
        unset AWS_ACCESS_KEY_ID AWS_SESSION_TOKEN AWS_PROFILE
    fi
    if [ -n "$secret_access_key" ]; then
        AWS_SECRET_ACCESS_KEY="$secret_access_key"
        export AWS_SECRET_ACCESS_KEY
    else
        unset AWS_SECRET_ACCESS_KEY
    fi
    export PATH AWS_CALLS_LOG MOCK_AWS_STS_MODE
    set +e
    ensure_live_probe_prereqs >"$output_file" 2>&1
    RUN_EXIT_CODE=$?
    set -e
    PATH="$saved_path"

    RUN_OUTPUT="$(cat "$output_file" 2>/dev/null || true)"
    RUN_AWS_CALLS="$(cat "$aws_log" 2>/dev/null || true)"
}

cleanup_prereq_case() {
    rm -rf "${RUN_TMP_DIR:-}"
    RUN_TMP_DIR=""
    unset FJCLOUD_SECRET_FILE
}

assert_summary_skip_reason() {
    local expected_token="$1"
    local summary_body

    CANARY_CUSTOMER_ID="cust_probe_env_gap"
    CANARY_INDEX_NAME="probe-env-gap-index"
    API_URL="https://api.staging.flapjack.foo"
    CANARY_INDEX_CREATED=0
    CANARY_ACCOUNT_DELETED=1
    CANARY_ADMIN_CLEANED=0
    PROBE_FAILURE_DETAIL=""
    SUMMARY_JSON="$RUN_TMP_DIR/summary.json"

    write_summary_json
    assert_file_exists "$SUMMARY_JSON" "summary.json should be written for $expected_token skip"
    summary_body="$(cat "$SUMMARY_JSON")"
    assert_valid_json "$summary_body" "summary.json should be valid for $expected_token skip"
    assert_contains "$summary_body" '"status": "skip"' \
        "summary should report status=skip for $expected_token"
    assert_contains "$summary_body" '"exit_code": 100' \
        "summary should report exit_code=100 for $expected_token"
    assert_contains "$summary_body" "\"skip_reason\": \"$expected_token\"" \
        "summary should persist $expected_token"
}

assert_prereq_skip_case() {
    local expected_token="$1"
    local expected_aws_call_count="$2"
    local aws_call_count

    assert_eq "$RUN_EXIT_CODE" "100" "$expected_token should return the skip exit code"
    assert_contains "$RUN_OUTPUT" "SKIPPED: $expected_token" \
        "$expected_token should be announced on stdout"
    assert_eq "$PROBE_SKIP_REASON" "$expected_token" \
        "$expected_token should persist in PROBE_SKIP_REASON"

    aws_call_count="$(printf '%s\n' "$RUN_AWS_CALLS" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
    assert_eq "$aws_call_count" "$expected_aws_call_count" \
        "$expected_token should perform the expected number of sts preflight calls"

    assert_summary_skip_reason "$expected_token"
}

test_missing_aws_cli_returns_skip_without_hitting_aws() {
    run_prereq_case "missing_cli" "" ""

    assert_prereq_skip_case "probe_env_gap_aws_credentials_unavailable" "0"
    cleanup_prereq_case
}

test_invalid_aws_credentials_returns_skip_after_sts_preflight() {
    run_prereq_case "invalid" "AKIA_PROBE_ENV_GAP" "test-secret"

    assert_prereq_skip_case "probe_env_gap_aws_credentials_invalid" "1"
    assert_contains "$RUN_AWS_CALLS" "sts get-caller-identity" \
        "invalid AWS credentials should be classified by the shared sts preflight"
    cleanup_prereq_case
}

test_missing_inbox_env_returns_skip_without_hitting_aws() {
    local aws_call_count

    run_prereq_case "ok" "" "" "" ""

    assert_prereq_skip_case "probe_env_gap_aws_inbox_env_missing" "0"
    aws_call_count="$(printf '%s\n' "$RUN_AWS_CALLS" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
    assert_eq "$aws_call_count" "0" "missing inbox env should skip before any aws CLI call"
    cleanup_prereq_case
}

test_default_credential_chain_gets_past_precheck() {
    local aws_call_count

    run_prereq_case "ok" "" ""

    assert_eq "$RUN_EXIT_CODE" "0" "default AWS credential chain should let the probe proceed past the precheck"

    aws_call_count="$(printf '%s\n' "$RUN_AWS_CALLS" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
    assert_eq "$aws_call_count" "1" "default AWS credential chain should perform exactly one sts preflight call"
    assert_contains "$RUN_AWS_CALLS" "sts get-caller-identity" \
        "default AWS credential chain should validate the caller identity with sts"
    cleanup_prereq_case
}

main() {
    echo "=== customer_metrics_endpoint_authenticated_probe_env_gap_test.sh ==="

    test_missing_aws_cli_returns_skip_without_hitting_aws
    test_invalid_aws_credentials_returns_skip_after_sts_preflight
    test_missing_inbox_env_returns_skip_without_hitting_aws
    test_default_credential_chain_gets_past_precheck

    run_test_summary
}

main "$@"
