#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/algolia_import_catalog_live_probe.sh"
DEFAULT_INVENTORY="$REPO_ROOT/scripts/tests/fixtures/catalog_lifecycle_writers.json"
DEFAULT_ORACLE="$REPO_ROOT/scripts/tests/fixtures/catalog_lifecycle_acceptance_oracles.json"
ENV_VARS_DOC="$REPO_ROOT/docs/env-vars.md"

# shellcheck source=scripts/tests/lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=scripts/tests/lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

WORK_DIR=""
RUN_STDOUT=""
RUN_EXIT_CODE=0

cleanup() {
  if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

write_fake_command() {
  local path="$1"
  local body="$2"
  printf '%s\n' "$body" > "$path"
  chmod +x "$path"
}

copy_fixture() {
  local source="$1"
  local target="$2"
  local mutation="${3:-}"
  python3 - "$source" "$target" "$mutation" <<'PY'
import json
import sys

source, target, mutation = sys.argv[1:]
with open(source, encoding="utf-8") as handle:
    payload = json.load(handle)

if mutation == "zero_blocking_denominator":
    for row in payload["writers"]:
        if row.get("disposition") == "block_without_change":
            row["disposition"] = "privacy_transition"
            row["live_phase"] = "privacy_erasure"
elif mutation == "missing_caller_mapping":
    payload["writers"][0].pop("live_caller_key", None)
elif mutation == "missing_executable_caller_mapping":
    payload["writers"][0].pop("live_caller_command", None)
elif mutation == "duplicate_writer_id":
    payload["writers"][1]["id"] = payload["writers"][0]["id"]
elif mutation == "wrong_disposition":
    payload["writers"][0]["disposition"] = "unknown"
elif mutation == "stale_source_discovery":
    payload["writers"][0]["source_anchor"] = "catalog_lifecycle_probe_missing_source_anchor"
elif mutation == "shared_nested_scenario":
    catalog_rows = [
        row for row in payload["writers"] if row.get("live_phase") == "catalog"
    ]
    catalog_rows[1]["live_scenario_key"] = catalog_rows[0]["live_scenario_key"]
elif mutation == "unknown_catalog_scenario":
    catalog_row = next(row for row in payload["writers"] if row.get("live_phase") == "catalog")
    catalog_row["live_scenario_key"] = "scenario__probe_only_catalog_class_claim"

with open(target, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
}

copy_oracle() {
  local source="$1"
  local target="$2"
  local mutation="${3:-}"
  python3 - "$source" "$target" "$mutation" <<'PY'
import json
import sys

source, target, mutation = sys.argv[1:]
with open(source, encoding="utf-8") as handle:
    payload = json.load(handle)

if mutation == "altered_acceptance_oracle":
    payload["oracles"]["block_without_change"]["release_trigger"] = "timer_expiry"
elif mutation == "privacy_scrub_transport_unavailable":
    payload["privacy_erasure_dependencies"][0]["status"] = "action_required"
elif mutation == "privacy_scrub_worker_unavailable":
    payload["privacy_erasure_dependencies"][0]["status"] = "available"
    payload["privacy_erasure_dependencies"][1]["status"] = "action_required"
elif mutation == "privacy_boundary_control_unavailable":
    payload["privacy_erasure_dependencies"][0]["status"] = "available"
    payload["privacy_erasure_dependencies"][1]["status"] = "available"
    payload["privacy_erasure_dependencies"][2]["status"] = "action_required"

with open(target, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
}

setup_workspace() {
  cleanup
  WORK_DIR="$(mktemp -d)"
  mkdir -p "$WORK_DIR/bin" "$WORK_DIR/flapjack_dev/engine" "$WORK_DIR/runtime"
  : > "$WORK_DIR/curl.log"
  : > "$WORK_DIR/psql.log"
  : > "$WORK_DIR/up.log"
  : > "$WORK_DIR/down.log"
  : > "$WORK_DIR/contract_check.log"
  : > "$WORK_DIR/caller_runner.log"
  : > "$WORK_DIR/cargo.log"
  touch "$WORK_DIR/flapjack_dev/engine/Cargo.toml"
  printf '[package]\nname = "flapjack-server"\n' > "$WORK_DIR/flapjack_dev/engine/Cargo.toml"
  printf 'ALGOLIA_APP_ID=TESTAPP123\nALGOLIA_ADMIN_KEY=algolia-admin-secret\n' > "$WORK_DIR/secret.env"
  : > "$WORK_DIR/fjcloud-auth.conf"
  copy_fixture "$DEFAULT_INVENTORY" "$WORK_DIR/catalog_lifecycle_writers.json"
  copy_oracle "$DEFAULT_ORACLE" "$WORK_DIR/catalog_lifecycle_acceptance_oracles.json"

  write_fake_command "$WORK_DIR/up.sh" '#!/usr/bin/env bash
set -euo pipefail
printf "db=%s pid_dir=%s enabled=%s preserve=%s\n" "${INTEGRATION_DB:-}" "${FJCLOUD_INTEGRATION_PID_DIR:-}" "${FJCLOUD_ALGOLIA_MIGRATION_ENABLED:-}" "${FJCLOUD_INTEGRATION_PRESERVE_DB:-}" >> "$UP_LOG"
mkdir -p "$FJCLOUD_INTEGRATION_PID_DIR"
printf "123\n" > "$FJCLOUD_INTEGRATION_PID_DIR/api.pid"
printf "456\n" > "$FJCLOUD_INTEGRATION_PID_DIR/flapjack.pid"
'
  write_fake_command "$WORK_DIR/down.sh" '#!/usr/bin/env bash
set -euo pipefail
printf "db=%s pid_dir=%s\n" "${INTEGRATION_DB:-}" "${FJCLOUD_INTEGRATION_PID_DIR:-}" >> "$DOWN_LOG"
rm -f "$FJCLOUD_INTEGRATION_PID_DIR"/*.pid 2>/dev/null || true
rmdir "$FJCLOUD_INTEGRATION_PID_DIR" 2>/dev/null || true
'
  write_fake_command "$WORK_DIR/contract_check.sh" '#!/usr/bin/env bash
set -euo pipefail
printf "flapjack_dev_dir=%s args=%s\n" "${FLAPJACK_DEV_DIR:-}" "$*" >> "$CONTRACT_CHECK_LOG"
[ "${CONTRACT_CHECK_SCENARIO:-success}" = "missing_scrub" ] && exit 2
[ "${CONTRACT_CHECK_SCENARIO:-success}" = "missing_ack_route" ] && exit 3
exit 0
'
  write_fake_command "$WORK_DIR/caller_runner.sh" '#!/usr/bin/env bash
set -euo pipefail
inventory=""
phases=""
job_id=""
output=""
api_url=""
auth_config=""
admin_key=""
target_index=""
runtime_dir=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --inventory) inventory="$2"; shift 2 ;;
    --phases) phases="$2"; shift 2 ;;
    --job-id) job_id="$2"; shift 2 ;;
    --api-url) api_url="$2"; shift 2 ;;
    --auth-config) auth_config="$2"; shift 2 ;;
    --admin-key) admin_key="$2"; shift 2 ;;
    --target-index) target_index="$2"; shift 2 ;;
    --runtime-dir) runtime_dir="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    *) echo "unexpected caller runner argument: $1" >&2; exit 2 ;;
  esac
done
printf "inventory=%s phases=%s job_id=%s api_url=%s auth_config=%s admin_key_set=%s target_index=%s runtime_dir=%s output=%s\n" \
  "$inventory" "$phases" "$job_id" "$api_url" "$auth_config" "$([ -n "$admin_key" ] && printf yes || printf no)" "$target_index" "$runtime_dir" "$output" >> "$CALLER_RUNNER_LOG"
[ "${CALLER_RUNNER_SCENARIO:-success}" = "runner_failed" ] && {
  printf "ack_release_not_observed\n" >&2
  exit 1
}
[ "${CALLER_RUNNER_SCENARIO:-success}" = "live_caller_missing" ] && {
  printf "source_selection_not_live_called\n" >&2
  exit 1
}
python3 - "$inventory" "$phases" "$job_id" "$output" "${CALLER_RUNNER_SCENARIO:-success}" <<'"'"'PY'"'"'
import json
import sys

inventory_path, phases_csv, job_id, output_path, scenario = sys.argv[1:]
with open(inventory_path, encoding="utf-8") as handle:
    inventory = json.load(handle)
phases = set(phases_csv.split(","))
observations = []
for row in inventory["writers"]:
    phase = row["live_phase"]
    if phase not in phases:
        continue
    observations.append(
        {
            "writer_id": row["id"],
            "caller_key": row["live_caller_key"],
            "caller_command": row["live_caller_command"],
            "scenario_key": row["live_scenario_key"],
            "outcome": "refused" if phase == "catalog" else "retained",
        }
    )
scenario_ledger = sorted({item["scenario_key"] for item in observations})
catalog_scenarios = sorted(
    {
        item["scenario_key"]
        for item in observations
        if item["outcome"] == "refused"
    }
)
invariant_surfaces = ["catalog", "public_indexes", "quota", "routing"]
lifecycle_checks = [
    {
        "contract": "soft_delete_pre_promotion",
        "selection": (
            "algolia_import_catalog_finalize::soft_delete_boundaries::"
            "soft_delete_pre_promotion_retains_target_and_fences_ack"
        ),
    },
    {
        "contract": "soft_delete_cancelling",
        "selection": (
            "algolia_import_catalog_finalize::soft_delete_boundaries::"
            "soft_delete_cancelling_retains_target_and_fences_ack"
        ),
    },
    {
        "contract": "soft_delete_cancelled_before_ack",
        "selection": (
            "algolia_import_catalog_finalize::soft_delete_boundaries::"
            "soft_delete_cancelled_before_ack_retains_target_and_fences_ack"
        ),
    },
    {
        "contract": "soft_delete_terminal_failed",
        "selection": (
            "algolia_import_catalog_finalize::soft_delete_boundaries::"
            "soft_delete_terminal_failed_retains_target_and_fences_ack"
        ),
    },
    {
        "contract": "soft_delete_post_promotion",
        "selection": (
            "algolia_import_catalog_finalize::soft_delete_boundaries::"
            "soft_delete_post_promotion_retains_target_and_fences_ack"
        ),
    },
    {
        "contract": "hidden_while_deleted_authorization",
        "selection": (
            "catalog_lifecycle_leases::catalog_lifecycle_lease_invariants::"
            "soft_deleted_customer_snapshot_eligibility_refuses_while_target_retained"
        ),
    },
    {
        "contract": "ack_release_active_reservation_predicate",
        "selection": (
            "algolia_import_catalog_finalize::"
            "catalog_lifecycle_write_is_excluded_until_terminal_ack_releases_reservation"
        ),
    },
    {
        "contract": "deleted_reactivation_refused_400_no_mutation",
        "selection": (
            "admin_audit_view_test::"
            "post_admin_customers_reactivate_deleted_writes_no_audit_row"
        ),
    },
    {
        "contract": "suspended_reactivation_active_200",
        "selection": (
            "admin_audit_view_test::"
            "post_admin_customers_reactivate_writes_customer_reactivated_audit_row"
        ),
    },
]
executed_scenarios = set(scenario_ledger)
catalog_reservation_checks = [
    {
        "selection": observation["scenario_key"],
        "caller_key": observation["caller_key"],
        "checkpoint": checkpoint,
        "customer_id": "00000000-0000-4000-8000-000000000111",
        "target_index": "target",
        "reservation_state": "active",
    }
    for observation in observations
    if observation["outcome"] == "refused"
    for checkpoint in ["before", "after"]
]
lifecycle_reservation_checks = []
if "lifecycle_exclusion" in phases:
    lifecycle_selections = {
        observation["scenario_key"]
        for observation in observations
        if observation["outcome"] == "retained"
    }
    lifecycle_selections.update(check["selection"] for check in lifecycle_checks)
    executed_scenarios.update(lifecycle_selections)
    lifecycle_reservation_checks = [
        {
            "selection": selection,
            "caller_key": "",
            "checkpoint": checkpoint,
            "customer_id": "00000000-0000-4000-8000-000000000111",
            "target_index": "target",
            "reservation_state": "active",
        }
        for selection in sorted(lifecycle_selections)
        for checkpoint in ["before", "after"]
    ]
live_reservation_checks = catalog_reservation_checks + lifecycle_reservation_checks
evidence = {
    "version": 1,
    "job_id": job_id,
    "observations": observations,
    "scenario_ledger": scenario_ledger,
    "executed_scenarios": sorted(executed_scenarios),
    "job_state_ledger": [
        {
            "checkpoint": "before_writer_execution",
            "customer_id": "00000000-0000-4000-8000-000000000111",
            "target_index": "target",
            "reservation_state": "active",
            "status": "queued",
            "publication_disposition": "not_started",
            "engine_ack_state": "pending",
            "terminal_at": "absent",
            "dispatch_intent_state": "committed",
            "engine_job_id": "present",
        },
        {
            "checkpoint": "after_reconciliation",
            "customer_id": "00000000-0000-4000-8000-000000000111",
            "target_index": "target",
            "reservation_state": "released",
            "status": "completed",
            "publication_disposition": "promoted",
            "engine_ack_state": "acknowledged",
            "terminal_at": "present",
            "dispatch_intent_state": "committed",
            "engine_job_id": "present",
        },
    ],
    "live_reservation_checks": live_reservation_checks,
}
if "catalog" in phases:
    evidence["invariants"] = {
        "surfaces": invariant_surfaces,
        "production_scenarios": catalog_scenarios,
    }
    evidence["invariant_snapshots"] = [
        {
            "writer_id": observation["writer_id"],
            "caller_key": observation["caller_key"],
            "scenario_key": observation["scenario_key"],
            "surface": surface,
            "before_sha256": "0" * 64,
            "after_sha256": "0" * 64,
        }
        for observation in observations
        if observation["outcome"] == "refused"
        for surface in invariant_surfaces
    ]
if "lifecycle_exclusion" in phases:
    evidence["lifecycle"] = {"checks": lifecycle_checks}
if scenario == "missing_observation":
    evidence["observations"].pop(0)
elif scenario == "accepted_mutation":
    next(
        observation
        for observation in evidence["observations"]
        if observation["outcome"] == "refused"
    )["outcome"] = "accepted"
elif scenario == "duplicate_writer":
    evidence["observations"].append(dict(evidence["observations"][0]))
elif scenario == "wrong_caller_command":
    evidence["observations"][0]["caller_command"] = "invoke_probe_only_writer"
elif scenario == "repeated_scenario":
    evidence["scenario_ledger"].append(evidence["scenario_ledger"][0])
elif scenario == "invariant_drift":
    evidence["invariant_snapshots"][0]["after_sha256"] = "1" * 64
elif scenario == "missing_invariant_surfaces":
    evidence["invariant_snapshots"] = [
        snapshot
        for snapshot in evidence["invariant_snapshots"]
        if snapshot["surface"] != "quota"
    ]
elif scenario == "early_release":
    evidence["job_state_ledger"][0]["engine_ack_state"] = "acknowledged"
elif scenario == "unlinked_ack_ledger":
    for state in evidence["job_state_ledger"]:
        state["dispatch_intent_state"] = "ambiguous"
        state["engine_job_id"] = "absent"
elif scenario == "missing_live_reservation_checks":
    evidence["live_reservation_checks"].pop(0)
elif scenario == "broad_lifecycle_smoke":
    evidence["lifecycle"]["checks"] = [
        {
            "contract": "soft_delete_boundary_matrix",
            "selection": "algolia_import_catalog_finalize",
        },
        *[
            check
            for check in evidence["lifecycle"]["checks"]
            if check["contract"].endswith("reactivation_refused_400_no_mutation")
            or check["contract"].endswith("reactivation_active_200")
        ],
    ]
    evidence["executed_scenarios"] = sorted({
        *scenario_ledger,
        *(check["selection"] for check in evidence["lifecycle"]["checks"]),
    })
elif scenario == "missing_soft_delete_boundary":
    evidence["lifecycle"]["checks"] = [
        check
        for check in evidence["lifecycle"]["checks"]
        if check["contract"] != "soft_delete_cancelling"
    ]
elif scenario == "missing_hidden_authorization":
    evidence["lifecycle"]["checks"] = [
        check
        for check in evidence["lifecycle"]["checks"]
        if check["contract"] != "hidden_while_deleted_authorization"
    ]
elif scenario == "missing_ack_release_contract":
    evidence["lifecycle"]["checks"] = [
        check
        for check in evidence["lifecycle"]["checks"]
        if check["contract"] != "ack_release_active_reservation_predicate"
    ]
elif scenario == "deleted_reactivation_accepted":
    next(
        check
        for check in evidence["lifecycle"]["checks"]
        if check["contract"] == "deleted_reactivation_refused_400_no_mutation"
    )["selection"] = "admin_audit_view_test::post_admin_customers_reactivate"
elif scenario == "suspended_reactivation_refused":
    next(
        check
        for check in evidence["lifecycle"]["checks"]
        if check["contract"] == "suspended_reactivation_active_200"
    )["selection"] = "admin_audit_view_test::post_admin_customers_reactivate"
with open(output_path, "w", encoding="utf-8") as handle:
    json.dump(evidence, handle)
PY
'
  write_fake_command "$WORK_DIR/bin/psql" '#!/usr/bin/env bash
set -euo pipefail
printf "%s\n" "$*" >> "$PSQL_LOG"
case "$*" in
  *"probe:catalog_runner_job_state_before"*) printf "00000000-0000-4000-8000-000000000111|target|active|queued|not_started|pending|absent|committed|present\n" ;;
  *"probe:catalog_runner_job_state_after"*) printf "00000000-0000-4000-8000-000000000111|target|released|completed|promoted|acknowledged|present|committed|present\n" ;;
  *"probe:catalog_runner_active_reservation"*)
    count_file="$(dirname "$PSQL_LOG")/active-reservation-count"
    count="$(cat "$count_file" 2>/dev/null || printf 0)"
    count=$((count + 1))
    printf "%s\n" "$count" > "$count_file"
    if [ "${PSQL_SCENARIO:-success}" = "released_during_scenarios" ] && [ "$count" -gt 2 ]; then
      printf "00000000-0000-4000-8000-000000000111|target|released\n"
    else
      printf "00000000-0000-4000-8000-000000000111|target|active\n"
    fi ;;
  *"probe:catalog_live_reservation_active"*) printf "1\n" ;;
  *"probe:catalog_live_ack_release"*) printf "1\n" ;;
  *"probe:catalog_live_database_residue"*) printf "0\n" ;;
  *) printf "1\n" ;;
esac
'
  write_fake_command "$WORK_DIR/bin/cargo" '#!/usr/bin/env bash
set -euo pipefail
printf "%s\n" "$*" >> "$CARGO_LOG"
for variable_name in \
  ALGOLIA_IMPORT_CATALOG_LIVE_API_URL \
  ALGOLIA_IMPORT_CATALOG_LIVE_AUTH_CONFIG \
  ALGOLIA_IMPORT_CATALOG_LIVE_ADMIN_KEY \
  ALGOLIA_IMPORT_CATALOG_LIVE_SELECTION
do
  [ -n "${!variable_name:-}" ] || {
    printf "missing live source context: %s\n" "$variable_name" >&2
    exit 98
  }
done
printf "api_url=%s auth_config=%s admin_key_set=yes\n" \
  "$ALGOLIA_IMPORT_CATALOG_LIVE_API_URL" \
  "$ALGOLIA_IMPORT_CATALOG_LIVE_AUTH_CONFIG" \
  >> "${CARGO_CONTEXT_LOG:-/dev/null}"
selection=""
arguments=("$@")
for ((index = 0; index + 2 < ${#arguments[@]}; index++)); do
  if [ "${arguments[$index]}" = "--test" ]; then
    selection="${arguments[$((index + 2))]}"
    break
  fi
done
[ -z "${ALGOLIA_IMPORT_CATALOG_LIVE_CALLER_KEY:-}" ] || \
  printf "LIVE_CALLER|%s|%s\n" \
    "$ALGOLIA_IMPORT_CATALOG_LIVE_CALLER_KEY" "$selection" >> "$CARGO_LOG"
if [[ "$*" == *"admin_audit_view_test::delete_admin_tenants_id_writes_tenant_deleted_audit_row"* ]] \
  && [[ "$*" != *"--ignored"* ]]; then
  printf "test admin_audit_view_test::delete_admin_tenants_id_writes_tenant_deleted_audit_row ... ignored, requires DATABASE_URL\n"
  printf "test result: ok. 0 passed; 0 failed; 1 ignored; 0 measured; 1559 filtered out\n"
  exit 0
fi
if [ "${CARGO_SCENARIO:-success}" != "missing_live_binding" ]; then
  printf "CATALOG_LIVE_BINDING|selection=%s|job_id=%s|customer_id=%s|target_index=%s\n" \
    "$selection" "$ALGOLIA_IMPORT_CATALOG_LIVE_JOB_ID" \
    "$ALGOLIA_IMPORT_CATALOG_LIVE_CUSTOMER_ID" \
    "$ALGOLIA_IMPORT_CATALOG_LIVE_TARGET_INDEX"
fi
if [ "${CARGO_SCENARIO:-success}" != "missing_live_caller" ]; then
  printf "CATALOG_LIVE_CALLER|caller_key=%s|selection=%s|job_id=%s|customer_id=%s|target_index=%s|outcome=refused\n" \
    "${ALGOLIA_IMPORT_CATALOG_LIVE_CALLER_KEY:-}" \
    "$selection" "$ALGOLIA_IMPORT_CATALOG_LIVE_JOB_ID" \
    "$ALGOLIA_IMPORT_CATALOG_LIVE_CUSTOMER_ID" \
    "$ALGOLIA_IMPORT_CATALOG_LIVE_TARGET_INDEX"
fi
printf "test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 1559 filtered out\n"
'
  write_fake_command "$WORK_DIR/bin/curl" '#!/usr/bin/env bash
set -euo pipefail
printf "%s\n" "$*" >> "$CURL_LOG"
method="GET"
data_file=""
url=""
header_dump_file=""
idempotency_key=""
config_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X|--request) method="$2"; shift 2 ;;
    --data|-d|--data-binary) data_file="${2#@}"; shift 2 ;;
    -D) header_dump_file="$2"; shift 2 ;;
    --config|-K) config_file="$2"; shift 2 ;;
    -H|--header)
      case "$2" in
        [Ii]dempotency-[Kk]ey:*) idempotency_key="${2#*: }" ;;
      esac
      shift 2 ;;
    --connect-timeout|--max-time|-w) shift 2 ;;
    -s|-S|-sS|-f|-L) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$method $url" in
  "GET http://127.0.0.1:3099/health"|"GET http://127.0.0.1:7799/health")
    printf "{\"status\":\"ok\"}\n200" ;;
  "GET https://testapp123.algolia.net/1/indexes?page=0&hitsPerPage=100")
    if [ "${ALGOLIA_INDEX_RESIDUE_SCENARIO:-}" = "retained_owned_index" ]; then
      printf "{\"items\":[{\"name\":\"fjcloud_import_catalog_probe_test_retained\"}]}\n200"
    elif [ "${ALGOLIA_DELETE_TASK:-0}" = "1" ] && [ ! -f "$WORK_DIR/delete-task-published" ]; then
      printf "{\"items\":[{\"name\":\"fjcloud_import_catalog_probe_test_source\"}]}\n200"
    else
      printf "{\"items\":[]}\n200"
    fi ;;
  "POST https://testapp123.algolia.net/1/indexes/"*"/batch")
    touch "$WORK_DIR/source-index-created"
    if [ "${CURL_SCENARIO:-success}" = "unsafe_task_identifier" ]; then
      printf "{\"taskID\":\"unsafe/task\"}\n200"
    else
      printf "{\"taskID\":1}\n200"
    fi ;;
  "GET https://testapp123.algolia.net/1/indexes/"*"/task/1")
    printf "{\"status\":\"published\"}\n200" ;;
  "GET https://testapp123.algolia.net/1/indexes/"*"/task/2")
    touch "$WORK_DIR/delete-task-published"
    printf "{\"status\":\"published\"}\n200" ;;
  "GET https://testapp123.algolia.net/1/indexes/"*)
    if [ -f "$WORK_DIR/source-index-created" ] \
      && [ -n "$config_file" ] \
      && grep -q "disposable-restricted-key" "$config_file"; then
      touch "$WORK_DIR/restricted-key-readiness-observed"
      printf "{\"name\":\"source\"}\n200"
    else
      printf "{\"message\":\"not found\"}\n404"
    fi ;;
  "POST https://testapp123.algolia.net/1/keys")
    printf "{\"key\":\"disposable-restricted-key\"}\n201" ;;
  "DELETE https://testapp123.algolia.net/1/keys/disposable-restricted-key")
    printf "{}\n200" ;;
  "GET https://testapp123.algolia.net/1/keys/disposable-restricted-key")
    printf "{\"message\":\"key not found\"}\n404" ;;
  "DELETE https://testapp123.algolia.net/1/indexes/"*)
    if [ "${ALGOLIA_DELETE_TASK:-0}" = "1" ]; then
      printf "{\"taskID\":2}\n200"
    else
      printf "{}\n200"
    fi ;;
  "POST http://127.0.0.1:3099/auth/register")
    customer_id="00000000-0000-4000-8000-000000000111"
    if [ -n "$data_file" ] && grep -q "soft-delete-admin" "$data_file"; then
      customer_id="00000000-0000-4000-8000-000000000222"
    elif [ -n "$data_file" ] && grep -q "suspended-control" "$data_file"; then
      customer_id="00000000-0000-4000-8000-000000000333"
    fi
    printf "{\"token\":\"register-token\",\"customer_id\":\"%s\"}\n201" "$customer_id" ;;
  "POST http://127.0.0.1:3099/auth/login")
    printf "{\"token\":\"tenant-token\",\"customer_id\":\"00000000-0000-4000-8000-000000000111\"}\n200" ;;
  "POST http://127.0.0.1:3099/indexes")
    if [ -n "$data_file" ] && grep -q "target" "$data_file"; then
      printf "{\"error\":\"active lifecycle operation\"}\n409"
    else
      printf "{\"name\":\"warmup\",\"region\":\"us-east-1\"}\n201"
    fi ;;
  "DELETE http://127.0.0.1:3099/indexes/"*)
    printf "\n204" ;;
  "POST http://127.0.0.1:3099/migration/algolia/destination-eligibility")
    if [ "${CURL_SCENARIO:-success}" = "eligibility_down" ]; then
      printf "{\"error\":\"backend unavailable\"}\n503"
    elif [ -n "$data_file" ] && grep -q "\"phase\":\"provider\"" "$data_file"; then
      printf "eligibility_phase=provider\n" >> "$CURL_LOG"
      printf "{\"phase\":\"provider\",\"mode\":\"create\",\"provider\":\"aws\",\"target\":{\"kind\":\"create\",\"region\":\"us-east-1\",\"name\":\"target\"},\"eligibilityToken\":\"provider-token\",\"expiresAt\":\"2026-07-22T00:00:00Z\"}\n200"
    elif [ -n "$data_file" ] \
      && grep -q "\"phase\":\"target\"" "$data_file" \
      && grep -q "\"eligibilityToken\":\"provider-token\"" "$data_file"; then
      printf "eligibility_phase=target\n" >> "$CURL_LOG"
      printf "{\"phase\":\"target\",\"mode\":\"create\",\"provider\":\"aws\",\"target\":{\"kind\":\"create\",\"region\":\"us-east-1\",\"name\":\"target\"},\"eligibilityToken\":\"target-token\",\"expiresAt\":\"2026-07-22T00:00:00Z\"}\n200"
    else
      printf "{\"error\":\"eligibility_token_required\"}\n400"
    fi ;;
  "POST http://127.0.0.1:3099/migration/algolia/jobs")
    if [ "${CURL_SCENARIO:-success}" = "restricted_key_requires_readiness" ] \
      && [ ! -f "$WORK_DIR/restricted-key-readiness-observed" ]; then
      printf "{\"error\":\"source credential not ready\"}\n403"
      exit 0
    fi
    if [ "$idempotency_key" = "fjcloud_import_catalog_probe_test_dispatch" ]; then
      printf "{\"id\":\"job-123\",\"status\":\"running\"}\n202"
    else
      printf "{\"error\":\"idempotency_key_required\"}\n400"
    fi ;;
  "GET http://127.0.0.1:3099/migration/algolia/jobs/job-123")
    printf "{\"id\":\"job-123\",\"status\":\"running\"}\n200" ;;
  "DELETE http://127.0.0.1:3099/account")
    printf "\n204" ;;
  "DELETE http://127.0.0.1:3099/admin/tenants/"*)
    printf "\n204" ;;
  "GET http://127.0.0.1:3099/indexes/"*"soft-delete"*)
    printf "{\"error\":\"not found\"}\n404" ;;
  "GET http://127.0.0.1:3099/indexes"*)
    printf "{\"indexes\":[]}\n200" ;;
  "POST http://127.0.0.1:3099/admin/customers/00000000-0000-4000-8000-000000000222/reactivate")
    printf "{\"error\":\"customer is not suspended\"}\n400" ;;
  "POST http://127.0.0.1:3099/admin/customers/00000000-0000-4000-8000-000000000333/reactivate")
    printf "{\"message\":\"customer reactivated\"}\n200" ;;
  "POST http://127.0.0.1:3099/admin/customers/"*"/suspend")
    printf "{\"message\":\"customer suspended\"}\n200" ;;
  *)
    echo "unexpected curl call: $method $url" >&2
    exit 1 ;;
esac
'
}

run_probe() {
  RUN_EXIT_CODE=0
  RUN_STDOUT="$(
    PATH="$WORK_DIR/bin:$PATH" \
    WORK_DIR="$WORK_DIR" \
    CURL_LOG="$WORK_DIR/curl.log" \
    PSQL_LOG="$WORK_DIR/psql.log" \
    UP_LOG="$WORK_DIR/up.log" \
    DOWN_LOG="$WORK_DIR/down.log" \
    CONTRACT_CHECK_LOG="$WORK_DIR/contract_check.log" \
    CALLER_RUNNER_LOG="$WORK_DIR/caller_runner.log" \
    FJCLOUD_SECRET_FILE="$WORK_DIR/secret.env" \
    FLAPJACK_DEV_DIR="$WORK_DIR/flapjack_dev" \
    ALGOLIA_IMPORT_CATALOG_ENGINE_CONTRACT_CHECK="$WORK_DIR/contract_check.sh" \
    ALGOLIA_IMPORT_CATALOG_CALLER_RUNNER="${CALLER_RUNNER_PATH:-$WORK_DIR/caller_runner.sh}" \
    ALGOLIA_IMPORT_CATALOG_INTEGRATION_UP="$WORK_DIR/up.sh" \
    ALGOLIA_IMPORT_CATALOG_INTEGRATION_DOWN="$WORK_DIR/down.sh" \
    ALGOLIA_IMPORT_CATALOG_RUN_ID="test" \
    ALGOLIA_IMPORT_CATALOG_RUNTIME_PARENT="$WORK_DIR/runtime" \
    ALGOLIA_IMPORT_CATALOG_API_URL="http://127.0.0.1:3099" \
    ALGOLIA_IMPORT_CATALOG_ENGINE_URL="http://127.0.0.1:7799" \
    ALGOLIA_IMPORT_CATALOG_INVENTORY="${INVENTORY_PATH:-$WORK_DIR/catalog_lifecycle_writers.json}" \
    ALGOLIA_IMPORT_CATALOG_ORACLE="${ORACLE_PATH:-$WORK_DIR/catalog_lifecycle_acceptance_oracles.json}" \
    bash "$TARGET_SCRIPT" "$@" 2>&1
  )" || RUN_EXIT_CODE=$?
}

test_success_emits_noninflated_catalog_and_lifecycle_evidence() {
  setup_workspace
  run_probe --phases catalog,lifecycle_exclusion

  assert_eq "$RUN_EXIT_CODE" "0" "mocked catalog and lifecycle run should pass"
  assert_contains "$RUN_STDOUT" "PHASE|name=catalog|expected=block_without_change:41|observed=refused:41|pass=true" \
    "catalog phase emits exact blocking denominator"
  assert_contains "$RUN_STDOUT" "PHASE|name=lifecycle_exclusion|expected=privacy_transition_soft_delete:3|observed=retained:3|pass=true" \
    "lifecycle phase emits exact soft-delete denominator"
  assert_contains "$RUN_STDOUT" "EVIDENCE|inventory_total=48|block_without_change=41|soft_delete=3|hard_delete=4|duplicate_writer_ids=0" \
    "fixture denominator evidence is structured and nonzero"
  assert_contains "$RUN_STDOUT" "EVIDENCE|ack_release=active_reservation_predicate|job_id=job-123" \
    "ACK release evidence names the canonical predicate"
  assert_contains "$RUN_STDOUT" "EVIDENCE|invariants=catalog,quota,routing,public_indexes|unchanged=true" \
    "catalog phase proves normalized pre/post invariants"
  assert_contains "$RUN_STDOUT" "EVIDENCE|invariant_snapshots=surfaces:catalog,public_indexes,quota,routing|per_catalog_writer=true" \
    "catalog phase derives invariant claims from per-writer surface snapshots"
  assert_contains "$RUN_STDOUT" "EVIDENCE|soft_delete_boundaries=5|deleted_reactivation=refused_400_no_mutation|suspended_reactivation=active_200" \
    "lifecycle phase proves reversible policy boundaries and controls"
  assert_contains "$RUN_STDOUT" "CLEANUP|algolia_indexes=0|algolia_keys=0|local_stack=0|runtime_files=0" \
    "cleanup reports zero residue"
  assert_contains "$RUN_STDOUT" "RESULT|status=PASS|phases=catalog,lifecycle_exclusion" \
    "success result marker"
  assert_not_contains "$RUN_STDOUT" "algolia-admin-secret" "probe output redacts Algolia admin key"
  assert_contains "$(cat "$WORK_DIR/up.log")" "enabled=true" "integration stack starts with migration enabled"
  assert_contains "$(cat "$WORK_DIR/contract_check.log")" "args=--check" \
    "probe delegates source-built engine contract validation"
  assert_contains "$(cat "$WORK_DIR/caller_runner.log")" "phases=catalog,lifecycle_exclusion job_id=job-123" \
    "probe delegates writer execution to the source-built caller runner"
  assert_contains "$(cat "$WORK_DIR/caller_runner.log")" "api_url=http://127.0.0.1:3099" \
    "probe passes the API URL to the source-built caller runner"
  assert_contains "$(cat "$WORK_DIR/caller_runner.log")" "auth_config=" \
    "probe passes tenant auth config to the source-built caller runner"
  assert_contains "$(cat "$WORK_DIR/caller_runner.log")" "admin_key_set=yes" \
    "probe passes local admin auth to the source-built caller runner"
  assert_contains "$(cat "$WORK_DIR/caller_runner.log")" "target_index=fjcloud_import_catalog_probe_test_target" \
    "probe passes the reserved target index to the source-built caller runner"
  assert_not_contains "$(cat "$WORK_DIR/curl.log")" "catalog-lifecycle-callers" \
    "probe never calls a probe-only HTTP endpoint"
  assert_eq "$(
    grep '^eligibility_phase=' "$WORK_DIR/curl.log" | paste -sd ',' -
  )" "eligibility_phase=provider,eligibility_phase=target" \
    "probe follows the canonical provider-then-target eligibility exchange"
  assert_contains "$(cat "$WORK_DIR/curl.log")" \
    "Idempotency-Key: fjcloud_import_catalog_probe_test_dispatch" \
    "probe supplies a stable per-run idempotency key when creating the import job"
}

test_default_runner_produces_validated_source_built_evidence() {
  setup_workspace
  local output="$WORK_DIR/default_runner_evidence.json"

  PATH="$WORK_DIR/bin:$PATH" \
    CURL_LOG="$WORK_DIR/curl.log" \
    PSQL_LOG="$WORK_DIR/psql.log" \
    CARGO_LOG="$WORK_DIR/cargo.log" \
    CARGO_CONTEXT_LOG="$WORK_DIR/cargo-context.log" \
    DATABASE_URL="postgres://catalog-probe.invalid/fjcloud" \
    ALGOLIA_IMPORT_CATALOG_STATE_POLL_ATTEMPTS=2 \
    ALGOLIA_IMPORT_CATALOG_STATE_POLL_SECONDS=0 \
    bash "$REPO_ROOT/scripts/algolia_import_catalog_caller_runner.sh" \
    --inventory "$WORK_DIR/catalog_lifecycle_writers.json" \
    --phases catalog,lifecycle_exclusion \
    --job-id job-123 \
    --api-url "http://127.0.0.1:3099" \
    --auth-config "$WORK_DIR/fjcloud-auth.conf" \
    --admin-key "local-admin-key" \
    --target-index "target" \
    --runtime-dir "$WORK_DIR/runtime" \
    --output "$output"

  python3 "$REPO_ROOT/scripts/lib/algolia_import_catalog_evidence.py" \
    --inventory "$WORK_DIR/catalog_lifecycle_writers.json" \
    --evidence "$output" \
    --phases catalog,lifecycle_exclusion \
    --job-id job-123 >/dev/null

  if python3 - "$WORK_DIR/catalog_lifecycle_writers.json" "$output" <<'PY'
import json
import sys

inventory_path, evidence_path = sys.argv[1:]
with open(inventory_path, encoding="utf-8") as handle:
    inventory = json.load(handle)
with open(evidence_path, encoding="utf-8") as handle:
    evidence = json.load(handle)
expected_writers = {
    row["id"]
    for row in inventory["writers"]
    if row["live_phase"] == "catalog"
}
expected_surfaces = {"catalog", "quota", "routing", "public_indexes"}
snapshots = evidence.get("invariant_snapshots")
if not isinstance(snapshots, list):
    raise SystemExit("missing invariant snapshots")
observed = {
    (snapshot.get("writer_id"), snapshot.get("surface"))
    for snapshot in snapshots
}
expected = {
    (writer_id, surface)
    for writer_id in expected_writers
    for surface in expected_surfaces
}
if observed != expected:
    raise SystemExit(f"invariant snapshot drift: missing={expected - observed}, unexpected={observed - expected}")
if any(snapshot.get("before_sha256") != snapshot.get("after_sha256") for snapshot in snapshots):
    raise SystemExit("invariant snapshot changed")
PY
  then
    pass "default runner records unchanged catalog/quota/routing/public-index snapshots per catalog scenario"
  else
    fail "default runner records unchanged catalog/quota/routing/public-index snapshots per catalog scenario"
  fi

  assert_not_contains "$(cat "$WORK_DIR/curl.log")" \
    "POST http://127.0.0.1:3099/indexes" \
    "default runner must not reuse one generic catalog mutation for every writer"
  assert_contains "$(cat "$WORK_DIR/cargo.log")" \
    "delete_index_reservation_races_after_intent_before_finalization" \
    "default runner executes the production delete writer family"
  assert_contains "$(cat "$WORK_DIR/cargo.log")" \
    "auth_admin admin_audit_view_test::delete_admin_tenants_id_writes_tenant_deleted_audit_row" \
    "default runner resolves production selections through the generated auth_admin test root"
  assert_contains "$(cat "$WORK_DIR/cargo.log")" \
    "create_index_on_shared_vm_reservation_races_after_intent_before_remote_work" \
    "default runner executes the production create/shared-VM writer family"
  assert_contains "$(cat "$WORK_DIR/cargo.log")" \
    "create_index_on_shared_vm_reservation_races_after_intent_before_remote_work -- --test-threads=1 --nocapture --exact" \
    "default runner executes only the canonical source-built scenario body"
  assert_contains "$(cat "$WORK_DIR/cargo-context.log")" \
    "api_url=http://127.0.0.1:3099 auth_config=$WORK_DIR/fjcloud-auth.conf admin_key_set=yes" \
    "default runner passes live API and authentication context into every source selection"
  assert_not_contains "$(cat "$WORK_DIR/cargo.log")" \
    "platform catalog_lifecycle_leases::catalog_lifecycle_lease_remote_races::admin_seed_create_races_after_intent_before_remote_secret_work -- --test-threads=1 --nocapture --exact --ignored" \
    "default runner executes normal production selections without filtering them out"
  assert_contains "$(cat "$WORK_DIR/cargo.log")" \
    "auth_admin admin_audit_view_test::delete_admin_tenants_id_writes_tenant_deleted_audit_row -- --test-threads=1 --nocapture --exact --ignored" \
    "default runner retries generated-root ignored DB selections explicitly"
  if python3 - "$WORK_DIR/catalog_lifecycle_writers.json" "$WORK_DIR/cargo.log" <<'PY'
import json
import sys

inventory_path, cargo_log_path = sys.argv[1:]
with open(inventory_path, encoding="utf-8") as handle:
    inventory = json.load(handle)
expected = {
    row["live_scenario_key"]
    for row in inventory["writers"]
    if row["live_phase"] in {"catalog", "lifecycle_exclusion"}
}
expected.update(
    {
        (
            "algolia_import_catalog_finalize::soft_delete_boundaries::"
            "soft_delete_pre_promotion_retains_target_and_fences_ack"
        ),
        (
            "algolia_import_catalog_finalize::soft_delete_boundaries::"
            "soft_delete_cancelling_retains_target_and_fences_ack"
        ),
        (
            "algolia_import_catalog_finalize::soft_delete_boundaries::"
            "soft_delete_cancelled_before_ack_retains_target_and_fences_ack"
        ),
        (
            "algolia_import_catalog_finalize::soft_delete_boundaries::"
            "soft_delete_terminal_failed_retains_target_and_fences_ack"
        ),
        (
            "algolia_import_catalog_finalize::soft_delete_boundaries::"
            "soft_delete_post_promotion_retains_target_and_fences_ack"
        ),
        (
            "catalog_lifecycle_leases::catalog_lifecycle_lease_invariants::"
            "soft_deleted_customer_snapshot_eligibility_refuses_while_target_retained"
        ),
        (
            "algolia_import_catalog_finalize::"
            "catalog_lifecycle_write_is_excluded_until_terminal_ack_releases_reservation"
        ),
        (
            "admin_audit_view_test::"
            "post_admin_customers_reactivate_deleted_writes_no_audit_row"
        ),
        (
            "admin_audit_view_test::"
            "post_admin_customers_reactivate_writes_customer_reactivated_audit_row"
        ),
    }
)
observed = set()
with open(cargo_log_path, encoding="utf-8") as handle:
    for line in handle:
        arguments = line.split()
        if "--test" not in arguments:
            continue
        test_target_index = arguments.index("--test")
        observed.add(arguments[test_target_index + 2])
if observed != expected:
    raise SystemExit(
        f"production caller selections drifted: missing={expected - observed}, "
        f"unexpected={observed - expected}"
    )
PY
  then
    pass "default runner executes every canonical production scenario exactly once"
  else
    fail "default runner executes every canonical production scenario exactly once"
  fi
  assert_contains "$(cat "$WORK_DIR/psql.log")" \
    "probe:catalog_runner_job_state_before" \
    "default runner observes the held import before writer execution"
  assert_contains "$(cat "$WORK_DIR/psql.log")" \
    "probe:catalog_runner_job_state_after" \
    "default runner observes terminal finalization and ACK"
  if python3 - "$WORK_DIR/catalog_lifecycle_writers.json" "$WORK_DIR/psql.log" <<'PY'
import json
import pathlib
import sys

inventory_path, psql_log_path = sys.argv[1:]
with open(inventory_path, encoding="utf-8") as handle:
    inventory = json.load(handle)
expected = {
    (row["live_scenario_key"], row["live_caller_key"])
    for row in inventory["writers"]
    if row["live_phase"] == "catalog"
}
expected.update(
    {
        (row["live_scenario_key"], "scenario")
        for row in inventory["writers"]
        if row["live_phase"] == "lifecycle_exclusion"
    }
)
expected.update(
    {
        ((
            "algolia_import_catalog_finalize::soft_delete_boundaries::"
            "soft_delete_pre_promotion_retains_target_and_fences_ack"
        ), "scenario"),
        ((
            "algolia_import_catalog_finalize::soft_delete_boundaries::"
            "soft_delete_cancelling_retains_target_and_fences_ack"
        ), "scenario"),
        ((
            "algolia_import_catalog_finalize::soft_delete_boundaries::"
            "soft_delete_cancelled_before_ack_retains_target_and_fences_ack"
        ), "scenario"),
        ((
            "algolia_import_catalog_finalize::soft_delete_boundaries::"
            "soft_delete_terminal_failed_retains_target_and_fences_ack"
        ), "scenario"),
        ((
            "algolia_import_catalog_finalize::soft_delete_boundaries::"
            "soft_delete_post_promotion_retains_target_and_fences_ack"
        ), "scenario"),
        ((
            "catalog_lifecycle_leases::catalog_lifecycle_lease_invariants::"
            "soft_deleted_customer_snapshot_eligibility_refuses_while_target_retained"
        ), "scenario"),
        ((
            "algolia_import_catalog_finalize::"
            "catalog_lifecycle_write_is_excluded_until_terminal_ack_releases_reservation"
        ), "scenario"),
        ((
            "admin_audit_view_test::"
            "post_admin_customers_reactivate_deleted_writes_no_audit_row"
        ), "scenario"),
        ((
            "admin_audit_view_test::"
            "post_admin_customers_reactivate_writes_customer_reactivated_audit_row"
        ), "scenario"),
    }
)
log = pathlib.Path(psql_log_path).read_text(encoding="utf-8")
missing = [
    (selection, caller_key)
    for selection, caller_key in expected
    if f"probe:catalog_runner_active_reservation_before:{selection}:{caller_key}" not in log
    or f"probe:catalog_runner_active_reservation_after:{selection}:{caller_key}" not in log
]
if missing:
    raise SystemExit(f"missing active reservation checks: {missing[:5]}")
PY
  then
    pass "default runner proves the live job reservation is active around every source-built selection"
  else
    fail "default runner proves the live job reservation is active around every source-built selection"
  fi
  assert_not_contains "$(cat "$WORK_DIR/psql.log")" \
    ":'job_id'" \
    "default runner uses psql -c syntax that live psql can execute"
  assert_not_contains "$(cat "$WORK_DIR/cargo.log")" \
    "--test platform algolia_import_catalog_finalize --" \
    "default runner cannot substitute one broad module smoke run for exact lifecycle contracts"
  if python3 - "$WORK_DIR/catalog_lifecycle_writers.json" "$WORK_DIR/cargo.log" <<'PY'
import json
import pathlib
import sys

inventory = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
expected = sorted(
    (row["live_caller_key"], row["live_scenario_key"])
    for row in inventory["writers"]
    if row["live_phase"] == "catalog"
)
observed = sorted(
    tuple(line.split("|", 2)[1:])
    for line in pathlib.Path(sys.argv[2]).read_text(encoding="utf-8").splitlines()
    if line.startswith("LIVE_CALLER|")
)
if observed != expected:
    raise SystemExit(
        f"live caller executions do not match writer inventory: "
        f"expected={len(expected)} observed={len(observed)}"
    )
PY
  then
    pass "default runner executes every fixture-owned catalog caller against the live target"
  else
    fail "default runner executes every fixture-owned catalog caller against the live target"
  fi
}

test_default_runner_rejects_released_live_job_during_scenario_execution() {
  setup_workspace
  local output="$WORK_DIR/default_runner_evidence.json"

  RUN_EXIT_CODE=0
  RUN_STDOUT="$(
    PATH="$WORK_DIR/bin:$PATH" \
    CURL_LOG="$WORK_DIR/curl.log" \
    PSQL_LOG="$WORK_DIR/psql.log" \
    CARGO_LOG="$WORK_DIR/cargo.log" \
    DATABASE_URL="postgres://catalog-probe.invalid/fjcloud" \
    PSQL_SCENARIO=released_during_scenarios \
    ALGOLIA_IMPORT_CATALOG_STATE_POLL_ATTEMPTS=2 \
    ALGOLIA_IMPORT_CATALOG_STATE_POLL_SECONDS=0 \
    bash "$REPO_ROOT/scripts/algolia_import_catalog_caller_runner.sh" \
    --inventory "$WORK_DIR/catalog_lifecycle_writers.json" \
    --phases catalog,lifecycle_exclusion \
    --job-id job-123 \
    --api-url "http://127.0.0.1:3099" \
    --auth-config "$WORK_DIR/fjcloud-auth.conf" \
    --admin-key "local-admin-key" \
    --target-index "target" \
    --runtime-dir "$WORK_DIR/runtime" \
    --output "$output" 2>&1
  )" || RUN_EXIT_CODE=$?

  assert_eq "$RUN_EXIT_CODE" "1" \
    "default runner must fail if the live job releases before all caller observations are recorded"
  assert_contains "$RUN_STDOUT" "active_reservation_not_observed" \
    "released live job emits a stable runner reason"
}

test_default_runner_rejects_isolated_source_selection() {
  setup_workspace
  local output="$WORK_DIR/default_runner_evidence.json"

  RUN_EXIT_CODE=0
  RUN_STDOUT="$(
    PATH="$WORK_DIR/bin:$PATH" \
    CURL_LOG="$WORK_DIR/curl.log" \
    PSQL_LOG="$WORK_DIR/psql.log" \
    CARGO_LOG="$WORK_DIR/cargo.log" \
    CARGO_SCENARIO=missing_live_binding \
    DATABASE_URL="postgres://catalog-probe.invalid/fjcloud" \
    ALGOLIA_IMPORT_CATALOG_STATE_POLL_ATTEMPTS=2 \
    ALGOLIA_IMPORT_CATALOG_STATE_POLL_SECONDS=0 \
    bash "$REPO_ROOT/scripts/algolia_import_catalog_caller_runner.sh" \
    --inventory "$WORK_DIR/catalog_lifecycle_writers.json" \
    --phases catalog,lifecycle_exclusion \
    --job-id job-123 \
    --api-url "http://127.0.0.1:3099" \
    --auth-config "$WORK_DIR/fjcloud-auth.conf" \
    --admin-key "local-admin-key" \
    --target-index "target" \
    --runtime-dir "$WORK_DIR/runtime" \
    --output "$output" 2>&1
  )" || RUN_EXIT_CODE=$?

  assert_eq "$RUN_EXIT_CODE" "1" \
    "default runner must reject a successful source selection that did not bind its caller to the live job"
  assert_contains "$RUN_STDOUT" "source_selection_not_live_bound" \
    "isolated source selection emits a stable runner reason"
}

test_default_runner_rejects_temporal_binding_without_live_caller() {
  setup_workspace
  local output="$WORK_DIR/default_runner_evidence.json"

  RUN_EXIT_CODE=0
  RUN_STDOUT="$(
    PATH="$WORK_DIR/bin:$PATH" \
    CURL_LOG="$WORK_DIR/curl.log" \
    PSQL_LOG="$WORK_DIR/psql.log" \
    CARGO_LOG="$WORK_DIR/cargo.log" \
    CARGO_SCENARIO=missing_live_caller \
    DATABASE_URL="postgres://catalog-probe.invalid/fjcloud" \
    ALGOLIA_IMPORT_CATALOG_STATE_POLL_ATTEMPTS=2 \
    ALGOLIA_IMPORT_CATALOG_STATE_POLL_SECONDS=0 \
    bash "$REPO_ROOT/scripts/algolia_import_catalog_caller_runner.sh" \
    --inventory "$WORK_DIR/catalog_lifecycle_writers.json" \
    --phases catalog,lifecycle_exclusion \
    --job-id job-123 \
    --api-url "http://127.0.0.1:3099" \
    --auth-config "$WORK_DIR/fjcloud-auth.conf" \
    --admin-key "local-admin-key" \
    --target-index "target" \
    --runtime-dir "$WORK_DIR/runtime" \
    --output "$output" 2>&1
  )" || RUN_EXIT_CODE=$?

  assert_eq "$RUN_EXIT_CODE" "1" \
    "temporal reservation binding must not substitute for a caller operating on the live target"
  assert_contains "$RUN_STDOUT" "source_selection_not_live_called" \
    "missing live caller evidence emits a stable runner reason"
}

test_default_runner_rejects_unobserved_terminal_ack() {
  setup_workspace
  local output="$WORK_DIR/default_runner_evidence.json"
  write_fake_command "$WORK_DIR/bin/psql" '#!/usr/bin/env bash
set -euo pipefail
printf "%s\n" "$*" >> "$PSQL_LOG"
case "$*" in
  *"probe:catalog_runner_job_state_before"*) printf "00000000-0000-4000-8000-000000000111|target|active|queued|not_started|pending|absent|committed|present\n" ;;
  *"probe:catalog_runner_job_state_after"*) printf "00000000-0000-4000-8000-000000000111|target|active|queued|not_started|pending|absent|committed|present\n" ;;
  *"probe:catalog_runner_active_reservation"*) printf "00000000-0000-4000-8000-000000000111|target|active\n" ;;
  *) printf "1\n" ;;
esac
'

  RUN_EXIT_CODE=0
  RUN_STDOUT="$(
    PATH="$WORK_DIR/bin:$PATH" \
    CURL_LOG="$WORK_DIR/curl.log" \
    PSQL_LOG="$WORK_DIR/psql.log" \
    CARGO_LOG="$WORK_DIR/cargo.log" \
    DATABASE_URL="postgres://catalog-probe.invalid/fjcloud" \
    ALGOLIA_IMPORT_CATALOG_STATE_POLL_ATTEMPTS=2 \
    ALGOLIA_IMPORT_CATALOG_STATE_POLL_SECONDS=0 \
    bash "$REPO_ROOT/scripts/algolia_import_catalog_caller_runner.sh" \
    --inventory "$WORK_DIR/catalog_lifecycle_writers.json" \
    --phases catalog,lifecycle_exclusion \
    --job-id job-123 \
    --api-url "http://127.0.0.1:3099" \
    --auth-config "$WORK_DIR/fjcloud-auth.conf" \
    --admin-key "local-admin-key" \
    --target-index "target" \
    --runtime-dir "$WORK_DIR/runtime" \
    --output "$output" 2>&1
  )" || RUN_EXIT_CODE=$?

  assert_eq "$RUN_EXIT_CODE" "1" \
    "default runner must fail when production reconciliation never reaches terminal ACK"
  assert_contains "$RUN_STDOUT" "ack_terminal_state_not_observed" \
    "unobserved terminal ACK emits a checkpoint-specific stable runner reason"
}

test_default_runner_rejects_unheld_initial_job() {
  setup_workspace
  local output="$WORK_DIR/default_runner_evidence.json"
  write_fake_command "$WORK_DIR/bin/psql" '#!/usr/bin/env bash
set -euo pipefail
printf "%s\n" "$*" >> "$PSQL_LOG"
case "$*" in
  *"probe:catalog_runner_job_state_before"*) printf "00000000-0000-4000-8000-000000000111|target|released|completed|promoted|acknowledged|present|committed|present\n" ;;
  *"probe:catalog_runner_job_state_after"*) printf "00000000-0000-4000-8000-000000000111|target|released|completed|promoted|acknowledged|present|committed|present\n" ;;
  *"probe:catalog_runner_active_reservation"*) printf "00000000-0000-4000-8000-000000000111|target|released\n" ;;
  *) printf "1\n" ;;
esac
'

  RUN_EXIT_CODE=0
  RUN_STDOUT="$(
    PATH="$WORK_DIR/bin:$PATH" \
    CURL_LOG="$WORK_DIR/curl.log" \
    PSQL_LOG="$WORK_DIR/psql.log" \
    CARGO_LOG="$WORK_DIR/cargo.log" \
    DATABASE_URL="postgres://catalog-probe.invalid/fjcloud" \
    ALGOLIA_IMPORT_CATALOG_STATE_POLL_ATTEMPTS=2 \
    ALGOLIA_IMPORT_CATALOG_STATE_POLL_SECONDS=0 \
    bash "$REPO_ROOT/scripts/algolia_import_catalog_caller_runner.sh" \
    --inventory "$WORK_DIR/catalog_lifecycle_writers.json" \
    --phases catalog,lifecycle_exclusion \
    --job-id job-123 \
    --api-url "http://127.0.0.1:3099" \
    --auth-config "$WORK_DIR/fjcloud-auth.conf" \
    --admin-key "local-admin-key" \
    --target-index "target" \
    --runtime-dir "$WORK_DIR/runtime" \
    --output "$output" 2>&1
  )" || RUN_EXIT_CODE=$?

  assert_eq "$RUN_EXIT_CODE" "1" \
    "default runner must fail when the import is already released before writer execution"
  assert_contains "$RUN_STDOUT" "ack_initial_state_not_observed" \
    "unheld initial job emits a checkpoint-specific stable runner reason"
}

test_default_runner_rejects_unlinked_initial_job() {
  setup_workspace
  local output="$WORK_DIR/default_runner_evidence.json"
  write_fake_command "$WORK_DIR/bin/psql" '#!/usr/bin/env bash
set -euo pipefail
printf "%s\n" "$*" >> "$PSQL_LOG"
case "$*" in
  *"probe:catalog_runner_job_state_before"*) printf "00000000-0000-4000-8000-000000000111|target|active|queued|not_started|pending|absent|ambiguous|absent\n" ;;
  *"probe:catalog_runner_job_state_after"*) printf "00000000-0000-4000-8000-000000000111|target|released|completed|promoted|acknowledged|present|ambiguous|absent\n" ;;
  *"probe:catalog_runner_active_reservation"*) printf "00000000-0000-4000-8000-000000000111|target|active\n" ;;
  *) printf "1\n" ;;
esac
'

  RUN_EXIT_CODE=0
  RUN_STDOUT="$(
    PATH="$WORK_DIR/bin:$PATH" \
    CURL_LOG="$WORK_DIR/curl.log" \
    PSQL_LOG="$WORK_DIR/psql.log" \
    CARGO_LOG="$WORK_DIR/cargo.log" \
    DATABASE_URL="postgres://catalog-probe.invalid/fjcloud" \
    ALGOLIA_IMPORT_CATALOG_STATE_POLL_ATTEMPTS=2 \
    ALGOLIA_IMPORT_CATALOG_STATE_POLL_SECONDS=0 \
    bash "$REPO_ROOT/scripts/algolia_import_catalog_caller_runner.sh" \
    --inventory "$WORK_DIR/catalog_lifecycle_writers.json" \
    --phases catalog,lifecycle_exclusion \
    --job-id job-123 \
    --api-url "http://127.0.0.1:3099" \
    --auth-config "$WORK_DIR/fjcloud-auth.conf" \
    --admin-key "local-admin-key" \
    --target-index "target" \
    --runtime-dir "$WORK_DIR/runtime" \
    --output "$output" 2>&1
  )" || RUN_EXIT_CODE=$?

  assert_eq "$RUN_EXIT_CODE" "1" \
    "default runner must fail when the import never linked to an engine job"
  assert_contains "$RUN_STDOUT" "ack_initial_state_not_observed" \
    "unlinked initial job emits a stable runner reason before caller coverage is counted"
}

test_default_runner_rejects_unmapped_catalog_scenarios() {
  setup_workspace
  copy_fixture "$DEFAULT_INVENTORY" "$WORK_DIR/catalog_lifecycle_writers.json" unknown_catalog_scenario
  local output="$WORK_DIR/default_runner_evidence.json"

  RUN_EXIT_CODE=0
  PATH="$WORK_DIR/bin:$PATH" \
    CURL_LOG="$WORK_DIR/curl.log" \
    bash "$REPO_ROOT/scripts/algolia_import_catalog_caller_runner.sh" \
    --inventory "$WORK_DIR/catalog_lifecycle_writers.json" \
    --phases catalog \
    --job-id job-123 \
    --api-url "http://127.0.0.1:3099" \
    --auth-config "$WORK_DIR/fjcloud-auth.conf" \
    --admin-key "local-admin-key" \
    --target-index "target" \
    --runtime-dir "$WORK_DIR/runtime" \
    --output "$output" >/dev/null 2>&1 || RUN_EXIT_CODE=$?

  assert_eq "$RUN_EXIT_CODE" "1" \
    "default runner must not claim broad command-class coverage for an unmapped scenario"
  assert_not_contains "$(cat "$WORK_DIR/curl.log")" "POST http://127.0.0.1:3099/indexes" \
    "unmapped scenario should fail before issuing a generic catalog mutation"
}

test_required_dependency_and_phase_failures_are_action_required() {
  setup_workspace
  run_probe --phases ""
  assert_eq "$RUN_EXIT_CODE" "1" "empty phase set should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=invalid_phases" \
    "empty phase emits ACTION_REQUIRED"

  setup_workspace
  run_probe --phases privacy_erasure
  assert_eq "$RUN_EXIT_CODE" "1" "privacy erasure remains a dependency-gated phase"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=privacy_scrub_transport_unavailable" \
    "privacy erasure reports the missing authenticated scrub transport"
  assert_contains "$RUN_STDOUT" "DEPENDENCY|phase=privacy_erasure|id=authenticated_engine_seal_privacy_scrub|status=action_required" \
    "privacy transport gate names the missing contract"
  assert_eq "$(cat "$WORK_DIR/up.log")" "" "privacy transport gate fails before stack start"

  setup_workspace
  copy_oracle "$DEFAULT_ORACLE" "$WORK_DIR/catalog_lifecycle_acceptance_oracles.json" privacy_scrub_worker_unavailable
  run_probe --phases privacy_erasure
  assert_eq "$RUN_EXIT_CODE" "1" "missing scrub worker should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=privacy_scrub_worker_unavailable" \
    "missing scrub worker emits ACTION_REQUIRED"
  assert_contains "$RUN_STDOUT" "DEPENDENCY|phase=privacy_erasure|id=cloud_erased_tombstone_scrub_worker|status=action_required" \
    "scrub worker gate names the missing cloud owner"
  assert_eq "$(cat "$WORK_DIR/up.log")" "" "scrub worker gate fails before stack start"

  setup_workspace
  copy_oracle "$DEFAULT_ORACLE" "$WORK_DIR/catalog_lifecycle_acceptance_oracles.json" privacy_boundary_control_unavailable
  run_probe --phases privacy_erasure
  assert_eq "$RUN_EXIT_CODE" "1" "missing deterministic boundary controls should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=privacy_boundary_control_unavailable" \
    "missing deterministic boundary controls emit ACTION_REQUIRED"
  assert_contains "$RUN_STDOUT" "DEPENDENCY|phase=privacy_erasure|id=deterministic_source_boundary_controls|status=action_required" \
    "boundary-control gate names the missing source-built controls"
  assert_eq "$(cat "$WORK_DIR/up.log")" "" "boundary-control gate fails before stack start"

  setup_workspace
  CONTRACT_CHECK_SCENARIO=missing_scrub run_probe --phases catalog
  assert_eq "$RUN_EXIT_CODE" "1" "engine contract mismatch should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=flapjack_dev_dir_mismatch" \
    "engine contract mismatch emits ACTION_REQUIRED"

  setup_workspace
  CONTRACT_CHECK_SCENARIO=missing_ack_route run_probe --phases catalog
  assert_eq "$RUN_EXIT_CODE" "1" "missing engine ACK route should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=engine_ack_route_unavailable" \
    "missing engine ACK route emits its actionable dependency reason"
}

test_fixture_mutations_fail_closed_before_stack_start() {
  setup_workspace
  copy_fixture "$DEFAULT_INVENTORY" "$WORK_DIR/catalog_lifecycle_writers.json" zero_blocking_denominator
  run_probe --phases catalog
  assert_eq "$RUN_EXIT_CODE" "1" "zero blocking denominator should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=zero_class_denominator" \
    "zero denominator emits ACTION_REQUIRED"
  assert_eq "$(cat "$WORK_DIR/up.log")" "" "fixture validation fails before stack start"

  setup_workspace
  copy_fixture "$DEFAULT_INVENTORY" "$WORK_DIR/catalog_lifecycle_writers.json" missing_caller_mapping
  run_probe --phases catalog
  assert_eq "$RUN_EXIT_CODE" "1" "missing live caller key should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=missing_caller_mapping" \
    "missing caller mapping emits ACTION_REQUIRED"

  setup_workspace
  copy_fixture "$DEFAULT_INVENTORY" "$WORK_DIR/catalog_lifecycle_writers.json" missing_executable_caller_mapping
  run_probe --phases catalog
  assert_eq "$RUN_EXIT_CODE" "1" "missing executable caller command should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=missing_caller_mapping" \
    "missing executable caller mapping emits ACTION_REQUIRED"

  setup_workspace
  copy_fixture "$DEFAULT_INVENTORY" "$WORK_DIR/catalog_lifecycle_writers.json" duplicate_writer_id
  run_probe --phases catalog
  assert_eq "$RUN_EXIT_CODE" "1" "duplicate writer ID should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=duplicate_writer_id" \
    "duplicate writer ID emits ACTION_REQUIRED"

  setup_workspace
  copy_fixture "$DEFAULT_INVENTORY" "$WORK_DIR/catalog_lifecycle_writers.json" wrong_disposition
  run_probe --phases catalog
  assert_eq "$RUN_EXIT_CODE" "1" "unknown disposition should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=unknown_disposition" \
    "unknown disposition emits ACTION_REQUIRED"

  setup_workspace
  copy_fixture "$DEFAULT_INVENTORY" "$WORK_DIR/catalog_lifecycle_writers.json" stale_source_discovery
  run_probe --phases catalog
  assert_eq "$RUN_EXIT_CODE" "1" "stale source discovery should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=stale_source_discovery" \
    "stale source discovery emits ACTION_REQUIRED"
  assert_eq "$(cat "$WORK_DIR/up.log")" "" "stale source discovery fails before stack start"

  setup_workspace
  copy_oracle "$DEFAULT_ORACLE" "$WORK_DIR/catalog_lifecycle_acceptance_oracles.json" altered_acceptance_oracle
  run_probe --phases catalog
  assert_eq "$RUN_EXIT_CODE" "1" "altered acceptance oracle should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=altered_acceptance_oracle" \
    "altered acceptance oracle emits ACTION_REQUIRED"
  assert_eq "$(cat "$WORK_DIR/up.log")" "" "altered acceptance oracle fails before stack start"

  setup_workspace
  copy_fixture "$DEFAULT_INVENTORY" "$WORK_DIR/catalog_lifecycle_writers.json" shared_nested_scenario
  run_probe --phases catalog
  assert_eq "$RUN_EXIT_CODE" "0" "one production scenario may observe multiple canonical writers"
}

test_noncanonical_fixture_paths_fail_closed_before_stack_start() {
  setup_workspace
  INVENTORY_PATH="$WORK_DIR/missing_catalog_lifecycle_writers.json" run_probe --phases catalog
  assert_eq "$RUN_EXIT_CODE" "1" "missing inventory path should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=missing_fixture_path" \
    "missing inventory path emits ACTION_REQUIRED"
  assert_eq "$(cat "$WORK_DIR/up.log")" "" "missing inventory path fails before stack start"

  setup_workspace
  ORACLE_PATH="$WORK_DIR/missing_catalog_lifecycle_acceptance_oracles.json" run_probe --phases catalog
  assert_eq "$RUN_EXIT_CODE" "1" "missing oracle path should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=missing_fixture_path" \
    "missing oracle path emits ACTION_REQUIRED"
  assert_eq "$(cat "$WORK_DIR/up.log")" "" "missing oracle path fails before stack start"

  setup_workspace
  copy_fixture "$DEFAULT_INVENTORY" "$WORK_DIR/noncanonical_inventory.json"
  INVENTORY_PATH="$WORK_DIR/noncanonical_inventory.json" run_probe --phases catalog
  assert_eq "$RUN_EXIT_CODE" "1" "noncanonical inventory path should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=noncanonical_fixture_path" \
    "noncanonical inventory path emits ACTION_REQUIRED"
  assert_eq "$(cat "$WORK_DIR/up.log")" "" "noncanonical inventory path fails before stack start"

  setup_workspace
  copy_oracle "$DEFAULT_ORACLE" "$WORK_DIR/noncanonical_oracle.json"
  ORACLE_PATH="$WORK_DIR/noncanonical_oracle.json" run_probe --phases catalog
  assert_eq "$RUN_EXIT_CODE" "1" "noncanonical oracle path should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=noncanonical_fixture_path" \
    "noncanonical oracle path emits ACTION_REQUIRED"
  assert_eq "$(cat "$WORK_DIR/up.log")" "" "noncanonical oracle path fails before stack start"
}

assert_caller_evidence_failure() {
  local scenario="$1"
  local reason="$2"
  setup_workspace
  CALLER_RUNNER_SCENARIO="$scenario" run_probe --phases catalog,lifecycle_exclusion
  assert_eq "$RUN_EXIT_CODE" "1" "$scenario caller evidence should fail closed"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=$reason" \
    "$scenario emits stable ACTION_REQUIRED reason"
  assert_contains "$(cat "$WORK_DIR/down.log")" "pid_dir=" \
    "$scenario tears down the isolated stack"
}

test_runtime_failures_are_action_required_and_cleanup_runs() {
  setup_workspace
  CALLER_RUNNER_PATH="$WORK_DIR/missing_runner" run_probe --phases catalog
  assert_eq "$RUN_EXIT_CODE" "1" "missing production caller runner should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=production_caller_runner_unavailable" \
    "missing runner emits stable ACTION_REQUIRED reason"

  setup_workspace
  write_fake_command "$WORK_DIR/caller_runner.sh" '#!/usr/bin/env bash
set -euo pipefail
while [ "$#" -gt 0 ]; do
  case "$1" in
    --admin-key) printf "leaked fixture secret: algolia-admin-secret\n" >&2; shift 2 ;;
    *) shift 2 ;;
  esac
done
printf "ack_release_not_observed\n" >&2
exit 1
'
  run_probe --phases catalog
  assert_eq "$RUN_EXIT_CODE" "1" "runner failure with raw secret output should fail closed"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=ack_release_not_observed" \
    "probe still preserves the runner's stable reason"
  assert_not_contains "$RUN_STDOUT" "algolia-admin-secret" \
    "probe suppresses raw caller runner output that can contain secrets"

  setup_workspace
  CALLER_RUNNER_SCENARIO=runner_failed run_probe --phases catalog
  assert_eq "$RUN_EXIT_CODE" "1" "production caller runner failure should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=ack_release_not_observed" \
    "probe preserves the runner's stable failure reason"

  setup_workspace
  CALLER_RUNNER_SCENARIO=live_caller_missing run_probe --phases catalog
  assert_eq "$RUN_EXIT_CODE" "1" "missing live production caller should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=source_selection_not_live_called" \
    "probe preserves the live caller's stable failure reason"

  assert_caller_evidence_failure missing_observation accepted_refused_count_drift
  assert_caller_evidence_failure accepted_mutation catalog_mutation_accepted
  assert_caller_evidence_failure duplicate_writer repeated_writer_observation
  assert_caller_evidence_failure wrong_caller_command accepted_refused_count_drift
  assert_caller_evidence_failure repeated_scenario repeated_scenario_coverage
  assert_caller_evidence_failure invariant_drift catalog_invariant_drift
  assert_caller_evidence_failure missing_invariant_surfaces catalog_invariant_drift
  assert_caller_evidence_failure missing_live_reservation_checks active_reservation_not_observed
  assert_caller_evidence_failure early_release early_reservation_release
  assert_caller_evidence_failure unlinked_ack_ledger ack_release_not_observed
  assert_caller_evidence_failure missing_soft_delete_boundary soft_delete_boundary_missing
  assert_caller_evidence_failure missing_hidden_authorization lifecycle_policy_drift
  assert_caller_evidence_failure missing_ack_release_contract ack_release_not_observed
  assert_caller_evidence_failure broad_lifecycle_smoke soft_delete_boundary_missing
  assert_caller_evidence_failure deleted_reactivation_accepted deleted_reactivation_accepted
  assert_caller_evidence_failure suspended_reactivation_refused suspended_reactivation_control_failed
}

test_failure_diagnostics_and_async_cleanup_converge() {
  setup_workspace
  CURL_SCENARIO=eligibility_down run_probe --phases catalog
  assert_eq "$RUN_EXIT_CODE" "1" "eligibility endpoint failure should fail"
  assert_contains "$RUN_STDOUT" "target=POST /migration/algolia/destination-eligibility|http_status=503" \
    "cleanup preserves the primary request status"

  setup_workspace
  CURL_SCENARIO=unsafe_task_identifier run_probe --phases catalog
  assert_eq "$RUN_EXIT_CODE" "1" "unsafe Algolia task identifiers should fail closed"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=invalid_response_identifier" \
    "unsafe task identifier emits a stable ACTION_REQUIRED reason"

  setup_workspace
  ALGOLIA_DELETE_TASK=1 run_probe --phases catalog,lifecycle_exclusion
  assert_eq "$RUN_EXIT_CODE" "0" "cleanup should await asynchronous Algolia deletion"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "/task/2" \
    "cleanup observes the Algolia deletion task before residue validation"
  assert_contains "$RUN_STDOUT" "CLEANUP|algolia_indexes=0|algolia_keys=0|local_stack=0|runtime_files=0" \
    "asynchronous cleanup reports zero residue after task convergence"

  setup_workspace
  ALGOLIA_INDEX_RESIDUE_SCENARIO=retained_owned_index run_probe --phases catalog
  assert_eq "$RUN_EXIT_CODE" "1" "owned Algolia index residue should fail the probe"
  assert_contains "$RUN_STDOUT" "CLEANUP|algolia_indexes=1|algolia_keys=0|local_stack=0|runtime_files=0" \
    "cleanup reports the retained owned index residue"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=residue_detected" \
    "owned Algolia index residue emits a stable ACTION_REQUIRED reason"
}

test_restricted_source_key_is_verified_before_dispatch() {
  setup_workspace
  CURL_SCENARIO=restricted_key_requires_readiness run_probe --phases catalog,lifecycle_exclusion
  assert_eq "$RUN_EXIT_CODE" "0" \
    "probe should verify the restricted source key before dispatch"
  assert_contains "$(cat "$WORK_DIR/curl.log")" \
    "GET https://testapp123.algolia.net/1/indexes/fjcloud_import_catalog_probe_test_source" \
    "probe checks restricted source-key readability before job creation"
  assert_eq "$(test -f "$WORK_DIR/restricted-key-readiness-observed" && printf yes || printf no)" "yes" \
    "readiness probe uses the restricted source key"
  assert_contains "$RUN_STDOUT" "RESULT|status=PASS|phases=catalog,lifecycle_exclusion" \
    "readiness-gated dispatch passes"
}

test_caller_runner_override_is_documented() {
  assert_contains "$(cat "$ENV_VARS_DOC")" 'ALGOLIA_IMPORT_CATALOG_CALLER_RUNNER' \
    "production caller runner test override is documented"
}

test_success_emits_noninflated_catalog_and_lifecycle_evidence
test_default_runner_produces_validated_source_built_evidence
test_default_runner_rejects_released_live_job_during_scenario_execution
test_default_runner_rejects_isolated_source_selection
test_default_runner_rejects_temporal_binding_without_live_caller
test_default_runner_rejects_unobserved_terminal_ack
test_default_runner_rejects_unheld_initial_job
test_default_runner_rejects_unlinked_initial_job
test_default_runner_rejects_unmapped_catalog_scenarios
test_required_dependency_and_phase_failures_are_action_required
test_fixture_mutations_fail_closed_before_stack_start
test_noncanonical_fixture_paths_fail_closed_before_stack_start
test_runtime_failures_are_action_required_and_cleanup_runs
test_failure_diagnostics_and_async_cleanup_converge
test_restricted_source_key_is_verified_before_dispatch
test_caller_runner_override_is_documented

run_test_summary
