#!/usr/bin/env bash
# Hermetic regression test for the customer metrics authenticated probe:
# verify GET /indexes/<name>/metrics bearer-token shape/cache contracts plus
# Stage 4 requirements: live-prereq SKIP reason handling, Metrics-tab
# __data.json proof, and summary evidence fields.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROBE_SCRIPT="$REPO_ROOT/scripts/canary/contracts/customer_metrics_endpoint_authenticated_probe.sh"
METRICS_TAB_DATA_FAILURE_FIXTURE="$REPO_ROOT/scripts/tests/fixtures/customer_metrics_tab_data_failure_devalue_redacted.json"

# shellcheck disable=SC1091
# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck disable=SC1091
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

if [ ! -f "$PROBE_SCRIPT" ]; then
	fail "probe script exists at scripts/canary/contracts/customer_metrics_endpoint_authenticated_probe.sh"
	run_test_summary
	exit 1
fi

assert_file_exists "$METRICS_TAB_DATA_FAILURE_FIXTURE" \
	"redacted Metrics-tab data failure fixture should exist"
if python3 - "$METRICS_TAB_DATA_FAILURE_FIXTURE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    payload = json.load(fh)

serialized = json.dumps(payload, sort_keys=True)
required_fields = (
    "documents_count",
    "storage_bytes",
    "search_requests_total",
    "write_operations_total",
)

def has_data_type(node):
    if isinstance(node, dict):
        if node.get("type") == "data":
            return True
        return any(has_data_type(value) for value in node.values())
    if isinstance(node, list):
        return any(has_data_type(value) for value in node)
    return False

if not has_data_type(payload):
    raise SystemExit("fixture does not contain a SvelteKit data node")
for field_name in required_fields:
    if field_name not in serialized:
        raise SystemExit(f"fixture missing raw metric field evidence: {field_name}")
PY
then
	pass "redacted Metrics-tab data failure fixture should preserve SvelteKit data and raw metric field evidence"
else
	fail "redacted Metrics-tab data failure fixture should preserve SvelteKit data and raw metric field evidence"
fi

export ALERT_DISPATCH_HELPER="$REPO_ROOT/scripts/lib/alert_dispatch.sh"
# shellcheck disable=SC1091
# shellcheck source=scripts/canary/contracts/customer_metrics_endpoint_authenticated_probe.sh
source "$PROBE_SCRIPT"

WORK_DIR="$(mktemp -d -t customer_metrics_probe_XXXXXX)"
SERVER_PID=""

