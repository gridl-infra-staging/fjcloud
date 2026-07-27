#!/usr/bin/env bash
# Source-only join boundary for the local real-pipeline oracle.
#
# This module reads the authenticated admin VM contracts and joins them with
# metering evidence already proved by local_real_pipeline_run.sh. It does not
# start services, query metering tables, classify evidence, or own coordination.

lrp_admin_json_get() {
    curl -fsS \
        --header @<(printf 'x-admin-key: %s\n' "$ADMIN_KEY") \
        "${LRP_API_BASE_URL}$1" 2>/dev/null
}

lrp_capture_oracle_topology() {
    local inventory joined
    inventory="$(lrp_admin_json_get "/admin/vms")" \
        || probe_fail topology "could not fetch authenticated VM inventory"
    joined="$(
        python3 - "$inventory" "$LRP_DRIVEN_REGION" <<'PY'
import json
import sys

try:
    entries = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(2)
driven_region = sys.argv[2]
if not isinstance(entries, list):
    raise SystemExit(2)

required = (
    "id", "region", "provider", "hostname", "flapjack_url", "capacity",
    "current_load", "status", "tenant_count", "index_count", "health",
    "created_at", "updated_at",
)
vms = []
for entry in entries:
    if not isinstance(entry, dict):
        raise SystemExit(2)
    if entry.get("status") != "active":
        continue
    if any(key not in entry for key in required):
        raise SystemExit(2)
    if entry["health"] not in {"healthy", "unhealthy", "unknown"}:
        raise SystemExit(2)
    if not isinstance(entry["capacity"], dict) or not isinstance(entry["current_load"], dict):
        raise SystemExit(2)
    if not isinstance(entry["tenant_count"], int) or not isinstance(entry["index_count"], int):
        raise SystemExit(2)
    vms.append({key: entry[key] for key in required})

eligible = sorted(
    (vm for vm in vms if vm["region"] == driven_region),
    key=lambda vm: (vm["region"], vm["id"]),
)
if not eligible:
    raise SystemExit(3)
selected_vm_id = eligible[0]["id"]
vms.sort(key=lambda vm: (vm["region"], vm["id"]))

regions = []
for region in sorted({vm["region"] for vm in vms}):
    scoped = [vm for vm in vms if vm["region"] == region]
    regions.append({
        "region": region,
        "vm_count": len(scoped),
        "healthy_count": sum(vm["health"] == "healthy" for vm in scoped),
        "unhealthy_count": sum(vm["health"] == "unhealthy" for vm in scoped),
        "unknown_count": sum(vm["health"] == "unknown" for vm in scoped),
        "tenant_count": sum(vm["tenant_count"] for vm in scoped),
        "index_count": sum(vm["index_count"] for vm in scoped),
    })
totals = {
    key: sum(region[key] for region in regions)
    for key in (
        "vm_count", "healthy_count", "unhealthy_count", "unknown_count",
        "tenant_count", "index_count",
    )
}
topology = {
    "selected_vm_id": selected_vm_id,
    "vms": vms,
    "regions": regions,
    "totals": totals,
}
print(selected_vm_id)
print(json.dumps(topology, separators=(",", ":")))
PY
    )" || probe_fail topology "VM inventory was malformed or had no active VM in ${LRP_DRIVEN_REGION}"
    case "$joined" in
        *$'\n'*) : ;;
        *) probe_fail topology "VM inventory join did not return a selected VM and topology" ;;
    esac
    LRP_SELECTED_VM_ID="${joined%%$'\n'*}"
    LRP_ORACLE_TOPOLOGY_JSON="${joined#*$'\n'}"
}

