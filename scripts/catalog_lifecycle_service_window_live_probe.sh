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
DEFAULT_ORACLE="$REPO_ROOT/scripts/tests/fixtures/catalog_lifecycle_acceptance_oracles.json"
DEFAULT_ORACLE_DISPLAY="scripts/tests/fixtures/catalog_lifecycle_acceptance_oracles.json"

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
  oracle scripts/tests/fixtures/catalog_lifecycle_acceptance_oracles.json

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
  CATALOG_LIFECYCLE_SERVICE_WINDOW_HARD_ERASE_EMAIL
  CATALOG_LIFECYCLE_SERVICE_WINDOW_HARD_ERASE_PASSWORD
  CATALOG_LIFECYCLE_SERVICE_WINDOW_RUNTIME_DIR
  CATALOG_LIFECYCLE_SERVICE_WINDOW_API_BUILD_ROOT
  CATALOG_LIFECYCLE_SERVICE_WINDOW_ENGINE_BUILD_ROOT
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

canonical_path() {
    python3 - "$1" <<'PY'
import pathlib
import sys

print(pathlib.Path(sys.argv[1]).resolve(strict=False))
PY
}

path_is_under_target_debug() {
    local path="$1"
    local root="$2"
    [ -n "$root" ] || return 1

    python3 - "$path" "$root" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1]).resolve(strict=False)
target_debug = pathlib.Path(sys.argv[2]).resolve(strict=False) / "target" / "debug"
try:
    path.relative_to(target_debug)
except ValueError:
    raise SystemExit(1)
raise SystemExit(0)
PY
}

require_source_built_binary() {
    local label="$1"
    local path="$2"
    shift 2

    local resolved
    resolved="$(canonical_path "$path")"
    local root
    for root in "$@"; do
        path_is_under_target_debug "$resolved" "$root" && return 0
    done

    die "$label must resolve under source-built target/debug output"
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
require_file "catalog lifecycle acceptance oracle" "$DEFAULT_ORACLE"
require_source_built_binary "--api-binary" "$API_BINARY" \
    "${CATALOG_LIFECYCLE_SERVICE_WINDOW_API_BUILD_ROOT:-$REPO_ROOT/infra}"
require_source_built_binary "--engine-binary" "$ENGINE_BINARY" \
    "${CATALOG_LIFECYCLE_SERVICE_WINDOW_ENGINE_BUILD_ROOT:-${FLAPJACK_DEV_DIR:-$REPO_ROOT/../flapjack_dev}}" \
    "${FLAPJACK_DEV_DIR:-$REPO_ROOT/../flapjack_dev}/engine"

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
PROBE_EXPIRED_CLAIM_INDEX="${PROBE_INDEX}_expired_claim"
PROBE_REGION="${CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_REGION:-us-east-1}"
PROBE_REPLICA_REGION="${CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_REPLICA_REGION:-eu-central-1}"
PROBE_DEST_VM_ID="${CATALOG_LIFECYCLE_SERVICE_WINDOW_DEST_VM_ID:-}"
PROBE_DEST_SEED_INDEX="${CATALOG_LIFECYCLE_SERVICE_WINDOW_DEST_SEED_INDEX:-catalog_service_window_destination_seed}"
PROBE_ENGINE_URL="${CATALOG_LIFECYCLE_SERVICE_WINDOW_ENGINE_URL:-http://127.0.0.1:${FLAPJACK_PORT}}"
PROBE_ADMIN_KEY="${CATALOG_LIFECYCLE_SERVICE_WINDOW_ADMIN_KEY:-catalog-service-window-admin-key}"
PROBE_NODE_API_KEY="${CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_NODE_API_KEY:-catalog-service-window-node-api-key}"
ISOLATION_EMAIL="${CATALOG_LIFECYCLE_SERVICE_WINDOW_ISOLATION_EMAIL:-service-window-isolation@example.com}"
ISOLATION_PASSWORD="${CATALOG_LIFECYCLE_SERVICE_WINDOW_ISOLATION_PASSWORD:-Integration-Isolation-Pass-1!}"
# Soft-delete generation-fence scenario: dedicated customers, seeded at
# generation G, deleted only through the real API routes. The account arm proves
# `routes/account.rs::delete_account`; the admin arm proves
# `routes/admin/tenants.rs::delete_tenant`. Both map back to the single F5P1
# inventory denominator in the final evidence.
SOFT_DELETE_FENCE_GENERATION="${CATALOG_LIFECYCLE_SERVICE_WINDOW_SOFT_DELETE_GENERATION:-5}"
SOFT_DELETE_ACCOUNT_EMAIL="${CATALOG_LIFECYCLE_SERVICE_WINDOW_SOFT_DELETE_ACCOUNT_EMAIL:-service-window-soft-delete-account@example.com}"
SOFT_DELETE_ACCOUNT_PASSWORD="${CATALOG_LIFECYCLE_SERVICE_WINDOW_SOFT_DELETE_ACCOUNT_PASSWORD:-Integration-Soft-Delete-Account-1!}"
SOFT_DELETE_ACCOUNT_INDEX="${PROBE_INDEX}_soft_delete_account"
SOFT_DELETE_ADMIN_EMAIL="${CATALOG_LIFECYCLE_SERVICE_WINDOW_SOFT_DELETE_ADMIN_EMAIL:-service-window-soft-delete-admin@example.com}"
SOFT_DELETE_ADMIN_PASSWORD="${CATALOG_LIFECYCLE_SERVICE_WINDOW_SOFT_DELETE_ADMIN_PASSWORD:-Integration-Soft-Delete-Admin-1!}"
SOFT_DELETE_ADMIN_INDEX="${PROBE_INDEX}_soft_delete_admin"
SOFT_DELETE_STALE_EMAIL="${CATALOG_LIFECYCLE_SERVICE_WINDOW_SOFT_DELETE_STALE_EMAIL:-service-window-soft-delete-stale@example.com}"
SOFT_DELETE_STALE_PASSWORD="${CATALOG_LIFECYCLE_SERVICE_WINDOW_SOFT_DELETE_STALE_PASSWORD:-Integration-Soft-Delete-Stale-1!}"
SOFT_DELETE_STALE_INDEX="${PROBE_INDEX}_soft_delete_stale"
HARD_ERASE_EMAIL="${CATALOG_LIFECYCLE_SERVICE_WINDOW_HARD_ERASE_EMAIL:-service-window-hard-erase@example.com}"
HARD_ERASE_PASSWORD="${CATALOG_LIFECYCLE_SERVICE_WINDOW_HARD_ERASE_PASSWORD:-Integration-Hard-Erase-1!}"
HARD_ERASE_INDEX="${PROBE_INDEX}_hard_erase"
HARD_ERASE_CUSTOMER_ID=""
HARD_ERASE_TOKEN=""
HARD_ERASE_SEEDED_IDS=""
HARD_ERASE_SNAPSHOT=""
HARD_ERASE_EVIDENCE=""
HARD_ERASE_SEEDED_COUNT=""
HARD_ERASE_RETAINED_COUNT=""
HARD_ERASE_STATUS=""
SOFT_DELETE_STALE_NEW_ADMISSION_STATUS=""
SOFT_DELETE_STALE_REPLAY_ADMISSION_STATUS=""
SOFT_DELETE_STALE_CANCEL_STATUS=""
SOFT_DELETE_STALE_RESUME_STATUS=""
SOFT_DELETE_STALE_ELAPSED_RESUME_CLAIM_STATUS=""
SOFT_DELETE_STALE_STATE_UPDATE_STATUS=""
SOFT_DELETE_STALE_TERMINAL_ACK_STATUS=""
SOFT_DELETE_STALE_TERMINAL_FINALIZATION_STATUS=""
SOFT_DELETE_STALE_RETENTION_GC_STATUS=""
SOFT_DELETE_STALE_ACTIVE_RESERVATION_STATUS=""
SOFT_DELETE_STALE_RESUME_INTENT_STATUS=""
SOFT_DELETE_ACCOUNT_STATUS=""
SOFT_DELETE_ADMIN_STATUS=""
SOFT_DELETE_ACCOUNT_HIDDEN=""
SOFT_DELETE_ADMIN_HIDDEN=""
SOFT_DELETE_ARM_TOKEN=""
SOFT_DELETE_ARM_CUSTOMER_ID=""
SOFT_DELETE_ARM_PASSWORD=""
SOFT_DELETE_LAST_STATUS=""
SOFT_DELETE_LAST_HIDDEN=""
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
EXPIRED_ROUTE_STATUS=""
EXPIRED_SERVICE_STATUS=""
PROHIBITED_ENGINE_OBSERVATIONS=""
SELECTED_EVIDENCE_TEMPLATE=""
STACK_STARTED=0
HTTP_RESPONSE_BODY=""
HTTP_RESPONSE_CODE=""

[ -n "$PROBE_NODE_API_KEY" ] || die "probe node API key must not be empty"

if [ "$START_STACK" -eq 0 ]; then
    case "$PROBE_INTEGRATION_DB" in
        catalog_service_window_live_probe*) ;;
        *) die "--no-start-stack requires INTEGRATION_DB to name a dedicated catalog service window database" ;;
    esac
    case "$RUNTIME_DIR" in
        *catalog-service-window*|*catalog_service_window*|*service-window*) ;;
        *) die "--no-start-stack requires a dedicated catalog service window runtime dir" ;;
    esac
fi

