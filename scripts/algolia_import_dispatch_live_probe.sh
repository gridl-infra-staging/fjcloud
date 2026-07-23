#!/usr/bin/env bash
# Live acceptance probe for Algolia import dispatch continuation behavior.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=scripts/lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=scripts/lib/flapjack_binary.sh
source "$SCRIPT_DIR/lib/flapjack_binary.sh"
# shellcheck source=scripts/lib/integration_db_access.sh
source "$SCRIPT_DIR/lib/integration_db_access.sh"
# shellcheck source=scripts/lib/integration_stack_env.sh
source "$SCRIPT_DIR/lib/integration_stack_env.sh"

ALLOWED_PHASES="dispatch,cancel,lease_retention,restart_reconciliation"
REQUESTED_PHASES="$ALLOWED_PHASES"
SECRET_FILE="${FJCLOUD_SECRET_FILE:-}"
ALGOLIA_APP_ID=""
ALGOLIA_ADMIN_KEY=""
ALGOLIA_IMPORT_DISPATCH_RUN_ID="${ALGOLIA_IMPORT_DISPATCH_RUN_ID:-$(date -u +%Y%m%d%H%M%S)_$$}"
PROBE_PREFIX="${ALGOLIA_IMPORT_DISPATCH_PREFIX:-fjcloud_import_dispatch_probe}"
RUNTIME_PARENT="${ALGOLIA_IMPORT_DISPATCH_RUNTIME_PARENT:-${TMPDIR:-/tmp}}"
RUNTIME_DIR=""
PID_DIR=""
INTEGRATION_DB_EFFECTIVE=""
API_PORT="${API_PORT:-3099}"
FLAPJACK_PORT="${FLAPJACK_PORT:-7799}"
API_URL="${ALGOLIA_IMPORT_DISPATCH_API_URL:-http://127.0.0.1:${API_PORT}}"
ENGINE_URL="${ALGOLIA_IMPORT_DISPATCH_ENGINE_URL:-http://127.0.0.1:${FLAPJACK_PORT}}"
INTEGRATION_UP="${ALGOLIA_IMPORT_DISPATCH_INTEGRATION_UP:-$SCRIPT_DIR/integration-up.sh}"
INTEGRATION_DOWN="${ALGOLIA_IMPORT_DISPATCH_INTEGRATION_DOWN:-$SCRIPT_DIR/integration-down.sh}"
ENGINE_CONTRACT_CHECK="${ALGOLIA_IMPORT_DISPATCH_ENGINE_CONTRACT_CHECK:-$SCRIPT_DIR/update_algolia_migration_engine_contract.sh}"
# Seconds to let a reconciliation loop turnover run after inducing claim expiry.
# The API loop runs every 30s; the live default gives one full interval plus
# margin. Contract tests fake sleep and may override this to zero when needed.
LEASE_SETTLE_SECONDS="${ALGOLIA_IMPORT_DISPATCH_SETTLE_SECONDS:-70}"
PROBE_EMAIL=""
PROBE_PASSWORD=""
SOURCE_INDEX=""
TARGET_INDEX=""
NODE_KEY_WARMUP_INDEX=""
IDEMPOTENCY_KEY=""
ALGOLIA_AUTH_CONFIG=""
FJCLOUD_AUTH_CONFIG=""
FLAPJACK_AUTH_CONFIG=""
HTTP_BODY=""
HTTP_STATUS=""
HTTP_HEADERS_FILE=""
HTTP_REQUEST_TARGET=""
TENANT_TOKEN=""
PROVIDER_TOKEN=""
TARGET_TOKEN=""
JOB_ID=""
JOB_LOCATION=""
DISPOSABLE_KEY=""
SECRET_CANARY=""
PROBE_FLAPJACK_ADMIN_KEY=""
NODE_KEY_WARMUP_CREATED=0
STACK_STARTED=0
CLEANUP_DONE=0
CLEANUP_FAILED=0
CURRENT_STEP="startup"
CREATED_INDEXES=()
CREATED_KEYS=()
ALGOLIA_INDEX_RESIDUE=0
ALGOLIA_KEY_RESIDUE=0
LOCAL_STACK_RESIDUE=0
RUNTIME_FILE_RESIDUE=0

usage() {
    cat >&2 <<'USAGE'
Usage: algolia_import_dispatch_live_probe.sh --phases dispatch,cancel,lease_retention,restart_reconciliation
USAGE
}

sanitize() {
    local value="$1"
    if [ -n "${ALGOLIA_ADMIN_KEY:-}" ]; then
        value="${value//${ALGOLIA_ADMIN_KEY}/[REDACTED]}"
    fi
    if [ -n "${DISPOSABLE_KEY:-}" ]; then
        value="${value//${DISPOSABLE_KEY}/[REDACTED]}"
    fi
    if [ -n "${PROBE_FLAPJACK_ADMIN_KEY:-}" ]; then
        value="${value//${PROBE_FLAPJACK_ADMIN_KEY}/[REDACTED]}"
    fi
    if [ -n "${TENANT_TOKEN:-}" ]; then
        value="${value//${TENANT_TOKEN}/[REDACTED]}"
    fi
    printf '%s\n' "$value"
}

emit() {
    sanitize "$*"
}

emit_phase() {
    local phase="$1" expected="$2" observed="$3" passed="$4"
    emit "PHASE|name=${phase}|expected=${expected}|observed=${observed}|pass=${passed}"
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
    local path
    path="$(mktemp "$RUNTIME_DIR/file.XXXXXX")"
    chmod 600 "$path"
    printf '%s\n' "$path"
}

curl_config_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

write_header_config() {
    local path="$1"
    shift
    : > "$path"
    while [ "$#" -gt 0 ]; do
        printf 'header = "%s"\n' "$(curl_config_escape "$1")" >> "$path"
        shift
    done
}

write_url_config() {
    local path="$1"
    local url="$2"
    printf 'url = "%s"\n' "$(curl_config_escape "$url")" > "$path"
}

generate_probe_secret() {
    python3 - <<'PY'
import secrets

print(secrets.token_urlsafe(32))
PY
}

