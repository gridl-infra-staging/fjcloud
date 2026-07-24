#!/usr/bin/env bash
# Inventory-driven production caller runner for the Algolia import catalog probe.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EVIDENCE_VALIDATOR="$SCRIPT_DIR/lib/algolia_import_catalog_evidence.py"
INVENTORY=""
REQUESTED_PHASES=""
JOB_ID=""
API_URL=""
AUTH_CONFIG=""
ADMIN_KEY=""
TARGET_INDEX=""
RUNTIME_DIR=""
OUTPUT=""
HTTP_BODY=""
HTTP_STATUS=""
OBSERVATIONS_FILE=""
EXECUTED_SCENARIOS_FILE=""
EXECUTED_INVOCATIONS_FILE=""
JOB_STATES_FILE=""
INVARIANT_SNAPSHOTS_FILE=""
LIFECYCLE_CHECKS_FILE=""
LIVE_RESERVATION_CHECKS_FILE=""
LIVE_CUSTOMER_ID=""
LIVE_TARGET_INDEX=""
STATE_POLL_ATTEMPTS="${ALGOLIA_IMPORT_CATALOG_STATE_POLL_ATTEMPTS:-18}"
STATE_POLL_SECONDS="${ALGOLIA_IMPORT_CATALOG_STATE_POLL_SECONDS:-5}"
INVARIANT_SURFACES="catalog public_indexes quota routing"

usage() {
    cat >&2 <<'USAGE'
Usage: algolia_import_catalog_caller_runner.sh --inventory <json> --phases catalog,lifecycle_exclusion --job-id <id> --api-url <url> --auth-config <curl-config> --admin-key <key> --target-index <name> --runtime-dir <dir> --output <json>
USAGE
}

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --inventory) INVENTORY="${2:-}"; shift 2 ;;
            --phases) REQUESTED_PHASES="${2:-}"; shift 2 ;;
            --job-id) JOB_ID="${2:-}"; shift 2 ;;
            --api-url) API_URL="${2:-}"; shift 2 ;;
            --auth-config) AUTH_CONFIG="${2:-}"; shift 2 ;;
            --admin-key) ADMIN_KEY="${2:-}"; shift 2 ;;
            --target-index) TARGET_INDEX="${2:-}"; shift 2 ;;
            --runtime-dir) RUNTIME_DIR="${2:-}"; shift 2 ;;
            --output) OUTPUT="${2:-}"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) usage; fail "invalid_args" ;;
        esac
    done
}

require_inputs() {
    [ -f "$INVENTORY" ] || fail "inventory_unavailable"
    [ -n "$REQUESTED_PHASES" ] || fail "invalid_phases"
    [ -n "$JOB_ID" ] || fail "job_id_required"
    [ -n "$API_URL" ] || fail "api_url_required"
    [ -f "$AUTH_CONFIG" ] || fail "auth_config_unavailable"
    [ -n "$ADMIN_KEY" ] || fail "admin_key_required"
    [ -n "$TARGET_INDEX" ] || fail "target_index_required"
    [ -d "$RUNTIME_DIR" ] || fail "runtime_dir_unavailable"
    [ -n "$OUTPUT" ] || fail "output_required"
    [ -n "${DATABASE_URL:-}" ] || fail "database_url_required"
    [ -f "$EVIDENCE_VALIDATOR" ] || fail "caller_evidence_invalid"
    command -v cargo >/dev/null 2>&1 || fail "source_built_caller_unavailable"
    command -v psql >/dev/null 2>&1 || fail "job_state_observer_unavailable"
    [[ "$STATE_POLL_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || fail "invalid_poll_config"
    [[ "$STATE_POLL_SECONDS" =~ ^[0-9]+$ ]] || fail "invalid_poll_config"
}

phase_requested() {
    case ",$REQUESTED_PHASES," in
        *",$1,"*) return 0 ;;
        *) return 1 ;;
    esac
}

secure_temp_file() {
    local path
    path="$(mktemp "$RUNTIME_DIR/caller.XXXXXX")"
    chmod 600 "$path"
    printf '%s\n' "$path"
}

