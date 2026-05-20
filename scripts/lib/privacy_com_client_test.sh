#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2329
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=privacy_com_client.sh
source "$SCRIPT_DIR/privacy_com_client.sh"

assert_equals() {
    local actual="$1"
    local expected="$2"
    local context="$3"
    if [ "$actual" != "$expected" ]; then
        echo "FAIL: ${context} expected=${expected} actual=${actual}" >&2
        return 1
    fi
}

require_json_field() {
    local json_body="$1"
    local field_path="$2"
    local context="$3"
    python3 - "$json_body" "$field_path" "$context" <<"PY"
import json
import sys

body = sys.argv[1]
path = sys.argv[2].split(".")
context = sys.argv[3]

try:
    value = json.loads(body)
except Exception as exc:
    print(f"FAIL: {context} invalid json: {exc}", file=sys.stderr)
    raise SystemExit(1)

for part in path:
    if isinstance(value, dict) and part in value:
        value = value[part]
        continue
    print(f"FAIL: {context} missing key: {'.'.join(path)}", file=sys.stderr)
    raise SystemExit(1)

if value in (None, ""):
    print(f"FAIL: {context} empty key value: {'.'.join(path)}", file=sys.stderr)
    raise SystemExit(1)
PY
}

require_card_schema() {
    local json_body="$1"
    local context="$2"

    require_json_field "$json_body" "token" "$context"
    require_json_field "$json_body" "state" "$context"
    require_json_field "$json_body" "type" "$context"
    require_json_field "$json_body" "spend_limit" "$context"
    require_json_field "$json_body" "spend_limit_duration" "$context"
    require_json_field "$json_body" "created" "$context"
    require_json_field "$json_body" "funding.token" "$context"
    require_json_field "$json_body" "funding.state" "$context"
    require_json_field "$json_body" "funding.type" "$context"
    require_json_field "$json_body" "funding.created" "$context"
    require_json_field "$json_body" "exp_month" "$context"
    require_json_field "$json_body" "exp_year" "$context"
}

assert_state_equals() {
    local json_body="$1"
    local expected="$2"
    local context="$3"

    local actual
    actual="$(python3 - "$json_body" <<"PY"
import json
import sys
obj = json.loads(sys.argv[1])
print(obj.get("state", ""))
PY
)"

    if [ "$actual" != "$expected" ]; then
        echo "FAIL: ${context} expected state=${expected}, got state=${actual}" >&2
        return 1
    fi
}

assert_spend_limit_duration_equals() {
    local json_body="$1"
    local expected="$2"
    local context="$3"

    local actual
    actual="$(python3 - "$json_body" <<"PY"
import json
import sys
obj = json.loads(sys.argv[1])
print(obj.get("spend_limit_duration", ""))
PY
)"

    if [ "$actual" != "$expected" ]; then
        echo "FAIL: ${context} expected spend_limit_duration=${expected}, got ${actual}" >&2
        return 1
    fi
}

is_card_limit_create_failure() {
    [ "$PRIVACY_CLIENT_EXIT_CLASS" = "http_error" ] || return 1
    [ "$PRIVACY_CLIENT_HTTP_CODE" = "405" ] || return 1
    python3 - "$PRIVACY_CLIENT_BODY" <<'PY'
import json
import sys

try:
    message = str(json.loads(sys.argv[1]).get("message", ""))
except Exception:
    raise SystemExit(1)

if "max allowed Card limit" not in message:
    raise SystemExit(1)
PY
}

extract_first_reclaimable_open_card_token() {
    local json_body="$1"
    python3 - "$json_body" "${PRIVACY_LANE_MEMO_PREFIXES[@]}" <<'PY'
import json
import sys

body = json.loads(sys.argv[1])
prefixes = tuple(sys.argv[2:])
for card in body.get("data", []):
    if card.get("state") != "OPEN":
        continue
    memo = card.get("memo")
    if not isinstance(memo, str):
        continue
    if not any(memo.startswith(prefix) for prefix in prefixes):
        continue
    token = card.get("token", "")
    if token:
        print(token)
        raise SystemExit(0)
print("")
PY
}

close_one_open_probe_card_for_capacity() {
    local current_page=1
    local total_pages=1
    while [ "$current_page" -le "$total_pages" ]; do
        if ! privacy_com_list_cards_raw_auth "$current_page" 100; then
            return 1
        fi
        total_pages="$(extract_total_pages "$PRIVACY_CLIENT_BODY")"
        local reclaim_token
        reclaim_token="$(extract_first_reclaimable_open_card_token "$PRIVACY_CLIENT_BODY")"
        if [ -n "$reclaim_token" ]; then
            if ! privacy_com_close_card "$reclaim_token"; then
                return 1
            fi
            return 0
        fi
        current_page=$((current_page + 1))
    done

    echo "FAIL: card-limit recovery found no reclaimable OPEN probe card to close" >&2
    return 1
}