capture_http_response() {
    local response="$1"
    HTTP_STATUS="${response##*$'\n'}"
    HTTP_BODY="${response%$'\n'*}"
    if [ "$HTTP_STATUS" = "$response" ]; then
        HTTP_BODY=""
    fi
}

curl_http() {
    local expected_statuses="$1"
    shift
    local response status

    response="$(curl -sS --connect-timeout 2 --max-time 20 -w "\n%{http_code}" "$@" || true)"
    capture_http_response "$response"
    for status in $expected_statuses; do
        [ "$HTTP_STATUS" = "$status" ] && return 0
    done
    return 1
}

json_field() {
    local payload="$1"
    local field="$2"
    python3 - "$payload" "$field" <<'PY'
import json
import sys

payload = sys.argv[1]
field = sys.argv[2]
try:
    data = json.loads(payload)
except json.JSONDecodeError:
    raise SystemExit(1)
value = data
for part in field.split("."):
    if not isinstance(value, dict) or part not in value:
        raise SystemExit(1)
    value = value[part]
if value is None:
    print("")
elif isinstance(value, bool):
    print(str(value).lower())
else:
    print(value)
PY
}

write_json_file() {
    local path="$1"
    local payload="$2"
    python3 - "$path" "$payload" <<'PY'
import json
import sys

payload = json.loads(sys.argv[2])
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, separators=(",", ":"))
PY
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --phases)
                [ "${2:-}" != "" ] || {
                    REQUESTED_PHASES=""
                    shift 2
                    continue
                }
                REQUESTED_PHASES="$2"
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

phase_requested() {
    local phase="$1"
    case ",$REQUESTED_PHASES," in
        *",$phase,"*) return 0 ;;
        *) return 1 ;;
    esac
}

validate_phase_set() {
    local IFS=',' phase
    [ -n "$REQUESTED_PHASES" ] || finish_action_required "invalid_phases"
    for phase in $REQUESTED_PHASES; do
        case "$phase" in
            dispatch|cancel|lease_retention|restart_reconciliation) ;;
            *) finish_action_required "invalid_phases" ;;
        esac
    done
}

# Values returned by remote HTTP services are reused in URL paths and, for the
# retained job/key evidence, SQL literals. Keep that boundary deliberately
# narrower than the external APIs so response data can never become syntax.
safe_response_identifier() {
    local value="$1"
    [ "${#value}" -le 256 ] && [[ "$value" =~ ^[A-Za-z0-9_-]+$ ]]
}

safe_header_value() {
    local value="$1"
    [ -n "$value" ] && [ "${#value}" -le 4096 ] \
        && [[ "$value" != *$'\r'* ]] && [[ "$value" != *$'\n'* ]]
}

safe_opaque_token() {
    local value="$1"
    safe_header_value "$value" && [[ "$value" != *\"* ]] \
        && [[ "$value" != *\\* ]]
}

load_algolia_secrets() {
    local line line_number=0 parse_status
    [ -n "$SECRET_FILE" ] || finish_action_required "missing_credentials"
    [ -f "$SECRET_FILE" ] || finish_action_required "missing_credentials"
    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))
        parse_env_assignment_line "$line" && parse_status=0 || parse_status=$?
        case "$parse_status" in
            0)
                case "$ENV_ASSIGNMENT_KEY" in
                    ALGOLIA_APP_ID) ALGOLIA_APP_ID="$ENV_ASSIGNMENT_VALUE" ;;
                    ALGOLIA_ADMIN_KEY) ALGOLIA_ADMIN_KEY="$ENV_ASSIGNMENT_VALUE" ;;
                esac
                ;;
            2) ;;
            *) emit "ERROR|reason=unsupported_secret_syntax|line=${line_number}"; finish_action_required "missing_credentials" ;;
        esac
    done < "$SECRET_FILE"
    [ -n "$ALGOLIA_APP_ID" ] || finish_action_required "missing_credentials"
    [ -n "$ALGOLIA_ADMIN_KEY" ] || finish_action_required "missing_credentials"
    [ "${#ALGOLIA_APP_ID}" -le 128 ] && [[ "$ALGOLIA_APP_ID" =~ ^[A-Za-z0-9-]+$ ]] \
        || finish_action_required "invalid_response_identifier"
    safe_header_value "$ALGOLIA_ADMIN_KEY" \
        || finish_action_required "invalid_response_identifier"
}

validate_flapjack_dev_dir() {
    [ -n "${FLAPJACK_DEV_DIR:-}" ] || finish_action_required "flapjack_dev_dir_unavailable"
    [ -d "$FLAPJACK_DEV_DIR" ] || finish_action_required "flapjack_dev_dir_unavailable"
    flapjack_source_root "$FLAPJACK_DEV_DIR" >/dev/null 2>&1 \
        || finish_action_required "flapjack_dev_dir_unavailable"
    [ -x "$ENGINE_CONTRACT_CHECK" ] \
        || finish_action_required "flapjack_dev_dir_mismatch"
    FLAPJACK_DEV_DIR="$FLAPJACK_DEV_DIR" "$ENGINE_CONTRACT_CHECK" --check >/dev/null 2>&1 \
        || finish_action_required "flapjack_dev_dir_mismatch"
}

algolia_url() {
    local path="$1"
    printf 'https://%s.algolia.net%s' "$(printf '%s' "$ALGOLIA_APP_ID" | tr '[:upper:]' '[:lower:]')" "$path"
}

algolia_request() {
    local expected="$1"
    local method="$2"
    local path="$3"
    local data_file="${4:-}"
    local args=(--config "$ALGOLIA_AUTH_CONFIG" -X "$method")
    HTTP_REQUEST_TARGET="Algolia ${method} ${path}"
    if [ -n "$data_file" ]; then
        args+=(--data @"$data_file")
    fi
    curl_http "$expected" "${args[@]}" "$(algolia_url "$path")"
}