cleanup() {
    if [ "$STACK_STARTED" -eq 1 ]; then
        FJCLOUD_INTEGRATION_PID_DIR="$RUNTIME_DIR" \
            INTEGRATION_DB="$PROBE_INTEGRATION_DB" \
            bash "$SCRIPT_DIR/integration-down.sh" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

validate_catalog_acceptance_fixtures() {
    python3 - "$INVENTORY" "$DEFAULT_INVENTORY" "$DEFAULT_ORACLE" "$DEFAULT_ORACLE_DISPLAY" "$REPO_ROOT" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
default_path = pathlib.Path(sys.argv[2])
oracle_path = pathlib.Path(sys.argv[3])
oracle_display = sys.argv[4]
repo_root = pathlib.Path(sys.argv[5])
canonical_oracle_path = repo_root / oracle_display

def reject_duplicate_object_keys(label, pairs):
    seen = set()
    value = {}
    for key, child in pairs:
        if key in seen:
            raise ValueError(f"{label} must not repeat object key {key}")
        seen.add(key)
        value[key] = child
    return value

def load_json(label, source):
    try:
        with source.open(encoding="utf-8") as handle:
            return json.load(
                handle,
                object_pairs_hook=lambda pairs: reject_duplicate_object_keys(label, pairs),
            )
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        raise SystemExit(f"{label} is not readable structured JSON: {exc}")

def require_canonical(label, actual, expected):
    try:
        canonical_actual = actual.resolve(strict=True)
        canonical_expected = expected.resolve(strict=True)
    except OSError as exc:
        raise SystemExit(f"{label} canonical path check failed: {exc}")
    if canonical_actual != canonical_expected:
        raise SystemExit(f"{label} must use the canonical {label.split()[-1]} path")

def require_exact_keys(label, value, expected):
    if not isinstance(value, dict):
        raise SystemExit(f"{label} must be an object")
    actual = set(value)
    expected = set(expected)
    unknown = sorted(actual - expected)
    missing = sorted(expected - actual)
    if unknown:
        raise SystemExit(f"{label} has unknown fields: " + ", ".join(unknown))
    if missing:
        raise SystemExit(f"{label} missing required fields: " + ", ".join(missing))

inventory = load_json("catalog lifecycle writer inventory", path)
oracles = load_json("catalog lifecycle acceptance oracle", oracle_path)

expected_oracles = {
    "block_without_change": {
        "leased_behavior": "refuse_without_mutation",
        "release_trigger": "engine_ack",
    },
    "privacy_transition": {
        "soft_delete": "mark_deleted_bump_generation_fence_future_writes",
        "hard_delete": "purge_dependents_then_target",
        "reaper_scrub": "reaper_scrubs_catalog_target_after_hard_delete",
    },
}
require_exact_keys(
    "catalog lifecycle acceptance oracle",
    oracles,
    {"version", "oracle_kind", "lane_composition", "oracles"},
)
lane_composition = oracles.get("lane_composition")
require_exact_keys(
    "catalog lifecycle acceptance oracle lane_composition",
    lane_composition,
    {
        "execute_every_inventoried_caller_before_route_activation",
        "missing_dependency_disposition",
    },
)
if lane_composition.get("execute_every_inventoried_caller_before_route_activation") is not True:
    raise SystemExit("catalog lifecycle acceptance oracle lane composition must execute every caller")
if lane_composition.get("missing_dependency_disposition") != "failure":
    raise SystemExit("catalog lifecycle acceptance oracle lane composition must fail missing dependencies")
if oracles.get("version") != 1:
    raise SystemExit("catalog lifecycle acceptance oracle requires version 1")
if oracles.get("oracle_kind") != "catalog_lifecycle_acceptance":
    raise SystemExit("catalog lifecycle acceptance oracle_kind drifted")
oracle_classes = oracles.get("oracles")
if not isinstance(oracle_classes, dict) or set(oracle_classes) != set(expected_oracles):
    raise SystemExit("catalog lifecycle acceptance oracle classes drifted")
for oracle_class, expected_fields in expected_oracles.items():
    actual_fields = oracle_classes.get(oracle_class)
    if not isinstance(actual_fields, dict):
        raise SystemExit("catalog lifecycle acceptance oracle behavior drifted")
    require_exact_keys(
        f"catalog lifecycle acceptance oracle {oracle_class}",
        actual_fields,
        {"summary", *expected_fields},
    )
    for field, expected in expected_fields.items():
        if actual_fields.get(field) != expected:
            raise SystemExit("catalog lifecycle acceptance oracle behavior drifted")
require_canonical("catalog lifecycle acceptance oracle", oracle_path, canonical_oracle_path)

try:
    inventory_version = inventory.get("version")
except AttributeError:
    raise SystemExit("catalog lifecycle writer inventory requires version 1")
if inventory_version != 1:
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
    disposition = writer.get("disposition")
    if sum(1 for oracle_class in oracle_classes if oracle_class == disposition) != 1:
        raise SystemExit(
            "catalog lifecycle writer inventory writer disposition does not resolve to exactly one oracle: "
            + str(disposition)
        )
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

soft_delete_contracts = {
    "repository": (
        "catalog_writer__infra_api_src_repos_pg_customer_repo_lifecycle__soft_delete__pg_customer_repo_soft_delete",
        "infra/api/src/repos/pg_customer_repo/lifecycle.rs",
        "pg_customer_repo.soft_delete",
    ),
    "account route": (
        "catalog_writer__infra_api_src_routes_account__delete_account__customer_repo_soft_delete",
        "infra/api/src/routes/account.rs",
        "customer_repo.soft_delete",
    ),
    "admin tenant route": (
        "catalog_writer__infra_api_src_routes_admin_tenants__delete_tenant__customer_repo_soft_delete",
        "infra/api/src/routes/admin/tenants.rs",
        "customer_repo.soft_delete",
    ),
}

def select_soft_delete_writer(label, expected_id, owner_path, source_anchor):
    matches = [
        writer for writer in writers
        if writer.get("owner_path") == owner_path
        and writer.get("source_anchor") == source_anchor
        and writer.get("disposition") == "privacy_transition"
    ]
    if not matches:
        raise SystemExit("catalog lifecycle writer inventory missing F5P1 soft-delete writers: " + expected_id)
    if len(matches) != 1:
        raise SystemExit(
            f"catalog lifecycle writer inventory expected exactly one F5P1 soft-delete writer "
            f"for {owner_path}::{source_anchor}, got {len(matches)}"
        )
    if matches[0].get("id") != expected_id:
        raise SystemExit(f"catalog lifecycle writer inventory {label} F5P1 soft-delete writer id drifted")
    return matches[0]

soft_delete_writers = [
    select_soft_delete_writer(label, *contract)
    for label, contract in soft_delete_contracts.items()
]

def select_blocking_writer(label, owner_path, source_anchor):
    matches = [
        writer for writer in writers
        if writer.get("owner_path") == owner_path
        and writer.get("source_anchor") == source_anchor
        and writer.get("disposition") == "block_without_change"
    ]
    if len(matches) != 1:
        raise SystemExit(
            f"catalog lifecycle writer inventory expected exactly one {label} "
            f"block_without_change writer for {owner_path}::{source_anchor}, got {len(matches)}"
        )
    return matches[0]

def select_privacy_writer(label, owner_path, source_anchor):
    matches = [
        writer for writer in writers
        if writer.get("owner_path") == owner_path
        and writer.get("source_anchor") == source_anchor
        and writer.get("disposition") == "privacy_transition"
    ]
    if len(matches) != 1:
        raise SystemExit(
            f"catalog lifecycle writer inventory expected exactly one {label} "
            f"privacy_transition writer for {owner_path}::{source_anchor}, got {len(matches)}"
        )
    return matches[0]

def selected_evidence(writer, operation_result_key):
    return {
        "writer_id": writer["id"],
        "owner_path": writer["owner_path"],
        "source_anchor": writer["source_anchor"],
        "oracle_class": writer["disposition"],
        "operation_result_key": operation_result_key,
    }

route_writer = select_blocking_writer(
    "route-owned expired-claim",
    "infra/api/src/routes/indexes/lifecycle.rs",
    "flapjack_proxy.delete_index",
)
service_writer = select_blocking_writer(
    "service-owned expired-claim",
    "infra/api/src/services/replica.rs",
    "replica_repo.create",
)
hard_erase_writer = select_privacy_writer(
    "hard-erasure route",
    "infra/api/src/routes/admin/tenants.rs",
    "customer_repo.hard_delete",
)
selected = [
    selected_evidence(route_writer, "expired_worker_claim_route_status"),
    selected_evidence(service_writer, "expired_worker_claim_service_status"),
    selected_evidence(soft_delete_writers[0], "stale_state_update_status"),
    selected_evidence(soft_delete_writers[1], "soft_delete_account_route_status"),
    selected_evidence(soft_delete_writers[2], "soft_delete_admin_route_status"),
    selected_evidence(hard_erase_writer, "hard_erase_tombstone_matrix_status"),
]
require_canonical("catalog lifecycle writer inventory", path, default_path)
print(json.dumps(selected, separators=(",", ":"), sort_keys=True))
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

expired_worker_claim_seed_sql() {
    cat <<'SQL'
-- catalog_service_window_expired_worker_claim_seed: local-only active reservation with an elapsed worker claim.
WITH upserted_vm AS (
    INSERT INTO vm_inventory (
        id,
        region,
        provider,
        hostname,
        flapjack_url,
        capacity,
        current_load,
        status
    )
    VALUES (
        '99999999-9999-9999-9999-999999999992'::uuid,
        :'probe_region',
        'aws',
        'catalog-service-window-expired-claim-us-east-1',
        :'probe_engine_url',
        '{"cpu_weight":8,"mem_rss_bytes":8589934592,"disk_bytes":107374182400,"query_rps":1000,"indexing_rps":100}'::jsonb,
        '{}'::jsonb,
        'active'
    )
    ON CONFLICT (id) DO UPDATE
    SET region = EXCLUDED.region,
        flapjack_url = EXCLUDED.flapjack_url,
        status = 'active',
        updated_at = NOW()
    RETURNING id
),
upserted_deployment AS (
    INSERT INTO customer_deployments (
        id,
        customer_id,
        node_id,
        region,
        vm_type,
        vm_provider,
        ip_address,
        status,
        flapjack_url,
        health_status
    )
    VALUES (
        '99999999-9999-9999-9999-999999999991'::uuid,
        :'probe_customer_id'::uuid,
        'catalog-service-window-expired-claim-node',
        :'probe_region',
        'shared',
        'aws',
        '127.0.0.1',
        'running',
        :'probe_engine_url',
        'healthy'
    )
    ON CONFLICT (id) DO UPDATE
    SET customer_id = EXCLUDED.customer_id,
        region = EXCLUDED.region,
        status = 'running',
        flapjack_url = EXCLUDED.flapjack_url,
        health_status = 'healthy'
    RETURNING id
),
upserted_tenant AS (
    INSERT INTO customer_tenants (
        customer_id,
        tenant_id,
        deployment_id,
        vm_id,
        tier,
        cold_snapshot_id,
        service_type
    )
    VALUES (
        :'probe_customer_id'::uuid,
        :'probe_expired_index',
        (SELECT id FROM upserted_deployment),
        (SELECT id FROM upserted_vm),
        'active',
        NULL,
        'flapjack'
    )
    ON CONFLICT (customer_id, tenant_id) DO UPDATE
    SET deployment_id = EXCLUDED.deployment_id,
        vm_id = EXCLUDED.vm_id,
        tier = 'active',
        cold_snapshot_id = NULL,
        service_type = 'flapjack'
    RETURNING customer_id, tenant_id
),
deleted_replicas AS (
    DELETE FROM index_replicas
    WHERE customer_id = :'probe_customer_id'::uuid
      AND tenant_id = :'probe_expired_index'
    RETURNING id
),
upserted_job AS (
    INSERT INTO algolia_import_jobs (
        id,
        customer_id,
        tenant_id,
        algolia_app_id,
        destination_kind,
        logical_target,
        destination_region,
        destination_vm_id,
        physical_uid,
        source_name,
        idempotency_key,
        canonical_fingerprint,
        routing_identity,
        source_size_bytes,
        reserved_index_count,
        reserved_customer_storage_bytes,
        reserved_node_transient_bytes,
        lifecycle_generation,
        worker_claimed_at,
        worker_lease_expires_at,
        status,
        publication_disposition,
        engine_ack_state,
        dispatch_intent_state
    )
    SELECT
        '99999999-9999-9999-9999-999999999993'::uuid,
        :'probe_customer_id'::uuid,
        :'probe_expired_index',
        'CATALOGSERVICEWINDOW',
        'create',
        :'probe_expired_index',
        :'probe_region',
        '99999999-9999-9999-9999-999999999992'::uuid,
        :'probe_expired_index',
        :'probe_expired_index',
        'catalog-service-window-expired-claim',
        'catalog-service-window-expired-claim',
        'catalog-service-window-expired-claim-routing',
        1,
        1,
        0,
        0,
        customers.lifecycle_generation,
        NOW() - INTERVAL '20 minutes',
        NOW() - INTERVAL '10 minutes',
        'queued',
        'not_started',
        'pending',
        'absent'
    FROM customers
    WHERE customers.id = :'probe_customer_id'::uuid
    ON CONFLICT (id) DO UPDATE
    SET customer_id = EXCLUDED.customer_id,
        tenant_id = EXCLUDED.tenant_id,
        logical_target = EXCLUDED.logical_target,
        destination_region = EXCLUDED.destination_region,
        destination_vm_id = EXCLUDED.destination_vm_id,
        physical_uid = EXCLUDED.physical_uid,
        source_name = EXCLUDED.source_name,
        idempotency_key = EXCLUDED.idempotency_key,
        canonical_fingerprint = EXCLUDED.canonical_fingerprint,
        routing_identity = EXCLUDED.routing_identity,
        source_size_bytes = EXCLUDED.source_size_bytes,
        reserved_index_count = EXCLUDED.reserved_index_count,
        reserved_customer_storage_bytes = EXCLUDED.reserved_customer_storage_bytes,
        reserved_node_transient_bytes = EXCLUDED.reserved_node_transient_bytes,
        lifecycle_generation = EXCLUDED.lifecycle_generation,
        worker_claimed_at = NOW() - INTERVAL '20 minutes',
        worker_lease_expires_at = NOW() - INTERVAL '10 minutes',
        status = 'queued',
        publication_disposition = 'not_started',
        engine_ack_state = 'pending',
        dispatch_intent_state = 'absent',
        updated_at = NOW()
    RETURNING id, worker_lease_expires_at
)
SELECT CASE
    WHEN (
        SELECT COUNT(*)
        FROM upserted_job
        WHERE worker_lease_expires_at IS NOT NULL
          AND worker_lease_expires_at < NOW()
    ) = 1 THEN 'seeded'
    ELSE 'missing_expired_worker_claim_reservation'
END;
SQL
}

seed_expired_worker_claim_reservation() {
    local seed_result

    seed_result="$(
        expired_worker_claim_seed_sql | run_probe_psql -v ON_ERROR_STOP=1 -tA \
            -v probe_customer_id="$PROBE_CUSTOMER_ID" \
            -v probe_expired_index="$PROBE_EXPIRED_CLAIM_INDEX" \
            -v probe_region="$PROBE_REGION" \
            -v probe_engine_url="$PROBE_ENGINE_URL"
    )" || die "local expired worker claim reservation seed failed"

    [ "$seed_result" = "seeded" ] \
        || die "local expired worker claim reservation seed did not persist an elapsed worker lease: $seed_result"
}

expired_worker_claim_snapshot_sql() {
    cat <<'SQL'
-- catalog_service_window_expired_worker_claim_snapshot: canonical target evidence.
SELECT jsonb_build_object(
    'catalog', (
        SELECT jsonb_build_object(
            'customer_id', customer_id::text,
            'tenant_id', tenant_id,
            'deployment_id', deployment_id::text,
            'vm_id', vm_id::text,
            'tier', tier,
            'service_type', service_type
        )
        FROM customer_tenants
        WHERE customer_id = :'probe_customer_id'::uuid
          AND tenant_id = :'probe_expired_index'
    ),
    'routing', (
        SELECT jsonb_build_object(
            'deployment_id', deployment.id::text,
            'deployment_region', deployment.region,
            'deployment_status', deployment.status,
            'deployment_health_status', deployment.health_status,
            'deployment_flapjack_url', deployment.flapjack_url,
            'vm_id', vm.id::text,
            'vm_region', vm.region,
            'vm_status', vm.status,
            'vm_flapjack_url', vm.flapjack_url,
            'replicas', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                    'id', replica.id::text,
                    'replica_region', replica.replica_region,
                    'status', replica.status
                ) ORDER BY replica.id)
                FROM index_replicas replica
                WHERE replica.customer_id = tenant.customer_id
                  AND replica.tenant_id = tenant.tenant_id
            ), '[]'::jsonb)
        )
        FROM customer_tenants tenant
        JOIN customer_deployments deployment ON deployment.id = tenant.deployment_id
        JOIN vm_inventory vm ON vm.id = tenant.vm_id
        WHERE tenant.customer_id = :'probe_customer_id'::uuid
          AND tenant.tenant_id = :'probe_expired_index'
    ),
    'import_operation', (
        SELECT jsonb_build_object(
            'id', job.id::text,
            'status', job.status,
            'publication_disposition', job.publication_disposition,
            'engine_ack_state', job.engine_ack_state,
            'dispatch_intent_state', job.dispatch_intent_state,
            'worker_claimed_elapsed', job.worker_claimed_at IS NOT NULL AND job.worker_claimed_at < NOW(),
            'worker_lease_elapsed', job.worker_lease_expires_at IS NOT NULL AND job.worker_lease_expires_at < NOW(),
            'reserved_index_count', job.reserved_index_count,
            'reserved_customer_storage_bytes', job.reserved_customer_storage_bytes,
            'reserved_node_transient_bytes', job.reserved_node_transient_bytes,
            'logical_target', job.logical_target
        )
        FROM algolia_import_jobs job
        WHERE job.id = '99999999-9999-9999-9999-999999999993'::uuid
          AND job.customer_id = :'probe_customer_id'::uuid
          AND job.logical_target = :'probe_expired_index'
          AND job.erased_at IS NULL
    )
)::text;
SQL
}

capture_expired_worker_claim_snapshot() {
    local snapshot
    snapshot="$(
        expired_worker_claim_snapshot_sql | run_probe_psql -v ON_ERROR_STOP=1 -tA \
            -v probe_customer_id="$PROBE_CUSTOMER_ID" \
            -v probe_expired_index="$PROBE_EXPIRED_CLAIM_INDEX"
    )" || die "expired worker claim snapshot query failed"
    canonical_json "$snapshot"
}

expected_expired_worker_claim_snapshot() {
    python3 - "$PROBE_CUSTOMER_ID" "$PROBE_EXPIRED_CLAIM_INDEX" "$PROBE_REGION" "$PROBE_ENGINE_URL" <<'PY'
import json
import sys

customer_id, index_name, region, engine_url = sys.argv[1:]
print(json.dumps({
    "catalog": {
        "customer_id": customer_id,
        "tenant_id": index_name,
        "deployment_id": "99999999-9999-9999-9999-999999999991",
        "vm_id": "99999999-9999-9999-9999-999999999992",
        "tier": "active",
        "service_type": "flapjack",
    },
    "routing": {
        "deployment_id": "99999999-9999-9999-9999-999999999991",
        "deployment_region": region,
        "deployment_status": "running",
        "deployment_health_status": "healthy",
        "deployment_flapjack_url": engine_url,
        "vm_id": "99999999-9999-9999-9999-999999999992",
        "vm_region": region,
        "vm_status": "active",
        "vm_flapjack_url": engine_url,
        "replicas": [],
    },
    "import_operation": {
        "id": "99999999-9999-9999-9999-999999999993",
        "status": "queued",
        "publication_disposition": "not_started",
        "engine_ack_state": "pending",
        "dispatch_intent_state": "absent",
        "worker_claimed_elapsed": True,
        "worker_lease_elapsed": True,
        "reserved_index_count": 1,
        "reserved_customer_storage_bytes": 0,
        "reserved_node_transient_bytes": 0,
        "logical_target": index_name,
    },
}, separators=(",", ":"), sort_keys=True))
PY
}

