#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../validate_full_vm_lifecycle_prod.sh
source "$REPO_ROOT/scripts/validate_full_vm_lifecycle_prod.sh"

assert_equals() {
    local actual="$1"
    local expected="$2"
    local context="$3"
    if [ "$actual" != "$expected" ]; then
        echo "FAIL: ${context} expected=${expected} actual=${actual}" >&2
        exit 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local context="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "FAIL: ${context} missing=${needle} actual=${haystack}" >&2
        exit 1
    fi
}

reset_lifecycle_test_state() {
    FLOW_FAILED=0
    FLOW_FAILURE_STEP=""
    FLOW_FAILURE_DETAIL=""
    LIFECYCLE_ENABLE_PRIVACY_CARD=1
    LIFECYCLE_ENV="staging"
    LIFECYCLE_PRIVACY_CARD_TOKEN=""
    PRIVACY_CLIENT_EXIT_CLASS=""
    PRIVACY_CLIENT_HTTP_CODE=""
    PRIVACY_CLIENT_BODY=""
    PRIVACY_CLIENT_ERROR_MESSAGE=""
    TEST_LOGS=()
    TEST_FAILURES=()
    TEST_CREATE_CALLS=()
    TEST_GET_CALLS=()
    TEST_UNPAUSE_CALLS=()
    TEST_PAUSE_CALLS=()
    TEST_CLOSE_CALLS=()
    TEST_AWS_CALLS=()
    TEST_AWS_PUT_NAME=""
    TEST_AWS_PUT_VALUE=""
    TEST_AWS_GET_TOKEN_MODE="missing"
    TEST_AWS_GET_TOKEN_VALUE=""
    TEST_AWS_GET_TOKEN_ERROR="An error occurred (ParameterNotFound) when calling the GetParameter operation: Parameter /fjcloud/staging/privacy_card_reusable_token not found."
    TEST_PRIVACY_GET_STATE=""
    TEST_PRIVACY_GET_RC=0
    TEST_PRIVACY_GET_CLASS="ok"
    TEST_PRIVACY_GET_HTTP_CODE="200"
    TEST_CREATE_RC=0
    TEST_CREATE_CLASS="ok"
    TEST_CREATE_HTTP_CODE="200"
    TEST_CREATE_TOKEN="tok_created"
    TEST_UNPAUSE_RC=0
    TEST_UNPAUSE_CLASS="ok"
    TEST_PAUSE_RC=0
    TEST_PAUSE_CLASS="ok"
    TEST_AWS_PUT_RC=0
}

log() {
    TEST_LOGS+=("$*")
}

mark_failure() {
    TEST_FAILURES+=("$1|$2")
    FLOW_FAILED=1
    FLOW_FAILURE_STEP="$1"
    FLOW_FAILURE_DETAIL="$2"
}

privacy_com_require_env() {
    PRIVACY_CLIENT_EXIT_CLASS="ok"
    PRIVACY_CLIENT_ERROR_MESSAGE=""
    return 0
}

privacy_com_get_card() {
    TEST_GET_CALLS+=("$1")
    PRIVACY_CLIENT_EXIT_CLASS="$TEST_PRIVACY_GET_CLASS"
    PRIVACY_CLIENT_HTTP_CODE="$TEST_PRIVACY_GET_HTTP_CODE"
    if [ "$TEST_PRIVACY_GET_RC" -eq 0 ]; then
        PRIVACY_CLIENT_BODY="{\"token\":\"$1\",\"state\":\"${TEST_PRIVACY_GET_STATE}\",\"type\":\"MERCHANT_LOCKED\",\"spend_limit\":1000,\"spend_limit_duration\":\"FOREVER\",\"created\":\"2026-01-01T00:00:00Z\",\"funding\":{\"token\":\"funding-token\",\"state\":\"ENABLED\",\"type\":\"DEPOSITORY_CHECKING\",\"created\":\"2026-01-01T00:00:00Z\"},\"exp_month\":\"01\",\"exp_year\":\"2030\"}"
    else
        PRIVACY_CLIENT_BODY='{"message":"not found"}'
    fi
    return "$TEST_PRIVACY_GET_RC"
}

