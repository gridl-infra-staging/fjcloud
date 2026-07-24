#!/usr/bin/env bash
# Live acceptance probe for Algolia import catalog finalization and lifecycle exclusion.

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
# shellcheck source=scripts/lib/algolia_import_live_probe_common.sh
source "$SCRIPT_DIR/lib/algolia_import_live_probe_common.sh"

ALLOWED_PHASES="catalog,lifecycle_exclusion,privacy_erasure"
REQUESTED_PHASES="$ALLOWED_PHASES"
SECRET_FILE="${FJCLOUD_SECRET_FILE:-}"
INVENTORY="${ALGOLIA_IMPORT_CATALOG_INVENTORY:-$REPO_ROOT/scripts/tests/fixtures/catalog_lifecycle_writers.json}"
ORACLE="${ALGOLIA_IMPORT_CATALOG_ORACLE:-$REPO_ROOT/scripts/tests/fixtures/catalog_lifecycle_acceptance_oracles.json}"
RUN_ID="${ALGOLIA_IMPORT_CATALOG_RUN_ID:-$(date -u +%Y%m%d%H%M%S)_$$}"
PROBE_PREFIX="${ALGOLIA_IMPORT_CATALOG_PREFIX:-fjcloud_import_catalog_probe}"
RUNTIME_PARENT="${ALGOLIA_IMPORT_CATALOG_RUNTIME_PARENT:-${TMPDIR:-/tmp}}"
RUNTIME_DIR=""
PID_DIR=""
API_PORT="${API_PORT:-3099}"
FLAPJACK_PORT="${FLAPJACK_PORT:-7799}"
API_URL="${ALGOLIA_IMPORT_CATALOG_API_URL:-http://127.0.0.1:${API_PORT}}"
ENGINE_URL="${ALGOLIA_IMPORT_CATALOG_ENGINE_URL:-http://127.0.0.1:${FLAPJACK_PORT}}"
INTEGRATION_UP="${ALGOLIA_IMPORT_CATALOG_INTEGRATION_UP:-$SCRIPT_DIR/integration-up.sh}"
INTEGRATION_DOWN="${ALGOLIA_IMPORT_CATALOG_INTEGRATION_DOWN:-$SCRIPT_DIR/integration-down.sh}"
ENGINE_CONTRACT_CHECK="${ALGOLIA_IMPORT_CATALOG_ENGINE_CONTRACT_CHECK:-$SCRIPT_DIR/update_algolia_migration_engine_contract.sh}"
CALLER_RUNNER="${ALGOLIA_IMPORT_CATALOG_CALLER_RUNNER:-$SCRIPT_DIR/algolia_import_catalog_caller_runner.sh}"
CALLER_EVIDENCE_VALIDATOR="$SCRIPT_DIR/lib/algolia_import_catalog_evidence.py"
PROBE_ADMIN_KEY="" # gitleaks:allow -- adjacent empty variable names, no credential literal
INTEGRATION_DB_EFFECTIVE=""
ALGOLIA_AUTH_CONFIG=""
FJCLOUD_AUTH_CONFIG=""
HTTP_BODY=""
HTTP_STATUS=""
HTTP_HEADERS_FILE=""
HTTP_REQUEST_TARGET=""
TENANT_TOKEN="" # gitleaks:allow -- adjacent empty variable names, no credential literal
DISPOSABLE_KEY=""
JOB_ID=""
SOURCE_INDEX=""
TARGET_INDEX=""
TARGET_TOKEN=""
IDEMPOTENCY_KEY=""
NODE_KEY_WARMUP_INDEX=""
PROBE_EMAIL=""
PROBE_PASSWORD=""
SECRET_CANARY=""
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
Usage: algolia_import_catalog_live_probe.sh --phases catalog,lifecycle_exclusion
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
    if [ -n "${TENANT_TOKEN:-}" ]; then
        value="${value//${TENANT_TOKEN}/[REDACTED]}"
    fi
    if [ -n "${PROBE_ADMIN_KEY:-}" ]; then
        value="${value//${PROBE_ADMIN_KEY}/[REDACTED]}"
    fi
    printf '%s\n' "$value"
}

