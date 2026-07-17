#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=scripts/lib/live_probe_common.sh
source "$SCRIPT_DIR/lib/live_probe_common.sh"
source "$SCRIPT_DIR/lib/integration_stack_env.sh"
source "$SCRIPT_DIR/lib/integration_db_access.sh"
DEFAULT_INVENTORY="$REPO_ROOT/scripts/tests/fixtures/catalog_lifecycle_writers.json"
DEFAULT_INVENTORY_DISPLAY="scripts/tests/fixtures/catalog_lifecycle_writers.json"

API_BINARY=""
ENGINE_BINARY=""
INVENTORY="$DEFAULT_INVENTORY"
INVENTORY_DISPLAY="$DEFAULT_INVENTORY_DISPLAY"
START_STACK=1

die() {
    echo "[catalog-lifecycle-service-window-live-probe] ERROR: $*" >&2
    exit 1
}

usage() {
    cat >&2 <<'USAGE'
Usage: catalog_lifecycle_service_window_live_probe.sh --api-binary <absolute> --engine-binary <absolute> [--inventory <json>] [--no-start-stack]

Defaults:
  --inventory scripts/tests/fixtures/catalog_lifecycle_writers.json

Environment consumed:
  ENGINE_INDEX_IDENTITY_API_URL
  ENGINE_INDEX_IDENTITY_OBSERVED_CALLERS_FILE
  CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_EMAIL
  CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_PASSWORD
  CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_INDEX
  CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_REGION
  CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_REPLICA_REGION
  CATALOG_LIFECYCLE_SERVICE_WINDOW_ISOLATION_EMAIL
  CATALOG_LIFECYCLE_SERVICE_WINDOW_ISOLATION_PASSWORD
  CATALOG_LIFECYCLE_SERVICE_WINDOW_DEST_VM_ID
  CATALOG_LIFECYCLE_SERVICE_WINDOW_DEST_SEED_INDEX
  CATALOG_LIFECYCLE_SERVICE_WINDOW_ENGINE_URL
  CATALOG_LIFECYCLE_SERVICE_WINDOW_ADMIN_KEY
  CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_NODE_API_KEY
  CATALOG_LIFECYCLE_SERVICE_WINDOW_RUNTIME_DIR
  FJCLOUD_INTEGRATION_PID_DIR
  INTEGRATION_DB
  INTEGRATION_DB_URL
  INTEGRATION_DB_USER
  INTEGRATION_DB_PASSWORD
  INTEGRATION_DB_HOST
  INTEGRATION_DB_PORT
  API_PORT
  FLAPJACK_PORT
USAGE
}

require_absolute_executable() {
    local label="$1"
    local path="$2"

    live_probe_is_absolute_executable "$path" \
        || die "$label must be an absolute executable path"
}

require_file() {
    local label="$1"
    local path="$2"

    live_probe_file_exists "$path" || die "$label does not exist: $path"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --api-binary)
            [ "$#" -ge 2 ] || die "--api-binary requires a value"
            API_BINARY="$2"
            shift 2
            ;;
        --engine-binary)
            [ "$#" -ge 2 ] || die "--engine-binary requires a value"
            ENGINE_BINARY="$2"
            shift 2
            ;;
        --inventory)
            [ "$#" -ge 2 ] || die "--inventory requires a value"
            INVENTORY="$2"
            INVENTORY_DISPLAY="$2"
            shift 2
            ;;
        --no-start-stack)
            START_STACK=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            die "unknown argument: $1"
            ;;
    esac
done

[ -n "$API_BINARY" ] || die "--api-binary is required"
[ -n "$ENGINE_BINARY" ] || die "--engine-binary is required"
require_absolute_executable "--api-binary" "$API_BINARY"
require_absolute_executable "--engine-binary" "$ENGINE_BINARY"
require_file "--inventory" "$INVENTORY"

OBSERVED_CALLERS_FILE="${ENGINE_INDEX_IDENTITY_OBSERVED_CALLERS_FILE:-}"
if [ -z "$OBSERVED_CALLERS_FILE" ]; then
    OBSERVED_CALLERS_FILE="$(mktemp -t catalog-service-window-observed.XXXXXX.json)"
    rm -f "$OBSERVED_CALLERS_FILE"
fi
export ENGINE_INDEX_IDENTITY_OBSERVED_CALLERS_FILE="$OBSERVED_CALLERS_FILE"