capture_http_response() {
    local response="$1"
    HTTP_STATUS="${response##*$'\n'}"
    HTTP_BODY="${response%$'\n'*}"
    if [ "$HTTP_STATUS" = "$response" ]; then
        HTTP_BODY=""
    fi
}

api_request() {
    local expected_statuses="$1"
    local method="$2"
    local path="$3"
    local data_file="${4:-}"
    local config_file="${5:-$AUTH_CONFIG}"
    local response status
    local args=(-sS --connect-timeout 2 --max-time 20 -X "$method" --config "$config_file")
    if [ -n "$data_file" ]; then
        args+=(-H "content-type: application/json" --data @"$data_file")
    fi
    response="$(curl "${args[@]}" -w "\n%{http_code}" "${API_URL%/}${path}" || true)"
    capture_http_response "$response"
    for status in $expected_statuses; do
        [ "$HTTP_STATUS" = "$status" ] && return 0
    done
    return 1
}

canonical_json() {
    python3 - "$1" <<'PY'
import json
import sys

print(json.dumps(json.loads(sys.argv[1]), separators=(",", ":"), sort_keys=True))
PY
}

catalog_rows_tsv() {
    python3 - "$INVENTORY" "$REQUESTED_PHASES" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    inventory = json.load(handle)
phases = set(sys.argv[2].split(","))
for row in inventory["writers"]:
    if row.get("live_phase") in phases:
        print("\t".join([
            row["id"],
            row["live_caller_key"],
            row["live_caller_command"],
            row["live_scenario_key"],
            row["live_phase"],
        ]))
PY
}

require_scenario_mapping() {
    local command="$1"
    local scenario_key="$2"
    local phase="$3"
    case "$phase:$command" in
        catalog:invoke_catalog_blocking_writer)
            [[ "$scenario_key" == catalog_lifecycle_leases::catalog_lifecycle_lease_remote_races::* ]] \
                || fail "caller_evidence_invalid"
            ;;
        lifecycle_exclusion:invoke_lifecycle_soft_delete_writer)
            case "$scenario_key" in
                pg_customer_repo_test::*|account_test::*|admin_audit_view_test::*) ;;
                *) fail "caller_evidence_invalid" ;;
            esac
            ;;
        *) fail "caller_evidence_invalid" ;;
    esac
}

record_observation() {
    local writer_id="$1"
    local caller_key="$2"
    local command="$3"
    local scenario_key="$4"
    local outcome="$5"
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$writer_id" "$caller_key" "$command" "$scenario_key" "$outcome" \
        >> "$OBSERVATIONS_FILE"
}

phase_scenarios_tsv() {
    local selected_phase="$1"
    python3 - "$INVENTORY" "$selected_phase" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    inventory = json.load(handle)
rows = {
    (
        row["live_caller_command"],
        row["live_scenario_key"],
        row["live_phase"],
    )
    for row in inventory["writers"]
    if row.get("live_phase") == sys.argv[2]
}
for row in sorted(rows):
    print("\t".join(row))
PY
}

