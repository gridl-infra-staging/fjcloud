#!/usr/bin/env bash
# Contract test for cold_customer_journey_walkthrough.sh.
#
# Reuse decision: existing owners cover the right seams but not this exact
# cold-customer 5-document batch plus first-search proof. This test keeps the
# probe on those owners: http_json.sh's direct curl transport, customer lifecycle
# signup/verify helpers, test-inbox helpers, and deterministic_batch_payload.sh.
# The test owns only deterministic curl scenarios and evidence assertions.
# shellcheck disable=SC1091
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$SCRIPT_DIR/cold_customer_journey_walkthrough.sh"

if [ ! -f "$PROBE" ]; then
    echo "probe not found: $PROBE" >&2
    exit 1
fi

# shellcheck source=scripts/canary/contracts/cold_customer_journey_walkthrough.sh
source "$PROBE"

failures=0

fail_test() {
    echo "FAIL: $1" >&2
    failures=$((failures + 1))
}

pass_test() {
    echo "PASS: $1"
}

assert_eq() {
    local actual="$1"
    local expected="$2"
    local context="$3"
    if [ "$actual" != "$expected" ]; then
        fail_test "$context expected '$expected' but got '$actual'"
    else
        pass_test "$context"
    fi
}

json_file_field() {
    local file_path="$1"
    local field_path="$2"
    python3 - "$file_path" "$field_path" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
value = payload
for part in sys.argv[2].split("."):
    value = value[part]
if isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

jsonl_step_field() {
    local file_path="$1"
    local step_name="$2"
    local field_name="$3"
    python3 - "$file_path" "$step_name" "$field_name" <<'PY'
import json
import sys

path, step_name, field_name = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    for line in handle:
        payload = json.loads(line)
        if payload.get("step") == step_name:
            value = payload[field_name]
            if isinstance(value, list):
                print("\n".join(str(item) for item in value))
            else:
                print(value)
            raise SystemExit(0)
raise SystemExit(1)
PY
}

assert_jsonl_step_list_empty() {
    local file_path="$1"
    local step_name="$2"
    local field_name="$3"
    python3 - "$file_path" "$step_name" "$field_name" <<'PY'
import json
import sys

path, step_name, field_name = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    for line in handle:
        payload = json.loads(line)
        if payload.get("step") == step_name:
            value = payload[field_name]
            if value != []:
                raise SystemExit(1)
            raise SystemExit(0)
raise SystemExit(1)
PY
}

assert_step_evidence() {
    local evidence_dir="$1"
    local step_name="$2"
    local expected_status="$3"
    local expected_key="$4"
    local steps_file="$evidence_dir/cli_steps.jsonl"
    local actual_status outcome latency keys

    actual_status="$(jsonl_step_field "$steps_file" "$step_name" "http_status")"
    outcome="$(jsonl_step_field "$steps_file" "$step_name" "outcome")"
    latency="$(jsonl_step_field "$steps_file" "$step_name" "latency_ms")"
    keys="$(jsonl_step_field "$steps_file" "$step_name" "body_shape_keys")"

    assert_eq "$actual_status" "$expected_status" "$step_name records HTTP status"
    assert_eq "$outcome" "pass" "$step_name records pass outcome"
    if [[ ! "$latency" =~ ^[0-9]+$ ]]; then
        fail_test "$step_name latency_ms is not a non-negative integer: $latency"
    else
        pass_test "$step_name latency_ms is non-negative"
    fi
    if printf '%s\n' "$keys" | grep -Fxq "$expected_key"; then
        pass_test "$step_name body_shape_keys includes $expected_key"
    else
        fail_test "$step_name body_shape_keys missing $expected_key"
    fi
}

assert_step_detail() {
    local evidence_dir="$1"
    local step_name="$2"
    local expected_detail="$3"
    local actual_detail

    actual_detail="$(jsonl_step_field "$evidence_dir/cli_steps.jsonl" "$step_name" "detail")"
    assert_eq "$actual_detail" "$expected_detail" "$step_name records failure detail"
}

assert_call_order() {
    local calls_file="$1"
    shift

    python3 - "$calls_file" "$@" <<'PY'
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    calls = [line.strip() for line in handle if line.strip()]

position = 0
for expected in sys.argv[2:]:
    for idx in range(position, len(calls)):
        if expected in calls[idx]:
            position = idx + 1
            break
    else:
        print(f"missing call after position {position}: {expected}", file=sys.stderr)
        raise SystemExit(1)
PY
}

emit_curl_response() {
    local body="$1"
    local status="$2"
    local write_format="$3"

    printf '%s' "$body"
    if [ -n "$write_format" ]; then
        printf '\n%s' "$status"
    fi
}

assert_batch_payload() {
    local payload="$1"
    python3 - "$payload" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
requests = payload.get("requests")
if not isinstance(requests, list) or len(requests) != 5:
    raise SystemExit(1)
object_ids = [request.get("body", {}).get("objectID") for request in requests]
if object_ids != [f"doc-{idx}" for idx in range(5)]:
    raise SystemExit(1)
first = requests[0].get("body", {})
if first.get("title") != "Document 0" or "Deterministic content" not in first.get("body", ""):
    raise SystemExit(1)
PY
}

curl() {
    local method="GET"
    local url=""
    local data=""
    local write_format=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -X)
                method="$2"
                shift 2
                ;;
            -d)
                data="$2"
                shift 2
                ;;
            -w)
                write_format="$2"
                shift 2
                ;;
            http://*|https://*)
                url="$1"
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    local path="${url#https://api.staging.flapjack.foo}"
    local scenario="${COLD_CUSTOMER_STUB_SCENARIO:-success}"
    local seed_body
    seed_body="$(deterministic_exact_query_term_for_object_id 42 doc-0)"
    if [ -n "${COLD_CUSTOMER_STUB_CALLS_FILE:-}" ]; then
        printf '%s %s\n' "$method" "$path" >> "$COLD_CUSTOMER_STUB_CALLS_FILE"
    fi

    case "${method} ${path}" in
        "POST /auth/register")
            emit_curl_response '{"token":"dry-token","customer_id":"cust_dry_123"}' "201" "$write_format"
            ;;
        "POST /auth/verify-email")
            if [ "$scenario" = "verify_400" ]; then
                emit_curl_response '{"error":"invalid_token"}' "400" "$write_format"
            else
                emit_curl_response '{"verified":true,"customer_id":"cust_dry_123"}' "200" "$write_format"
            fi
            ;;
        "GET /account")
            if [ "$scenario" = "account_email_verified_false" ]; then
                emit_curl_response '{"email":"cold-customer@example.com","email_verified":false}' "200" "$write_format"
            else
                emit_curl_response '{"email":"cold-customer@example.com","email_verified":true}' "200" "$write_format"
            fi
            ;;
        "POST /indexes")
            local index_name
            index_name="$(python3 - "$data" <<'PY'
