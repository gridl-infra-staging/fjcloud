#!/usr/bin/env bash
# Probe the customer-facing `/indexes/{name}/metrics` endpoint end-to-end using
# a transient staging signup. The route is authenticated by the dashboard JWT
# extractor (`infra/api/src/auth/tenant.rs`), so this follows the real
# signup -> verify-email -> JWT path instead of relying on a stale API-key-only
# assumption from prior artifacts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CUSTOMER_LOOP_SCRIPT="$REPO_ROOT/scripts/canary/customer_loop_synthetic.sh"
SKIP_EXIT_CODE=100

# shellcheck disable=SC1091
# shellcheck source=scripts/lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"
# shellcheck disable=SC1091
# shellcheck source=scripts/lib/http_json.sh
source "$REPO_ROOT/scripts/lib/http_json.sh"

export ALERT_DISPATCH_HELPER="${ALERT_DISPATCH_HELPER:-$REPO_ROOT/scripts/lib/alert_dispatch.sh}"
# shellcheck disable=SC1091
# shellcheck source=scripts/canary/customer_loop_synthetic.sh
source "$CUSTOMER_LOOP_SCRIPT"

PROBE_ONLY_STAGING=0
SUMMARY_JSON=""
PROBE_SUMMARY_DIR=""
PROBE_SKIP_REASON=""
PROBE_SKIP_DETAIL=""
PROBE_FAILURE_DETAIL=""
METRICS_FIRST_BODY=""
METRICS_SECOND_BODY=""
METRICS_FIRST_FETCHED_AT=""
METRICS_SECOND_FETCHED_AT=""
METRICS_SHAPE_OK=0
METRICS_CACHE_REUSE_OK=0
METRICS_POPULATED_OK=0
METRICS_TAB_DATA_BODY=""
METRICS_TAB_DATA_OK=0
METRICS_TAB_DATA_RESPONSE_TYPE=""
CUSTOMER_METRICS_POLL_SLEEP_SECONDS="${CUSTOMER_METRICS_POLL_SLEEP_SECONDS:-10}"
CUSTOMER_METRICS_SECOND_PROBE_SLEEP_SECONDS="${CUSTOMER_METRICS_SECOND_PROBE_SLEEP_SECONDS:-10}"

usage() {
	cat <<'EOF'
Usage: customer_metrics_endpoint_authenticated_probe.sh [--staging-only] [--help]

Options:
  --staging-only  Fail closed unless API_URL targets staging.
  --help          Print this help text.
EOF
}

metrics_log() {
	echo "[customer-metrics-probe] $*"
}

metrics_notice_skip() {
	echo "SKIPPED: $*"
	echo "::notice:: $*"
}

record_probe_skip() {
	PROBE_SKIP_REASON="$1"
	PROBE_SKIP_DETAIL="$2"
	if [ -n "$PROBE_SKIP_DETAIL" ]; then
		metrics_notice_skip "${PROBE_SKIP_REASON}: ${PROBE_SKIP_DETAIL}"
	else
		metrics_notice_skip "$PROBE_SKIP_REASON"
	fi
}

