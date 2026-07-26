#!/usr/bin/env bash
# Live create-into-fresh parity proof for Algolia migration.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=scripts/lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=scripts/lib/flapjack_binary.sh
source "$SCRIPT_DIR/lib/flapjack_binary.sh"
# shellcheck source=scripts/lib/algolia_import_live_probe_common.sh
source "$SCRIPT_DIR/lib/algolia_import_live_probe_common.sh"
# shellcheck source=scripts/lib/integration_db_access.sh
source "$SCRIPT_DIR/lib/integration_db_access.sh"
# shellcheck source=scripts/lib/integration_stack_env.sh
source "$SCRIPT_DIR/lib/integration_stack_env.sh"

ALLOWED_PHASES="create_into_fresh,overwrite_rerun,idempotency,cancel_partial,resume_refused"
REQUESTED_PHASES="create_into_fresh"
SECRET_FILE="${FJCLOUD_SECRET_FILE:-$REPO_ROOT/.secret/.env.secret}"
FIXTURE_FILE="$REPO_ROOT/scripts/tests/fixtures/algolia_migration_parity_source.json"
PARITY_ORACLE="$REPO_ROOT/scripts/lib/algolia_migration_parity.py"
RUN_ID="${ALGOLIA_MIGRATION_PARITY_RUN_ID:-$(date -u +%Y%m%d%H%M%S)_$$}"
PROBE_PREFIX="${ALGOLIA_MIGRATION_PARITY_PREFIX:-fjcloud_migration_parity_probe}"
RUNTIME_PARENT="${ALGOLIA_MIGRATION_PARITY_RUNTIME_PARENT:-${TMPDIR:-/tmp}}"
POLL_SECONDS="${ALGOLIA_MIGRATION_PARITY_POLL_SECONDS:-180}"
POLL_INTERVAL_SECONDS="${ALGOLIA_MIGRATION_PARITY_POLL_INTERVAL_SECONDS:-2}"
CLEANUP_POLL_ATTEMPTS="${ALGOLIA_MIGRATION_PARITY_CLEANUP_POLL_ATTEMPTS:-45}"
CLEANUP_POLL_INTERVAL_SECONDS="${ALGOLIA_MIGRATION_PARITY_CLEANUP_POLL_INTERVAL_SECONDS:-1}"
PRESERVE_FAILURE_RUNTIME="${ALGOLIA_MIGRATION_PARITY_PRESERVE_FAILURE_RUNTIME:-0}"
API_PORT="${API_PORT:-3099}"
FLAPJACK_PORT="${FLAPJACK_PORT:-7799}"
API_URL="${ALGOLIA_MIGRATION_PARITY_API_URL:-http://127.0.0.1:${API_PORT}}"
ENGINE_URL="${ALGOLIA_MIGRATION_PARITY_ENGINE_URL:-http://127.0.0.1:${FLAPJACK_PORT}}"
INTEGRATION_UP="${ALGOLIA_MIGRATION_PARITY_INTEGRATION_UP:-$SCRIPT_DIR/integration-up.sh}"
INTEGRATION_DOWN="${ALGOLIA_MIGRATION_PARITY_INTEGRATION_DOWN:-$SCRIPT_DIR/integration-down.sh}"

ALGOLIA_APP_ID="${ALGOLIA_APP_ID:-}"
ALGOLIA_ADMIN_KEY="${ALGOLIA_ADMIN_KEY:-}"
RUNTIME_DIR=""
PID_DIR=""
INTEGRATION_DB_EFFECTIVE=""
BASE_SOURCE_INDEX=""
BASE_TARGET_INDEX=""
SOURCE_INDEX=""
TARGET_INDEX=""
SECOND_SOURCE_INDEX=""
NODE_KEY_WARMUP_INDEX=""
PROBE_EMAIL=""
PROBE_PASSWORD=""
IDEMPOTENCY_KEY=""
TENANT_TOKEN=""
TARGET_TOKEN=""
DISPOSABLE_KEY=""
JOB_ID=""
JOB_LOCATION=""
ALGOLIA_AUTH_CONFIG=""
FJCLOUD_AUTH_CONFIG=""
HTTP_BODY=""
HTTP_STATUS=""
HTTP_HEADERS_FILE=""
HTTP_REQUEST_TARGET=""
CUSTOMER_VISIBLE_TARGET_COUNT=""
STACK_STARTED=0
CLEANUP_DONE=0
CLEANUP_FAILED=0
# Set when a tracked migration job is still running/unacknowledged after the
# accepted-job drain budget. Deleting its source index, restricted key, or
# target would race the live worker, so cleanup preserves every remote resource
# and reports it as residue instead of deleting it.
PRESERVE_LIVE_JOB_RESOURCES=0
NODE_KEY_WARMUP_CREATED=0
CURRENT_STEP="startup"
CREATED_INDEXES=()
CREATED_KEYS=()
CREATED_TARGETS=()
SOURCE_HITS_FILE=""
MIGRATED_HITS_FILE=""
PARITY_REPORT_FILE=""
ALGOLIA_INDEX_RESIDUE=0
FLAPJACK_INDEX_RESIDUE=0
ALGOLIA_KEY_RESIDUE=0
LOCAL_STACK_RESIDUE=0
RUNTIME_FILE_RESIDUE=0
FLAPJACK_TARGET_DELETE_STATUSES=""
FLAPJACK_TARGET_DELETE_BODY_SUMMARIES=""
FLAPJACK_TARGET_RESIDUE_STATUSES=""

