#!/usr/bin/env bash
# One-shot cold-customer journey CLI probe for the Algolia-refugee audit lane.
#
# The transport seam intentionally stays at `curl()` because scripts/lib/http_json.sh
# calls curl directly. Dry-run and tests override that function so the shared HTTP
# helpers remain the single request owner.
# shellcheck disable=SC2034,SC1091
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

source "$REPO_ROOT/scripts/lib/env.sh"
source "$REPO_ROOT/scripts/lib/http_json.sh"
source "$REPO_ROOT/scripts/lib/test_inbox_helpers.sh"
source "$REPO_ROOT/scripts/lib/customer_lifecycle_steps.sh"
source "$REPO_ROOT/scripts/lib/deterministic_batch_payload.sh"

COLD_CUSTOMER_ENV="staging"
COLD_CUSTOMER_DRY_RUN=0
COLD_CUSTOMER_ENV_FILE=""
COLD_CUSTOMER_EVIDENCE_DIR=""
COLD_CUSTOMER_STEPS_FILE=""
COLD_CUSTOMER_SUMMARY_FILE=""
COLD_CUSTOMER_BATCH_SEED=""
COLD_CUSTOMER_SEARCH_TERM=""
COLD_CUSTOMER_BATCH_ACCEPTED=0
COLD_CUSTOMER_VERIFIED=false
COLD_CUSTOMER_SEEDED_RECORD_OBJECT_ID=""
COLD_CUSTOMER_SEEDED_RECORD_TITLE=""
COLD_CUSTOMER_FAILURE_STEP=""
COLD_CUSTOMER_FAILURE_DETAIL=""
COLD_CUSTOMER_SEARCH_RETRY_SLEEP_SECONDS="${COLD_CUSTOMER_SEARCH_RETRY_SLEEP_SECONDS:-2}"
COLD_CUSTOMER_SEARCH_MAX_ATTEMPTS="${COLD_CUSTOMER_SEARCH_MAX_ATTEMPTS:-8}"
COLD_CUSTOMER_DRY_RUN_STUBS_INSTALLED=0

log() {
    echo "[cold-customer-walkthrough] $*"
}

cold_customer_usage() {
    cat <<'EOF'
Usage: cold_customer_journey_walkthrough.sh --evidence-dir DIR [--dry-run] [--env-file FILE] [--env staging]

Options:
  --dry-run          Use deterministic stubbed HTTP and inbox responses.
  --env-file FILE    Required for live mode; optional for dry-run.
  --evidence-dir DIR Directory for cli_steps.jsonl and summary.json.
  --env staging      Only staging is accepted.
EOF
}

cold_customer_epoch_ms() {
    python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
}

cold_customer_json_quote() {
    python3 - "$1" <<'PY'
import json
import sys
print(json.dumps(sys.argv[1]))
PY
}

cold_customer_json_field() {
    local json_body="$1"
    local field_name="$2"

    printf '%s' "$json_body" | python3 -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except json.JSONDecodeError:
    raise SystemExit(0)
value = payload.get(sys.argv[1], "")
if value is None:
    print("")
elif isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
' "$field_name" || true
}

cold_customer_json_array_length() {
    local json_body="$1"
    local field_name="$2"

    printf '%s' "$json_body" | python3 -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except json.JSONDecodeError:
    raise SystemExit(0)
value = payload.get(sys.argv[1])
if isinstance(value, list):
    print(len(value))
' "$field_name" || true
}

cold_customer_reset_invocation_mode() {
    COLD_CUSTOMER_ENV="staging"
    COLD_CUSTOMER_DRY_RUN=0
    COLD_CUSTOMER_ENV_FILE=""
    COLD_CUSTOMER_EVIDENCE_DIR=""
    if [ "${COLD_CUSTOMER_DRY_RUN_STUBS_INSTALLED:-0}" -eq 1 ] \
        && [ "${COLD_CUSTOMER_TEST_CURL_STUB:-0}" != "1" ]; then
        unset -f curl 2>/dev/null || true
        unset -f test_inbox_find_matching_object_key 2>/dev/null || true
        unset -f test_inbox_fetch_rfc822 2>/dev/null || true
    fi
    if [ "${COLD_CUSTOMER_DRY_RUN_STUBS_INSTALLED:-0}" -eq 1 ]; then
        unset ADMIN_KEY 2>/dev/null || true
        unset CANARY_TEST_INBOX_S3_URI 2>/dev/null || true
        unset CANARY_TEST_INBOX_DOMAIN 2>/dev/null || true
    fi
    COLD_CUSTOMER_DRY_RUN_STUBS_INSTALLED=0
}

