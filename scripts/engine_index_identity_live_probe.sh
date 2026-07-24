#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=scripts/lib/live_probe_common.sh
source "$SCRIPT_DIR/lib/live_probe_common.sh"

API_BINARY=""
ENGINE_BINARY=""
INVENTORY=""

die() {
    echo "[engine-index-identity-live-probe] ERROR: $*" >&2
    exit 1
}

usage() {
    cat >&2 <<'USAGE'
Usage: engine_index_identity_live_probe.sh --api-binary <absolute> --engine-binary <absolute> --inventory <json>
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
            shift 2
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
[ -n "$INVENTORY" ] || die "--inventory is required"
require_absolute_executable "--api-binary" "$API_BINARY"
require_absolute_executable "--engine-binary" "$ENGINE_BINARY"
require_file "--inventory" "$INVENTORY"

OBSERVED_CALLERS_FILE="${ENGINE_INDEX_IDENTITY_OBSERVED_CALLERS_FILE:-}"
if [ -z "$OBSERVED_CALLERS_FILE" ]; then
    OBSERVED_CALLERS_FILE="$(mktemp -t engine-index-identity-observed.XXXXXX.json)"
    rm -f "$OBSERVED_CALLERS_FILE"
fi
export ENGINE_INDEX_IDENTITY_OBSERVED_CALLERS_FILE="$OBSERVED_CALLERS_FILE"

RUNTIME_DIR="${FJCLOUD_INTEGRATION_PID_DIR:-$(mktemp -d -t engine-index-identity-runtime.XXXXXX)}"
export FJCLOUD_INTEGRATION_PID_DIR="$RUNTIME_DIR"
API_PORT="${API_PORT:-3099}"
API_URL="${ENGINE_INDEX_IDENTITY_API_URL:-http://localhost:${API_PORT}}"
PROBE_EMAIL="${ENGINE_INDEX_IDENTITY_PROBE_EMAIL:-engine-index-identity-probe@example.com}"
PROBE_PASSWORD="${ENGINE_INDEX_IDENTITY_PROBE_PASSWORD:-Integration-Test-Pass-1!}"
PROBE_INDEX="${ENGINE_INDEX_IDENTITY_PROBE_INDEX:-engine_identity_source}"
PROBE_REGION="${ENGINE_INDEX_IDENTITY_PROBE_REGION:-us-east-1}"
PROBE_REPLICA_REGION="${ENGINE_INDEX_IDENTITY_PROBE_REPLICA_REGION:-eu-central-1}"
PROBE_DEST_VM_ID="${ENGINE_INDEX_IDENTITY_DEST_VM_ID:-}"
PROBE_DEST_SEED_INDEX="${ENGINE_INDEX_IDENTITY_DEST_SEED_INDEX:-engine_identity_destination_seed}"
PROBE_ENGINE_URL="${ENGINE_INDEX_IDENTITY_ENGINE_URL:-http://127.0.0.1:${FLAPJACK_PORT:-7799}}"
PROBE_ADMIN_KEY="${ENGINE_INDEX_IDENTITY_ADMIN_KEY:-engine-index-identity-admin-key}"
PROBE_NODE_API_KEY="${ENGINE_INDEX_IDENTITY_PROBE_NODE_API_KEY:-engine-index-identity-node-api-key}"
ISOLATION_EMAIL="${ENGINE_INDEX_IDENTITY_ISOLATION_EMAIL:-engine-index-identity-isolation@example.com}"
ISOLATION_PASSWORD="${ENGINE_INDEX_IDENTITY_ISOLATION_PASSWORD:-Integration-Isolation-Pass-1!}"
PROBE_CUSTOMER_ID=""
PROBE_AUTH_HEADER_PROOF="$(
    printf '%s' "$PROBE_NODE_API_KEY" \
        | python3 -c 'import hashlib, sys; print("sha256:" + hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
)"