usage() {
    cat >&2 <<'USAGE'
Usage: algolia_migration_parity_live_probe.sh --phases create_into_fresh,overwrite_rerun,idempotency,cancel_partial,resume_refused
USAGE
}
sanitize() {
    local value="$1"
    [ -z "${ALGOLIA_ADMIN_KEY:-}" ] || value="${value//${ALGOLIA_ADMIN_KEY}/[REDACTED]}"
    [ -z "${DISPOSABLE_KEY:-}" ] || value="${value//${DISPOSABLE_KEY}/[REDACTED]}"
    [ -z "${TENANT_TOKEN:-}" ] || value="${value//${TENANT_TOKEN}/[REDACTED]}"
    printf '%s\n' "$value"
}
emit() {
    sanitize "$*"
}
emit_phase() {
    emit "PHASE|name=$1|expected=$2|observed=$3|pass=$4"
}
emit_result() {
    local status="$1" reason="${2:-}"
    if [ -n "$reason" ]; then
        emit "RESULT|status=${status}|reason=${reason}|phases=${REQUESTED_PHASES}"
    else
        emit "RESULT|status=${status}|phases=${REQUESTED_PHASES}"
    fi
}
secure_temp_file() {
    algolia_import_probe_secure_temp_file "$RUNTIME_DIR"
}
curl_config_escape() {
    algolia_import_probe_curl_config_escape "$1"
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
    local response="$1"
    HTTP_STATUS="${response##*$'\n'}"
    HTTP_BODY="${response%$'\n'*}"
    [ "$HTTP_STATUS" != "$response" ] || HTTP_BODY=""
    HTTP_STATUS="$(printf '%s' "$HTTP_STATUS" | tr -d '\r[:space:]')"
}
curl_http() {
    local expected_statuses="$1"
    shift
    local response
    response="$(curl -sS --connect-timeout 2 --max-time 20 -w "\n%{http_code}" "$@" || true)"
    capture_http_response "$response"
    case " $expected_statuses " in
        *" $HTTP_STATUS "*) return 0 ;;
        *) return 1 ;;
    esac
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --phases)
                [ "${2:-}" != "" ] || {
                    REQUESTED_PHASES=""
                    if [ "$#" -ge 2 ]; then
                        shift 2
                    else
                        shift
                    fi
                    continue
                }
                REQUESTED_PHASES="${2:-}"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                usage
                finish_action_required "invalid_args"
                ;;
        esac
    done
}

validate_phase_set() {
    local IFS=',' phase
    [ -n "$REQUESTED_PHASES" ] || finish_action_required "invalid_phases"
    for phase in $REQUESTED_PHASES; do
        case "$phase" in
            create_into_fresh|overwrite_rerun|idempotency|cancel_partial|resume_refused) ;;
            *) finish_action_required "invalid_phases" ;;
        esac
    done
}

run_static_w1_gate() {
    CURRENT_STEP="w1_static_gate"
    if ! git grep -q 'fn algolia_availability' origin/main -- infra/api/src/routes/migration.rs \
        || ! git grep -q 'fn compute_availability' origin/main -- infra/api/src/routes/migration.rs; then
        emit "ANTI_STOP|owner=W1|unblock_file=infra/api/src/routes/migration.rs|decision=wait_for_availability_surface"
        finish_action_required "w1_static_gate_unavailable"
    fi
}

load_algolia_secrets() {
    local line line_number=0 parse_status
    CURRENT_STEP="credentials"
    [ -f "$SECRET_FILE" ] || finish_action_required "missing_credentials"
    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))
        parse_env_assignment_line "$line" && parse_status=0 || parse_status=$?
        case "$parse_status" in
            0)
                case "$ENV_ASSIGNMENT_KEY" in
                    ALGOLIA_APP_ID)
                        ALGOLIA_APP_ID="$ENV_ASSIGNMENT_VALUE"
                        ;;
                    ALGOLIA_ADMIN_KEY)
                        ALGOLIA_ADMIN_KEY="$ENV_ASSIGNMENT_VALUE"
                        ;;
                esac
                ;;
            2) ;;
            *)
                emit "ERROR|reason=unsupported_secret_syntax|line=${line_number}"
                finish_action_required "missing_credentials"
                ;;
        esac
    done < "$SECRET_FILE"
    [ -n "$ALGOLIA_APP_ID" ] || finish_action_required "missing_credentials"
    [ -n "$ALGOLIA_ADMIN_KEY" ] || finish_action_required "missing_credentials"
    [ "${#ALGOLIA_APP_ID}" -le 128 ] && [[ "$ALGOLIA_APP_ID" =~ ^[A-Za-z0-9-]+$ ]] \
        || finish_action_required "invalid_response_identifier"
    safe_header_value "$ALGOLIA_ADMIN_KEY" || finish_action_required "invalid_response_identifier"
}