RUNTIME_DIR="${FJCLOUD_INTEGRATION_PID_DIR:-${CATALOG_LIFECYCLE_SERVICE_WINDOW_RUNTIME_DIR:-$(mktemp -d -t catalog-service-window-runtime.XXXXXX)}}"
export FJCLOUD_INTEGRATION_PID_DIR="$RUNTIME_DIR"
PROBE_INTEGRATION_DB="${INTEGRATION_DB:-catalog_service_window_live_probe}"
export INTEGRATION_DB="$PROBE_INTEGRATION_DB"
API_PORT="${API_PORT:-3101}"
FLAPJACK_PORT="${FLAPJACK_PORT:-7801}"
API_URL="${ENGINE_INDEX_IDENTITY_API_URL:-http://localhost:${API_PORT}}"
PROBE_EMAIL="${CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_EMAIL:-catalog-service-window-probe@example.com}"
PROBE_PASSWORD="${CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_PASSWORD:-Integration-Test-Pass-1!}"
PROBE_INDEX="${CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_INDEX:-catalog_service_window_source}"
PROBE_ADMIN_RESTORE_INDEX="${PROBE_INDEX}_admin_restore"
PROBE_MIGRATION_INDEX="${PROBE_INDEX}_migration"
PROBE_REGION="${CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_REGION:-us-east-1}"
PROBE_REPLICA_REGION="${CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_REPLICA_REGION:-eu-central-1}"
PROBE_DEST_VM_ID="${CATALOG_LIFECYCLE_SERVICE_WINDOW_DEST_VM_ID:-}"
PROBE_DEST_SEED_INDEX="${CATALOG_LIFECYCLE_SERVICE_WINDOW_DEST_SEED_INDEX:-catalog_service_window_destination_seed}"
PROBE_ENGINE_URL="${CATALOG_LIFECYCLE_SERVICE_WINDOW_ENGINE_URL:-http://127.0.0.1:${FLAPJACK_PORT}}"
PROBE_ADMIN_KEY="${CATALOG_LIFECYCLE_SERVICE_WINDOW_ADMIN_KEY:-catalog-service-window-admin-key}"
PROBE_NODE_API_KEY="${CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_NODE_API_KEY:-catalog-service-window-node-api-key}"
ISOLATION_EMAIL="${CATALOG_LIFECYCLE_SERVICE_WINDOW_ISOLATION_EMAIL:-service-window-isolation@example.com}"
ISOLATION_PASSWORD="${CATALOG_LIFECYCLE_SERVICE_WINDOW_ISOLATION_PASSWORD:-Integration-Isolation-Pass-1!}"
PROBE_CUSTOMER_ID=""
PROBE_TOKEN=""
ISOLATION_CUSTOMER_ID=""
ISOLATION_TOKEN=""
UNRELATED_STATE_BEFORE=""
REPLICA_STATUS=""
CUSTOMER_RESTORE_STATUS=""
ADMIN_RESTORE_STATUS=""
ROLLBACK_STATUS=""
FAILURE_STATUS=""
STACK_STARTED=0
HTTP_RESPONSE_BODY=""
HTTP_RESPONSE_CODE=""

[ -n "$PROBE_NODE_API_KEY" ] || die "probe node API key must not be empty"