cleanup() {
	if [ -n "${SERVER_PID:-}" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
		kill "$SERVER_PID" 2>/dev/null || true
		wait "$SERVER_PID" 2>/dev/null || true
	fi
	rm -rf "$WORK_DIR"
}
trap cleanup EXIT

SERVER_PORT_FILE="$WORK_DIR/port"
REQUEST_LOG="$WORK_DIR/requests.log"
TIMESTAMP_FILE="$WORK_DIR/fetched_at.txt"
TAB_PREFIX_TIMESTAMP_FILE="$WORK_DIR/tab_prefix_fetched_at.txt"
SERVER_SCRIPT="$WORK_DIR/capture_server.py"
printf '%s' "2026-07-11T01:03:15.766682Z" >"$TIMESTAMP_FILE"
: >"$TAB_PREFIX_TIMESTAMP_FILE"

cat > "$SERVER_SCRIPT" <<'PYEOF'
import http.server
import json
import sys
from pathlib import Path

port_file = Path(sys.argv[1])
log_path = Path(sys.argv[2])
timestamp_path = Path(sys.argv[3])
tab_prefix_timestamp_path = Path(sys.argv[4])


def current_fetched_at():
    return timestamp_path.read_text(encoding="utf-8").strip()


def tab_prefix_fetched_at():
    return tab_prefix_timestamp_path.read_text(encoding="utf-8").strip()


def metrics_body():
    return {
        "index": "probe-index",
        "documents_count": 5,
        "storage_bytes": 2048,
        "search_requests_total": 12,
        "write_operations_total": 5,
        "fetched_at": current_fetched_at(),
    }


def data_body():
    nodes = []
    prefix_timestamp = tab_prefix_fetched_at()
    if prefix_timestamp:
        nodes.append(
            {
                "data": {
                    "metrics": {
                        "documents_count": 5,
                        "storage_bytes": 2048,
                        "search_requests_total": 12,
                        "write_operations_total": 5,
                        "fetched_at": prefix_timestamp,
                    }
                }
            }
        )
    nodes.append(
        {
            "data": {
                "metrics": {
                    "documents_count": 5,
                    "storage_bytes": 2048,
                    "search_requests_total": 12,
                    "write_operations_total": 5,
                    "fetched_at": current_fetched_at(),
                }
            }
        }
    )
    return {
        "type": "data",
        "nodes": nodes,
    }


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def do_GET(self):
        with log_path.open("a", encoding="utf-8") as fh:
            fh.write(f"{self.command} {self.path}\n")
            for name, value in self.headers.items():
                fh.write(f"{name}: {value}\n")
            fh.write("\n")
        if self.path in (
            "/indexes/probe-index/metrics",
            "/indexes/probe%2Findex%20space/metrics",
        ):
            payload = metrics_body()
        elif self.path in (
            "/console/indexes/probe-index/__data.json?tab=metrics",
            "/console/indexes/probe%2Findex%20space/__data.json?tab=metrics",
        ):
            payload = data_body()
        else:
            self.send_response(404)
            self.end_headers()
            return
        body = json.dumps(payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
port_file.write_text(str(server.server_port), encoding="utf-8")
server.serve_forever()
PYEOF

python3 "$SERVER_SCRIPT" "$SERVER_PORT_FILE" "$REQUEST_LOG" "$TIMESTAMP_FILE" "$TAB_PREFIX_TIMESTAMP_FILE" &
SERVER_PID=$!

for _ in $(seq 1 50); do
	if [ -s "$SERVER_PORT_FILE" ]; then
		break
	fi
	sleep 0.05
done

if [ ! -s "$SERVER_PORT_FILE" ]; then
	fail "capture server failed to bind a port"
	run_test_summary
	exit 1
fi

PORT="$(cat "$SERVER_PORT_FILE")"

API_URL="http://127.0.0.1:${PORT}"
WEB_BASE_URL="$API_URL"
assert_eq "$(encode_url_path_segment 'probe/index space')" "probe%2Findex%20space" \
	"encode_url_path_segment should escape reserved path separators"
CANARY_TOKEN="jwt-probe-token"
CANARY_INDEX_NAME="probe-index"
CUSTOMER_METRICS_SECOND_PROBE_SLEEP_SECONDS=0

set_metrics_fixture_timestamp() {
	printf '%s' "$1" >"$TIMESTAMP_FILE"
}

set_metrics_tab_prefix_timestamp() {
	printf '%s' "$1" >"$TAB_PREFIX_TIMESTAMP_FILE"
}

clear_metrics_tab_prefix_timestamp() {
	: >"$TAB_PREFIX_TIMESTAMP_FILE"
}

reset_metrics_probe_state() {
	PROBE_SKIP_REASON=""
	PROBE_FAILURE_DETAIL=""
	METRICS_FIRST_BODY=""
	METRICS_SECOND_BODY=""
	METRICS_FIRST_FETCHED_AT=""
	METRICS_SECOND_FETCHED_AT=""
	METRICS_SHAPE_OK=0
	METRICS_CACHE_REUSE_OK=0
	METRICS_TAB_DATA_BODY=""
	METRICS_TAB_DATA_OK=0
	METRICS_TAB_DATA_RESPONSE_TYPE=""
}

reset_metrics_probe_state

set +e
run_metrics_request_pair
RUN_RC=$?
set -e

assert_eq "$RUN_RC" "0" "6-digit + Z = GREEN: run_metrics_request_pair should succeed against the capture server"
assert_eq "$METRICS_SHAPE_OK" "1" "6-digit + Z = GREEN: probe should mark the six-field response shape as valid"
assert_eq "$METRICS_CACHE_REUSE_OK" "1" "probe should treat identical fetched_at values as a cache hit"
assert_eq "$METRICS_FIRST_FETCHED_AT" "2026-07-11T01:03:15.766682Z" "6-digit + Z = GREEN: first fetched_at should preserve the timestamp"
assert_eq "$METRICS_SECOND_FETCHED_AT" "2026-07-11T01:03:15.766682Z" "6-digit + Z = GREEN: second fetched_at should preserve the timestamp"
assert_valid_json "$METRICS_FIRST_BODY" "first metrics body should be valid JSON"
assert_valid_json "$METRICS_SECOND_BODY" "second metrics body should be valid JSON"

if [ ! -s "$REQUEST_LOG" ]; then
	fail "capture server should record both metrics requests"
	run_test_summary
	exit 1
fi

FIRST_REQUEST_LINE="$(awk 'NR==1{print; exit}' "$REQUEST_LOG")"
assert_eq "$FIRST_REQUEST_LINE" "GET /indexes/probe-index/metrics" \
	"probe should request the customer metrics endpoint path exactly"

AUTH_HEADER_VALUE="$(
	awk 'BEGIN{IGNORECASE=1} /^[Aa]uthorization:[[:space:]]/ {
		sub(/^[^:]+:[[:space:]]/, "")
		print
		exit
	}' "$REQUEST_LOG"
)"
assert_eq "$AUTH_HEADER_VALUE" "Bearer jwt-probe-token" \
	"probe should authenticate metrics requests with the dashboard JWT bearer token"