cold_customer_reset_run_state() {
    COLD_CUSTOMER_BATCH_SEED=""
    COLD_CUSTOMER_SEARCH_TERM=""
    COLD_CUSTOMER_BATCH_ACCEPTED=0
    COLD_CUSTOMER_VERIFIED=false
    COLD_CUSTOMER_SEEDED_RECORD_OBJECT_ID=""
    COLD_CUSTOMER_SEEDED_RECORD_TITLE=""
    COLD_CUSTOMER_FAILURE_STEP=""
    COLD_CUSTOMER_FAILURE_DETAIL=""
    COLD_CUSTOMER_SEARCH_RETRY_SLEEP_SECONDS="${COLD_CUSTOMER_SEARCH_RETRY_SLEEP_SECONDS:-2}"
    COLD_CUSTOMER_SEARCH_MAX_ATTEMPTS="${COLD_CUSTOMER_SEARCH_MAX_ATTEMPTS:-8}"
    HTTP_RESPONSE_CODE=0
    HTTP_RESPONSE_BODY=""
    HTTP_RESPONSE_EXIT_STATUS=0
}

cold_customer_parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --dry-run)
                COLD_CUSTOMER_DRY_RUN=1
                shift
                ;;
            --env-file)
                COLD_CUSTOMER_ENV_FILE="${2:-}"
                shift 2
                ;;
            --evidence-dir)
                COLD_CUSTOMER_EVIDENCE_DIR="${2:-}"
                shift 2
                ;;
            --env)
                COLD_CUSTOMER_ENV="${2:-}"
                shift 2
                ;;
            --help|-h)
                cold_customer_usage
                return 2
                ;;
            *)
                echo "unknown argument: $1" >&2
                cold_customer_usage >&2
                return 2
                ;;
        esac
    done

    if [ "$COLD_CUSTOMER_ENV" != "staging" ]; then
        echo "--env must be staging (got ${COLD_CUSTOMER_ENV})" >&2
        return 2
    fi
    if [ -z "$COLD_CUSTOMER_EVIDENCE_DIR" ]; then
        echo "--evidence-dir is required" >&2
        return 2
    fi
    if [ "$COLD_CUSTOMER_DRY_RUN" -eq 0 ] && [ -z "$COLD_CUSTOMER_ENV_FILE" ]; then
        echo "--env-file is required outside --dry-run" >&2
        return 2
    fi
}

cold_customer_prepare_environment() {
    mkdir -p "$COLD_CUSTOMER_EVIDENCE_DIR"
    COLD_CUSTOMER_STEPS_FILE="$COLD_CUSTOMER_EVIDENCE_DIR/cli_steps.jsonl"
    COLD_CUSTOMER_SUMMARY_FILE="$COLD_CUSTOMER_EVIDENCE_DIR/summary.json"
    : > "$COLD_CUSTOMER_STEPS_FILE"
    cold_customer_reset_run_state

    if [ -n "$COLD_CUSTOMER_ENV_FILE" ]; then
        if [ ! -f "$COLD_CUSTOMER_ENV_FILE" ]; then
            echo "env file not found: $COLD_CUSTOMER_ENV_FILE" >&2
            return 2
        fi
        load_env_file "$COLD_CUSTOMER_ENV_FILE"
    fi

    API_URL="${API_URL:-https://api.staging.flapjack.foo}"
    API_URL="${API_URL%/}"
    if [ "$API_URL" != "https://api.staging.flapjack.foo" ]; then
        echo "API_URL must be https://api.staging.flapjack.foo (got ${API_URL})" >&2
        return 2
    fi

    CANARY_TEST_INBOX_DOMAIN="${CANARY_TEST_INBOX_DOMAIN:-${TEST_INBOX_DOMAIN:-test.flapjack.foo}}"
    CANARY_TEST_INBOX_S3_URI="${CANARY_TEST_INBOX_S3_URI:-${INBOUND_ROUNDTRIP_S3_URI:-}}"
    CANARY_AWS_REGION="${CANARY_AWS_REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}}"
    CANARY_INBOX_MAX_ATTEMPTS="${CANARY_INBOX_MAX_ATTEMPTS:-12}"
    CANARY_INBOX_SLEEP_SECONDS="${CANARY_INBOX_SLEEP_SECONDS:-5}"
    CANARY_INDEX_REGION="${CANARY_INDEX_REGION:-us-east-1}"
    FLOW_FAILED=0
    FLOW_FAILURE_STEP=""
    FLOW_FAILURE_DETAIL=""
    CANARY_INDEX_NAME=""
    CANARY_INDEX_CREATED=0
    CANARY_CUSTOMER_ID=""
    CANARY_TOKEN=""
    CANARY_ACCOUNT_DELETED=0
    CANARY_ADMIN_CLEANED=0
}