emit() {
    sanitize "$*"
}

emit_result() {
    local status="$1" reason="${2:-}"
    if [ -n "$reason" ]; then
        emit "RESULT|status=${status}|reason=${reason}|phases=${REQUESTED_PHASES}"
    else
        emit "RESULT|status=${status}|phases=${REQUESTED_PHASES}"
    fi
}

finish_action_required() {
    local reason="$1"
    local failure_status failure_target
    failure_status="${HTTP_STATUS:-none}"
    failure_target="${HTTP_REQUEST_TARGET:-none}"
    cleanup_resources
    emit "ERROR|reason=${reason}|step=${CURRENT_STEP}|target=${failure_target}|http_status=${failure_status}"
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

secure_temp_file() {
    algolia_import_probe_secure_temp_file "$RUNTIME_DIR"
}

write_json_file() {
    algolia_import_probe_write_json_file "$1" "$2"
}

json_field() {
    algolia_import_probe_json_field "$1" "$2"
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --phases)
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
            catalog|lifecycle_exclusion|privacy_erasure) ;;
            *) finish_action_required "invalid_phases" ;;
        esac
    done
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

validate_catalog_acceptance_fixtures() {
    CURRENT_STEP="fixture_validation"
    local evidence
    [ -f "$INVENTORY" ] && [ -f "$ORACLE" ] || finish_action_required "missing_fixture_path"
    [ "${INVENTORY##*/}" = "catalog_lifecycle_writers.json" ] \
        && [ "${ORACLE##*/}" = "catalog_lifecycle_acceptance_oracles.json" ] \
        || finish_action_required "noncanonical_fixture_path"
    if ! evidence="$(python3 - "$INVENTORY" "$ORACLE" "$REPO_ROOT" 2>&1 <<'PY'
import json
import pathlib
import sys
from collections import Counter

inventory_path = pathlib.Path(sys.argv[1])
oracle_path = pathlib.Path(sys.argv[2])
repo_root = pathlib.Path(sys.argv[3])

def reject_duplicate_object_keys(label, pairs):
    seen = set()
    value = {}
    for key, child in pairs:
        if key in seen:
            raise SystemExit(f"duplicate_object_key:{label}:{key}")
        seen.add(key)
        value[key] = child
    return value

def load_json(label, path):
    try:
        with path.open(encoding="utf-8") as handle:
            return json.load(
                handle,
                object_pairs_hook=lambda pairs: reject_duplicate_object_keys(label, pairs),
            )
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"unreadable_json:{label}:{exc}")

def slug(value):
    return "_".join(
        part
        for part in "".join(
            ch.lower() if ch.isalnum() else "_" for ch in value
        ).split("_")
        if part
    )

def validate_writer_identity(writer_id, owner_path, source_anchor):
    parts = writer_id.split("__") if isinstance(writer_id, str) else []
    if len(parts) != 4 or parts[0] != "catalog_writer":
        raise SystemExit("stale_source_discovery")
    expected_owner_slug = slug(owner_path.removesuffix(".rs"))
    expected_anchor_slug = slug(source_anchor)
    if parts[1] != expected_owner_slug or parts[3] != expected_anchor_slug:
        raise SystemExit("stale_source_discovery")

inventory = load_json("inventory", inventory_path)
oracle = load_json("oracle", oracle_path)
writers = inventory.get("writers")
if inventory.get("version") != 1 or inventory.get("total_writer_count") != 48:
    raise SystemExit("wrong_inventory_total")
if not isinstance(writers, list) or len(writers) != 48:
    raise SystemExit("wrong_inventory_total")