run_source_built_selection() {
    local selection="$1"
    local require_live_caller="${2:-false}"
    local caller_key="${3:-}"
    local invocation_key output_file test_target
    [[ "$selection" =~ ^[A-Za-z0-9_:]+$ ]] || fail "caller_evidence_invalid"
    if [ "$require_live_caller" = "true" ]; then
        [[ "$caller_key" =~ ^[A-Za-z0-9_]+$ ]] || fail "caller_evidence_invalid"
    fi
    invocation_key="${selection}"$'\t'"${caller_key}"
    if grep -Fqx "$invocation_key" "$EXECUTED_INVOCATIONS_FILE"; then
        return 0
    fi
    test_target="$(selection_test_target "$selection")" || fail "caller_evidence_invalid"
    output_file="$(secure_temp_file)"
    if ! run_cargo_selection "$test_target" "$selection" "$output_file" "$caller_key"; then
        printf 'FAILED_SELECTION|%s\n' "$selection" >&2
        fail "production_caller_failed"
    fi
    if ! grep -Eq 'test result: ok\. [1-9][0-9]* passed; 0 failed;' "$output_file" \
        && grep -Eq 'test result: ok\. 0 passed; 0 failed; [1-9][0-9]* ignored;' "$output_file"; then
        output_file="$(secure_temp_file)"
        if ! run_cargo_selection "$test_target" "$selection" "$output_file" "$caller_key" --ignored; then
            printf 'FAILED_SELECTION|%s\n' "$selection" >&2
            fail "production_caller_failed"
        fi
    fi
    if ! grep -Eq 'test result: ok\. [1-9][0-9]* passed; 0 failed;' "$output_file"; then
        printf 'FAILED_SELECTION|%s\n' "$selection" >&2
        fail "production_caller_failed"
    fi
    if grep -Eq 'SKIP: DATABASE_URL|skipping .*PostgreSQL' "$output_file"; then
        fail "database_caller_skipped"
    fi
    require_live_source_binding "$selection" "$output_file" "$require_live_caller" "$caller_key"
    printf '%s\n' "$invocation_key" >> "$EXECUTED_INVOCATIONS_FILE"
    grep -Fqx "$selection" "$EXECUTED_SCENARIOS_FILE" \
        || printf '%s\n' "$selection" >> "$EXECUTED_SCENARIOS_FILE"
}

require_live_source_binding() {
    local selection="$1"
    local output_file="$2"
    local require_live_caller="$3"
    local caller_key="$4"
    local expected
    expected="CATALOG_LIVE_BINDING|selection=${selection}|job_id=${JOB_ID}|customer_id=${LIVE_CUSTOMER_ID}|target_index=${LIVE_TARGET_INDEX}"
    [ "$(grep -Fxc "$expected" "$output_file" || true)" -eq 1 ] \
        || fail "source_selection_not_live_bound"
    if [ "$require_live_caller" = "true" ]; then
        expected="CATALOG_LIVE_CALLER|caller_key=${caller_key}|selection=${selection}|job_id=${JOB_ID}|customer_id=${LIVE_CUSTOMER_ID}|target_index=${LIVE_TARGET_INDEX}|outcome=refused"
        [ "$(grep -Fxc "$expected" "$output_file" || true)" -eq 1 ] \
            || fail "source_selection_not_live_called"
    fi
}

run_cargo_selection() {
    local test_target="$1"
    local selection="$2"
    local output_file="$3"
    local caller_key="$4"
    local ignored_flag="${5:-}"
    (
        cd "$REPO_ROOT/infra"
        if [ -n "$ignored_flag" ]; then
            DATABASE_URL="$DATABASE_URL" \
                ALGOLIA_IMPORT_CATALOG_LIVE_JOB_ID="$JOB_ID" \
                ALGOLIA_IMPORT_CATALOG_LIVE_CUSTOMER_ID="$LIVE_CUSTOMER_ID" \
                ALGOLIA_IMPORT_CATALOG_LIVE_TARGET_INDEX="$LIVE_TARGET_INDEX" \
                ALGOLIA_IMPORT_CATALOG_LIVE_API_URL="$API_URL" \
                ALGOLIA_IMPORT_CATALOG_LIVE_AUTH_CONFIG="$AUTH_CONFIG" \
                ALGOLIA_IMPORT_CATALOG_LIVE_ADMIN_KEY="$ADMIN_KEY" \
                ALGOLIA_IMPORT_CATALOG_LIVE_SELECTION="$selection" \
                ALGOLIA_IMPORT_CATALOG_LIVE_CALLER_KEY="$caller_key" \
                cargo test --no-fail-fast \
                -p api --test "$test_target" "$selection" \
                -- --test-threads=1 --nocapture --exact "$ignored_flag"
        else
            DATABASE_URL="$DATABASE_URL" \
                ALGOLIA_IMPORT_CATALOG_LIVE_JOB_ID="$JOB_ID" \
                ALGOLIA_IMPORT_CATALOG_LIVE_CUSTOMER_ID="$LIVE_CUSTOMER_ID" \
                ALGOLIA_IMPORT_CATALOG_LIVE_TARGET_INDEX="$LIVE_TARGET_INDEX" \
                ALGOLIA_IMPORT_CATALOG_LIVE_API_URL="$API_URL" \
                ALGOLIA_IMPORT_CATALOG_LIVE_AUTH_CONFIG="$AUTH_CONFIG" \
                ALGOLIA_IMPORT_CATALOG_LIVE_ADMIN_KEY="$ADMIN_KEY" \
                ALGOLIA_IMPORT_CATALOG_LIVE_SELECTION="$selection" \
                ALGOLIA_IMPORT_CATALOG_LIVE_CALLER_KEY="$caller_key" \
                cargo test --no-fail-fast \
                -p api --test "$test_target" "$selection" \
                -- --test-threads=1 --nocapture --exact
        fi
    ) >"$output_file" 2>&1
}

