#!/usr/bin/env bash
# validate_vm_inventory_ec2_consistency.sh
#
# Reconciles active VM inventory rows against managed EC2 instances and
# deployment linkage markers. Emits JSON on stdout and returns:
#   0 when all mismatch buckets are zero
#   1 when reconciliation mismatches are present
#   2 for usage/system errors

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RETRY_WINDOW_SECONDS=60

# shellcheck disable=SC1091
# shellcheck source=scripts/lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"
# shellcheck disable=SC1091
# shellcheck source=scripts/lib/psql_path.sh
source "$REPO_ROOT/scripts/lib/psql_path.sh"
# shellcheck disable=SC1091
# shellcheck source=scripts/lib/staging_db.sh
source "$REPO_ROOT/scripts/lib/staging_db.sh"

usage() {
    cat <<'USAGE'
Usage:
  validate_vm_inventory_ec2_consistency.sh [--evidence-dir <dir>] [--now-epoch <sec>]
  validate_vm_inventory_ec2_consistency.sh --inventory-json <file> --deployment-json <file> --ec2-json <file> [--evidence-dir <dir>] [--now-epoch <sec>]

Output contract (JSON on stdout):
  - inventory_rows_without_nonterminated_ec2_match
  - managed_instances_without_inventory_match (shared vm-shared-* managed EC2 only)
  - deployment_linkage_mismatches
  - stuck_shared_provisioning_rows
  - raw_records[<same category keys>] as per-category arrays

Exit contract:
  0 => all buckets are zero
  1 => one or more buckets are nonzero
  2 => usage/system error
USAGE
}

EVIDENCE_DIR=""
INVENTORY_JSON_INPUT=""
DEPLOYMENT_JSON_INPUT=""
EC2_JSON_INPUT=""
NOW_EPOCH=""

system_error() {
    echo "ERROR: $*" >&2
    exit 2
}

