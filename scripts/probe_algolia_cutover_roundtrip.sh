#!/usr/bin/env bash
# Real Algolia cutover-verification roundtrip proof.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=scripts/lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=scripts/lib/flapjack_binary.sh
source "$SCRIPT_DIR/lib/flapjack_binary.sh"
# shellcheck source=scripts/lib/algolia_import_live_probe_common.sh
source "$SCRIPT_DIR/lib/algolia_import_live_probe_common.sh"
# shellcheck source=scripts/lib/integration_stack_env.sh
source "$SCRIPT_DIR/lib/integration_stack_env.sh"
# shellcheck source=scripts/lib/integration_db_access.sh
source "$SCRIPT_DIR/lib/integration_db_access.sh"

RUN_ID="${ALGOLIA_CUTOVER_ROUNDTRIP_RUN_ID:-$(date -u +%Y%m%d%H%M%S)-$$}"
RUNTIME_PARENT="${ALGOLIA_CUTOVER_ROUNDTRIP_RUNTIME_PARENT:-${TMPDIR:-/tmp}}"
POLL_SECONDS="${ALGOLIA_CUTOVER_ROUNDTRIP_POLL_SECONDS:-180}"
POLL_INTERVAL_SECONDS="${ALGOLIA_CUTOVER_ROUNDTRIP_POLL_INTERVAL_SECONDS:-2}"
CLEANUP_POLL_ATTEMPTS="${ALGOLIA_CUTOVER_ROUNDTRIP_CLEANUP_POLL_ATTEMPTS:-30}"
CLEANUP_POLL_INTERVAL_SECONDS="${ALGOLIA_CUTOVER_ROUNDTRIP_CLEANUP_POLL_INTERVAL_SECONDS:-1}"
API_PORT="${API_PORT:-3099}"
FLAPJACK_PORT="${FLAPJACK_PORT:-7799}"
API_URL="${ALGOLIA_CUTOVER_ROUNDTRIP_API_URL:-http://127.0.0.1:${API_PORT}}"
ENGINE_URL="${ALGOLIA_CUTOVER_ROUNDTRIP_ENGINE_URL:-http://127.0.0.1:${FLAPJACK_PORT}}"
INTEGRATION_UP="${ALGOLIA_CUTOVER_ROUNDTRIP_INTEGRATION_UP:-$SCRIPT_DIR/integration-up.sh}"
INTEGRATION_DOWN="${ALGOLIA_CUTOVER_ROUNDTRIP_INTEGRATION_DOWN:-$SCRIPT_DIR/integration-down.sh}"
EVIDENCE_ROOT="${ALGOLIA_CUTOVER_ROUNDTRIP_EVIDENCE_ROOT:-$REPO_ROOT/docs/runbooks/evidence/cutover-verification}"
EVIDENCE_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE_DIR="${ALGOLIA_CUTOVER_ROUNDTRIP_EVIDENCE_DIR:-$EVIDENCE_ROOT/${EVIDENCE_STAMP}_algolia_roundtrip}"

ALGOLIA_APP_ID="${ALGOLIA_APP_ID:-}"
ALGOLIA_ADMIN_KEY="${ALGOLIA_ADMIN_KEY:-}"
SOURCE_INDEX="fjcloud-cutover-probe-$RUN_ID"
DESTINATION_INDEX="fjcloud-cutover-destination-$RUN_ID"
NODE_KEY_WARMUP_INDEX="fjcloud-cutover-warmup-$RUN_ID"
PROBE_EMAIL="algolia-cutover-${RUN_ID}@example.test"
PROBE_PASSWORD=""
IDEMPOTENCY_KEY="cutover-roundtrip-$RUN_ID"
RUNTIME_DIR=""
PID_DIR=""
INTEGRATION_DB_EFFECTIVE=""
ALGOLIA_AUTH_CONFIG=""
FJCLOUD_AUTH_CONFIG=""
HTTP_BODY=""
HTTP_STATUS=""
HTTP_HEADERS_FILE=""
HTTP_REQUEST_TARGET=""
HTTP_CURL_EXIT=0
TENANT_TOKEN=""
DISPOSABLE_KEY=""
TARGET_TOKEN=""
JOB_ID=""
STACK_STARTED=0
CLEANUP_DONE=0
CLEANUP_FAILED=0
TERMINAL_RESULT_EMITTED=0
NODE_KEY_WARMUP_CREATED=0
SOURCE_INDEX_CREATED=0
SEED_RECORD_COUNT=""
CURRENT_STEP="startup"

SEED_FIXTURE_FILE=""
MUTATED_FIXTURE_FILE=""
EXPECTED_MATCH_FILE=""
EXPECTED_MUTATION_FILE=""
OBSERVED_MATCH_FILE=""
OBSERVED_MUTATION_FILE=""
OBSERVED_RESTORED_FILE=""
LIST_INDEXES_AFTER_CLEANUP_FILE=""

source "$SCRIPT_DIR/lib/algolia_migration_parity_phase_helpers.sh"