selection_test_target() {
    local selection="$1"
    python3 - "$REPO_ROOT" "$selection" <<'PY'
import pathlib
import re
import sys

repo_root = pathlib.Path(sys.argv[1])
selection = sys.argv[2]
module = selection.split("::", 1)[0]
test_roots = sorted((repo_root / "infra/api/tests").glob("*.rs"))
for root in test_roots:
    source = root.read_text(encoding="utf-8")
    if re.search(rf"(?m)^mod {re.escape(module)};$", source):
        print(root.stem)
        raise SystemExit(0)
raise SystemExit(1)
PY
}

record_scenario_observations() {
    local selected_phase="$1"
    local selected_scenario="$2"
    local outcome="$3"
    local writer_id caller_key command scenario_key phase
    local observed=0
    while IFS=$'\t' read -r writer_id caller_key command scenario_key phase; do
        [ "$phase" = "$selected_phase" ] || continue
        [ "$scenario_key" = "$selected_scenario" ] || continue
        record_observation "$writer_id" "$caller_key" "$command" "$scenario_key" "$outcome"
        observed=$((observed + 1))
    done < <(catalog_rows_tsv)
    [ "$observed" -gt 0 ] || fail "caller_evidence_invalid"
}

execute_phase_scenarios() {
    local selected_phase="$1"
    local outcome="$2"
    local command scenario_key phase
    while IFS=$'\t' read -r command scenario_key phase; do
        require_scenario_mapping "$command" "$scenario_key" "$phase"
        run_live_bound_source_selection "$scenario_key"
        record_scenario_observations "$selected_phase" "$scenario_key" "$outcome"
    done < <(phase_scenarios_tsv "$selected_phase")
}

catalog_invariant_sql() {
    local surface="$1"
    case "$surface" in
        catalog)
            cat <<'SQL'
SELECT COALESCE(jsonb_agg(to_jsonb(row) ORDER BY row.customer_id, row.tenant_id), '[]'::jsonb)::text
FROM (
    SELECT customer_id::text, tenant_id, deployment_id::text, vm_id::text,
           tier, service_type, cold_snapshot_id::text
    FROM customer_tenants
) AS row;
/* probe:catalog_invariant_catalog */
SQL
            ;;
        quota)
            cat <<'SQL'
SELECT COALESCE(jsonb_agg(to_jsonb(row) ORDER BY row.id), '[]'::jsonb)::text
FROM (
    SELECT id::text, customer_id::text, logical_target, destination_kind,
           destination_region, destination_deployment_id::text,
           destination_vm_id::text, status, publication_disposition,
           engine_ack_state, reserved_index_count,
           reserved_customer_storage_bytes, reserved_node_transient_bytes
    FROM algolia_import_jobs
    WHERE erased_at IS NULL
) AS row;
/* probe:catalog_invariant_quota */
SQL
            ;;
        routing)
            cat <<'SQL'