# Accept one host-metrics response only when it belongs to the selected VM and
# was collected at or after $2, the caller's freshness floor.
lrp_normalize_fresh_host_sample() {
    python3 - "$1" "$LRP_SELECTED_VM_ID" "$2" <<'PY'
import datetime
import json
import sys

try:
    sample = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(2)
if sample is None:
    raise SystemExit(5)
if not isinstance(sample, dict):
    raise SystemExit(2)
required = (
    "id", "vm_id", "collected_at", "cpu_pct", "mem_used_bytes",
    "mem_total_bytes", "disk_used_bytes", "disk_total_bytes", "net_rx_bytes",
    "net_tx_bytes", "created_at",
)
if any(key not in sample for key in required):
    raise SystemExit(2)
if sample["vm_id"] != sys.argv[2]:
    raise SystemExit(3)
try:
    collected_at = datetime.datetime.fromisoformat(sample["collected_at"].replace("Z", "+00:00"))
    freshness_floor = datetime.datetime.fromisoformat(sys.argv[3].replace("Z", "+00:00"))
except (AttributeError, TypeError, ValueError):
    raise SystemExit(2)
if collected_at < freshness_floor:
    raise SystemExit(4)
print(json.dumps({key: sample[key] for key in required}, separators=(",", ":")))
PY
}

# Poll the live endpoint until the selected VM has a sample collected at or
# after $1, then store it. Callers pass the floor that makes the sample fresh
# for their step, so a sample cached earlier in the run is never reused.
lrp_poll_selected_host_metrics() {
    local freshness_floor="$1" deadline response normalized rc=0
    deadline=$((SECONDS + LRP_HOST_METRICS_TIMEOUT))
    while [ "$SECONDS" -lt "$deadline" ]; do
        response="$(lrp_admin_json_get "/admin/vms/${LRP_SELECTED_VM_ID}/host-metrics")" \
            || probe_fail host_metrics "could not fetch selected VM host metrics"
        if normalized="$(lrp_normalize_fresh_host_sample "$response" "$freshness_floor")"; then
            LRP_ORACLE_HOST_SAMPLE_JSON="$normalized"
            return 0
        else
            rc=$?
        fi
        case "$rc" in
            4|5) sleep "$LRP_HOST_METRICS_POLL_INTERVAL" ;;
            2) probe_fail host_metrics "selected VM host-metrics response was malformed" ;;
            3) probe_fail host_metrics "selected VM host-metrics response identified a different VM" ;;
            *) probe_fail host_metrics "selected VM host-metrics response was rejected" ;;
        esac
    done
    probe_fail host_metrics "selected VM had no sample collected at or after ${freshness_floor}"
}

lrp_oracle_redaction_guard() {
    python3 - "$1" <<'PY'
import re
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    serialized = handle.read()
if re.search(
    r"(DATABASE_URL|ADMIN_KEY|FLAPJACK_ADMIN_KEY|INTERNAL_AUTH_TOKEN|AWS_|STRIPE_|SECRET|TOKEN)",
    serialized,
    re.I,
):
    raise SystemExit(1)
PY
}