REQUEST_COUNT="$(grep -c '^GET /indexes/probe-index/metrics$' "$REQUEST_LOG")"
assert_eq "$REQUEST_COUNT" "2" "probe should issue exactly two metrics requests when checking cache reuse"

set +e
assert_metrics_tab_data_surface
TAB_RC=$?
set -e
assert_eq "$TAB_RC" "0" "6-digit + Z = GREEN: probe should validate metrics-tab __data.json using auth_token session cookie flow"
assert_eq "$METRICS_TAB_DATA_OK" "1" "6-digit + Z = GREEN: probe should mark metrics-tab data proof as successful"
assert_eq "$METRICS_TAB_DATA_RESPONSE_TYPE" "data" "probe should capture the metrics-tab __data.json type marker"
assert_valid_json "$METRICS_TAB_DATA_BODY" "metrics-tab __data.json body should be valid JSON"

TAB_REQUEST_LINE="$(
	awk '
		$0 == "GET /console/indexes/probe-index/__data.json?tab=metrics" {
			print
			exit
		}
	' "$REQUEST_LOG"
)"
assert_eq "$TAB_REQUEST_LINE" "GET /console/indexes/probe-index/__data.json?tab=metrics" \
	"probe should request the Metrics tab __data.json endpoint exactly"

COOKIE_HEADER_VALUE="$(
	awk '
		BEGIN { in_block=0 }
		$0 == "GET /console/indexes/probe-index/__data.json?tab=metrics" { in_block=1; next }
		in_block && /^[Cc]ookie:[[:space:]]/ {
			sub(/^[^:]+:[[:space:]]/, "")
			print
			exit
		}
		in_block && $0 == "" { exit }
	' "$REQUEST_LOG"
)"
assert_eq "$COOKIE_HEADER_VALUE" "auth_token=jwt-probe-token" \
	"probe should send auth_token cookie when validating Metrics tab __data.json"

FIXTURE_TAB_BODY="$(cat "$METRICS_TAB_DATA_FAILURE_FIXTURE")"
set +e
metrics_tab_data_shape_ok "$FIXTURE_TAB_BODY"
FIXTURE_TAB_RC=$?
set -e
assert_eq "$FIXTURE_TAB_RC" "0" \
	"Stage-1 captured devalue fixture should pass metrics-tab shape validation"