SELECT jsonb_build_object(
    'deployments',
    COALESCE((SELECT jsonb_agg(to_jsonb(row) ORDER BY row.id)
              FROM (
                  SELECT id::text, customer_id::text, node_id, region, vm_type,
                         vm_provider, ip_address, status, provider_vm_id,
                         hostname, flapjack_url, health_status, failure_reason
                  FROM customer_deployments
              ) AS row), '[]'::jsonb),
    'replicas',
    COALESCE((SELECT jsonb_agg(to_jsonb(row) ORDER BY row.id)
              FROM (
                  SELECT id::text, customer_id::text, tenant_id,
                         primary_vm_id::text, replica_vm_id::text,
                         replica_region, status, lag_ops
                  FROM index_replicas
              ) AS row), '[]'::jsonb),
    'migrations',
    COALESCE((SELECT jsonb_agg(to_jsonb(row) ORDER BY row.id)
              FROM (
                  SELECT id::text, index_name, customer_id::text,
                         source_vm_id::text, dest_vm_id::text, status,
                         requested_by, error, metadata
                  FROM index_migrations
              ) AS row), '[]'::jsonb),
    'vms',
    COALESCE((SELECT jsonb_agg(to_jsonb(row) ORDER BY row.id)
              FROM (
                  SELECT id::text, region, provider, hostname, flapjack_url,
                         capacity, current_load, status
                  FROM vm_inventory
              ) AS row), '[]'::jsonb)
)::text;
/* probe:catalog_invariant_routing */
SQL
            ;;
        *) fail "caller_evidence_invalid" ;;
    esac
}

capture_psql_invariant() {
    local surface="$1"
    local sql
    sql="$(catalog_invariant_sql "$surface")"
    PSQLRC=/dev/null psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -tA \
        -c "$sql" 2>/dev/null | tr -d '\r'
}

capture_invariant_value() {
    local surface="$1"
    case "$surface" in
        public_indexes)
            api_request "200" GET "/indexes" || fail "catalog_invariant_drift"
            canonical_json "$HTTP_BODY" || fail "catalog_invariant_drift"
            ;;
        catalog|quota|routing)
            capture_psql_invariant "$surface" || fail "catalog_invariant_drift"
            ;;
        *) fail "caller_evidence_invalid" ;;
    esac
}

capture_invariant_hashes() {
    local output_file="$1"
    local surface value
    : > "$output_file"
    for surface in $INVARIANT_SURFACES; do
        value="$(capture_invariant_value "$surface")" || fail "catalog_invariant_drift"
        [ -n "$value" ] || fail "catalog_invariant_drift"
        printf '%s\t%s\n' "$surface" "$(snapshot_hash "$value")" >> "$output_file"
    done
}

record_catalog_invariant_snapshots() {
    local writer_id="$1"
    local caller_key="$2"
    local scenario_key="$3"
    local before_file="$4"
    local after_file="$5"
    local surface before_hash after_hash
    while IFS=$'\t' read -r surface before_hash; do
        after_hash="$(awk -F '\t' -v wanted="$surface" '$1 == wanted { print $2 }' "$after_file")"
        [ -n "$after_hash" ] || fail "catalog_invariant_drift"
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$writer_id" "$caller_key" "$scenario_key" \
            "$surface" "$before_hash" "$after_hash" \
            >> "$INVARIANT_SNAPSHOTS_FILE"
    done < "$before_file"
}

execute_catalog_scenarios() {
    local writer_id caller_key command scenario_key phase before_file after_file
    while IFS=$'\t' read -r writer_id caller_key command scenario_key phase; do
        [ "$phase" = "catalog" ] || continue
        require_scenario_mapping "$command" "$scenario_key" "$phase"
        before_file="$(secure_temp_file)"
        after_file="$(secure_temp_file)"
        capture_invariant_hashes "$before_file"
        run_live_bound_source_selection "$scenario_key" true "$caller_key"
        capture_invariant_hashes "$after_file"
        record_catalog_invariant_snapshots \
            "$writer_id" "$caller_key" "$scenario_key" "$before_file" "$after_file"
        record_observation "$writer_id" "$caller_key" "$command" "$scenario_key" refused
    done < <(catalog_rows_tsv)
}