require_expired_worker_claim_snapshot() {
    local actual="$1"
    local expected="$2"

    python3 - "$actual" "$expected" <<'PY'
import json
import sys

actual = json.loads(sys.argv[1])
expected = json.loads(sys.argv[2])
operation = actual.get("import_operation")
if operation is None:
    raise SystemExit("expired worker claim snapshot missing active import reservation")
if operation.get("worker_lease_elapsed") is not True:
    raise SystemExit("expired worker claim snapshot missing elapsed worker lease")
if actual != expected:
    raise SystemExit("expired worker claim row evidence changed")
PY
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

physical_engine_observation_count() {
    python3 - "$OBSERVED_CALLERS_FILE" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
if not path.exists():
    raise SystemExit("observed callers artifact missing")
try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except json.JSONDecodeError as exc:
    raise SystemExit(f"observed callers artifact is not structured JSON: {exc}")
if payload.get("status") in {"skipped", "unchecked"}:
    raise SystemExit("observed callers artifact reports skipped or unchecked state")
checks = payload.get("checks")
required_checks = {"identity", "auth", "status"}
if (
    not isinstance(checks, dict)
    or set(checks) != required_checks
    or any(value != "checked" for value in checks.values())
):
    raise SystemExit("observed callers artifact reports skipped or unchecked state")
callers = payload.get("callers")
if not isinstance(callers, list):
    raise SystemExit("observed callers artifact missing callers array")
for row in callers:
    if (
        not isinstance(row, dict)
        or not isinstance(row.get("caller_id"), str)
        or not isinstance(row.get("observed_upstream_kind"), str)
    ):
        raise SystemExit("observed callers artifact has malformed caller rows")
print(sum(1 for row in callers if isinstance(row, dict) and row.get("observed_upstream_kind") == "physical_uid"))
PY
}

require_zero_prohibited_engine_observations() {
    local count="$1"

    [ -n "$count" ] \
        || die "prohibited_engine_observations missing"
    [ "$count" = "0" ] \
        || die "prohibited_engine_observations must be 0 before verdict emission, got $count"
}

expect_expired_worker_claim_conflict() {
    local label="$1"
    local body

    if [ "$HTTP_RESPONSE_CODE" != "409" ]; then
        die "$label expected HTTP 409 destination_conflict, got HTTP $HTTP_RESPONSE_CODE: $HTTP_RESPONSE_BODY"
    fi
    body="$(canonical_json "$HTTP_RESPONSE_BODY")" \
        || die "$label response was not structured JSON"
    [ "$body" = '{"error":"destination_conflict"}' ] \
        || die "$label expected HTTP 409 destination_conflict, got HTTP $HTTP_RESPONSE_CODE: $HTTP_RESPONSE_BODY"
}

exercise_expired_worker_claim_reservation() {
    local expected_snapshot before_snapshot after_route_snapshot after_service_snapshot
    local engine_count_before engine_count_after

    seed_expired_worker_claim_reservation
    expected_snapshot="$(expected_expired_worker_claim_snapshot)"
    before_snapshot="$(capture_expired_worker_claim_snapshot)" \
        || die "expired worker claim snapshot before blocked calls failed"
    require_expired_worker_claim_snapshot "$before_snapshot" "$expected_snapshot" \
        || die "expired worker claim snapshot missing active import reservation"

    engine_count_before="$(physical_engine_observation_count)"
    [ "$engine_count_before" = "0" ] \
        || die "observed callers artifact has pre-existing prohibited engine observations"

    tenant_call DELETE "/indexes/${PROBE_EXPIRED_CLAIM_INDEX}" "$PROBE_TOKEN" \
        -H "content-type: application/json" \
        -d '{"confirm":true}'
    expect_expired_worker_claim_conflict "expired worker claim route writer"
    EXPIRED_ROUTE_STATUS="destination_conflict"
    after_route_snapshot="$(capture_expired_worker_claim_snapshot)" \
        || die "expired worker claim snapshot after route call failed"
    require_expired_worker_claim_snapshot "$after_route_snapshot" "$expected_snapshot" \
        || die "expired worker claim row evidence changed"

    tenant_call POST "/indexes/${PROBE_EXPIRED_CLAIM_INDEX}/replicas" "$PROBE_TOKEN" \
        -H "content-type: application/json" \
        -d "{\"region\":\"${PROBE_REPLICA_REGION}\"}"
    expect_expired_worker_claim_conflict "expired worker claim service writer"
    EXPIRED_SERVICE_STATUS="destination_conflict"
    after_service_snapshot="$(capture_expired_worker_claim_snapshot)" \
        || die "expired worker claim snapshot after service call failed"
    require_expired_worker_claim_snapshot "$after_service_snapshot" "$expected_snapshot" \
        || die "expired worker claim row evidence changed"

    engine_count_after="$(physical_engine_observation_count)"
    [ "$engine_count_after" = "$engine_count_before" ] \
        || die "expired worker claim blocked calls produced engine observations"
    [ "$engine_count_after" = "0" ] \
        || die "expired worker claim blocked calls produced engine observations"
    PROHIBITED_ENGINE_OBSERVATIONS="$engine_count_after"
}

# Seed one dedicated soft-delete customer at generation G with a full retained
# evidence graph (catalog target, deployment/VM routing, and an import job that
# carries the active reservation, dispatch intent, and ACK/reconciliation state).
# The customer row itself is created by the real /auth/register flow; this only
# pins its generation and attaches the retained evidence.
soft_delete_fence_seed_sql() {
    cat <<'SQL'
-- catalog_service_window_soft_delete_seed: dedicated generation-G customer with retained evidence.
WITH fenced_customer AS (
    UPDATE customers
    SET status = 'active',
        lifecycle_generation = :'sd_generation'::bigint,
        deleted_at = NULL,
        updated_at = NOW()
    WHERE id = :'sd_customer_id'::uuid
    RETURNING id, lifecycle_generation
),
seed_vm AS (
    INSERT INTO vm_inventory (
        id, region, provider, hostname, flapjack_url, capacity, current_load, status
    )
    VALUES (
        md5(:'sd_customer_id' || 'vm')::uuid, :'probe_region', 'aws',
        'catalog-service-window-sd-' || :'sd_customer_id', :'probe_engine_url',
        '{"cpu_weight":8,"mem_rss_bytes":8589934592,"disk_bytes":107374182400,"query_rps":1000,"indexing_rps":100}'::jsonb,
        '{}'::jsonb, 'active'
    )
    ON CONFLICT (id) DO UPDATE
    SET region = EXCLUDED.region, flapjack_url = EXCLUDED.flapjack_url,
        status = 'active', updated_at = NOW()
    RETURNING id
),
seed_deployment AS (
    INSERT INTO customer_deployments (
        id, customer_id, node_id, region, vm_type, vm_provider, ip_address,
        status, flapjack_url, health_status
    )
    VALUES (
        md5(:'sd_customer_id' || 'deploy')::uuid, :'sd_customer_id'::uuid,
        'catalog-service-window-sd-node-' || :'sd_customer_id', :'probe_region', 'shared', 'aws',
        '127.0.0.1', 'running', :'probe_engine_url', 'healthy'
    )
    ON CONFLICT (id) DO UPDATE
    SET customer_id = EXCLUDED.customer_id, status = 'running',
        flapjack_url = EXCLUDED.flapjack_url, health_status = 'healthy'
    RETURNING id
),
seed_tenant AS (
    INSERT INTO customer_tenants (
        customer_id, tenant_id, deployment_id, vm_id, tier, cold_snapshot_id, service_type
    )
    VALUES (
        :'sd_customer_id'::uuid, :'sd_index', (SELECT id FROM seed_deployment),
        (SELECT id FROM seed_vm), 'active', NULL, 'flapjack'
    )
    ON CONFLICT (customer_id, tenant_id) DO UPDATE
    SET deployment_id = EXCLUDED.deployment_id, vm_id = EXCLUDED.vm_id,
        tier = 'active', cold_snapshot_id = NULL, service_type = 'flapjack'
    RETURNING customer_id
),
seed_job AS (
    INSERT INTO algolia_import_jobs (
        id, customer_id, tenant_id, algolia_app_id, destination_kind, logical_target,
        destination_region, destination_deployment_id, destination_vm_id, physical_uid, source_name,
        idempotency_key, canonical_fingerprint, routing_identity, source_size_bytes, engine_job_id,
        reserved_index_count, reserved_customer_storage_bytes, reserved_node_transient_bytes,
        lifecycle_generation, status, publication_disposition, engine_ack_state, dispatch_intent_state
    )
    SELECT
        md5(:'sd_customer_id' || 'job')::uuid, :'sd_customer_id'::uuid, :'sd_index',
        'CATALOGSERVICEWINDOW', 'replace', :'sd_index', :'probe_region',
        (SELECT id FROM seed_deployment), (SELECT id FROM seed_vm), :'sd_index', :'sd_index',
        'catalog-service-window-soft-delete', 'catalog-service-window-soft-delete',
        'catalog-service-window-soft-delete-routing', 1,
        md5(:'sd_customer_id' || 'engine-job')::uuid, 1, 0, 0,
        :'sd_generation'::bigint, 'completed', 'promoted', 'acknowledged', 'committed'
    ON CONFLICT (id) DO UPDATE
    SET status = 'completed', publication_disposition = 'promoted',
        engine_ack_state = 'acknowledged', dispatch_intent_state = 'committed',
        destination_deployment_id = EXCLUDED.destination_deployment_id,
        destination_vm_id = EXCLUDED.destination_vm_id,
        engine_job_id = EXCLUDED.engine_job_id,
        lifecycle_generation = EXCLUDED.lifecycle_generation, updated_at = NOW()
    RETURNING id
)
SELECT CASE
    WHEN (SELECT lifecycle_generation FROM fenced_customer) = :'sd_generation'::bigint
        AND EXISTS (SELECT 1 FROM seed_tenant)
        AND EXISTS (SELECT 1 FROM seed_job)
    THEN 'seeded'
    ELSE 'missing_soft_delete_fence_customer'
END;
SQL
}

seed_soft_delete_fence() {
    local customer_id="$1"
    local index="$2"
    local seed_result

    seed_result="$(
        soft_delete_fence_seed_sql | run_probe_psql -v ON_ERROR_STOP=1 -tA \
            -v sd_customer_id="$customer_id" \
            -v sd_index="$index" \
            -v sd_generation="$SOFT_DELETE_FENCE_GENERATION" \
            -v probe_region="$PROBE_REGION" \
            -v probe_engine_url="$PROBE_ENGINE_URL"
    )" || die "soft delete fence seed failed"

    [ "$seed_result" = "seeded" ] \
        || die "soft delete fence seed did not persist generation G evidence: $seed_result"
}

# Canonical customer + retained-evidence snapshot. The arm label rides in a
# leading SQL comment so evidence from the account and admin arms is captured
# independently across the before, first-delete, and repeat-delete phases.
soft_delete_fence_snapshot_sql() {
    printf -- '-- catalog_service_window_soft_delete_snapshot:%s\n' "$1"
    cat <<'SQL'
SELECT jsonb_build_object(
    'customer', (
        SELECT jsonb_build_object(
            'status', status,
            'lifecycle_generation', lifecycle_generation,
            'deleted_at', CASE
                WHEN deleted_at IS NULL THEN NULL
                ELSE to_char(deleted_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
            END
        )
        FROM customers
        WHERE id = :'sd_customer_id'::uuid
    ),
    'evidence', jsonb_build_object(
        'catalog', (
            SELECT jsonb_build_object(
                'customer_id', customer_id::text,
                'tenant_id', tenant_id,
                'deployment_id', deployment_id::text,
                'vm_id', vm_id::text,
                'tier', tier,
                'service_type', service_type
            )
            FROM customer_tenants
            WHERE customer_id = :'sd_customer_id'::uuid
              AND tenant_id = :'sd_index'
        ),
        'routing', (
            SELECT jsonb_build_object(
                'deployment_id', deployment.id::text,
                'deployment_status', deployment.status,
                'deployment_flapjack_url', deployment.flapjack_url,
                'vm_id', vm.id::text,
                'vm_status', vm.status
            )
            FROM customer_tenants tenant
            JOIN customer_deployments deployment ON deployment.id = tenant.deployment_id
            JOIN vm_inventory vm ON vm.id = tenant.vm_id
            WHERE tenant.customer_id = :'sd_customer_id'::uuid
              AND tenant.tenant_id = :'sd_index'
        ),
        'import_operation', (
            SELECT jsonb_build_object(
                'id', job.id::text,
                'status', job.status,
                'publication_disposition', job.publication_disposition,
                'engine_ack_state', job.engine_ack_state,
                'dispatch_intent_state', job.dispatch_intent_state,
                'reserved_index_count', job.reserved_index_count,
                'lifecycle_generation', job.lifecycle_generation,
                'logical_target', job.logical_target
            )
            FROM algolia_import_jobs job
            WHERE job.customer_id = :'sd_customer_id'::uuid
              AND job.logical_target = :'sd_index'
              AND job.erased_at IS NULL
        )
    )
)::text;
SQL
}

capture_soft_delete_fence_snapshot() {
    local arm="$1"
    local customer_id="$2"
    local index="$3"
    local snapshot

    snapshot="$(
        soft_delete_fence_snapshot_sql "$arm" | run_probe_psql -v ON_ERROR_STOP=1 -tA \
            -v sd_customer_id="$customer_id" \
            -v sd_index="$index"
    )" || die "soft delete fence snapshot ($arm) query failed"
    canonical_json "$snapshot"
}