metrics_json_field() {
	local json_body="$1"
	local field_name="$2"

	python3 - "$json_body" "$field_name" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
value = payload.get(sys.argv[2])
if value is None:
    print("")
elif isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

metrics_shape_ok() {
	metrics_validation_ok endpoint "$1"
}

metrics_validation_ok() {
	local validation_mode="$1"
	local json_body="$2"

	python3 - "$validation_mode" "$json_body" <<'PY'
import datetime
import json
import sys

validation_mode = sys.argv[1]
payload = json.loads(sys.argv[2])
required_int_fields = (
    "documents_count",
    "storage_bytes",
    "search_requests_total",
    "write_operations_total",
)

def normalized_iso_timestamp(value):
    if not isinstance(value, str) or not value:
        raise ValueError("missing timestamp")
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"

    timezone_start = max(value.rfind("+"), value.rfind("-"))
    if timezone_start > value.rfind("T"):
        timestamp_part = value[:timezone_start]
        timezone_part = value[timezone_start:]
    else:
        timestamp_part = value
        timezone_part = ""

    dot_index = timestamp_part.rfind(".")
    if dot_index != -1:
        fraction = timestamp_part[dot_index + 1 :]
        if len(fraction) > 6 and fraction.isdigit():
            # This probe checks timestamp shape, parseability, and cache reuse;
            # truncating here does not affect billing or metering precision.
            timestamp_part = f"{timestamp_part[:dot_index]}.{fraction[:6]}"

    return timestamp_part + timezone_part

def looks_like_metrics_candidate(candidate):
    if not isinstance(candidate, dict):
        return False
    return any(
        field_name in candidate
        for field_name in (*required_int_fields, "fetched_at")
    )

def metrics_payload_fields_match(candidate, require_index):
    if not isinstance(candidate, dict):
        return False
    if require_index and (
        not isinstance(candidate.get("index"), str) or not candidate["index"]
    ):
        return False
    for field_name in required_int_fields:
        value = candidate.get(field_name)
        if not isinstance(value, int) or value < 0:
            return False
    return True

def valid_metrics_shape(candidate, require_index):
    if not metrics_payload_fields_match(candidate, require_index):
        return False
    try:
        datetime.datetime.fromisoformat(
            normalized_iso_timestamp(candidate.get("fetched_at"))
        )
    except ValueError as exc:
        raise ValueError("invalid metrics fetched_at") from exc
    return True

def decode_devalue_reference(reference, data_slots, seen):
    if type(reference) is int:
        if reference < 0 or reference >= len(data_slots):
            raise ValueError("unresolved devalue reference")
        if reference in seen:
            raise ValueError("circular devalue reference")
        return decode_devalue_value(data_slots[reference], data_slots, seen | {reference})
    return decode_devalue_value(reference, data_slots, seen)

def decode_devalue_value(value, data_slots, seen):
    if isinstance(value, dict):
        return {
            key: decode_devalue_reference(child, data_slots, seen)
            for key, child in value.items()
        }
    if isinstance(value, list):
        return [decode_devalue_reference(child, data_slots, seen) for child in value]
    return value

def walk(node):
    if isinstance(node, dict):
        if looks_like_metrics_candidate(node):
            if valid_metrics_shape(node, False):
                return True
            raise ValueError("invalid metrics payload")
        for value in node.values():
            if walk(value):
                return True
        return False
    if isinstance(node, list):
        for value in node:
            if walk(value):
                return True
        return False
    return False

def walk_sveltekit_data_payload(payload):
    nodes = payload.get("nodes")
    if not isinstance(nodes, list):
        raise ValueError("missing nodes array")

    saw_devalue_node = False
    for node in nodes:
        if not isinstance(node, dict) or node.get("type") != "data":
            continue

        node_data = node.get("data")
        if isinstance(node_data, list):
            saw_devalue_node = True
            # SvelteKit serializes load data as a flattened devalue array where
            # object properties are integer references back into this slot list.
            if not node_data or not isinstance(node_data[0], dict):
                raise ValueError("invalid devalue data node")
            if walk(decode_devalue_value(node_data[0], node_data, set())):
                return True
            continue

        if isinstance(node_data, dict) and walk(node_data):
            return True

    if saw_devalue_node:
        return False
    return walk(payload)

if validation_mode == "endpoint":
    try:
        if not valid_metrics_shape(payload, True):
            raise SystemExit(1)
    except ValueError:
        raise SystemExit(1)
elif validation_mode == "tab":
    try:
        if payload.get("type") != "data" or not walk_sveltekit_data_payload(payload):
            raise SystemExit(1)
    except ValueError:
        raise SystemExit(1)
else:
    raise SystemExit(1)
PY
}

encode_url_path_segment() {
	local raw_value="$1"

	python3 - "$raw_value" <<'PY'
import sys
from urllib.parse import quote

print(quote(sys.argv[1], safe=""))
PY
}

ensure_live_probe_prereqs() {
	local prereq_output="" prereq_rc=0 reason detail prereq_output_file

	prereq_output_file="$(mktemp)"
	test_inbox_require_aws_inbox_prereqs \
		"${CANARY_TEST_INBOX_S3_URI:-}" \
		"${CANARY_TEST_INBOX_DOMAIN:-}" >"$prereq_output_file" 2>&1 || prereq_rc=$?
	prereq_output="$(cat "$prereq_output_file")"
	rm -f "$prereq_output_file"

	case "$prereq_rc" in
		0)
			return 0
			;;
		"$SKIP_EXIT_CODE")
			reason="${prereq_output%%:*}"
			detail="${prereq_output#*: }"
			record_probe_skip "$reason" "$detail"
			return "$SKIP_EXIT_CODE"
			;;
		*)
			if [ -n "$prereq_output" ]; then
				echo "$prereq_output" >&2
			fi
			return "$prereq_rc"
			;;
	esac
}