[ -n "$PROBE_NODE_API_KEY" ] || die "probe node API key must not be empty"

STACK_STARTED=0
cleanup() {
    if [ "$STACK_STARTED" -eq 1 ]; then
        FJCLOUD_INTEGRATION_PID_DIR="$RUNTIME_DIR" \
            INTEGRATION_DB="${INTEGRATION_DB:-engine_index_identity_live_probe}" \
            bash "$SCRIPT_DIR/integration-down.sh" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

validate_inventory() {
    python3 - "$INVENTORY" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as handle:
        inventory = json.load(handle)
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"inventory is not readable structured JSON: {exc}")

expected_count = inventory.get("expected_caller_count")
callers = inventory.get("callers")
if not isinstance(expected_count, int) or expected_count <= 0:
    raise SystemExit("expected_caller_count must be greater than zero")
if not isinstance(callers, list) or len(callers) != expected_count:
    raise SystemExit("inventory callers length must equal expected_caller_count")

ids = []
for row in callers:
    if not isinstance(row, dict):
        raise SystemExit("inventory callers must be objects")
    caller_id = row.get("caller_id")
    if not isinstance(caller_id, str) or not caller_id:
        raise SystemExit("inventory caller_id values must be non-empty strings")
    expected_path = row.get("expected_upstream_path")
    expected_headers = row.get("expected_upstream_headers")
    if not isinstance(expected_headers, dict):
        raise SystemExit("inventory expected_upstream_headers must be an object")
    if row.get("expected_upstream_kind") == "physical_uid":
        if not isinstance(expected_path, str) or not expected_path.startswith("/"):
            raise SystemExit("physical inventory caller must define expected_upstream_path")
        if set(expected_headers) != {
            "x-algolia-api-key",
            "x-algolia-application-id",
        }:
            raise SystemExit("physical inventory caller must define exact upstream headers")
        if expected_headers.get("x-algolia-api-key") != "sha256:*":
            raise SystemExit("physical inventory caller must require observed auth header proof")
    elif expected_path is not None or expected_headers:
        raise SystemExit("catalog-only inventory caller cannot define upstream values")
    ids.append(caller_id)

if len(ids) != len(set(ids)):
    raise SystemExit("inventory caller_id values must be unique")
PY
}

validate_observed_artifact() {
    python3 - "$INVENTORY" "$OBSERVED_CALLERS_FILE" "$PROBE_CUSTOMER_ID" "$PROBE_INDEX" "$PROBE_AUTH_HEADER_PROOF" <<'PY'
import json
import re
import sys

inventory_path, observed_path, customer_id, index_name, expected_auth_proof = sys.argv[1:]

try:
    with open(inventory_path, encoding="utf-8") as handle:
        inventory = json.load(handle)
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"inventory is not readable structured JSON: {exc}")

try:
    with open(observed_path, encoding="utf-8") as handle:
        observed = json.load(handle)
except FileNotFoundError:
    raise SystemExit("observed caller artifact is missing")
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"observed caller artifact is not structured JSON: {exc}")

if observed.get("status") in {"skipped", "unchecked"}:
    raise SystemExit("observed caller artifact reports skipped or unchecked state")

checks = observed.get("checks")
if not isinstance(checks, dict) or any(value != "checked" for value in checks.values()):
    raise SystemExit("observed caller artifact reports skipped or unchecked state")

expected_ids = sorted(row["caller_id"] for row in inventory["callers"])
inventory_by_id = {row["caller_id"]: row for row in inventory["callers"]}
observed_rows = observed.get("callers")
if not isinstance(observed_rows, list):
    raise SystemExit("observed caller artifact is missing callers")