sanitize() {
    local value="$1" lower_app
    if [ -n "${ALGOLIA_APP_ID:-}" ]; then
        lower_app="$(printf '%s' "$ALGOLIA_APP_ID" | tr '[:upper:]' '[:lower:]')"
        value="${value//${ALGOLIA_APP_ID}/[REDACTED_APP_ID]}"
        value="${value//${lower_app}/[REDACTED_APP_ID]}"
    fi
    [ -z "${ALGOLIA_ADMIN_KEY:-}" ] || value="${value//${ALGOLIA_ADMIN_KEY}/[REDACTED]}"
    [ -z "${DISPOSABLE_KEY:-}" ] || value="${value//${DISPOSABLE_KEY}/[REDACTED]}"
    [ -z "${TENANT_TOKEN:-}" ] || value="${value//${TENANT_TOKEN}/[REDACTED]}"
    printf '%s\n' "$value"
}

emit() {
    sanitize "$*"
}

emit_phase() {
    emit "PHASE|name=$1|pass=$2"
}

emit_result() {
    local status="$1" reason="${2:-}"
    TERMINAL_RESULT_EMITTED=1
    if [ -n "$reason" ]; then
        emit "RESULT|status=${status}|reason=${reason}"
    else
        emit "RESULT|status=${status}"
    fi
}

handle_exit() {
    local exit_status=$?
    trap - EXIT
    cleanup_resources >/dev/null 2>&1 || true
    if [ "$exit_status" -ne 0 ] && [ "$TERMINAL_RESULT_EMITTED" -eq 0 ]; then
        emit_result "ACTION_REQUIRED" "unhandled_failure"
    fi
    exit "$exit_status"
}

secure_temp_file() {
    algolia_import_probe_secure_temp_file "$RUNTIME_DIR"
}

write_header_config() {
    algolia_import_probe_write_header_config "$@"
}

write_json_file() {
    algolia_import_probe_write_json_file "$@"
}

json_field() {
    algolia_import_probe_json_field "$@"
}

safe_response_identifier() {
    algolia_import_probe_safe_response_identifier "$1"
}

safe_header_value() {
    algolia_import_probe_safe_header_value "$1"
}

safe_opaque_token() {
    algolia_import_probe_safe_opaque_token "$1"
}

capture_http_response() {
    algolia_import_probe_capture_http_response "$1"
}

curl_http() {
    local expected_statuses="$1"
    shift
    algolia_import_probe_curl_http "$expected_statuses" 5 30 "$@"
}

algolia_url() {
    algolia_import_probe_algolia_url "$1"
}

request_failure_reason() {
    local status="$1"
    case "$status" in
        curl_*) printf 'network_failure\n' ;;
        *) printf 'unexpected_status\n' ;;
    esac
}

algolia_request() {
    algolia_import_probe_algolia_request "$@"
}

api_request() {
    algolia_import_probe_api_request "$@"
}

finish_action_required() {
    local reason="$1" failure_body="${HTTP_BODY:-}" failure_status="${HTTP_STATUS:-none}" failure_target="${HTTP_REQUEST_TARGET:-none}" failure_step="$CURRENT_STEP" body_summary result_reason
    cleanup_resources
    result_reason="$reason"
    [ "$CLEANUP_FAILED" -eq 0 ] || result_reason="cleanup_residue"
    HTTP_BODY="$failure_body"
    CURRENT_STEP="$failure_step"
    body_summary="$(http_body_summary)"
    emit "ERROR|reason=${reason}|step=${CURRENT_STEP}|target=${failure_target}|http_status=${failure_status}|body=${body_summary}"
    [ -n "$RUNTIME_DIR" ] && write_summary "$result_reason" >/dev/null 2>&1 || true
    emit_result "ACTION_REQUIRED" "$result_reason"
    exit 1
}

finish_pass() {
    cleanup_resources
    if [ "$CLEANUP_FAILED" -ne 0 ]; then
        write_summary "cleanup_residue" >/dev/null 2>&1 || true
        emit_result "ACTION_REQUIRED" "cleanup_residue"
        exit 1
    fi
    write_summary "pass"
    emit_result "PASS"
}

validate_credentials() {
    CURRENT_STEP="credentials"
    [ -n "$ALGOLIA_APP_ID" ] || finish_action_required "missing_credentials"
    [ -n "$ALGOLIA_ADMIN_KEY" ] || finish_action_required "missing_credentials"
    [ "${#ALGOLIA_APP_ID}" -le 128 ] && [[ "$ALGOLIA_APP_ID" =~ ^[A-Za-z0-9-]+$ ]] \
        || finish_action_required "invalid_credentials"
    safe_header_value "$ALGOLIA_ADMIN_KEY" || finish_action_required "invalid_credentials"
}

safe_db_fragment() {
    printf '%s' "$RUN_ID" | sed 's/[^A-Za-z0-9_]/_/g'
}

flapjack_binary_runtime_version() {
    local binary_path="$1" build_info
    build_info="$("$binary_path" build-info --json 2>/dev/null)" || return 1
    python3 - "$build_info" <<'PY'
import json
import sys

try:
    payload = json.loads(sys.argv[1])
except json.JSONDecodeError:
    raise SystemExit(1)

build = payload.get("build") if isinstance(payload.get("build"), dict) else payload
if not isinstance(build, dict):
    raise SystemExit(1)
version = build.get("version")
if not isinstance(version, str) or not version:
    raise SystemExit(1)
print(version)
PY
}