privacy_com_create_card() {
    TEST_CREATE_CALLS+=("${1:-}")
    PRIVACY_CLIENT_EXIT_CLASS="$TEST_CREATE_CLASS"
    PRIVACY_CLIENT_HTTP_CODE="$TEST_CREATE_HTTP_CODE"
    PRIVACY_CLIENT_ERROR_MESSAGE="create failed"
    PRIVACY_CLIENT_BODY="{\"token\":\"${TEST_CREATE_TOKEN}\",\"state\":\"OPEN\",\"type\":\"MERCHANT_LOCKED\",\"spend_limit\":1000,\"spend_limit_duration\":\"FOREVER\",\"created\":\"2026-01-01T00:00:00Z\",\"funding\":{\"token\":\"funding-token\",\"state\":\"ENABLED\",\"type\":\"DEPOSITORY_CHECKING\",\"created\":\"2026-01-01T00:00:00Z\"},\"exp_month\":\"01\",\"exp_year\":\"2030\"}"
    return "$TEST_CREATE_RC"
}

privacy_com_unpause_card() {
    TEST_UNPAUSE_CALLS+=("$1")
    PRIVACY_CLIENT_EXIT_CLASS="$TEST_UNPAUSE_CLASS"
    PRIVACY_CLIENT_HTTP_CODE="200"
    PRIVACY_CLIENT_BODY="{\"token\":\"$1\",\"state\":\"OPEN\",\"type\":\"MERCHANT_LOCKED\",\"spend_limit\":1000,\"spend_limit_duration\":\"FOREVER\",\"created\":\"2026-01-01T00:00:00Z\",\"funding\":{\"token\":\"funding-token\",\"state\":\"ENABLED\",\"type\":\"DEPOSITORY_CHECKING\",\"created\":\"2026-01-01T00:00:00Z\"},\"exp_month\":\"01\",\"exp_year\":\"2030\"}"
    return "$TEST_UNPAUSE_RC"
}

privacy_com_pause_card() {
    TEST_PAUSE_CALLS+=("$1")
    PRIVACY_CLIENT_EXIT_CLASS="$TEST_PAUSE_CLASS"
    PRIVACY_CLIENT_HTTP_CODE="200"
    PRIVACY_CLIENT_BODY="{\"token\":\"$1\",\"state\":\"PAUSED\",\"type\":\"MERCHANT_LOCKED\",\"spend_limit\":1000,\"spend_limit_duration\":\"FOREVER\",\"created\":\"2026-01-01T00:00:00Z\",\"funding\":{\"token\":\"funding-token\",\"state\":\"ENABLED\",\"type\":\"DEPOSITORY_CHECKING\",\"created\":\"2026-01-01T00:00:00Z\"},\"exp_month\":\"01\",\"exp_year\":\"2030\"}"
    return "$TEST_PAUSE_RC"
}

privacy_com_close_card() {
    TEST_CLOSE_CALLS+=("$1")
    return 0
}

aws() {
    TEST_AWS_CALLS+=("$*")
    if [ "$1" != "ssm" ]; then
        echo "unexpected aws call: $*" >&2
        return 99
    fi

    case "$2" in
        get-parameter)
            if [ "$TEST_AWS_GET_TOKEN_MODE" = "present" ]; then
                printf '%s\n' "$TEST_AWS_GET_TOKEN_VALUE"
                return 0
            fi
            printf '%s\n' "$TEST_AWS_GET_TOKEN_ERROR" >&2
            return 254
            ;;
        put-parameter)
            local name=""
            local value=""
            shift 2
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --name)
                        name="$2"
                        shift 2
                        ;;
                    --value)
                        value="$2"
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            TEST_AWS_PUT_NAME="$name"
            TEST_AWS_PUT_VALUE="$value"
            return "$TEST_AWS_PUT_RC"
            ;;
        *)
            echo "unexpected aws ssm subcommand: $2" >&2
            return 98
            ;;
    esac
}

test_empty_ssm_creates_and_stashes() {
    reset_lifecycle_test_state
    TEST_CREATE_TOKEN="tok_new"

    run_optional_privacy_card_step

    assert_equals "${TEST_CREATE_CALLS[0]}" "fjcloud reusable lifecycle card" "empty_ssm_create_uses_reusable_memo"
    assert_equals "$LIFECYCLE_PRIVACY_CARD_TOKEN" "tok_new" "empty_ssm_sets_lifecycle_token"
    assert_equals "$TEST_AWS_PUT_NAME" "/fjcloud/staging/privacy_card_reusable_token" "empty_ssm_put_name"
    assert_equals "$TEST_AWS_PUT_VALUE" "tok_new" "empty_ssm_put_value"
}