create_card_with_capacity_recovery() {
    if privacy_com_create_card; then
        return 0
    fi
    local original_exit_class="$PRIVACY_CLIENT_EXIT_CLASS"
    local original_http_code="$PRIVACY_CLIENT_HTTP_CODE"
    local original_body="$PRIVACY_CLIENT_BODY"
    local original_error_message="${PRIVACY_CLIENT_ERROR_MESSAGE-}"

    if ! is_card_limit_create_failure; then
        return 1
    fi
    if ! close_one_open_probe_card_for_capacity; then
        PRIVACY_CLIENT_EXIT_CLASS="$original_exit_class"
        PRIVACY_CLIENT_HTTP_CODE="$original_http_code"
        PRIVACY_CLIENT_BODY="$original_body"
        PRIVACY_CLIENT_ERROR_MESSAGE="$original_error_message"
        return 1
    fi
    privacy_com_create_card
}

run_unit_contract_checks() {
    local original_base_url="${PRIVACY_BASE_URL-}"
    local original_api_key="${PRIVACY_API_KEY-}"
    local cleanup_token_before="$cleanup_token"
    local cleanup_open_before="$cleanup_open"

    PRIVACY_BASE_URL="http://127.0.0.1:9"
    PRIVACY_API_KEY="unit_test_key"
    if privacy_com_list_cards_raw_auth 1 1; then
        echo "FAIL: expected transport failure for unreachable endpoint" >&2
        return 1
    fi
    assert_equals "$PRIVACY_CLIENT_EXIT_CLASS" "curl_failure" "curl_failure_classification"
    assert_equals "$PRIVACY_CLIENT_HTTP_CODE" "000" "curl_failure_http_code"

    local fake_secret_file
    fake_secret_file="$(mktemp)"
    cat > "$fake_secret_file" <<'ENV'
PRIVACY_API_KEY=explicit_override_key
PRIVACY_BASE_URL=https://api.privacy.com
ENV
    export FJCLOUD_SECRET_FILE="$fake_secret_file"
    unset PRIVACY_API_KEY
    unset PRIVACY_COM_API_KEY
    unset PRIVACY_PRODUCTION_API_KEY
    privacy_com_require_env
    assert_equals "$PRIVACY_API_KEY" "explicit_override_key" "secret_file_override_load"
    rm -f "$fake_secret_file"

    if [ -n "${original_base_url}" ]; then
        PRIVACY_BASE_URL="$original_base_url"
    else
        unset PRIVACY_BASE_URL
    fi
    if [ -n "${original_api_key}" ]; then
        PRIVACY_API_KEY="$original_api_key"
    else
        unset PRIVACY_API_KEY
    fi
    unset FJCLOUD_SECRET_FILE

    run_unit_create_card_memo_contract_checks
    run_unit_identifier_validation_checks
    run_unit_pause_unpause_contract_checks
    run_unit_cleanup_restore_failure_path_checks
    run_unit_card_limit_recovery_checks
    run_unit_card_limit_recovery_no_reclaimable_checks
    run_unit_expected_failure_paths_are_quiet_checks
    if ! with_cleanup_state_restored run_unit_cleanup_registration_checks; then
        return 1
    fi

    assert_equals "$cleanup_token" "$cleanup_token_before" "cleanup_token_restored_after_unit_checks"
    assert_equals "$cleanup_open" "$cleanup_open_before" "cleanup_open_restored_after_unit_checks"
}