if oracle.get("version") != 1 or oracle.get("oracle_kind") != "catalog_lifecycle_acceptance":
    raise SystemExit("altered_acceptance_oracle")
lane = oracle.get("lane_composition")
if not isinstance(lane, dict) or lane.get("missing_dependency_disposition") != "failure":
    raise SystemExit("altered_acceptance_oracle")
oracles = oracle.get("oracles")
if set(oracles or {}) != {"block_without_change", "privacy_transition"}:
    raise SystemExit("altered_acceptance_oracle")
if oracles["block_without_change"].get("leased_behavior") != "refuse_without_mutation":
    raise SystemExit("altered_acceptance_oracle")
if oracles["block_without_change"].get("release_trigger") != "engine_ack":
    raise SystemExit("altered_acceptance_oracle")
privacy_oracle = oracles["privacy_transition"]
if privacy_oracle.get("soft_delete") != "mark_deleted_bump_generation_fence_future_writes":
    raise SystemExit("altered_acceptance_oracle")
if privacy_oracle.get("hard_delete") != "purge_dependents_then_target":
    raise SystemExit("altered_acceptance_oracle")
if privacy_oracle.get("reaper_scrub") != "reaper_scrubs_catalog_target_after_hard_delete":
    raise SystemExit("altered_acceptance_oracle")

ids = [row.get("id") for row in writers]
if len(ids) != len(set(ids)):
    raise SystemExit("duplicate_writer_id")
counter = Counter()
soft_delete = 0
hard_delete = 0
caller_keys = set()
for row in writers:
    if not isinstance(row, dict):
        raise SystemExit("malformed_writer")
    writer_id = row.get("id")
    disposition = row.get("disposition")
    owner_path = row.get("owner_path")
    source_anchor = row.get("source_anchor")
    caller_key = row.get("live_caller_key")
    caller_command = row.get("live_caller_command")
    scenario_key = row.get("live_scenario_key")
    live_phase = row.get("live_phase")
    if disposition not in {"block_without_change", "privacy_transition"}:
        raise SystemExit("unknown_disposition")
    if not isinstance(owner_path, str) or not (repo_root / owner_path).exists():
        raise SystemExit("stale_source_discovery")
    if not isinstance(source_anchor, str) or not source_anchor:
        raise SystemExit("stale_source_discovery")
    validate_writer_identity(writer_id, owner_path, source_anchor)
    if not isinstance(caller_key, str) or not caller_key:
        raise SystemExit("missing_caller_mapping")
    if caller_command not in {
        "invoke_catalog_blocking_writer",
        "invoke_lifecycle_soft_delete_writer",
        "invoke_privacy_erasure_dependency_gate",
    }:
        raise SystemExit("missing_caller_mapping")
    if not isinstance(scenario_key, str) or not scenario_key:
        raise SystemExit("missing_caller_mapping")
    if caller_key in caller_keys:
        raise SystemExit("duplicate_caller_mapping")
    caller_keys.add(caller_key)
    if live_phase not in {"catalog", "lifecycle_exclusion", "privacy_erasure"}:
        raise SystemExit("missing_caller_mapping")
    counter[disposition] += 1
    if live_phase == "lifecycle_exclusion":
        soft_delete += 1
    if live_phase == "privacy_erasure":
        hard_delete += 1
if counter["block_without_change"] == 0 or soft_delete == 0:
    raise SystemExit("zero_class_denominator")
if counter["block_without_change"] != 41 or soft_delete != 3 or hard_delete != 4:
    raise SystemExit("wrong_disposition")