MISSING_FIELD_FIXTURE="$WORK_DIR/missing_metrics_field.json"
UNRESOLVED_FETCHED_AT_FIXTURE="$WORK_DIR/unresolved_metrics_fetched_at.json"
INVALID_EARLIER_DEVALUE_NODE_FIXTURE="$WORK_DIR/invalid_earlier_devalue_node.json"

python3 - "$METRICS_TAB_DATA_FAILURE_FIXTURE" "$MISSING_FIELD_FIXTURE" "$UNRESOLVED_FETCHED_AT_FIXTURE" "$INVALID_EARLIER_DEVALUE_NODE_FIXTURE" <<'PY'
import json
import sys
from pathlib import Path

source_path = Path(sys.argv[1])
missing_field_path = Path(sys.argv[2])
unresolved_timestamp_path = Path(sys.argv[3])
invalid_earlier_node_path = Path(sys.argv[4])
payload = json.loads(source_path.read_text(encoding="utf-8"))
metrics_slot = payload["nodes"][2]["data"][88]

missing_field_payload = json.loads(json.dumps(payload))
del missing_field_payload["nodes"][2]["data"][88]["write_operations_total"]
missing_field_path.write_text(
    json.dumps(missing_field_payload), encoding="utf-8"
)

unresolved_timestamp_payload = json.loads(json.dumps(payload))
unresolved_timestamp_payload["nodes"][2]["data"][88]["fetched_at"] = 999
unresolved_timestamp_path.write_text(
    json.dumps(unresolved_timestamp_payload), encoding="utf-8"
)

invalid_earlier_node_payload = json.loads(json.dumps(payload))
invalid_metrics_node = {
    "type": "data",
    "data": {
        "metrics": {
            "documents_count": 5,
            "storage_bytes": 2048,
            "search_requests_total": 12,
            "fetched_at": "2026-07-11T01:03:15.766682Z",
        },
    },
}
invalid_earlier_node_payload["nodes"].insert(0, invalid_metrics_node)
invalid_earlier_node_path.write_text(
    json.dumps(invalid_earlier_node_payload), encoding="utf-8"
)
PY

set +e
metrics_tab_data_shape_ok "$(cat "$MISSING_FIELD_FIXTURE")"
MISSING_FIELD_RC=$?
metrics_tab_data_shape_ok "$(cat "$UNRESOLVED_FETCHED_AT_FIXTURE")"
UNRESOLVED_FETCHED_AT_RC=$?
metrics_tab_data_shape_ok "$(cat "$INVALID_EARLIER_DEVALUE_NODE_FIXTURE")"
INVALID_EARLIER_DEVALUE_NODE_RC=$?
set -e

assert_eq "$MISSING_FIELD_RC" "1" \
	"devalue fixture missing a metrics field should fail the metrics-tab shape contract"
assert_eq "$UNRESOLVED_FETCHED_AT_RC" "1" \
	"devalue fixture with an unresolved fetched_at reference should fail the metrics-tab shape contract"
assert_eq "$INVALID_EARLIER_DEVALUE_NODE_RC" "1" \
	"devalue fixture with an invalid earlier Metrics-tab node should fail closed before a later valid node"

set_metrics_fixture_timestamp "2026-07-11T01:03:15.766682746+00:00"
: > "$REQUEST_LOG"
CANARY_INDEX_NAME="probe-index"
reset_metrics_probe_state

set +e
run_metrics_request_pair 2>"$WORK_DIR/nanosecond_metrics_stderr.log"
NANO_RUN_RC=$?
assert_metrics_tab_data_surface 2>"$WORK_DIR/nanosecond_tab_stderr.log"
NANO_TAB_RC=$?
set -e