import json
import sys
print(json.loads(sys.argv[1])["name"])
PY
)"
            emit_curl_response "{\"name\":\"${index_name}\",\"region\":\"aws-us-east-1\"}" "201" "$write_format"
            ;;
        "POST "*"/batch")
            if ! assert_batch_payload "$data"; then
                emit_curl_response '{"error":"bad_batch_payload"}' "422" "$write_format"
            elif [ "$scenario" = "batch_object_ids_4" ]; then
                emit_curl_response '{"taskID":99,"objectIDs":["doc-0","doc-1","doc-2","doc-3"]}' "200" "$write_format"
            else
                emit_curl_response '{"taskID":99,"objectIDs":["doc-0","doc-1","doc-2","doc-3","doc-4"]}' "200" "$write_format"
            fi
            ;;
        "POST "*"/search")
            if [ "$scenario" = "search_zero_hits" ]; then
                emit_curl_response '{"hits":[]}' "200" "$write_format"
            elif [ "$scenario" = "search_delayed_hits" ] \
                && [ "$(grep -c 'POST /indexes/.*search' "$COLD_CUSTOMER_STUB_CALLS_FILE")" -lt 3 ]; then
                emit_curl_response '{"hits":[]}' "200" "$write_format"
            else
                emit_curl_response "{\"hits\":[{\"objectID\":\"doc-0\",\"title\":\"Document 0\",\"body\":\"${seed_body}\"}]}" "200" "$write_format"
            fi
            ;;
        "DELETE /indexes/"*)
            emit_curl_response '' "204" "$write_format"
            ;;
        "DELETE /account")
            emit_curl_response '' "204" "$write_format"
            ;;
        "DELETE /admin/tenants/cust_dry_123")
            emit_curl_response '' "204" "$write_format"
            ;;
        *)
            echo "unexpected curl call: ${method} ${url}" >&2
            return 97
            ;;
    esac
}

