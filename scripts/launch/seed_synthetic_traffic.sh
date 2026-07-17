#!/usr/bin/env bash
#
# seed_synthetic_traffic.sh — populate staging `usage_records` with
# representative tenant traffic so the billing-rehearsal lane can produce
# real invoices across all three customer archetypes.
#
# Status: SKELETON. The argument parsing, tenant definitions, and safety
# gates are implemented. The staging-specific provisioning and document-
# write sections are marked TODO and must be filled in during the
# follow-up session described in
# docs/launch/synthetic_traffic_seeder_plan.md.
#
# Usage:
#   seed_synthetic_traffic.sh --tenant <A|B|C|all> [--dry-run]
#   seed_synthetic_traffic.sh --tenant all --execute --i-know-this-hits-staging
#   seed_synthetic_traffic.sh --tenant B --execute --i-know-this-hits-staging --provision-only
#
# Modes:
#   default execute             — provision + storage-backfill to target_storage_mb + sustained traffic
#   --duration-minutes 0        — provision + storage-backfill, skip sustained traffic
#   --provision-only            — provision tenant only (skip storage backfill AND sustained traffic).
#                                 Use case: capturing usage_records evidence for B/C without
#                                 multi-GB pumping (LAUNCH.md LB-5). Metering agent writes
#                                 usage_records as soon as the index exists.
#
# Tenant shapes (approved by Stuart 2026-04-24):
#   A — demo-shared-free       (100 MB, 10 writes/min, 1 search/min)
#   B — demo-small-dedicated   (2 GB,  100 writes/min, 10 searches/min)
#   C — demo-medium-dedicated  (20 GB, 1000 writes/min, 50 searches/min)
#
# Compatible with bash 3.2 (macOS default). No associative arrays.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/deterministic_batch_payload.sh
source "$SCRIPT_DIR/../lib/deterministic_batch_payload.sh"

# ---------------------------------------------------------------------------
# Tenant definitions — flat vars, prefix-scoped. Single source of truth.
# ---------------------------------------------------------------------------

TENANT_A_NAME="demo-shared-free"
TENANT_A_PLAN="shared"
TENANT_A_TARGET_STORAGE_MB=100
TENANT_A_WRITES_PER_MINUTE=10
TENANT_A_SEARCHES_PER_MINUTE=1
TENANT_A_EXPECTED_MIN_CENTS=500     # $5 shared minimum floor

TENANT_B_NAME="demo-small-dedicated"
TENANT_B_PLAN="dedicated"
TENANT_B_TARGET_STORAGE_MB=2048
TENANT_B_WRITES_PER_MINUTE=100
TENANT_B_SEARCHES_PER_MINUTE=10
TENANT_B_EXPECTED_MIN_CENTS=1000    # $10 dedicated minimum floor

TENANT_C_NAME="demo-medium-dedicated"
TENANT_C_PLAN="dedicated"
TENANT_C_TARGET_STORAGE_MB=20480
TENANT_C_WRITES_PER_MINUTE=1000
TENANT_C_SEARCHES_PER_MINUTE=50
TENANT_C_EXPECTED_MIN_CENTS=1000    # $10 dedicated min — actual usage will dominate

# ---------------------------------------------------------------------------
# CLI parsing and safety gates
# ---------------------------------------------------------------------------

TENANT_SELECTOR=""
DRY_RUN="true"
EXECUTE_FLAG="false"
STAGING_ACK="false"
DURATION_MINUTES=60
# --provision-only runs ensure_customer_and_tenant only and skips both
# seed_documents_to_target_size and drive_sustained_writes_and_searches.
# Use case: capturing usage_records evidence for tenants B/C without
# pumping multi-GB of storage backfill (LAUNCH.md LB-5). The metering
# agent on staging Flapjack VMs writes usage_records as soon as a tenant
# index exists, regardless of size, so provisioning alone is sufficient
# evidence that the metering chain attributes correctly to each tenant.
PROVISION_ONLY="false"
SEED_BATCH_SIZE=100
SEED_BATCH_SEED=42
MAX_STAGE3_STORAGE_POLLS=400
SUSTAINED_WRITE_OFFSET_BASE=100000
# Flapjack's direct node API requires both the API key and an Application-Id
# header. Keep the Application-Id value in one place so every direct-node curl
# call stays aligned with the backend proxy contract.
FLAPJACK_APPLICATION_ID="flapjack"

die() { echo "[seed-synthetic] ERROR: $*" >&2; exit 1; }
log() { echo "[seed-synthetic] $*"; }

require_option_value() {
  local option_name="$1"
  local option_value="${2:-}"
  case "$option_value" in
    ""|--*) die "${option_name} requires a value" ;;
  esac
}

print_usage() {
  sed -n '2,25p' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tenant)
      require_option_value "--tenant" "${2:-}"
      TENANT_SELECTOR="$2"
      shift 2
      ;;
    --dry-run) DRY_RUN="true"; shift;;
    --execute) EXECUTE_FLAG="true"; DRY_RUN="false"; shift;;
    --i-know-this-hits-staging) STAGING_ACK="true"; shift;;
    --duration-minutes)
      require_option_value "--duration-minutes" "${2:-}"
      DURATION_MINUTES="$2"
      shift 2
      ;;
    --provision-only) PROVISION_ONLY="true"; shift;;
    -h|--help) print_usage; exit 0;;
    *) die "unknown argument: $1";;
  esac
done

case "$DURATION_MINUTES" in
  ""|*[!0-9]*)
    die "--duration-minutes must be a non-negative integer"
    ;;
esac
# `--duration-minutes 0` is a legitimate operational mode: provision the
# tenant and converge storage, but skip the sustained-traffic phase. The
# contract tests rely on this seam (MOCK_SYNTHETIC_DURATION_MINUTES=0) to
# verify earlier stages without paying for write/search loops; tooling
# operators use it for provisioning-only runs.

case "${TENANT_SELECTOR}" in
  A|B|C|all) ;;
  *) die "--tenant must be one of: A, B, C, all";;
esac

if [ "${EXECUTE_FLAG}" = "true" ] && [ "${STAGING_ACK}" != "true" ]; then
  die "--execute requires --i-know-this-hits-staging (this mutates staging state)"
fi

# Stage-2 gate (rejected --tenant B/C/all in execute mode) was lifted on
# 2026-05-01 to satisfy LAUNCH.md LB-5. The seeder code path is letter-
# agnostic: tenant_field, tenant_mapping_path, run_tenant, ensure_customer_and_tenant,
# seed_documents_to_target_size, and drive_sustained_writes_and_searches all
# already operated correctly for B and C; the only blockers were the two
# explicit Stage-2 gates (here and in run_tenant). Removing them unblocks
# usage_records evidence for the dedicated-plan tenants.

# ---------------------------------------------------------------------------
# Tenant field lookup — bash 3.2 compatible indirect expansion.
# ---------------------------------------------------------------------------

tenant_field() {
  # tenant_field <A|B|C> <NAME|PLAN|TARGET_STORAGE_MB|WRITES_PER_MINUTE|SEARCHES_PER_MINUTE|EXPECTED_MIN_CENTS>
  local letter="$1" field="$2"
  local var="TENANT_${letter}_${field}"
  case "$letter" in
    A|B|C) ;;
    *)
      return 1
      ;;
  esac
  case "$field" in
    NAME|PLAN|TARGET_STORAGE_MB|WRITES_PER_MINUTE|SEARCHES_PER_MINUTE|EXPECTED_MIN_CENTS) ;;
    *)
      return 1
      ;;
  esac
  printf '%s' "${!var-}"
}