active_reservation_sql() {
    # Canonical owner: PgAlgoliaImportJobRepo::active_reservation_predicate_for_contract_tests().
    cat <<'SQL'
erased_at IS NULL AND NOT (
   resumable = FALSE AND (
     (
       engine_ack_state = 'acknowledged'
       AND dispatch_intent_state <> 'absent'
       AND engine_job_id IS NOT NULL
       AND (
         (status IN ('completed', 'completed_with_warnings')
          AND publication_disposition = 'promoted')
         OR (status = 'cancelled' AND publication_disposition = 'unchanged')
         OR (status = 'failed'
             AND publication_disposition IN ('unchanged', 'not_started'))
         OR (status = 'interrupted' AND publication_disposition = 'unchanged')
       )
     )
     OR (
       engine_ack_state = 'not_applicable'
       AND status = 'failed'
       AND publication_disposition = 'not_started'
       AND dispatch_intent_state = 'absent'
       AND engine_job_id IS NULL
     )
     OR (
       engine_ack_state = 'seal_acknowledged'
       AND status = 'interrupted'
       AND publication_disposition = 'not_started'
       AND dispatch_intent_state <> 'absent'
       AND engine_job_id IS NULL
     )
   )
 )
SQL
}

query_job_state() {
    local probe_tag="$1"
    PSQLRC=/dev/null psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -tA -F '|' \
        -c \
        "SELECT customer_id::text, logical_target,
                CASE WHEN ($(active_reservation_sql)) THEN 'active' ELSE 'released' END,
                status, publication_disposition, engine_ack_state,
                CASE WHEN terminal_at IS NULL THEN 'absent' ELSE 'present' END,
                dispatch_intent_state,
                CASE WHEN engine_job_id IS NULL THEN 'absent' ELSE 'present' END
         FROM algolia_import_jobs
         WHERE id = '$JOB_ID'::uuid;
         /* probe:${probe_tag} */" 2>/dev/null | tr -d '\r'
}

query_active_reservation() {
    local probe_tag="$1"
    PSQLRC=/dev/null psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -tA -F '|' \
        -c \
        "SELECT customer_id::text, logical_target,
                CASE WHEN ($(active_reservation_sql)) THEN 'active' ELSE 'released' END
         FROM algolia_import_jobs
         WHERE id = '$JOB_ID'::uuid;
         /* probe:${probe_tag} */" 2>/dev/null | tr -d '\r'
}

require_active_reservation_for_selection() {
    local checkpoint="$1"
    local selection="$2"
    local caller_key="${3:-}"
    local state customer_id target_index reservation_state
    state="$(query_active_reservation "catalog_runner_active_reservation_${checkpoint}:${selection}:${caller_key:-scenario}")" \
        || fail "active_reservation_not_observed"
    IFS='|' read -r customer_id target_index reservation_state <<< "$state"
    [ "$customer_id" = "$LIVE_CUSTOMER_ID" ] || fail "active_reservation_not_observed"
    [ "$target_index" = "$LIVE_TARGET_INDEX" ] || fail "active_reservation_not_observed"
    [ "$reservation_state" = "active" ] || fail "active_reservation_not_observed"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$selection" "$caller_key" "$checkpoint" \
        "$customer_id" "$target_index" "$reservation_state" \
        >> "$LIVE_RESERVATION_CHECKS_FILE"
}

run_live_bound_source_selection() {
    local selection="$1"
    local require_live_caller="${2:-false}"
    local caller_key="${3:-}"
    require_active_reservation_for_selection before "$selection" "$caller_key"
    run_source_built_selection "$selection" "$require_live_caller" "$caller_key"
    require_active_reservation_for_selection after "$selection" "$caller_key"
}