run_unit_create_card_memo_contract_checks() {
    local captured_method=""
    local captured_path=""
    local captured_auth_mode=""
    local captured_body=""

    privacy_com_request() {
        captured_method="$1"
        captured_path="$2"
        captured_auth_mode="$3"
        captured_body="${4:-}"
        PRIVACY_CLIENT_EXIT_CLASS="ok"
        PRIVACY_CLIENT_HTTP_CODE="200"
        PRIVACY_CLIENT_BODY='{"token":"tok_create","state":"OPEN","type":"MERCHANT_LOCKED","spend_limit":1000,"spend_limit_duration":"FOREVER","created":"2026-01-01T00:00:00Z","funding":{"token":"funding-token","state":"ENABLED","type":"DEPOSITORY_CHECKING","created":"2026-01-01T00:00:00Z"},"exp_month":"01","exp_year":"2030"}'
        return 0
    }

    privacy_com_validate_schema() {
        return 0
    }

    if ! privacy_com_create_card; then
        echo "FAIL: expected privacy_com_create_card default memo call to succeed" >&2
        return 1
    fi
    assert_equals "$captured_method" "POST" "create_card_default_method" || return 1
    assert_equals "$captured_path" "/v1/cards" "create_card_default_path" || return 1
    assert_equals "$captured_auth_mode" "raw" "create_card_default_auth_mode" || return 1
    assert_equals "$captured_body" '{"type":"MERCHANT_LOCKED","memo":"fjcloud stage2 contract probe","spend_limit":1000,"spend_limit_duration":"TRANSACTION","state":"OPEN"}' "create_card_default_body" || return 1

    if ! privacy_com_create_card "fjcloud reusable lifecycle card"; then
        echo "FAIL: expected privacy_com_create_card custom memo call to succeed" >&2
        return 1
    fi
    assert_equals "$captured_body" '{"type":"MERCHANT_LOCKED","memo":"fjcloud reusable lifecycle card","spend_limit":1000,"spend_limit_duration":"TRANSACTION","state":"OPEN"}' "create_card_custom_body" || return 1

    privacy_com_request() {
        echo "FAIL: forbidden memo should not invoke privacy_com_request" >&2
        return 1
    }

    local rc=0
    if privacy_com_create_card 'memo " quote'; then
        echo "FAIL: expected privacy_com_create_card to reject quote characters in memo" >&2
        return 1
    else
        rc=$?
    fi
    assert_equals "$rc" "$PRIVACY_CLIENT_EXIT_SCHEMA_MISMATCH" "create_card_quote_rejection_exit_code" || return 1
    assert_equals "$PRIVACY_CLIENT_EXIT_CLASS" "schema_mismatch" "create_card_quote_rejection_class" || return 1
    assert_equals "$PRIVACY_CLIENT_ERROR_MESSAGE" "memo contains forbidden chars" "create_card_quote_rejection_message" || return 1

    if privacy_com_create_card 'memo \ slash'; then
        echo "FAIL: expected privacy_com_create_card to reject backslash characters in memo" >&2
        return 1
    else
        rc=$?
    fi
    assert_equals "$rc" "$PRIVACY_CLIENT_EXIT_SCHEMA_MISMATCH" "create_card_backslash_rejection_exit_code" || return 1
    assert_equals "$PRIVACY_CLIENT_EXIT_CLASS" "schema_mismatch" "create_card_backslash_rejection_class" || return 1
    assert_equals "$PRIVACY_CLIENT_ERROR_MESSAGE" "memo contains forbidden chars" "create_card_backslash_rejection_message" || return 1

    if privacy_com_create_card $'memo\nnewline'; then
        echo "FAIL: expected privacy_com_create_card to reject newline characters in memo" >&2
        return 1
    else
        rc=$?
    fi
    assert_equals "$rc" "$PRIVACY_CLIENT_EXIT_SCHEMA_MISMATCH" "create_card_newline_rejection_exit_code" || return 1
    assert_equals "$PRIVACY_CLIENT_EXIT_CLASS" "schema_mismatch" "create_card_newline_rejection_class" || return 1
    assert_equals "$PRIVACY_CLIENT_ERROR_MESSAGE" "memo contains forbidden chars" "create_card_newline_rejection_message" || return 1

    if privacy_com_create_card $'memo\ttab'; then
        echo "FAIL: expected privacy_com_create_card to reject tab characters in memo" >&2
        return 1
    else
        rc=$?
    fi
    assert_equals "$rc" "$PRIVACY_CLIENT_EXIT_SCHEMA_MISMATCH" "create_card_tab_rejection_exit_code" || return 1
    assert_equals "$PRIVACY_CLIENT_EXIT_CLASS" "schema_mismatch" "create_card_tab_rejection_class" || return 1
    assert_equals "$PRIVACY_CLIENT_ERROR_MESSAGE" "memo contains forbidden chars" "create_card_tab_rejection_message" || return 1
}