api_request() {
    local expected="$1"
    local method="$2"
    local path="$3"
    local data_file="${4:-}"
    local idempotency="${5:-}"
    local args=(-X "$method")
    HTTP_REQUEST_TARGET="${method} ${path}"
    HTTP_HEADERS_FILE="$(secure_temp_file)"
    args+=(-D "$HTTP_HEADERS_FILE")
    if [ -n "$TENANT_TOKEN" ]; then
        args+=(--config "$FJCLOUD_AUTH_CONFIG")
    fi
    if [ -n "$idempotency" ]; then
        args+=(-H "Idempotency-Key: $idempotency")
    fi
    if [ -n "$data_file" ]; then
        args+=(-H "content-type: application/json" --data @"$data_file")
    fi
    curl_http "$expected" "${args[@]}" "${API_URL%/}${path}"
}

wait_for_algolia_task() {
    local index="$1"
    local task_id="$2"
    local status
    for _ in 1 2 3 4 5; do
        algolia_request "200 404" GET "/1/indexes/$index/task/$task_id" || return 1
        [ "$HTTP_STATUS" = "404" ] && return 0
        status="$(json_field "$HTTP_BODY" status 2>/dev/null || true)"
        [ "$status" = "published" ] && return 0
        sleep 1
    done
    return 1
}

prepare_runtime() {
    [[ "$PROBE_PREFIX" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || finish_action_required "invalid_probe_prefix"
    [[ "$ALGOLIA_IMPORT_DISPATCH_RUN_ID" =~ ^[A-Za-z0-9_]+$ ]] || finish_action_required "invalid_probe_run_id"
    RUNTIME_DIR="$(mktemp -d "${RUNTIME_PARENT%/}/algolia_import_dispatch.XXXXXX")"
    PID_DIR="$RUNTIME_DIR/pids"
    INTEGRATION_DB_EFFECTIVE="fjcloud_import_dispatch_${ALGOLIA_IMPORT_DISPATCH_RUN_ID}"
    export INTEGRATION_DB="$INTEGRATION_DB_EFFECTIVE"
    unset INTEGRATION_DB_URL
    init_integration_env_defaults
    SOURCE_INDEX="${PROBE_PREFIX}_${ALGOLIA_IMPORT_DISPATCH_RUN_ID}_source"
    TARGET_INDEX="${PROBE_PREFIX}_${ALGOLIA_IMPORT_DISPATCH_RUN_ID}_target"
    NODE_KEY_WARMUP_INDEX="${PROBE_PREFIX}_${ALGOLIA_IMPORT_DISPATCH_RUN_ID}_warmup"
    PROBE_EMAIL="${PROBE_PREFIX}_${ALGOLIA_IMPORT_DISPATCH_RUN_ID}@example.com"
    PROBE_PASSWORD="Integration-Test-Pass-1-${ALGOLIA_IMPORT_DISPATCH_RUN_ID}!"
    IDEMPOTENCY_KEY="${PROBE_PREFIX}_${ALGOLIA_IMPORT_DISPATCH_RUN_ID}_dispatch"
    SECRET_CANARY="${PROBE_PREFIX}_${ALGOLIA_IMPORT_DISPATCH_RUN_ID}_canary"
    PROBE_FLAPJACK_ADMIN_KEY="$(generate_probe_secret)"
    export JWT_SECRET="${JWT_SECRET:-$(generate_probe_secret)}"
    ALGOLIA_AUTH_CONFIG="$(secure_temp_file)"
    FJCLOUD_AUTH_CONFIG="$(secure_temp_file)"
    FLAPJACK_AUTH_CONFIG="$(secure_temp_file)"
    write_header_config "$ALGOLIA_AUTH_CONFIG" \
        "X-Algolia-Application-Id: $ALGOLIA_APP_ID" \
        "X-Algolia-API-Key: $ALGOLIA_ADMIN_KEY"
    write_header_config "$FLAPJACK_AUTH_CONFIG" \
        "X-Algolia-Application-Id: flapjack" \
        "X-Algolia-API-Key: $PROBE_FLAPJACK_ADMIN_KEY"
}

finish_action_required() {
    local reason="$1"
    local body_summary failure_body failure_status failure_target
    failure_body="${HTTP_BODY:-}"
    failure_status="${HTTP_STATUS:-none}"
    failure_target="${HTTP_REQUEST_TARGET:-none}"
    cleanup_resources
    HTTP_BODY="$failure_body"
    body_summary="$(http_body_summary)"
    emit "ERROR|reason=${reason}|step=${CURRENT_STEP}|target=${failure_target}|http_status=${failure_status}|body=${body_summary}"
    emit_result "ACTION_REQUIRED" "$reason"
    exit 1
}

finish_pass() {
    cleanup_resources
    if [ "$ALGOLIA_INDEX_RESIDUE" -ne 0 ] || [ "$ALGOLIA_KEY_RESIDUE" -ne 0 ] \
        || [ "$LOCAL_STACK_RESIDUE" -ne 0 ] || [ "$RUNTIME_FILE_RESIDUE" -ne 0 ] \
        || [ "$CLEANUP_FAILED" -ne 0 ]; then
        emit_result "ACTION_REQUIRED" "residue_detected"
        exit 1
    fi
    emit_result "PASS"
}

cleanup_resources() {
    [ "$CLEANUP_DONE" -eq 0 ] || return 0
    CLEANUP_DONE=1
    set +e

    # Expand with the set -u-safe array form so cleanup on an early exit (before
    # any Algolia resources are tracked) does not trip "unbound variable".
    local key index database_residue=0 teardown_failed=0
    delete_node_key_warmup_index || CLEANUP_FAILED=1
    for key in "${CREATED_KEYS[@]+"${CREATED_KEYS[@]}"}"; do
        [ -n "$key" ] || continue
        curl_http "200 204 404" --config "$ALGOLIA_AUTH_CONFIG" -X DELETE "$(algolia_url "/1/keys/$key")" >/dev/null \
            || CLEANUP_FAILED=1
    done
    for index in "${CREATED_INDEXES[@]+"${CREATED_INDEXES[@]}"}"; do
        [ -n "$index" ] || continue
        delete_algolia_index "$index" || CLEANUP_FAILED=1
    done

    ALGOLIA_INDEX_RESIDUE="$(count_algolia_index_residue)"
    ALGOLIA_KEY_RESIDUE="$(count_algolia_key_residue)"
    if [ "$STACK_STARTED" -eq 1 ]; then
        FJCLOUD_INTEGRATION_PID_DIR="$PID_DIR" \
            INTEGRATION_DB="$INTEGRATION_DB_EFFECTIVE" \
            "$INTEGRATION_DOWN" >/dev/null 2>&1 || {
                CLEANUP_FAILED=1
                teardown_failed=1
            }
        database_residue="$(count_owned_database_residue)"
    fi
    if [ "$teardown_failed" -ne 0 ] || [ "$database_residue" -ne 0 ] \
        || { [ -d "$PID_DIR" ] && compgen -G "$PID_DIR/*.pid" >/dev/null; }; then
        LOCAL_STACK_RESIDUE=1
    else
        LOCAL_STACK_RESIDUE=0
    fi
    rm -rf "$RUNTIME_DIR" 2>/dev/null || CLEANUP_FAILED=1
    if [ -n "$RUNTIME_DIR" ] && [ -e "$RUNTIME_DIR" ]; then
        RUNTIME_FILE_RESIDUE=1
    else
        RUNTIME_FILE_RESIDUE=0
    fi
    emit "CLEANUP|algolia_indexes=${ALGOLIA_INDEX_RESIDUE}|algolia_keys=${ALGOLIA_KEY_RESIDUE}|local_stack=${LOCAL_STACK_RESIDUE}|runtime_files=${RUNTIME_FILE_RESIDUE}"
    set -e
}

count_owned_database_residue() {
    local residue
    [ -n "$INTEGRATION_DB_EFFECTIVE" ] || {
        printf '0\n'
        return 0
    }
    init_integration_db_access >/dev/null 2>&1 || {
        printf '1\n'
        return 0
    }
    residue="$(
        run_integration_psql postgres -tAc \
            "SELECT COUNT(*) FROM pg_database WHERE datname = '${INTEGRATION_DB_EFFECTIVE}'; /* probe:database_residue */" \
            2>/dev/null | tr -d '[:space:]'
    )" || {
        printf '1\n'
        return 0
    }
    case "$residue" in
        ''|*[!0-9]*) printf '1\n' ;;
        *) printf '%s\n' "$residue" ;;
    esac
}