observe_initial_job_state() {
    local state customer_id target_index reservation_state status disposition ack_state terminal_at dispatch_intent_state engine_job_id
    state="$(query_job_state catalog_runner_job_state_before)" \
        || fail "ack_initial_state_not_observed"
    IFS='|' read -r customer_id target_index reservation_state status disposition ack_state terminal_at dispatch_intent_state engine_job_id <<< "$state"
    LIVE_CUSTOMER_ID="$customer_id"
    LIVE_TARGET_INDEX="$target_index"
    [ -n "$LIVE_CUSTOMER_ID" ] || fail "ack_initial_state_not_observed"
    [ "$LIVE_TARGET_INDEX" = "$TARGET_INDEX" ] || fail "ack_initial_state_not_observed"
    [ "$reservation_state" = "active" ] || fail "ack_initial_state_not_observed"
    case "$status" in
        queued|validating_source|copying_configuration|copying_documents|verifying|promoting|cancelling) ;;
        *) fail "ack_initial_state_not_observed" ;;
    esac
    case "$disposition" in
        not_started|unchanged|unknown) ;;
        *) fail "ack_initial_state_not_observed" ;;
    esac
    [ "$ack_state" = "pending" ] || fail "ack_initial_state_not_observed"
    [ "$terminal_at" = "absent" ] || fail "ack_initial_state_not_observed"
    [ "$dispatch_intent_state" = "committed" ] || fail "ack_initial_state_not_observed"
    [ "$engine_job_id" = "present" ] || fail "ack_initial_state_not_observed"
    printf 'before_writer_execution\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$LIVE_CUSTOMER_ID" "$LIVE_TARGET_INDEX" "$reservation_state" \
        "$status" "$disposition" "$ack_state" "$terminal_at" \
        "$dispatch_intent_state" "$engine_job_id" >> "$JOB_STATES_FILE"
}

observe_terminal_job_state() {
    local attempt state customer_id target_index reservation_state status disposition ack_state terminal_at dispatch_intent_state engine_job_id
    for ((attempt = 1; attempt <= STATE_POLL_ATTEMPTS; attempt++)); do
        state="$(query_job_state catalog_runner_job_state_after)" \
            || fail "ack_terminal_state_not_observed"
        IFS='|' read -r customer_id target_index reservation_state status disposition ack_state terminal_at dispatch_intent_state engine_job_id <<< "$state"
        if { [ "$status" = "completed" ] || [ "$status" = "completed_with_warnings" ]; } \
            && [ "$customer_id" = "$LIVE_CUSTOMER_ID" ] \
            && [ "$target_index" = "$LIVE_TARGET_INDEX" ] \
            && [ "$reservation_state" = "released" ] \
            && [ "$disposition" = "promoted" ] \
            && [ "$ack_state" = "acknowledged" ] \
            && [ "$terminal_at" = "present" ] \
            && [ "$dispatch_intent_state" = "committed" ] \
            && [ "$engine_job_id" = "present" ]; then
            printf 'after_reconciliation\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$customer_id" "$target_index" "$reservation_state" \
                "$status" "$disposition" "$ack_state" "$terminal_at" \
                "$dispatch_intent_state" "$engine_job_id" >> "$JOB_STATES_FILE"
            return 0
        fi
        if [ "$attempt" -lt "$STATE_POLL_ATTEMPTS" ] && [ "$STATE_POLL_SECONDS" -gt 0 ]; then
            sleep "$STATE_POLL_SECONDS"
        fi
    done
    fail "ack_terminal_state_not_observed"
}

snapshot_hash() {
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
}

exercise_catalog_rows() {
    execute_catalog_scenarios
}

exercise_lifecycle_rows() {
    local contract selection lifecycle_manifest
    execute_phase_scenarios lifecycle_exclusion retained
    lifecycle_manifest="$(secure_temp_file)"
    python3 "$EVIDENCE_VALIDATOR" --list-lifecycle-checks > "$lifecycle_manifest" \
        || fail "caller_evidence_invalid"
    : > "$LIFECYCLE_CHECKS_FILE"
    while IFS=$'\t' read -r contract selection; do
        [ -n "$contract" ] && [ -n "$selection" ] || fail "caller_evidence_invalid"
        run_live_bound_source_selection "$selection"
        printf '%s\t%s\n' "$contract" "$selection" >> "$LIFECYCLE_CHECKS_FILE"
    done < "$lifecycle_manifest"
    [ -s "$LIFECYCLE_CHECKS_FILE" ] || fail "caller_evidence_invalid"
}