load_probe_env() {
	if ! load_canary_probe_prereq_env; then
		return 1
	fi
	API_URL="${API_URL:-https://api.staging.flapjack.foo}"
	WEB_BASE_URL="${WEB_BASE_URL:-https://cloud.staging.flapjack.foo}"
	export API_URL
	export WEB_BASE_URL

	return 0
}

require_staging_probe_urls() {
	python3 - "$API_URL" "$WEB_BASE_URL" <<'PY'
import sys
import urllib.parse

for label, raw_url in (("API_URL", sys.argv[1]), ("WEB_BASE_URL", sys.argv[2])):
    parsed = urllib.parse.urlsplit(raw_url)
    hostname = (parsed.hostname or "").lower()
    if hostname == "staging" or hostname.startswith("staging.") or ".staging." in hostname:
        continue
    print(f"{label} must target staging when --staging-only is set (got {raw_url})", file=sys.stderr)
    raise SystemExit(1)
PY
}

create_probe_summary_dir() {
	local utc_stamp
	utc_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
	PROBE_SUMMARY_DIR="$REPO_ROOT/docs/runbooks/evidence/customer-metrics-probe/${utc_stamp}"
	mkdir -p "$PROBE_SUMMARY_DIR"
	SUMMARY_JSON="$PROBE_SUMMARY_DIR/summary.json"
}

run_metrics_request_pair() {
	local encoded_index_name

	if [ -z "${CANARY_TOKEN:-}" ] || [ -z "${CANARY_INDEX_NAME:-}" ]; then
		PROBE_FAILURE_DETAIL="CANARY_TOKEN and CANARY_INDEX_NAME must be set before probing metrics"
		return 1
	fi

	encoded_index_name="$(encode_url_path_segment "$CANARY_INDEX_NAME")"
	capture_json_response tenant_call GET "/indexes/${encoded_index_name}/metrics" "$CANARY_TOKEN"
	if [ "${HTTP_RESPONSE_CODE:-}" != "200" ]; then
		PROBE_FAILURE_DETAIL="first metrics fetch returned HTTP ${HTTP_RESPONSE_CODE:-unknown}"
		return 1
	fi
	METRICS_FIRST_BODY="$HTTP_RESPONSE_BODY"
	if ! metrics_shape_ok "$METRICS_FIRST_BODY"; then
		PROBE_FAILURE_DETAIL="first metrics fetch returned a non-conforming JSON body"
		return 1
	fi
	METRICS_FIRST_FETCHED_AT="$(metrics_json_field "$METRICS_FIRST_BODY" "fetched_at")"
	METRICS_SHAPE_OK=1

	sleep "$CUSTOMER_METRICS_SECOND_PROBE_SLEEP_SECONDS"

	capture_json_response tenant_call GET "/indexes/${encoded_index_name}/metrics" "$CANARY_TOKEN"
	if [ "${HTTP_RESPONSE_CODE:-}" != "200" ]; then
		PROBE_FAILURE_DETAIL="second metrics fetch returned HTTP ${HTTP_RESPONSE_CODE:-unknown}"
		return 1
	fi
	METRICS_SECOND_BODY="$HTTP_RESPONSE_BODY"
	if ! metrics_shape_ok "$METRICS_SECOND_BODY"; then
		PROBE_FAILURE_DETAIL="second metrics fetch returned a non-conforming JSON body"
		return 1
	fi
	METRICS_SECOND_FETCHED_AT="$(metrics_json_field "$METRICS_SECOND_BODY" "fetched_at")"
	if [ "$METRICS_FIRST_FETCHED_AT" = "$METRICS_SECOND_FETCHED_AT" ]; then
		METRICS_CACHE_REUSE_OK=1
	else
		PROBE_FAILURE_DETAIL="metrics fetched_at changed within the cache window"
		return 1
	fi

	return 0
}

metrics_tab_data_shape_ok() {
	metrics_validation_ok tab "$1"
}