cleanup() {
    if [ "$STACK_STARTED" -eq 1 ]; then
        FJCLOUD_INTEGRATION_PID_DIR="$RUNTIME_DIR" \
            INTEGRATION_DB="$PROBE_INTEGRATION_DB" \
            bash "$SCRIPT_DIR/integration-down.sh" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

validate_catalog_inventory() {
    python3 - "$INVENTORY" "$REPO_ROOT" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
repo_root = pathlib.Path(sys.argv[2])
try:
    with path.open(encoding="utf-8") as handle:
        inventory = json.load(handle)
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"catalog lifecycle writer inventory is not readable structured JSON: {exc}")

if inventory.get("version") != 1:
    raise SystemExit("catalog lifecycle writer inventory requires version 1")
total = inventory.get("total_writer_count")
writers = inventory.get("writers")
if not isinstance(total, int) or total <= 0:
    raise SystemExit("total_writer_count must be greater than zero")
if not isinstance(writers, list) or len(writers) != total:
    raise SystemExit("writers length must equal total_writer_count")

ids = []
owner_paths = set()
stage6_owner_paths = {
    "infra/api/src/services/replica.rs",
    "infra/api/src/services/restore.rs",
    "infra/api/src/services/cold_tier/pipeline.rs",
    "infra/api/src/services/migration/mod.rs",
    "infra/api/src/services/migration/protocol.rs",
    "infra/api/src/services/migration/recovery.rs",
}
expected_stage6_writer_ids = {
    "catalog_writer__infra_api_src_services_cold_tier_pipeline__begin_snapshot_record__tenant_repo_set_tier",
    "catalog_writer__infra_api_src_services_cold_tier_pipeline__rollback_tenant_snapshot_state__tenant_repo_set_cold_snapshot_id",
    "catalog_writer__infra_api_src_services_cold_tier_pipeline__rollback_tenant_snapshot_state__tenant_repo_set_tier",
    "catalog_writer__infra_api_src_services_cold_tier_pipeline__rollback_tenant_snapshot_state__tenant_repo_set_vm_id",
    "catalog_writer__infra_api_src_services_cold_tier_pipeline__transition_tenant_to_cold_storage__tenant_repo_clear_vm_id",
    "catalog_writer__infra_api_src_services_cold_tier_pipeline__transition_tenant_to_cold_storage__tenant_repo_set_cold_snapshot_id",
    "catalog_writer__infra_api_src_services_migration_mod__begin_migration_intent__tenant_repo_set_tier",
    "catalog_writer__infra_api_src_services_migration_mod__reset_tenant_tier_after_execute_failure__tenant_repo_set_tier",
    "catalog_writer__infra_api_src_services_migration_protocol__finalize_protocol__tenant_repo_set_tier",
    "catalog_writer__infra_api_src_services_migration_protocol__finalize_protocol__tenant_repo_set_vm_id",
    "catalog_writer__infra_api_src_services_migration_recovery__publish_rollback__tenant_repo_publish_lifecycle_placement",
    "catalog_writer__infra_api_src_services_migration_recovery__recover_source_on_failure__tenant_repo_publish_lifecycle_placement",
    "catalog_writer__infra_api_src_services_replica__create_replica__replica_repo_create",
    "catalog_writer__infra_api_src_services_replica__remove_replica__replica_repo_delete",
    "catalog_writer__infra_api_src_services_restore__execute_restore_inner__tenant_repo_set_cold_snapshot_id",
    "catalog_writer__infra_api_src_services_restore__execute_restore_inner__tenant_repo_set_tier",
    "catalog_writer__infra_api_src_services_restore__execute_restore_inner__tenant_repo_set_vm_id",
    "catalog_writer__infra_api_src_services_restore__handle_restore_failure__tenant_repo_set_tier",
    "catalog_writer__infra_api_src_services_restore__initiate_restore__tenant_repo_set_tier",
}
stage6_writer_ids = set()
for writer in writers:
    if not isinstance(writer, dict):
        raise SystemExit("writers must be objects")
    writer_id = writer.get("id")
    owner_path = writer.get("owner_path")
    source_anchor = writer.get("source_anchor")
    if not isinstance(writer_id, str) or not writer_id:
        raise SystemExit("writer ids must be non-empty strings")
    if not isinstance(owner_path, str) or not owner_path:
        raise SystemExit("writer owner_path values must be non-empty strings")
    if not isinstance(source_anchor, str) or not source_anchor:
        raise SystemExit("writer source_anchor values must be non-empty strings")
    if not (repo_root / owner_path).exists():
        raise SystemExit(f"writer owner_path does not exist: {owner_path}")
    ids.append(writer_id)
    owner_paths.add(owner_path)
    if owner_path in stage6_owner_paths:
        stage6_writer_ids.add(writer_id)

if len(ids) != len(set(ids)):
    raise SystemExit("writer ids must be unique")

missing = sorted(stage6_owner_paths - owner_paths)
if missing:
    raise SystemExit("catalog lifecycle writer inventory missing Stage 6 service owners: " + ", ".join(missing))
missing_ids = sorted(expected_stage6_writer_ids - stage6_writer_ids)
if missing_ids:
    raise SystemExit("catalog lifecycle writer inventory missing Stage 6 writer ids: " + ", ".join(missing_ids))
unexpected_ids = sorted(stage6_writer_ids - expected_stage6_writer_ids)
if unexpected_ids:
    raise SystemExit("catalog lifecycle writer inventory has unexpected Stage 6 writer ids: " + ", ".join(unexpected_ids))
PY
}

json_field() {
    local payload="$1"
    local field="$2"

    python3 - "$payload" "$field" <<'PY'
import json
import sys

payload, field = sys.argv[1:]
try:
    value = json.loads(payload).get(field)
except json.JSONDecodeError:
    raise SystemExit(1)
if value is None:
    raise SystemExit(1)
print(value)
PY
}

canonical_json() {
    local payload="$1"

    python3 - "$payload" <<'PY'
import json
import sys

try:
    value = json.loads(sys.argv[1])
except json.JSONDecodeError as exc:
    raise SystemExit(f"response is not structured JSON: {exc}")
print(json.dumps(value, separators=(",", ":"), sort_keys=True))
PY
}