test_open_card_is_reused_no_mutation() {
    reset_lifecycle_test_state
    TEST_AWS_GET_TOKEN_MODE="present"
    TEST_AWS_GET_TOKEN_VALUE="tok_open"
    TEST_PRIVACY_GET_STATE="OPEN"

    run_optional_privacy_card_step

    assert_equals "${#TEST_CREATE_CALLS[@]}" "0" "open_reuse_no_create"
    assert_equals "${#TEST_UNPAUSE_CALLS[@]}" "0" "open_reuse_no_unpause"
    assert_equals "$TEST_AWS_PUT_NAME" "" "open_reuse_no_ssm_write"
    assert_equals "${TEST_GET_CALLS[0]}" "tok_open" "open_reuse_get_lookup"
    assert_equals "$LIFECYCLE_PRIVACY_CARD_TOKEN" "tok_open" "open_reuse_sets_token"
}

test_paused_card_is_unpaused_then_reused() {
    reset_lifecycle_test_state
    TEST_AWS_GET_TOKEN_MODE="present"
    TEST_AWS_GET_TOKEN_VALUE="tok_paused"
    TEST_PRIVACY_GET_STATE="PAUSED"

    run_optional_privacy_card_step

    assert_equals "${#TEST_CREATE_CALLS[@]}" "0" "paused_reuse_no_create"
    assert_equals "${#TEST_UNPAUSE_CALLS[@]}" "1" "paused_reuse_unpause_count"
    assert_equals "${TEST_UNPAUSE_CALLS[0]}" "tok_paused" "paused_reuse_unpause_token"
    assert_equals "$TEST_AWS_PUT_NAME" "" "paused_reuse_no_ssm_write"
    assert_equals "$LIFECYCLE_PRIVACY_CARD_TOKEN" "tok_paused" "paused_reuse_sets_token"
}

test_closed_card_falls_through_to_create() {
    reset_lifecycle_test_state
    TEST_AWS_GET_TOKEN_MODE="present"
    TEST_AWS_GET_TOKEN_VALUE="tok_closed"
    TEST_PRIVACY_GET_STATE="CLOSED"
    TEST_CREATE_TOKEN="tok_replaced"

    run_optional_privacy_card_step

    assert_equals "${TEST_GET_CALLS[0]}" "tok_closed" "closed_card_get_lookup"
    assert_equals "${#TEST_CREATE_CALLS[@]}" "1" "closed_card_triggers_create"
    assert_equals "$TEST_AWS_PUT_VALUE" "tok_replaced" "closed_card_rewrites_ssm"
    assert_equals "$LIFECYCLE_PRIVACY_CARD_TOKEN" "tok_replaced" "closed_card_sets_new_token"
}

test_get_card_404_falls_through_to_create() {
    reset_lifecycle_test_state
    TEST_AWS_GET_TOKEN_MODE="present"
    TEST_AWS_GET_TOKEN_VALUE="tok_ghost"
    TEST_PRIVACY_GET_RC=12
    TEST_PRIVACY_GET_CLASS="http_error"
    TEST_PRIVACY_GET_HTTP_CODE="404"
    TEST_CREATE_TOKEN="tok_after_404"

    run_optional_privacy_card_step

    assert_equals "${TEST_GET_CALLS[0]}" "tok_ghost" "get_404_lookup"
    assert_equals "${#TEST_CREATE_CALLS[@]}" "1" "get_404_triggers_create"
    assert_equals "$TEST_AWS_PUT_VALUE" "tok_after_404" "get_404_rewrites_ssm"
    assert_equals "$LIFECYCLE_PRIVACY_CARD_TOKEN" "tok_after_404" "get_404_sets_new_token"
}