assert_metrics_tab_data_surface() {
	local response metrics_tab_url response_code response_body encoded_index_name

	if [ -z "${CANARY_TOKEN:-}" ] || [ -z "${CANARY_INDEX_NAME:-}" ]; then
		PROBE_FAILURE_DETAIL="CANARY_TOKEN and CANARY_INDEX_NAME must be set before probing metrics tab data"
		return 1
	fi
	if [ -z "${WEB_BASE_URL:-}" ]; then
		PROBE_FAILURE_DETAIL="WEB_BASE_URL must be set before probing metrics tab data"
		return 1
	fi

	encoded_index_name="$(encode_url_path_segment "$CANARY_INDEX_NAME")"
	metrics_tab_url="${WEB_BASE_URL}/console/indexes/${encoded_index_name}/__data.json?tab=metrics"
	response="$(curl -sS --max-time 30 -b "auth_token=${CANARY_TOKEN}" "$metrics_tab_url" -w "\n%{http_code}" 2>/dev/null || true)"
	response_code="$(printf '%s\n' "$response" | tail -1)"
	response_body="$(printf '%s\n' "$response" | sed '$d')"

	if [ "$response_code" != "200" ]; then
		PROBE_FAILURE_DETAIL="metrics tab __data.json fetch returned HTTP ${response_code:-unknown}"
		return 1
	fi
	METRICS_TAB_DATA_BODY="$response_body"
	if ! metrics_tab_data_shape_ok "$response_body"; then
		PROBE_FAILURE_DETAIL="metrics tab __data.json response did not expose the expected metrics payload shape"
		return 1
	fi

	METRICS_TAB_DATA_RESPONSE_TYPE="$(metrics_json_field "$METRICS_TAB_DATA_BODY" "type")"
	METRICS_TAB_DATA_OK=1
	return 0
}

wait_for_metrics_population() {
	local attempt max_attempts documents_count encoded_index_name

	max_attempts=12
	encoded_index_name="$(encode_url_path_segment "$CANARY_INDEX_NAME")"
	for attempt in $(seq 1 "$max_attempts"); do
		capture_json_response tenant_call GET "/indexes/${encoded_index_name}/metrics" "$CANARY_TOKEN"
		if [ "${HTTP_RESPONSE_CODE:-}" = "200" ] && metrics_shape_ok "$HTTP_RESPONSE_BODY"; then
			documents_count="$(metrics_json_field "$HTTP_RESPONSE_BODY" "documents_count")"
			if [ "${documents_count:-0}" -gt 0 ]; then
				METRICS_POPULATED_OK=1
				return 0
			fi
		fi
		metrics_log "metrics not populated yet for ${CANARY_INDEX_NAME}; retrying (${attempt}/${max_attempts})"
		sleep "$CUSTOMER_METRICS_POLL_SLEEP_SECONDS"
	done

	PROBE_FAILURE_DETAIL="metrics did not report documents_count > 0 within the scrape window"
	return 1
}

