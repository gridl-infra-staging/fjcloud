#!/usr/bin/env bash
# Regression test: verify_email step must preserve inbox lookup errors instead of misreporting timeout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CANARY_SCRIPT="$REPO_ROOT/scripts/canary/customer_loop_synthetic.sh"

# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

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

if [ ! -f "$CANARY_SCRIPT" ]; then
    fail "canary script exists at scripts/canary/customer_loop_synthetic.sh"
    exit 1
fi

# shellcheck source=scripts/canary/customer_loop_synthetic.sh
source "$CANARY_SCRIPT"

TEST_INBOX_LOOKUP_MODE="fail"
TEST_VERIFY_TOKEN=""
CAPTURED_REQUEST_PATH=""
CAPTURED_REQUEST_BODY=""

capture_json_response() {
    CAPTURED_REQUEST_PATH="${3:-}"
    CAPTURED_REQUEST_BODY="${5:-}"

    if [ "$CAPTURED_REQUEST_PATH" = "/auth/verify-email" ]; then
        if ! python3 - "$CAPTURED_REQUEST_BODY" <<'PY'
import json
import sys

json.loads(sys.argv[1])
PY
        then
            HTTP_RESPONSE_CODE="400"
            HTTP_RESPONSE_BODY='{"error":"invalid json"}'
            return 0
        fi
    fi

    HTTP_RESPONSE_CODE="200"
    HTTP_RESPONSE_BODY='{}'
}
api_json_call() { :; }
AWS_FAIL_NAMES=""

aws() {
    local parameter_name=""
    local arg

    if [ "${1:-}" != "ssm" ] || [ "${2:-}" != "get-parameter" ]; then
        echo "unexpected aws invocation: $*" >&2
        return 1
    fi

    shift 2
    while [ "$#" -gt 0 ]; do
        arg="$1"
        case "$arg" in
            --name)
                parameter_name="${2:-}"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    case " $AWS_FAIL_NAMES " in
        *" $parameter_name "*)
            echo "parameter lookup failed for ${parameter_name}" >&2
            return 1
            ;;
    esac

    case "$parameter_name" in
        /fjcloud/prod/admin_key)
            printf 'resolved-admin-key\n'
            ;;
        /fjcloud/prod/stripe_secret_key)
            printf 'sk_test_resolved\n'
            ;;
        /fjcloud/prod/slack_webhook_url)
            printf 'https://hooks.slack.example/customer-loop\n'
            ;;
        /fjcloud/prod/discord_webhook_url)
            printf 'https://discord.example/api/webhooks/customer-loop\n'
            ;;
        *)
            echo "unexpected parameter lookup: ${parameter_name}" >&2
            return 1
            ;;
    esac
}

test_inbox_parse_s3_uri() {
    printf 'flapjack-cloud-releases|e2e-emails/\n'
}

test_inbox_find_matching_object_key() {
    case "$TEST_INBOX_LOOKUP_MODE" in
        fail)
            echo 'aws s3api list-objects-v2 failed for s3://flapjack-cloud-releases/e2e-emails/' >&2
            return 1
            ;;
        success)
            printf 'matching-message.eml\n'
            ;;
        *)
            echo "unexpected TEST_INBOX_LOOKUP_MODE=${TEST_INBOX_LOOKUP_MODE}" >&2
            return 1
            ;;
    esac
}

test_inbox_fetch_rfc822() { printf 'dummy-rfc822-payload\n'; }
test_inbox_extract_verify_token_from_rfc822() { printf '%s' "$TEST_VERIFY_TOKEN"; }

reset_flow_state() {
    FLOW_FAILED=0
    FLOW_FAILURE_STEP=""
    FLOW_FAILURE_DETAIL=""
    CANARY_NONCE="canary-regression"
    CANARY_TEST_INBOX_S3_URI="s3://flapjack-cloud-releases/e2e-emails/"
    CANARY_AWS_REGION="us-east-1"
    CANARY_INBOX_MAX_ATTEMPTS=3
    CANARY_INBOX_SLEEP_SECONDS=0
    CANARY_SIGNUP_EMAIL="canary-regression@test.flapjack.foo"
    TEST_INBOX_LOOKUP_MODE="fail"
    TEST_VERIFY_TOKEN=""
    CAPTURED_REQUEST_PATH=""
    CAPTURED_REQUEST_BODY=""
}