count_algolia_index_residue() {
    if [ -z "${ALGOLIA_AUTH_CONFIG:-}" ] || [ -z "${SOURCE_INDEX:-}" ]; then
        printf '0\n'
        return 0
    fi
    curl_http "200" --config "$ALGOLIA_AUTH_CONFIG" -X GET "$(algolia_url "/1/indexes?page=0&hitsPerPage=100")" >/dev/null || {
        printf '1\n'
        return 0
    }
    python3 - "$HTTP_BODY" "${PROBE_PREFIX}_${ALGOLIA_IMPORT_DISPATCH_RUN_ID}" <<'PY'
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
print(
    len(
        [
            item for item in items
            if isinstance(item, dict)
            and isinstance(item.get("name"), str)
            and item["name"].startswith(prefix)
        ]
    )
)
PY
}

count_algolia_key_residue() {
    local key residue=0
    if [ -z "${ALGOLIA_AUTH_CONFIG:-}" ]; then
        printf '0\n'
        return 0
    fi
    for key in "${CREATED_KEYS[@]+"${CREATED_KEYS[@]}"}"; do
        [ -n "$key" ] || continue
        curl_http "200 404" --config "$ALGOLIA_AUTH_CONFIG" -X GET "$(algolia_url "/1/keys/$key")" >/dev/null || {
            printf '1\n'
            return 0
        }
        if [ "$HTTP_STATUS" = "200" ]; then
            residue=$((residue + 1))
        fi
    done
    printf '%s\n' "$residue"
}

run_integration_up() {
    local preserve_db="$1"
    FJCLOUD_INTEGRATION_PID_DIR="$PID_DIR" \
        INTEGRATION_DB="$INTEGRATION_DB_EFFECTIVE" \
        FJCLOUD_ALGOLIA_MIGRATION_ENABLED=true \
        FJCLOUD_INTEGRATION_SKIP_METERING_AGENT=1 \
        FJCLOUD_INTEGRATION_PRESERVE_DB="$preserve_db" \
        FLAPJACK_ADMIN_KEY="$PROBE_FLAPJACK_ADMIN_KEY" \
        ENVIRONMENT=local \
        SKIP_EMAIL_VERIFICATION=1 \
        "$INTEGRATION_UP" >/dev/null
}

start_stack() {
    CURRENT_STEP="integration_start"
    mkdir -p "$PID_DIR"
    STACK_STARTED=1
    run_integration_up "" || finish_action_required "endpoint_unavailable"
}

# Restart the API/engine processes while preserving the isolated database, so the
# retained job survives the restart and reconciliation resumes from durable state.
restart_stack() {
    CURRENT_STEP="restart"
    run_integration_up "1" || finish_action_required "endpoint_unavailable"
}

require_health() {
    CURRENT_STEP="health"
    curl_http "200" -X GET "${API_URL%/}/health" || finish_action_required "endpoint_unavailable"
    curl_http "200" -X GET "${ENGINE_URL%/}/health" || finish_action_required "endpoint_unavailable"
}