# Enforce the generation fence: active,G -> deleted,G+1 with a populated stable
# deleted_at on the first delete; an unchanged generation, timestamp, and retained
# evidence on the repeat; and byte-for-byte retained evidence throughout.
require_soft_delete_fence_transition() {
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import json
import sys

before, after_first, after_repeat = (json.loads(arg) for arg in sys.argv[1:4])
generation = int(sys.argv[4])


def customer(snapshot):
    value = snapshot.get("customer")
    if value is None:
        raise SystemExit("soft delete fence snapshot missing customer row")
    return value


def evidence(snapshot):
    value = snapshot.get("evidence")
    if value is None:
        raise SystemExit("soft delete fence snapshot missing retained evidence")
    for row in ("catalog", "routing", "import_operation"):
        if value.get(row) is None:
            raise SystemExit(f"soft delete fence snapshot missing {row} row")
    return value


before_customer = customer(before)
before_evidence = evidence(before)
if before_customer.get("status") != "active":
    raise SystemExit("soft delete fence before-snapshot must be active")
if before_customer.get("lifecycle_generation") != generation:
    raise SystemExit("soft delete fence before-snapshot generation must equal G")
if before_customer.get("deleted_at") is not None:
    raise SystemExit("soft delete fence before-snapshot must not be deleted")

first_customer = customer(after_first)
first_evidence = evidence(after_first)
if first_customer.get("status") != "deleted":
    raise SystemExit("soft delete fence first delete must set status=deleted")
if first_customer.get("lifecycle_generation") != generation + 1:
    raise SystemExit("soft delete fence first delete must advance generation to G + 1")
if not first_customer.get("deleted_at"):
    raise SystemExit("soft delete fence first delete must populate deleted_at")
if first_evidence != before_evidence:
    raise SystemExit("soft delete fence first delete mutated retained evidence")

repeat_customer = customer(after_repeat)
repeat_evidence = evidence(after_repeat)
if repeat_customer.get("status") != "deleted":
    raise SystemExit("soft delete fence repeat delete must keep status=deleted")
if repeat_customer.get("lifecycle_generation") != first_customer.get("lifecycle_generation"):
    raise SystemExit("soft delete fence repeat delete must not change generation")
if repeat_customer.get("deleted_at") != first_customer.get("deleted_at"):
    raise SystemExit("soft delete fence repeat delete must not change deleted_at")
if repeat_evidence != before_evidence:
    raise SystemExit("soft delete fence repeat delete mutated retained evidence")
print(json.dumps({
    "before_customer": before_customer,
    "first_delete_customer": first_customer,
    "repeat_delete_customer": repeat_customer,
    "before_retained_evidence": before_evidence,
    "first_delete_retained_evidence": first_evidence,
    "repeat_delete_retained_evidence": repeat_evidence,
    "first_delete_retained_evidence_unchanged": first_evidence == before_evidence,
    "repeat_delete_retained_evidence_unchanged": repeat_evidence == before_evidence,
}, separators=(",", ":"), sort_keys=True))
PY
}

soft_delete_register_and_login() {
    local email="$1"
    local password="$2"

    capture_response POST "${API_URL}/auth/register" \
        -H "content-type: application/json" \
        -d "{\"name\":\"Catalog Service Window Soft Delete\",\"email\":\"${email}\",\"password\":\"${password}\"}"
    case "$HTTP_RESPONSE_CODE" in
        201|409) ;;
        *) die "soft delete arm register expected HTTP 201 or existing-account 409, got ${HTTP_RESPONSE_CODE}" ;;
    esac

    capture_response POST "${API_URL}/auth/login" \
        -H "content-type: application/json" \
        -d "{\"email\":\"${email}\",\"password\":\"${password}\"}"
    expect_status "soft delete arm login" "200"
    SOFT_DELETE_ARM_TOKEN="$(json_field "$HTTP_RESPONSE_BODY" token)" \
        || die "soft delete arm login response missing token"
    SOFT_DELETE_ARM_CUSTOMER_ID="$(json_field "$HTTP_RESPONSE_BODY" customer_id)" \
        || die "soft delete arm login response missing customer_id"
}

soft_delete_account_route_delete() {
    tenant_call DELETE "/account" "$SOFT_DELETE_ARM_TOKEN" \
        -H "content-type: application/json" \
        -d "{\"password\":\"${SOFT_DELETE_ARM_PASSWORD}\"}"
    if [ "$1" = "404" ] && is_deleted_customer_auth_rejection "$HTTP_RESPONSE_CODE" "$HTTP_RESPONSE_BODY"; then
        return 0
    fi
    expect_status "account soft delete route" "$1"
}

soft_delete_admin_route_delete() {
    admin_call DELETE "/admin/tenants/${SOFT_DELETE_ARM_CUSTOMER_ID}"
    expect_status "admin soft delete route" "$1"
}

is_deleted_customer_auth_rejection() {
    local code="$1"
    local body="$2"
    local canonical

    [ "$code" = "401" ] || return 1
    canonical="$(canonical_json "$body" 2>/dev/null)" || return 1
    [ "$canonical" = '{"error":"invalid or expired token"}' ]
}

require_deleted_customer_route_refusal() {
    local label="$1"
    shift
    local accepted_status

    if is_deleted_customer_auth_rejection "$HTTP_RESPONSE_CODE" "$HTTP_RESPONSE_BODY"; then
        return 0
    fi
    for accepted_status in "$@"; do
        if [ "$HTTP_RESPONSE_CODE" = "$accepted_status" ]; then
            return 0
        fi
    done
    die "$label expected deleted-customer refusal, got HTTP $HTTP_RESPONSE_CODE: $HTTP_RESPONSE_BODY"
}

# After the delete, the retained target must stay hidden from the deleted
# customer's own lease-guarded route seams: reads return not-found and every
# `IndexLifecycleLease`-guarded mutation is refused, without dispatching to the
# engine or changing the retained snapshot.
require_soft_delete_target_hidden() {
    local arm="$1"
    local index="$2"
    local retained_snapshot="$3"
    local engine_before engine_after after_hidden

    engine_before="$(physical_engine_observation_count)"

    tenant_call GET "/indexes/${index}" "$SOFT_DELETE_ARM_TOKEN"
    require_deleted_customer_route_refusal "soft delete hidden target ($arm)" 404

    tenant_call POST "/indexes/${index}/replicas" "$SOFT_DELETE_ARM_TOKEN" \
        -H "content-type: application/json" \
        -d "{\"region\":\"${PROBE_REPLICA_REGION}\"}"
    require_deleted_customer_route_refusal "soft delete hidden target ($arm) lease mutation" 409 404

    tenant_call DELETE "/indexes/${index}" "$SOFT_DELETE_ARM_TOKEN" \
        -H "content-type: application/json" \
        -d '{"confirm":true}'
    require_deleted_customer_route_refusal "soft delete hidden target ($arm) lease delete" 409 404

    engine_after="$(physical_engine_observation_count)"
    [ "$engine_after" = "$engine_before" ] \
        || die "soft delete hidden target ($arm) refused mutations produced engine observations"
    PROHIBITED_ENGINE_OBSERVATIONS="$engine_after"

    after_hidden="$(capture_soft_delete_fence_snapshot "$arm" "$SOFT_DELETE_ARM_CUSTOMER_ID" "$index")"
    [ "$after_hidden" = "$retained_snapshot" ] \
        || die "soft delete hidden target ($arm) mutated retained evidence"
}

# Drive one arm end-to-end: seed at G, capture the before snapshot, delete through
# the real route, capture the first-delete snapshot, repeat the delete (route
# not-found contract), capture the repeat snapshot, and enforce the fence.
run_soft_delete_fence_arm() {
    local arm="$1"
    local email="$2"
    local password="$3"
    local index="$4"
    local delete_fn="$5"
    local before after_first after_repeat transition_evidence

    SOFT_DELETE_ARM_PASSWORD="$password"
    soft_delete_register_and_login "$email" "$password"
    seed_soft_delete_fence "$SOFT_DELETE_ARM_CUSTOMER_ID" "$index"

    before="$(capture_soft_delete_fence_snapshot "$arm" "$SOFT_DELETE_ARM_CUSTOMER_ID" "$index")"
    "$delete_fn" 204
    after_first="$(capture_soft_delete_fence_snapshot "$arm" "$SOFT_DELETE_ARM_CUSTOMER_ID" "$index")"
    "$delete_fn" 404
    after_repeat="$(capture_soft_delete_fence_snapshot "$arm" "$SOFT_DELETE_ARM_CUSTOMER_ID" "$index")"

    transition_evidence="$(require_soft_delete_fence_transition "$before" "$after_first" "$after_repeat" \
        "$SOFT_DELETE_FENCE_GENERATION")" \
        || die "soft delete generation fence ($arm) failed"
    require_soft_delete_target_hidden "$arm" "$index" "$after_repeat"
    SOFT_DELETE_LAST_STATUS="deleted"
    SOFT_DELETE_LAST_HIDDEN="hidden"
    SOFT_DELETE_LAST_TRANSITION="$transition_evidence"
}

exercise_soft_delete_fence() {
    run_soft_delete_fence_arm account "$SOFT_DELETE_ACCOUNT_EMAIL" \
        "$SOFT_DELETE_ACCOUNT_PASSWORD" "$SOFT_DELETE_ACCOUNT_INDEX" \
        soft_delete_account_route_delete
    SOFT_DELETE_ACCOUNT_STATUS="$SOFT_DELETE_LAST_STATUS"
    SOFT_DELETE_ACCOUNT_HIDDEN="$SOFT_DELETE_LAST_HIDDEN"
    SOFT_DELETE_ACCOUNT_TRANSITION="$SOFT_DELETE_LAST_TRANSITION"

    run_soft_delete_fence_arm admin "$SOFT_DELETE_ADMIN_EMAIL" \
        "$SOFT_DELETE_ADMIN_PASSWORD" "$SOFT_DELETE_ADMIN_INDEX" \
        soft_delete_admin_route_delete
    SOFT_DELETE_ADMIN_STATUS="$SOFT_DELETE_LAST_STATUS"
    SOFT_DELETE_ADMIN_HIDDEN="$SOFT_DELETE_LAST_HIDDEN"
    SOFT_DELETE_ADMIN_TRANSITION="$SOFT_DELETE_LAST_TRANSITION"
}

hard_erase_register_and_login() {
    capture_response POST "${API_URL}/auth/register" \
        -H "content-type: application/json" \
        -d "{\"name\":\"Catalog Service Window Hard Erase\",\"email\":\"${HARD_ERASE_EMAIL}\",\"password\":\"${HARD_ERASE_PASSWORD}\"}"
    case "$HTTP_RESPONSE_CODE" in
        201|409) ;;
        *) die "hard erase arm register expected HTTP 201 or existing-account 409, got ${HTTP_RESPONSE_CODE}" ;;
    esac

    capture_response POST "${API_URL}/auth/login" \
        -H "content-type: application/json" \
        -d "{\"email\":\"${HARD_ERASE_EMAIL}\",\"password\":\"${HARD_ERASE_PASSWORD}\"}"
    expect_status "hard erase arm login" "200"
    HARD_ERASE_TOKEN="$(json_field "$HTTP_RESPONSE_BODY" token)" \
        || die "hard erase arm login response missing token"
    HARD_ERASE_CUSTOMER_ID="$(json_field "$HTTP_RESPONSE_BODY" customer_id)" \
        || die "hard erase arm login response missing customer_id"
}