print(
    "EVIDENCE|inventory_total=48|block_without_change=41|"
    "soft_delete=3|hard_delete=4|duplicate_writer_ids=0"
)
PY
    )"; then
        case "$evidence" in
            *zero_class_denominator*) finish_action_required "zero_class_denominator" ;;
            *duplicate_writer_id*) finish_action_required "duplicate_writer_id" ;;
            *unknown_disposition*) finish_action_required "unknown_disposition" ;;
            *missing_caller_mapping*|*duplicate_caller_mapping*) finish_action_required "missing_caller_mapping" ;;
            *altered_acceptance_oracle*) finish_action_required "altered_acceptance_oracle" ;;
            *stale_source_discovery*) finish_action_required "stale_source_discovery" ;;
            *) finish_action_required "fixture_validation_failed" ;;
        esac
    fi
    emit "$evidence"
}

require_privacy_erasure_dependencies() {
    CURRENT_STEP="privacy_erasure_dependencies"
    local dependency_output dependency_reason
    if ! dependency_output="$(python3 - "$ORACLE" 2>&1 <<'PY'
import json
import pathlib
import re
import sys

oracle_path = pathlib.Path(sys.argv[1])
expected_ids = [
    "authenticated_engine_seal_privacy_scrub",
    "cloud_erased_tombstone_scrub_worker",
    "deterministic_source_boundary_controls",
]
reason_pattern = re.compile(r"^[a-z][a-z0-9_]*$")

try:
    with oracle_path.open(encoding="utf-8") as handle:
        oracle = json.load(handle)
except (OSError, json.JSONDecodeError):
    print("privacy_dependency_contract_invalid")
    raise SystemExit(1)

dependencies = oracle.get("privacy_erasure_dependencies")
if not isinstance(dependencies, list) or len(dependencies) != len(expected_ids):
    print("privacy_dependency_contract_invalid")
    raise SystemExit(1)

first_missing_reason = ""
for expected_id, dependency in zip(expected_ids, dependencies):
    if not isinstance(dependency, dict) or dependency.get("id") != expected_id:
        print("privacy_dependency_contract_invalid")
        raise SystemExit(1)
    status = dependency.get("status")
    reason = dependency.get("reason")
    required_text_fields = [
        dependency.get("owner"),
        dependency.get("required_contract"),
        dependency.get("minimum_unblock"),
    ]
    if (
        status not in {"available", "action_required"}
        or not isinstance(reason, str)
        or not reason_pattern.fullmatch(reason)
        or any(not isinstance(value, str) or not value for value in required_text_fields)
    ):
        print("privacy_dependency_contract_invalid")
        raise SystemExit(1)
    print(
        "DEPENDENCY|phase=privacy_erasure|"
        f"id={expected_id}|status={status}|reason={reason}"
    )
    if status != "available" and not first_missing_reason:
        first_missing_reason = reason

print(f"REASON|{first_missing_reason or 'privacy_erasure_implementation_unavailable'}")
PY
    )"; then
        finish_action_required "privacy_dependency_contract_invalid"
    fi
    while IFS= read -r dependency_line; do
        case "$dependency_line" in
            DEPENDENCY\|*) emit "$dependency_line" ;;
            REASON\|*) dependency_reason="${dependency_line#REASON|}" ;;
        esac
    done <<< "$dependency_output"
    [ -n "${dependency_reason:-}" ] || finish_action_required "privacy_dependency_contract_invalid"
    finish_action_required "$dependency_reason"
}