prepare_runtime() {
    [[ "$PROBE_PREFIX" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || finish_action_required "invalid_probe_prefix"
    [[ "$RUN_ID" =~ ^[A-Za-z0-9_]+$ ]] || finish_action_required "invalid_probe_run_id"
    RUNTIME_DIR="$(mktemp -d "${RUNTIME_PARENT%/}/algolia_migration_parity.XXXXXX")"
    PID_DIR="$RUNTIME_DIR/pids"
    INTEGRATION_DB_EFFECTIVE="fjcloud_migration_parity_${RUN_ID}"
    export INTEGRATION_DB="$INTEGRATION_DB_EFFECTIVE"
    unset INTEGRATION_DB_URL
    init_integration_env_defaults
    BASE_SOURCE_INDEX="${PROBE_PREFIX}_${RUN_ID}_source"
    BASE_TARGET_INDEX="${PROBE_PREFIX}_${RUN_ID}_target"
    SOURCE_INDEX="$BASE_SOURCE_INDEX"
    TARGET_INDEX="$BASE_TARGET_INDEX"
    NODE_KEY_WARMUP_INDEX="${PROBE_PREFIX}_${RUN_ID}_warmup"
    PROBE_EMAIL="${PROBE_PREFIX}_${RUN_ID}@example.com"
    PROBE_PASSWORD="Integration-Test-Pass-1-${RUN_ID}!"
    IDEMPOTENCY_KEY="${PROBE_PREFIX}_${RUN_ID}_create"
    export JWT_SECRET="${JWT_SECRET:-$(algolia_import_probe_generate_secret)}"
    ALGOLIA_AUTH_CONFIG="$(secure_temp_file)"
    FJCLOUD_AUTH_CONFIG="$(secure_temp_file)"
    SOURCE_HITS_FILE="$(secure_temp_file)"
    MIGRATED_HITS_FILE="$(secure_temp_file)"
    PARITY_REPORT_FILE="$(secure_temp_file)"
    write_header_config "$ALGOLIA_AUTH_CONFIG" \
        "X-Algolia-Application-Id: $ALGOLIA_APP_ID" \
        "X-Algolia-API-Key: $ALGOLIA_ADMIN_KEY"
}

algolia_url() {
    printf 'https://%s.algolia.net%s' "$(printf '%s' "$ALGOLIA_APP_ID" | tr '[:upper:]' '[:lower:]')" "$1"
}

algolia_request() {
    local expected="$1" method="$2" path="$3" data_file="${4:-}" args
    args=(--config "$ALGOLIA_AUTH_CONFIG" -X "$method")
    HTTP_REQUEST_TARGET="Algolia ${method} ${path}"
    [ -z "$data_file" ] || args+=(--data @"$data_file")
    curl_http "$expected" "${args[@]}" "$(algolia_url "$path")"
}

api_request() {
    local expected="$1" method="$2" path="$3" data_file="${4:-}" idempotency="${5:-}" args
    args=(-X "$method")
    HTTP_REQUEST_TARGET="${method} ${path}"
    HTTP_HEADERS_FILE="$(secure_temp_file)"
    args+=(-D "$HTTP_HEADERS_FILE")
    [ -z "${TENANT_TOKEN:-}" ] || args+=(--config "$FJCLOUD_AUTH_CONFIG")
    [ -z "$idempotency" ] || args+=(-H "Idempotency-Key: $idempotency")
    [ -z "$data_file" ] || args+=(-H "content-type: application/json" --data @"$data_file")
    curl_http "$expected" "${args[@]}" "${API_URL%/}${path}"
}

finish_action_required() {
    local reason="$1" failure_body="${HTTP_BODY:-}" failure_status="${HTTP_STATUS:-none}" failure_target="${HTTP_REQUEST_TARGET:-none}" body_summary
    [ "$PRESERVE_FAILURE_RUNTIME" = "1" ] && PRESERVE_LIVE_JOB_RESOURCES=1
    cleanup_resources
    HTTP_BODY="$failure_body"
    body_summary="$(http_body_summary)"
    emit "ERROR|reason=${reason}|step=${CURRENT_STEP}|target=${failure_target}|http_status=${failure_status}|body=${body_summary}"
    emit_result "ACTION_REQUIRED" "$reason"
    exit 1
}

finish_pass() {
    cleanup_resources
    if [ "$ALGOLIA_INDEX_RESIDUE" -ne 0 ] || [ "$FLAPJACK_INDEX_RESIDUE" -ne 0 ] \
        || [ "$ALGOLIA_KEY_RESIDUE" -ne 0 ] || [ "$LOCAL_STACK_RESIDUE" -ne 0 ] \
        || [ "$RUNTIME_FILE_RESIDUE" -ne 0 ] || [ "$CLEANUP_FAILED" -ne 0 ]; then
        emit_result "ACTION_REQUIRED" "residue_detected"
        exit 1
    fi
    emit_result "PASS"
}

cleanup_resources() {
    [ "$CLEANUP_DONE" -eq 0 ] || return 0
    CLEANUP_DONE=1
    set +e
    if [ "$PRESERVE_LIVE_JOB_RESOURCES" -eq 1 ]; then
        # A tracked job never reached terminal promoted success plus durable ACK
        # within the drain budget, so it may still be running against this stack.
        # Preserve every remote resource AND the local integration stack, its
        # database, and the runtime directory the worker depends on, reporting
        # what remains as residue rather than deleting a source index, restricted
        # key, or target — or killing the worker process / dropping its database —
        # out from under a still-running worker.
        refresh_remote_cleanup_residue_counts
        preserve_local_stack
    else
        delete_node_key_warmup_index || CLEANUP_FAILED=1
        delete_tracked_algolia_indexes || true
        delete_flapjack_targets || true
        delete_tracked_algolia_keys || true
        wait_for_remote_cleanup_residue_clearance || CLEANUP_FAILED=1
        teardown_local_stack
    fi
    if [ "$FLAPJACK_INDEX_RESIDUE" -ne 0 ]; then
        emit "CLEANUP_DIAGNOSTIC|flapjack_delete_statuses=${FLAPJACK_TARGET_DELETE_STATUSES:-none}|flapjack_delete_bodies=${FLAPJACK_TARGET_DELETE_BODY_SUMMARIES:-none}|flapjack_residue_statuses=${FLAPJACK_TARGET_RESIDUE_STATUSES:-none}"
    fi
    emit "CLEANUP|algolia_indexes=${ALGOLIA_INDEX_RESIDUE}|flapjack_indexes=${FLAPJACK_INDEX_RESIDUE}|algolia_keys=${ALGOLIA_KEY_RESIDUE}|local_stack=${LOCAL_STACK_RESIDUE}|runtime_files=${RUNTIME_FILE_RESIDUE}"
    set -e
}

# Leave the integration stack, its database, and the runtime directory intact so
# a still-running accepted job is not killed mid-flight; report the preserved
# local state as residue instead of tearing it down.
preserve_local_stack() {
    [ "$STACK_STARTED" -eq 1 ] && LOCAL_STACK_RESIDUE=1 || LOCAL_STACK_RESIDUE=0
    [ -n "$RUNTIME_DIR" ] && [ -e "$RUNTIME_DIR" ] && RUNTIME_FILE_RESIDUE=1 || RUNTIME_FILE_RESIDUE=0
}

# Stop the integration processes, drop the owned database, and remove the runtime
# directory, then report whatever local state remains as residue.
teardown_local_stack() {
    local database_residue=0 teardown_failed=0
    if [ "$STACK_STARTED" -eq 1 ]; then
        FJCLOUD_INTEGRATION_PID_DIR="$PID_DIR" INTEGRATION_DB="$INTEGRATION_DB_EFFECTIVE" \
            "$INTEGRATION_DOWN" >/dev/null 2>&1 || { CLEANUP_FAILED=1; teardown_failed=1; }
        database_residue="$(count_owned_database_residue)"
    fi
    if [ "$teardown_failed" -ne 0 ] || [ "$database_residue" -ne 0 ] \
        || { [ -d "$PID_DIR" ] && compgen -G "$PID_DIR/*.pid" >/dev/null; }; then
        LOCAL_STACK_RESIDUE=1
    else
        LOCAL_STACK_RESIDUE=0
    fi
    [ -z "$RUNTIME_DIR" ] || rm -rf "$RUNTIME_DIR" 2>/dev/null || CLEANUP_FAILED=1
    [ -n "$RUNTIME_DIR" ] && [ -e "$RUNTIME_DIR" ] && RUNTIME_FILE_RESIDUE=1 || RUNTIME_FILE_RESIDUE=0
}

append_unique_csv_value() {
    local list="$1" value="$2"
    [ -n "$value" ] || { printf '%s\n' "$list"; return 0; }
    case ",$list," in
        *,"$value",*) printf '%s\n' "$list" ;;
        *) printf '%s%s%s\n' "$list" "${list:+,}" "$value" ;;
    esac
}