hard_erase_matrix_seed_sql() {
    cat <<'SQL'
-- catalog_service_window_hard_erase_matrix_seed: local-only hard-erasure tombstone matrix.
WITH deleted_customer AS (
    SELECT id, lifecycle_generation
    FROM customers
    WHERE id = :'he_customer_id'::uuid
      AND status = 'deleted'
),
case_fixture(ordinal, case_name, job_id, status, dispatch_intent_state, destination_kind,
             destination_vm_id, destination_deployment_id, engine_job_id,
             publication_disposition, engine_ack_state, retryable, resumable,
             worker_lease, cancel_requested, resume_metadata, elapsed_resume_deadline,
             error_code, terminal_at) AS (
    VALUES
        (1, 'committed', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbb0001'::uuid, 'copying_documents', 'committed', 'replace', 'eeeeeeee-eeee-eeee-eeee-eeeeeeee0001'::uuid, 'ffffffff-ffff-ffff-ffff-ffffffff0001'::uuid, 'cccccccc-cccc-cccc-cccc-cccccccc0001'::uuid, 'unchanged', 'pending', FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, NULL::text, FALSE),
        (2, 'ambiguous', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbb0002'::uuid, 'verifying', 'ambiguous', 'replace', 'eeeeeeee-eeee-eeee-eeee-eeeeeeee0002'::uuid, 'ffffffff-ffff-ffff-ffff-ffffffff0002'::uuid, 'cccccccc-cccc-cccc-cccc-cccccccc0002'::uuid, 'unknown', 'pending', FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, NULL::text, FALSE),
        (3, 'pre_linkage', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbb0003'::uuid, 'validating_source', 'committed', 'create', NULL::uuid, NULL::uuid, NULL::uuid, 'not_started', 'pending', FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, NULL::text, FALSE),
        (4, 'cancelling', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbb0004'::uuid, 'cancelling', 'committed', 'replace', 'eeeeeeee-eeee-eeee-eeee-eeeeeeee0004'::uuid, 'ffffffff-ffff-ffff-ffff-ffffffff0004'::uuid, 'cccccccc-cccc-cccc-cccc-cccccccc0004'::uuid, 'unchanged', 'pending', FALSE, FALSE, TRUE, TRUE, FALSE, FALSE, NULL::text, FALSE),
        (5, 'cancelled_before_ack', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbb0005'::uuid, 'cancelled', 'committed', 'replace', 'eeeeeeee-eeee-eeee-eeee-eeeeeeee0005'::uuid, 'ffffffff-ffff-ffff-ffff-ffffffff0005'::uuid, 'cccccccc-cccc-cccc-cccc-cccccccc0005'::uuid, 'unchanged', 'outbox_pending', FALSE, FALSE, FALSE, TRUE, FALSE, FALSE, NULL::text, TRUE),
        (6, 'failed_resumable_with_lease', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbb0006'::uuid, 'failed', 'committed', 'replace', 'eeeeeeee-eeee-eeee-eeee-eeeeeeee0006'::uuid, 'ffffffff-ffff-ffff-ffff-ffffffff0006'::uuid, 'cccccccc-cccc-cccc-cccc-cccccccc0006'::uuid, 'unchanged', 'pending', TRUE, TRUE, TRUE, FALSE, TRUE, FALSE, 'internal', TRUE),
        (7, 'credential_accepted_before_socket', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbb0007'::uuid, 'validating_source', 'committed', 'create', NULL::uuid, NULL::uuid, NULL::uuid, 'not_started', 'pending', FALSE, FALSE, TRUE, FALSE, FALSE, FALSE, NULL::text, FALSE),
        (8, 'resuming', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbb0008'::uuid, 'resuming', 'committed', 'replace', 'eeeeeeee-eeee-eeee-eeee-eeeeeeee0008'::uuid, 'ffffffff-ffff-ffff-ffff-ffffffff0008'::uuid, 'cccccccc-cccc-cccc-cccc-cccccccc0008'::uuid, 'unchanged', 'pending', FALSE, FALSE, TRUE, FALSE, TRUE, FALSE, NULL::text, FALSE),
        (9, 'resume_deadline_race', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbb0009'::uuid, 'failed', 'ambiguous', 'replace', 'eeeeeeee-eeee-eeee-eeee-eeeeeeee0009'::uuid, 'ffffffff-ffff-ffff-ffff-ffffffff0009'::uuid, 'cccccccc-cccc-cccc-cccc-cccccccc0009'::uuid, 'unchanged', 'pending', TRUE, TRUE, FALSE, FALSE, TRUE, TRUE, 'internal', TRUE),
        (10, 'local_no_dispatch', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbb0010'::uuid, 'failed', 'absent', 'create', NULL::uuid, NULL::uuid, NULL::uuid, 'not_started', 'not_applicable', FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, 'internal', TRUE),
        (11, 'seal_tombstone', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbb0011'::uuid, 'interrupted', 'ambiguous', 'create', NULL::uuid, NULL::uuid, NULL::uuid, 'not_started', 'seal_acknowledged', FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, 'interrupted', TRUE),
        (12, 'ambiguous_publication', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbb0012'::uuid, 'promoting', 'ambiguous', 'replace', 'eeeeeeee-eeee-eeee-eeee-eeeeeeee0012'::uuid, 'ffffffff-ffff-ffff-ffff-ffffffff0012'::uuid, 'cccccccc-cccc-cccc-cccc-cccccccc0012'::uuid, 'unknown', 'pending', FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, NULL::text, FALSE)
),
seed_vm AS (
    INSERT INTO vm_inventory (
        id, region, provider, hostname, flapjack_url, capacity, current_load, status
    )
    SELECT DISTINCT destination_vm_id, :'probe_region', 'aws',
        'catalog-service-window-hard-erase-' || ordinal, :'probe_engine_url',
        '{"cpu_weight":8,"mem_rss_bytes":8589934592,"disk_bytes":107374182400,"query_rps":1000,"indexing_rps":100}'::jsonb,
        '{}'::jsonb, 'active'
    FROM case_fixture
    WHERE destination_vm_id IS NOT NULL
    ON CONFLICT (id) DO UPDATE
    SET region = EXCLUDED.region, flapjack_url = EXCLUDED.flapjack_url,
        status = 'active', updated_at = NOW()
    RETURNING id
),
seed_deployment AS (
    INSERT INTO customer_deployments (
        id, customer_id, node_id, region, vm_type, vm_provider, ip_address,
        status, flapjack_url, health_status
    )
    SELECT destination_deployment_id, :'he_customer_id'::uuid,
        'catalog-service-window-hard-erase-node-' || ordinal, :'probe_region',
        'shared', 'aws', '127.0.0.1', 'running', :'probe_engine_url', 'healthy'
    FROM case_fixture
    WHERE destination_deployment_id IS NOT NULL
    ON CONFLICT (id) DO UPDATE
    SET customer_id = EXCLUDED.customer_id, status = 'running',
        flapjack_url = EXCLUDED.flapjack_url, health_status = 'healthy'
    RETURNING id
),
seed_tenant AS (
    INSERT INTO customer_tenants (
        customer_id, tenant_id, deployment_id, vm_id, tier, cold_snapshot_id, service_type
    )
    SELECT :'he_customer_id'::uuid, :'he_index', NULL, NULL, 'active', NULL, 'flapjack'
    FROM deleted_customer
    ON CONFLICT (customer_id, tenant_id) DO UPDATE
    SET tier = 'active', cold_snapshot_id = NULL, service_type = 'flapjack'
    RETURNING customer_id
),
seed_jobs AS (
    INSERT INTO algolia_import_jobs (
        id, customer_id, tenant_id, algolia_app_id, destination_kind, logical_target,
        destination_region, destination_deployment_id, destination_vm_id, physical_uid,
        source_name, engine_job_id, dispatch_intent_state, lifecycle_generation,
        idempotency_key, canonical_fingerprint, routing_identity, source_size_bytes,
        reserved_index_count, reserved_customer_storage_bytes, reserved_node_transient_bytes,
        retryable, worker_claimed_at, worker_lease_expires_at, cancel_requested_at,
        resume_intent_generation, resume_checkpoint, resume_deadline,
        resume_status_observed_at, resumable, resume_count, documents_expected,
        documents_imported, documents_rejected, settings_applied, settings_unsupported,
        synonyms_expected, synonyms_imported, synonyms_rejected, rules_expected,
        rules_imported, rules_rejected, warnings, error_code, error_message, status,
        publication_disposition, engine_ack_state, terminal_at
    )
    SELECT
        job_id, :'he_customer_id'::uuid, :'he_index' || '-' || case_name,
        'CATALOGSERVICEWINDOW', destination_kind, :'he_index' || '-' || case_name,
        :'probe_region', destination_deployment_id, destination_vm_id,
        CASE WHEN destination_vm_id IS NULL THEN NULL ELSE 'PII_MATRIX_PHYSICAL_' || case_name END,
        'PII_MATRIX_SOURCE_' || case_name, engine_job_id, dispatch_intent_state,
        (SELECT lifecycle_generation FROM deleted_customer),
        'PII_MATRIX_IDEMPOTENCY_' || ordinal,
        'PII_MATRIX_FINGERPRINT_' || case_name,
        CASE WHEN destination_vm_id IS NULL THEN NULL ELSE 'PII_MATRIX_ROUTING_' || case_name END,
        4096, 1, 2048, 512, retryable,
        CASE WHEN worker_lease THEN NOW() ELSE NULL END,
        CASE WHEN worker_lease THEN NOW() + INTERVAL '5 minutes' ELSE NULL END,
        CASE WHEN cancel_requested THEN NOW() ELSE NULL END,
        CASE WHEN resume_metadata THEN 2 ELSE 0 END,
        CASE WHEN resume_metadata THEN 'PII_MATRIX_CHECKPOINT_' || case_name ELSE NULL END,
        CASE
            WHEN resume_metadata AND elapsed_resume_deadline THEN NOW() - INTERVAL '5 minutes'
            WHEN resume_metadata THEN NOW() + INTERVAL '1 hour'
            ELSE NULL
        END,
        CASE WHEN resume_metadata THEN NOW() - INTERVAL '10 minutes' ELSE NULL END,
        resumable, CASE WHEN resume_metadata THEN 1 ELSE 0 END,
        31, 17, 2, 5, 1, 7, 6, 1, 9, 8, 1,
        jsonb_build_array('PII_MATRIX_WARNING_' || case_name, 'PII_MATRIX_OBJECT_' || case_name),
        error_code,
        CASE WHEN error_code IS NULL THEN NULL ELSE 'PII_MATRIX_ERROR_' || case_name END,
        status, publication_disposition, engine_ack_state,
        CASE WHEN terminal_at THEN NOW() ELSE NULL END
    FROM case_fixture
    WHERE EXISTS (SELECT 1 FROM deleted_customer)
    ON CONFLICT (id) DO UPDATE
    SET customer_id = EXCLUDED.customer_id,
        tenant_id = EXCLUDED.tenant_id,
        algolia_app_id = EXCLUDED.algolia_app_id,
        destination_kind = EXCLUDED.destination_kind,
        logical_target = EXCLUDED.logical_target,
        destination_region = EXCLUDED.destination_region,
        destination_deployment_id = EXCLUDED.destination_deployment_id,
        destination_vm_id = EXCLUDED.destination_vm_id,
        physical_uid = EXCLUDED.physical_uid,
        source_name = EXCLUDED.source_name,
        engine_job_id = EXCLUDED.engine_job_id,
        dispatch_intent_state = EXCLUDED.dispatch_intent_state,
        lifecycle_generation = EXCLUDED.lifecycle_generation,
        idempotency_key = EXCLUDED.idempotency_key,
        canonical_fingerprint = EXCLUDED.canonical_fingerprint,
        routing_identity = EXCLUDED.routing_identity,
        status = EXCLUDED.status,
        publication_disposition = EXCLUDED.publication_disposition,
        engine_ack_state = EXCLUDED.engine_ack_state,
        erased_at = NULL,
        erasure_handle = NULL,
        cleanup_phase = 'public',
        tombstone_compacted_at = NULL,
        updated_at = NOW()
    RETURNING id
),
audit_canary AS (
    INSERT INTO audit_log (actor_id, action, target_tenant_id, metadata)
    SELECT '00000000-0000-0000-0000-000000000000'::uuid,
        'PII_MATRIX_AUDIT_ACTION_CANARY', :'he_customer_id'::uuid,
        '{"history":"PII_MATRIX_AUDIT_METADATA_CANARY"}'::jsonb
    FROM deleted_customer
    RETURNING id
)
SELECT COALESCE(
    jsonb_agg(jsonb_build_object('case_name', case_fixture.case_name, 'id', case_fixture.job_id::text)
              ORDER BY case_fixture.ordinal),
    '[]'::jsonb
)::text
FROM case_fixture
JOIN seed_jobs ON seed_jobs.id = case_fixture.job_id;
SQL
}

seed_hard_erase_matrix() {
    local seed_result

    seed_result="$(
        hard_erase_matrix_seed_sql | run_probe_psql -v ON_ERROR_STOP=1 -tA \
            -v he_customer_id="$HARD_ERASE_CUSTOMER_ID" \
            -v he_index="$HARD_ERASE_INDEX" \
            -v probe_region="$PROBE_REGION" \
            -v probe_engine_url="$PROBE_ENGINE_URL"
    )" || die "hard erase matrix seed failed"
    HARD_ERASE_SEEDED_IDS="$(canonical_json "$seed_result")" \
        || die "hard erase matrix seed returned non-JSON evidence"
}

hard_erase_matrix_clock_sql() {
    cat <<'SQL'
-- catalog_service_window_hard_erase_matrix_clock: database freshness bound.
SELECT to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"');
SQL
}

capture_hard_erase_matrix_clock() {
    hard_erase_matrix_clock_sql | run_probe_psql -v ON_ERROR_STOP=1 -tA
}

hard_erase_matrix_snapshot_sql() {
    cat <<'SQL'
-- catalog_service_window_hard_erase_matrix_snapshot: scoped post-erasure tombstone readback.
WITH seeded AS (
    SELECT
        row.value->>'case_name' AS case_name,
        (row.value->>'id')::uuid AS id,
        row.ordinal
    FROM jsonb_array_elements(:'he_seeded_rows'::jsonb) WITH ORDINALITY AS row(value, ordinal)
),
tombstone_rows AS (
    SELECT
        seeded.case_name,
        seeded.ordinal,
        job.*,
        (
            job.customer_id IS NULL
            AND job.tenant_id IS NULL
            AND job.algolia_app_id IS NULL
            AND job.destination_kind IS NULL
            AND job.logical_target IS NULL
            AND job.destination_region IS NULL
            AND job.destination_deployment_id IS NULL
            AND job.physical_uid IS NULL
            AND job.source_name IS NULL
            AND job.cloud_job_id IS NULL
            AND job.dispatch_intent_state IS NULL
            AND job.lifecycle_generation IS NULL
            AND job.idempotency_key IS NULL
            AND job.canonical_fingerprint IS NULL
            AND job.routing_identity IS NULL
            AND job.source_size_bytes IS NULL
            AND job.reserved_index_count IS NULL
            AND job.reserved_customer_storage_bytes IS NULL
            AND job.reserved_node_transient_bytes IS NULL
            AND job.retryable IS NULL
            AND job.worker_claimed_at IS NULL
            AND job.worker_lease_expires_at IS NULL
            AND job.cancel_requested_at IS NULL
            AND job.resume_intent_generation IS NULL
            AND job.resume_checkpoint IS NULL
            AND job.resume_deadline IS NULL
            AND job.resume_status_observed_at IS NULL
            AND job.resumable IS NULL
            AND job.resume_count IS NULL
            AND job.documents_expected IS NULL
            AND job.documents_imported IS NULL
            AND job.documents_rejected IS NULL
            AND job.settings_applied IS NULL
            AND job.settings_unsupported IS NULL
            AND job.synonyms_expected IS NULL
            AND job.synonyms_imported IS NULL
            AND job.synonyms_rejected IS NULL
            AND job.rules_expected IS NULL
            AND job.rules_imported IS NULL
            AND job.rules_rejected IS NULL
            AND job.warnings IS NULL
            AND job.error_code IS NULL
            AND job.error_message IS NULL
            AND job.status IS NULL
        ) AS non_opaque_algolia_columns_null
    FROM seeded
    JOIN algolia_import_jobs job ON job.id = seeded.id
)
SELECT jsonb_build_object(
    'customer_absent', NOT EXISTS (
        SELECT 1 FROM customers WHERE id = :'he_customer_id'::uuid
    ),
    'target_dependents_absent', NOT EXISTS (
        SELECT 1 FROM customer_tenants WHERE customer_id = :'he_customer_id'::uuid
    ) AND NOT EXISTS (
        SELECT 1 FROM customer_deployments WHERE customer_id = :'he_customer_id'::uuid
    ),
    'audit_canary_absent', NOT EXISTS (
        SELECT 1 FROM audit_log
        WHERE target_tenant_id = :'he_customer_id'::uuid
           OR action = 'PII_MATRIX_AUDIT_ACTION_CANARY'
           OR metadata::text LIKE '%PII_MATRIX_AUDIT_METADATA_CANARY%'
    ),
    'tombstones', COALESCE((
        SELECT jsonb_agg(
            jsonb_build_object(
                'case_name', case_name,
                'id', id::text,
                'engine_job_id', engine_job_id::text,
                'destination_vm_id', destination_vm_id::text,
                'publication_disposition', publication_disposition,
                'cleanup_phase', cleanup_phase,
                'engine_ack_state', engine_ack_state,
                'erasure_handle', erasure_handle::text,
                'erased_at', to_char(erased_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
                'tombstone_compacted_at', tombstone_compacted_at,
                'non_opaque_algolia_columns_null', non_opaque_algolia_columns_null,
                'scrub_verdict', CASE WHEN non_opaque_algolia_columns_null THEN 'scrubbed' ELSE 'pii_retained' END
            )
            ORDER BY ordinal
        )
        FROM tombstone_rows
    ), '[]'::jsonb)
)::text;
SQL
}

capture_hard_erase_matrix_snapshot() {
    local snapshot

    snapshot="$(
        hard_erase_matrix_snapshot_sql | run_probe_psql -v ON_ERROR_STOP=1 -tA \
            -v he_customer_id="$HARD_ERASE_CUSTOMER_ID" \
            -v he_seeded_rows="$HARD_ERASE_SEEDED_IDS"
    )" || die "hard erase matrix snapshot query failed"
    canonical_json "$snapshot"
}

require_hard_erase_matrix_snapshot() {
    python3 - "$HARD_ERASE_SEEDED_IDS" "$1" "$2" "$3" <<'PY'
import datetime as dt
import json
import re
import sys

seeded_payload, snapshot_payload, before_raw, after_raw = sys.argv[1:]
case_order = [
    "committed",
    "ambiguous",
    "pre_linkage",
    "cancelling",
    "cancelled_before_ack",
    "failed_resumable_with_lease",
    "credential_accepted_before_socket",
    "resuming",
    "resume_deadline_race",
    "local_no_dispatch",
    "seal_tombstone",
    "ambiguous_publication",
]
expected_opaque = {
    "committed": ("cccccccc-cccc-cccc-cccc-cccccccc0001", "eeeeeeee-eeee-eeee-eeee-eeeeeeee0001", "unchanged", "exact_target_absence_required", "pending"),
    "ambiguous": ("cccccccc-cccc-cccc-cccc-cccccccc0002", "eeeeeeee-eeee-eeee-eeee-eeeeeeee0002", "unknown", "exact_target_absence_required", "pending"),
    "pre_linkage": (None, None, "not_started", "exact_target_absence_required", "pending"),
    "cancelling": ("cccccccc-cccc-cccc-cccc-cccccccc0004", "eeeeeeee-eeee-eeee-eeee-eeeeeeee0004", "unchanged", "exact_target_absence_required", "pending"),
    "cancelled_before_ack": ("cccccccc-cccc-cccc-cccc-cccccccc0005", "eeeeeeee-eeee-eeee-eeee-eeeeeeee0005", "unchanged", "exact_target_absence_required", "outbox_pending"),
    "failed_resumable_with_lease": ("cccccccc-cccc-cccc-cccc-cccccccc0006", "eeeeeeee-eeee-eeee-eeee-eeeeeeee0006", "unchanged", "exact_target_absence_required", "pending"),
    "credential_accepted_before_socket": (None, None, "not_started", "exact_target_absence_required", "pending"),
    "resuming": ("cccccccc-cccc-cccc-cccc-cccccccc0008", "eeeeeeee-eeee-eeee-eeee-eeeeeeee0008", "unchanged", "exact_target_absence_required", "pending"),
    "resume_deadline_race": ("cccccccc-cccc-cccc-cccc-cccccccc0009", "eeeeeeee-eeee-eeee-eeee-eeeeeeee0009", "unchanged", "exact_target_absence_required", "pending"),
    "local_no_dispatch": (None, None, "not_started", "engine_disposition_required", "not_applicable"),
    "seal_tombstone": (None, None, "not_started", "engine_disposition_required", "seal_acknowledged"),
    "ambiguous_publication": ("cccccccc-cccc-cccc-cccc-cccccccc0012", "eeeeeeee-eeee-eeee-eeee-eeeeeeee0012", "unknown", "exact_target_absence_required", "pending"),
}
uuid_pattern = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def parse_clock(label, raw):
    if not raw:
        raise SystemExit(f"hard erase matrix {label} DB clock missing")
    try:
        return dt.datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError as exc:
        raise SystemExit(f"hard erase matrix {label} DB clock malformed: {raw}") from exc


before = parse_clock("before", before_raw)
after = parse_clock("after", after_raw)
if before > after:
    raise SystemExit("hard erase matrix DB clock bounds are reversed")

seeded = json.loads(seeded_payload)
if not isinstance(seeded, list) or not seeded:
    raise SystemExit("hard erase matrix seed returned no rows")
if len(seeded) != len(case_order) or [row.get("case_name") for row in seeded] != case_order:
    raise SystemExit("hard erase matrix seed must include the 12 canonical cases in order")
seeded_ids = [row.get("id") for row in seeded]
if any(not isinstance(value, str) or not uuid_pattern.match(value) for value in seeded_ids):
    raise SystemExit("hard erase matrix seed returned malformed job IDs")
if len(seeded_ids) != len(set(seeded_ids)):
    raise SystemExit("hard erase matrix seed IDs must be unique")

snapshot = json.loads(snapshot_payload)
if snapshot.get("customer_absent") is not True:
    raise SystemExit("hard erase matrix customer row must be absent")
if snapshot.get("target_dependents_absent") is not True:
    raise SystemExit("hard erase matrix target-dependent rows must be absent")
if snapshot.get("audit_canary_absent") is not True:
    raise SystemExit("hard erase matrix seeded customer audit canary must be absent")

rows = snapshot.get("tombstones")
if not isinstance(rows, list) or len(rows) != len(case_order):
    raise SystemExit("hard erase matrix snapshot must retain exactly 12 scoped rows")
if [row.get("id") for row in rows] != seeded_ids:
    raise SystemExit("hard erase matrix snapshot IDs must match seeded IDs exactly once")
if [row.get("case_name") for row in rows] != case_order:
    raise SystemExit("hard erase matrix snapshot cases must remain in canonical order")

evidence = []
for row in rows:
    name = row["case_name"]
    engine_job_id, destination_vm_id, publication, cleanup, ack = expected_opaque[name]
    checks = {
        "engine_job_id": engine_job_id,
        "destination_vm_id": destination_vm_id,
        "publication_disposition": publication,
        "cleanup_phase": cleanup,
        "engine_ack_state": ack,
    }
    for key, expected in checks.items():
        if row.get(key) != expected:
            raise SystemExit(f"{name} {key} expected {expected}, got {row.get(key)}")
    if not row.get("erasure_handle") or not uuid_pattern.match(row["erasure_handle"]):
        raise SystemExit(f"{name} erasure_handle must be populated")
    if row.get("tombstone_compacted_at") is not None:
        raise SystemExit(f"{name} tombstone_compacted_at must be null")
    if row.get("non_opaque_algolia_columns_null") is not True:
        raise SystemExit(f"{name} non-opaque Algolia columns must be scrubbed")
    erased_at = parse_clock(f"{name} erased_at", row.get("erased_at"))
    if erased_at < before or erased_at > after:
        raise SystemExit(f"{name} erased_at outside hard-erasure DB clock window")
    evidence.append({
        "case_name": name,
        "captured_id": row["id"],
        "retained_opaque_state": checks,
        "scrub_verdict": row.get("scrub_verdict"),
    })

print(json.dumps({
    "status": "passed",
    "seeded_count": len(seeded_ids),
    "retained_count": len(rows),
    "evidence": evidence,
}, separators=(",", ":"), sort_keys=True))
PY
}

exercise_hard_erase_tombstone_matrix() {
    local before_clock after_clock validated

    hard_erase_register_and_login
    admin_call DELETE "/admin/tenants/${HARD_ERASE_CUSTOMER_ID}"
    expect_status "hard erase matrix soft-delete precondition" "204"
    seed_hard_erase_matrix
    before_clock="$(capture_hard_erase_matrix_clock)" \
        || die "hard erase matrix before DB clock query failed"
    admin_call POST "/admin/customers/${HARD_ERASE_CUSTOMER_ID}/hard-erase"
    expect_status "hard erase admin route" "204"
    after_clock="$(capture_hard_erase_matrix_clock)" \
        || die "hard erase matrix after DB clock query failed"
    HARD_ERASE_SNAPSHOT="$(capture_hard_erase_matrix_snapshot)"
    validated="$(require_hard_erase_matrix_snapshot "$HARD_ERASE_SNAPSHOT" "$before_clock" "$after_clock")" \
        || die "$validated"
    HARD_ERASE_STATUS="$(json_field "$validated" status)"
    HARD_ERASE_SEEDED_COUNT="$(json_field "$validated" seeded_count)"
    HARD_ERASE_RETAINED_COUNT="$(json_field "$validated" retained_count)"
    HARD_ERASE_EVIDENCE="$(python3 - "$validated" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
print(json.dumps(payload["evidence"], separators=(",", ":"), sort_keys=True))
PY
    )"
}

soft_delete_stale_job_id() {
    case "$1" in
        replay) echo "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01" ;;
        cancel) echo "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa02" ;;
        resume) echo "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa03" ;;
        elapsed) echo "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa04" ;;
        state) echo "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa05" ;;
        ack) echo "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa06" ;;
        finalize) echo "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa07" ;;
        gc) echo "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa08" ;;
        reservation) echo "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa09" ;;
        resume_intent) echo "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa10" ;;
        *) die "unknown stale matrix job id: $1" ;;
    esac
}