require_probe_pid_file() {
    local path="$1"
    local pid
    case "$path" in
        "$PID_DIR"/*) ;;
        *) finish_action_required "inconclusive_evidence" ;;
    esac
    [ -f "$path" ] || finish_action_required "inconclusive_evidence"
    pid="$(cat "$path" 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] || finish_action_required "inconclusive_evidence"
}

create_algolia_fixture() {
    CURRENT_STEP="algolia_fixture"
    local payload task_id key_payload
    algolia_request "404" GET "/1/indexes/$SOURCE_INDEX" \
        || finish_action_required "residue_detected"
    payload="$(secure_temp_file)"
    write_json_file "$payload" "{\"requests\":[{\"action\":\"addObject\",\"body\":{\"objectID\":\"doc-1\",\"probe_secret_canary\":\"${SECRET_CANARY}\"}}]}"
    algolia_request "200 201" POST "/1/indexes/$SOURCE_INDEX/batch" "$payload" \
        || finish_action_required "endpoint_unavailable"
    CREATED_INDEXES+=("$SOURCE_INDEX")
    task_id="$(json_field "$HTTP_BODY" taskID 2>/dev/null || true)"
    if [ -n "$task_id" ]; then
        safe_response_identifier "$task_id" \
            || finish_action_required "invalid_response_identifier"
        wait_for_algolia_task "$SOURCE_INDEX" "$task_id" \
            || finish_action_required "inconclusive_evidence"
    fi
    key_payload="$(secure_temp_file)"
    write_json_file "$key_payload" "{\"acl\":[\"search\",\"browse\",\"settings\",\"listIndexes\"],\"indexes\":[\"$SOURCE_INDEX\"],\"description\":\"$SECRET_CANARY\"}"
    algolia_request "200 201" POST "/1/keys" "$key_payload" \
        || finish_action_required "endpoint_unavailable"
    DISPOSABLE_KEY="$(json_field "$HTTP_BODY" key 2>/dev/null || true)"
    [ -n "$DISPOSABLE_KEY" ] || finish_action_required "inconclusive_evidence"
    safe_response_identifier "$DISPOSABLE_KEY" \
        || finish_action_required "invalid_response_identifier"
    CREATED_KEYS+=("$DISPOSABLE_KEY")
}

register_and_login() {
    CURRENT_STEP="tenant_auth"
    local payload
    payload="$(secure_temp_file)"
    write_json_file "$payload" "{\"name\":\"Algolia Import Dispatch Probe\",\"email\":\"$PROBE_EMAIL\",\"password\":\"$PROBE_PASSWORD\"}"
    api_request "201" POST "/auth/register" "$payload" "" \
        || finish_action_required "endpoint_unavailable"
    api_request "200" POST "/auth/login" "$payload" "" \
        || finish_action_required "endpoint_unavailable"
    TENANT_TOKEN="$(json_field "$HTTP_BODY" token 2>/dev/null || true)"
    [ -n "$TENANT_TOKEN" ] || finish_action_required "inconclusive_evidence"
    safe_header_value "$TENANT_TOKEN" \
        || finish_action_required "invalid_response_identifier"
    write_header_config "$FJCLOUD_AUTH_CONFIG" "authorization: Bearer $TENANT_TOKEN"
}

# The public index lifecycle owns initialization of a selected local shared
# VM's admin key. Exercise it once, then remove the disposable index before
# dispatch so the probe follows that owner without duplicating secret storage.
prime_local_node_key() {
    CURRENT_STEP="local_node_key_warmup"
    local payload
    payload="$(secure_temp_file)"
    write_json_file "$payload" "{\"name\":\"$NODE_KEY_WARMUP_INDEX\",\"region\":\"us-east-1\"}"
    api_request "201" POST "/indexes" "$payload" "" \
        || finish_action_required "endpoint_unavailable"
    NODE_KEY_WARMUP_CREATED=1
    delete_node_key_warmup_index \
        || finish_action_required "endpoint_unavailable"
}

delete_node_key_warmup_index() {
    [ "$NODE_KEY_WARMUP_CREATED" -eq 1 ] || return 0
    local payload
    payload="$(secure_temp_file)" || return 1
    write_json_file "$payload" '{"confirm":true}' || return 1
    api_request "204 404" DELETE "/indexes/$NODE_KEY_WARMUP_INDEX" "$payload" "" \
        || return 1
    NODE_KEY_WARMUP_CREATED=0
}

obtain_target_envelope() {
    CURRENT_STEP="destination_eligibility"
    local payload
    payload="$(secure_temp_file)"
    write_json_file "$payload" "{\"phase\":\"provider\",\"mode\":\"create\",\"target\":{\"region\":\"us-east-1\",\"name\":\"$TARGET_INDEX\"}}"
    api_request "200" POST "/migration/algolia/destination-eligibility" "$payload" "" \
        || finish_action_required "endpoint_unavailable"
    PROVIDER_TOKEN="$(json_field "$HTTP_BODY" eligibilityToken 2>/dev/null || true)"
    [ -n "$PROVIDER_TOKEN" ] || finish_action_required "inconclusive_evidence"
    safe_opaque_token "$PROVIDER_TOKEN" \
        || finish_action_required "invalid_response_identifier"

    payload="$(secure_temp_file)"
    write_json_file "$payload" "{\"phase\":\"target\",\"mode\":\"create\",\"target\":{\"region\":\"us-east-1\",\"name\":\"$TARGET_INDEX\"},\"eligibilityToken\":\"$PROVIDER_TOKEN\"}"
    api_request "200" POST "/migration/algolia/destination-eligibility" "$payload" "" \
        || finish_action_required "endpoint_unavailable"
    TARGET_TOKEN="$(json_field "$HTTP_BODY" eligibilityToken 2>/dev/null || true)"
    [ -n "$TARGET_TOKEN" ] || finish_action_required "inconclusive_evidence"
    safe_opaque_token "$TARGET_TOKEN" \
        || finish_action_required "invalid_response_identifier"
}

create_job_once() {
    CURRENT_STEP="dispatch_create"
    local payload expected_observed
    payload="$(secure_temp_file)"
    write_json_file "$payload" "{\"mode\":\"create\",\"appId\":\"$ALGOLIA_APP_ID\",\"apiKey\":\"$DISPOSABLE_KEY\",\"sourceName\":\"$SOURCE_INDEX\",\"target\":{\"eligibilityToken\":\"$TARGET_TOKEN\"}}"
    api_request "202" POST "/migration/algolia/jobs" "$payload" "$IDEMPOTENCY_KEY" \
        || finish_action_required "inconclusive_evidence"
    JOB_ID="$(json_field "$HTTP_BODY" id 2>/dev/null || true)"
    JOB_LOCATION="$(sed -n 's/^[Ll]ocation:[[:space:]]*//p' "$HTTP_HEADERS_FILE" | tr -d '\r' | tail -1)"
    [ -n "$JOB_ID" ] || finish_action_required "inconclusive_evidence"
    safe_response_identifier "$JOB_ID" \
        || finish_action_required "invalid_response_identifier"
    [ "$JOB_LOCATION" = "/migration/algolia/jobs/$JOB_ID" ] || finish_action_required "inconclusive_evidence"
    expected_observed="accepted_202_location"
    emit_phase "dispatch" "accepted_202_location" "$expected_observed" "true"
}