capture_response() {
    local method="$1"
    local url="$2"
    shift 2

    local response
    response="$(curl -sS -X "$method" "$@" -w '\n%{http_code}' "$url")" \
        || die "$method $url failed"
    HTTP_RESPONSE_CODE="${response##*$'\n'}"
    HTTP_RESPONSE_BODY="${response%$'\n'*}"
}

expect_status() {
    local label="$1"
    local expected="$2"

    if [ "$HTTP_RESPONSE_CODE" != "$expected" ]; then
        die "$label expected HTTP $expected, got $HTTP_RESPONSE_CODE: $HTTP_RESPONSE_BODY"
    fi
}

restore_status_from_response() {
    local label="$1"
    local status=""

    case "$HTTP_RESPONSE_CODE" in
        202)
            status="$(json_field "$HTTP_RESPONSE_BODY" status 2>/dev/null || true)"
            [ "$status" = "queued" ] || [ "$status" = "accepted" ] \
                || die "$label returned unexpected accepted status"
            ;;
        409)
            status="$(json_field "$HTTP_RESPONSE_BODY" error 2>/dev/null || true)"
            [ "$status" = "destination_conflict" ] || [ "$status" = "destination_changed" ] \
                || die "$label returned unexpected conflict reason"
            ;;
        *)
            die "$label expected HTTP 202/409, got $HTTP_RESPONSE_CODE: $HTTP_RESPONSE_BODY"
            ;;
    esac

    printf '%s\n' "$status"
}

tenant_call() {
    local method="$1"
    local path="$2"
    local token="$3"
    shift 3

    capture_response "$method" "${API_URL}${path}" \
        -H "authorization: Bearer ${token}" \
        "$@"
}

admin_call() {
    local method="$1"
    local path="$2"
    shift 2

    capture_response "$method" "${API_URL}${path}" \
        -H "x-admin-key: ${PROBE_ADMIN_KEY}" \
        "$@"
}

run_probe_psql() {
    init_integration_env_defaults
    if ! init_integration_db_access; then
        if [ -n "${INTEGRATION_DB_ACCESS_FAILURE_HINT:-}" ]; then
            die "$INTEGRATION_DB_ACCESS_FAILURE_HINT"
        fi
        die "integration database access is unavailable"
    fi
    run_integration_psql "$PROBE_INTEGRATION_DB" "$@"
}

catalog_cold_seed_sql() {
    cat <<'SQL'
-- catalog_service_window_cold_seed: local-only fixture setup for restore-route preconditions.
WITH target_tenant AS (
    SELECT customer_id, tenant_id, vm_id
    FROM customer_tenants
    WHERE customer_id = :'probe_customer_id'::uuid
      AND tenant_id = :'probe_index'
),
source_vm AS (
    SELECT COALESCE(
        (SELECT vm_id FROM target_tenant WHERE vm_id IS NOT NULL),
        NULLIF(:'dest_vm_id', '')::uuid,
        (SELECT id FROM vm_inventory WHERE status = 'active' ORDER BY created_at LIMIT 1)
    ) AS id
),
updated_snapshot AS (
    UPDATE cold_snapshots
    SET status = 'completed',
        error = NULL,
        size_bytes = GREATEST(size_bytes, 1),
        checksum = COALESCE(checksum, 'catalog-service-window-probe'),
        completed_at = COALESCE(completed_at, NOW()),
        expires_at = NULL
    WHERE customer_id = (SELECT customer_id FROM target_tenant)
      AND tenant_id = (SELECT tenant_id FROM target_tenant)
      AND status IN ('pending', 'exporting', 'completed')
    RETURNING id
),
inserted_snapshot AS (
    INSERT INTO cold_snapshots (
        customer_id,
        tenant_id,
        source_vm_id,
        object_key,
        size_bytes,
        checksum,
        status,
        completed_at
    )
    SELECT
        target_tenant.customer_id,
        target_tenant.tenant_id,
        source_vm.id,
        :'object_key',
        1,
        'catalog-service-window-probe',
        'completed',
        NOW()
    FROM target_tenant
    CROSS JOIN source_vm
    WHERE source_vm.id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM updated_snapshot)
    RETURNING id
),
selected_snapshot AS (
    SELECT id FROM updated_snapshot
    UNION ALL
    SELECT id FROM inserted_snapshot
    LIMIT 1
),
updated_tenant AS (
    UPDATE customer_tenants
    SET tier = 'cold',
        cold_snapshot_id = (SELECT id FROM selected_snapshot),
        vm_id = NULL
    WHERE customer_id = :'probe_customer_id'::uuid
      AND tenant_id = :'probe_index'
      AND EXISTS (SELECT 1 FROM selected_snapshot)
    RETURNING cold_snapshot_id
)
SELECT CASE
    WHEN EXISTS (SELECT 1 FROM updated_tenant) THEN 'seeded'
    ELSE 'missing_probe_tenant_or_snapshot'