soft_delete_stale_matrix_seed_sql() {
    cat <<'SQL'
-- catalog_service_window_soft_delete_stale_matrix_seed: deleted generation-fenced import jobs.
WITH fenced_customer AS (
    UPDATE customers
    SET status = 'active',
        lifecycle_generation = :'sd_generation'::bigint,
        deleted_at = NULL,
        updated_at = NOW()
    WHERE id = :'sd_customer_id'::uuid
    RETURNING id
),
seed_vm AS (
    INSERT INTO vm_inventory (
        id, region, provider, hostname, flapjack_url, capacity, current_load, status
    )
    VALUES (
        md5(:'sd_customer_id' || 'stale-vm')::uuid, :'probe_region', 'aws',
        'catalog-service-window-soft-delete-stale', :'probe_engine_url',
        '{"cpu_weight":8,"mem_rss_bytes":8589934592,"disk_bytes":107374182400,"query_rps":1000,"indexing_rps":100}'::jsonb,
        '{}'::jsonb, 'active'
    )
    ON CONFLICT (id) DO UPDATE
    SET region = EXCLUDED.region, flapjack_url = EXCLUDED.flapjack_url,
        status = 'active', updated_at = NOW()
    RETURNING id
),
seed_deployment AS (
    INSERT INTO customer_deployments (
        id, customer_id, node_id, region, vm_type, vm_provider, ip_address,
        status, flapjack_url, health_status
    )
    VALUES (
        md5(:'sd_customer_id' || 'stale-deploy')::uuid, :'sd_customer_id'::uuid,
        'catalog-service-window-soft-delete-stale-node', :'probe_region', 'shared',
        'aws', '127.0.0.1', 'running', :'probe_engine_url', 'healthy'
    )
    ON CONFLICT (id) DO UPDATE
    SET customer_id = EXCLUDED.customer_id, status = 'running',
        flapjack_url = EXCLUDED.flapjack_url, health_status = 'healthy'
    RETURNING id
),
seed_tenant AS (
    INSERT INTO customer_tenants (
        customer_id, tenant_id, deployment_id, vm_id, tier, cold_snapshot_id, service_type
    )
    VALUES (
        :'sd_customer_id'::uuid, :'sd_index', (SELECT id FROM seed_deployment),
        (SELECT id FROM seed_vm), 'active', NULL, 'flapjack'
    )
    ON CONFLICT (customer_id, tenant_id) DO UPDATE
    SET deployment_id = EXCLUDED.deployment_id, vm_id = EXCLUDED.vm_id,
        tier = 'active', cold_snapshot_id = NULL, service_type = 'flapjack'
    RETURNING customer_id
),
job_fixture(id, suffix, idempotency_key, status, publication_disposition, engine_ack_state, dispatch_intent_state, engine_job_id, resumable, resume_deadline, terminal_at, reserved_index_count) AS (
    VALUES
        (:'replay_job_id'::uuid, 'replay', 'stale-replay-admission', 'queued', 'not_started', 'pending', 'absent', NULL::uuid, FALSE, NULL::timestamptz, NULL::timestamptz, 1),
        (:'cancel_job_id'::uuid, 'cancel', 'stale-cancel', 'queued', 'not_started', 'pending', 'committed', md5(:'sd_customer_id' || 'cancel-engine')::uuid, FALSE, NULL::timestamptz, NULL::timestamptz, 1),
        (:'resume_job_id'::uuid, 'resume', 'stale-resume', 'failed', 'unchanged', 'pending', 'committed', md5(:'sd_customer_id' || 'resume-engine')::uuid, TRUE, NOW() + INTERVAL '1 hour', NULL::timestamptz, 1),
        (:'elapsed_job_id'::uuid, 'elapsed', 'stale-elapsed', 'failed', 'unchanged', 'pending', 'committed', md5(:'sd_customer_id' || 'elapsed-engine')::uuid, TRUE, NOW() - INTERVAL '1 hour', NULL::timestamptz, 1),
        (:'state_job_id'::uuid, 'state', 'stale-state', 'copying_documents', 'not_started', 'pending', 'committed', md5(:'sd_customer_id' || 'state-engine')::uuid, FALSE, NULL::timestamptz, NULL::timestamptz, 0),
        (:'ack_job_id'::uuid, 'ack', 'stale-ack', 'completed', 'promoted', 'outbox_pending', 'committed', md5(:'sd_customer_id' || 'ack-engine')::uuid, FALSE, NULL::timestamptz, NOW() - INTERVAL '1 hour', 0),
        (:'finalize_job_id'::uuid, 'finalize', 'stale-finalize', 'verifying', 'not_started', 'pending', 'committed', md5(:'sd_customer_id' || 'finalize-engine')::uuid, FALSE, NULL::timestamptz, NULL::timestamptz, 0),
        (:'gc_job_id'::uuid, 'gc', 'stale-gc', 'completed', 'promoted', 'acknowledged', 'committed', md5(:'sd_customer_id' || 'gc-engine')::uuid, FALSE, NULL::timestamptz, NOW() - INTERVAL '100 days', 0),
        (:'reservation_job_id'::uuid, 'reservation', 'stale-reservation', 'queued', 'not_started', 'pending', 'absent', NULL::uuid, FALSE, NULL::timestamptz, NULL::timestamptz, 1),
        (:'resume_intent_job_id'::uuid, 'resume-intent', 'stale-resume-intent', 'failed', 'unchanged', 'pending', 'committed', md5(:'sd_customer_id' || 'resume-intent-engine')::uuid, TRUE, NOW() + INTERVAL '1 hour', NULL::timestamptz, 1)
),
seed_jobs AS (
    INSERT INTO algolia_import_jobs (
        id, customer_id, tenant_id, algolia_app_id, destination_kind, logical_target,
        destination_region, destination_deployment_id, destination_vm_id, physical_uid,
        source_name, idempotency_key, canonical_fingerprint, routing_identity,
        source_size_bytes, reserved_index_count, reserved_customer_storage_bytes,
        reserved_node_transient_bytes, lifecycle_generation, status,
        publication_disposition, engine_ack_state, dispatch_intent_state, engine_job_id,
        resumable, resume_checkpoint, resume_status_observed_at, resume_deadline,
        terminal_at, retryable
    )
    SELECT
        id, :'sd_customer_id'::uuid, :'sd_index' || '-' || suffix, 'CATALOGSERVICEWINDOW',
        'replace', :'sd_index' || '-' || suffix, :'probe_region', (SELECT id FROM seed_deployment),
        (SELECT id FROM seed_vm), :'sd_index' || '-' || suffix, :'sd_index',
        idempotency_key, 'catalog-service-window-soft-delete-stale-' || suffix,
        'catalog-service-window-soft-delete-stale-routing-' || suffix, 1,
        reserved_index_count, 1, 0, :'sd_generation'::bigint, status,
        publication_disposition, engine_ack_state, dispatch_intent_state, engine_job_id,
        resumable,
        CASE WHEN resumable THEN 'checkpoint-' || suffix ELSE NULL END,
        CASE WHEN resumable THEN NOW() - INTERVAL '2 hours' ELSE NULL END,
        resume_deadline, terminal_at, resumable
    FROM job_fixture
    ON CONFLICT (id) DO UPDATE
    SET status = EXCLUDED.status,
        publication_disposition = EXCLUDED.publication_disposition,
        engine_ack_state = EXCLUDED.engine_ack_state,
        dispatch_intent_state = EXCLUDED.dispatch_intent_state,
        engine_job_id = EXCLUDED.engine_job_id,
        lifecycle_generation = EXCLUDED.lifecycle_generation,
        resumable = EXCLUDED.resumable,
        resume_checkpoint = EXCLUDED.resume_checkpoint,
        resume_status_observed_at = EXCLUDED.resume_status_observed_at,
        resume_deadline = EXCLUDED.resume_deadline,
        terminal_at = EXCLUDED.terminal_at,
        reserved_index_count = EXCLUDED.reserved_index_count
    RETURNING id
)
SELECT CASE
    WHEN EXISTS (SELECT 1 FROM fenced_customer)
     AND EXISTS (SELECT 1 FROM seed_tenant)
     AND (SELECT count(*) FROM seed_jobs) = 10
    THEN 'seeded'
    ELSE 'missing_soft_delete_stale_matrix_rows'
END;
SQL
}