run_probe_scenario() {
    local scenario="$1"
    local expected_rc="$2"
    local evidence_dir
    local rc=0

    evidence_dir="$(mktemp -d "${TMPDIR:-/tmp}/cold-customer-contract.XXXXXX")"
    COLD_CUSTOMER_STUB_CALLS_FILE="$evidence_dir/curl_calls.log"
    set +e
    COLD_CUSTOMER_TEST_CURL_STUB=1 COLD_CUSTOMER_STUB_SCENARIO="$scenario" \
        cold_customer_main --dry-run --evidence-dir "$evidence_dir" \
        >"$evidence_dir/stdout.log" 2>"$evidence_dir/stderr.log"
    rc=$?
    set -e

    assert_eq "$rc" "$expected_rc" "$scenario exit code"
    printf '%s\n' "$evidence_dir"
}

success_dir="$(run_probe_scenario success 0 | tail -1)"
assert_step_evidence "$success_dir" "register" "201" "token"
assert_step_evidence "$success_dir" "verify_email" "200" "verified"
assert_step_evidence "$success_dir" "confirm_verified" "200" "email_verified"
assert_step_evidence "$success_dir" "create_index" "201" "name"
assert_step_evidence "$success_dir" "batch_write" "200" "objectIDs"
assert_step_evidence "$success_dir" "search_index" "200" "hits"
assert_call_order "$success_dir/curl_calls.log" \
    "POST /auth/verify-email" \
    "GET /account" \
    "POST /indexes" \
    "POST /indexes/cold-customer-" \
    "DELETE /indexes/cold-customer-" \
    "DELETE /account" \
    "DELETE /admin/tenants/cust_dry_123"
assert_eq "$(json_file_field "$success_dir/summary.json" "overall")" "pass" "summary overall pass"
assert_eq "$(json_file_field "$success_dir/summary.json" "customer_id")" "cust_dry_123" "summary records customer_id"
assert_eq "$(json_file_field "$success_dir/summary.json" "verified")" "true" "summary records verified account"
assert_eq "$(json_file_field "$success_dir/summary.json" "batch_accepted")" "5" "summary records accepted document count"
assert_eq "$(json_file_field "$success_dir/summary.json" "seeded_record_object_id")" "doc-0" "summary records returned seeded objectID"

delayed_search_dir="$(run_probe_scenario search_delayed_hits 0 | tail -1)"
assert_eq "$(grep -c 'POST /indexes/cold-customer-.*search' "$delayed_search_dir/curl_calls.log")" "3" "delayed search retries until seeded record appears"
assert_eq "$(json_file_field "$delayed_search_dir/summary.json" "overall")" "pass" "delayed search summary overall"
assert_eq "$(json_file_field "$delayed_search_dir/summary.json" "seeded_record_object_id")" "doc-0" "delayed search summary records seeded objectID"

verify_fail_dir="$(run_probe_scenario verify_400 1 | tail -1)"
assert_eq "$(json_file_field "$verify_fail_dir/summary.json" "overall")" "fail" "verify failure summary overall"
assert_eq "$(json_file_field "$verify_fail_dir/summary.json" "failing_step")" "verify_email" "verify failure step"
assert_eq "$(json_file_field "$verify_fail_dir/summary.json" "verified")" "false" "verify failure summary resets verified state"
assert_eq "$(json_file_field "$verify_fail_dir/summary.json" "batch_accepted")" "0" "verify failure summary resets batch count"
assert_eq "$(json_file_field "$verify_fail_dir/summary.json" "seeded_record_object_id")" "" "verify failure summary resets seeded objectID"

batch_fail_dir="$(run_probe_scenario batch_object_ids_4 1 | tail -1)"
assert_eq "$(json_file_field "$batch_fail_dir/summary.json" "failing_step")" "batch_write" "batch failure step"
assert_eq "$(json_file_field "$batch_fail_dir/summary.json" "detail")" "accepted_count_mismatch" "batch failure detail"
assert_call_order "$batch_fail_dir/curl_calls.log" \
    "POST /indexes" \
    "POST /indexes/cold-customer-" \
    "DELETE /indexes/cold-customer-" \
    "DELETE /account" \
    "DELETE /admin/tenants/cust_dry_123"

search_fail_dir="$(run_probe_scenario search_zero_hits 1 | tail -1)"
assert_eq "$(json_file_field "$search_fail_dir/summary.json" "failing_step")" "search_index" "search failure step"
assert_eq "$(json_file_field "$search_fail_dir/summary.json" "detail")" "seeded_record_missing" "search failure detail"