END;
SQL
}

seed_cold_snapshot_for_restore() {
    local restore_index="$1"
    local object_key="cold/${PROBE_REGION}/catalog-service-window/${PROBE_CUSTOMER_ID}/${restore_index}.snapshot"
    local seed_result

    seed_result="$(
        catalog_cold_seed_sql | run_probe_psql -v ON_ERROR_STOP=1 -tA \
            -v probe_customer_id="$PROBE_CUSTOMER_ID" \
            -v probe_index="$restore_index" \
            -v dest_vm_id="$PROBE_DEST_VM_ID" \
            -v object_key="$object_key"
    )" || die "local cold snapshot seed failed"

    [ "$seed_result" = "seeded" ] \
        || die "local cold snapshot seed did not update the probe tenant: $seed_result"
}

discover_destination_vm() {
    if [ -n "$PROBE_DEST_VM_ID" ]; then
        return 0
    fi

    admin_call POST "/admin/tenants/${PROBE_CUSTOMER_ID}/indexes" \
        -H "content-type: application/json" \
        -d "{\"name\":\"${PROBE_DEST_SEED_INDEX}\",\"region\":\"${PROBE_REPLICA_REGION}\",\"flapjack_url\":\"${PROBE_ENGINE_URL}\"}"
    if [ "$HTTP_RESPONSE_CODE" != "201" ] && [ "$HTTP_RESPONSE_CODE" != "200" ] && [ "$HTTP_RESPONSE_CODE" != "409" ]; then
        die "destination VM seed expected HTTP 201/200/409, got $HTTP_RESPONSE_CODE: $HTTP_RESPONSE_BODY"
    fi

    admin_call GET "/admin/vms"
    expect_status "destination VM inventory list" "200"
    PROBE_DEST_VM_ID="$(
        python3 - "$HTTP_RESPONSE_BODY" "$PROBE_REPLICA_REGION" "$PROBE_ENGINE_URL" <<'PY'
import json
import sys

payload, region, flapjack_url = sys.argv[1:]
try:
    vms = json.loads(payload)
except json.JSONDecodeError as exc:
    raise SystemExit(f"admin VM list response is not structured JSON: {exc}")
matches = [
    vm
    for vm in vms
    if isinstance(vm, dict)
    and vm.get("region") == region
    and vm.get("flapjack_url") == flapjack_url
    and isinstance(vm.get("id"), str)
]
if len(matches) != 1:
    raise SystemExit(f"expected exactly one destination VM for region {region} and {flapjack_url}, got {len(matches)}")
print(matches[0]["id"])
PY
    )" || die "destination VM inventory did not contain a unique seeded VM"
}

seed_probe_index() {
    local token="$1"
    local index_name="$2"

    tenant_call POST "/indexes" "$token" \
        -H "content-type: application/json" \
        -d "{\"name\":\"${index_name}\",\"region\":\"${PROBE_REGION}\"}"
    if [ "$HTTP_RESPONSE_CODE" != "201" ] && [ "$HTTP_RESPONSE_CODE" != "200" ] && [ "$HTTP_RESPONSE_CODE" != "409" ]; then
        die "index create expected HTTP 201/200/409, got $HTTP_RESPONSE_CODE: $HTTP_RESPONSE_BODY"
    fi

    tenant_call POST "/indexes/${index_name}/batch" "$token" \
        -H "content-type: application/json" \
        -d "{\"requests\":[{\"action\":\"addObject\",\"body\":{\"objectID\":\"catalog-service-window-doc-1\",\"title\":\"Catalog lifecycle service window probe\"}}]}"
    expect_status "source document seed" "200"
}

prepare_destination_replica() {
    tenant_call POST "/indexes/${PROBE_INDEX}/replicas" "$1" \
        -H "content-type: application/json" \
        -d "{\"region\":\"${PROBE_REPLICA_REGION}\"}"
    if [ "$HTTP_RESPONSE_CODE" != "201" ] && [ "$HTTP_RESPONSE_CODE" != "200" ] && [ "$HTTP_RESPONSE_CODE" != "409" ]; then
        die "destination replica prepare expected HTTP 201/200/409, got $HTTP_RESPONSE_CODE: $HTTP_RESPONSE_BODY"
    fi
}