cold_customer_body_shape_keys_json() {
    local body="$1"
    printf '%s' "$body" | python3 -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except json.JSONDecodeError:
    print("[]")
    raise SystemExit(0)
if isinstance(payload, dict):
    print(json.dumps(sorted(payload.keys())))
else:
    print("[]")
'
}

cold_customer_append_step_evidence() {
    local step="$1"
    local outcome="$2"
    local detail="$3"
    local latency_ms="$4"
    local shape_keys
    shape_keys="$(cold_customer_body_shape_keys_json "${HTTP_RESPONSE_BODY:-}")"

    python3 - "$COLD_CUSTOMER_STEPS_FILE" "$step" "${HTTP_RESPONSE_CODE:-0}" \
        "$shape_keys" "$latency_ms" "$outcome" "$detail" "${HTTP_RESPONSE_BODY:-}" <<'PY'
import json
import sys

path, step, status, keys_json, latency, outcome, detail, response_body = sys.argv[1:]

def sanitize_search_response(raw_body):
    try:
        parsed = json.loads(raw_body)
    except json.JSONDecodeError:
        return raw_body
    if not isinstance(parsed, dict):
        return parsed

    sanitized = {}
    for key in ("query", "nbHits", "page", "hitsPerPage"):
        if key in parsed:
            sanitized[key] = parsed[key]

    hits = parsed.get("hits")
    if isinstance(hits, list):
        sanitized_hits = []
        for hit in hits:
            if not isinstance(hit, dict):
                continue
            sanitized_hit = {}
            for field in ("objectID", "title", "body"):
                if field in hit:
                    sanitized_hit[field] = hit[field]
            sanitized_hits.append(sanitized_hit)
        sanitized["hits"] = sanitized_hits

    return sanitized

payload = {
    "step": step,
    "http_status": int(status) if status.isdigit() else 0,
    "body_shape_keys": json.loads(keys_json),
    "latency_ms": int(latency),
    "outcome": outcome,
}
if detail:
    payload["detail"] = detail
if step == "search_index" and response_body:
    payload["response_body"] = sanitize_search_response(response_body)
with open(path, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(payload, sort_keys=True) + "\n")
PY
}

cold_customer_probe_sha() {
    git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown\n'
}

