#!/usr/bin/env bash
# Regression test: customer-loop Lambda bootstrap must parse SSM get-parameters
# JSON and hydrate env vars without crashing with JSONDecodeError.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOOTSTRAP_SCRIPT="$REPO_ROOT/scripts/canary/lambda_image/bootstrap"

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

if [ ! -f "$BOOTSTRAP_SCRIPT" ]; then
    fail "bootstrap script exists at scripts/canary/lambda_image/bootstrap"
    exit 1
fi

BOOTSTRAP_DEFS="$(mktemp)"
trap 'rm -f "$BOOTSTRAP_DEFS"' EXIT
awk '/^while true; do/{exit} {print}' "$BOOTSTRAP_SCRIPT" > "$BOOTSTRAP_DEFS"
export AWS_LAMBDA_RUNTIME_API="local-runtime-api.test"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DEFS"

AWS_MOCK_PAYLOAD='{}'
aws() {
    if [ "${1:-}" = "ssm" ] && [ "${2:-}" = "get-parameters" ]; then
        printf '%s\n' "$AWS_MOCK_PAYLOAD"
        return 0
    fi

    echo "unexpected aws invocation: $*" >&2
    return 1
}

reset_env() {
    export CANARY_AWS_REGION="us-east-1"
    export ADMIN_KEY="/fjcloud/prod/admin_key"
    export STRIPE_SECRET_KEY="/fjcloud/prod/stripe_secret_key"
    export SLACK_WEBHOOK_URL="/fjcloud/prod/slack_webhook_url"
    export DISCORD_WEBHOOK_URL="/fjcloud/prod/discord_webhook_url"
    unset CANARY_SSM_HYDRATED
}

test_hydrates_and_allows_optional_missing() {
    local output_file

    reset_env
    AWS_MOCK_PAYLOAD='{"Parameters":[{"Name":"/fjcloud/prod/admin_key","Value":"resolved-admin"},{"Name":"/fjcloud/prod/stripe_secret_key","Value":"resolved-stripe"},{"Name":"/fjcloud/prod/slack_webhook_url","Value":"https://hooks.slack.example/abc"}],"InvalidParameters":["/fjcloud/prod/discord_webhook_url"]}'

    output_file="$(mktemp)"
    if ! hydrate_runtime_parameter_env_vars >"$output_file" 2>&1; then
        local output
        output="$(cat "$output_file" 2>/dev/null || true)"
        rm -f "$output_file"
        fail "hydrate_runtime_parameter_env_vars should succeed with valid get-parameters JSON; output: ${output}"
        return
    fi
    rm -f "$output_file"

    assert_eq "$ADMIN_KEY" "resolved-admin" \
        "bootstrap should resolve ADMIN_KEY from SSM payload"
    assert_eq "$STRIPE_SECRET_KEY" "resolved-stripe" \
        "bootstrap should resolve STRIPE_SECRET_KEY from SSM payload"
    assert_eq "$SLACK_WEBHOOK_URL" "https://hooks.slack.example/abc" \
        "bootstrap should resolve SLACK_WEBHOOK_URL from SSM payload"
    assert_eq "$DISCORD_WEBHOOK_URL" "" \
        "bootstrap should blank optional webhook var when parameter is invalid"
}

test_required_parameter_missing_fails() {
    local output_file output

    reset_env
    AWS_MOCK_PAYLOAD='{"Parameters":[{"Name":"/fjcloud/prod/admin_key","Value":"resolved-admin"}],"InvalidParameters":["/fjcloud/prod/stripe_secret_key"]}'

    output_file="$(mktemp)"
    if hydrate_runtime_parameter_env_vars >"$output_file" 2>&1; then
        rm -f "$output_file"
        fail "hydrate_runtime_parameter_env_vars should fail when required STRIPE parameter is missing"
        return
    fi
    output="$(cat "$output_file" 2>/dev/null || true)"
    rm -f "$output_file"

    assert_contains "$output" "missing required SSM parameter for STRIPE_SECRET_KEY" \
        "bootstrap should surface required-parameter failure"
}

test_skips_rehydration_when_already_hydrated() {
    local output_file output before_admin before_stripe
    reset_env
    # Simulate a prior invocation that resolved values; env vars now contain
    # the secret values (which may themselves start with "/") and the sentinel
    # is set. Bootstrap MUST NOT re-resolve those on warm invocation.
    export ADMIN_KEY="/uiaeMnmRzsOPw0aEglARrv5hW6GX0pi"
    export STRIPE_SECRET_KEY="sk_test_alreadyResolved"
    export SLACK_WEBHOOK_URL="https://hooks.slack.example/already"
    export DISCORD_WEBHOOK_URL="https://discord.example/already"
    export CANARY_SSM_HYDRATED=1
    before_admin="$ADMIN_KEY"
    before_stripe="$STRIPE_SECRET_KEY"

    aws() {
        echo "unexpected aws invocation: $*" >&2
        return 1
    }

    output_file="$(mktemp)"
    if ! hydrate_runtime_parameter_env_vars >"$output_file" 2>&1; then
        output="$(cat "$output_file" 2>/dev/null || true)"
        rm -f "$output_file"
        unset CANARY_SSM_HYDRATED
        fail "hydrate_runtime_parameter_env_vars must succeed without calling aws when CANARY_SSM_HYDRATED=1; output: ${output}"
        return
    fi
    output="$(cat "$output_file" 2>/dev/null || true)"
    rm -f "$output_file"

    assert_eq "$ADMIN_KEY" "$before_admin" \
        "bootstrap must preserve already-hydrated ADMIN_KEY verbatim on warm invoke"
    assert_eq "$STRIPE_SECRET_KEY" "$before_stripe" \
        "bootstrap must preserve already-hydrated STRIPE_SECRET_KEY verbatim on warm invoke"
    if [[ "$output" == *"unexpected aws invocation"* ]]; then
        fail "bootstrap must not call aws when CANARY_SSM_HYDRATED=1; output: ${output}"
    fi
    unset CANARY_SSM_HYDRATED
}

main() {
    echo "=== customer_loop_bootstrap_ssm_hydration_test.sh ==="
    echo ""

    test_hydrates_and_allows_optional_missing
    test_required_parameter_missing_fails
    test_skips_rehydration_when_already_hydrated

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