assert_eq "$NANO_RUN_RC" "0" "9-digit timestamp should pass metrics endpoint shape validation but is RED before parser fix"
assert_eq "$METRICS_SHAPE_OK" "1" "9-digit timestamp should set METRICS_SHAPE_OK after metrics endpoint validation"
assert_eq "$METRICS_FIRST_FETCHED_AT" "2026-07-11T01:03:15.766682746+00:00" \
	"9-digit timestamp should be captured from the metrics endpoint response"
assert_eq "$NANO_TAB_RC" "0" "9-digit timestamp should pass Metrics tab data shape validation but is RED before parser fix"
assert_eq "$METRICS_TAB_DATA_OK" "1" "9-digit timestamp should set METRICS_TAB_DATA_OK after Metrics tab validation"

set_metrics_fixture_timestamp "not-a-timestamp"
: > "$REQUEST_LOG"
reset_metrics_probe_state

set +e
run_metrics_request_pair 2>"$WORK_DIR/invalid_metrics_stderr.log"
INVALID_RUN_RC=$?
assert_metrics_tab_data_surface 2>"$WORK_DIR/invalid_tab_stderr.log"
INVALID_TAB_RC=$?
set -e

assert_eq "$INVALID_RUN_RC" "1" "invalid timestamp = GREEN guard: metrics endpoint shape validation should reject it"
assert_eq "$METRICS_SHAPE_OK" "0" "invalid timestamp = GREEN guard: METRICS_SHAPE_OK should remain unset"
assert_eq "$INVALID_TAB_RC" "1" "invalid timestamp = GREEN guard: Metrics tab data shape validation should reject it"
assert_eq "$METRICS_TAB_DATA_OK" "0" "invalid timestamp = GREEN guard: METRICS_TAB_DATA_OK should remain unset"
EXPECTED_INVALID_TAB_BODY='{"type": "data", "nodes": [{"data": {"metrics": {"documents_count": 5, "storage_bytes": 2048, "search_requests_total": 12, "write_operations_total": 5, "fetched_at": "not-a-timestamp"}}}]}'
assert_eq "$PROBE_FAILURE_DETAIL" "metrics tab __data.json response did not expose the expected metrics payload shape" \
	"invalid timestamp = GREEN guard: Metrics tab data failure should retain the existing detail"
assert_eq "$METRICS_TAB_DATA_BODY" "$EXPECTED_INVALID_TAB_BODY" \
	"invalid timestamp = RED guard: failed Metrics-tab shape validation should preserve the exact response body"

set_metrics_fixture_timestamp "2026-07-11T01:03:15.766682Z"
set_metrics_tab_prefix_timestamp "not-a-timestamp"
: > "$REQUEST_LOG"
reset_metrics_probe_state

set +e
assert_metrics_tab_data_surface 2>"$WORK_DIR/invalid_prefix_tab_stderr.log"
INVALID_PREFIX_TAB_RC=$?
set -e

assert_eq "$INVALID_PREFIX_TAB_RC" "1" "invalid earlier Metrics-tab metrics node should fail closed even when a later node is valid"
assert_eq "$METRICS_TAB_DATA_OK" "0" "invalid earlier Metrics-tab metrics node should leave METRICS_TAB_DATA_OK unset"
clear_metrics_tab_prefix_timestamp

set_metrics_fixture_timestamp "2026-07-11T01:03:15.766682Z"
: > "$REQUEST_LOG"
CANARY_INDEX_NAME="probe/index space"
reset_metrics_probe_state

set +e
run_metrics_request_pair
ENCODED_RUN_RC=$?
assert_metrics_tab_data_surface
ENCODED_TAB_RC=$?
set -e

assert_eq "$ENCODED_RUN_RC" "0" "run_metrics_request_pair should handle index names with reserved path characters"
assert_eq "$ENCODED_TAB_RC" "0" "metrics-tab probe should encode reserved path characters in index names"

ENCODED_METRICS_REQUEST_LINE="$(awk 'NR==1{print; exit}' "$REQUEST_LOG")"
assert_eq "$ENCODED_METRICS_REQUEST_LINE" "GET /indexes/probe%2Findex%20space/metrics" \
	"probe should percent-encode reserved characters in metrics endpoint paths"