prepare_runtime() {
    CURRENT_STEP="runtime"
    [[ "$PROBE_PREFIX" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || finish_action_required "invalid_probe_prefix"
    [[ "$RUN_ID" =~ ^[A-Za-z0-9_]+$ ]] || finish_action_required "invalid_probe_run_id"
    RUNTIME_DIR="$(mktemp -d "${RUNTIME_PARENT%/}/algolia_import_catalog.XXXXXX")"
    PID_DIR="$RUNTIME_DIR/pids"
    INTEGRATION_DB_EFFECTIVE="fjcloud_import_catalog_${RUN_ID}"
    export INTEGRATION_DB="$INTEGRATION_DB_EFFECTIVE"
    unset INTEGRATION_DB_URL
    init_integration_env_defaults
    SOURCE_INDEX="${PROBE_PREFIX}_${RUN_ID}_source"
    TARGET_INDEX="${PROBE_PREFIX}_${RUN_ID}_target"
    IDEMPOTENCY_KEY="${PROBE_PREFIX}_${RUN_ID}_dispatch"
    NODE_KEY_WARMUP_INDEX="${PROBE_PREFIX}_${RUN_ID}_warmup"
    PROBE_EMAIL="${PROBE_PREFIX}_${RUN_ID}@example.com"
    PROBE_PASSWORD="Integration-Test-Pass-1-${RUN_ID}!"
    SECRET_CANARY="${PROBE_PREFIX}_${RUN_ID}_canary"
    PROBE_ADMIN_KEY="$(algolia_import_probe_generate_secret)"
    export JWT_SECRET="${JWT_SECRET:-$(algolia_import_probe_generate_secret)}"
    ALGOLIA_AUTH_CONFIG="$(secure_temp_file)"
    FJCLOUD_AUTH_CONFIG="$(secure_temp_file)"
    algolia_import_probe_write_header_config "$ALGOLIA_AUTH_CONFIG" \
        "X-Algolia-Application-Id: $ALGOLIA_APP_ID" \
        "X-Algolia-API-Key: $ALGOLIA_ADMIN_KEY"
}

run_integration_up() {
    local preserve_db="$1"
    FJCLOUD_INTEGRATION_PID_DIR="$PID_DIR" \
        INTEGRATION_DB="$INTEGRATION_DB_EFFECTIVE" \
        FJCLOUD_ALGOLIA_MIGRATION_ENABLED=true \
        FJCLOUD_INTEGRATION_SKIP_METERING_AGENT=1 \
        FJCLOUD_INTEGRATION_PRESERVE_DB="$preserve_db" \
        ENVIRONMENT=local \
        SKIP_EMAIL_VERIFICATION=1 \
        ADMIN_KEY="$PROBE_ADMIN_KEY" \
        "$INTEGRATION_UP" >/dev/null
}

start_stack() {
    CURRENT_STEP="integration_start"
    mkdir -p "$PID_DIR"
    STACK_STARTED=1
    run_integration_up "" || finish_action_required "endpoint_unavailable"
}

require_health() {
    CURRENT_STEP="health"
    curl_http "200" -X GET "${API_URL%/}/health" || finish_action_required "endpoint_unavailable"
    curl_http "200" -X GET "${ENGINE_URL%/}/health" || finish_action_required "endpoint_unavailable"
}

wait_for_algolia_task() {
    algolia_import_probe_wait_for_algolia_task "$@"
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
        algolia_import_probe_safe_response_identifier "$task_id" \
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
    algolia_import_probe_safe_response_identifier "$DISPOSABLE_KEY" \
        || finish_action_required "invalid_response_identifier"
    CREATED_KEYS+=("$DISPOSABLE_KEY")
    algolia_import_probe_wait_for_restricted_source_key "$SOURCE_INDEX" "$DISPOSABLE_KEY" \
        || finish_action_required "inconclusive_evidence"
}

register_and_login() {
    CURRENT_STEP="tenant_auth"
    local payload
    payload="$(secure_temp_file)"
    write_json_file "$payload" "{\"name\":\"Algolia Import Catalog Probe\",\"email\":\"$PROBE_EMAIL\",\"password\":\"$PROBE_PASSWORD\"}"
    api_request "201" POST "/auth/register" "$payload" \
        || finish_action_required "endpoint_unavailable"
    api_request "200" POST "/auth/login" "$payload" \
        || finish_action_required "endpoint_unavailable"
    TENANT_TOKEN="$(json_field "$HTTP_BODY" token 2>/dev/null || true)"
    [ -n "$TENANT_TOKEN" ] || finish_action_required "inconclusive_evidence"
    algolia_import_probe_safe_header_value "$TENANT_TOKEN" \
        || finish_action_required "invalid_response_identifier"
    algolia_import_probe_write_header_config "$FJCLOUD_AUTH_CONFIG" "authorization: Bearer $TENANT_TOKEN"
}

prime_local_node_key() {
    CURRENT_STEP="local_node_key_warmup"
    local payload
    payload="$(secure_temp_file)"
    write_json_file "$payload" "{\"name\":\"$NODE_KEY_WARMUP_INDEX\",\"region\":\"us-east-1\"}"
    api_request "201" POST "/indexes" "$payload" \
        || finish_action_required "endpoint_unavailable"
    payload="$(secure_temp_file)"
    write_json_file "$payload" '{"confirm":true}'
    api_request "204 404" DELETE "/indexes/$NODE_KEY_WARMUP_INDEX" "$payload" \
        || finish_action_required "endpoint_unavailable"
}

create_import_job() {
    CURRENT_STEP="dispatch_create"
    local payload
    algolia_import_probe_obtain_target_envelope "$TARGET_INDEX"
    payload="$(secure_temp_file)"
    write_json_file "$payload" "{\"mode\":\"create\",\"appId\":\"$ALGOLIA_APP_ID\",\"apiKey\":\"$DISPOSABLE_KEY\",\"sourceName\":\"$SOURCE_INDEX\",\"target\":{\"eligibilityToken\":\"$TARGET_TOKEN\"}}"
    api_request "202" POST "/migration/algolia/jobs" "$payload" "$IDEMPOTENCY_KEY" \
        || finish_action_required "inconclusive_evidence"
    JOB_ID="$(json_field "$HTTP_BODY" id 2>/dev/null || true)"
    [ -n "$JOB_ID" ] || finish_action_required "inconclusive_evidence"
    algolia_import_probe_safe_response_identifier "$JOB_ID" || finish_action_required "invalid_response_identifier"
}

run_production_callers() {
    CURRENT_STEP="production_callers"
    local evidence_file runner_output validation_output validation_reason
    [ -x "$CALLER_RUNNER" ] || finish_action_required "production_caller_runner_unavailable"
    [ -f "$CALLER_EVIDENCE_VALIDATOR" ] \
        || finish_action_required "production_caller_runner_unavailable"

    evidence_file="$(secure_temp_file)"
    runner_output="$(secure_temp_file)"
    if ! DATABASE_URL="$INTEGRATION_DB_URL" "$CALLER_RUNNER" \
        --inventory "$INVENTORY" \
        --phases "$REQUESTED_PHASES" \
        --job-id "$JOB_ID" \
        --api-url "$API_URL" \
        --auth-config "$FJCLOUD_AUTH_CONFIG" \
        --admin-key "$PROBE_ADMIN_KEY" \
        --target-index "$TARGET_INDEX" \
        --runtime-dir "$RUNTIME_DIR" \
        --output "$evidence_file" >"$runner_output" 2>&1; then
        validation_reason="$(tail -n 1 "$runner_output" | tr -d '\r')"
        case "$validation_reason" in
            accepted_refused_count_drift|ack_initial_state_not_observed|\
            ack_release_not_observed|ack_terminal_state_not_observed|\
            active_reservation_not_observed|caller_evidence_invalid|\
            catalog_invariant_drift|catalog_mutation_accepted|\
            database_caller_skipped|deleted_reactivation_accepted|\
            early_reservation_release|lifecycle_policy_drift|\
            production_caller_failed|repeated_scenario_coverage|\
            repeated_writer_observation|soft_delete_boundary_missing|\
            source_selection_not_live_called|\
            suspended_reactivation_control_failed|\
            writer_invocation_identity_drift)
                finish_action_required "$validation_reason"
                ;;
            *)
                finish_action_required "production_caller_runner_failed"
                ;;
        esac
    fi
    if ! validation_output="$(python3 "$CALLER_EVIDENCE_VALIDATOR" \
        --inventory "$INVENTORY" \
        --evidence "$evidence_file" \
        --phases "$REQUESTED_PHASES" \
        --job-id "$JOB_ID" 2>&1)"; then
        validation_reason="${validation_output##*$'\n'}"
        case "$validation_reason" in
            accepted_refused_count_drift|ack_release_not_observed|\
            active_reservation_not_observed|caller_evidence_invalid|\
            catalog_invariant_drift|catalog_mutation_accepted|\
            deleted_reactivation_accepted|early_reservation_release|\
            lifecycle_policy_drift|repeated_scenario_coverage|\
            repeated_writer_observation|soft_delete_boundary_missing|\
            suspended_reactivation_control_failed|\
            writer_invocation_identity_drift)
                finish_action_required "$validation_reason"
                ;;
            *)
                finish_action_required "caller_evidence_invalid"
                ;;
        esac
    fi
    while IFS= read -r evidence_line; do
        [ -n "$evidence_line" ] && emit "$evidence_line"
    done <<< "$validation_output"
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
            "SELECT COUNT(*) FROM pg_database WHERE datname = '${INTEGRATION_DB_EFFECTIVE}'; /* probe:catalog_live_database_residue */" \
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
    [ -n "${ALGOLIA_AUTH_CONFIG:-}" ] || {
        printf '0\n'
        return 0
    }
    curl_http "200" --config "$ALGOLIA_AUTH_CONFIG" -X GET "$(algolia_url "/1/indexes?page=0&hitsPerPage=100")" >/dev/null || {
        printf '1\n'
        return 0
    }
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
print(sum(
    1 for item in items
    if isinstance(item, dict)
    and isinstance(item.get("name"), str)
    and item["name"].startswith(prefix)
))
PY
}