delete_tracked_algolia_indexes() {
    local index failed=0
    for index in "${CREATED_INDEXES[@]+"${CREATED_INDEXES[@]}"}"; do
        [ -n "$index" ] || continue
        algolia_import_probe_delete_algolia_index "$index" || failed=1
    done
    return "$failed"
}

delete_tracked_algolia_keys() {
    local key failed=0
    for key in "${CREATED_KEYS[@]+"${CREATED_KEYS[@]}"}"; do
        [ -n "$key" ] || continue
        curl_http "200 204 404" --config "$ALGOLIA_AUTH_CONFIG" -X DELETE "$(algolia_url "/1/keys/$key")" >/dev/null || failed=1
    done
    return "$failed"
}

refresh_remote_cleanup_residue_counts() {
    ALGOLIA_INDEX_RESIDUE="$(count_algolia_index_residue)"
    FLAPJACK_INDEX_RESIDUE="$(count_flapjack_index_residue)"
    ALGOLIA_KEY_RESIDUE="$(count_algolia_key_residue)"
}

retry_remote_cleanup_deletes() {
    [ "$ALGOLIA_INDEX_RESIDUE" -eq 0 ] || delete_tracked_algolia_indexes >/dev/null 2>&1 || true
    [ "$FLAPJACK_INDEX_RESIDUE" -eq 0 ] || delete_flapjack_targets >/dev/null 2>&1 || true
    [ "$ALGOLIA_KEY_RESIDUE" -eq 0 ] || delete_tracked_algolia_keys >/dev/null 2>&1 || true
}

wait_for_remote_cleanup_residue_clearance() {
    local attempt=1
    while :; do
        refresh_remote_cleanup_residue_counts
        if [ "$ALGOLIA_INDEX_RESIDUE" -eq 0 ] && [ "$FLAPJACK_INDEX_RESIDUE" -eq 0 ] \
            && [ "$ALGOLIA_KEY_RESIDUE" -eq 0 ]; then
            return 0
        fi
        [ "$attempt" -ge "$CLEANUP_POLL_ATTEMPTS" ] && return 1
        retry_remote_cleanup_deletes
        attempt=$((attempt + 1))
        sleep "$CLEANUP_POLL_INTERVAL_SECONDS"
    done
}

track_flapjack_target() {
    local target="$1" existing
    [ -n "$target" ] || return 0
    for existing in "${CREATED_TARGETS[@]+"${CREATED_TARGETS[@]}"}"; do
        [ "$existing" = "$target" ] && return 0
    done
    CREATED_TARGETS+=("$target")
}

delete_flapjack_targets() {
    local target failed=0 previous_target="$TARGET_INDEX"
    for target in "${CREATED_TARGETS[@]+"${CREATED_TARGETS[@]}"}"; do
        TARGET_INDEX="$target"
        delete_flapjack_target || failed=1
    done
    TARGET_INDEX="$previous_target"
    return "$failed"
}

delete_flapjack_target() {
    [ "$STACK_STARTED" -eq 1 ] || return 0
    [ -n "${TENANT_TOKEN:-}" ] || return 0
    [ -n "${TARGET_INDEX:-}" ] || return 0
    local payload
    payload="$(secure_temp_file)" || return 1
    write_json_file "$payload" '{"confirm":true}' || return 1
    if api_request "204 404" DELETE "/indexes/$TARGET_INDEX" "$payload" "" >/dev/null; then
        FLAPJACK_TARGET_DELETE_STATUSES="${FLAPJACK_TARGET_DELETE_STATUSES}${FLAPJACK_TARGET_DELETE_STATUSES:+,}${HTTP_STATUS}"
        return 0
    fi
    FLAPJACK_TARGET_DELETE_STATUSES="${FLAPJACK_TARGET_DELETE_STATUSES}${FLAPJACK_TARGET_DELETE_STATUSES:+,}${HTTP_STATUS:-request_failed}"
    FLAPJACK_TARGET_DELETE_BODY_SUMMARIES="$(
        append_unique_csv_value "$FLAPJACK_TARGET_DELETE_BODY_SUMMARIES" "$(http_body_summary)"
    )"
    return 1
}

prime_local_node_key() {
    CURRENT_STEP="local_node_key_warmup"
    local payload
    payload="$(secure_temp_file)"
    write_json_file "$payload" "{\"name\":\"$NODE_KEY_WARMUP_INDEX\",\"region\":\"us-east-1\"}"
    api_request "201" POST "/indexes" "$payload" "" || finish_action_required "endpoint_unavailable"
    NODE_KEY_WARMUP_CREATED=1
    delete_node_key_warmup_index || finish_action_required "endpoint_unavailable"
}

delete_node_key_warmup_index() {
    [ "$NODE_KEY_WARMUP_CREATED" -eq 1 ] || return 0
    local payload
    payload="$(secure_temp_file)" || return 1
    write_json_file "$payload" '{"confirm":true}' || return 1
    api_request "204 404" DELETE "/indexes/$NODE_KEY_WARMUP_INDEX" "$payload" "" || {
        case "${HTTP_STATUS:-}" in
            204|404) ;;
            *) return 1 ;;
        esac
    }
    NODE_KEY_WARMUP_CREATED=0
}