seed_synthetic_state_dir() {
  local uid_value state_dir
  uid_value="${UID:-$(id -u)}"
  state_dir="${SEED_SYNTHETIC_STATE_DIR:-/tmp/seed-synthetic-${uid_value}}"

  if [ -L "$state_dir" ]; then
    if [ ! -d "$state_dir" ]; then
      die "seed state dir symlink must resolve to a directory: ${state_dir}"
    fi
    if [ ! -w "$state_dir" ]; then
      die "seed state dir symlink target must be writable: ${state_dir}"
    fi
    printf '%s' "$state_dir"
    return 0
  fi
  if [ -e "$state_dir" ] && [ ! -d "$state_dir" ]; then
    die "seed state dir path must be a directory: ${state_dir}"
  fi

  mkdir -p "$state_dir"
  chmod 700 "$state_dir" 2>/dev/null || die "failed to secure seed state dir permissions: ${state_dir}"
  printf '%s' "$state_dir"
}

tenant_mapping_path() {
  local letter="$1"
  printf '%s/seed-synthetic-%s.json' "$(seed_synthetic_state_dir)" "$(tenant_field "$letter" NAME)"
}

json_string() {
  python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"
}

parse_json_field() {
  local field_name="$1"
  python3 -c 'import json, sys
field = sys.argv[1]
obj = json.load(sys.stdin)
value = obj.get(field, "")
if value is None:
    print("")
elif isinstance(value, (dict, list)):
    print(json.dumps(value))
else:
    print(value)
' "$field_name"
}

http_response_status() {
  printf '%s\n' "$1" | tail -1
}

http_response_body() {
  printf '%s\n' "$1" | sed '$d'
}

admin_call() {
  local method="$1" path="$2"
  shift 2
  curl -sS -X "$method" "${API_URL}${path}" \
    -H "Content-Type: application/json" \
    -H "x-admin-key: ${ADMIN_KEY}" \
    "$@" \
    -w '\n%{http_code}'
}

mapping_field_or_empty() {
  local mapping_path="$1" field_name="$2"
  if [ ! -f "$mapping_path" ]; then
    printf ''
    return 0
  fi
  parse_json_field "$field_name" < "$mapping_path" 2>/dev/null || true
}

write_tenant_mapping_artifact() {
  local mapping_path="$1"
  local customer_id="$2"
  local tenant_id="$3"
  local flapjack_uid="$4"
  local flapjack_url="$5"
  local mapping_dir mapping_tmp

  mapping_dir="$(dirname "$mapping_path")"
  mkdir -p "$mapping_dir"
  if [ -L "$mapping_dir" ]; then
    if [ ! -d "$mapping_dir" ]; then
      die "tenant mapping dir symlink must resolve to a directory: ${mapping_dir}"
    fi
    if [ ! -w "$mapping_dir" ]; then
      die "tenant mapping dir symlink target must be writable: ${mapping_dir}"
    fi
  elif [ -O "$mapping_dir" ]; then
    chmod 700 "$mapping_dir" 2>/dev/null || die "failed to secure tenant mapping dir permissions: ${mapping_dir}"
  elif [ ! -w "$mapping_dir" ]; then
    die "tenant mapping dir must be writable: ${mapping_dir}"
  fi
  mapping_tmp="$(mktemp "${mapping_path}.tmp.XXXXXX")" || die "failed to allocate tenant mapping temp file"

  cat > "$mapping_tmp" <<EOF
{"customer_id":$(json_string "$customer_id"),"tenant_id":$(json_string "$tenant_id"),"flapjack_uid":$(json_string "$flapjack_uid"),"flapjack_url":$(json_string "$flapjack_url")}
EOF
  chmod 600 "$mapping_tmp" 2>/dev/null || {
    rm -f "$mapping_tmp"
    die "failed to secure tenant mapping file permissions: ${mapping_tmp}"
  }
  mv "$mapping_tmp" "$mapping_path"
}

flapjack_url_host_or_empty() {
  local flapjack_url="$1"
  printf '%s' "$flapjack_url" | python3 -c '
import sys, urllib.parse as u
parsed = u.urlparse(sys.stdin.read().strip())
print(parsed.hostname or "")
'
}

# Direct-node flows (/internal/storage, /1/indexes/*) must not target public
# control-plane hosts (api.* / cloud.*). Those hosts are not direct Flapjack
# node endpoints and return 404 for direct-index routes.
flapjack_url_is_control_plane() {
  local flapjack_url="$1"
  local host
  host="$(flapjack_url_host_or_empty "$flapjack_url")"
  case "$host" in
    api.*|cloud.*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

healthy_shared_vm_url_from_ssm() {
  local region parameter_names parameter_name host health_status
  region="${AWS_DEFAULT_REGION:-us-east-1}"
  parameter_names="$(aws ssm describe-parameters \
    --region "$region" \
    --parameter-filters Key=Name,Option=Contains,Values=vm-shared \
    --query 'Parameters[].Name' --output text 2>/dev/null | tr '\t' '\n' | sort || true)"

  while IFS= read -r parameter_name; do
    [ -n "$parameter_name" ] || continue
    case "$parameter_name" in
      /fjcloud/vm-shared-*.flapjack.foo/api-key) ;;
      *) continue ;;
    esac
    host="${parameter_name#/fjcloud/}"
    host="${host%/api-key}"
    health_status="$(curl -sS --connect-timeout 2 --max-time 4 \
      -o /dev/null -w '%{http_code}' "http://${host}:7700/health" 2>/dev/null || true)"
    if [ "$health_status" = "200" ]; then
      printf 'http://%s:7700' "$host"
      return 0
    fi
  done <<EOF
$parameter_names
EOF
  return 1
}

direct_fallback_flapjack_url_for_tenant() {
  local tenant_letter="$1"
  local mapped_a_url=""
  local healthy_shared_vm_url=""
  local mapped_a_path

  if [ "$tenant_letter" != "A" ]; then
    mapped_a_path="$(tenant_mapping_path "A")"
    mapped_a_url="$(mapping_field_or_empty "$mapped_a_path" "flapjack_url")"
    if [ -n "$mapped_a_url" ] && [ "$mapped_a_url" != "null" ] && ! flapjack_url_is_control_plane "$mapped_a_url"; then
      printf '%s' "$mapped_a_url"
      return 0
    fi
  fi

  if [ -n "${FLAPJACK_URL:-}" ] && [ "${FLAPJACK_URL}" != "null" ] && ! flapjack_url_is_control_plane "${FLAPJACK_URL}"; then
    printf '%s' "${FLAPJACK_URL}"
    return 0
  fi

  if healthy_shared_vm_url="$(healthy_shared_vm_url_from_ssm)"; then
    printf '%s' "$healthy_shared_vm_url"
    return 0
  fi

  printf '%s' "${FLAPJACK_URL:-}"
}

probe_owner_counter_dir() {
  if [ -n "${PROBE_OWNER_COUNTER_DIR:-}" ]; then
    printf '%s' "$PROBE_OWNER_COUNTER_DIR"
    return 0
  fi
  if [ -n "${PROBE_OUTPUT_DIR:-}" ]; then
    printf '%s' "$PROBE_OUTPUT_DIR"
    return 0
  fi
  printf ''
}

probe_owner_counter_path() {
  local tenant_letter="$1" metric_name="$2"
  local counter_dir
  counter_dir="$(probe_owner_counter_dir)"
  if [ -z "$counter_dir" ]; then
    printf ''
    return 0
  fi
  printf '%s/%s_%s.count' "$counter_dir" "$tenant_letter" "$metric_name"
}

probe_owner_event_log_path() {
  local log_kind="$1"
  local counter_dir
  counter_dir="$(probe_owner_counter_dir)"
  if [ -z "$counter_dir" ]; then
    printf ''
    return 0
  fi
  printf '%s/probe_owner_%s_events.log' "$counter_dir" "$log_kind"
}