write_evidence() {
    python3 - \
        "$OBSERVATIONS_FILE" "$EXECUTED_SCENARIOS_FILE" \
        "$JOB_STATES_FILE" "$INVARIANT_SNAPSHOTS_FILE" \
        "$LIFECYCLE_CHECKS_FILE" "$LIVE_RESERVATION_CHECKS_FILE" "$REQUESTED_PHASES" \
        "$JOB_ID" "$OUTPUT" <<'PY'
import json
import sys

(
    observations_path,
    executed_scenarios_path,
    job_states_path,
    invariant_snapshots_path,
    lifecycle_checks_path,
    live_reservation_checks_path,
    phases_csv,
    job_id,
    output_path,
) = sys.argv[1:]
phases = set(phases_csv.split(","))
observations = []
with open(observations_path, encoding="utf-8") as handle:
    for raw_line in handle:
        line = raw_line.rstrip("\n")
        if not line:
            continue
        writer_id, caller_key, caller_command, scenario_key, outcome = line.split("\t")
        observations.append({
            "writer_id": writer_id,
            "caller_key": caller_key,
            "caller_command": caller_command,
            "scenario_key": scenario_key,
            "outcome": outcome,
        })
if not observations:
    raise SystemExit("caller_evidence_invalid")
if "catalog" not in phases and any(item["outcome"] == "refused" for item in observations):
    raise SystemExit("caller_evidence_invalid")
if "lifecycle_exclusion" not in phases and any(item["outcome"] == "retained" for item in observations):
    raise SystemExit("caller_evidence_invalid")
for item in observations:
    if item["outcome"] not in {"refused", "retained"}:
        raise SystemExit("caller_evidence_invalid")
def tsv_rows(path, columns):
    rows = []
    with open(path, encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.rstrip("\n")
            if not line:
                continue
            values = line.split("\t")
            if len(values) != len(columns):
                raise SystemExit("caller_evidence_invalid")
            rows.append(dict(zip(columns, values)))
    return rows

with open(executed_scenarios_path, encoding="utf-8") as handle:
    executed_scenarios = sorted({line.strip() for line in handle if line.strip()})
job_states = tsv_rows(
    job_states_path,
    [
        "checkpoint",
        "customer_id",
        "target_index",
        "reservation_state",
        "status",
        "publication_disposition",
        "engine_ack_state",
        "terminal_at",
        "dispatch_intent_state",
        "engine_job_id",
    ],
)

evidence = {
    "version": 1,
    "job_id": job_id,
    "observations": observations,
    "scenario_ledger": sorted({item["scenario_key"] for item in observations}),
    "executed_scenarios": executed_scenarios,
    "job_state_ledger": job_states,
    "live_reservation_checks": tsv_rows(
        live_reservation_checks_path,
        [
            "selection",
            "caller_key",
            "checkpoint",
            "customer_id",
            "target_index",
            "reservation_state",
        ],
    ),
}
if "catalog" in phases:
    invariant_snapshots = tsv_rows(
        invariant_snapshots_path,
        [
            "writer_id",
            "caller_key",
            "scenario_key",
            "surface",
            "before_sha256",
            "after_sha256",
        ],
    )
    evidence["invariants"] = {
        "surfaces": sorted({row["surface"] for row in invariant_snapshots}),
        "production_scenarios": sorted({
            item["scenario_key"]
            for item in observations
            if item["outcome"] == "refused"
        }),
    }
    evidence["invariant_snapshots"] = invariant_snapshots
if "lifecycle_exclusion" in phases:
    evidence["lifecycle"] = {
        "checks": tsv_rows(
            lifecycle_checks_path,
            ["contract", "selection"],
        ),
    }
with open(output_path, "w", encoding="utf-8") as handle:
    json.dump(evidence, handle, separators=(",", ":"), sort_keys=True)
PY
}

main() {
    parse_args "$@"
    require_inputs
    OBSERVATIONS_FILE="$(secure_temp_file)"
    EXECUTED_SCENARIOS_FILE="$(secure_temp_file)"
    EXECUTED_INVOCATIONS_FILE="$(secure_temp_file)"
    JOB_STATES_FILE="$(secure_temp_file)"
    INVARIANT_SNAPSHOTS_FILE="$(secure_temp_file)"
    LIFECYCLE_CHECKS_FILE="$(secure_temp_file)"
    LIVE_RESERVATION_CHECKS_FILE="$(secure_temp_file)"
    observe_initial_job_state
    phase_requested catalog && exercise_catalog_rows
    phase_requested lifecycle_exclusion && exercise_lifecycle_rows
    observe_terminal_job_state
    write_evidence
}

main "$@"