expected_physical_uid = f"{customer_id.replace('-', '')}_{index_name}"
observed_ids = []
for row in observed_rows:
    if not isinstance(row, dict) or not isinstance(row.get("caller_id"), str):
        raise SystemExit("observed caller artifact has invalid caller rows")
    caller_id = row["caller_id"]
    observed_ids.append(caller_id)
    expected = inventory_by_id.get(caller_id)
    if expected is None:
        continue

    expected_kind = expected["expected_upstream_kind"]
    if row.get("observed_upstream_kind") != expected_kind:
        raise SystemExit("observed upstream kind does not match inventory")

    if row.get("auth_secret_owner") != expected["auth_secret_owner"]:
        raise SystemExit("auth secret owner does not match inventory")

    http_status = row.get("http_status")
    if (
        not isinstance(http_status, int)
        or http_status < 200
        or http_status >= 300
        or http_status == 202
    ):
        raise SystemExit("observed HTTP status is not terminal success")

    if row.get("terminal_migration_state") != "completed":
        raise SystemExit("terminal migration state is not completed")

    if expected_kind == "physical_uid":
        if row.get("physical_uid") != expected_physical_uid:
            raise SystemExit("physical UID does not match expected tenant-scoped UID")
        if row.get("logical_uid") == row.get("physical_uid"):
            raise SystemExit("physical UID does not match expected tenant-scoped UID")
        node_secret_id = row.get("node_secret_id")
        if not isinstance(node_secret_id, str) or not node_secret_id:
            raise SystemExit("node secret id is missing")
        if row.get("auth_secret_id") != node_secret_id:
            raise SystemExit("auth secret id does not match VmInventory::node_secret_id")
        expected_path = expected["expected_upstream_path"].replace(
            "{physical_uid}", expected_physical_uid
        )
        if row.get("upstream_path") != expected_path:
            raise SystemExit("upstream path does not match inventory")
        headers = row.get("upstream_headers")
        if not isinstance(headers, dict):
            raise SystemExit("upstream headers are missing")
        lower_headers = {str(key).lower(): value for key, value in headers.items()}
        expected_headers = expected["expected_upstream_headers"]
        auth_header = lower_headers.get("x-algolia-api-key")
        if not isinstance(auth_header, str) or not re.fullmatch(
            r"sha256:[0-9a-f]{64}", auth_header
        ):
            raise SystemExit("upstream auth header was not observed")
        if auth_header != expected_auth_proof:
            raise SystemExit("upstream auth header does not match expected node credential")
        comparable_headers = {
            key: value for key, value in lower_headers.items() if key != "x-algolia-api-key"
        }
        expected_comparable_headers = {
            key: value for key, value in expected_headers.items() if key != "x-algolia-api-key"
        }
        if comparable_headers != expected_comparable_headers:
            raise SystemExit("upstream headers do not match inventory")

if sorted(observed_ids) != expected_ids:
    raise SystemExit("observed caller IDs do not match inventory")

print(json.dumps({
    "status": "pass",
    "expected_caller_count": len(expected_ids),
    "observed_caller_count": len(observed_ids),
}, separators=(",", ":")))
PY
}

HTTP_RESPONSE_BODY=""
HTTP_RESPONSE_CODE=""

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

discover_destination_vm() {
    if [ -n "$PROBE_DEST_VM_ID" ]; then
        return 0
    fi

    admin_call POST "/admin/tenants/${PROBE_CUSTOMER_ID}/indexes" \
        -H "content-type: application/json" \
        -d "{\"name\":\"${PROBE_DEST_SEED_INDEX}\",\"region\":\"${PROBE_REPLICA_REGION}\",\"flapjack_url\":\"${PROBE_ENGINE_URL}\"}"
    if [ "$HTTP_RESPONSE_CODE" != "201" ] && [ "$HTTP_RESPONSE_CODE" != "200" ]; then
        die "destination VM seed expected HTTP 201/200, got $HTTP_RESPONSE_CODE: $HTTP_RESPONSE_BODY"
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
if not isinstance(vms, list):
    raise SystemExit("admin VM list response is not an array")

matches = [
    vm
    for vm in vms
    if isinstance(vm, dict)
    and vm.get("region") == region
    and vm.get("flapjack_url") == flapjack_url
    and isinstance(vm.get("id"), str)
]
if len(matches) != 1:
    raise SystemExit(
        f"expected exactly one destination VM for region {region} and {flapjack_url}, got {len(matches)}"
    )
print(matches[0]["id"])
PY
    )" || die "destination VM inventory did not contain a unique seeded VM"
}