probe_owner_append_event() {
  local log_kind="$1" tenant_letter="$2" operation_name="$3" status_code="$4"
  local event_log_path now_epoch
  event_log_path="$(probe_owner_event_log_path "$log_kind")"
  if [ -z "$event_log_path" ] || [ -z "$tenant_letter" ]; then
    return 0
  fi
  now_epoch="$(date +%s)"
  printf '%s|%s|%s|%s\n' "$now_epoch" "$tenant_letter" "$operation_name" "$status_code" >> "$event_log_path"
}

probe_owner_read_numeric_or_zero() {
  local count_path="$1"
  if [ -z "$count_path" ] || [ ! -f "$count_path" ]; then
    printf '0'
    return 0
  fi
  local value
  value="$(tr -dc '0-9\n' < "$count_path" | tail -n 1)"
  if [ -z "$value" ]; then
    printf '0'
    return 0
  fi
  printf '%s' "$value"
}

probe_owner_count_fail_fast_events_in_window() {
  local tenant_letter="$1" window_start_epoch="$2" window_end_epoch="$3"
  local write_events_log fail_fast_count
  write_events_log="$(probe_owner_event_log_path "write")"
  fail_fast_count="$(
    python3 - "$tenant_letter" "$window_start_epoch" "$window_end_epoch" "$write_events_log" <<'PY'
import sys

tenant_letter = sys.argv[1]
window_start = int(sys.argv[2]) if sys.argv[2].isdigit() else 0
window_end = int(sys.argv[3]) if sys.argv[3].isdigit() else 0
paths = [sys.argv[4]]

if window_start <= 0 or window_end <= 0 or window_end < window_start:
    print("0")
    raise SystemExit(0)

count = 0
for path in paths:
    if not path:
        continue
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for raw_line in handle:
                line = raw_line.strip()
                if not line:
                    continue
                pieces = line.split("|")
                if len(pieces) != 4:
                    continue
                event_epoch_raw, event_tenant, _operation, status_raw = pieces
                if event_tenant != tenant_letter:
                    continue
                try:
                    event_epoch = int(event_epoch_raw)
                    status_code = int(status_raw)
                except ValueError:
                    continue
                if event_epoch < window_start or event_epoch > window_end:
                    continue
                if status_code not in (200, 202):
                    count += 1
    except FileNotFoundError:
        continue

print(str(count))
PY
  )"
  if [ -z "$fail_fast_count" ]; then
    printf '0'
    return 0
  fi
  printf '%s' "$fail_fast_count"
}

probe_owner_query_hit_count() {
  local flapjack_url="$1" flapjack_uid="$2" query_term="$3"
  local node_api_key query_payload response status body hit_count
  node_api_key="$(node_api_key_for_url "$flapjack_url")"
  query_payload="$(printf '{"query":%s}' "$(json_string "$query_term")")"
  response="$(curl -sS -X POST "${flapjack_url}/1/indexes/${flapjack_uid}/query" \
    -H "Content-Type: application/json" \
    -H "X-Algolia-API-Key: ${node_api_key}" \
    -H "X-Algolia-Application-Id: ${FLAPJACK_APPLICATION_ID}" \
    -d "$query_payload" \
    -w '\n%{http_code}')"
  status="$(http_response_status "$response")"
  body="$(http_response_body "$response")"
  case "$status" in
    200|202) ;;
    *)
      return 9
      ;;
  esac
  if ! hit_count="$(python3 - "$body" <<'PY'
import json
import sys

try:
    payload = json.loads(sys.argv[1])
except json.JSONDecodeError:
    raise SystemExit(9)

hits = payload.get("hits")
if isinstance(hits, list):
    print(str(len(hits)))
    raise SystemExit(0)

for key in ("estimatedTotalHits", "nbHits", "totalHits"):
    value = payload.get(key)
    if isinstance(value, int):
        print(str(value))
        raise SystemExit(0)
    if isinstance(value, str) and value.isdigit():
        print(value)
        raise SystemExit(0)

raise SystemExit(8)
PY
  )"; then
    return 9
  fi
  printf '%s' "$hit_count"
}

probe_owner_health_status_code() {
  local flapjack_url="$1"
  local response status
  response="$(curl -sS -X GET "${flapjack_url}/health" -w '\n%{http_code}')"
  status="$(http_response_status "$response")"
  printf '%s' "$status"
}

probe_owner_fail_fast_during_restart_window_count() {
  local flapjack_url="$1" flapjack_uid="$2" window_start_epoch="$3" window_end_epoch="$4" tenant_letter="$5"
  : "$flapjack_url" "$flapjack_uid"
  probe_owner_count_fail_fast_events_in_window "$tenant_letter" "$window_start_epoch" "$window_end_epoch"
}

probe_owner_writes_attempted_during_restart_window_count() {
  local flapjack_url="$1" flapjack_uid="$2" window_start_epoch="$3" window_end_epoch="$4" tenant_letter="$5"
  local write_events_log attempted_count
  : "$flapjack_url" "$flapjack_uid"
  write_events_log="$(probe_owner_event_log_path "write")"
  attempted_count="$(
    python3 - "$tenant_letter" "$window_start_epoch" "$window_end_epoch" "$write_events_log" <<'PY'
import sys

tenant_letter = sys.argv[1]
window_start = int(sys.argv[2]) if sys.argv[2].isdigit() else 0
window_end = int(sys.argv[3]) if sys.argv[3].isdigit() else 0
path = sys.argv[4]

if window_start <= 0 or window_end <= 0 or window_end < window_start:
    print("0")
    raise SystemExit(0)

count = 0
try:
    with open(path, "r", encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line:
                continue
            pieces = line.split("|")
            if len(pieces) != 4:
                continue
            event_epoch_raw, event_tenant, _operation, _status_raw = pieces
            if event_tenant != tenant_letter:
                continue
            try:
                event_epoch = int(event_epoch_raw)
            except ValueError:
                continue
            if event_epoch < window_start or event_epoch > window_end:
                continue
            count += 1
except FileNotFoundError:
    count = 0

print(str(count))
PY
  )"
  printf '%s' "${attempted_count:-0}"
}

probe_owner_query_exact_object_hit_count() {
  local flapjack_url="$1" flapjack_uid="$2" object_id="$3"
  local exact_query_term hit_count
  # Live staging disproved GET /documents/<id> as a readback contract for
  # deterministic probe writes: published batch tasks became searchable on the
  # canonical flapjack UID while the document endpoint still returned 404.
  # Reconstruct the write's unique deterministic body token and query for that
  # exact term instead, which preserves same-index exactness without relying on
  # the live-broken document read route.
  if ! exact_query_term="$(deterministic_exact_query_term_for_object_id "$SEED_BATCH_SEED" "$object_id")"; then
    return 9
  fi
  if ! hit_count="$(probe_owner_query_hit_count "$flapjack_url" "$flapjack_uid" "$exact_query_term")"; then
    return 9
  fi
  case "$hit_count" in
    ''|*[!0-9]*) return 9 ;;
  esac
  if [ "$hit_count" -gt 0 ]; then
    printf '1'
  else
    printf '0'
  fi
}