reset_secret_resolution_state() {
    export FJCLOUD_SECRET_FILE="$REPO_ROOT/.secret/does_not_exist"
    export ENVIRONMENT="prod"
    export CANARY_AWS_REGION="us-east-1"
    export ADMIN_KEY="/fjcloud/prod/admin_key"
    export STRIPE_SECRET_KEY="/fjcloud/prod/stripe_secret_key"
    export SLACK_WEBHOOK_URL="/fjcloud/prod/slack_webhook_url"
    export DISCORD_WEBHOOK_URL="/fjcloud/prod/discord_webhook_url"
    unset STRIPE_TEST_SECRET_KEY
    unset STRIPE_SECRET_KEY_EFFECTIVE
    AWS_FAIL_NAMES=""
}

test_verify_email_surfaces_inbox_lookup_error() {
    reset_flow_state

    if run_verify_email_step; then
        fail "verify_email step should fail when inbox lookup command exits non-zero"
        return
    fi

    assert_eq "$FLOW_FAILURE_STEP" "verify_email" \
        "verify_email step should set FLOW_FAILURE_STEP"
    assert_contains "$FLOW_FAILURE_DETAIL" "inbox lookup command failed" \
        "verify_email failure detail should report inbox lookup command error"
    assert_not_contains "$FLOW_FAILURE_DETAIL" "not found in inbox within timeout" \
        "verify_email failure detail should not collapse command failure into timeout"
}

test_verify_email_json_escapes_token() {
    reset_flow_state
    TEST_INBOX_LOOKUP_MODE="success"
    TEST_VERIFY_TOKEN=$'verify-token-"quoted"\\slash\nsecond-line'

    if ! run_verify_email_step; then
        fail "verify_email step should accept tokens that require JSON escaping"
        return
    fi

    assert_eq "$CAPTURED_REQUEST_PATH" "/auth/verify-email" \
        "verify_email step should call the verify-email endpoint"

    if ! python3 - "$CAPTURED_REQUEST_BODY" "$TEST_VERIFY_TOKEN" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
expected = sys.argv[2]
if payload.get("token") != expected:
    raise SystemExit(1)
PY
    then
        fail "verify_email payload should preserve the original token after JSON encoding"
    else
        pass "verify_email payload preserves quoted/newline token content"
    fi
}

test_load_canary_env_resolves_ssm_parameter_values() {
    reset_secret_resolution_state

    if ! load_canary_env; then
        fail "load_canary_env should resolve SSM-backed runtime secrets"
        return
    fi

    assert_eq "$ADMIN_KEY" "resolved-admin-key" \
        "load_canary_env should resolve ADMIN_KEY parameter names"
    assert_eq "$STRIPE_SECRET_KEY_EFFECTIVE" "sk_test_resolved" \
        "load_canary_env should resolve Stripe parameter names"
    assert_eq "$SLACK_WEBHOOK_URL" "https://hooks.slack.example/customer-loop" \
        "load_canary_env should resolve Slack webhook parameter names"
    assert_eq "$DISCORD_WEBHOOK_URL" "https://discord.example/api/webhooks/customer-loop" \
        "load_canary_env should resolve Discord webhook parameter names"
    assert_eq "$CANARY_INDEX_REGION" "$CANARY_AWS_REGION" \
        "load_canary_env should default CANARY_INDEX_REGION from CANARY_AWS_REGION"
}

test_load_canary_env_fails_when_ssm_lookup_fails() {
    local output

    reset_secret_resolution_state
    AWS_FAIL_NAMES="/fjcloud/prod/discord_webhook_url"

    if output="$(load_canary_env 2>&1)"; then
        fail "load_canary_env should fail when an SSM-backed secret cannot be resolved"
        return
    fi

    assert_contains "$output" "failed to resolve SSM parameter /fjcloud/prod/discord_webhook_url" \
        "load_canary_env should surface the failing SSM parameter name"
}

main() {
    echo "=== customer_loop_verify_email_error_surface_test.sh ==="
    echo ""

    test_verify_email_surfaces_inbox_lookup_error
    test_verify_email_json_escapes_token
    test_load_canary_env_resolves_ssm_parameter_values
    test_load_canary_env_fails_when_ssm_lookup_fails

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