prepare_engine_version() {
    CURRENT_STEP="flapjack_identity"
    local binary_path="${FJCLOUD_INTEGRATION_ENGINE_BINARY:-}" resolution_status=0 version
    if [ -z "$binary_path" ]; then
        FLAPJACK_DEV_DIR="$(resolve_default_flapjack_dev_dir)"
        export FLAPJACK_DEV_DIR
        binary_path="$(find_flapjack_binary "$FLAPJACK_DEV_DIR")" || resolution_status=$?
        if [ "$resolution_status" -eq "$FJCLOUD_FLAPJACK_SOURCE_RESOLUTION_FAILURE_STATUS" ]; then
            finish_action_required "unexpected_status"
        fi
    fi
    [ -n "$binary_path" ] && [ -x "$binary_path" ] || finish_action_required "unexpected_status"
    version="$(flapjack_binary_runtime_version "$binary_path")" || finish_action_required "unparsed_response"
    [[ "$version" =~ ^[0-9A-Za-z._+-]+$ ]] || finish_action_required "unparsed_response"
    export FJCLOUD_FLAPJACK_VERSION_OVERRIDE="$version"
}

prepare_runtime() {
    CURRENT_STEP="runtime"
    RUNTIME_DIR="$(mktemp -d "$RUNTIME_PARENT/fjcloud-cutover-roundtrip.XXXXXX")"
    trap handle_exit EXIT
    PID_DIR="$RUNTIME_DIR/pids"
    mkdir -p "$PID_DIR" "$EVIDENCE_DIR"
    PROBE_PASSWORD="$(algolia_import_probe_generate_secret)"
    INTEGRATION_DB_EFFECTIVE="fjcloud_cutover_probe_$(safe_db_fragment)"
    validate_integration_db_name "$INTEGRATION_DB_EFFECTIVE" || finish_action_required "invalid_response_identifier"
    export INTEGRATION_DB="$INTEGRATION_DB_EFFECTIVE"
    unset INTEGRATION_DB_URL
    init_integration_env_defaults
    ALGOLIA_AUTH_CONFIG="$(secure_temp_file)"
    FJCLOUD_AUTH_CONFIG="$(secure_temp_file)"
    SEED_FIXTURE_FILE="$(secure_temp_file)"
    MUTATED_FIXTURE_FILE="$(secure_temp_file)"
    EXPECTED_MATCH_FILE="$(secure_temp_file)"
    EXPECTED_MUTATION_FILE="$(secure_temp_file)"
    OBSERVED_MATCH_FILE="$EVIDENCE_DIR/observed_match_report.json"
    OBSERVED_MUTATION_FILE="$EVIDENCE_DIR/mutation_mismatch_report.json"
    OBSERVED_RESTORED_FILE="$EVIDENCE_DIR/restored_match_report.json"
    LIST_INDEXES_AFTER_CLEANUP_FILE="$EVIDENCE_DIR/list_indexes_after_cleanup.json"
    write_header_config "$ALGOLIA_AUTH_CONFIG" \
        "X-Algolia-Application-Id: $ALGOLIA_APP_ID" \
        "X-Algolia-API-Key: $ALGOLIA_ADMIN_KEY"
    write_probe_fixtures
    SEED_RECORD_COUNT="$(record_count)" || finish_action_required "unparsed_response"
    write_expected_reports
}

write_probe_fixtures() {
    python3 - "$SEED_FIXTURE_FILE" "$MUTATED_FIXTURE_FILE" <<'PY'
import json
import sys
seed = [
    {"objectID": "doc-alpha", "title": "UniqueAlpha", "category": "shoes", "rank": 1},
    {"objectID": "doc-shared", "title": "UniqueShared", "category": "shoes", "rank": 2},
    {"objectID": "doc-beta", "title": "UniqueBeta", "category": "bags", "rank": 3},
]
mutated = [
    {"objectID": "doc-mutated", "title": "UniqueAlpha", "category": "shoes", "rank": 1},
    seed[1],
    seed[2],
]
for path, docs in ((sys.argv[1], seed), (sys.argv[2], mutated)):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(docs, handle, separators=(",", ":"))
PY
}