count_algolia_key_residue() {
    local key residue=0
    [ -n "${ALGOLIA_AUTH_CONFIG:-}" ] || {
        printf '0\n'
        return 0
    }
    for key in "${CREATED_KEYS[@]+"${CREATED_KEYS[@]}"}"; do
        curl_http "200 404" --config "$ALGOLIA_AUTH_CONFIG" -X GET "$(algolia_url "/1/keys/$key")" >/dev/null || {
            printf '1\n'
            return 0
        }
        [ "$HTTP_STATUS" = "200" ] && residue=$((residue + 1))
    done
    printf '%s\n' "$residue"
}

delete_algolia_index() {
    algolia_import_probe_delete_algolia_index "$1"
}

cleanup_resources() {
    [ "$CLEANUP_DONE" -eq 0 ] || return 0
    CLEANUP_DONE=1
    set +e
    local key index database_residue=0 teardown_failed=0
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

main() {
    parse_args "$@"
    validate_phase_set
    validate_catalog_acceptance_fixtures
    if phase_requested privacy_erasure; then
        require_privacy_erasure_dependencies
    fi
    CURRENT_STEP="credentials"
    algolia_import_probe_load_algolia_secrets "$SECRET_FILE" || {
        [ "$?" -eq 2 ] && finish_action_required "invalid_response_identifier"
        finish_action_required "missing_credentials"
    }
    CURRENT_STEP="engine_contract"
    algolia_import_probe_validate_flapjack_dev_dir "${FLAPJACK_DEV_DIR:-}" "$ENGINE_CONTRACT_CHECK" || {
        contract_status=$?
        case "$contract_status" in
            2) finish_action_required "flapjack_dev_dir_mismatch" ;;
            3) finish_action_required "engine_ack_route_unavailable" ;;
            *) finish_action_required "flapjack_dev_dir_unavailable" ;;
        esac
    }
    prepare_runtime
    trap 'cleanup_resources >/dev/null 2>&1 || true' EXIT
    start_stack
    require_health
    create_algolia_fixture
    register_and_login
    prime_local_node_key
    create_import_job
    run_production_callers
    finish_pass
}

main "$@"