# Guards finding 1: even when /auth/verify-email acknowledges the token, the probe
# must fail when GET /account.email_verified is false rather than green-light a
# regressed signup journey on response-shape alone.
account_unverified_dir="$(run_probe_scenario account_email_verified_false 1 | tail -1)"
assert_eq "$(json_file_field "$account_unverified_dir/summary.json" "failing_step")" "confirm_verified" "unverified account failure step"
assert_eq "$(json_file_field "$account_unverified_dir/summary.json" "detail")" "email_verified_false" "unverified account failure detail"
assert_eq "$(json_file_field "$account_unverified_dir/summary.json" "verified")" "false" "unverified account summary verified=false"
assert_step_detail "$account_unverified_dir" "confirm_verified" "email_verified_false"

pre_request_dir="$(mktemp -d "${TMPDIR:-/tmp}/cold-customer-pre-request.XXXXXX")"
COLD_CUSTOMER_STEPS_FILE="$pre_request_dir/cli_steps.jsonl"
: > "$COLD_CUSTOMER_STEPS_FILE"
HTTP_RESPONSE_CODE=201
HTTP_RESPONSE_BODY='{"token":"stale-register-token"}'
pre_request_failure_step() { return 1; }
set +e
cold_customer_run_evidenced_step "pre_request_failure" pre_request_failure_step cold_customer_noop_assertion >/dev/null 2>&1
pre_request_rc=$?
set -e
assert_eq "$pre_request_rc" "1" "pre-request failure exits non-zero"
assert_eq "$(jsonl_step_field "$COLD_CUSTOMER_STEPS_FILE" "pre_request_failure" "http_status")" "0" "pre-request failure clears stale HTTP status"
if assert_jsonl_step_list_empty "$COLD_CUSTOMER_STEPS_FILE" "pre_request_failure" "body_shape_keys"; then
    pass_test "pre-request failure clears stale body shape"
else
    fail_test "pre-request failure did not clear stale body shape"
fi
assert_step_detail "$pre_request_dir" "pre_request_failure" "step_failed"

# Guards finding 2: invocation-mode globals must reset between sourced runs so
# a prior --dry-run call cannot carry stubbed transport or relaxed env-file
# checks into a later live invocation in the same shell.
leak_dir="$(mktemp -d "${TMPDIR:-/tmp}/cold-customer-leak.XXXXXX")"
COLD_CUSTOMER_STUB_CALLS_FILE="$leak_dir/curl_calls.log"
set +e
COLD_CUSTOMER_TEST_CURL_STUB=1 COLD_CUSTOMER_STUB_SCENARIO=success \
    cold_customer_main --dry-run --evidence-dir "$leak_dir/run1" \
    >"$leak_dir/run1_stdout.log" 2>"$leak_dir/run1_stderr.log"
leak_first_rc=$?
COLD_CUSTOMER_TEST_CURL_STUB=1 \
    cold_customer_main --evidence-dir "$leak_dir/run2" \
    >"$leak_dir/run2_stdout.log" 2>"$leak_dir/run2_stderr.log"
leak_second_rc=$?
set -e
assert_eq "$leak_first_rc" "0" "leak guard: first sourced --dry-run passes"
assert_eq "$leak_second_rc" "2" "leak guard: second sourced run without --dry-run rejects missing --env-file"
assert_eq "$COLD_CUSTOMER_DRY_RUN" "0" "leak guard: COLD_CUSTOMER_DRY_RUN reset after second invocation"
assert_eq "$COLD_CUSTOMER_ENV_FILE" "" "leak guard: COLD_CUSTOMER_ENV_FILE reset after second invocation"
assert_eq "${ADMIN_KEY:-}" "" "leak guard: ADMIN_KEY cleared after dry-run reset"
assert_eq "${CANARY_TEST_INBOX_S3_URI:-}" "" "leak guard: CANARY_TEST_INBOX_S3_URI cleared after dry-run reset"
if grep -q "env-file is required outside --dry-run" "$leak_dir/run2_stderr.log"; then
    pass_test "leak guard: second sourced run surfaces env-file requirement"
else
    fail_test "leak guard: second sourced run did not surface env-file requirement"
fi

if [ "$failures" -ne 0 ]; then
    echo "cold customer journey walkthrough contract: $failures assertion(s) failed" >&2
    exit 1
fi

echo "cold customer journey walkthrough contract: all assertions passed"