write_expected_reports() {
    python3 - "$EXPECTED_MATCH_FILE" "$EXPECTED_MUTATION_FILE" "$SOURCE_INDEX" "$DESTINATION_INDEX" <<'PY'
import json
import sys
match_path, mutation_path, source_index, destination_index = sys.argv[1:]
match = {
    "sourceIndex": source_index,
    "destinationIndex": destination_index,
    "resultLimit": 3,
    "queries": [
        {
            "query": "uniquealpha",
            "overlapCount": 1,
            "sourceOnly": [],
            "destinationOnly": [],
            "hits": [
                {"objectID": "doc-alpha", "sourceRank": 1, "destinationRank": 1, "rankDelta": 0},
            ],
        },
        {
            "query": "uniqueshared",
            "overlapCount": 1,
            "sourceOnly": [],
            "destinationOnly": [],
            "hits": [
                {"objectID": "doc-shared", "sourceRank": 1, "destinationRank": 1, "rankDelta": 0},
            ],
        },
    ],
}
mutation = {
    "sourceIndex": source_index,
    "destinationIndex": destination_index,
    "resultLimit": 3,
    "queries": [
        {
            "query": "uniquealpha",
            "overlapCount": 0,
            "sourceOnly": ["doc-mutated"],
            "destinationOnly": ["doc-alpha"],
            "hits": [],
        },
        match["queries"][1],
    ],
}
for path, payload in ((match_path, match), (mutation_path, mutation)):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
PY
}

start_stack() {
    CURRENT_STEP="integration_start"
    STACK_STARTED=1
    FJCLOUD_INTEGRATION_PID_DIR="$PID_DIR" INTEGRATION_DB="$INTEGRATION_DB_EFFECTIVE" \
        FJCLOUD_ALGOLIA_MIGRATION_ENABLED=true FJCLOUD_INTEGRATION_SKIP_METERING_AGENT=1 \
        ENVIRONMENT=local SKIP_EMAIL_VERIFICATION=1 "$INTEGRATION_UP" >/dev/null \
        || finish_action_required "unexpected_status"
}

require_health() {
    CURRENT_STEP="health"
    api_request "200" GET "/health" "" "" || finish_action_required "$(request_failure_reason "$HTTP_STATUS")"
    HTTP_REQUEST_TARGET="Engine GET /health"
    curl_http "200" -X GET "${ENGINE_URL%/}/health" || finish_action_required "$(request_failure_reason "$HTTP_STATUS")"
}

register_and_login() {
    CURRENT_STEP="tenant_auth"
    local payload
    payload="$(secure_temp_file)"
    write_json_file "$payload" "{\"name\":\"Algolia Cutover Probe\",\"email\":\"$PROBE_EMAIL\",\"password\":\"$PROBE_PASSWORD\"}"
    api_request "201" POST "/auth/register" "$payload" "" || finish_action_required "$(request_failure_reason "$HTTP_STATUS")"
    api_request "200" POST "/auth/login" "$payload" "" || finish_action_required "$(request_failure_reason "$HTTP_STATUS")"
    TENANT_TOKEN="$(json_field "$HTTP_BODY" token 2>/dev/null || true)"
    [ -n "$TENANT_TOKEN" ] || finish_action_required "unparsed_response"
    safe_header_value "$TENANT_TOKEN" || finish_action_required "invalid_response_identifier"
    write_header_config "$FJCLOUD_AUTH_CONFIG" "authorization: Bearer $TENANT_TOKEN"
}

require_migration_availability() {
    CURRENT_STEP="migration_availability"
    api_request "200" GET "/migration/algolia/availability" "" "" || finish_action_required "$(request_failure_reason "$HTTP_STATUS")"
    python3 - "$HTTP_BODY" <<'PY' || finish_action_required "unparsed_response"
import json
import sys
payload = json.loads(sys.argv[1])
caps = payload.get("capabilities")
if payload.get("available") is not True or not isinstance(caps, dict) or caps.get("verify") is not True:
    raise SystemExit(1)
PY
}

seed_source_index() {
    CURRENT_STEP="seed_source"
    local payload task_id
    algolia_request "404" GET "/1/indexes/$SOURCE_INDEX" || finish_action_required "$(request_failure_reason "$HTTP_STATUS")"
    payload="$(secure_temp_file)"
    fixture_to_batch "$SEED_FIXTURE_FILE" "$payload"
    algolia_request "200 201" POST "/1/indexes/$SOURCE_INDEX/batch" "$payload" || finish_action_required "$(request_failure_reason "$HTTP_STATUS")"
    SOURCE_INDEX_CREATED=1
    task_id="$(json_field "$HTTP_BODY" taskID 2>/dev/null || true)"
    if [ -n "$task_id" ]; then
        safe_response_identifier "$task_id" || finish_action_required "invalid_response_identifier"
        algolia_import_probe_wait_for_algolia_task "$SOURCE_INDEX" "$task_id" \
            || finish_action_required "unparsed_response"
    fi
}

fixture_to_batch() {
    local fixture_file="$1" output="$2"
    python3 - "$fixture_file" "$output" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    docs = json.load(handle)
requests = [{"action": "addObject", "body": doc} for doc in docs]
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump({"requests": requests}, handle, separators=(",", ":"))
PY
}