cold_snapshot_id_for_tenant() {
    python3 - "$1" "$2" "$3" <<'PY'
import json
import sys

payload, customer_id, tenant_id = sys.argv[1:]
try:
    entries = json.loads(payload)
except json.JSONDecodeError as exc:
    raise SystemExit(f"admin cold list response is not structured JSON: {exc}")
matches = []
for entry in entries:
    if not isinstance(entry, dict):
        continue
    if entry.get("customer_id") != customer_id or entry.get("tenant_id") != tenant_id:
        continue
    snapshot_id = entry.get("snapshot_id")
    if isinstance(snapshot_id, str) and snapshot_id:
        matches.append(snapshot_id)
if len(matches) != 1:
    raise SystemExit(
        "admin cold list expected exactly one snapshot for "
        f"customer_id={customer_id} tenant_id={tenant_id}, got {len(matches)}"
    )
print(matches[0])
PY
}

require_probe_replica_row() {
    python3 - "$1" "$PROBE_REPLICA_REGION" <<'PY'
import json
import sys

payload, replica_region = sys.argv[1:]
try:
    entries = json.loads(payload)
except json.JSONDecodeError as exc:
    raise SystemExit(f"replica list response is not structured JSON: {exc}")
if not isinstance(entries, list):
    raise SystemExit("replica list response must be an array")
for entry in entries:
    if not isinstance(entry, dict):
        continue
    if entry.get("replica_region") == replica_region and entry.get("status") in {"provisioning", "syncing", "active", "replicating"}:
        raise SystemExit(0)
raise SystemExit("replica list missing probe row")
PY
}

require_admin_replica_row() {
    python3 - "$1" "$PROBE_CUSTOMER_ID" "$PROBE_INDEX" "$PROBE_REPLICA_REGION" <<'PY'
import json
import sys

payload, customer_id, tenant_id, replica_region = sys.argv[1:]
try:
    entries = json.loads(payload)
except json.JSONDecodeError as exc:
    raise SystemExit(f"admin replica list response is not structured JSON: {exc}")
if not isinstance(entries, list):
    raise SystemExit("admin replica list response must be an array")
for entry in entries:
    if not isinstance(entry, dict):
        continue
    if (
        entry.get("customer_id") == customer_id
        and entry.get("tenant_id") == tenant_id
        and entry.get("replica_region") == replica_region
        and entry.get("status") in {"provisioning", "syncing", "active", "replicating"}
    ):
        raise SystemExit(0)
raise SystemExit("admin replica list missing probe row")
PY
}

require_migration_row() {
    local payload="$1"
    local expected_status="$2"

    python3 - "$payload" "$PROBE_CUSTOMER_ID" "$PROBE_MIGRATION_INDEX" "$PROBE_DEST_VM_ID" "$expected_status" <<'PY'
import json
import sys

payload, customer_id, index_name, dest_vm_id, expected_status = sys.argv[1:]
try:
    entries = json.loads(payload)
except json.JSONDecodeError as exc:
    raise SystemExit(f"migration list response is not structured JSON: {exc}")
if not isinstance(entries, list):
    raise SystemExit("migration list response must be an array")
for entry in entries:
    if not isinstance(entry, dict):
        continue
    if (
        entry.get("customer_id") == customer_id
        and entry.get("index_name") == index_name
        and entry.get("dest_vm_id") == dest_vm_id
        and entry.get("status") == expected_status
    ):
        raise SystemExit(0)
raise SystemExit("migration list missing probe row")
PY
}

emit_success() {
    python3 - "$INVENTORY_DISPLAY" "$1" "$2" "$3" "$4" "$5" <<'PY'
import json
import sys

inventory, replica, customer_restore, admin_restore, rollback, failure = sys.argv[1:]
print(json.dumps({
    "status": "pass",
    "inventory": inventory,
    "replica_create_status": replica,
    "customer_restore_status": customer_restore,
    "admin_restore_status": admin_restore,
    "rollback_status": rollback,
    "failure_status": failure,
}, separators=(",", ":"), sort_keys=True))
PY
}