lrp_serialize_oracle_candidate() {
    python3 - \
        "$LRP_ORACLE_TEMP_FILE" "$LRP_EVIDENCE_FILE" "$LRP_ORACLE_TOPOLOGY_JSON" \
        "$LRP_ORACLE_HOST_SAMPLE_JSON" "$LRP_RUN_ID" "$LRP_DRIVEN_INDEX_NAME" \
        "$LRP_FLAPJACK_UID" "$LRP_PRE_SEARCH" "$LRP_PRE_WRITE" \
        "$LRP_POST_SEARCH" "$LRP_POST_WRITE" "$LRP_GENERATED_AT" \
        "$LRP_HOST_METRICS_MAX_SAMPLE_AGE_SECONDS" <<'PY'
import json
import sys

(output_path, evidence_path, topology_json, host_sample_json, run_id,
 index_name, flapjack_uid, pre_search, pre_write, post_search, post_write,
 generated_at, max_sample_age) = sys.argv[1:14]
with open(evidence_path, encoding="utf-8") as handle:
    evidence = json.load(handle)
doc = {
    "schema_version": 1,
    "provenance": {
        "run_id": run_id,
        "locality": "local",
        "stack_mode": "booted",
        "pipeline_verdict": "LOCAL_REAL_PIPELINE_STATUS: PASS reason=verified",
        "probe_started_at": evidence["probe_started_at"],
        "generated_at": generated_at,
    },
    "metering": {
        "customer_id": evidence["customer_id"],
        "index_name": index_name,
        "flapjack_uid": flapjack_uid,
        "region": evidence["region"],
        "target_date": evidence["target_date"],
        "expected_search_requests": evidence["expected_search"],
        "expected_write_operations": evidence["expected_write"],
        "pre_search_requests": int(pre_search),
        "pre_write_operations": int(pre_write),
        "post_search_requests": int(post_search),
        "post_write_operations": int(post_write),
        "usage_daily": {
            "customer_id": evidence["row_customer_id"],
            "region": evidence["row_region"],
            "target_date": evidence["row_target_date"],
            "search_requests": evidence["search_requests"],
            "write_operations": evidence["write_operations"],
            "rows_affected": evidence["rows_affected"],
            "aggregated_at": evidence["aggregated_at"],
        },
    },
    "topology": json.loads(topology_json),
    "host_metrics": {
        "max_sample_age_seconds": int(max_sample_age),
        "samples": [json.loads(host_sample_json)],
    },
}
with open(output_path, "w", encoding="utf-8") as handle:
    json.dump(doc, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

lrp_oracle_candidate_is_sane() {
    python3 - \
        "$LRP_ORACLE_TEMP_FILE" "$LRP_SELECTED_VM_ID" "$LRP_EXPECTED_SEARCH" \
        "$LRP_EXPECTED_WRITE" "$LRP_PRE_SEARCH" "$LRP_PRE_WRITE" \
        "$LRP_POST_SEARCH" "$LRP_POST_WRITE" <<'PY'
import datetime
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    oracle = json.load(handle)
(selected_vm_id, expected_search, expected_write, pre_search, pre_write,
 post_search, post_write) = sys.argv[2:9]
if not oracle["provenance"]["run_id"]:
    raise SystemExit(1)
topology = oracle["topology"]
if topology["selected_vm_id"] != selected_vm_id:
    raise SystemExit(1)
if not any(vm["id"] == selected_vm_id for vm in topology["vms"]):
    raise SystemExit(1)
metering = oracle["metering"]
actual = (
    metering["expected_search_requests"], metering["expected_write_operations"],
    metering["pre_search_requests"], metering["pre_write_operations"],
    metering["post_search_requests"], metering["post_write_operations"],
)
if actual != tuple(map(int, (
    expected_search, expected_write, pre_search, pre_write, post_search, post_write,
))):
    raise SystemExit(1)
sample = oracle["host_metrics"]["samples"][0]
if sample["vm_id"] != selected_vm_id:
    raise SystemExit(1)
parse = lambda value: datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
started = parse(oracle["provenance"]["probe_started_at"])
generated = parse(oracle["provenance"]["generated_at"])
collected = parse(sample["collected_at"])
max_age = datetime.timedelta(seconds=oracle["host_metrics"]["max_sample_age_seconds"])
if collected < started or collected > generated or generated - collected > max_age:
    raise SystemExit(1)
PY
}

lrp_publish_oracle() {
    local parent
    LRP_GENERATED_AT="$(lrp_db_utc_now)"
    [ -n "$LRP_GENERATED_AT" ] \
        || probe_fail oracle "could not read DB clock for oracle generated_at"
    LRP_ORACLE_TEMP_FILE="$(mktemp "${LRP_ORACLE_FILE}.tmp.XXXXXX")" \
        || probe_fail oracle "could not create sibling oracle temporary file"
    chmod 600 "$LRP_ORACLE_TEMP_FILE" \
        || probe_fail oracle "could not make oracle temporary file private"
    lrp_serialize_oracle_candidate \
        || probe_fail oracle "could not serialize the oracle candidate"
    lrp_oracle_candidate_is_sane \
        || probe_fail oracle "oracle candidate failed producer-owned sanity checks"
    lrp_oracle_redaction_guard "$LRP_ORACLE_TEMP_FILE" \
        || probe_fail oracle "oracle candidate contained credential-like content"
    parent="$(dirname "$LRP_ORACLE_FILE")"
    if [ ! -d "$parent" ] || lrp_first_symlinked_path_component "$parent" >/dev/null; then
        probe_fail oracle "oracle output parent became unsafe before publication"
    fi
    [ ! -e "$LRP_ORACLE_FILE" ] && [ ! -L "$LRP_ORACLE_FILE" ] \
        || probe_fail oracle "oracle output appeared before atomic publication"
    mv "$LRP_ORACLE_TEMP_FILE" "$LRP_ORACLE_FILE" \
        || probe_fail oracle "could not atomically publish the oracle"
    LRP_ORACLE_TEMP_FILE=""
}