mutate_source_index() {
    CURRENT_STEP="mutate_source"
    local fixture_file="$1" payload task_id
    payload="$(secure_temp_file)"
    python3 - "$fixture_file" "$payload" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    docs = json.load(handle)
requests = [
    {"action": "deleteObject", "body": {"objectID": "doc-alpha"}},
    {"action": "deleteObject", "body": {"objectID": "doc-mutated"}},
]
requests.extend({"action": "addObject", "body": doc} for doc in docs)
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump({"requests": requests}, handle, separators=(",", ":"))
PY
    algolia_request "200 201" POST "/1/indexes/$SOURCE_INDEX/batch" "$payload" || finish_action_required "$(request_failure_reason "$HTTP_STATUS")"
    task_id="$(json_field "$HTTP_BODY" taskID 2>/dev/null || true)"
    if [ -n "$task_id" ]; then
        safe_response_identifier "$task_id" || finish_action_required "invalid_response_identifier"
        algolia_import_probe_wait_for_algolia_task "$SOURCE_INDEX" "$task_id" \
            || finish_action_required "unparsed_response"
    fi
}

create_restricted_key() {
    CURRENT_STEP="source_key"
    local payload
    payload="$(secure_temp_file)"
    write_json_file "$payload" "{\"acl\":[\"search\",\"browse\",\"settings\",\"listIndexes\"],\"indexes\":[\"$SOURCE_INDEX\"],\"description\":\"fjcloud-cutover-$RUN_ID\"}"
    algolia_request "200 201" POST "/1/keys" "$payload" || finish_action_required "$(request_failure_reason "$HTTP_STATUS")"
    DISPOSABLE_KEY="$(json_field "$HTTP_BODY" key 2>/dev/null || true)"
    [ -n "$DISPOSABLE_KEY" ] || finish_action_required "unparsed_response"
    safe_response_identifier "$DISPOSABLE_KEY" || finish_action_required "invalid_response_identifier"
    algolia_import_probe_wait_for_restricted_source_key "$SOURCE_INDEX" "$DISPOSABLE_KEY" \
        || finish_action_required "unexpected_status"
}

obtain_target_envelope() {
    CURRENT_STEP="destination_eligibility"
    algolia_import_probe_obtain_target_envelope "$DESTINATION_INDEX"
}

dispatch_job() {
    CURRENT_STEP="dispatch_job"
    local payload location
    payload="$(secure_temp_file)"
    write_json_file "$payload" "{\"mode\":\"create\",\"appId\":\"$ALGOLIA_APP_ID\",\"apiKey\":\"$DISPOSABLE_KEY\",\"sourceName\":\"$SOURCE_INDEX\",\"target\":{\"eligibilityToken\":\"$TARGET_TOKEN\"}}"
    api_request "202" POST "/migration/algolia/jobs" "$payload" "$IDEMPOTENCY_KEY" || finish_action_required "$(request_failure_reason "$HTTP_STATUS")"
    JOB_ID="$(json_field "$HTTP_BODY" id 2>/dev/null || true)"
    location="$(sed -n 's/^[Ll]ocation:[[:space:]]*//p' "$HTTP_HEADERS_FILE" | tr -d '\r' | tail -1)"
    [ -n "$JOB_ID" ] || finish_action_required "unparsed_response"
    safe_response_identifier "$JOB_ID" || finish_action_required "invalid_response_identifier"
    [ "$location" = "/migration/algolia/jobs/$JOB_ID" ] || finish_action_required "unparsed_response"
}

poll_job_to_terminal() {
    CURRENT_STEP="terminal_poll"
    local elapsed=0 status disposition resumable
    while :; do
        api_request "200" GET "/migration/algolia/jobs/$JOB_ID" "" "" || finish_action_required "$(request_failure_reason "$HTTP_STATUS")"
        status="$(json_field "$HTTP_BODY" status 2>/dev/null || true)"
        disposition="$(json_field "$HTTP_BODY" publicationDisposition 2>/dev/null || true)"
        resumable="$(json_field "$HTTP_BODY" resumable 2>/dev/null || true)"
        if { [ "$status" = "completed" ] || [ "$status" = "completed_with_warnings" ]; } \
            && [ "$disposition" = "promoted" ] && [ "$resumable" = "false" ]; then
            return 0
        fi
        case "$status" in
            queued|validating_source|copying_configuration|copying_documents|verifying|promoting) ;;
            failed|cancelled) finish_action_required "migration_failed" ;;
            completed|completed_with_warnings) finish_action_required "migration_failed" ;;
            *) finish_action_required "unparsed_response" ;;
        esac
        [ "$elapsed" -lt "$POLL_SECONDS" ] || finish_action_required "unexpected_status"
        sleep "$POLL_INTERVAL_SECONDS"
        elapsed=$((elapsed + POLL_INTERVAL_SECONDS))
    done
}

job_engine_acknowledged_count() {
    init_integration_db_access >/dev/null 2>&1 || return 1
    run_integration_psql "$INTEGRATION_DB_EFFECTIVE" -tAc \
        "SELECT COUNT(*) FROM algolia_import_jobs WHERE id = '${JOB_ID}' AND engine_ack_state = 'acknowledged'; /* probe:cutover_engine_ack */" \
        2>/dev/null | tr -d '[:space:]'
}

job_reconciliation_debug() {
    init_integration_db_access >/dev/null 2>&1 || return 1
    run_integration_psql "$INTEGRATION_DB_EFFECTIVE" -tAc \
        "SELECT concat_ws(',', 'ack=' || engine_ack_state, 'updated=' || EXTRACT(EPOCH FROM updated_at)::bigint) FROM algolia_import_jobs WHERE id = '${JOB_ID}' AND erased_at IS NULL; /* probe:cutover_reconciliation_debug */" \
        2>/dev/null | tr -d '[:space:]'
}