replay_job() {
    CURRENT_STEP="dispatch_replay"
    local payload replay_id
    payload="$(secure_temp_file)"
    write_json_file "$payload" "{\"mode\":\"create\",\"appId\":\"$ALGOLIA_APP_ID\",\"apiKey\":\"$DISPOSABLE_KEY\",\"sourceName\":\"$SOURCE_INDEX\",\"target\":{\"eligibilityToken\":\"$TARGET_TOKEN\"}}"
    api_request "202" POST "/migration/algolia/jobs" "$payload" "$IDEMPOTENCY_KEY" \
        || finish_action_required "inconclusive_evidence"
    replay_id="$(json_field "$HTTP_BODY" id 2>/dev/null || true)"
    [ "$replay_id" = "$JOB_ID" ] || finish_action_required "inconclusive_evidence"
}

cancel_job() {
    CURRENT_STEP="cancel"
    local payload first_status replay_status cancel_count
    payload="$(secure_temp_file)"
    write_json_file "$payload" '{}'
    api_request "202" POST "/migration/algolia/jobs/$JOB_ID/cancel" "$payload" "" \
        || finish_action_required "inconclusive_evidence"
    first_status="$HTTP_STATUS"
    api_request "200" POST "/migration/algolia/jobs/$JOB_ID/cancel" "$payload" "" \
        || finish_action_required "inconclusive_evidence"
    replay_status="$HTTP_STATUS"
    cancel_count="$(job_cancel_intent_count)"
    [ "$first_status" = "202" ] || finish_action_required "inconclusive_evidence"
    [ "$replay_status" = "200" ] || finish_action_required "inconclusive_evidence"
    [ "$cancel_count" = "1" ] || finish_action_required "inconclusive_evidence"
    emit_phase "cancel" "first_202_replay_200_single_intent" "first_202_replay_200_single_intent" "true"
}

job_cancel_intent_count() {
    db_scalar "SELECT COUNT(*) FROM algolia_import_jobs WHERE id = '${JOB_ID}' AND cancel_requested_at IS NOT NULL; /* probe:cancel_intent */"
}

# Durable-state queries used by the lease-retention and restart phases. Each
# query carries a distinct marker comment so the answer comes from the owned
# integration database, not from a synthetic in-shell assumption.
reserved_active_count() {
    db_scalar "SELECT COUNT(*) FROM algolia_import_jobs WHERE id = '${JOB_ID}' AND erased_at IS NULL AND dispatch_intent_state <> 'absent'; /* probe:reserved_active */"
}

released_row_count() {
    db_scalar "SELECT COUNT(*) FROM algolia_import_jobs WHERE id = '${JOB_ID}' AND erased_at IS NULL AND dispatch_intent_state = 'absent'; /* probe:released */"
}

reserved_engine_identity() {
    db_scalar "SELECT COALESCE(engine_job_id::text, 'unlinked') FROM algolia_import_jobs WHERE id = '${JOB_ID}' AND erased_at IS NULL LIMIT 1; /* probe:engine_identity */"
}

fresh_reconciliation_lease_count() {
    db_scalar "SELECT COUNT(*) FROM algolia_import_jobs WHERE id = '${JOB_ID}' AND erased_at IS NULL AND worker_claimed_at > NOW() - INTERVAL '2 minutes' AND worker_lease_expires_at > NOW(); /* probe:fresh_lease */"
}

job_updated_epoch() {
    db_scalar "SELECT COALESCE(EXTRACT(EPOCH FROM updated_at)::bigint, 0) FROM algolia_import_jobs WHERE id = '${JOB_ID}' AND erased_at IS NULL; /* probe:updated_epoch */"
}

job_reconciliation_debug() {
    db_scalar "SELECT concat_ws(',', 'ack=' || engine_ack_state, 'customer=' || customer.status, 'worker_claimed=' || (worker_claimed_at IS NOT NULL)::text, 'worker_future=' || COALESCE((worker_lease_expires_at > NOW())::text, 'null'), 'updated=' || EXTRACT(EPOCH FROM job.updated_at)::bigint) FROM algolia_import_jobs AS job JOIN customers AS customer ON customer.id = job.customer_id WHERE job.id = '${JOB_ID}' AND job.erased_at IS NULL; /* probe:reconciliation_debug */"
}

# Model reconciliation claim expiry: elapse the retained job's worker lease so the
# next reconciliation turnover treats it as re-claimable. Uses the owned database
# only; never touches product code paths.
force_reconciliation_lease_expiry() {
    db_exec "UPDATE algolia_import_jobs SET worker_claimed_at = NOW() - INTERVAL '11 minutes', worker_lease_expires_at = NOW() - INTERVAL '10 minutes' WHERE id = '${JOB_ID}' AND erased_at IS NULL; /* probe:force_expiry */" \
        || finish_action_required "inconclusive_evidence"
}

db_scalar() {
    local sql="$1"
    init_integration_db_access >/dev/null 2>&1 || {
        printf '0\n'
        return 0
    }
    run_integration_psql "$INTEGRATION_DB_EFFECTIVE" -tAc "$sql" 2>/dev/null \
        | tr -d '[:space:]'
}