count_algolia_index_residue() {
    [ -n "${ALGOLIA_AUTH_CONFIG:-}" ] && [ -n "${PROBE_PREFIX:-}" ] || { printf '0\n'; return 0; }
    curl_http "200" --config "$ALGOLIA_AUTH_CONFIG" -X GET "$(algolia_url "/1/indexes?page=0&hitsPerPage=100")" >/dev/null || { printf '1\n'; return 0; }
    python3 - "$HTTP_BODY" "${PROBE_PREFIX}_${RUN_ID}" <<'PY'
import json
import sys
try:
    payload = json.loads(sys.argv[1])
except json.JSONDecodeError:
    print(1)
    raise SystemExit(0)
items = payload.get("items", [])
prefix = sys.argv[2]
if not isinstance(items, list):
    print(1)
    raise SystemExit(0)
print(sum(1 for item in items if isinstance(item, dict) and isinstance(item.get("name"), str) and item["name"].startswith(prefix)))
PY
}

count_flapjack_index_residue() {
    [ "$STACK_STARTED" -eq 1 ] && [ -n "${TENANT_TOKEN:-}" ] || { printf '0\n'; return 0; }
    local payload target residue=0 previous_target="$TARGET_INDEX"
    for target in "${CREATED_TARGETS[@]+"${CREATED_TARGETS[@]}"}"; do
        [ -n "$target" ] || continue
        TARGET_INDEX="$target"
        payload="$(secure_temp_file)" || { printf '1\n'; return 0; }
        write_json_file "$payload" '{}' || { printf '1\n'; return 0; }
        api_request "200 404" POST "/indexes/$TARGET_INDEX/browse" "$payload" "" >/dev/null || {
            FLAPJACK_TARGET_RESIDUE_STATUSES="${FLAPJACK_TARGET_RESIDUE_STATUSES}${FLAPJACK_TARGET_RESIDUE_STATUSES:+,}${HTTP_STATUS:-request_failed}"
            printf '1\n'
            return 0
        }
        FLAPJACK_TARGET_RESIDUE_STATUSES="${FLAPJACK_TARGET_RESIDUE_STATUSES}${FLAPJACK_TARGET_RESIDUE_STATUSES:+,}${HTTP_STATUS}"
        [ "$HTTP_STATUS" = "404" ] || residue=$((residue + 1))
    done
    TARGET_INDEX="$previous_target"
    printf '%s\n' "$residue"
}

count_algolia_key_residue() {
    local key residue=0
    [ -n "${ALGOLIA_AUTH_CONFIG:-}" ] || { printf '0\n'; return 0; }
    for key in "${CREATED_KEYS[@]+"${CREATED_KEYS[@]}"}"; do
        curl_http "200 404" --config "$ALGOLIA_AUTH_CONFIG" -X GET "$(algolia_url "/1/keys/$key")" >/dev/null || { printf '1\n'; return 0; }
        [ "$HTTP_STATUS" = "200" ] && residue=$((residue + 1))
    done
    printf '%s\n' "$residue"
}

count_owned_database_residue() {
    [ -n "$INTEGRATION_DB_EFFECTIVE" ] || { printf '0\n'; return 0; }
    init_integration_db_access >/dev/null 2>&1 || { printf '1\n'; return 0; }
    local residue
    residue="$(run_integration_psql postgres -tAc "SELECT COUNT(*) FROM pg_database WHERE datname = '${INTEGRATION_DB_EFFECTIVE}'; /* probe:database_residue */" 2>/dev/null | tr -d '[:space:]')" \
        || { printf '1\n'; return 0; }
    case "$residue" in ''|*[!0-9]*) printf '1\n' ;; *) printf '%s\n' "$residue" ;; esac
}

db_scalar() {
    local sql="$1"
    init_integration_db_access >/dev/null 2>&1 || return 1
    run_integration_psql "$INTEGRATION_DB_EFFECTIVE" -tAc "$sql" 2>/dev/null \
        | tr -d '[:space:]'
}

job_engine_acknowledged_count() {
    db_scalar "SELECT COUNT(*) FROM algolia_import_jobs WHERE id = '${JOB_ID}' AND engine_ack_state = 'acknowledged'; /* probe:engine_ack */"
}

idempotency_source_unchanged_count() {
    db_scalar "SELECT COUNT(*) FROM algolia_import_jobs WHERE id = '${JOB_ID}' AND source_name = '${SOURCE_INDEX}' AND erased_at IS NULL; /* probe:idempotency_source_unchanged */"
}

idempotency_key_row_count() {
    db_scalar "SELECT COUNT(*) FROM algolia_import_jobs WHERE customer_id = (SELECT customer_id FROM algolia_import_jobs WHERE id = '${JOB_ID}') AND idempotency_key = '${IDEMPOTENCY_KEY}' AND erased_at IS NULL; /* probe:idempotency_key_count */"
}

idempotency_terminal_job_count() {
    db_scalar "SELECT COUNT(*) FROM algolia_import_jobs WHERE customer_id = (SELECT customer_id FROM algolia_import_jobs WHERE id = '${JOB_ID}') AND idempotency_key = '${IDEMPOTENCY_KEY}' AND status IN ('completed', 'completed_with_warnings') AND publication_disposition = 'promoted' AND engine_ack_state = 'acknowledged' AND erased_at IS NULL; /* probe:idempotency_terminal_job_count */"
}

job_reconciliation_debug() {
    db_scalar "SELECT concat_ws(',', 'ack=' || engine_ack_state, 'worker_claimed=' || (worker_claimed_at IS NOT NULL)::text, 'worker_future=' || COALESCE((worker_lease_expires_at > NOW())::text, 'null'), 'updated=' || EXTRACT(EPOCH FROM updated_at)::bigint) FROM algolia_import_jobs WHERE id = '${JOB_ID}' AND erased_at IS NULL; /* probe:reconciliation_debug */"
}

# Durable cancel intent for the current job: exactly one row must record a
# non-null cancel_requested_at, proving the cancellation was persisted once.
cancel_intent_count() {
    db_scalar "SELECT COUNT(*) FROM algolia_import_jobs WHERE id = '${JOB_ID}' AND cancel_requested_at IS NOT NULL AND erased_at IS NULL; /* probe:cancel_intent */"
}