probe_owner_visible_in_search_after_count() {
  local flapjack_url="$1" flapjack_uid="$2" window_start_epoch="$3" window_end_epoch="$4" tenant_letter="$5"
  local write_events_log visible_count doc_ids doc_id hit_count
  write_events_log="$(probe_owner_event_log_path "write")"
  visible_count=0
  if [ ! -f "$write_events_log" ]; then
    printf '0'
    return 0
  fi
  doc_ids="$(
    awk -F'|' -v tenant="$tenant_letter" -v start="$window_start_epoch" -v end="$window_end_epoch" '
      NF==4 {
        epoch=$1+0
        status=$4+0
        if ($2==tenant && epoch>=start && epoch<=end && (status==200 || status==202) && $3 ~ /^doc-/) {
          print $3
        }
      }
    ' "$write_events_log"
  )"
  if [ -z "$doc_ids" ]; then
    # Zero successful restart-window writes is a valid measured outcome.
    # Return a numeric zero so probe consumers keep callback-backed scope.
    printf '0'
    return 0
  fi
  while IFS= read -r doc_id; do
    [ -n "$doc_id" ] || continue
    if hit_count="$(probe_owner_query_exact_object_hit_count "$flapjack_url" "$flapjack_uid" "$doc_id")"; then
      case "$hit_count" in
        ''|*[!0-9]*) ;;
        *)
          if [ "$hit_count" -gt 0 ]; then
            visible_count=$((visible_count + 1))
          fi
          ;;
      esac
    fi
  done <<EOF
$doc_ids
EOF
  printf '%s' "$visible_count"
}

probe_owner_cross_tenant_leak_count() {
  local flapjack_url="$1" flapjack_uid="$2" tenant_letter="$3"
  local source_offset_base source_doc_id leaks old_ifs peer_letter peer_mapping_path peer_flapjack_url peer_flapjack_uid peer_hits
  local counter_path
  : "$flapjack_url" "$flapjack_uid"
  counter_path="$(probe_owner_counter_path "$tenant_letter" "write_offset_base")"
  source_offset_base="$(probe_owner_read_numeric_or_zero "$counter_path")"
  if [ "$source_offset_base" -le 0 ]; then
    printf '0'
    return 0
  fi
  source_doc_id="doc-${source_offset_base}"
  leaks=0
  old_ifs="$IFS"
  IFS=','
  for peer_letter in ${PROBE_TENANTS_CSV:-}; do
    if [ -z "$peer_letter" ] || [ "$peer_letter" = "$tenant_letter" ]; then
      continue
    fi
    peer_mapping_path="$(tenant_mapping_path "$peer_letter")"
    peer_flapjack_url="$(mapping_field_or_empty "$peer_mapping_path" "flapjack_url")"
    peer_flapjack_uid="$(mapping_field_or_empty "$peer_mapping_path" "flapjack_uid")"
    if [ -z "$peer_flapjack_url" ] || [ -z "$peer_flapjack_uid" ]; then
      return 10
    fi
    if ! peer_hits="$(probe_owner_query_exact_object_hit_count "$peer_flapjack_url" "$peer_flapjack_uid" "$source_doc_id")"; then
      return 11
    fi
    case "$peer_hits" in
      ''|*[!0-9]*) return 12 ;;
    esac
    if [ "$peer_hits" -gt 0 ]; then
      leaks=$((leaks + 1))
    fi
  done
  IFS="$old_ifs"
  printf '%s' "$leaks"
}

probe_owner_noisy_neighbor_violation_count() {
  local flapjack_url="$1" flapjack_uid="$2" tenant_letter="$3"
  local violations old_ifs peer_letter peer_mapping_path peer_flapjack_url peer_status
  : "$flapjack_uid" "$tenant_letter"
  violations=0
  old_ifs="$IFS"
  IFS=','
  for peer_letter in ${PROBE_TENANTS_CSV:-}; do
    if [ -z "$peer_letter" ] || [ "$peer_letter" = "$tenant_letter" ]; then
      continue
    fi
    peer_mapping_path="$(tenant_mapping_path "$peer_letter")"
    peer_flapjack_url="$(mapping_field_or_empty "$peer_mapping_path" "flapjack_url")"
    if [ -z "$peer_flapjack_url" ]; then
      return 13
    fi
    peer_status="$(probe_owner_health_status_code "$peer_flapjack_url")"
    case "$peer_status" in
      ''|*[!0-9]*) return 14 ;;
      200) ;;
      *) violations=$((violations + 1)) ;;
    esac
  done
  IFS="$old_ifs"
  # Probe the active tenant last so a callback caller can detect local
  # availability regression as a noisy-neighbor symptom.
  peer_status="$(probe_owner_health_status_code "$flapjack_url")"
  case "$peer_status" in
    ''|*[!0-9]*) return 15 ;;
    200) ;;
    *) violations=$((violations + 1)) ;;
  esac
  printf '%s' "$violations"
}

single_write_batch_payload() {
  local offset="$1"
  deterministic_batch_payload "$SEED_BATCH_SEED" "$offset" 1
}

per_minute_sleep_seconds() {
  local rate="$1"
  python3 - "$rate" <<'PY'
import sys

rate = float(sys.argv[1])
if rate <= 0:
    print("0")
else:
    print(f"{60.0 / rate:.6f}")
PY
}

poll_child_exit_status() {
  local pid="$1"
  if kill -0 "$pid" 2>/dev/null; then
    return 1
  fi
  wait "$pid" 2>/dev/null
  printf '%s' "$?"
}

poll_child_exit_interval() {
  python3 - <<'PY'
import time

time.sleep(0.05)
PY
}

run_direct_write_loop() {
  local flapjack_url="$1" flapjack_uid="$2" total_writes="$3" sleep_seconds="$4" count_path="$5"
  local sent=0 document_offset payload response status
  local node_api_key
  node_api_key="$(node_api_key_for_url "$flapjack_url")"

  while [ "$sent" -lt "$total_writes" ]; do
    document_offset=$((SUSTAINED_WRITE_OFFSET_BASE + sent))
    payload="$(single_write_batch_payload "$document_offset")"
    # Use the same direct batch contract as the storage backfill step. The
    # live node accepts /batch for writes, while /documents currently 405s.
    response="$(curl -sS -X POST "${flapjack_url}/1/indexes/${flapjack_uid}/batch" \
      -H "Content-Type: application/json" \
      -H "X-Algolia-API-Key: ${node_api_key}" \
      -H "X-Algolia-Application-Id: ${FLAPJACK_APPLICATION_ID}" \
      -d "$payload" \
      -w '\n%{http_code}')"
    status="$(http_response_status "$response")"
    probe_owner_append_event "write" "${PROBE_ACTIVE_TENANT_LETTER:-}" "doc-${document_offset}" "$status"
    case "$status" in
      200|202) ;;
      *)
        # Under probe mode the loop runs across the API restart window, where
        # transient non-200/202 responses are expected. The failure is already
        # recorded as a fail-fast event via probe_owner_append_event above, so log
        # and continue (still counting the attempt) instead of aborting — that lets
        # the probe reach assertion evaluation. The standalone seeder (no
        # PROBE_ACTIVE_TENANT_LETTER) still treats a write failure as fatal.
        if [ -n "${PROBE_ACTIVE_TENANT_LETTER:-}" ]; then
          log "sustained write transient error for ${flapjack_uid} (status=${status}); probe mode continuing"
        else
          die "sustained write failed for ${flapjack_uid} (status=${status} body=$(http_response_body "$response"))"
        fi
        ;;
    esac
    sent=$((sent + 1))
    printf '%s' "$sent" > "$count_path"
    if [ "$sent" -lt "$total_writes" ]; then
      sleep "$sleep_seconds"
    fi
  done
}