verify_report() {
    local output_file="$1" expected_file="$2" phase="$3" payload
    CURRENT_STEP="$phase"
    payload="$(secure_temp_file)"
    write_json_file "$payload" "{\"appId\":\"$ALGOLIA_APP_ID\",\"apiKey\":\"$DISPOSABLE_KEY\",\"sourceIndex\":\"$SOURCE_INDEX\",\"destinationIndex\":\"$DESTINATION_INDEX\",\"queries\":[\"uniquealpha\",\"uniqueshared\"],\"resultLimit\":3}"
    api_request "200" POST "/migration/algolia/verify" "$payload" "" || finish_action_required "$(request_failure_reason "$HTTP_STATUS")"
    printf '%s' "$HTTP_BODY" > "$output_file"
    assert_json_file_equals "$output_file" "$expected_file" || {
        emit_json_diff_summary "$output_file" "$expected_file"
        finish_action_required "parity_mismatch"
    }
    emit_phase "$phase" "true"
}

assert_json_file_equals() {
    local observed="$1" expected="$2"
    python3 - "$observed" "$expected" <<'PY'
import json
import sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        observed = json.load(handle)
    with open(sys.argv[2], encoding="utf-8") as handle:
        expected = json.load(handle)
except json.JSONDecodeError:
    raise SystemExit(2)
if observed != expected:
    raise SystemExit(1)
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(observed, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
    case "$?" in
        0) return 0 ;;
        2) finish_action_required "unparsed_response" ;;
        *) return 1 ;;
    esac
}

emit_json_diff_summary() {
    local observed="$1" expected="$2"
    python3 - "$observed" "$expected" <<'PY' || true
import json
import sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        observed = json.load(handle)
    with open(sys.argv[2], encoding="utf-8") as handle:
        expected = json.load(handle)
except json.JSONDecodeError:
    print("VERIFY_DIFF|summary=unparsed")
    raise SystemExit(0)
print(
    "VERIFY_DIFF|observed_queries={oq}|expected_queries={eq}".format(
        oq=len(observed.get("queries", [])) if isinstance(observed, dict) else "unknown",
        eq=len(expected.get("queries", [])) if isinstance(expected, dict) else "unknown",
    )
)
PY
}

prime_local_node_key() {
    CURRENT_STEP="local_node_key_warmup"
    local payload
    payload="$(secure_temp_file)"
    write_json_file "$payload" "{\"name\":\"$NODE_KEY_WARMUP_INDEX\",\"region\":\"us-east-1\"}"
    api_request "201" POST "/indexes" "$payload" "" || finish_action_required "$(request_failure_reason "$HTTP_STATUS")"
    NODE_KEY_WARMUP_CREATED=1
    delete_node_key_warmup_index || finish_action_required "unexpected_status"
}

delete_node_key_warmup_index() {
    [ "$NODE_KEY_WARMUP_CREATED" -eq 1 ] || return 0
    local payload
    payload="$(secure_temp_file)" || return 1
    write_json_file "$payload" '{"confirm":true}' || return 1
    api_request "204 404" DELETE "/indexes/$NODE_KEY_WARMUP_INDEX" "$payload" "" >/dev/null || return 1
    NODE_KEY_WARMUP_CREATED=0
}

run_roundtrip() {
    start_stack
    require_health
    register_and_login
    require_migration_availability
    seed_source_index
    create_restricted_key
    prime_local_node_key
    obtain_target_envelope
    dispatch_job
    poll_job_to_terminal
    require_engine_acknowledged
    cp "$EXPECTED_MATCH_FILE" "$EVIDENCE_DIR/expected_report.json"
    verify_report "$OBSERVED_MATCH_FILE" "$EXPECTED_MATCH_FILE" "verify_match"
    mutate_source_index "$MUTATED_FIXTURE_FILE"
    verify_report "$OBSERVED_MUTATION_FILE" "$EXPECTED_MUTATION_FILE" "verify_mutation_mismatch"
    mutate_source_index "$SEED_FIXTURE_FILE"
    verify_report "$OBSERVED_RESTORED_FILE" "$EXPECTED_MATCH_FILE" "verify_restored_match"
}