prepare_destination_replica() {
    tenant_call POST "/indexes/${PROBE_INDEX}/replicas" "$1" \
        -H "content-type: application/json" \
        -d "{\"region\":\"${PROBE_REPLICA_REGION}\"}"
    if [ "$HTTP_RESPONSE_CODE" != "201" ] && [ "$HTTP_RESPONSE_CODE" != "200" ] && [ "$HTTP_RESPONSE_CODE" != "409" ]; then
        die "destination replica prepare expected HTTP 201/200/409, got $HTTP_RESPONSE_CODE: $HTTP_RESPONSE_BODY"
    fi
}

seed_source_index() {
    tenant_call POST "/indexes" "$1" \
        -H "content-type: application/json" \
        -d "{\"name\":\"${PROBE_INDEX}\",\"region\":\"${PROBE_REGION}\"}"
    if [ "$HTTP_RESPONSE_CODE" != "201" ] && [ "$HTTP_RESPONSE_CODE" != "200" ] && [ "$HTTP_RESPONSE_CODE" != "409" ]; then
        die "index create expected HTTP 201/200/409, got $HTTP_RESPONSE_CODE: $HTTP_RESPONSE_BODY"
    fi

    tenant_call POST "/indexes/${PROBE_INDEX}/batch" "$1" \
        -H "content-type: application/json" \
        -d "{\"requests\":[{\"action\":\"addObject\",\"body\":{\"objectID\":\"engine-identity-doc-1\",\"title\":\"Engine identity probe\"}}]}"
    expect_status "source document seed" "200"
}

delete_probe_replicas() {
    local replica_ids replica_to_delete

    tenant_call GET "/indexes/${PROBE_INDEX}/replicas" "$1"
    expect_status "probe replica cleanup list" "200"
    replica_ids="$(
        python3 - "$HTTP_RESPONSE_BODY" <<'PY'
import json
import sys

try:
    replicas = json.loads(sys.argv[1])
except json.JSONDecodeError as exc:
    raise SystemExit(f"replica list response is not structured JSON: {exc}")
if not isinstance(replicas, list):
    raise SystemExit("replica list response is not an array")
for replica in replicas:
    if isinstance(replica, dict) and isinstance(replica.get("id"), str):
        print(replica["id"])
PY
    )" || die "probe replica cleanup list did not contain structured replica rows"

    while IFS= read -r replica_to_delete; do
        [ -n "$replica_to_delete" ] || continue
        tenant_call DELETE "/indexes/${PROBE_INDEX}/replicas/${replica_to_delete}" "$1"
        if [ "$HTTP_RESPONSE_CODE" != "204" ] && [ "$HTTP_RESPONSE_CODE" != "404" ]; then
            die "probe replica cleanup delete expected HTTP 204/404, got $HTTP_RESPONSE_CODE: $HTTP_RESPONSE_BODY"
        fi
    done <<EOF
$replica_ids
EOF
}