register_isolation_tenant() {
    capture_response POST "${API_URL}/auth/register" \
        -H "content-type: application/json" \
        -d "{\"name\":\"Catalog Service Window Isolation\",\"email\":\"${ISOLATION_EMAIL}\",\"password\":\"${ISOLATION_PASSWORD}\"}"
    case "$HTTP_RESPONSE_CODE" in
        201|409) ;;
        *) die "unrelated tenant auth register expected HTTP 201 or existing-account 409, got ${HTTP_RESPONSE_CODE}" ;;
    esac

    capture_response POST "${API_URL}/auth/login" \
        -H "content-type: application/json" \
        -d "{\"email\":\"${ISOLATION_EMAIL}\",\"password\":\"${ISOLATION_PASSWORD}\"}"
    expect_status "unrelated tenant auth login" "200"
    ISOLATION_TOKEN="$(json_field "$HTTP_RESPONSE_BODY" token)" \
        || die "unrelated tenant auth login response missing token"
    ISOLATION_CUSTOMER_ID="$(json_field "$HTTP_RESPONSE_BODY" customer_id)" \
        || die "unrelated tenant auth login response missing customer_id"

    tenant_call POST "/indexes" "$ISOLATION_TOKEN" \
        -H "content-type: application/json" \
        -d "{\"name\":\"${PROBE_INDEX}\",\"region\":\"${PROBE_REGION}\"}"
    case "$HTTP_RESPONSE_CODE" in
        201|409) ;;
        *) die "unrelated same-name index create expected HTTP 201 or existing-index 409, got ${HTTP_RESPONSE_CODE}" ;;
    esac
    tenant_call GET "/indexes/${PROBE_INDEX}" "$ISOLATION_TOKEN"
    expect_status "unrelated tenant snapshot before primary flow" "200"
    UNRELATED_STATE_BEFORE="$(canonical_json "$HTTP_RESPONSE_BODY")" \
        || die "unrelated tenant state before primary flow was not structured JSON"
}

register_probe_tenant() {
    local isolation_customer_id="$1"
    capture_response POST "${API_URL}/auth/register" \
        -H "content-type: application/json" \
        -d "{\"name\":\"Catalog Service Window Probe\",\"email\":\"${PROBE_EMAIL}\",\"password\":\"${PROBE_PASSWORD}\"}"
    case "$HTTP_RESPONSE_CODE" in
        201|409) ;;
        *) die "auth register expected HTTP 201 or existing-account 409, got ${HTTP_RESPONSE_CODE}" ;;
    esac

    capture_response POST "${API_URL}/auth/login" \
        -H "content-type: application/json" \
        -d "{\"email\":\"${PROBE_EMAIL}\",\"password\":\"${PROBE_PASSWORD}\"}"
    expect_status "auth login" "200"
    PROBE_TOKEN="$(json_field "$HTTP_RESPONSE_BODY" token)" \
        || die "auth login response missing token"
    PROBE_CUSTOMER_ID="$(json_field "$HTTP_RESPONSE_BODY" customer_id)" \
        || die "auth login response missing customer_id"
    [ "$PROBE_CUSTOMER_ID" != "$isolation_customer_id" ] \
        || die "probe and unrelated tenant customer IDs must differ"
}

exercise_replica_and_restore_windows() {
    local snapshot_id

    seed_probe_index "$PROBE_TOKEN" "$PROBE_INDEX"
    discover_destination_vm

    prepare_destination_replica "$PROBE_TOKEN"
    REPLICA_STATUS="$(json_field "$HTTP_RESPONSE_BODY" status 2>/dev/null || true)"
    [ -n "$REPLICA_STATUS" ] || REPLICA_STATUS="conflict"

    tenant_call GET "/indexes/${PROBE_INDEX}/replicas" "$PROBE_TOKEN"
    expect_status "replica list" "200"
    require_probe_replica_row "$HTTP_RESPONSE_BODY" \
        || die "replica list missing probe row"

    seed_cold_snapshot_for_restore "$PROBE_INDEX"
    tenant_call POST "/indexes/${PROBE_INDEX}/restore" "$PROBE_TOKEN"
    CUSTOMER_RESTORE_STATUS="$(restore_status_from_response "customer restore")"

    seed_probe_index "$PROBE_TOKEN" "$PROBE_ADMIN_RESTORE_INDEX"
    seed_cold_snapshot_for_restore "$PROBE_ADMIN_RESTORE_INDEX"
    admin_call GET "/admin/cold"
    expect_status "admin cold list" "200"
    snapshot_id="$(cold_snapshot_id_for_tenant "$HTTP_RESPONSE_BODY" "$PROBE_CUSTOMER_ID" "$PROBE_ADMIN_RESTORE_INDEX")" \
        || die "admin cold list did not expose the probe admin restore snapshot_id"

    admin_call POST "/admin/cold/${snapshot_id}/restore"
    ADMIN_RESTORE_STATUS="$(restore_status_from_response "admin cold restore")"
}