# Exactly one phase-scoped job must be linked to the engine (non-null
# engine_job_id). Emits a count, never the engine identifier itself.
cancel_phase_engine_linked_count() {
    db_scalar "SELECT COUNT(*) FROM algolia_import_jobs WHERE customer_id = (SELECT customer_id FROM algolia_import_jobs WHERE id = '${JOB_ID}') AND idempotency_key = '${IDEMPOTENCY_KEY}' AND engine_job_id IS NOT NULL AND erased_at IS NULL; /* probe:cancel_engine_link */"
}

# Lifecycle-generation fingerprint of the current job, used to prove a refused
# resume mutated no lifecycle generation or checkpoint. Emits a compact scalar.
resume_lifecycle_generation() {
    db_scalar "SELECT concat_ws(',', 'gen=' || COALESCE(lifecycle_generation::text, 'null'), 'resume_intent=' || resume_intent_generation, 'resume_count=' || resume_count, 'checkpoint_hash=' || COALESCE(md5(resume_checkpoint), 'null')) FROM algolia_import_jobs WHERE id = '${JOB_ID}' AND erased_at IS NULL; /* probe:resume_lifecycle_generation */"
}

# Exactly one phase-scoped job must exist for the resume specimen; a refused
# resume must not fork a second job row.
resume_phase_job_count() {
    db_scalar "SELECT COUNT(*) FROM algolia_import_jobs WHERE customer_id = (SELECT customer_id FROM algolia_import_jobs WHERE id = '${JOB_ID}') AND idempotency_key = '${IDEMPOTENCY_KEY}' AND erased_at IS NULL; /* probe:resume_phase_job_count */"
}

start_stack() {
    CURRENT_STEP="integration_start"
    mkdir -p "$PID_DIR"
    STACK_STARTED=1
    FJCLOUD_INTEGRATION_PID_DIR="$PID_DIR" INTEGRATION_DB="$INTEGRATION_DB_EFFECTIVE" \
        FJCLOUD_ALGOLIA_MIGRATION_ENABLED=true FJCLOUD_INTEGRATION_SKIP_METERING_AGENT=1 \
        ENVIRONMENT=local SKIP_EMAIL_VERIFICATION=1 "$INTEGRATION_UP" >/dev/null \
        || finish_action_required "endpoint_unavailable"
}

require_health() {
    CURRENT_STEP="health"
    curl_http "200" -X GET "${API_URL%/}/health" || finish_action_required "endpoint_unavailable"
    curl_http "200" -X GET "${ENGINE_URL%/}/health" || finish_action_required "endpoint_unavailable"
}

register_and_login() {
    CURRENT_STEP="tenant_auth"
    local payload
    payload="$(secure_temp_file)"
    write_json_file "$payload" "{\"name\":\"Algolia Migration Parity Probe\",\"email\":\"$PROBE_EMAIL\",\"password\":\"$PROBE_PASSWORD\"}"
    api_request "201" POST "/auth/register" "$payload" "" || finish_action_required "endpoint_unavailable"
    api_request "200" POST "/auth/login" "$payload" "" || finish_action_required "endpoint_unavailable"
    TENANT_TOKEN="$(json_field "$HTTP_BODY" token 2>/dev/null || true)"
    [ -n "$TENANT_TOKEN" ] || finish_action_required "inconclusive_evidence"
    safe_header_value "$TENANT_TOKEN" || finish_action_required "invalid_response_identifier"
    write_header_config "$FJCLOUD_AUTH_CONFIG" "authorization: Bearer $TENANT_TOKEN"
}

require_migration_availability() {
    CURRENT_STEP="migration_availability"
    api_request "200" GET "/migration/algolia/availability" "" "" || finish_action_required "endpoint_unavailable"
    python3 - "$HTTP_BODY" <<'PY' || finish_action_required "w1_availability_unavailable"
import json
import sys
payload = json.loads(sys.argv[1])
caps = payload.get("capabilities")
if not isinstance(caps, dict):
    raise SystemExit(1)
if payload.get("available") is not True or caps.get("cancel") is not True or caps.get("resume") is not False:
    raise SystemExit(1)
PY
    AVAILABILITY_REPLACE="$(json_field "$HTTP_BODY" capabilities.replace 2>/dev/null || true)"
}

# Phase-scoped precondition: replace-mode reruns must never seed or mutate live
# Algolia state unless the active W1 availability surface advertises the replace
# capability. Fails closed before any Algolia call for overwrite_rerun.
require_replace_capability() {
    CURRENT_STEP="replace_availability"
    [ "${AVAILABILITY_REPLACE:-}" = "true" ] || finish_action_required "replace_unavailable"
}

# resume_refused proves the enabled advertisement is exactly
# available=true/cancel=true/replace=true/resume=false — resume must stay off
# even while the other lifecycle capabilities are on.
require_enabled_availability_exact() {
    CURRENT_STEP="enabled_availability_exact"
    api_request "200" GET "/migration/algolia/availability" "" "" || finish_action_required "endpoint_unavailable"
    python3 - "$HTTP_BODY" <<'PY' || finish_action_required "w1_availability_unavailable"
import json
import sys
payload = json.loads(sys.argv[1])
caps = payload.get("capabilities")
if not isinstance(caps, dict):
    raise SystemExit(1)
if (
    payload.get("available") is not True
    or caps.get("cancel") is not True
    or caps.get("replace") is not True
    or caps.get("resume") is not False
):
    raise SystemExit(1)
PY
    emit_phase "resume_refused_availability" "available=true,cancel=true,replace=true,resume=false" "available=true,cancel=true,replace=true,resume=false" "true"
}