write_summary_json() {
	local summary_json cleanup_ok

	if [ "$CANARY_INDEX_CREATED" -eq 0 ] && [ "$CANARY_ACCOUNT_DELETED" -eq 1 ]; then
		cleanup_ok=1
	else
		cleanup_ok=0
	fi
	if [ -z "$PROBE_FAILURE_DETAIL" ] && [ "${FLOW_FAILED:-0}" -eq 1 ]; then PROBE_FAILURE_DETAIL="customer loop step '${FLOW_FAILURE_STEP:-unknown}' failed: ${FLOW_FAILURE_DETAIL:-unknown failure}"; fi

	summary_json="$(
		python3 - "$API_URL" "$CANARY_INDEX_NAME" "$CANARY_CUSTOMER_ID" \
			"$METRICS_FIRST_FETCHED_AT" "$METRICS_SECOND_FETCHED_AT" \
			"$METRICS_SHAPE_OK" "$METRICS_CACHE_REUSE_OK" "$METRICS_POPULATED_OK" \
			"$cleanup_ok" "$PROBE_SKIP_REASON" "$PROBE_SKIP_DETAIL" "$PROBE_FAILURE_DETAIL" \
			"$METRICS_TAB_DATA_OK" "$METRICS_TAB_DATA_RESPONSE_TYPE" "$METRICS_TAB_DATA_BODY" \
			"$METRICS_FIRST_BODY" "$METRICS_SECOND_BODY" \
			"$CANARY_INDEX_CREATED" "$CANARY_ACCOUNT_DELETED" "$CANARY_ADMIN_CLEANED" <<'PY'
import json
import sys

(
    api_url,
    index_name,
    customer_id,
    fetched_at_first,
    fetched_at_second,
    shape_ok,
    cache_ok,
    populated_ok,
    cleanup_ok,
    skip_reason,
    skip_detail,
    failure_detail,
    metrics_tab_data_ok,
    metrics_tab_data_response_type,
    metrics_tab_data_body,
    first_body,
    second_body,
    index_created,
    account_deleted,
    admin_cleaned,
) = sys.argv[1:]
status = "pass"
exit_code = 0
if skip_reason:
    status = "skip"
    exit_code = 100
elif failure_detail:
    status = "fail"
    exit_code = 1

def attach_probe_body(summary, field_name, raw_body):
    if not raw_body:
        return
    try:
        summary[field_name] = json.loads(raw_body)
    except json.JSONDecodeError as exc:
        summary[f"{field_name}_raw"] = raw_body
        summary[f"{field_name}_parse_error"] = str(exc)

summary = {
    "api_url": api_url,
    "status": status,
    "exit_code": exit_code,
    "index_name": index_name,
    "customer_id": customer_id,
    "fetched_at_first": fetched_at_first,
    "fetched_at_second": fetched_at_second,
    "shape_ok": shape_ok == "1",
    "cache_reuse_ok": cache_ok == "1",
    "metrics_populated_ok": populated_ok == "1",
    "metrics_tab_data_ok": metrics_tab_data_ok == "1",
    "metrics_tab_data_response_type": metrics_tab_data_response_type,
    "cleanup_ok": cleanup_ok == "1",
    "skip_reason": skip_reason,
    "skip_detail": skip_detail,
    "failure_detail": failure_detail,
    "cleanup_state": {
        "index_created": index_created == "1",
        "account_deleted": account_deleted == "1",
        "admin_cleaned": admin_cleaned == "1",
    },
}
attach_probe_body(summary, "first_response", first_body)
attach_probe_body(summary, "second_response", second_body)
attach_probe_body(summary, "metrics_tab_data_response", metrics_tab_data_body)
print(json.dumps(summary, indent=2, sort_keys=True))
PY
	)"

	printf '%s\n' "$summary_json" > "$SUMMARY_JSON"
}

cleanup_probe_resources() {
	if [ "${CANARY_INDEX_CREATED:-0}" -eq 1 ]; then
		run_delete_index_step || true
	fi
	if [ -n "${CANARY_TOKEN:-}" ] && [ "${CANARY_ACCOUNT_DELETED:-0}" -eq 0 ]; then
		run_delete_account_step || true
	fi
	# Admin cleanup is best-effort only here. The probe's load-bearing auth path
	# is the customer JWT route, so a missing ADMIN_KEY should not turn cleanup
	# into a probe failure.
	if [ -n "${ADMIN_KEY:-}" ] && [ "${CANARY_ADMIN_CLEANED:-0}" -eq 0 ]; then
		run_admin_cleanup_step || true
	fi
}

parse_probe_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--staging-only)
				PROBE_ONLY_STAGING=1
				;;
			--help|-h)
				usage
				exit 0
				;;
			*)
				echo "unknown argument: $1" >&2
				usage >&2
				exit 2
				;;
		esac
		shift
	done
}

main() {
	local prereq_rc

	parse_probe_args "$@"

	if ! load_probe_env; then
		return 1
	fi
	if [ "$PROBE_ONLY_STAGING" -eq 1 ] && ! require_staging_probe_urls; then
		return 1
	fi
	create_probe_summary_dir
	trap 'cleanup_probe_resources; write_summary_json' EXIT

	ensure_live_probe_prereqs
	prereq_rc=$?
	if [ "$prereq_rc" -ne 0 ]; then
		return "$prereq_rc"
	fi
	if ! load_canary_env; then
		return 1
	fi
	API_URL="${API_URL:-https://api.staging.flapjack.foo}"
	WEB_BASE_URL="${WEB_BASE_URL:-https://cloud.staging.flapjack.foo}"
	export API_URL
	export WEB_BASE_URL
	if [ "$PROBE_ONLY_STAGING" -eq 1 ] && ! require_staging_probe_urls; then
		return 1
	fi
	CANARY_LIVE_MODE=0
	export CANARY_LIVE_MODE

	run_signup_step
	run_verify_email_step
	run_index_create_step
	# Write a document before polling so the scrape result can move past the empty state.
	run_index_batch_step
	wait_for_metrics_population
	run_metrics_request_pair
	assert_metrics_tab_data_surface

	metrics_log "summary written to ${SUMMARY_JSON}"
	return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