exercise_migration_windows() {
    seed_probe_index "$PROBE_TOKEN" "$PROBE_MIGRATION_INDEX"

    admin_call POST "/admin/migrations/probe/rollback-after-replication" \
        -H "content-type: application/json" \
        -d "{\"customer_id\":\"${PROBE_CUSTOMER_ID}\",\"index_name\":\"${PROBE_MIGRATION_INDEX}\",\"dest_vm_id\":\"${PROBE_DEST_VM_ID}\"}"
    if [ "$HTTP_RESPONSE_CODE" = "403" ]; then
        die "recovery seams forbidden outside local probe stack"
    fi
    expect_status "admin probe rollback after replication" "200"
    ROLLBACK_STATUS="$(json_field "$HTTP_RESPONSE_BODY" status 2>/dev/null || true)"
    [ "$ROLLBACK_STATUS" = "rolled_back" ] \
        || die "admin probe rollback after replication expected rolled_back status"

    admin_call POST "/admin/migrations/probe/failure-after-replication" \
        -H "content-type: application/json" \
        -d "{\"customer_id\":\"${PROBE_CUSTOMER_ID}\",\"index_name\":\"${PROBE_MIGRATION_INDEX}\",\"dest_vm_id\":\"${PROBE_DEST_VM_ID}\"}"
    expect_status "admin probe failure after replication" "200"
    FAILURE_STATUS="$(json_field "$HTTP_RESPONSE_BODY" status 2>/dev/null || true)"
    [ "$FAILURE_STATUS" = "failed" ] \
        || die "admin probe failure after replication expected failed status"

    admin_call GET "/admin/migrations?status=active&limit=10"
    expect_status "admin migration active list" "200"
    admin_call GET "/admin/migrations?status=rolled_back&limit=10"
    expect_status "admin migration rolled_back list" "200"
    require_migration_row "$HTTP_RESPONSE_BODY" "rolled_back" \
        || die "migration list missing probe row"
    admin_call GET "/admin/migrations?status=failed&limit=10"
    expect_status "admin migration failed list" "200"
    require_migration_row "$HTTP_RESPONSE_BODY" "failed" \
        || die "migration list missing probe row"
    admin_call GET "/admin/replicas"
    expect_status "admin replica list" "200"
    require_admin_replica_row "$HTTP_RESPONSE_BODY" \
        || die "admin replica list missing probe row"
}

verify_unrelated_tenant_unchanged() {
    local unrelated_state_after
    tenant_call GET "/indexes/${PROBE_INDEX}" "$ISOLATION_TOKEN"
    expect_status "unrelated tenant snapshot after primary flow" "200"
    unrelated_state_after="$(canonical_json "$HTTP_RESPONSE_BODY")" \
        || die "unrelated tenant state after primary flow was not structured JSON"
    [ "$unrelated_state_after" = "$UNRELATED_STATE_BEFORE" ] \
        || die "unrelated tenant state changed"
}

drive_service_window_entrypoints() {
    register_isolation_tenant
    register_probe_tenant "$ISOLATION_CUSTOMER_ID"
    exercise_replica_and_restore_windows
    exercise_migration_windows
    verify_unrelated_tenant_unchanged
    emit_success "$REPLICA_STATUS" "$CUSTOMER_RESTORE_STATUS" "$ADMIN_RESTORE_STATUS" "$ROLLBACK_STATUS" "$FAILURE_STATUS"
}

validate_catalog_inventory

if [ "$START_STACK" -eq 1 ]; then
    STACK_STARTED=1
    FJCLOUD_INTEGRATION_API_BINARY="$API_BINARY" \
    FJCLOUD_INTEGRATION_ENGINE_BINARY="$ENGINE_BINARY" \
    FJCLOUD_INTEGRATION_SKIP_METERING_AGENT=1 \
    FJCLOUD_INTEGRATION_PID_DIR="$RUNTIME_DIR" \
    ENGINE_INDEX_IDENTITY_OBSERVED_CALLERS_FILE="$OBSERVED_CALLERS_FILE" \
    FJCLOUD_INTEGRATION_API_RECOVERY_SEAMS=1 \
    ENVIRONMENT=local \
    SKIP_EMAIL_VERIFICATION=1 \
    ADMIN_KEY="$PROBE_ADMIN_KEY" \
    FLAPJACK_ADMIN_KEY="$PROBE_NODE_API_KEY" \
    API_PORT="$API_PORT" \
    FLAPJACK_PORT="$FLAPJACK_PORT" \
    INTEGRATION_DB="$PROBE_INTEGRATION_DB" \
    bash "$SCRIPT_DIR/integration-up.sh"
fi

drive_service_window_entrypoints