run_unit_identifier_validation_checks() {
    local request_calls=0
    local captured_method=""
    local captured_path=""
    local captured_auth_mode=""
    local captured_body=""

    privacy_com_request() {
        request_calls=$((request_calls + 1))
        captured_method="$1"
        captured_path="$2"
        captured_auth_mode="$3"
        captured_body="${4:-}"
        PRIVACY_CLIENT_EXIT_CLASS="ok"
        PRIVACY_CLIENT_HTTP_CODE="200"
        PRIVACY_CLIENT_BODY='{"token":"tok_abc","state":"OPEN","type":"MERCHANT_LOCKED","spend_limit":1000,"spend_limit_duration":"FOREVER","created":"2026-01-01T00:00:00Z","funding":{"token":"funding-token","state":"ENABLED","type":"DEPOSITORY_CHECKING","created":"2026-01-01T00:00:00Z"},"exp_month":"01","exp_year":"2030"}'
        return 0
    }

    privacy_com_validate_schema() {
        return 0
    }

    if ! privacy_com_get_card "tok_abc"; then
        echo "FAIL: expected privacy_com_get_card request construction call to succeed" >&2
        return 1
    fi
    assert_equals "$captured_method" "GET" "get_card_request_method" || return 1
    assert_equals "$captured_path" "/v1/cards/tok_abc" "get_card_request_path" || return 1
    assert_equals "$captured_auth_mode" "raw" "get_card_request_auth_mode" || return 1

    if ! privacy_com_close_card "tok_abc"; then
        echo "FAIL: expected privacy_com_close_card request construction call to succeed" >&2
        return 1
    fi
    assert_equals "$captured_method" "PATCH" "close_card_request_method" || return 1
    assert_equals "$captured_path" "/v1/cards/tok_abc" "close_card_request_path" || return 1
    assert_equals "$captured_auth_mode" "raw" "close_card_request_auth_mode" || return 1
    assert_equals "$captured_body" '{"state":"CLOSED"}' "close_card_request_body" || return 1

    local calls_before="$request_calls"
    local rc=0
    if privacy_com_get_card 'tok_bad/../cards'; then
        echo "FAIL: expected privacy_com_get_card to reject unsafe token chars" >&2
        return 1
    else
        rc=$?
    fi
    assert_equals "$rc" "$PRIVACY_CLIENT_EXIT_SCHEMA_MISMATCH" "get_card_unsafe_token_exit_code" || return 1
    assert_equals "$PRIVACY_CLIENT_EXIT_CLASS" "schema_mismatch" "get_card_unsafe_token_class" || return 1
    assert_equals "$PRIVACY_CLIENT_ERROR_MESSAGE" "card token contains unsafe chars" "get_card_unsafe_token_message" || return 1
    assert_equals "$request_calls" "$calls_before" "get_card_unsafe_token_no_request" || return 1

    if privacy_com_close_card $'tok_bad\nnewline'; then
        echo "FAIL: expected privacy_com_close_card to reject control chars in token" >&2
        return 1
    else
        rc=$?
    fi
    assert_equals "$rc" "$PRIVACY_CLIENT_EXIT_SCHEMA_MISMATCH" "close_card_unsafe_token_exit_code" || return 1
    assert_equals "$PRIVACY_CLIENT_EXIT_CLASS" "schema_mismatch" "close_card_unsafe_token_class" || return 1
    assert_equals "$PRIVACY_CLIENT_ERROR_MESSAGE" "card token contains unsafe chars" "close_card_unsafe_token_message" || return 1
    assert_equals "$request_calls" "$calls_before" "close_card_unsafe_token_no_request" || return 1

    if privacy_com_list_cards_raw_auth '1&admin=true' 2; then
        echo "FAIL: expected privacy_com_list_cards_raw_auth to reject unsafe page values" >&2
        return 1
    else
        rc=$?
    fi
    assert_equals "$rc" "$PRIVACY_CLIENT_EXIT_SCHEMA_MISMATCH" "list_cards_unsafe_page_exit_code" || return 1
    assert_equals "$PRIVACY_CLIENT_EXIT_CLASS" "schema_mismatch" "list_cards_unsafe_page_class" || return 1
    assert_equals "$PRIVACY_CLIENT_ERROR_MESSAGE" "page must be a positive integer" "list_cards_unsafe_page_message" || return 1
    assert_equals "$request_calls" "$calls_before" "list_cards_unsafe_page_no_request" || return 1

    if privacy_com_list_cards_prefixed_auth 1 0; then
        echo "FAIL: expected privacy_com_list_cards_prefixed_auth to reject non-positive page_size" >&2
        return 1
    else
        rc=$?
    fi
    assert_equals "$rc" "$PRIVACY_CLIENT_EXIT_SCHEMA_MISMATCH" "list_cards_bad_page_size_exit_code" || return 1
    assert_equals "$PRIVACY_CLIENT_EXIT_CLASS" "schema_mismatch" "list_cards_bad_page_size_class" || return 1
    assert_equals "$PRIVACY_CLIENT_ERROR_MESSAGE" "page_size must be a positive integer" "list_cards_bad_page_size_message" || return 1
    assert_equals "$request_calls" "$calls_before" "list_cards_bad_page_size_no_request" || return 1
}