db_exec() {
    local sql="$1"
    local result
    init_integration_db_access >/dev/null 2>&1 || return 1
    result="$(run_integration_psql "$INTEGRATION_DB_EFFECTIVE" -tAc "$sql" 2>/dev/null | tr -d '[:space:]')" \
        || return 1
    [ "$result" = "UPDATE1" ]
}

reconciliation_turnover_ready() {
    local previous_updated_epoch="$1"
    local current_updated_epoch fresh_lease_count
    fresh_lease_count="$(fresh_reconciliation_lease_count)"
    [ "$fresh_lease_count" = "1" ] && return 0
    current_updated_epoch="$(job_updated_epoch)"
    [[ "$previous_updated_epoch" =~ ^[0-9]+$ ]] || finish_action_required "inconclusive_evidence"
    [[ "$current_updated_epoch" =~ ^[0-9]+$ ]] || finish_action_required "inconclusive_evidence"
    [ "$current_updated_epoch" -gt "$previous_updated_epoch" ]
}

require_reconciliation_turnover() {
    local previous_updated_epoch="$1"
    local remaining="$LEASE_SETTLE_SECONDS"
    while [ "$remaining" -gt 0 ]; do
        reconciliation_turnover_ready "$previous_updated_epoch" && return 0
        sleep 1
        remaining=$((remaining - 1))
    done
    reconciliation_turnover_ready "$previous_updated_epoch" && return 0
    emit "EVIDENCE|reconciliation_turnover=missing|job_state=$(job_reconciliation_debug)"
    finish_action_required "inconclusive_evidence"
}

require_engine_status_observation() {
    local engine_job_id observed_job_id
    engine_job_id="$(reserved_engine_identity)"
    [[ "$engine_job_id" =~ ^[0-9a-fA-F-]{36}$ ]] || finish_action_required "inconclusive_evidence"
    HTTP_REQUEST_TARGET="GET /1/migrations/algolia/${engine_job_id}"
    curl_http "200" --config "$FLAPJACK_AUTH_CONFIG" -X GET "${ENGINE_URL%/}/1/migrations/algolia/${engine_job_id}" \
        || finish_action_required "inconclusive_evidence"
    observed_job_id="$(json_field "$HTTP_BODY" jobId 2>/dev/null || true)"
    [ "$observed_job_id" = "$engine_job_id" ] || finish_action_required "inconclusive_evidence"
}

public_field_evidence() {
    CURRENT_STEP="public_projection"
    api_request "200" GET "/migration/algolia/jobs/$JOB_ID" "" "" \
        || finish_action_required "inconclusive_evidence"
    assert_public_job_payload "$HTTP_BODY" "$JOB_ID" \
        || finish_action_required "inconclusive_evidence"
    api_request "200" GET "/migration/algolia/jobs?limit=10" "" "" \
        || finish_action_required "inconclusive_evidence"
    assert_public_job_list_payload "$HTTP_BODY" "$JOB_ID" \
        || finish_action_required "inconclusive_evidence"
    local secret_matches alert_duplicates
    secret_matches="$(secret_canary_match_count)"
    alert_duplicates="$(alert_duplicate_count)"
    [ "$secret_matches" = "0" ] || finish_action_required "residue_detected"
    [ "$alert_duplicates" = "0" ] || finish_action_required "inconclusive_evidence"
    emit "EVIDENCE|public_fields=get_allowlisted,list_allowlisted|retained_job_id=${JOB_ID}|secret_matches=${secret_matches}|alert_duplicates=${alert_duplicates}"
}

assert_public_job_payload() {
    python3 - "$1" "$2" <<'PY'
import json
import sys

allowed = {
    "id", "status", "mode", "destination", "source", "summary", "warnings",
    "error", "cancelRequestedAt", "resumeProvenance", "resumeDeadline",
    "resumable", "resumeCount", "publicationDisposition", "createdAt", "updatedAt",
}
dest_allowed = {"kind", "target", "region"}
source_allowed = {"appId", "name"}
forbidden = {
    "physicalUid", "physical_uid", "engineJobId", "engine_job_id",
    "routingIdentity", "routing_identity", "apiKey", "api_key", "credentials",
}


def check_job(job, expected_id):
    if set(job) != allowed or job.get("id") != expected_id:
        raise SystemExit(1)
    if set(job.get("destination", {})) != dest_allowed:
        raise SystemExit(1)
    if set(job.get("source", {})) != source_allowed:
        raise SystemExit(1)
    text = json.dumps(job, separators=(",", ":"))
    if any(token in text for token in forbidden):
        raise SystemExit(1)


check_job(json.loads(sys.argv[1]), sys.argv[2])
PY
}

# List projection must carry the exact same allowlisted job field set as GET; a
# drifted or leaked field fails the assertion instead of being silently accepted.
assert_public_job_list_payload() {
    python3 - "$1" "$2" <<'PY'
import json
import sys

allowed = {
    "id", "status", "mode", "destination", "source", "summary", "warnings",
    "error", "cancelRequestedAt", "resumeProvenance", "resumeDeadline",
    "resumable", "resumeCount", "publicationDisposition", "createdAt", "updatedAt",
}
dest_allowed = {"kind", "target", "region"}
source_allowed = {"appId", "name"}
forbidden = {
    "physicalUid", "physical_uid", "engineJobId", "engine_job_id",
    "routingIdentity", "routing_identity", "apiKey", "api_key", "credentials",
}

payload = json.loads(sys.argv[1])
expected_id = sys.argv[2]
if set(payload) != {"jobs", "nextCursor"}:
    raise SystemExit(1)
jobs = payload.get("jobs")
if not isinstance(jobs, list) or len(jobs) != 1:
    raise SystemExit(1)
job = jobs[0]
if set(job) != allowed or job.get("id") != expected_id:
    raise SystemExit(1)
if set(job.get("destination", {})) != dest_allowed:
    raise SystemExit(1)
if set(job.get("source", {})) != source_allowed:
    raise SystemExit(1)
text = json.dumps(job, separators=(",", ":"))
if any(token in text for token in forbidden):
    raise SystemExit(1)
PY
}