test_get_card_unreadable_falls_through_to_create() {
    reset_lifecycle_test_state
    TEST_AWS_GET_TOKEN_MODE="present"
    TEST_AWS_GET_TOKEN_VALUE="tok_unreadable"
    TEST_PRIVACY_GET_RC=13
    TEST_PRIVACY_GET_CLASS="invalid_json"
    TEST_PRIVACY_GET_HTTP_CODE="200"
    TEST_CREATE_TOKEN="tok_after_unreadable"

    run_optional_privacy_card_step

    assert_equals "${TEST_GET_CALLS[0]}" "tok_unreadable" "get_unreadable_lookup"
    assert_equals "${#TEST_CREATE_CALLS[@]}" "1" "get_unreadable_triggers_create"
    assert_equals "$TEST_AWS_PUT_VALUE" "tok_after_unreadable" "get_unreadable_rewrites_ssm"
    assert_equals "$LIFECYCLE_PRIVACY_CARD_TOKEN" "tok_after_unreadable" "get_unreadable_sets_new_token"
}

test_invalid_stashed_token_marks_failure_without_create() {
    reset_lifecycle_test_state
    TEST_AWS_GET_TOKEN_MODE="present"
    TEST_AWS_GET_TOKEN_VALUE="tok_bad/../cards"

    if run_optional_privacy_card_step; then
        echo "FAIL: invalid stashed token should make run_optional_privacy_card_step fail" >&2
        exit 1
    fi

    assert_equals "$FLOW_FAILURE_STEP" "privacy_ssm_token" "invalid_stashed_token_marks_step"
    assert_contains "$FLOW_FAILURE_DETAIL" "invalid" "invalid_stashed_token_marks_detail"
    assert_equals "${#TEST_GET_CALLS[@]}" "0" "invalid_stashed_token_skips_lookup"
    assert_equals "${#TEST_CREATE_CALLS[@]}" "0" "invalid_stashed_token_skips_create"
    assert_equals "$LIFECYCLE_PRIVACY_CARD_TOKEN" "" "invalid_stashed_token_leaves_token_empty"
}

test_ssm_read_error_marks_failure_without_create() {
    reset_lifecycle_test_state
    TEST_AWS_GET_TOKEN_MODE="error"
    TEST_AWS_GET_TOKEN_ERROR="An error occurred (AccessDeniedException) when calling the GetParameter operation: denied"

    if run_optional_privacy_card_step; then
        echo "FAIL: SSM read error should make run_optional_privacy_card_step fail" >&2
        exit 1
    fi

    assert_equals "$FLOW_FAILURE_STEP" "privacy_ssm_read" "ssm_read_error_marks_step"
    assert_contains "$FLOW_FAILURE_DETAIL" "/fjcloud/staging/privacy_card_reusable_token" "ssm_read_error_marks_detail"
    assert_equals "${#TEST_CREATE_CALLS[@]}" "0" "ssm_read_error_no_create"
    assert_equals "$LIFECYCLE_PRIVACY_CARD_TOKEN" "" "ssm_read_error_leaves_token_empty"
}

test_lifecycle_env_disabled_skips_entirely() {
    reset_lifecycle_test_state
    LIFECYCLE_ENABLE_PRIVACY_CARD=0

    run_optional_privacy_card_step

    assert_equals "${#TEST_AWS_CALLS[@]}" "0" "disabled_no_aws_calls"
    assert_equals "${#TEST_GET_CALLS[@]}" "0" "disabled_no_get_calls"
    assert_equals "${#TEST_CREATE_CALLS[@]}" "0" "disabled_no_create_calls"
    assert_equals "$LIFECYCLE_PRIVACY_CARD_TOKEN" "" "disabled_leaves_token_empty"
}

test_create_failure_marks_failure_does_not_stash() {
    reset_lifecycle_test_state
    LIFECYCLE_PRIVACY_CARD_TOKEN="tok_stale"
    TEST_CREATE_RC=12
    TEST_CREATE_CLASS="http_error"

    if run_optional_privacy_card_step; then
        echo "FAIL: create failure should make run_optional_privacy_card_step fail" >&2
        exit 1
    fi

    assert_equals "$FLOW_FAILURE_STEP" "privacy_create_card" "create_failure_marks_step"
    assert_contains "$FLOW_FAILURE_DETAIL" "create failed" "create_failure_marks_detail"
    assert_equals "$TEST_AWS_PUT_NAME" "" "create_failure_skips_ssm_write"
    assert_equals "$LIFECYCLE_PRIVACY_CARD_TOKEN" "" "create_failure_clears_token"
}