# Customer-visible document count for a migration target. A cancelled create
# never publishes, so the target is either absent (exact 404 browse) or an empty
# successful browse; both normalize to 0. Any positive hit count is the real
# observed count and will fail the phase.
customer_visible_target_count() {
    CURRENT_STEP="customer_visible_browse"
    local target="$1" payload count
    CUSTOMER_VISIBLE_TARGET_COUNT=""
    payload="$(secure_temp_file)"
    write_json_file "$payload" '{"hitsPerPage":1000}'
    api_request "200 404" POST "/indexes/$target/browse" "$payload" "" || return 1
    if [ "$HTTP_STATUS" = "404" ]; then
        CUSTOMER_VISIBLE_TARGET_COUNT="0"
        return 0
    fi
    count="$(python3 - "$HTTP_BODY" <<'PY'
import json
import sys
try:
    payload = json.loads(sys.argv[1])
except json.JSONDecodeError:
    raise SystemExit(1)
hits = payload.get("hits")
if not isinstance(hits, list):
    raise SystemExit(1)
print(len(hits))
PY
)" || return 1
    case "$count" in
        ''|*[!0-9]*) return 1 ;;
        *) CUSTOMER_VISIBLE_TARGET_COUNT="$count" ;;
    esac
}

seed_source_index() {
    CURRENT_STEP="seed_source"
    local source_index="${1:-$SOURCE_INDEX}" fixture_file="${2:-$FIXTURE_FILE}"
    local payload task_id
    algolia_request "404" GET "/1/indexes/$source_index" || finish_action_required "residue_detected"
    payload="$(secure_temp_file)"
    python3 - "$fixture_file" "$payload" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    docs = json.load(handle)
requests = [{"action": "addObject", "body": doc} for doc in docs]
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump({"requests": requests}, handle, separators=(",", ":"))
PY
    algolia_request "200 201" POST "/1/indexes/$source_index/batch" "$payload" || finish_action_required "endpoint_unavailable"
    CREATED_INDEXES+=("$source_index")
    task_id="$(json_field "$HTTP_BODY" taskID 2>/dev/null || true)"
    if [ -n "$task_id" ]; then
        safe_response_identifier "$task_id" || finish_action_required "invalid_response_identifier"
        algolia_import_probe_wait_for_algolia_task "$source_index" "$task_id" || finish_action_required "inconclusive_evidence"
    fi
}

create_restricted_key() {
    CURRENT_STEP="source_key"
    local payload indexes_json index
    [ "$#" -gt 0 ] || set -- "$SOURCE_INDEX"
    payload="$(secure_temp_file)"
    indexes_json="$(python3 - "$@" <<'PY'
import json
import sys
print(json.dumps(sys.argv[1:], separators=(",", ":")))
PY
)"
    write_json_file "$payload" "{\"acl\":[\"search\",\"browse\",\"settings\",\"listIndexes\"],\"indexes\":$indexes_json,\"description\":\"$PROBE_PREFIX-$RUN_ID\"}"
    algolia_request "200 201" POST "/1/keys" "$payload" || finish_action_required "endpoint_unavailable"
    DISPOSABLE_KEY="$(json_field "$HTTP_BODY" key 2>/dev/null || true)"
    [ -n "$DISPOSABLE_KEY" ] || finish_action_required "inconclusive_evidence"
    safe_response_identifier "$DISPOSABLE_KEY" || finish_action_required "invalid_response_identifier"
    CREATED_KEYS+=("$DISPOSABLE_KEY")
    for index in "$@"; do
        algolia_import_probe_wait_for_restricted_source_key "$index" "$DISPOSABLE_KEY" || finish_action_required "inconclusive_evidence"
    done
}

obtain_target_envelope() {
    CURRENT_STEP="destination_eligibility"
    algolia_import_probe_obtain_target_envelope "$TARGET_INDEX"
}

obtain_replace_target_envelope() {
    CURRENT_STEP="destination_eligibility_replace"
    local payload
    payload="$(secure_temp_file)"
    write_json_file "$payload" \
        "{\"phase\":\"target\",\"mode\":\"replace\",\"target\":{\"region\":\"us-east-1\",\"name\":\"$TARGET_INDEX\"}}"
    api_request "200" POST "/migration/algolia/destination-eligibility" "$payload" \
        || finish_action_required "endpoint_unavailable"
    TARGET_TOKEN="$(
        json_field "$HTTP_BODY" eligibilityToken 2>/dev/null || true
    )"
    [ -n "$TARGET_TOKEN" ] || finish_action_required "inconclusive_evidence"
    safe_opaque_token "$TARGET_TOKEN" || finish_action_required "invalid_response_identifier"
}

dispatch_job() {
    local mode="${1:-create}" source_index="${2:-$SOURCE_INDEX}" idempotency="${3:-$IDEMPOTENCY_KEY}"
    CURRENT_STEP="dispatch_${mode}"
    local payload
    payload="$(secure_temp_file)"
    write_json_file "$payload" "{\"mode\":\"$mode\",\"appId\":\"$ALGOLIA_APP_ID\",\"apiKey\":\"$DISPOSABLE_KEY\",\"sourceName\":\"$source_index\",\"target\":{\"eligibilityToken\":\"$TARGET_TOKEN\"}}"
    api_request "202" POST "/migration/algolia/jobs" "$payload" "$idempotency" || finish_action_required "inconclusive_evidence"
    JOB_ID="$(json_field "$HTTP_BODY" id 2>/dev/null || true)"
    JOB_LOCATION="$(sed -n 's/^[Ll]ocation:[[:space:]]*//p' "$HTTP_HEADERS_FILE" | tr -d '\r' | tail -1)"
    # The engine already accepted this job (HTTP 202). If the body id is missing,
    # unsafe, or disagrees with the canonical Location, drain the header-named job
    # to terminal ACK before cleanup rather than orphaning a live migration.
    [ -n "$JOB_ID" ] || finish_accepted_job_action_required "inconclusive_evidence"
    safe_response_identifier "$JOB_ID" || finish_accepted_job_action_required "invalid_response_identifier"
    [ "$JOB_LOCATION" = "/migration/algolia/jobs/$JOB_ID" ] || finish_accepted_job_action_required "inconclusive_evidence"
    track_accepted_job "$JOB_ID"
}