run_unit_pause_unpause_contract_checks() {
    local captured_method=""
    local captured_path=""
    local captured_auth_mode=""
    local captured_body=""

    privacy_com_request() {
        captured_method="$1"
        captured_path="$2"
        captured_auth_mode="$3"
        captured_body="${4:-}"
        PRIVACY_CLIENT_EXIT_CLASS="ok"
        PRIVACY_CLIENT_HTTP_CODE="200"
        PRIVACY_CLIENT_BODY='{"token":"tok_abc","state":"PAUSED","type":"MERCHANT_LOCKED","spend_limit":1000,"spend_limit_duration":"FOREVER","created":"2026-01-01T00:00:00Z","funding":{"token":"funding-token","state":"ENABLED","type":"DEPOSITORY_CHECKING","created":"2026-01-01T00:00:00Z"},"exp_month":"01","exp_year":"2030"}'
        return 0
    }

    privacy_com_validate_schema() {
        return 0
    }

    if ! privacy_com_pause_card "tok_abc"; then
        echo "FAIL: expected privacy_com_pause_card request construction call to succeed" >&2
        return 1
    fi
    assert_equals "$captured_method" "PATCH" "pause_card_request_method" || return 1
    assert_equals "$captured_path" "/v1/cards/tok_abc" "pause_card_request_path" || return 1
    assert_equals "$captured_auth_mode" "raw" "pause_card_request_auth_mode" || return 1
    assert_equals "$captured_body" '{"state":"PAUSED"}' "pause_card_request_body" || return 1

    if ! privacy_com_unpause_card "tok_abc"; then
        echo "FAIL: expected privacy_com_unpause_card request construction call to succeed" >&2
        return 1
    fi
    assert_equals "$captured_method" "PATCH" "unpause_card_request_method" || return 1
    assert_equals "$captured_path" "/v1/cards/tok_abc" "unpause_card_request_path" || return 1
    assert_equals "$captured_auth_mode" "raw" "unpause_card_request_auth_mode" || return 1
    assert_equals "$captured_body" '{"state":"OPEN"}' "unpause_card_request_body" || return 1

    privacy_com_request() {
        echo "FAIL: empty token path should not invoke privacy_com_request" >&2
        return 1
    }

    local rc=0
    if privacy_com_pause_card ""; then
        echo "FAIL: expected privacy_com_pause_card to reject empty token" >&2
        return 1
    else
        rc=$?
    fi
    assert_equals "$rc" "$PRIVACY_CLIENT_EXIT_SCHEMA_MISMATCH" "pause_card_empty_token_exit_code" || return 1
    assert_equals "$PRIVACY_CLIENT_EXIT_CLASS" "schema_mismatch" "pause_card_empty_token_class" || return 1
    assert_equals "$PRIVACY_CLIENT_ERROR_MESSAGE" "card token is required" "pause_card_empty_token_message" || return 1

    if privacy_com_unpause_card ""; then
        echo "FAIL: expected privacy_com_unpause_card to reject empty token" >&2
        return 1
    else
        rc=$?
    fi
    assert_equals "$rc" "$PRIVACY_CLIENT_EXIT_SCHEMA_MISMATCH" "unpause_card_empty_token_exit_code" || return 1
    assert_equals "$PRIVACY_CLIENT_EXIT_CLASS" "schema_mismatch" "unpause_card_empty_token_class" || return 1
    assert_equals "$PRIVACY_CLIENT_ERROR_MESSAGE" "card token is required" "unpause_card_empty_token_message" || return 1

    privacy_com_request() {
        PRIVACY_CLIENT_EXIT_CLASS="ok"
        PRIVACY_CLIENT_HTTP_CODE="200"
        PRIVACY_CLIENT_BODY='{"not":"a-card"}'
        return 0
    }

    privacy_com_validate_schema() {
        return 1
    }

    if privacy_com_pause_card "tok_abc"; then
        echo "FAIL: expected privacy_com_pause_card malformed response to fail schema validation" >&2
        return 1
    else
        rc=$?
    fi
    assert_equals "$rc" "$PRIVACY_CLIENT_EXIT_SCHEMA_MISMATCH" "pause_card_malformed_response_exit_code" || return 1
    assert_equals "$PRIVACY_CLIENT_EXIT_CLASS" "schema_mismatch" "pause_card_malformed_response_class" || return 1

    if privacy_com_unpause_card "tok_abc"; then
        echo "FAIL: expected privacy_com_unpause_card malformed response to fail schema validation" >&2
        return 1
    else
        rc=$?
    fi
    assert_equals "$rc" "$PRIVACY_CLIENT_EXIT_SCHEMA_MISMATCH" "unpause_card_malformed_response_exit_code" || return 1
    assert_equals "$PRIVACY_CLIENT_EXIT_CLASS" "schema_mismatch" "unpause_card_malformed_response_class" || return 1
}