cold_customer_write_summary() {
    local overall="$1"
    local failing_step="$2"
    local detail="$3"
    local probe_sha
    probe_sha="$(cold_customer_probe_sha)"

    python3 - "$COLD_CUSTOMER_SUMMARY_FILE" "$overall" "$failing_step" "$detail" \
        "$probe_sha" "${CANARY_CUSTOMER_ID:-}" "$COLD_CUSTOMER_VERIFIED" \
        "${CANARY_INDEX_NAME:-}" "$COLD_CUSTOMER_BATCH_ACCEPTED" \
        "$COLD_CUSTOMER_SEEDED_RECORD_OBJECT_ID" "$COLD_CUSTOMER_SEEDED_RECORD_TITLE" <<'PY'
import json
import sys

(
    path,
    overall,
    failing_step,
    detail,
    probe_sha,
    customer_id,
    verified,
    index_name,
    batch_accepted,
    seeded_object_id,
    seeded_title,
) = sys.argv[1:]
payload = {
    "overall": overall,
    "failing_step": failing_step,
    "detail": detail,
    "probe_sha": probe_sha,
    "customer_id": customer_id,
    "verified": verified == "true",
    "index_name": index_name,
    "batch_accepted": int(batch_accepted) if batch_accepted.isdigit() else 0,
    "seeded_record_object_id": seeded_object_id,
    "seeded_record_title": seeded_title,
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

cold_customer_fail() {
    COLD_CUSTOMER_FAILURE_STEP="$1"
    COLD_CUSTOMER_FAILURE_DETAIL="$2"
}

cold_customer_run_evidenced_step() {
    local step="$1"
    local command_name="$2"
    local assertion_name="$3"
    local start_ms end_ms latency_ms detail

    start_ms="$(cold_customer_epoch_ms)"
    FLOW_FAILED=0
    FLOW_FAILURE_STEP=""
    FLOW_FAILURE_DETAIL=""
    COLD_CUSTOMER_FAILURE_STEP=""
    COLD_CUSTOMER_FAILURE_DETAIL=""
    HTTP_RESPONSE_CODE=0
    HTTP_RESPONSE_BODY=""
    HTTP_RESPONSE_EXIT_STATUS=0
    if "$command_name" && "$assertion_name"; then
        end_ms="$(cold_customer_epoch_ms)"
        latency_ms=$((end_ms - start_ms))
        cold_customer_append_step_evidence "$step" "pass" "" "$latency_ms"
        return 0
    fi

    end_ms="$(cold_customer_epoch_ms)"
    latency_ms=$((end_ms - start_ms))
    detail="${COLD_CUSTOMER_FAILURE_DETAIL:-${FLOW_FAILURE_DETAIL:-step_failed}}"
    cold_customer_append_step_evidence "$step" "fail" "$detail" "$latency_ms"
    cold_customer_fail "$step" "$detail"
    return 1
}

cold_customer_assert_register() {
    if [ -z "${CANARY_TOKEN:-}" ] || [ -z "${CANARY_CUSTOMER_ID:-}" ]; then
        cold_customer_fail "register" "missing_token_or_customer_id"
        return 1
    fi
}

cold_customer_assert_verify_email() {
    local verified message
    verified="$(cold_customer_json_field "$HTTP_RESPONSE_BODY" "verified")"
    message="$(cold_customer_json_field "$HTTP_RESPONSE_BODY" "message")"
    if [ "$verified" = "true" ] || [ "$message" = "email verified" ]; then
        return 0
    fi
    cold_customer_fail "verify_email" "verified_state_missing"
    return 1
}

cold_customer_confirm_verified_step() {
    capture_json_response tenant_call GET "/account" "$CANARY_TOKEN"
    if [ "${HTTP_RESPONSE_CODE:-}" != "200" ]; then
        cold_customer_fail "confirm_verified" "account_read_http_${HTTP_RESPONSE_CODE:-unknown}"
        return 1
    fi
    local email_verified
    email_verified="$(cold_customer_json_field "$HTTP_RESPONSE_BODY" "email_verified")"
    if [ "$email_verified" != "true" ]; then
        cold_customer_fail "confirm_verified" "email_verified_false"
        return 1
    fi
    COLD_CUSTOMER_VERIFIED=true
}

cold_customer_create_index_step() {
    local payload expected_name actual_name
    CANARY_INDEX_NAME="cold-customer-${CANARY_NONCE}"
    expected_name="$CANARY_INDEX_NAME"
    payload="$(printf '{"name":%s,"region":%s}' \
        "$(cold_customer_json_quote "$expected_name")" \
        "$(cold_customer_json_quote "$CANARY_INDEX_REGION")")"

    capture_json_response tenant_call POST "/indexes" "$CANARY_TOKEN" -d "$payload"
    if [ "${HTTP_RESPONSE_CODE:-}" != "201" ] && [ "${HTTP_RESPONSE_CODE:-}" != "200" ]; then
        cold_customer_fail "create_index" "index_create_http_${HTTP_RESPONSE_CODE:-unknown}"
        return 1
    fi
    actual_name="$(cold_customer_json_field "$HTTP_RESPONSE_BODY" "name")"
    if [ "$actual_name" != "$expected_name" ]; then
        cold_customer_fail "create_index" "created_index_name_mismatch"
        return 1
    fi
    CANARY_INDEX_CREATED=1
}

cold_customer_noop_assertion() {
    return 0
}

cold_customer_batch_write_step() {
    local payload accepted task_id
    payload="$(deterministic_batch_payload "$COLD_CUSTOMER_BATCH_SEED" 0 5)"

    capture_json_response tenant_call POST "/indexes/${CANARY_INDEX_NAME}/batch" "$CANARY_TOKEN" -d "$payload"
    if [ "${HTTP_RESPONSE_CODE:-}" != "200" ]; then
        cold_customer_fail "batch_write" "batch_write_http_${HTTP_RESPONSE_CODE:-unknown}"
        return 1
    fi
    task_id="$(cold_customer_json_field "$HTTP_RESPONSE_BODY" "taskID")"
    if [ -z "$task_id" ]; then
        cold_customer_fail "batch_write" "task_id_missing"
        return 1
    fi
    accepted="$(cold_customer_json_array_length "$HTTP_RESPONSE_BODY" "objectIDs")"
    if [ "$accepted" != "5" ]; then
        COLD_CUSTOMER_BATCH_ACCEPTED="${accepted:-0}"
        cold_customer_fail "batch_write" "accepted_count_mismatch"
        return 1
    fi
    COLD_CUSTOMER_BATCH_ACCEPTED=5
}

cold_customer_search_seeded_result() {
    printf '%s' "$1" | python3 -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except json.JSONDecodeError:
    raise SystemExit(1)
search_term = sys.argv[1]
for hit in payload.get("hits", []):
    if not isinstance(hit, dict):
        continue
    object_id = hit.get("objectID", "")
    title = hit.get("title", "")
    body = hit.get("body", "")
    if object_id == "doc-0" or title == "Document 0" or search_term in body:
        print(f"{object_id}|{title}")
        raise SystemExit(0)
raise SystemExit(1)
' "$COLD_CUSTOMER_SEARCH_TERM" || true
}

cold_customer_sleep_before_search_retry() {
    if [ "$COLD_CUSTOMER_SEARCH_RETRY_SLEEP_SECONDS" -gt 0 ]; then
        sleep "$COLD_CUSTOMER_SEARCH_RETRY_SLEEP_SECONDS"
    fi
}

cold_customer_search_index_step() {
    local payload search_result detail attempt
    payload="$(printf '{"query":%s}' "$(cold_customer_json_quote "$COLD_CUSTOMER_SEARCH_TERM")")"
    detail="seeded_record_missing"

    for attempt in $(seq 1 "$COLD_CUSTOMER_SEARCH_MAX_ATTEMPTS"); do
        capture_json_response tenant_call POST "/indexes/${CANARY_INDEX_NAME}/search" "$CANARY_TOKEN" -d "$payload"
        if [ "${HTTP_RESPONSE_CODE:-}" != "200" ]; then
            detail="search_http_${HTTP_RESPONSE_CODE:-unknown}"
        else
            search_result="$(cold_customer_search_seeded_result "$HTTP_RESPONSE_BODY")"
            if [ -n "$search_result" ]; then
                COLD_CUSTOMER_SEEDED_RECORD_OBJECT_ID="${search_result%%|*}"
                COLD_CUSTOMER_SEEDED_RECORD_TITLE="${search_result#*|}"
                return 0
            fi
            detail="seeded_record_missing"
        fi

        if [ "$attempt" -lt "$COLD_CUSTOMER_SEARCH_MAX_ATTEMPTS" ]; then
            cold_customer_sleep_before_search_retry
        fi
    done

    if [ -z "${search_result:-}" ]; then
        cold_customer_fail "search_index" "$detail"
        return 1
    fi
}

cold_customer_delete_index_step() {
    if [ "${CANARY_INDEX_CREATED:-0}" -ne 1 ] || [ -z "${CANARY_INDEX_NAME:-}" ]; then
        return 0
    fi

    capture_json_response tenant_call DELETE "/indexes/${CANARY_INDEX_NAME}" "$CANARY_TOKEN" \
        -d '{"confirm":true}'
    if [ "${HTTP_RESPONSE_CODE:-}" != "204" ] && [ "${HTTP_RESPONSE_CODE:-}" != "404" ]; then
        cold_customer_fail "delete_index" "delete_index_http_${HTTP_RESPONSE_CODE:-unknown}"
        return 1
    fi
    CANARY_INDEX_CREATED=0
}

cold_customer_delete_account_step() {
    local payload

    if [ "${CANARY_ACCOUNT_DELETED:-0}" -eq 1 ] || [ -z "${CANARY_TOKEN:-}" ]; then
        return 0
    fi

    payload="$(printf '{"password":%s}' "$(cold_customer_json_quote "${CANARY_SIGNUP_PASSWORD:-}")")"
    capture_json_response tenant_call DELETE "/account" "$CANARY_TOKEN" -d "$payload"
    if [ "${HTTP_RESPONSE_CODE:-}" != "204" ] && [ "${HTTP_RESPONSE_CODE:-}" != "404" ]; then
        cold_customer_fail "delete_account" "delete_account_http_${HTTP_RESPONSE_CODE:-unknown}"
        return 1
    fi
    CANARY_ACCOUNT_DELETED=1
}

cold_customer_admin_cleanup_step() {
    if [ -z "${CANARY_CUSTOMER_ID:-}" ] || [ "${CANARY_ADMIN_CLEANED:-0}" -eq 1 ]; then
        return 0
    fi
    if [ -z "${ADMIN_KEY:-}" ]; then
        cold_customer_fail "admin_cleanup" "admin_key_missing"
        return 1
    fi

    capture_json_response admin_call DELETE "/admin/tenants/${CANARY_CUSTOMER_ID}"
    if [ "${HTTP_RESPONSE_CODE:-}" != "204" ] && [ "${HTTP_RESPONSE_CODE:-}" != "404" ]; then
        cold_customer_fail "admin_cleanup" "admin_cleanup_http_${HTTP_RESPONSE_CODE:-unknown}"
        return 1
    fi
    CANARY_ADMIN_CLEANED=1
}

cold_customer_install_dry_run_inbox_stubs() {
    CANARY_TEST_INBOX_S3_URI="s3://cold-customer-dry-run/verification/"
    CANARY_TEST_INBOX_DOMAIN="test.flapjack.foo"
    ADMIN_KEY="${ADMIN_KEY:-dry-admin-key}"
    COLD_CUSTOMER_SEARCH_RETRY_SLEEP_SECONDS=0
    test_inbox_find_matching_object_key() { printf 'dry-run-message.eml\n'; }
    test_inbox_fetch_rfc822() { printf 'Click https://cloud.staging.flapjack.foo/verify-email/dry-verify-token\n'; }
    COLD_CUSTOMER_DRY_RUN_STUBS_INSTALLED=1
}

cold_customer_emit_curl_response() {
    local body="$1"
    local status="$2"
    local write_format="$3"

    printf '%s' "$body"
    if [ -n "$write_format" ]; then
        printf '\n%s' "$status"
    fi
}

cold_customer_dry_run_curl() {
    local method="GET" url="" data="" write_format="" path seed_body
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -X) method="$2"; shift 2 ;;
            -d) data="$2"; shift 2 ;;
            -w) write_format="$2"; shift 2 ;;
            http://*|https://*) url="$1"; shift ;;
            *) shift ;;
        esac
    done

    path="${url#https://api.staging.flapjack.foo}"
    seed_body="$(deterministic_exact_query_term_for_object_id "$COLD_CUSTOMER_BATCH_SEED" doc-0)"
    case "${method} ${path}" in
        "POST /auth/register")
            cold_customer_emit_curl_response '{"token":"dry-token","customer_id":"cust_dry_123"}' "201" "$write_format" ;;
        "POST /auth/verify-email")
            cold_customer_emit_curl_response '{"verified":true,"customer_id":"cust_dry_123"}' "200" "$write_format" ;;
        "GET /account")
            cold_customer_emit_curl_response '{"email":"cold-customer@example.com","email_verified":true}' "200" "$write_format" ;;
        "POST /indexes")
            local index_name
            index_name="$(cold_customer_json_field "$data" "name")"
            cold_customer_emit_curl_response "{\"name\":\"${index_name}\",\"region\":\"${CANARY_INDEX_REGION}\"}" "201" "$write_format" ;;
        "POST "*"/batch")
            cold_customer_emit_curl_response '{"taskID":99,"objectIDs":["doc-0","doc-1","doc-2","doc-3","doc-4"]}' "200" "$write_format" ;;
        "POST "*"/search")
            cold_customer_emit_curl_response "{\"hits\":[{\"objectID\":\"doc-0\",\"title\":\"Document 0\",\"body\":\"${seed_body}\"}]}" "200" "$write_format" ;;
        "DELETE /indexes/"*|"DELETE /account"|"DELETE /admin/tenants/cust_dry_123")
            cold_customer_emit_curl_response '' "204" "$write_format" ;;
        *)
            echo "dry-run unexpected curl call: ${method} ${url}" >&2
            return 97 ;;
    esac
}