run_direct_search_loop() {
  local flapjack_url="$1" flapjack_uid="$2" total_searches="$3" sleep_seconds="$4" count_path="$5"
  local sent=0 response status search_payload
  local node_api_key
  node_api_key="$(node_api_key_for_url "$flapjack_url")"
  search_payload='{"query":"Document"}'

  while [ "$sent" -lt "$total_searches" ]; do
    response="$(curl -sS -X POST "${flapjack_url}/1/indexes/${flapjack_uid}/query" \
      -H "Content-Type: application/json" \
      -H "X-Algolia-API-Key: ${node_api_key}" \
      -H "X-Algolia-Application-Id: ${FLAPJACK_APPLICATION_ID}" \
      -d "$search_payload" \
      -w '\n%{http_code}')"
    status="$(http_response_status "$response")"
    probe_owner_append_event "search" "${PROBE_ACTIVE_TENANT_LETTER:-}" "query" "$status"
    case "$status" in
      200|202) ;;
      *)
        # Searches issued just after restart recovery may still see transient
        # errors; same probe-mode seam as run_direct_write_loop. The event is
        # already logged above, so continue under probe mode and stay fatal for
        # the standalone seeder.
        if [ -n "${PROBE_ACTIVE_TENANT_LETTER:-}" ]; then
          log "sustained search transient error for ${flapjack_uid} (status=${status}); probe mode continuing"
        else
          die "sustained search failed for ${flapjack_uid} (status=${status} body=$(http_response_body "$response"))"
        fi
        ;;
    esac
    sent=$((sent + 1))
    printf '%s' "$sent" > "$count_path"
    if [ "$sent" -lt "$total_searches" ]; then
      sleep "$sleep_seconds"
    fi
  done
}

# ---------------------------------------------------------------------------
# Pre-flight environment checks
# ---------------------------------------------------------------------------

preflight_env() {
  # FLAPJACK_API_KEY is intentionally NOT required: each shared VM uses a
  # distinct per-node admin key stored at SSM /fjcloud/{vm-hostname}/api-key,
  # so a single global key value is meaningless against staging. The seeder
  # resolves the right key per VM via node_api_key_for_url(). FLAPJACK_API_KEY
  # is still honored as a test/override seam.
  local required="DATABASE_URL API_URL ADMIN_KEY FLAPJACK_URL"
  local missing=""
  for v in ${required}; do
    if [ -z "${!v:-}" ]; then
      missing="${missing} ${v}"
    fi
  done
  if [ -n "${missing}" ]; then
    die "missing required env vars:${missing} (source .secret/.env.secret first)"
  fi
}

# Resolve the per-node flapjack admin API key for a given flapjack_url.
#
# Each shared VM is provisioned with its own SSM-stored admin key under
# /fjcloud/{vm-hostname}/api-key (see ops/user-data/bootstrap.sh). The seeder
# attaches new tenants to existing VMs, so direct-node calls must use that
# VM's key — not whatever the operator has set as FLAPJACK_API_KEY.
#
# Resolution order:
#   1. Non-.flapjack.foo hosts: ${FLAPJACK_API_KEY} env var (test/local seam).
#   2. SSM GetParameter on /fjcloud/{host}/api-key in ${AWS_DEFAULT_REGION:-us-east-1}.
#   3. Final fallback to ${FLAPJACK_API_KEY} only when the SSM lookup fails.
#
# Results are cached in-process via dynamic var names (bash 3.2 compatible)
# so hot write/search loops do not re-query SSM per request.
node_api_key_for_url() {
  local flapjack_url="$1"
  local host ssm_path region key ssm_lookup_error=""
  host="$(printf '%s' "$flapjack_url" | python3 -c '
import sys, urllib.parse as u
parsed = u.urlparse(sys.stdin.read().strip())
print(parsed.hostname or "")
')"
  [ -n "$host" ] || die "failed to parse host from flapjack_url: ${flapjack_url}"

  # bash 3.2 lacks associative arrays; fake one via dynamic env var names.
  local cache_var="_NODE_KEY_CACHE_${host}"
  cache_var="${cache_var//./_}"
  cache_var="${cache_var//-/_}"
  if [ -n "${!cache_var:-}" ]; then
    printf '%s' "${!cache_var}"
    return 0
  fi

  # Non-production/local hosts (for example synthetic test hosts) continue
  # to honor FLAPJACK_API_KEY as the primary seam.
  if [[ "$host" != *.flapjack.foo ]]; then
    if [ -n "${FLAPJACK_API_KEY:-}" ]; then
      printf -v "$cache_var" '%s' "${FLAPJACK_API_KEY}"
      printf '%s' "${FLAPJACK_API_KEY}"
      return 0
    fi
  fi

  ssm_path="/fjcloud/${host}/api-key"
  region="${AWS_DEFAULT_REGION:-us-east-1}"
  key=""
  if key="$(aws ssm get-parameter --name "$ssm_path" --with-decryption --region "$region" --query 'Parameter.Value' --output text 2>&1)"; then
    [ -n "$key" ] && [ "$key" != "None" ] || die "SSM returned empty value for ${ssm_path}"
    printf -v "$cache_var" '%s' "$key"
    printf '%s' "$key"
    return 0
  fi
  ssm_lookup_error="$key"

  # For vm-host paths, stale FLAPJACK_API_KEY values can cause persistent 403s.
  # Only fall back to FLAPJACK_API_KEY when SSM is unavailable.
  if [ -n "${FLAPJACK_API_KEY:-}" ]; then
    printf -v "$cache_var" '%s' "${FLAPJACK_API_KEY}"
    printf '%s' "${FLAPJACK_API_KEY}"
    return 0
  fi
  die "SSM lookup failed for ${ssm_path} (region=${region}): ${ssm_lookup_error}; set FLAPJACK_API_KEY or grant ssm:GetParameter on the operator IAM"
}

read_mapped_storage_mb() {
  local flapjack_url="$1" flapjack_uid="$2"
  local storage_response storage_status storage_body mapped_storage_mb
  local node_api_key
  node_api_key="$(node_api_key_for_url "$flapjack_url")"
  storage_response="$(curl -sS -X GET "${flapjack_url}/internal/storage" \
    -H "X-Algolia-API-Key: ${node_api_key}" \
    -H "X-Algolia-Application-Id: ${FLAPJACK_APPLICATION_ID}" \
    -w '\n%{http_code}')"
  storage_status="$(http_response_status "$storage_response")"
  storage_body="$(http_response_body "$storage_response")"
  if [ "$storage_status" != "200" ]; then
    die "storage poll failed for ${flapjack_uid} at ${flapjack_url} (status=${storage_status} body=${storage_body})"
  fi
  mapped_storage_mb="$(
    python3 - "$flapjack_uid" "$storage_body" <<'PY'
import json
import sys

uid = sys.argv[1]
raw_body = sys.argv[2]
payload = json.loads(raw_body)
tenants = payload.get("tenants")
if not isinstance(tenants, list):
    raise SystemExit(2)
for tenant in tenants:
    if str(tenant.get("id", "")) != uid:
        continue
    try:
        raw_bytes = int(tenant.get("bytes", 0))
    except (TypeError, ValueError):
        raise SystemExit(3)
    print(f"{raw_bytes / 1048576.0:.2f}")
    raise SystemExit(0)
# Tenant not yet present in /internal/storage. Flapjack only emits a tenant
# row after the first successful write, so an absent uid means "0 bytes
# stored" — the legitimate starting state for a freshly-created index.
print("0.00")
PY
  )"
  if [ -z "$mapped_storage_mb" ]; then
    die "storage poll returned no value for '${flapjack_uid}' at ${flapjack_url}"
  fi
  printf '%s' "$mapped_storage_mb"
}

# ---------------------------------------------------------------------------
# Per-tenant execution stages
# ---------------------------------------------------------------------------