run_unit_card_limit_recovery_checks() {
    local create_attempts=0
    local close_attempts=0
    local list_attempts=0

    privacy_com_create_card() {
        create_attempts=$((create_attempts + 1))
        if [ "$create_attempts" -eq 1 ]; then
            PRIVACY_CLIENT_EXIT_CLASS="http_error"
            PRIVACY_CLIENT_HTTP_CODE="405"
            PRIVACY_CLIENT_BODY='{"message":"You'\''ve reached your max allowed Card limit and cannot create more"}'
            return 12
        fi
        PRIVACY_CLIENT_EXIT_CLASS="ok"
        PRIVACY_CLIENT_HTTP_CODE="200"
        PRIVACY_CLIENT_BODY='{"token":"retry-created","state":"OPEN","type":"MERCHANT_LOCKED","spend_limit":1000,"spend_limit_duration":"FOREVER","created":"2026-01-01T00:00:00Z","funding":{"token":"funding-token","state":"ENABLED","type":"DEPOSITORY_CHECKING","created":"2026-01-01T00:00:00Z"},"exp_month":"01","exp_year":"2030"}'
        return 0
    }

    privacy_com_list_cards_raw_auth() {
        list_attempts=$((list_attempts + 1))
        PRIVACY_CLIENT_EXIT_CLASS="ok"
        PRIVACY_CLIENT_HTTP_CODE="200"
        PRIVACY_CLIENT_BODY='{"data":[{"token":"open-probe-token","state":"OPEN","memo":"fjcloud stage2 contract probe"}],"page":1,"total_entries":1,"total_pages":1}'
        return 0
    }

    privacy_com_close_card() {
        close_attempts=$((close_attempts + 1))
        assert_equals "$1" "open-probe-token" "reclaim_close_token"
        PRIVACY_CLIENT_EXIT_CLASS="ok"
        PRIVACY_CLIENT_HTTP_CODE="200"
        PRIVACY_CLIENT_BODY='{"token":"open-probe-token","state":"CLOSED","type":"MERCHANT_LOCKED","spend_limit":1000,"spend_limit_duration":"FOREVER","created":"2026-01-01T00:00:00Z","funding":{"token":"funding-token","state":"ENABLED","type":"DEPOSITORY_CHECKING","created":"2026-01-01T00:00:00Z"},"exp_month":"01","exp_year":"2030"}'
        return 0
    }

    if ! create_card_with_capacity_recovery; then
        echo "FAIL: expected create_card_with_capacity_recovery to recover from card limit and succeed" >&2
        return 1
    fi

    assert_equals "$create_attempts" "2" "reclaim_retries_create_once"
    assert_equals "$close_attempts" "1" "reclaim_closes_one_probe_card"
    assert_equals "$list_attempts" "1" "reclaim_lists_cards_once"
    assert_equals "$PRIVACY_CLIENT_EXIT_CLASS" "ok" "reclaim_final_class"
}

run_unit_card_limit_recovery_no_reclaimable_checks() {
    local create_attempts=0
    local close_attempts=0
    local list_attempts=0

    privacy_com_create_card() {
        create_attempts=$((create_attempts + 1))
        PRIVACY_CLIENT_EXIT_CLASS="http_error"
        PRIVACY_CLIENT_HTTP_CODE="405"
        PRIVACY_CLIENT_BODY='{"message":"You'\''ve reached your max allowed Card limit and cannot create more"}'
        return 12
    }

    privacy_com_list_cards_raw_auth() {
        list_attempts=$((list_attempts + 1))
        PRIVACY_CLIENT_EXIT_CLASS="ok"
        PRIVACY_CLIENT_HTTP_CODE="200"
        PRIVACY_CLIENT_BODY='{"data":[{"token":"closed-card","state":"CLOSED","memo":"fjcloud stage2 contract probe"}],"page":1,"total_entries":1,"total_pages":1}'
        return 0
    }

    privacy_com_close_card() {
        close_attempts=$((close_attempts + 1))
        return 0
    }

    if create_card_with_capacity_recovery 2>/dev/null; then
        echo "FAIL: expected create_card_with_capacity_recovery to fail without reclaimable OPEN cards" >&2
        return 1
    fi

    assert_equals "$create_attempts" "1" "reclaim_no_open_cards_no_retry"
    assert_equals "$list_attempts" "1" "reclaim_no_open_cards_lists_once"
    assert_equals "$close_attempts" "0" "reclaim_no_open_cards_no_close"
    assert_equals "$PRIVACY_CLIENT_EXIT_CLASS" "http_error" "reclaim_no_open_cards_preserves_class"
    assert_equals "$PRIVACY_CLIENT_HTTP_CODE" "405" "reclaim_no_open_cards_preserves_code"
    require_json_field "$PRIVACY_CLIENT_BODY" "message" "reclaim_no_open_cards_preserves_body"
}

cleanup_token=""
cleanup_open="0"
with_cleanup_state_restored() {
    local cleanup_token_before="$cleanup_token"
    local cleanup_open_before="$cleanup_open"
    local command_status=0

    "$@" || command_status=$?

    cleanup_token="$cleanup_token_before"
    cleanup_open="$cleanup_open_before"
    return "$command_status"
}