ENCODED_TAB_REQUEST_LINE="$(
	awk '
		$0 == "GET /console/indexes/probe%2Findex%20space/__data.json?tab=metrics" {
			print
			exit
		}
	' "$REQUEST_LOG"
)"
assert_eq "$ENCODED_TAB_REQUEST_LINE" "GET /console/indexes/probe%2Findex%20space/__data.json?tab=metrics" \
	"probe should percent-encode reserved characters in Metrics tab __data.json paths"

run_prereq_skip_case() {
	local token="$1"
	local detail="$2"
	local path_override="$3"
	local inbox_s3_uri="$4"
	local inbox_domain="$5"
	local output_file summary_body

	PATH="$path_override"
	CANARY_TEST_INBOX_S3_URI="$inbox_s3_uri"
	CANARY_TEST_INBOX_DOMAIN="$inbox_domain"
	PROBE_SKIP_REASON=""
	PROBE_SKIP_DETAIL=""

	set +e
	output_file="$WORK_DIR/prereq_${token}.log"
	ensure_live_probe_prereqs >"$output_file" 2>&1
	PREREQ_RC=$?
	set -e
	PREREQ_OUTPUT="$(cat "$output_file")"

	PATH="$SAVED_PATH"
	assert_eq "$PREREQ_RC" "$SKIP_EXIT_CODE" "$token should use the shared SKIP exit code"
	assert_contains "$PREREQ_OUTPUT" "SKIPPED: $token: $detail" \
		"$token should be announced with its shared detail"
	assert_eq "$PROBE_SKIP_REASON" "$token" \
		"$token should persist in PROBE_SKIP_REASON"
	assert_eq "$PROBE_SKIP_DETAIL" "$detail" \
		"$token should persist its human-readable detail"

	CANARY_CUSTOMER_ID="cust_probe_123"
	CANARY_INDEX_CREATED=0
	CANARY_ACCOUNT_DELETED=1
	CANARY_ADMIN_CLEANED=0
	PROBE_FAILURE_DETAIL=""
	SUMMARY_JSON="$WORK_DIR/summary_${token}.json"

	write_summary_json
	assert_file_exists "$SUMMARY_JSON" "write_summary_json should create summary output for $token"
	summary_body="$(cat "$SUMMARY_JSON")"
	assert_valid_json "$summary_body" "write_summary_json should emit valid JSON for $token"
	assert_contains "$summary_body" '"status": "skip"' "summary should report status=skip for $token"
	assert_contains "$summary_body" '"exit_code": 100' "summary should report exit_code=100 for $token"
	assert_json_bool_field "$summary_body" "cache_reuse_ok" "true" "summary should preserve cache-reuse proof for $token"
	assert_json_bool_field "$summary_body" "metrics_tab_data_ok" "true" "summary should record Metrics-tab proof for $token"
	assert_contains "$summary_body" "\"skip_reason\": \"$token\"" \
		"summary should record the canonical SKIP reason token $token"
	assert_contains "$summary_body" "\"skip_detail\": \"$detail\"" \
		"summary should record the human-readable SKIP detail for $token"
	assert_contains "$summary_body" "\"metrics_tab_data_response_type\": \"data\"" \
		"summary should include __data.json response type evidence for $token"
}

SAVED_PATH="$PATH"
NO_AWS_BIN="$WORK_DIR/no-aws-bin"
INVALID_AWS_BIN="$WORK_DIR/invalid-aws-bin"
VALID_AWS_BIN="$WORK_DIR/valid-aws-bin"
mkdir -p "$NO_AWS_BIN" "$INVALID_AWS_BIN" "$VALID_AWS_BIN"
cat > "$INVALID_AWS_BIN/aws" <<'AWS_INVALID'
#!/usr/bin/env bash
if [[ "${1:-}" == "sts" && "${2:-}" == "get-caller-identity" ]]; then
	echo "InvalidClientTokenId" >&2
	exit 255