describe_tenant() {
  local letter="$1"
  log "  name:              $(tenant_field "$letter" NAME)"
  log "  plan:              $(tenant_field "$letter" PLAN)"
  log "  target_storage_mb: $(tenant_field "$letter" TARGET_STORAGE_MB)"
  log "  writes_per_minute: $(tenant_field "$letter" WRITES_PER_MINUTE)"
  log "  searches_per_min:  $(tenant_field "$letter" SEARCHES_PER_MINUTE)"
  log "  expected floor:    $(tenant_field "$letter" EXPECTED_MIN_CENTS) cents/month"
}

resolve_customer_id_by_name_or_email() {
  local expected_name="$1" expected_email="$2"
  local list_response list_status list_body resolved_customer_id

  list_response="$(admin_call "GET" "/admin/tenants")"
  list_status="$(http_response_status "$list_response")"
  list_body="$(http_response_body "$list_response")"
  if [ "$list_status" != "200" ]; then
    die "tenant lookup failed while resolving existing customer_id for ${expected_name} (status=${list_status} body=${list_body})"
  fi

  resolved_customer_id="$(
    python3 - "$expected_name" "$expected_email" "$list_body" <<'PY'
import json
import sys

expected_name = sys.argv[1]
expected_email = sys.argv[2]
raw_payload = sys.argv[3]
payload = json.loads(raw_payload)

if isinstance(payload, dict):
    tenant_rows = payload.get("tenants") or payload.get("items") or []
elif isinstance(payload, list):
    tenant_rows = payload
else:
    tenant_rows = []

candidates = []

for tenant in tenant_rows:
    if not isinstance(tenant, dict):
        continue
    tenant_name = str(tenant.get("name", ""))
    tenant_email = str(tenant.get("email", ""))
    if tenant_name != expected_name and tenant_email != expected_email:
        continue
    tenant_id = tenant.get("id")
    if not tenant_id:
        continue
    status = str(tenant.get("status", "")).strip().lower()
    candidates.append((str(tenant_id), status))

for tenant_id, status in candidates:
    if status == "active":
        print(tenant_id)
        raise SystemExit(0)

for tenant_id, status in candidates:
    if status not in {"deleted", "soft_deleted", "soft-deleted", "archived", "inactive", "disabled"}:
        print(tenant_id)
        raise SystemExit(0)

if candidates:
    raise SystemExit(0)

print("")
PY
  )"
  printf '%s' "$resolved_customer_id"
}

ensure_customer_and_tenant() {
  local letter="$1" name mapping_path email
  local unique_email_retry_remaining="true"
  local mapped_customer_id="" mapped_tenant_id="" mapped_flapjack_uid="" mapped_flapjack_url=""
  local customer_id="" tenant_id="" flapjack_uid="" flapjack_url=""
  local billing_plan
  local create_payload create_response create_status create_body
  local update_payload update_response update_status
  local index_payload index_response index_status index_body seed_index_flapjack_url
  local index_name index_endpoint
  local stale_customer_retry_remaining="true"
  local lookup_before_create="false"
  ENSURE_CUSTOMER_AND_TENANT_CREATED_THIS_CALL="false"

  name="$(tenant_field "$letter" NAME)"
  billing_plan="$(tenant_field "$letter" PLAN)"
  email="${name}@synthetic-seed.invalid"
  # Persist per-tenant mappings in /tmp because the data is ephemeral run
  # state, not repo state; later stages must reuse the exact routed node.
  mapping_path="$(tenant_mapping_path "$letter")"

  if [ -f "$mapping_path" ]; then
    mapped_customer_id="$(mapping_field_or_empty "$mapping_path" "customer_id")"
    mapped_tenant_id="$(mapping_field_or_empty "$mapping_path" "tenant_id")"
    mapped_flapjack_uid="$(mapping_field_or_empty "$mapping_path" "flapjack_uid")"
    mapped_flapjack_url="$(mapping_field_or_empty "$mapping_path" "flapjack_url")"
  fi

  customer_id="$mapped_customer_id"
  tenant_id="$mapped_tenant_id"
  flapjack_uid="$mapped_flapjack_uid"
  flapjack_url="$mapped_flapjack_url"
  if [ -n "$flapjack_url" ] && [ "$flapjack_url" != "null" ] && flapjack_url_is_control_plane "$flapjack_url"; then
    log "  mapped flapjack_url=${flapjack_url} is control-plane only; clearing cached flapjack_url for direct-node fallback resolution"
    flapjack_url=""
  fi

  while :; do
    if [ -z "$customer_id" ]; then
      if [ "$lookup_before_create" = "true" ]; then
        customer_id="$(resolve_customer_id_by_name_or_email "$name" "$email")"
        lookup_before_create="false"
      fi
    fi

    if [ -z "$customer_id" ]; then
      create_payload="$(printf '{"name":%s,"email":%s}' "$(json_string "$name")" "$(json_string "$email")")"
      create_response="$(admin_call "POST" "/admin/tenants" -d "$create_payload")"
      create_status="$(http_response_status "$create_response")"
      create_body="$(http_response_body "$create_response")"
      case "$create_status" in
        201|409)
          if [ "$create_status" = "201" ]; then
            ENSURE_CUSTOMER_AND_TENANT_CREATED_THIS_CALL="true"
            customer_id="$(printf '%s\n' "$create_body" | parse_json_field "id" 2>/dev/null || true)"
          else
            customer_id="$(resolve_customer_id_by_name_or_email "$name" "$email")"
            if [ -n "$customer_id" ] && [ "$customer_id" != "null" ]; then
              :
            elif [ "$unique_email_retry_remaining" = "true" ]; then
              unique_email_retry_remaining="false"
              email="${name}+$(date -u +%Y%m%dT%H%M%SZ)-$$@synthetic-seed.invalid"
              log "  canonical synthetic email is blocked by deleted tenant history; retrying create with a unique synthetic email"
              continue
            fi
          fi
          ;;
        *)
          die "create tenant failed for ${name} (status=${create_status} body=${create_body})"
          ;;
      esac
      if [ -z "$customer_id" ] || [ "$customer_id" = "null" ]; then
        customer_id="$(resolve_customer_id_by_name_or_email "$name" "$email")"
      fi
    fi

    if [ "$customer_id" = "null" ]; then
      customer_id=""
    fi
    [ -n "$customer_id" ] || die "tenant provisioning did not resolve customer_id for ${name}"

    update_payload="$(printf '{"billing_plan":%s}' "$(json_string "$billing_plan")")"
    update_response="$(admin_call "PUT" "/admin/tenants/${customer_id}" -d "$update_payload")"
    update_status="$(http_response_status "$update_response")"
    if [ "$update_status" = "200" ]; then
      break
    fi
    if [ "$update_status" = "404" ] && [ "$stale_customer_retry_remaining" = "true" ]; then
      stale_customer_retry_remaining="false"
      log "  mapped customer_id=${customer_id} was not active (update 404); clearing cached mapping state and reprovisioning once"
      customer_id=""
      tenant_id=""
      flapjack_uid=""
      flapjack_url=""
      lookup_before_create="true"
      continue
    fi
    die "update tenant failed for ${name} (status=${update_status} body=$(http_response_body "$update_response"))"
  done

  seed_index_flapjack_url="${FLAPJACK_URL}"
  if [ -z "$seed_index_flapjack_url" ] || [ "$seed_index_flapjack_url" = "null" ] || flapjack_url_is_control_plane "$seed_index_flapjack_url"; then
    seed_index_flapjack_url="$(direct_fallback_flapjack_url_for_tenant "$letter")"
  fi
  if [ -z "$seed_index_flapjack_url" ] || [ "$seed_index_flapjack_url" = "null" ] || flapjack_url_is_control_plane "$seed_index_flapjack_url"; then
    die "tenant provisioning could not resolve a direct-node flapjack_url for admin seed-index payload for ${name}; got '${seed_index_flapjack_url}'"
  fi

  index_payload="$(printf '{"name":%s,"region":"us-east-1","flapjack_url":%s}' "$(json_string "$name")" "$(json_string "$seed_index_flapjack_url")")"
  index_response="$(admin_call "POST" "/admin/tenants/${customer_id}/indexes" -d "$index_payload")"
  index_status="$(http_response_status "$index_response")"
  index_body="$(http_response_body "$index_response")"
  # 201: first-time create. 200: rerun returning the existing index's
  #   endpoint (post-c4a83033 idempotent fast-path). 409: very narrow
  #   race window in older API binaries — keep accepting it for
  #   backward compatibility with staging hosts that have not yet
  #   picked up the fast-path.
  case "$index_status" in
    200|201|409)
      index_name="$(printf '%s\n' "$index_body" | parse_json_field "name" 2>/dev/null || true)"
      index_endpoint="$(printf '%s\n' "$index_body" | parse_json_field "endpoint" 2>/dev/null || true)"
      if [ -n "$index_name" ]; then
        if [ -z "$tenant_id" ] || [ "$tenant_id" = "null" ]; then
          tenant_id="$index_name"
        fi
        if [ -z "$flapjack_uid" ] || [ "$flapjack_uid" = "null" ]; then
          # Flapjack engine isolates same-named indexes across tenants by
          # prefixing the customer UUID (dashes stripped). Mirror the API's
          # flapjack_index_uid() contract so /internal/storage and /batch
          # find the right tenant entry. See infra/api/src/services/flapjack_node.rs.
          flapjack_uid="${customer_id//-/}_${index_name}"
        fi
      fi
      if [ -n "$index_endpoint" ] && [ "$index_endpoint" != "null" ] && { [ -z "$flapjack_url" ] || [ "$flapjack_url" = "null" ]; }; then
        if flapjack_url_is_control_plane "$index_endpoint"; then
          log "  index endpoint ${index_endpoint} is control-plane only; ignoring for direct-node traffic"
        else
          flapjack_url="$index_endpoint"
        fi
      fi
      ;;
    *)
      die "seed index failed for ${name} (status=${index_status} body=${index_body})"
      ;;
  esac

  if [ -z "$tenant_id" ]; then
    tenant_id="$name"
  fi
  if [ -z "$flapjack_uid" ]; then
    flapjack_uid="${customer_id//-/}_${tenant_id}"
  fi
  if [ -z "$flapjack_url" ] || [ "$flapjack_url" = "null" ] || flapjack_url_is_control_plane "$flapjack_url"; then
    flapjack_url="$(direct_fallback_flapjack_url_for_tenant "$letter")"
  fi
  if [ -z "$flapjack_url" ] || [ "$flapjack_url" = "null" ] || flapjack_url_is_control_plane "$flapjack_url"; then
    die "tenant provisioning could not resolve a direct-node flapjack_url for ${name}; got '${flapjack_url}'"
  fi

  write_tenant_mapping_artifact "$mapping_path" "$customer_id" "$tenant_id" "$flapjack_uid" "$flapjack_url"
  log "  tenant mapping ready at ${mapping_path}"
}