seed_soft_delete_stale_matrix() {
    local seed_result

    seed_result="$(
        soft_delete_stale_matrix_seed_sql | run_probe_psql -v ON_ERROR_STOP=1 -tA \
            -v sd_customer_id="$SOFT_DELETE_ARM_CUSTOMER_ID" \
            -v sd_index="$SOFT_DELETE_STALE_INDEX" \
            -v sd_generation="$SOFT_DELETE_FENCE_GENERATION" \
            -v probe_region="$PROBE_REGION" \
            -v probe_engine_url="$PROBE_ENGINE_URL" \
            -v replay_job_id="$(soft_delete_stale_job_id replay)" \
            -v cancel_job_id="$(soft_delete_stale_job_id cancel)" \
            -v resume_job_id="$(soft_delete_stale_job_id resume)" \
            -v elapsed_job_id="$(soft_delete_stale_job_id elapsed)" \
            -v state_job_id="$(soft_delete_stale_job_id state)" \
            -v ack_job_id="$(soft_delete_stale_job_id ack)" \
            -v finalize_job_id="$(soft_delete_stale_job_id finalize)" \
            -v gc_job_id="$(soft_delete_stale_job_id gc)" \
            -v reservation_job_id="$(soft_delete_stale_job_id reservation)" \
            -v resume_intent_job_id="$(soft_delete_stale_job_id resume_intent)"
    )" || die "soft delete stale operation seed failed"

    [ "$seed_result" = "seeded" ] \
        || die "soft delete stale operation seed did not persist matrix rows: $seed_result"
}

soft_delete_stale_matrix_snapshot_sql() {
    cat <<'SQL'
-- catalog_service_window_soft_delete_stale_matrix_snapshot: canonical retained stale-operation evidence.
SELECT jsonb_build_object(
    'customer', (
        SELECT jsonb_build_object(
            'status', status,
            'lifecycle_generation', lifecycle_generation,
            'deleted_at_present', deleted_at IS NOT NULL
        )
        FROM customers
        WHERE id = :'sd_customer_id'::uuid
    ),
    'evidence', jsonb_build_object(
        'catalog', (
            SELECT jsonb_build_object('customer_id', customer_id::text, 'tenant_id', tenant_id, 'tier', tier)
            FROM customer_tenants
            WHERE customer_id = :'sd_customer_id'::uuid AND tenant_id = :'sd_index'
        ),
        'routing', (
            SELECT jsonb_build_object(
                'deployment_status', deployment.status,
                'deployment_flapjack_url', deployment.flapjack_url,
                'vm_status', vm.status
            )
            FROM customer_tenants tenant
            JOIN customer_deployments deployment ON deployment.id = tenant.deployment_id
            JOIN vm_inventory vm ON vm.id = tenant.vm_id
            WHERE tenant.customer_id = :'sd_customer_id'::uuid
              AND tenant.tenant_id = :'sd_index'
        ),
        'jobs', (
            SELECT jsonb_object_agg(
                idempotency_key,
                jsonb_build_object(
                    'id', id::text,
                    'status', status,
                    'publication_disposition', publication_disposition,
                    'engine_ack_state', engine_ack_state,
                    'dispatch_intent_state', dispatch_intent_state,
                    'reserved_index_count', reserved_index_count,
                    'lifecycle_generation', lifecycle_generation,
                    'resume_intent_generation', resume_intent_generation,
                    'resumable', resumable
                )
                ORDER BY idempotency_key
            )
            FROM algolia_import_jobs
            WHERE customer_id = :'sd_customer_id'::uuid
              AND logical_target LIKE :'sd_index' || '-%'
              AND erased_at IS NULL
        )
    )
)::text;
SQL
}

capture_soft_delete_stale_matrix_snapshot() {
    local snapshot

    snapshot="$(
        soft_delete_stale_matrix_snapshot_sql | run_probe_psql -v ON_ERROR_STOP=1 -tA \
            -v sd_customer_id="$SOFT_DELETE_ARM_CUSTOMER_ID" \
            -v sd_index="$SOFT_DELETE_STALE_INDEX"
    )" || die "soft delete stale operation snapshot query failed"
    canonical_json "$snapshot"
}

require_soft_delete_stale_matrix_snapshot() {
    python3 - "$1" "$2" "$SOFT_DELETE_FENCE_GENERATION" <<'PY'
import json
import sys

actual = json.loads(sys.argv[1])
baseline = json.loads(sys.argv[2])
generation = int(sys.argv[3])

customer = actual.get("customer")
if customer is None:
    raise SystemExit("soft delete stale operation snapshot missing customer row")
if customer.get("status") != "deleted":
    raise SystemExit("soft delete stale operation customer must remain deleted")
if customer.get("lifecycle_generation") != generation + 1:
    raise SystemExit("soft delete stale operation customer generation must remain G + 1")
if customer.get("deleted_at_present") is not True:
    raise SystemExit("soft delete stale operation customer must retain deleted_at")

evidence = actual.get("evidence")
if evidence is None:
    raise SystemExit("soft delete stale operation snapshot missing retained evidence")
for key in ("catalog", "routing", "jobs"):
    if evidence.get(key) is None:
        raise SystemExit(f"soft delete stale operation snapshot missing {key} row")
expected_jobs = {
    "stale-replay-admission",
    "stale-cancel",
    "stale-resume",
    "stale-elapsed",
    "stale-state",
    "stale-ack",
    "stale-finalize",
    "stale-gc",
    "stale-reservation",
    "stale-resume-intent",
}
jobs = evidence.get("jobs")
if not isinstance(jobs, dict) or set(jobs) != expected_jobs:
    raise SystemExit("soft delete stale operation snapshot missing import operation rows")
if evidence != baseline.get("evidence"):
    raise SystemExit("soft delete stale operation retained evidence changed")
PY
}

soft_delete_stale_repo_probe_sql() {
    cat <<'SQL'
-- catalog_service_window_soft_delete_stale_matrix_repo_probe: repository-generation-fence selector probes.
WITH elapsed_claim AS (
    SELECT job.id
    FROM algolia_import_jobs job
    JOIN customers customer ON customer.id = job.customer_id
    WHERE job.id = :'elapsed_job_id'::uuid
      AND job.resumable = TRUE
      AND customer.status = 'active'
      AND customer.lifecycle_generation = job.lifecycle_generation
      AND job.resume_deadline <= NOW()
      AND job.status IN ('failed', 'interrupted')
      AND job.engine_ack_state = 'pending'
      AND job.publication_disposition = 'unchanged'
      AND job.dispatch_intent_state IN ('committed', 'ambiguous')
      AND job.engine_job_id IS NOT NULL
),
state_update AS (
    UPDATE algolia_import_jobs job
    SET updated_at = updated_at
    FROM customers customer
    WHERE job.id = :'state_job_id'::uuid
      AND customer.id = job.customer_id
      AND customer.status = 'active'
      AND customer.lifecycle_generation = job.lifecycle_generation
    RETURNING job.id
),
terminal_ack AS (
    SELECT job.id
    FROM algolia_import_jobs job
    JOIN customers customer ON customer.id = job.customer_id
    WHERE job.id = :'ack_job_id'::uuid
      AND customer.status = 'active'
      AND customer.lifecycle_generation = job.lifecycle_generation
      AND job.engine_ack_state = 'outbox_pending'
      AND job.terminal_at IS NOT NULL
),
terminal_finalization AS (
    UPDATE algolia_import_jobs job
    SET updated_at = updated_at
    FROM customers customer
    WHERE job.id = :'finalize_job_id'::uuid
      AND customer.id = job.customer_id
      AND customer.status = 'active'
      AND customer.lifecycle_generation = job.lifecycle_generation
    RETURNING job.id
),
retention_gc AS (
    SELECT job.id
    FROM algolia_import_jobs job
    JOIN customers customer ON customer.id = job.customer_id
    WHERE job.id = :'gc_job_id'::uuid
      AND customer.status = 'active'
      AND customer.lifecycle_generation = job.lifecycle_generation
      AND job.terminal_at <= NOW() - INTERVAL '90 days'
      AND job.engine_ack_state IN ('not_applicable', 'seal_acknowledged', 'acknowledged')
      AND job.publication_disposition <> 'unknown'
      AND job.resumable = FALSE
      AND job.status IN ('cancelled', 'completed', 'completed_with_warnings', 'failed', 'interrupted')
),
active_reservation AS (
    SELECT job.id
    FROM algolia_import_jobs job
    JOIN customers customer ON customer.id = job.customer_id
    WHERE job.id = :'reservation_job_id'::uuid
      AND customer.status = 'active'
      AND customer.lifecycle_generation = job.lifecycle_generation
      AND job.reserved_index_count > 0
),
resume_intent AS (
    UPDATE algolia_import_jobs job
    SET updated_at = updated_at
    FROM customers customer
    WHERE job.id = :'resume_intent_job_id'::uuid
      AND customer.id = job.customer_id
      AND customer.status = 'active'
      AND customer.lifecycle_generation = job.lifecycle_generation
    RETURNING job.id
)
SELECT jsonb_build_object(
    'stale_elapsed_resume_claim_status', CASE WHEN EXISTS (SELECT 1 FROM elapsed_claim) THEN 'accepted' ELSE 'excluded' END,
    'stale_state_update_status', CASE WHEN EXISTS (SELECT 1 FROM state_update) THEN 'accepted' ELSE 'conflict' END,
    'stale_terminal_ack_status', CASE WHEN EXISTS (SELECT 1 FROM terminal_ack) THEN 'accepted' ELSE 'excluded' END,
    'stale_terminal_finalization_status', CASE WHEN EXISTS (SELECT 1 FROM terminal_finalization) THEN 'accepted' ELSE 'conflict' END,
    'stale_retention_gc_status', CASE WHEN EXISTS (SELECT 1 FROM retention_gc) THEN 'accepted' ELSE 'excluded' END,
    'stale_active_reservation_status', CASE WHEN EXISTS (SELECT 1 FROM active_reservation) THEN 'accepted' ELSE 'excluded' END,
    'stale_resume_intent_status', CASE WHEN EXISTS (SELECT 1 FROM resume_intent) THEN 'accepted' ELSE 'conflict' END
)::text;
SQL
}

capture_soft_delete_stale_repo_results() {
    local results

    results="$(
        soft_delete_stale_repo_probe_sql | run_probe_psql -v ON_ERROR_STOP=1 -tA \
            -v elapsed_job_id="$(soft_delete_stale_job_id elapsed)" \
            -v state_job_id="$(soft_delete_stale_job_id state)" \
            -v ack_job_id="$(soft_delete_stale_job_id ack)" \
            -v finalize_job_id="$(soft_delete_stale_job_id finalize)" \
            -v gc_job_id="$(soft_delete_stale_job_id gc)" \
            -v reservation_job_id="$(soft_delete_stale_job_id reservation)" \
            -v resume_intent_job_id="$(soft_delete_stale_job_id resume_intent)"
    )" || die "soft delete stale operation repository probe failed"
    canonical_json "$results"
}

require_soft_delete_stale_result() {
    local key="$1"
    local actual="$2"
    local expected="$3"

    [ -n "$actual" ] \
        || die "soft delete stale operation ${key} missing"
    [ "$actual" = "$expected" ] \
        || die "soft delete stale operation ${key} expected ${expected}, got ${actual}"
}

require_soft_delete_stale_route_error() {
    local key="$1"
    local expected_status="$2"
    local expected_code="$3"
    local code

    [ "$HTTP_RESPONSE_CODE" = "$expected_status" ] \
        || die "soft delete stale operation ${key} expected HTTP ${expected_status}, got HTTP ${HTTP_RESPONSE_CODE}: ${HTTP_RESPONSE_BODY}"
    code="$(json_field "$HTTP_RESPONSE_BODY" code)" \
        || code="$(json_field "$HTTP_RESPONSE_BODY" error)" \
        || die "soft delete stale operation ${key} missing"
    require_soft_delete_stale_result "$key" "$code" "$expected_code"
}

soft_delete_stale_destination_token() {
    local provider_token

    tenant_call POST "/migration/algolia/destination-eligibility" "$SOFT_DELETE_ARM_TOKEN" \
        -H "content-type: application/json" \
        -d "{\"phase\":\"provider\",\"mode\":\"create\",\"target\":{\"region\":\"${PROBE_REGION}\",\"name\":\"${SOFT_DELETE_STALE_INDEX}\"}}"
    expect_status "soft delete stale provider eligibility" "200"
    provider_token="$(json_field "$HTTP_RESPONSE_BODY" eligibilityToken)" \
        || die "soft delete stale provider eligibility missing token"

    tenant_call POST "/migration/algolia/destination-eligibility" "$SOFT_DELETE_ARM_TOKEN" \
        -H "content-type: application/json" \
        -d "{\"phase\":\"target\",\"mode\":\"create\",\"target\":{\"region\":\"${PROBE_REGION}\",\"name\":\"${SOFT_DELETE_STALE_INDEX}\"},\"eligibilityToken\":\"${provider_token}\"}"
    expect_status "soft delete stale target eligibility" "200"
    json_field "$HTTP_RESPONSE_BODY" eligibilityToken \
        || die "soft delete stale target eligibility missing token"
}