cold_customer_install_dry_run_curl_stub() {
    if [ "${COLD_CUSTOMER_TEST_CURL_STUB:-0}" = "1" ]; then
        return 0
    fi
    curl() { cold_customer_dry_run_curl "$@"; }
    COLD_CUSTOMER_DRY_RUN_STUBS_INSTALLED=1
}

cold_customer_run_flow() {
    COLD_CUSTOMER_BATCH_SEED="$(date +%s)"
    if [ "$COLD_CUSTOMER_DRY_RUN" -eq 1 ]; then
        COLD_CUSTOMER_BATCH_SEED=42
        cold_customer_install_dry_run_inbox_stubs
        cold_customer_install_dry_run_curl_stub
    fi
    COLD_CUSTOMER_SEARCH_TERM="$(deterministic_exact_query_term_for_object_id "$COLD_CUSTOMER_BATCH_SEED" doc-0)"

    cold_customer_run_evidenced_step "register" run_signup_step cold_customer_assert_register || return 1
    cold_customer_run_evidenced_step "verify_email" run_verify_email_step cold_customer_assert_verify_email || return 1
    cold_customer_run_evidenced_step "confirm_verified" cold_customer_confirm_verified_step cold_customer_noop_assertion || return 1
    cold_customer_run_evidenced_step "create_index" cold_customer_create_index_step cold_customer_noop_assertion || return 1
    cold_customer_run_evidenced_step "batch_write" cold_customer_batch_write_step cold_customer_noop_assertion || return 1
    cold_customer_run_evidenced_step "search_index" cold_customer_search_index_step cold_customer_noop_assertion || return 1
}