run_unit_cleanup_registration_checks() {
    cleanup_token=""
    cleanup_open="0"
    register_cleanup_from_card_body '{"token":"unit-token-123"}'
    assert_equals "$cleanup_token" "unit-token-123" "cleanup_token_registration" || return 1
    assert_equals "$cleanup_open" "1" "cleanup_open_registration" || return 1

    if [ "${PRIVACY_TEST_FORCE_ASSERT_FAILURE:-0}" = "1" ]; then
        assert_equals "$cleanup_open" "0" "forced_cleanup_assert_failure" || return 1
    fi

    if register_cleanup_from_card_body '{"token":""}' 2>/dev/null; then
        echo "FAIL: expected register_cleanup_from_card_body to fail on empty token" >&2
        return 1
    fi
}

run_unit_cleanup_restore_failure_path_checks() {
    local cleanup_token_before="$cleanup_token"
    local cleanup_open_before="$cleanup_open"
    local original_force_failure="${PRIVACY_TEST_FORCE_ASSERT_FAILURE:-0}"

    PRIVACY_TEST_FORCE_ASSERT_FAILURE="1"
    if with_cleanup_state_restored run_unit_cleanup_registration_checks 2>/dev/null; then
        echo "FAIL: expected forced cleanup assertion failure path to fail" >&2
        PRIVACY_TEST_FORCE_ASSERT_FAILURE="$original_force_failure"
        return 1
    fi
    PRIVACY_TEST_FORCE_ASSERT_FAILURE="$original_force_failure"

    assert_equals "$cleanup_token" "$cleanup_token_before" "cleanup_token_restored_after_forced_failure"
    assert_equals "$cleanup_open" "$cleanup_open_before" "cleanup_open_restored_after_forced_failure"
}

run_unit_expected_failure_paths_are_quiet_checks() {
    local stderr_capture=""
    stderr_capture="$(mktemp)"

    if ! run_unit_card_limit_recovery_no_reclaimable_checks 2>"$stderr_capture"; then
        rm -f "$stderr_capture"
        echo "FAIL: expected no-reclaimable recovery path check to pass its assertions" >&2
        return 1
    fi
    if rg -q '^FAIL:' "$stderr_capture"; then
        rm -f "$stderr_capture"
        echo "FAIL: no-reclaimable recovery path leaked FAIL output on expected failure branch" >&2
        return 1
    fi

    : > "$stderr_capture"
    if ! run_unit_cleanup_restore_failure_path_checks 2>"$stderr_capture"; then
        rm -f "$stderr_capture"
        echo "FAIL: expected cleanup restore failure-path check to pass its assertions" >&2
        return 1
    fi
    if rg -q '^FAIL:' "$stderr_capture"; then
        rm -f "$stderr_capture"
        echo "FAIL: cleanup restore failure-path check leaked FAIL output on expected failure branch" >&2
        return 1
    fi

    rm -f "$stderr_capture"
}

register_cleanup_from_card_body() {
    local json_body="$1"
    local card_token
    card_token="$(python3 - "$json_body" <<"PY"
import json
import sys
print(json.loads(sys.argv[1]).get("token", ""))
PY
)"

    if [ -z "$card_token" ]; then
        echo "FAIL: create response missing token required for cleanup" >&2
        return 1
    fi

    cleanup_token="$card_token"
    cleanup_open="1"
}

cleanup_card() {
    if [ -n "$cleanup_token" ] && [ "$cleanup_open" = "1" ]; then
        privacy_com_close_card "$cleanup_token" >/dev/null 2>&1 || true
    fi
}
trap cleanup_card EXIT

if [ "${PRIVACY_CLIENT_TEST_MODE:-}" = "unit_only" ]; then
    run_unit_contract_checks
    echo "PASS: privacy_com_client unit contract assertions succeeded"
    exit 0
fi

if ! privacy_com_require_env; then
    echo "FAIL: privacy env load failed (${PRIVACY_CLIENT_ERROR_MESSAGE})" >&2
    exit 1
fi

if ! privacy_com_list_cards_raw_auth 1 2; then
    echo "FAIL: raw auth list call returned non-zero class=$PRIVACY_CLIENT_EXIT_CLASS code=$PRIVACY_CLIENT_HTTP_CODE body=$PRIVACY_CLIENT_BODY" >&2
    exit 1
fi
if [ "$PRIVACY_CLIENT_EXIT_CLASS" != "ok" ]; then
    echo "FAIL: raw auth list call failed class=$PRIVACY_CLIENT_EXIT_CLASS code=$PRIVACY_CLIENT_HTTP_CODE" >&2
    exit 1