soft_delete_stale_assert_snapshot_unchanged() {
    local baseline="$1"
    local snapshot

    snapshot="$(capture_soft_delete_stale_matrix_snapshot)" \
        || die "soft delete stale operation snapshot capture failed"
    require_soft_delete_stale_matrix_snapshot "$snapshot" "$baseline" \
        || die "soft delete stale operation retained evidence changed"
}

exercise_soft_delete_stale_operation_matrix() {
    local target_token baseline repo_results engine_before engine_after

    SOFT_DELETE_ARM_PASSWORD="$SOFT_DELETE_STALE_PASSWORD"
    soft_delete_register_and_login "$SOFT_DELETE_STALE_EMAIL" "$SOFT_DELETE_STALE_PASSWORD"
    seed_soft_delete_stale_matrix
    target_token="$(soft_delete_stale_destination_token)"

    soft_delete_admin_route_delete 204
    baseline="$(capture_soft_delete_stale_matrix_snapshot)"
    require_soft_delete_stale_matrix_snapshot "$baseline" "$baseline" \
        || die "soft delete stale operation baseline snapshot invalid"
    engine_before="$(physical_engine_observation_count)"

    tenant_call POST "/migration/algolia/jobs" "$SOFT_DELETE_ARM_TOKEN" \
        -H "content-type: application/json" \
        -H "idempotency-key: stale-new-admission" \
        -d "{\"mode\":\"create\",\"appId\":\"CATALOGSERVICEWINDOW\",\"apiKey\":\"probe-key\",\"sourceName\":\"${SOFT_DELETE_STALE_INDEX}\",\"target\":{\"eligibilityToken\":\"${target_token}\"}}"
    require_soft_delete_stale_route_error "stale_new_admission_status" "400" "destination_changed"
    SOFT_DELETE_STALE_NEW_ADMISSION_STATUS="destination_changed"
    soft_delete_stale_assert_snapshot_unchanged "$baseline"

    tenant_call POST "/migration/algolia/jobs" "$SOFT_DELETE_ARM_TOKEN" \
        -H "content-type: application/json" \
        -H "idempotency-key: stale-replay-admission" \
        -d "{\"mode\":\"create\",\"appId\":\"CATALOGSERVICEWINDOW\",\"apiKey\":\"probe-key\",\"sourceName\":\"${SOFT_DELETE_STALE_INDEX}\",\"target\":{\"eligibilityToken\":\"${target_token}\"}}"
    require_soft_delete_stale_route_error "stale_replay_admission_status" "400" "destination_changed"
    SOFT_DELETE_STALE_REPLAY_ADMISSION_STATUS="destination_changed"
    soft_delete_stale_assert_snapshot_unchanged "$baseline"

    tenant_call POST "/migration/algolia/jobs/$(soft_delete_stale_job_id cancel)/cancel" \
        "$SOFT_DELETE_ARM_TOKEN" -H "content-type: application/json" -d '{}'
    require_soft_delete_stale_route_error "stale_cancel_status" "409" "cancel_not_permitted"
    SOFT_DELETE_STALE_CANCEL_STATUS="cancel_not_permitted"
    soft_delete_stale_assert_snapshot_unchanged "$baseline"

    tenant_call POST "/migration/algolia/jobs/$(soft_delete_stale_job_id resume)/resume" \
        "$SOFT_DELETE_ARM_TOKEN" -H "content-type: application/json" -d '{"apiKey":"probe-key"}'
    require_soft_delete_stale_route_error "stale_resume_status" "409" "not_resumable"
    SOFT_DELETE_STALE_RESUME_STATUS="not_resumable"
    soft_delete_stale_assert_snapshot_unchanged "$baseline"

    repo_results="$(capture_soft_delete_stale_repo_results)"
    SOFT_DELETE_STALE_ELAPSED_RESUME_CLAIM_STATUS="$(json_field "$repo_results" stale_elapsed_resume_claim_status 2>/dev/null || true)"
    SOFT_DELETE_STALE_STATE_UPDATE_STATUS="$(json_field "$repo_results" stale_state_update_status 2>/dev/null || true)"
    SOFT_DELETE_STALE_TERMINAL_ACK_STATUS="$(json_field "$repo_results" stale_terminal_ack_status 2>/dev/null || true)"
    SOFT_DELETE_STALE_TERMINAL_FINALIZATION_STATUS="$(json_field "$repo_results" stale_terminal_finalization_status 2>/dev/null || true)"
    SOFT_DELETE_STALE_RETENTION_GC_STATUS="$(json_field "$repo_results" stale_retention_gc_status 2>/dev/null || true)"
    SOFT_DELETE_STALE_ACTIVE_RESERVATION_STATUS="$(json_field "$repo_results" stale_active_reservation_status 2>/dev/null || true)"
    SOFT_DELETE_STALE_RESUME_INTENT_STATUS="$(json_field "$repo_results" stale_resume_intent_status 2>/dev/null || true)"
    require_soft_delete_stale_result "stale_elapsed_resume_claim_status" "$SOFT_DELETE_STALE_ELAPSED_RESUME_CLAIM_STATUS" "excluded"
    require_soft_delete_stale_result "stale_state_update_status" "$SOFT_DELETE_STALE_STATE_UPDATE_STATUS" "conflict"
    require_soft_delete_stale_result "stale_terminal_ack_status" "$SOFT_DELETE_STALE_TERMINAL_ACK_STATUS" "excluded"
    require_soft_delete_stale_result "stale_terminal_finalization_status" "$SOFT_DELETE_STALE_TERMINAL_FINALIZATION_STATUS" "conflict"
    require_soft_delete_stale_result "stale_retention_gc_status" "$SOFT_DELETE_STALE_RETENTION_GC_STATUS" "excluded"
    require_soft_delete_stale_result "stale_active_reservation_status" "$SOFT_DELETE_STALE_ACTIVE_RESERVATION_STATUS" "excluded"
    require_soft_delete_stale_result "stale_resume_intent_status" "$SOFT_DELETE_STALE_RESUME_INTENT_STATUS" "conflict"
    soft_delete_stale_assert_snapshot_unchanged "$baseline"

    engine_after="$(physical_engine_observation_count)"
    [ "$engine_after" = "$engine_before" ] \
        || die "soft delete stale operations produced engine observations"
    PROHIBITED_ENGINE_OBSERVATIONS="$engine_after"
}

emit_success() {
    require_zero_prohibited_engine_observations "${29}"
    echo "expired_worker_claim_reservation=passed"
    SELECTED_EVIDENCE_TEMPLATE="$SELECTED_EVIDENCE_TEMPLATE" \
    DEFAULT_ORACLE_DISPLAY="$DEFAULT_ORACLE_DISPLAY" \
        python3 - "$INVENTORY_DISPLAY" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" \
        "${10}" "${11}" "${12}" "${13}" "${14}" "${15}" "${16}" "${17}" "${18}" \
        "${19}" "${20}" "${21}" "${22}" "${23}" "${24}" "${25}" "${26}" "${27}" \
        "${28}" "${29}" <<'PY'
import json
import os
import sys

(
    inventory,
    replica,
    customer_restore,
    admin_restore,
    rollback,
    failure,
    expired_route,
    expired_service,
    soft_delete_account_status,
    soft_delete_admin_status,
    soft_delete_account_hidden,
    soft_delete_admin_hidden,
    soft_delete_account_transition,
    soft_delete_admin_transition,
    stale_new_admission,
    stale_replay_admission,
    stale_cancel,
    stale_resume,
    stale_elapsed_resume_claim,
    stale_state_update,
    stale_terminal_ack,
    stale_terminal_finalization,
    stale_retention_gc,
    stale_active_reservation,
    stale_resume_intent,
    hard_erase_status,
    hard_erase_seeded_count,
    hard_erase_retained_count,
    hard_erase_evidence,
    prohibited_engine_observations,
) = sys.argv[1:]
try:
    selected_evidence = json.loads(os.environ["SELECTED_EVIDENCE_TEMPLATE"])
    soft_delete_account_transition = json.loads(soft_delete_account_transition)
    soft_delete_admin_transition = json.loads(soft_delete_admin_transition)
    hard_erase_evidence = json.loads(hard_erase_evidence)
except json.JSONDecodeError as exc:
    raise SystemExit(f"service-window evidence is not structured JSON: {exc}") from exc
operation_results = {
    "expired_worker_claim_route_status": expired_route,
    "expired_worker_claim_service_status": expired_service,
    "stale_state_update_status": stale_state_update,
    "soft_delete_account_route_status": soft_delete_account_status,
    "soft_delete_admin_route_status": soft_delete_admin_status,
    "hard_erase_tombstone_matrix_status": hard_erase_status,
}
for selected in selected_evidence:
    result_key = selected.get("operation_result_key")
    if result_key not in operation_results:
        raise SystemExit(f"service-window selected evidence has unknown result key: {result_key}")
    selected["operation_result"] = operation_results[result_key]
print(json.dumps({
    "status": "pass",
    "inventory": inventory,
    "oracle": os.environ["DEFAULT_ORACLE_DISPLAY"],
    "selected_evidence": selected_evidence,
    "replica_create_status": replica,
    "customer_restore_status": customer_restore,
    "admin_restore_status": admin_restore,
    "rollback_status": rollback,
    "failure_status": failure,
    "expired_worker_claim_route_status": expired_route,
    "expired_worker_claim_service_status": expired_service,
    "prohibited_engine_observations": int(prohibited_engine_observations),
    "soft_delete_account_route_status": soft_delete_account_status,
    "soft_delete_admin_route_status": soft_delete_admin_status,
    "soft_delete_account_hidden_target": soft_delete_account_hidden,
    "soft_delete_admin_hidden_target": soft_delete_admin_hidden,
    "soft_delete_account_transition": soft_delete_account_transition,
    "soft_delete_admin_transition": soft_delete_admin_transition,
    "stale_new_admission_status": stale_new_admission,
    "stale_replay_admission_status": stale_replay_admission,
    "stale_cancel_status": stale_cancel,
    "stale_resume_status": stale_resume,
    "stale_elapsed_resume_claim_status": stale_elapsed_resume_claim,
    "stale_state_update_status": stale_state_update,
    "stale_terminal_ack_status": stale_terminal_ack,
    "stale_terminal_finalization_status": stale_terminal_finalization,
    "stale_retention_gc_status": stale_retention_gc,
    "stale_active_reservation_status": stale_active_reservation,
    "stale_resume_intent_status": stale_resume_intent,
    "hard_erase_tombstone_matrix_status": hard_erase_status,
    "hard_erase_tombstone_matrix_seeded_count": int(hard_erase_seeded_count),
    "hard_erase_tombstone_matrix_retained_count": int(hard_erase_retained_count),
    "hard_erase_tombstone_matrix_evidence": hard_erase_evidence,
}, separators=(",", ":"), sort_keys=True))
PY
    echo "hard_erase_tombstone_matrix=passed"
    echo "soft_delete_generation_fence=passed"
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
    exercise_expired_worker_claim_reservation
    exercise_soft_delete_fence
    exercise_soft_delete_stale_operation_matrix
    exercise_hard_erase_tombstone_matrix
    exercise_migration_windows
    verify_unrelated_tenant_unchanged
    emit_success \
        "$REPLICA_STATUS" \
        "$CUSTOMER_RESTORE_STATUS" \
        "$ADMIN_RESTORE_STATUS" \
        "$ROLLBACK_STATUS" \
        "$FAILURE_STATUS" \
        "$EXPIRED_ROUTE_STATUS" \
        "$EXPIRED_SERVICE_STATUS" \
        "$SOFT_DELETE_ACCOUNT_STATUS" \
        "$SOFT_DELETE_ADMIN_STATUS" \
        "$SOFT_DELETE_ACCOUNT_HIDDEN" \
        "$SOFT_DELETE_ADMIN_HIDDEN" \
        "$SOFT_DELETE_ACCOUNT_TRANSITION" \
        "$SOFT_DELETE_ADMIN_TRANSITION" \
        "$SOFT_DELETE_STALE_NEW_ADMISSION_STATUS" \
        "$SOFT_DELETE_STALE_REPLAY_ADMISSION_STATUS" \
        "$SOFT_DELETE_STALE_CANCEL_STATUS" \
        "$SOFT_DELETE_STALE_RESUME_STATUS" \
        "$SOFT_DELETE_STALE_ELAPSED_RESUME_CLAIM_STATUS" \
        "$SOFT_DELETE_STALE_STATE_UPDATE_STATUS" \
        "$SOFT_DELETE_STALE_TERMINAL_ACK_STATUS" \
        "$SOFT_DELETE_STALE_TERMINAL_FINALIZATION_STATUS" \
        "$SOFT_DELETE_STALE_RETENTION_GC_STATUS" \
        "$SOFT_DELETE_STALE_ACTIVE_RESERVATION_STATUS" \
        "$SOFT_DELETE_STALE_RESUME_INTENT_STATUS" \
        "$HARD_ERASE_STATUS" \
        "$HARD_ERASE_SEEDED_COUNT" \
        "$HARD_ERASE_RETAINED_COUNT" \
        "$HARD_ERASE_EVIDENCE" \
        "$PROHIBITED_ENGINE_OBSERVATIONS"
}

SELECTED_EVIDENCE_TEMPLATE="$(validate_catalog_acceptance_fixtures)"

if [ "$START_STACK" -eq 1 ]; then
    STACK_STARTED=1
    FJCLOUD_INTEGRATION_API_BINARY="$API_BINARY" \
    FJCLOUD_INTEGRATION_ENGINE_BINARY="$ENGINE_BINARY" \
    FJCLOUD_INTEGRATION_SKIP_METERING_AGENT=1 \
    FJCLOUD_INTEGRATION_PID_DIR="$RUNTIME_DIR" \
    ENGINE_INDEX_IDENTITY_OBSERVED_CALLERS_FILE="$OBSERVED_CALLERS_FILE" \
    FJCLOUD_INTEGRATION_API_RECOVERY_SEAMS=1 \
    FJCLOUD_ALGOLIA_MIGRATION_ENABLED=true \
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