test_stash_failure_marks_failure_and_clears_token() {
    reset_lifecycle_test_state
    TEST_CREATE_TOKEN="tok_needs_stash"
    TEST_AWS_PUT_RC=12

    if run_optional_privacy_card_step; then
        echo "FAIL: stash failure should make run_optional_privacy_card_step fail" >&2
        exit 1
    fi

    assert_equals "$FLOW_FAILURE_STEP" "privacy_ssm_stash" "stash_failure_marks_step"
    assert_contains "$FLOW_FAILURE_DETAIL" "/fjcloud/staging/privacy_card_reusable_token" "stash_failure_marks_detail"
    assert_equals "$LIFECYCLE_PRIVACY_CARD_TOKEN" "" "stash_failure_clears_token"
}

test_pause_step_calls_pause_not_close() {
    reset_lifecycle_test_state
    LIFECYCLE_PRIVACY_CARD_TOKEN="tok_abc"

    run_pause_privacy_card_step

    assert_equals "${#TEST_PAUSE_CALLS[@]}" "1" "pause_step_pause_count"
    assert_equals "${TEST_PAUSE_CALLS[0]}" "tok_abc" "pause_step_pause_token"
    assert_equals "${#TEST_CLOSE_CALLS[@]}" "0" "pause_step_never_closes"
}

test_pause_step_empty_token_is_noop() {
    reset_lifecycle_test_state

    run_pause_privacy_card_step

    assert_equals "${#TEST_PAUSE_CALLS[@]}" "0" "pause_noop_no_pause"
    assert_equals "${#TEST_CLOSE_CALLS[@]}" "0" "pause_noop_no_close"
}

test_pause_step_clears_token_on_success() {
    reset_lifecycle_test_state
    LIFECYCLE_PRIVACY_CARD_TOKEN="tok_abc"

    run_pause_privacy_card_step

    assert_equals "$LIFECYCLE_PRIVACY_CARD_TOKEN" "" "pause_success_clears_token"
}

test_pause_step_logs_warning_on_failure_but_returns_nonzero() {
    reset_lifecycle_test_state
    LIFECYCLE_PRIVACY_CARD_TOKEN="tok_abc"
    TEST_PAUSE_RC=12
    TEST_PAUSE_CLASS="http_error"

    if run_pause_privacy_card_step; then
        echo "FAIL: pause step should return non-zero on pause failure" >&2
        exit 1
    fi

    assert_equals "$LIFECYCLE_PRIVACY_CARD_TOKEN" "tok_abc" "pause_failure_retains_token"
    assert_contains "${TEST_LOGS[*]}" "cleanup warning: privacy card pause failed" "pause_failure_logs_warning"
}

test_pause_step_invalid_token_skips_api_and_returns_nonzero() {
    reset_lifecycle_test_state
    LIFECYCLE_PRIVACY_CARD_TOKEN="tok_bad/../cards"

    if run_pause_privacy_card_step; then
        echo "FAIL: pause step should reject invalid token before API call" >&2
        exit 1
    fi

    assert_equals "${#TEST_PAUSE_CALLS[@]}" "0" "pause_invalid_token_skips_pause"
    assert_equals "$LIFECYCLE_PRIVACY_CARD_TOKEN" "tok_bad/../cards" "pause_invalid_token_retains_token"
    assert_contains "${TEST_LOGS[*]}" "privacy card token is invalid" "pause_invalid_token_logs_warning"
}

test_old_function_name_does_not_exist() {
    if command -v run_close_privacy_card_step >/dev/null 2>&1; then
        echo "FAIL: run_close_privacy_card_step should not exist after rename" >&2
        exit 1
    fi
}

main() {
    test_empty_ssm_creates_and_stashes
    test_open_card_is_reused_no_mutation
    test_paused_card_is_unpaused_then_reused
    test_closed_card_falls_through_to_create
    test_get_card_404_falls_through_to_create
    test_get_card_unreadable_falls_through_to_create
    test_invalid_stashed_token_marks_failure_without_create
    test_ssm_read_error_marks_failure_without_create
    test_lifecycle_env_disabled_skips_entirely
    test_create_failure_marks_failure_does_not_stash
    test_stash_failure_marks_failure_and_clears_token
    test_pause_step_calls_pause_not_close
    test_pause_step_empty_token_is_noop
    test_pause_step_clears_token_on_success
    test_pause_step_logs_warning_on_failure_but_returns_nonzero
    test_pause_step_invalid_token_skips_api_and_returns_nonzero
    test_old_function_name_does_not_exist
    echo "PASS: lifecycle privacy step assertions succeeded"
}

main "$@"