cleanup_resources() {
    [ "$CLEANUP_DONE" -eq 0 ] || return 0
    CLEANUP_DONE=1
    set +e
    local algolia_residue=0 destination_residue=0 key_residue=0 local_residue=0
    if [ -n "${ALGOLIA_AUTH_CONFIG:-}" ] && [ -n "${SOURCE_INDEX:-}" ]; then
        algolia_import_probe_delete_algolia_index "$SOURCE_INDEX" "$CLEANUP_POLL_ATTEMPTS" "$CLEANUP_POLL_INTERVAL_SECONDS" \
            || CLEANUP_FAILED=1
    fi
    delete_node_key_warmup_index || CLEANUP_FAILED=1
    if [ "$STACK_STARTED" -eq 1 ] && [ -n "${TENANT_TOKEN:-}" ]; then
        delete_destination_index || CLEANUP_FAILED=1
    fi
    if [ -n "${DISPOSABLE_KEY:-}" ]; then
        curl_http "200 204 404" --config "$ALGOLIA_AUTH_CONFIG" -X DELETE "$(algolia_url "/1/keys/$DISPOSABLE_KEY")" >/dev/null \
            || CLEANUP_FAILED=1
        algolia_import_probe_wait_for_algolia_key_absence "$DISPOSABLE_KEY" "$CLEANUP_POLL_ATTEMPTS" "$CLEANUP_POLL_INTERVAL_SECONDS" \
            || CLEANUP_FAILED=1
    fi
    algolia_residue="$(probe_algolia_index_residue)"
    destination_residue="$(probe_destination_residue)"
    key_residue="$(probe_key_residue)"
    if [ "$STACK_STARTED" -eq 1 ]; then
        FJCLOUD_INTEGRATION_PID_DIR="$PID_DIR" INTEGRATION_DB="$INTEGRATION_DB_EFFECTIVE" "$INTEGRATION_DOWN" >/dev/null 2>&1 \
            || CLEANUP_FAILED=1
    fi
    [ -n "$RUNTIME_DIR" ] && rm -rf "$RUNTIME_DIR" 2>/dev/null || true
    [ -n "$RUNTIME_DIR" ] && [ -e "$RUNTIME_DIR" ] && local_residue=1
    [ "$algolia_residue" = "0" ] || CLEANUP_FAILED=1
    [ "$destination_residue" = "0" ] || CLEANUP_FAILED=1
    [ "$key_residue" = "0" ] || CLEANUP_FAILED=1
    [ "$local_residue" = "0" ] || CLEANUP_FAILED=1
    emit "CLEANUP|algolia_index=${algolia_residue}|destination_index=${destination_residue}|algolia_key=${key_residue}|local_stack=${local_residue}"
    set -e
}

delete_destination_index() {
    local payload
    payload="$(secure_temp_file)" || return 1
    write_json_file "$payload" '{"confirm":true}' || return 1
    api_request "204 404" DELETE "/indexes/$DESTINATION_INDEX" "$payload" "" >/dev/null || return 1
}

probe_algolia_index_residue() {
    [ -n "${ALGOLIA_AUTH_CONFIG:-}" ] || { printf '0\n'; return 0; }
    local page=0 nb_pages=1 aggregate_file
    aggregate_file="$(secure_temp_file)" || { printf '1\n'; return 0; }
    printf '{"items":[]}\n' > "$aggregate_file" || { printf '1\n'; return 0; }
    mkdir -p "$EVIDENCE_DIR" 2>/dev/null || true
    while [ "$page" -lt "$nb_pages" ]; do
        curl_http "200" --config "$ALGOLIA_AUTH_CONFIG" -X GET "$(algolia_url "/1/indexes?page=${page}&hitsPerPage=100")" >/dev/null \
            || { printf '1\n'; return 0; }
        nb_pages="$(
            python3 - "$HTTP_BODY" "$SOURCE_INDEX" "$aggregate_file" "$LIST_INDEXES_AFTER_CLEANUP_FILE" "$page" <<'PY'
import json
import sys
payload_text, source_index, aggregate_path, proof_path, page_text = sys.argv[1:]
expected_page = int(page_text)

def write_parse_error():
    with open(proof_path, "w", encoding="utf-8") as handle:
        json.dump({"items": [], "parse_error": True}, handle, separators=(",", ":"))
        handle.write("\n")

try:
    payload = json.loads(payload_text)
    with open(aggregate_path, encoding="utf-8") as handle:
        aggregate = json.load(handle)
except (OSError, json.JSONDecodeError):
    write_parse_error()
    raise SystemExit(1)

items = payload.get("items", [])
if not isinstance(items, list):
    write_parse_error()
    raise SystemExit(1)

response_page = payload.get("page", expected_page)
nb_pages = payload.get("nbPages", expected_page + 1)
if not isinstance(response_page, int) or response_page != expected_page:
    write_parse_error()
    raise SystemExit(1)
if not isinstance(nb_pages, int):
    write_parse_error()
    raise SystemExit(1)
if nb_pages == 0 and expected_page == 0:
    nb_pages = 1
elif nb_pages < expected_page + 1:
    write_parse_error()
    raise SystemExit(1)

probe_items = aggregate.get("items", [])
if not isinstance(probe_items, list):
    write_parse_error()
    raise SystemExit(1)
for item in items:
    if not isinstance(item, dict):
        continue
    name = item.get("name")
    if isinstance(name, str) and name.startswith("fjcloud-cutover-probe-"):
        probe_items.append({"name": name})
with open(aggregate_path, "w", encoding="utf-8") as handle:
    json.dump({"items": probe_items}, handle, separators=(",", ":"))
    handle.write("\n")
with open(proof_path, "w", encoding="utf-8") as handle:
    json.dump({"items": probe_items}, handle, separators=(",", ":"))
    handle.write("\n")
print(nb_pages)
PY
        )" || { printf '1\n'; return 0; }
        page=$((page + 1))
    done
    python3 - "$SOURCE_INDEX" "$aggregate_file" <<'PY'