seed_documents_to_target_size() {
  local letter="$1" name target_mb mapping_path
  local customer_id tenant_id flapjack_uid flapjack_url
  local current_storage_mb lower_bound_mb upper_bound_mb
  local batches_sent=0 poll_count=0
  local batch_json write_response write_status
  local node_api_key
  name="$(tenant_field "$letter" NAME)"
  target_mb="$(tenant_field "$letter" TARGET_STORAGE_MB)"
  mapping_path="$(tenant_mapping_path "$letter")"

  if [ ! -f "$mapping_path" ]; then
    die "tenant mapping artifact missing at ${mapping_path}; run ensure_customer_and_tenant before storage backfill"
  fi

  customer_id="$(mapping_field_or_empty "$mapping_path" "customer_id")"
  tenant_id="$(mapping_field_or_empty "$mapping_path" "tenant_id")"
  flapjack_uid="$(mapping_field_or_empty "$mapping_path" "flapjack_uid")"
  flapjack_url="$(mapping_field_or_empty "$mapping_path" "flapjack_url")"

  [ -n "$customer_id" ] && [ "$customer_id" != "null" ] || die "tenant mapping missing customer_id in ${mapping_path}"
  [ -n "$tenant_id" ] && [ "$tenant_id" != "null" ] || die "tenant mapping missing tenant_id in ${mapping_path}"
  [ -n "$flapjack_uid" ] && [ "$flapjack_uid" != "null" ] || die "tenant mapping missing flapjack_uid in ${mapping_path}"
  [ -n "$flapjack_url" ] && [ "$flapjack_url" != "null" ] || die "tenant mapping missing flapjack_url in ${mapping_path}"

  lower_bound_mb="$(python3 - "$target_mb" <<'PY'
import sys
target = float(sys.argv[1])
print(f"{target * 0.90:.2f}")
PY
)"
  upper_bound_mb="$(python3 - "$target_mb" <<'PY'
import sys
target = float(sys.argv[1])
print(f"{target * 1.10:.2f}")
PY
)"
  node_api_key="$(node_api_key_for_url "$flapjack_url")"
  current_storage_mb="$(read_mapped_storage_mb "$flapjack_url" "$flapjack_uid")"

  if python3 - "$current_storage_mb" "$lower_bound_mb" <<'PY'
import sys
current = float(sys.argv[1])
lower_bound = float(sys.argv[2])
raise SystemExit(0 if current >= lower_bound else 1)
PY
  then
    log "  storage floor already satisfied for ${name}: ${current_storage_mb} MB >= ${lower_bound_mb} MB; skipping batch backfill"
    return 0
  fi

  log "  adaptive storage backfill starting for ${name} (${current_storage_mb} MB -> target ${target_mb} MB, tolerance ${lower_bound_mb}-${upper_bound_mb} MB)"
  while true; do
    if python3 - "$current_storage_mb" "$lower_bound_mb" <<'PY'
import sys
current = float(sys.argv[1])
lower = float(sys.argv[2])
raise SystemExit(0 if current >= lower else 1)
PY
    then
      # This script only writes more data; it has no delete/shrink branch.
      # Once the storage floor is satisfied, continuing would only increase
      # overshoot and can never bring the value back toward the target band.
      log "  storage floor satisfied for ${name}: ${current_storage_mb} MB (target tolerance ${lower_bound_mb}-${upper_bound_mb} MB)"
      break
    fi

    batch_json="$(deterministic_batch_payload "$SEED_BATCH_SEED" "$((batches_sent * SEED_BATCH_SIZE))" "$SEED_BATCH_SIZE")"
    write_response="$(curl -sS -X POST "${flapjack_url}/1/indexes/${flapjack_uid}/batch" \
      -H "Content-Type: application/json" \
      -H "X-Algolia-API-Key: ${node_api_key}" \
      -H "X-Algolia-Application-Id: ${FLAPJACK_APPLICATION_ID}" \
      -d "$batch_json" \
      -w '\n%{http_code}')"
    write_status="$(http_response_status "$write_response")"
    case "$write_status" in
      200|202) ;;
      *)
        die "batch backfill failed for ${name} (status=${write_status} body=$(http_response_body "$write_response"))"
        ;;
    esac

    batches_sent=$((batches_sent + 1))
    poll_count=$((poll_count + 1))
    if [ "$poll_count" -gt "$MAX_STAGE3_STORAGE_POLLS" ]; then
      die "storage backfill did not converge for ${name} after ${poll_count} polls"
    fi

    current_storage_mb="$(read_mapped_storage_mb "$flapjack_url" "$flapjack_uid")"
  done
}