copy_input_file_or_exit() {
    local source_path="$1"
    local destination_path="$2"
    local label="$3"

    [ -f "$source_path" ] || system_error "${label} input file not found: $source_path"
    cp "$source_path" "$destination_path" || system_error "failed to copy ${label} input file: $source_path"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h)
            usage
            exit 0
            ;;
        --evidence-dir)
            [ "$#" -ge 2 ] || { echo "ERROR: --evidence-dir requires a value" >&2; exit 2; }
            EVIDENCE_DIR="$2"
            shift 2
            ;;
        --inventory-json)
            [ "$#" -ge 2 ] || { echo "ERROR: --inventory-json requires a value" >&2; exit 2; }
            INVENTORY_JSON_INPUT="$2"
            shift 2
            ;;
        --deployment-json)
            [ "$#" -ge 2 ] || { echo "ERROR: --deployment-json requires a value" >&2; exit 2; }
            DEPLOYMENT_JSON_INPUT="$2"
            shift 2
            ;;
        --ec2-json)
            [ "$#" -ge 2 ] || { echo "ERROR: --ec2-json requires a value" >&2; exit 2; }
            EC2_JSON_INPUT="$2"
            shift 2
            ;;
        --now-epoch)
            [ "$#" -ge 2 ] || { echo "ERROR: --now-epoch requires a value" >&2; exit 2; }
            NOW_EPOCH="$2"
            shift 2
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ -n "$NOW_EPOCH" ] && ! [[ "$NOW_EPOCH" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --now-epoch must be an integer unix epoch (seconds)" >&2
    exit 2
fi

if [ -n "$EVIDENCE_DIR" ]; then
    mkdir -p "$EVIDENCE_DIR" || system_error "failed to create evidence directory: $EVIDENCE_DIR"
fi

USE_INPUT_FIXTURES=0
if [ -n "$INVENTORY_JSON_INPUT" ] || [ -n "$DEPLOYMENT_JSON_INPUT" ] || [ -n "$EC2_JSON_INPUT" ]; then
    USE_INPUT_FIXTURES=1
    if [ -z "$INVENTORY_JSON_INPUT" ] || [ -z "$DEPLOYMENT_JSON_INPUT" ] || [ -z "$EC2_JSON_INPUT" ]; then
        echo "ERROR: --inventory-json, --deployment-json, and --ec2-json must be provided together" >&2
        exit 2
    fi
fi

TEMP_DIR="$(mktemp -d)"
# shellcheck disable=SC2329
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

INVENTORY_JSON="$TEMP_DIR/inventory_rows.json"
DEPLOYMENT_JSON="$TEMP_DIR/deployment_rows.json"
EC2_JSON="$TEMP_DIR/ec2_instances.json"

if [ "$USE_INPUT_FIXTURES" -eq 1 ]; then
    copy_input_file_or_exit "$INVENTORY_JSON_INPUT" "$INVENTORY_JSON" "inventory"
    copy_input_file_or_exit "$DEPLOYMENT_JSON_INPUT" "$DEPLOYMENT_JSON" "deployment"
    copy_input_file_or_exit "$EC2_JSON_INPUT" "$EC2_JSON" "ec2"
else
    # load_layered_env_files preserves explicitly exported vars, so stale shell
    # credentials can shadow repo-approved secrets unless we clear them first.
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE AWS_DEFAULT_REGION
    load_layered_env_files "${FJCLOUD_SECRET_FILE:-$REPO_ROOT/.secret/.env.secret}"
    export DATABASE_URL_SSM_PARAM="${DATABASE_URL_SSM_PARAM:-/fjcloud/prod/database_url}"

    DATABASE_URL="${DATABASE_URL:-}"
    if [ -z "$DATABASE_URL" ]; then
        if ! DATABASE_URL="$(
            aws ssm get-parameter \
                --name "$DATABASE_URL_SSM_PARAM" \
                --with-decryption \
                --query 'Parameter.Value' \
                --output text
        )"; then
            system_error "failed to load DATABASE_URL from SSM parameter $DATABASE_URL_SSM_PARAM"
        fi
    fi
    if [ -z "$DATABASE_URL" ]; then
        echo "ERROR: DATABASE_URL is empty and could not be loaded from $DATABASE_URL_SSM_PARAM" >&2
        exit 2
    fi
    export DATABASE_URL

    read -r -d '' INVENTORY_BASE_SQL <<'SQL' || true
SELECT
  id::text AS id,
  provider,
  status,
  region,
  hostname,
  flapjack_url,
  updated_at
FROM vm_inventory
WHERE status = 'active'
  AND provider = 'aws'
ORDER BY updated_at DESC
SQL

    read -r -d '' DEPLOYMENT_BASE_SQL <<'SQL' || true
SELECT
  id::text AS id,
  customer_id::text AS customer_id,
  status,
  vm_provider,
  provider_vm_id,
  hostname,
  flapjack_url,
  created_at
FROM customer_deployments
WHERE (
        status = 'provisioning'
        AND (
             vm_provider = 'aws'
             OR provider_vm_id LIKE 'provisioning-lock:%'
        )
   )
   OR (
        status != 'terminated'
        AND flapjack_url IS NOT NULL
        AND vm_provider = 'aws'
        AND provider_vm_id LIKE '%:%'
   )
ORDER BY created_at DESC
SQL

    # Use paginated owner-seam reads so large JSON payloads do not trip
    # SSM StandardOutputContent truncation limits.
    staging_db_run_sql_json_array_paginated "$DATABASE_URL" "$INVENTORY_BASE_SQL" > "$INVENTORY_JSON" \
        || system_error "failed to capture vm_inventory rows"
    staging_db_run_sql_json_array_paginated "$DATABASE_URL" "$DEPLOYMENT_BASE_SQL" > "$DEPLOYMENT_JSON" \
        || system_error "failed to capture deployment rows"

    aws ec2 describe-instances \
        --filters \
            Name=tag:managed-by,Values=fjcloud \
            Name=instance-state-name,Values=pending,running,stopping,stopped \
        --query 'Reservations[].Instances[].{InstanceId:InstanceId,State:State.Name,Tags:Tags,LaunchTime:LaunchTime}' \
        --output json > "$EC2_JSON" || system_error "failed to capture managed EC2 instances"
fi

if [ -n "$EVIDENCE_DIR" ]; then
    cp "$INVENTORY_JSON" "$EVIDENCE_DIR/inventory_rows.json" || system_error "failed to write evidence inventory_rows.json"
    cp "$DEPLOYMENT_JSON" "$EVIDENCE_DIR/deployment_rows.json" || system_error "failed to write evidence deployment_rows.json"
    cp "$EC2_JSON" "$EVIDENCE_DIR/ec2_instances.json" || system_error "failed to write evidence ec2_instances.json"
fi

if ! SUMMARY_JSON="$(python3 - "$INVENTORY_JSON" "$DEPLOYMENT_JSON" "$EC2_JSON" "${NOW_EPOCH:-}" "$RETRY_WINDOW_SECONDS" <<'PY'
import json
import re
import sys
from datetime import datetime, timezone

inventory_path, deployment_path, ec2_path, now_epoch_raw, retry_window_raw = sys.argv[1:]
retry_window_seconds = int(retry_window_raw)

with open(inventory_path, "r", encoding="utf-8") as fh:
    inventory_rows = json.load(fh)
with open(deployment_path, "r", encoding="utf-8") as fh:
    deployment_rows = json.load(fh)
with open(ec2_path, "r", encoding="utf-8") as fh:
    ec2_rows = json.load(fh)


def parse_datetime(value):
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"

    candidate_set = {text}
    if "T" in text:
        candidate_set.add(text.replace("T", " "))

    candidates = []
    for candidate in candidate_set:
        candidates.append(candidate)
        if re.search(r"[+-]\d{2}:\d{2}$", candidate):
            candidates.append(candidate[:-3] + candidate[-2:])
        if re.search(r"[+-]\d{2}$", candidate):
            candidates.append(candidate + "00")

    for candidate in candidates:
        try:
            parsed = datetime.fromisoformat(candidate)
            if parsed.tzinfo is None:
                return parsed.replace(tzinfo=timezone.utc)
            return parsed
        except ValueError:
            continue

    for candidate in candidates:
        for fmt in (
            "%Y-%m-%dT%H:%M:%S.%f%z",
            "%Y-%m-%dT%H:%M:%S%z",
            "%Y-%m-%d %H:%M:%S.%f%z",
            "%Y-%m-%d %H:%M:%S%z",
            "%Y-%m-%dT%H:%M:%S.%f",
            "%Y-%m-%dT%H:%M:%S",
            "%Y-%m-%d %H:%M:%S.%f",
            "%Y-%m-%d %H:%M:%S",
        ):
            try:
                parsed = datetime.strptime(candidate, fmt)
                if parsed.tzinfo is None:
                    return parsed.replace(tzinfo=timezone.utc)
                return parsed
            except ValueError:
                continue

    return None


def normalize_provider_vm_id(provider, provider_vm_id):
    raw = (provider_vm_id or "").strip()
    if not raw:
        return ""
    if ":" in raw:
        prefix, suffix = raw.split(":", 1)
        if prefix == (provider or "") and suffix:
            return suffix
    return raw


def ec2_name_tag(instance):
    if isinstance(instance.get("Name"), str):
        return instance["Name"]
    tags = instance.get("Tags") or []
    if isinstance(tags, list):
        for tag in tags:
            if isinstance(tag, dict) and tag.get("Key") == "Name":
                return tag.get("Value") or ""
    return ""


def host_from_instance(instance):
    name = ec2_name_tag(instance).strip()
    if not name:
        return ""
    if name.startswith("fj-"):
        return name[3:].lower()
    return name.lower()


def instance_state(instance):
    state = instance.get("State")
    if isinstance(state, dict):
        state = state.get("Name")
    return str(state or "").lower()


def has_managed_tag(instance):
    tags = instance.get("Tags") or []
    if isinstance(tags, list):
        for tag in tags:
            if (
                isinstance(tag, dict)
                and str(tag.get("Key") or "") == "managed-by"
                and str(tag.get("Value") or "") == "fjcloud"
            ):
                return True
    return False


def is_shared_managed_instance(instance):
    host = host_from_instance(instance)
    return host.startswith("vm-shared-")


if now_epoch_raw:
    now_epoch = int(now_epoch_raw)
else:
    now_epoch = int(datetime.now(timezone.utc).timestamp())

active_inventory_rows = []
for row in inventory_rows:
    status = str(row.get("status") or "").lower()
    provider = str(row.get("provider") or "").lower()
    if status == "active" and provider == "aws":
        active_inventory_rows.append(row)

usable_ec2_rows = []
for row in ec2_rows:
    state = instance_state(row)
    if state in {"terminated", "shutting-down"}:
        continue
    if not has_managed_tag(row):
        continue
    usable_ec2_rows.append(row)

inventory_by_id = {
    str(row.get("id") or ""): row
    for row in active_inventory_rows
    if str(row.get("id") or "")
}
inventory_by_host = {}
for row in active_inventory_rows:
    host = str(row.get("hostname") or "").strip().lower()
    if host:
        inventory_by_host[host] = row

ec2_by_id = {}
ec2_by_host = {}
for row in usable_ec2_rows:
    instance_id = str(row.get("InstanceId") or "").strip()
    if instance_id:
        ec2_by_id[instance_id] = row
    host = host_from_instance(row)
    if host:
        ec2_by_host[host] = row

raw_records = {
    "inventory_rows_without_nonterminated_ec2_match": [],
    "managed_instances_without_inventory_match": [],
    "deployment_linkage_mismatches": [],
    "stuck_shared_provisioning_rows": [],
}

for row in active_inventory_rows:
    host = str(row.get("hostname") or "").strip().lower()
    if host and host in ec2_by_host:
        continue
    raw_records["inventory_rows_without_nonterminated_ec2_match"].append(
        {
            "vm_inventory_id": row.get("id"),
            "provider": row.get("provider"),
            "status": row.get("status"),
            "hostname": row.get("hostname"),
            "flapjack_url": row.get("flapjack_url"),
            "updated_at": row.get("updated_at"),
        }
    )

for row in usable_ec2_rows:
    # This drift bucket is Stage-4 scoped to shared-fleet reconciliation only.
    if not is_shared_managed_instance(row):
        continue
    host = host_from_instance(row)
    if host and host in inventory_by_host:
        continue
    raw_records["managed_instances_without_inventory_match"].append(
        {
            "instance_id": row.get("InstanceId"),
            "state": row.get("State"),
            "hostname": host or None,
            "launch_time": row.get("LaunchTime"),
        }
    )

deployment_evaluations = {}
for row in deployment_rows:
    deployment_id = str(row.get("id") or "")
    provider = str(row.get("vm_provider") or "")
    provider_lower = provider.lower()
    status = str(row.get("status") or "").lower()
    flapjack_url = str(row.get("flapjack_url") or "").strip()
    raw_provider_vm_id = str(row.get("provider_vm_id") or "")
    has_provider_qualified_id = ":" in raw_provider_vm_id
    is_provisioning_lock = raw_provider_vm_id.startswith("provisioning-lock:")

    # Match the live deployment capture owner surface exactly:
    # keep provisioning rows only for AWS or provisioning-lock markers, and keep
    # non-provisioning rows only when they are active, flapjack-backed, AWS-backed,
    # and provider-qualified (provider:id).
    if status == "provisioning":
        if provider_lower != "aws" and not is_provisioning_lock:
            continue
    elif status == "terminated" or not flapjack_url or provider_lower != "aws" or not has_provider_qualified_id:
        continue

    normalized_provider_vm_id = normalize_provider_vm_id(provider, raw_provider_vm_id)
    deployment_host = str(row.get("hostname") or "").strip().lower()
    created_at = parse_datetime(row.get("created_at"))
    age_seconds = None
    if created_at is not None:
        age_seconds = max(0, now_epoch - int(created_at.timestamp()))

    evaluation = {
        "deployment_id": deployment_id,
        "status": status,
        "vm_provider": provider,
        "provider_vm_id_raw": raw_provider_vm_id,
        "provider_vm_id_normalized": normalized_provider_vm_id,
        "hostname": row.get("hostname"),
        "created_at": row.get("created_at"),
        "age_seconds": age_seconds,
        "match_source": "none",
        "classification": "mismatch",
    }

    if is_provisioning_lock:
        if status == "provisioning" and age_seconds is not None and age_seconds <= retry_window_seconds:
            evaluation["classification"] = "inflight_provisioning_lock"
            deployment_evaluations[deployment_id] = evaluation
            continue

        evaluation["classification"] = "aged_provisioning_lock"
        raw_records["deployment_linkage_mismatches"].append(
            {
                "deployment_id": deployment_id,
                "reason": "aged_provisioning_lock",
                "status": status,
                "provider_vm_id": raw_provider_vm_id,
                "created_at": row.get("created_at"),
                "age_seconds": age_seconds,
                "hostname": row.get("hostname"),
            }
        )
        if status == "provisioning":
            raw_records["stuck_shared_provisioning_rows"].append(
                {
                    "deployment_id": deployment_id,
                    "provider_vm_id": raw_provider_vm_id,
                    "created_at": row.get("created_at"),
                    "age_seconds": age_seconds,
                    "hostname": row.get("hostname"),
                }
            )
        deployment_evaluations[deployment_id] = evaluation
        continue

    if normalized_provider_vm_id in ec2_by_id:
        evaluation["match_source"] = "provider_vm_id"
        evaluation["classification"] = "matched_provider_vm_id"
        deployment_evaluations[deployment_id] = evaluation
        continue

    matched_via_inventory = False
    if normalized_provider_vm_id in inventory_by_id:
        inventory_row = inventory_by_id[normalized_provider_vm_id]
        inv_host = str(inventory_row.get("hostname") or "").strip().lower()
        if inv_host and inv_host in ec2_by_host:
            evaluation["match_source"] = "inventory_hostname"
            evaluation["classification"] = "matched_inventory_hostname"
            matched_via_inventory = True
    if matched_via_inventory:
        deployment_evaluations[deployment_id] = evaluation
        continue

    if deployment_host and deployment_host in ec2_by_host:
        evaluation["match_source"] = "deployment_hostname"
        evaluation["classification"] = "matched_deployment_hostname"
        deployment_evaluations[deployment_id] = evaluation
        continue

    raw_records["deployment_linkage_mismatches"].append(
        {
            "deployment_id": deployment_id,
            "reason": "no_nonterminated_ec2_match",
            "status": status,
            "vm_provider": provider,
            "provider_vm_id_raw": raw_provider_vm_id,
            "provider_vm_id_normalized": normalized_provider_vm_id,
            "hostname": row.get("hostname"),
            "created_at": row.get("created_at"),
        }
    )
    deployment_evaluations[deployment_id] = evaluation

summary = {
    "retry_window_seconds": retry_window_seconds,
    "inventory_rows_without_nonterminated_ec2_match": len(
        raw_records["inventory_rows_without_nonterminated_ec2_match"]
    ),
    "managed_instances_without_inventory_match": len(
        raw_records["managed_instances_without_inventory_match"]
    ),
    "deployment_linkage_mismatches": len(raw_records["deployment_linkage_mismatches"]),
    "stuck_shared_provisioning_rows": len(raw_records["stuck_shared_provisioning_rows"]),
    "raw_records": raw_records,
    "deployment_evaluations": deployment_evaluations,
}

print(json.dumps(summary, indent=2, sort_keys=True))
PY
)"; then
    system_error "failed to compute reconciliation summary"
fi

printf '%s\n' "$SUMMARY_JSON"

if python3 - "$SUMMARY_JSON" <<'PY'
import json
import sys

summary = json.loads(sys.argv[1])
required = [
    "inventory_rows_without_nonterminated_ec2_match",
    "managed_instances_without_inventory_match",
    "deployment_linkage_mismatches",
    "stuck_shared_provisioning_rows",
]
any_nonzero = any(int(summary.get(key, 0)) > 0 for key in required)
raise SystemExit(1 if any_nonzero else 0)
PY
then
    exit 0
else
    verdict_exit_code=$?
fi

if [ "$verdict_exit_code" -eq 1 ]; then
    exit 1
fi
system_error "failed to evaluate reconciliation summary verdict"