import json
import sys

source_index, aggregate_path = sys.argv[1:]
try:
    with open(aggregate_path, encoding="utf-8") as handle:
        items = json.load(handle)["items"]
except (OSError, KeyError, json.JSONDecodeError):
    print(1)
    raise SystemExit(0)
print(1 if any(item.get("name") == source_index for item in items if isinstance(item, dict)) else 0)
PY
}

probe_destination_residue() {
    [ "$STACK_STARTED" -eq 1 ] && [ -n "${TENANT_TOKEN:-}" ] || { printf '0\n'; return 0; }
    local payload
    payload="$(secure_temp_file)" || { printf '1\n'; return 0; }
    write_json_file "$payload" '{}' || { printf '1\n'; return 0; }
    api_request "200 404" POST "/indexes/$DESTINATION_INDEX/browse" "$payload" "" >/dev/null || { printf '1\n'; return 0; }
    [ "$HTTP_STATUS" = "404" ] && printf '0\n' || printf '1\n'
}

probe_key_residue() {
    [ -n "${DISPOSABLE_KEY:-}" ] || { printf '0\n'; return 0; }
    curl_http "200 404" --config "$ALGOLIA_AUTH_CONFIG" -X GET "$(algolia_url "/1/keys/$DISPOSABLE_KEY")" >/dev/null \
        || { printf '1\n'; return 0; }
    [ "$HTTP_STATUS" = "404" ] && printf '0\n' || printf '1\n'
}

record_count() {
    [ -z "${SEED_RECORD_COUNT:-}" ] || { printf '%s\n' "$SEED_RECORD_COUNT"; return 0; }
    python3 - "$SEED_FIXTURE_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(len(json.load(handle)))
PY
}

write_summary() {
    local verdict="$1" list_absent="unknown" summary_path="$EVIDENCE_DIR/SUMMARY.md"
    mkdir -p "$EVIDENCE_DIR"
    if [ "$SOURCE_INDEX_CREATED" -ne 1 ]; then
        list_absent="not_created"
    elif [ -f "$LIST_INDEXES_AFTER_CLEANUP_FILE" ]; then
        list_absent="$(python3 - "$LIST_INDEXES_AFTER_CLEANUP_FILE" "$SOURCE_INDEX" <<'PY'
import json
import sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        payload = json.load(handle)
except (OSError, json.JSONDecodeError):
    print("unknown")
    raise SystemExit(0)
if not isinstance(payload, dict) or payload.get("parse_error") is True:
    print("unknown")
    raise SystemExit(0)
items = payload.get("items", [])
if not isinstance(items, list):
    print("unknown")
    raise SystemExit(0)
absent = all(not (isinstance(item, dict) and item.get("name") == sys.argv[2]) for item in items)
print("true" if absent else "false")
PY
)"
    fi
    {
        printf '# Algolia Cutover Roundtrip Evidence\n\n'
        printf -- '- verdict: %s\n' "$verdict"
        printf -- '- step: %s\n' "$CURRENT_STEP"
        printf -- '- record_count: %s\n' "$(record_count 2>/dev/null || printf 'unknown')"
        printf -- '- source_index: %s\n' "$SOURCE_INDEX"
        printf -- '- destination_index: %s\n' "$DESTINATION_INDEX"
        printf -- '- deletion_proof_exact_source_absent: %s\n' "$list_absent"
        printf '\n## Expected Report\n\n```json\n'
        [ -f "$EVIDENCE_DIR/expected_report.json" ] && sanitize "$(cat "$EVIDENCE_DIR/expected_report.json")" || sanitize "$(cat "$EXPECTED_MATCH_FILE" 2>/dev/null || true)"
        printf '```\n\n## Observed Match Report\n\n```json\n'
        [ -f "$OBSERVED_MATCH_FILE" ] && sanitize "$(cat "$OBSERVED_MATCH_FILE")"
        printf '```\n\n## Mutation Mismatch Report\n\n```json\n'
        [ -f "$OBSERVED_MUTATION_FILE" ] && sanitize "$(cat "$OBSERVED_MUTATION_FILE")"
        printf '```\n\n## Restored Match Report\n\n```json\n'
        [ -f "$OBSERVED_RESTORED_FILE" ] && sanitize "$(cat "$OBSERVED_RESTORED_FILE")"
        printf '```\n\n## Sanitized Follow-Up List Indexes\n\n```json\n'
        [ -f "$LIST_INDEXES_AFTER_CLEANUP_FILE" ] && sanitize "$(cat "$LIST_INDEXES_AFTER_CLEANUP_FILE")"
        printf '```\n'
    } > "$summary_path"
    emit "EVIDENCE|summary=$summary_path|source_index=$SOURCE_INDEX|deleted_absent=$list_absent"
}

main() {
    validate_credentials
    prepare_runtime
    prepare_engine_version
    run_roundtrip
    finish_pass
}

main "$@"