# Fail-closed secret-leak oracle: the disposable source key is the credential
# canary and must never appear in fjcloud-owned state. The document canary is
# expected in engine data after a successful import, so it is deliberately not
# a privacy signal. Scan the owned database plus API/engine runtime captures.
secret_canary_match_count() {
    local count=0 db_hits file_hits
    db_hits="$(db_scalar "SELECT COUNT(*) FROM algolia_import_jobs AS job WHERE erased_at IS NULL AND CAST(job AS text) LIKE '%${DISPOSABLE_KEY}%'; /* probe:secret_leak */")"
    [[ "$db_hits" =~ ^[0-9]+$ ]] || db_hits=1
    count=$((count + db_hits))
    if [ -d "$PID_DIR" ] && [ -n "$DISPOSABLE_KEY" ]; then
        file_hits="$(grep -R -F -l "$DISPOSABLE_KEY" "$PID_DIR" 2>/dev/null | wc -l | tr -d ' ')"
        count=$((count + file_hits))
    fi
    printf '%s\n' "$count"
}

# Alert deduplication evidence, derived from the owned alerts table: any reconciliation
# alert for the retained job beyond a single distinct (title,message) is a duplicate.
alert_duplicate_count() {
    local duplicates
    duplicates="$(db_scalar "SELECT COUNT(*) - COUNT(DISTINCT (title, message)) FROM alerts WHERE metadata->>'job_id' = '${JOB_ID}'; /* probe:alert_duplicates */")"
    [[ "$duplicates" =~ ^-?[0-9]+$ ]] || duplicates=0
    [ "$duplicates" -lt 0 ] && duplicates=0
    printf '%s\n' "$duplicates"
}

http_body_summary() {
    if [ -z "${HTTP_BODY:-}" ]; then
        printf 'none\n'
        return 0
    fi
    python3 - "$HTTP_BODY" <<'PY'
import json
import sys

try:
    payload = json.loads(sys.argv[1])
except json.JSONDecodeError:
    print("non_json")
    raise SystemExit(0)
if not isinstance(payload, dict):
    print(type(payload).__name__)
    raise SystemExit(0)
parts = []
for key in ("error", "code", "status", "id"):
    value = payload.get(key)
    if isinstance(value, str) and value:
        parts.append(f"{key}:{value}")
print(",".join(parts) if parts else "object")
PY
}

# Prove the retained dispatch stays reserved/excluded through a reconciliation
# claim-expiry turnover: it must remain the single non-released reservation with a
# stable engine identity, never re-dispatched to a new identity or released.
run_lease_retention_phase() {
    CURRENT_STEP="lease_retention"
    require_probe_pid_file "$PID_DIR/api.pid"
    require_probe_pid_file "$PID_DIR/flapjack.pid"
    local pre_identity post_identity pre_updated_epoch reserved released
    pre_identity="$(reserved_engine_identity)"
    pre_updated_epoch="$(job_updated_epoch)"
    [ "$(reserved_active_count)" = "1" ] || finish_action_required "inconclusive_evidence"

    force_reconciliation_lease_expiry
    require_reconciliation_turnover "$pre_updated_epoch"

    reserved="$(reserved_active_count)"
    released="$(released_row_count)"
    post_identity="$(reserved_engine_identity)"
    [ "$reserved" = "1" ] || finish_action_required "inconclusive_evidence"
    [ "$released" = "0" ] || finish_action_required "inconclusive_evidence"
    [ "$post_identity" = "$pre_identity" ] || finish_action_required "inconclusive_evidence"
    emit_phase "lease_retention" "reserved_through_claim_expiry" "reserved_through_claim_expiry" "true"
}

# Prove the retained job survives an API/engine restart and reconciles from durable
# state without the source credential: after a database-preserving restart the
# reservation and engine identity are unchanged and no source secret leaked.
run_restart_reconciliation_phase() {
    CURRENT_STEP="restart_reconciliation"
    local pre_identity post_identity pre_updated_epoch leaks
    pre_identity="$(reserved_engine_identity)"
    pre_updated_epoch="$(job_updated_epoch)"

    force_reconciliation_lease_expiry
    restart_stack
    require_health
    require_reconciliation_turnover "$pre_updated_epoch"

    require_engine_status_observation
    post_identity="$(reserved_engine_identity)"
    leaks="$(secret_canary_match_count)"
    [ "$(reserved_active_count)" = "1" ] || finish_action_required "inconclusive_evidence"
    [ "$post_identity" = "$pre_identity" ] || finish_action_required "inconclusive_evidence"
    [ "$leaks" = "0" ] || finish_action_required "residue_detected"
    emit_phase "restart_reconciliation" "credential_free_reconciliation" "credential_free_reconciliation" "true"
}

delete_algolia_index() {
    local index="$1"
    local task_id
    curl_http "200 204 404" --config "$ALGOLIA_AUTH_CONFIG" -X DELETE "$(algolia_url "/1/indexes/$index")" || return 1
    [ "$HTTP_STATUS" = "404" ] && return 0
    task_id="$(json_field "$HTTP_BODY" taskID 2>/dev/null || true)"
    if [ -n "$task_id" ]; then
        safe_response_identifier "$task_id" || return 1
        wait_for_algolia_task "$index" "$task_id" || return 1
    fi
}

main() {
    parse_args "$@"
    validate_phase_set
    load_algolia_secrets
    validate_flapjack_dev_dir
    prepare_runtime
    trap 'cleanup_resources >/dev/null 2>&1 || true' EXIT

    start_stack
    require_health
    create_algolia_fixture
    register_and_login
    prime_local_node_key
    obtain_target_envelope

    phase_requested dispatch && create_job_once
    if phase_requested dispatch || phase_requested cancel || phase_requested lease_retention || phase_requested restart_reconciliation; then
        [ -n "$JOB_ID" ] || create_job_once
        replay_job
    fi
    phase_requested lease_retention && run_lease_retention_phase
    phase_requested restart_reconciliation && run_restart_reconciliation_phase
    phase_requested cancel && cancel_job
    public_field_evidence
    finish_pass
}

main "$@"