cold_customer_cleanup_after_flow() {
    local prior_step="$COLD_CUSTOMER_FAILURE_STEP"
    local prior_detail="$COLD_CUSTOMER_FAILURE_DETAIL"
    local cleanup_failed=0

    if [ "${CANARY_INDEX_CREATED:-0}" -eq 1 ]; then
        cold_customer_run_evidenced_step "delete_index" cold_customer_delete_index_step cold_customer_noop_assertion || cleanup_failed=1
    fi
    if [ -n "${CANARY_TOKEN:-}" ] && [ "${CANARY_ACCOUNT_DELETED:-0}" -eq 0 ]; then
        cold_customer_run_evidenced_step "delete_account" cold_customer_delete_account_step cold_customer_noop_assertion || cleanup_failed=1
    fi
    if [ -n "${CANARY_CUSTOMER_ID:-}" ] && [ "${CANARY_ADMIN_CLEANED:-0}" -eq 0 ]; then
        cold_customer_run_evidenced_step "admin_cleanup" cold_customer_admin_cleanup_step cold_customer_noop_assertion || cleanup_failed=1
    fi

    if [ -n "$prior_step" ]; then
        COLD_CUSTOMER_FAILURE_STEP="$prior_step"
        COLD_CUSTOMER_FAILURE_DETAIL="$prior_detail"
    fi
    return "$cleanup_failed"
}

cold_customer_main() {
    local flow_rc=0 cleanup_rc=0

    cold_customer_reset_invocation_mode
    cold_customer_reset_run_state
    if ! cold_customer_parse_args "$@"; then
        return 2
    fi
    if ! cold_customer_prepare_environment; then
        return 2
    fi

    if ! cold_customer_run_flow; then
        flow_rc=1
    fi
    if ! cold_customer_cleanup_after_flow; then
        cleanup_rc=1
    fi

    if [ "$flow_rc" -eq 0 ] && [ "$cleanup_rc" -eq 0 ]; then
        cold_customer_write_summary "pass" "" ""
        log "probe passed; evidence=$COLD_CUSTOMER_EVIDENCE_DIR"
        return 0
    fi

    cold_customer_write_summary "fail" "$COLD_CUSTOMER_FAILURE_STEP" "$COLD_CUSTOMER_FAILURE_DETAIL"
    log "probe failed at ${COLD_CUSTOMER_FAILURE_STEP}: ${COLD_CUSTOMER_FAILURE_DETAIL}" >&2
    return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    cold_customer_main "$@"
fi