drive_sustained_writes_and_searches() {
  local letter="$1" writes searches name mapping_path
  local customer_id tenant_id flapjack_uid flapjack_url
  local total_writes total_searches write_pid=0 search_pid=0
  local write_count_path search_count_path writes_sent=0 searches_sent=0
  local write_sleep_seconds search_sleep_seconds
  local write_done="false" search_done="false"
  local write_status=0 search_status=0
  local completed_status=""

  name="$(tenant_field "$letter" NAME)"
  mapping_path="$(tenant_mapping_path "$letter")"
  writes="$(tenant_field "$letter" WRITES_PER_MINUTE)"
  searches="$(tenant_field "$letter" SEARCHES_PER_MINUTE)"

  [ -f "$mapping_path" ] || die "tenant mapping artifact missing at ${mapping_path}; run provisioning before sustained traffic"

  customer_id="$(mapping_field_or_empty "$mapping_path" "customer_id")"
  tenant_id="$(mapping_field_or_empty "$mapping_path" "tenant_id")"
  flapjack_uid="$(mapping_field_or_empty "$mapping_path" "flapjack_uid")"
  flapjack_url="$(mapping_field_or_empty "$mapping_path" "flapjack_url")"

  [ -n "$customer_id" ] && [ "$customer_id" != "null" ] || die "tenant mapping missing customer_id in ${mapping_path}"
  [ -n "$tenant_id" ] && [ "$tenant_id" != "null" ] || die "tenant mapping missing tenant_id in ${mapping_path}"
  [ -n "$flapjack_uid" ] && [ "$flapjack_uid" != "null" ] || die "tenant mapping missing flapjack_uid in ${mapping_path}"
  [ -n "$flapjack_url" ] && [ "$flapjack_url" != "null" ] || die "tenant mapping missing flapjack_url in ${mapping_path}"

  total_writes=$((writes * DURATION_MINUTES))
  total_searches=$((searches * DURATION_MINUTES))
  write_sleep_seconds="$(per_minute_sleep_seconds "$writes")"
  search_sleep_seconds="$(per_minute_sleep_seconds "$searches")"
  write_count_path="${mapping_path}.writes.count"
  search_count_path="${mapping_path}.searches.count"
  : > "$write_count_path"
  : > "$search_count_path"

  cleanup_sustained_traffic_children() {
    local pid
    for pid in "$write_pid" "$search_pid"; do
      case "$pid" in
        ""|0) continue ;;
      esac
      if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
      fi
    done

    for pid in "$write_pid" "$search_pid"; do
      case "$pid" in
        ""|0) continue ;;
      esac
      wait "$pid" 2>/dev/null || true
    done

    rm -f "$write_count_path" "$search_count_path"
  }

  trap cleanup_sustained_traffic_children INT TERM EXIT

  # Writes and searches are separate loops because the metering agent records
  # them as distinct counters with different target rates.
  log "  sustained traffic starting for ${name}: ${total_writes} writes (~${write_sleep_seconds}s/tick) and ${total_searches} searches (~${search_sleep_seconds}s/tick)"
  [ "$total_writes" -eq 0 ] && [ "$total_searches" -eq 0 ] && { trap - INT TERM EXIT; cleanup_sustained_traffic_children; log "  sustained traffic skipped for ${name}: duration produced zero direct-node operations"; return 0; }

  (
    run_direct_write_loop "$flapjack_url" "$flapjack_uid" "$total_writes" "$write_sleep_seconds" "$write_count_path"
  ) &
  write_pid=$!

  (
    run_direct_search_loop "$flapjack_url" "$flapjack_uid" "$total_searches" "$search_sleep_seconds" "$search_count_path"
  ) &
  search_pid=$!

  while [ "$write_done" != "true" ] || [ "$search_done" != "true" ]; do
    if [ "$write_done" != "true" ] && completed_status="$(poll_child_exit_status "$write_pid")"; then
      write_done="true"
      write_status="$completed_status"
      if [ "$write_status" -ne 0 ]; then
        cleanup_sustained_traffic_children
        die "sustained traffic loop failed for ${name} (write_status=${write_status} search_status=${search_status})"
      fi
    fi

    if [ "$search_done" != "true" ] && completed_status="$(poll_child_exit_status "$search_pid")"; then
      search_done="true"
      search_status="$completed_status"
      if [ "$search_status" -ne 0 ]; then
        cleanup_sustained_traffic_children
        die "sustained traffic loop failed for ${name} (write_status=${write_status} search_status=${search_status})"
      fi
    fi

    if [ "$write_done" = "true" ] && [ "$search_done" = "true" ]; then
      break
    fi

    # bash 3.2 lacks `wait -n`, so poll the recorded child PIDs with a short
    # internal delay instead of reusing the traffic-pacing sleep seam.
    poll_child_exit_interval
  done

  writes_sent="$(cat "$write_count_path" 2>/dev/null || printf '0')"
  searches_sent="$(cat "$search_count_path" 2>/dev/null || printf '0')"
  trap - INT TERM EXIT
  cleanup_sustained_traffic_children

  # This is a one-off launch unblocker, so a pair of short-lived background
  # loops is safer than introducing a long-running scheduler or cron seam.
  log "  sustained traffic complete for ${name}: writes_sent=${writes_sent} searches_sent=${searches_sent}"
}

run_tenant() {
  local letter="$1"
  log ""
  log "=== Tenant ${letter} ==="
  describe_tenant "${letter}"
  if [ "${DRY_RUN}" = "true" ]; then
    if [ "${PROVISION_ONLY}" = "true" ]; then
      log "  [dry-run, provision-only] would only provision the tenant; skipping storage backfill and sustained traffic"
    else
      log "  [dry-run] skipping mutations"
    fi
    return 0
  fi
  # Stage-2 gate that rejected B/C lifted on 2026-05-01 (LAUNCH.md LB-5).
  # ensure_customer_and_tenant + seed_documents_to_target_size +
  # drive_sustained_writes_and_searches are all letter-agnostic via
  # tenant_field/tenant_mapping_path indirection; B and C provision the
  # same way A does, just with larger target_storage_mb / write rates.
  ensure_customer_and_tenant "${letter}"
  if [ "${PROVISION_ONLY}" = "true" ]; then
    log "  [provision-only] tenant ${letter} provisioned; skipping storage backfill and sustained traffic"
    return 0
  fi
  seed_documents_to_target_size "${letter}"
  drive_sustained_writes_and_searches "${letter}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Test seam: when sourced from contract tests with SEED_SYNTHETIC_NO_AUTO_RUN=1,
# expose only the function definitions and skip the top-level run flow. Tests
# can then invoke `node_api_key_for_url` and other helpers directly without
# the seeder mutating any state or calling out to staging.
if [ -n "${SEED_SYNTHETIC_NO_AUTO_RUN:-}" ]; then
  return 0 2>/dev/null || exit 0
fi

log "=== synthetic traffic seeder ==="
if [ "${DRY_RUN}" = "true" ]; then
  log "mode:     dry-run"
else
  log "mode:     execute"
fi
log "tenant:   ${TENANT_SELECTOR}"
log "duration: ${DURATION_MINUTES} min (if executing)"

if [ "${DRY_RUN}" != "true" ]; then
  preflight_env
fi

case "${TENANT_SELECTOR}" in
  A|B|C) run_tenant "${TENANT_SELECTOR}";;
  all)
    run_tenant A
    run_tenant B
    run_tenant C
    ;;
esac

log ""
log "=== done ==="
if [ "${DRY_RUN}" = "true" ]; then
  log "this was a dry run. Re-run with --execute --i-know-this-hits-staging to mutate staging."
  log "see docs/launch/synthetic_traffic_seeder_plan.md for the implementation gaps the follow-up session must close."
fi