fi
echo "unexpected aws invocation: $*" >&2
exit 99
AWS_INVALID
cat > "$VALID_AWS_BIN/aws" <<'AWS_VALID'
#!/usr/bin/env bash
if [[ "${1:-}" == "sts" && "${2:-}" == "get-caller-identity" ]]; then
	printf '{"Account":"123456789012"}\n'
	exit 0
fi
echo "unexpected aws invocation: $*" >&2
exit 99
AWS_VALID
chmod +x "$INVALID_AWS_BIN/aws" "$VALID_AWS_BIN/aws"

run_prereq_skip_case "probe_env_gap_aws_credentials_unavailable" "aws CLI unavailable" \
	"$NO_AWS_BIN:/usr/bin:/bin:/usr/sbin:/sbin" "s3://probe-inbox" "test.flapjack.foo"
run_prereq_skip_case "probe_env_gap_aws_credentials_invalid" \
	"aws sts get-caller-identity failed; creds present but rejected by AWS" \
	"$INVALID_AWS_BIN:/usr/bin:/bin:/usr/sbin:/sbin" "s3://probe-inbox" "test.flapjack.foo"
run_prereq_skip_case "probe_env_gap_aws_inbox_env_missing" \
	"missing CANARY_TEST_INBOX_S3_URI or CANARY_TEST_INBOX_DOMAIN" \
	"$VALID_AWS_BIN:/usr/bin:/bin:/usr/sbin:/sbin" "" ""

RECOVERY_AWS_BIN="$WORK_DIR/recovery-aws-bin"
RECOVERY_SECRET_FILE="$WORK_DIR/recovered_aws.env"
mkdir -p "$RECOVERY_AWS_BIN"
cat > "$RECOVERY_AWS_BIN/aws" <<'AWS_RECOVERY'
#!/usr/bin/env bash
if [[ "${1:-}" == "sts" && "${2:-}" == "get-caller-identity" ]]; then
	if [[ "${AWS_ACCESS_KEY_ID:-}" == "GOODKEY" ]]; then
		printf '{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/recovered"}\n'
		exit 0
	fi
	echo "InvalidClientTokenId" >&2
	exit 255
fi
echo "unexpected aws invocation: $*" >&2
exit 99
AWS_RECOVERY
chmod +x "$RECOVERY_AWS_BIN/aws"
cat > "$RECOVERY_SECRET_FILE" <<'RECOVERY_SECRET'
AWS_ACCESS_KEY_ID=GOODKEY
AWS_SECRET_ACCESS_KEY=GOODSECRET
RECOVERY_SECRET

PATH="$RECOVERY_AWS_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
FJCLOUD_SECRET_FILE="$RECOVERY_SECRET_FILE"
AWS_ACCESS_KEY_ID="BADKEY"
AWS_SECRET_ACCESS_KEY="BADSECRET"
AWS_SESSION_TOKEN="BADTOKEN"
CANARY_TEST_INBOX_S3_URI="s3://probe-inbox"
CANARY_TEST_INBOX_DOMAIN="test.flapjack.foo"
export PATH FJCLOUD_SECRET_FILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
export CANARY_TEST_INBOX_S3_URI CANARY_TEST_INBOX_DOMAIN
PROBE_SKIP_REASON=""
PROBE_SKIP_DETAIL=""

set +e
ensure_live_probe_prereqs >"$WORK_DIR/recovered_prereq_stdout.log" 2>"$WORK_DIR/recovered_prereq_stderr.log"
RECOVERED_PREREQ_RC=$?
set -e

PATH="$SAVED_PATH"
assert_eq "$RECOVERED_PREREQ_RC" "0" "recovered AWS prereqs should pass after loading the secret-file credentials"
assert_eq "${AWS_ACCESS_KEY_ID:-}" "GOODKEY" \
	"recovered AWS prereqs should leave the recovered credentials in the parent shell for later inbox polling"
unset FJCLOUD_SECRET_FILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

run_test_summary