fi
require_json_field "$PRIVACY_CLIENT_BODY" "data" "list_raw"
require_json_field "$PRIVACY_CLIENT_BODY" "page" "list_raw"
require_json_field "$PRIVACY_CLIENT_BODY" "total_entries" "list_raw"
require_json_field "$PRIVACY_CLIENT_BODY" "total_pages" "list_raw"

if ! privacy_com_list_cards_prefixed_auth 1 2; then
    echo "FAIL: api-key auth list call returned non-zero class=$PRIVACY_CLIENT_EXIT_CLASS code=$PRIVACY_CLIENT_HTTP_CODE body=$PRIVACY_CLIENT_BODY" >&2
    exit 1
fi
if [ "$PRIVACY_CLIENT_EXIT_CLASS" != "ok" ]; then
    echo "FAIL: api-key auth list call failed class=$PRIVACY_CLIENT_EXIT_CLASS code=$PRIVACY_CLIENT_HTTP_CODE" >&2
    exit 1
fi

if privacy_com_list_cards_missing_auth 1 2; then
    echo "FAIL: missing-auth list unexpectedly succeeded" >&2
    exit 1
fi
if [ "$PRIVACY_CLIENT_EXIT_CLASS" != "http_error" ]; then
    echo "FAIL: missing-auth expected http_error class, got $PRIVACY_CLIENT_EXIT_CLASS" >&2
    exit 1
fi

if ! create_card_with_capacity_recovery; then
    echo "FAIL: create card returned non-zero class=$PRIVACY_CLIENT_EXIT_CLASS code=$PRIVACY_CLIENT_HTTP_CODE body=$PRIVACY_CLIENT_BODY" >&2
    exit 1
fi
if [ "$PRIVACY_CLIENT_EXIT_CLASS" != "ok" ]; then
    echo "FAIL: create card failed class=$PRIVACY_CLIENT_EXIT_CLASS code=$PRIVACY_CLIENT_HTTP_CODE" >&2
    exit 1
fi
require_card_schema "$PRIVACY_CLIENT_BODY" "create"
register_cleanup_from_card_body "$PRIVACY_CLIENT_BODY"
assert_state_equals "$PRIVACY_CLIENT_BODY" "OPEN" "create"
assert_spend_limit_duration_equals "$PRIVACY_CLIENT_BODY" "FOREVER" "create"

if ! privacy_com_get_card "$cleanup_token"; then
    echo "FAIL: get card returned non-zero class=$PRIVACY_CLIENT_EXIT_CLASS code=$PRIVACY_CLIENT_HTTP_CODE body=$PRIVACY_CLIENT_BODY" >&2
    exit 1
fi
if [ "$PRIVACY_CLIENT_EXIT_CLASS" != "ok" ]; then
    echo "FAIL: get card failed class=$PRIVACY_CLIENT_EXIT_CLASS code=$PRIVACY_CLIENT_HTTP_CODE" >&2
    exit 1
fi
require_card_schema "$PRIVACY_CLIENT_BODY" "get_before_close"
assert_state_equals "$PRIVACY_CLIENT_BODY" "OPEN" "get_before_close"

if ! privacy_com_close_card "$cleanup_token"; then
    echo "FAIL: close card returned non-zero class=$PRIVACY_CLIENT_EXIT_CLASS code=$PRIVACY_CLIENT_HTTP_CODE body=$PRIVACY_CLIENT_BODY" >&2
    exit 1
fi
if [ "$PRIVACY_CLIENT_EXIT_CLASS" != "ok" ]; then
    echo "FAIL: close card failed class=$PRIVACY_CLIENT_EXIT_CLASS code=$PRIVACY_CLIENT_HTTP_CODE" >&2
    exit 1
fi
require_card_schema "$PRIVACY_CLIENT_BODY" "close"
assert_state_equals "$PRIVACY_CLIENT_BODY" "CLOSED" "close"
cleanup_open="0"

if ! privacy_com_get_card "$cleanup_token"; then
    echo "FAIL: get card after close returned non-zero class=$PRIVACY_CLIENT_EXIT_CLASS code=$PRIVACY_CLIENT_HTTP_CODE body=$PRIVACY_CLIENT_BODY" >&2
    exit 1
fi
if [ "$PRIVACY_CLIENT_EXIT_CLASS" != "ok" ]; then
    echo "FAIL: get card after close failed class=$PRIVACY_CLIENT_EXIT_CLASS code=$PRIVACY_CLIENT_HTTP_CODE" >&2
    exit 1
fi
require_card_schema "$PRIVACY_CLIENT_BODY" "get_after_close"
assert_state_equals "$PRIVACY_CLIENT_BODY" "CLOSED" "get_after_close"

run_unit_contract_checks

echo "PASS: privacy_com_client live contract assertions succeeded"