drive_live_entrypoints() {
    local token isolation_token isolation_customer_id replica_id migration_status
    local unrelated_state_before unrelated_state_after

    capture_response POST "${API_URL}/auth/register" \
        -H "content-type: application/json" \
        -d "{\"name\":\"Engine Identity Isolation\",\"email\":\"${ISOLATION_EMAIL}\",\"password\":\"${ISOLATION_PASSWORD}\"}"
    expect_status "unrelated tenant auth register" "201"
    isolation_customer_id="$(json_field "$HTTP_RESPONSE_BODY" customer_id)" \
        || die "unrelated tenant auth register response missing customer_id"

    capture_response POST "${API_URL}/auth/login" \
        -H "content-type: application/json" \
        -d "{\"email\":\"${ISOLATION_EMAIL}\",\"password\":\"${ISOLATION_PASSWORD}\"}"
    expect_status "unrelated tenant auth login" "200"
    isolation_token="$(json_field "$HTTP_RESPONSE_BODY" token)" \
        || die "unrelated tenant auth login response missing token"

    tenant_call POST "/indexes" "$isolation_token" \
        -H "content-type: application/json" \
        -d "{\"name\":\"${PROBE_INDEX}\",\"region\":\"${PROBE_REGION}\"}"
    expect_status "unrelated same-name index create" "201"

    tenant_call GET "/indexes/${PROBE_INDEX}/metrics" "$isolation_token"
    expect_status "unrelated same-name tenant metrics" "200"
    if [ "$(json_field "$HTTP_RESPONSE_BODY" index 2>/dev/null || true)" != "$PROBE_INDEX" ]; then
        die "unrelated same-name tenant metrics response did not echo probe index"
    fi

    tenant_call GET "/indexes/${PROBE_INDEX}" "$isolation_token"
    expect_status "unrelated tenant snapshot before primary flow" "200"
    if [ "$(json_field "$HTTP_RESPONSE_BODY" status 2>/dev/null || true)" != "ready" ]; then
        die "unrelated tenant was not reachable before primary flow"
    fi
    unrelated_state_before="$(canonical_json "$HTTP_RESPONSE_BODY")" \
        || die "unrelated tenant state before primary flow was not structured JSON"

    capture_response POST "${API_URL}/auth/register" \
        -H "content-type: application/json" \
        -d "{\"name\":\"Engine Identity Probe\",\"email\":\"${PROBE_EMAIL}\",\"password\":\"${PROBE_PASSWORD}\"}"
    expect_status "auth register" "201"
    PROBE_CUSTOMER_ID="$(json_field "$HTTP_RESPONSE_BODY" customer_id)" \
        || die "auth register response missing customer_id"
    if [ "$PROBE_CUSTOMER_ID" = "$isolation_customer_id" ]; then
        die "probe and unrelated tenant customer IDs must differ"
    fi

    capture_response POST "${API_URL}/auth/login" \
        -H "content-type: application/json" \
        -d "{\"email\":\"${PROBE_EMAIL}\",\"password\":\"${PROBE_PASSWORD}\"}"
    expect_status "auth login" "200"
    token="$(json_field "$HTTP_RESPONSE_BODY" token)" \
        || die "auth login response missing token"

    seed_source_index "$token"

    tenant_call GET "/indexes/${PROBE_INDEX}/metrics" "$token"
    expect_status "same-name tenant metrics" "200"
    if [ "$(json_field "$HTTP_RESPONSE_BODY" index 2>/dev/null || true)" != "$PROBE_INDEX" ]; then
        die "same-name tenant metrics response did not echo probe index"
    fi

    discover_destination_vm

    prepare_destination_replica "$token"
    expect_status "replica create" "201"
    replica_id="$(json_field "$HTTP_RESPONSE_BODY" id)" \
        || die "replica create response missing id"

    tenant_call GET "/indexes/${PROBE_INDEX}/replicas" "$token"
    expect_status "replica list" "200"

    tenant_call DELETE "/indexes/${PROBE_INDEX}/replicas/${replica_id}" "$token"
    expect_status "replica delete" "204"

    prepare_destination_replica "$token"
    admin_call POST "/admin/migrations/probe/rollback-after-replication" \
        -H "content-type: application/json" \
        -d "{\"customer_id\":\"${PROBE_CUSTOMER_ID}\",\"index_name\":\"${PROBE_INDEX}\",\"dest_vm_id\":\"${PROBE_DEST_VM_ID}\"}"
    expect_status "admin probe rollback after replication" "200"
    migration_status="$(json_field "$HTTP_RESPONSE_BODY" status 2>/dev/null || true)"
    if [ "$migration_status" != "rolled_back" ]; then
        die "admin probe rollback after replication expected rolled_back status"
    fi

    seed_source_index "$token"
    prepare_destination_replica "$token"
    admin_call POST "/admin/migrations/probe/failure-after-replication" \
        -H "content-type: application/json" \
        -d "{\"customer_id\":\"${PROBE_CUSTOMER_ID}\",\"index_name\":\"${PROBE_INDEX}\",\"dest_vm_id\":\"${PROBE_DEST_VM_ID}\"}"
    expect_status "admin probe failure after replication" "200"
    migration_status="$(json_field "$HTTP_RESPONSE_BODY" status 2>/dev/null || true)"
    if [ "$migration_status" != "failed" ]; then
        die "admin probe failure after replication expected failed status"
    fi

    seed_source_index "$token"
    prepare_destination_replica "$token"
    admin_call POST "/admin/migrations/cross-provider" \
        -H "content-type: application/json" \
        -d "{\"customer_id\":\"${PROBE_CUSTOMER_ID}\",\"index_name\":\"${PROBE_INDEX}\",\"dest_vm_id\":\"${PROBE_DEST_VM_ID}\"}"
    if [ "$HTTP_RESPONSE_CODE" != "200" ]; then
        die "admin migration execute expected HTTP 200 with completed status, got $HTTP_RESPONSE_CODE: $HTTP_RESPONSE_BODY"
    fi
    migration_status="$(json_field "$HTTP_RESPONSE_BODY" status 2>/dev/null || true)"
    if [ "$migration_status" != "completed" ]; then
        die "admin migration execute expected HTTP 200 with completed status"
    fi

    admin_call GET "/admin/migrations?status=active&limit=10"
    expect_status "admin migration active list" "200"

    admin_call GET "/admin/migrations?status=completed&limit=10"
    expect_status "admin migration completed status" "200"

    admin_call GET "/admin/replicas?status=provisioning"
    expect_status "admin replica list" "200"

    delete_probe_replicas "$token"

    tenant_call DELETE "/indexes/${PROBE_INDEX}" "$token" \
        -H "content-type: application/json" \
        -d '{"confirm":true}'
    if [ "$HTTP_RESPONSE_CODE" != "204" ] && [ "$HTTP_RESPONSE_CODE" != "404" ]; then
        die "source delete auth cleanup expected HTTP 204/404, got $HTTP_RESPONSE_CODE: $HTTP_RESPONSE_BODY"
    fi

    tenant_call GET "/indexes/${PROBE_INDEX}" "$isolation_token"
    expect_status "unrelated tenant snapshot after primary flow" "200"
    if [ "$(json_field "$HTTP_RESPONSE_BODY" status 2>/dev/null || true)" != "ready" ]; then
        die "unrelated tenant was not reachable after primary flow"
    fi
    unrelated_state_after="$(canonical_json "$HTTP_RESPONSE_BODY")" \
        || die "unrelated tenant state after primary flow was not structured JSON"
    if [ "$unrelated_state_after" != "$unrelated_state_before" ]; then
        die "unrelated tenant state changed"
    fi
}

validate_inventory

# Coverage must come from this API process. Reusing an artifact from an earlier
# run would let a launcher or observation regression pass without executing any
# of the inventory owners at the current boundary.
rm -f "$OBSERVED_CALLERS_FILE"

# integration-up can fail after starting one process or creating the database.
# Arm its idempotent teardown before startup so partial stacks are not leaked.
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
INTEGRATION_DB="${INTEGRATION_DB:-engine_index_identity_live_probe}" \
    bash "$SCRIPT_DIR/integration-up.sh" >/dev/null

drive_live_entrypoints
validate_observed_artifact