# Shared bounded terminal poll for any accepted job. The expected terminal kind
# is carried per job in ACCEPTED_JOB_TERMINAL_KIND (default promoted_success), so
# the one canonical drain and each phase poll the same way while asserting the
# terminal tuple that phase requires (promoted_success or cancelled_unchanged).
poll_job_to_terminal() {
    # on_failure lets a phase route non-terminal outcomes through the accepted-job
    # drain (finish_accepted_job_action_required) instead of racing cleanup.
    local on_failure="${1:-finish_action_required}"
    local kind="${ACCEPTED_JOB_TERMINAL_KIND[$JOB_ID]:-promoted_success}"
    CURRENT_STEP="terminal_poll"
    local elapsed=0 status disposition resumable
    while :; do
        api_request "200" GET "/migration/algolia/jobs/$JOB_ID" "" "" || "$on_failure" "inconclusive_evidence"
        status="$(json_field "$HTTP_BODY" status 2>/dev/null || true)"
        disposition="$(json_field "$HTTP_BODY" publicationDisposition 2>/dev/null || true)"
        resumable="$(json_field "$HTTP_BODY" resumable 2>/dev/null || true)"
        is_terminal_for_kind "$kind" "$status" "$disposition" "$resumable" && return 0
        is_transient_for_kind "$kind" "$status" || "$on_failure" "inconclusive_evidence"
        [ "$elapsed" -lt "$POLL_SECONDS" ] || "$on_failure" "inconclusive_evidence"
        sleep "$POLL_INTERVAL_SECONDS"
        elapsed=$((elapsed + POLL_INTERVAL_SECONDS))
    done
}

is_terminal_for_kind() {
    local kind="$1" status="$2" disposition="$3" resumable="$4"
    case "$kind" in
        cancelled_unchanged) is_cancelled_terminal "$status" "$disposition" "$resumable" ;;
        *) is_promoted_terminal_success "$status" "$disposition" "$resumable" ;;
    esac
}

# A running job may pass through extra transient states before its expected
# terminal; cancellation additionally passes through `cancelling`.
is_transient_for_kind() {
    local kind="$1" status="$2"
    case "$status" in
        queued|validating_source|copying_configuration|copying_documents|verifying|promoting|resuming) return 0 ;;
        cancelling) [ "$kind" = "cancelled_unchanged" ] && return 0 || return 1 ;;
        *) return 1 ;;
    esac
}

is_promoted_terminal_success() {
    local status="$1" disposition="$2" resumable="$3"
    [ "$disposition" = "promoted" ] && [ "$resumable" = "false" ] || return 1
    case "$status" in
        completed|completed_with_warnings) return 0 ;;
        *) return 1 ;;
    esac
}

# A cancelled create-into-fresh must publish nothing: canonical terminal tuple is
# status=cancelled, publicationDisposition=unchanged, resumable=false.
is_cancelled_terminal() {
    local status="$1" disposition="$2" resumable="$3"
    [ "$status" = "cancelled" ] && [ "$disposition" = "unchanged" ] && [ "$resumable" = "false" ]
}

# True while the public job status is a non-terminal running state. Used to prove
# cancellation is requested against a still-live job, never one that already
# reached a terminal disposition.
is_nonterminal_status() {
    case "$1" in
        queued|validating_source|copying_configuration|copying_documents|verifying|promoting|resuming|cancelling) return 0 ;;
        *) return 1 ;;
    esac
}

browse_collection_to_file() {
    local owner="$1" index="$2" output="$3" cursor="" page payload
    : > "$output"
    printf '[]' > "$output"
    while :; do
        page="$(secure_temp_file)"
        payload="$(secure_temp_file)"
        if [ -n "$cursor" ]; then
            write_json_file "$payload" "{\"cursor\":\"$cursor\",\"hitsPerPage\":1000}"
        else
            write_json_file "$payload" '{"hitsPerPage":1000}'
        fi
        if [ "$owner" = "algolia" ]; then
            algolia_request "200" POST "/1/indexes/$index/browse" "$payload" || finish_action_required "inconclusive_evidence"
        else
            api_request "200" POST "/indexes/$index/browse" "$payload" "" || finish_action_required "inconclusive_evidence"
        fi
        printf '%s' "$HTTP_BODY" > "$page"
        cursor="$(python3 - "$output" "$page" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    all_hits = json.load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    page = json.load(handle)
hits = page.get("hits")
if not isinstance(hits, list):
    raise SystemExit(2)
all_hits.extend(hits)
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(all_hits, handle, separators=(",", ":"))
cursor = page.get("cursor")
if isinstance(cursor, str) and cursor:
    print(cursor)
PY
)" || finish_action_required "inconclusive_evidence"
        [ -n "$cursor" ] || break
    done
}

emit_parity_diff_summary() {
    python3 - "$PARITY_REPORT_FILE" <<'PY' || finish_action_required "inconclusive_evidence"
import json
import re
import sys

SAFE_TOKEN = re.compile(r"[^A-Za-z0-9_.:-]+")

def safe_token(value):
    return SAFE_TOKEN.sub("_", str(value))[:160] or "unknown"

with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)

field_parts = []
for mismatch in report.get("field_mismatches", []):
    if not isinstance(mismatch, dict):
        continue
    object_id = safe_token(mismatch.get("objectID", "unknown"))
    source = mismatch.get("source")
    migrated = mismatch.get("migrated")
    if not isinstance(source, dict) or not isinstance(migrated, dict):
        field_parts.append(f"{object_id}:unknown")
        continue
    fields = [
        safe_token(field)
        for field in sorted(set(source) | set(migrated))
        if source.get(field) != migrated.get(field)
    ]
    field_parts.append(f"{object_id}:{','.join(fields) if fields else 'unknown'}")

print(
    "PARITY_DIFF|field_mismatches={field_mismatches}|only_in_source={only_in_source}|only_in_migrated={only_in_migrated}".format(
        field_mismatches=";".join(field_parts) if field_parts else "none",
        only_in_source=len(report.get("only_in_source", [])),
        only_in_migrated=len(report.get("only_in_migrated", [])),
    )
)
PY
}

source "$SCRIPT_DIR/lib/algolia_migration_parity_phase_helpers.sh"

main() {
    parse_args "$@"
    validate_phase_set
    run_static_w1_gate
    load_algolia_secrets
    prepare_runtime
    trap 'cleanup_resources >/dev/null 2>&1 || true' EXIT
    run_requested_phases
    finish_pass
}

main "$@"
