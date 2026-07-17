#!/usr/bin/env bash
# thin multi-tenant isolation probe wrapper over seed_synthetic_traffic owners

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

SEED_SYNTHETIC_NO_AUTO_RUN=1
# shellcheck source=seed_synthetic_traffic.sh
source "$SCRIPT_DIR/seed_synthetic_traffic.sh" --tenant A --dry-run

PROBE_ENV="staging"
PROBE_TENANTS_CSV="A,B,C"
PROBE_DURATION_MINUTES=30
PROBE_RESTART_API_ONCE="false"
PROBE_ASSERT_MODE="false"
PROBE_OUTPUT_BASE_DIR=""
PROBE_OUTPUT_DIR=""
PROBE_OUTPUT_WORKSPACE_DIR=""
PROBE_LEGACY_OUTPUT_MODE="false"
PROBE_DRY_RUN="false"
PROBE_CREATED_TENANTS=""

PROBE_WRITES_ATTEMPTED=0
PROBE_RESTART_WINDOW_WRITES_ATTEMPTED=0
PROBE_FAIL_FAST_DURING_WINDOW=0
PROBE_VISIBLE_IN_SEARCH_AFTER=0
PROBE_CROSS_TENANT_LEAKS=0
PROBE_NOISY_NEIGHBOR_VIOLATIONS=0
PROBE_RESTART_WINDOW_START_EPOCH=0
PROBE_RESTART_WINDOW_END_EPOCH=0
PROBE_RESTART_INVOKED="false"
PROBE_WRITES_COUNT_PATH=""
PROBE_VISIBLE_AFTER_COUNT_PATH=""
PROBE_FAIL_FAST_COUNT_PATH=""
PROBE_LEAK_COUNT_PATH=""
PROBE_NOISY_NEIGHBOR_COUNT_PATH=""
PROBE_RUNTIME_COUNTERS_COLLECTED="false"

probe_log() { echo "[multi-tenant-probe] $*"; }
probe_die() { echo "[multi-tenant-probe] ERROR: $*" >&2; exit 1; }

probe_usage() {
  cat <<USAGE
Usage: multi_tenant_isolation_probe.sh [options]
  --env <staging>
  --tenants <A,B,C>
  --duration-minutes <int>
  --restart-api-once
  --assert
  --out <dir>
  --dry-run
USAGE
}

probe_require_value() {
  local flag="$1"
  local value="${2:-}"
  case "$value" in
    ""|--*) probe_die "$flag requires a value" ;;
  esac
}

probe_parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --env)
        probe_require_value "$1" "${2:-}"
        PROBE_ENV="$2"
        shift 2
        ;;
      --tenants)
        probe_require_value "$1" "${2:-}"
        PROBE_TENANTS_CSV="$2"
        shift 2
        ;;
      --duration-minutes)
        probe_require_value "$1" "${2:-}"
        PROBE_DURATION_MINUTES="$2"
        shift 2
        ;;
      --restart-api-once)
        PROBE_RESTART_API_ONCE="true"
        shift
        ;;
      --assert)
        PROBE_ASSERT_MODE="true"
        shift
        ;;
      --out)
        probe_require_value "$1" "${2:-}"
        PROBE_OUTPUT_BASE_DIR="$2"
        PROBE_OUTPUT_DIR="$2"
        shift 2
        ;;
      --dry-run)
        PROBE_DRY_RUN="true"
        shift
        ;;
      --help|-h)
        probe_usage
        exit 0
        ;;
      *)
        probe_die "unknown argument: $1"
        ;;
    esac
  done

  if ! [[ "$PROBE_DURATION_MINUTES" =~ ^[0-9]+$ ]]; then
    probe_die "--duration-minutes must be an integer"
  fi
  case "$PROBE_ENV" in
    staging) ;;
    *) probe_die "--env must be staging for this probe entrypoint" ;;
  esac
  if [ -z "$PROBE_OUTPUT_BASE_DIR" ] && [ -z "$PROBE_OUTPUT_DIR" ]; then
    probe_die "--out is required"
  fi
}

probe_output_base_without_suffix() {
  local out_arg="$1"
  case "$out_arg" in
    *_GREEN) printf '%s' "${out_arg%_GREEN}" ;;
    *_NONGREEN) printf '%s' "${out_arg%_NONGREEN}" ;;
    *) printf '%s' "$out_arg" ;;
  esac
}

probe_output_final_dir_for_verdict() {
  local out_base="$1"
  local verdict="$2"
  printf '%s_%s' "$out_base" "$verdict"
}

probe_prepare_output_workspace() {
  local canonical_base workspace_suffix
  if [ -z "$PROBE_OUTPUT_BASE_DIR" ] && [ -n "$PROBE_OUTPUT_DIR" ]; then
    PROBE_LEGACY_OUTPUT_MODE="true"
    mkdir -p "$PROBE_OUTPUT_DIR"
    return 0
  fi
  PROBE_LEGACY_OUTPUT_MODE="false"
  canonical_base="$(probe_output_base_without_suffix "$PROBE_OUTPUT_BASE_DIR")"
  workspace_suffix="_RUNNING_$(date +%s)_$$"
  PROBE_OUTPUT_WORKSPACE_DIR="${canonical_base}${workspace_suffix}"
  PROBE_OUTPUT_DIR="$PROBE_OUTPUT_WORKSPACE_DIR"
  mkdir -p "$PROBE_OUTPUT_DIR"
}

probe_finalize_output_workspace() {
  local verdict="$1"
  local final_dir canonical_base
  if [ "$PROBE_LEGACY_OUTPUT_MODE" = "true" ]; then
    return 0
  fi
  canonical_base="$(probe_output_base_without_suffix "$PROBE_OUTPUT_BASE_DIR")"
  final_dir="$(probe_output_final_dir_for_verdict "$canonical_base" "$verdict")"
  if [ "$PROBE_OUTPUT_DIR" = "$final_dir" ]; then
    return 0
  fi
  rm -rf "$final_dir"
  mv "$PROBE_OUTPUT_DIR" "$final_dir"
  if [ "$canonical_base" != "$final_dir" ]; then
    if [ -e "$canonical_base" ]; then
      cp -R "$final_dir"/. "$canonical_base"/
    else
      ln -s "$final_dir" "$canonical_base"
    fi
  fi
  PROBE_OUTPUT_DIR="$final_dir"
}

probe_now_epoch() { date +%s; }

probe_silent_drops() {
  local writes="$1"
  local fail_fast="$2"
  local visible="$3"
  local drops
  drops=$((writes - (fail_fast + visible)))
  if [ "$drops" -lt 0 ]; then
    echo 0
  else
    echo "$drops"
  fi
}

probe_silent_drop_writes_scope() {
  if [ "${PROBE_RESTART_WINDOW_WRITES_ATTEMPTED:-0}" -gt 0 ]; then
    printf '%s' "$PROBE_RESTART_WINDOW_WRITES_ATTEMPTED"
  else
    printf '%s' "$PROBE_WRITES_ATTEMPTED"
  fi
}

probe_append_created_tenant() {
  local tenant_letter="$1"
  if [ -z "$PROBE_CREATED_TENANTS" ]; then
    PROBE_CREATED_TENANTS="$tenant_letter"
  else
    PROBE_CREATED_TENANTS="${PROBE_CREATED_TENANTS},${tenant_letter}"
  fi
  probe_write_cleanup_manifest
}

probe_read_count_file() {
  local path="$1"
  if [ -z "$path" ] || [ ! -f "$path" ]; then
    echo 0
    return 0
  fi
  local value
  value="$(tr -dc '0-9\n' < "$path" | tail -n 1)"
  if [ -z "$value" ]; then
    echo 0
    return 0
  fi
  echo "$value"
  return 0
}

probe_call_owner_counter_callback() {
  local callback_name="$1"
  shift
  if ! declare -F "$callback_name" >/dev/null 2>&1; then
    return 2
  fi
  local value
  if ! value="$("$callback_name" "$@" 2>/dev/null)"; then
    return 3
  fi
  case "$value" in
    ''|*[!0-9]*)
      return 4
      ;;
  esac
  printf '%s' "$value"
  return 0
}

probe_cleanup_manifest_json() {
  local tenants_json=""
  if [ -n "$PROBE_CREATED_TENANTS" ]; then
    local old_ifs="$IFS"
    local tenant
    IFS=','
    for tenant in $PROBE_CREATED_TENANTS; do
      if [ -n "$tenants_json" ]; then
        tenants_json="${tenants_json},"
      fi
      tenants_json="${tenants_json}\"${tenant}\""
    done
    IFS="$old_ifs"
  fi
  cat <<JSON
{"created_tenants_this_run":[${tenants_json}],"source":"probe_manifest"}
JSON
}

probe_write_cleanup_manifest() {
  if [ -z "$PROBE_OUTPUT_DIR" ]; then
    return 0
  fi
  mkdir -p "$PROBE_OUTPUT_DIR"
  local cleanup_path="$PROBE_OUTPUT_DIR/cleanup_manifest.json"
  probe_cleanup_manifest_json > "$cleanup_path"
}

probe_record_artifacts() {
  mkdir -p "$PROBE_OUTPUT_DIR"
  local summary_path="$PROBE_OUTPUT_DIR/summary.json"
  local silent_drops
  local writes_attempted_scope
  writes_attempted_scope="$(probe_silent_drop_writes_scope)"
  silent_drops="$(probe_silent_drops "$(probe_silent_drop_writes_scope)" "$PROBE_FAIL_FAST_DURING_WINDOW" "$PROBE_VISIBLE_IN_SEARCH_AFTER")"

  cat > "$summary_path" <<JSON
{"env":"$PROBE_ENV","tenants":"$PROBE_TENANTS_CSV","duration_minutes":$PROBE_DURATION_MINUTES,"dry_run":$([ "$PROBE_DRY_RUN" = "true" ] && echo true || echo false),"assert_mode":$([ "$PROBE_ASSERT_MODE" = "true" ] && echo true || echo false),"restart_invoked":$([ "$PROBE_RESTART_INVOKED" = "true" ] && echo true || echo false),"restart_window_start_epoch":$PROBE_RESTART_WINDOW_START_EPOCH,"restart_window_end_epoch":$PROBE_RESTART_WINDOW_END_EPOCH,"writes_attempted":$writes_attempted_scope,"writes_attempted_total":$PROBE_WRITES_ATTEMPTED,"fail_fast_responses_during_window":$PROBE_FAIL_FAST_DURING_WINDOW,"visible_in_search_after":$PROBE_VISIBLE_IN_SEARCH_AFTER,"silent_drops":$silent_drops,"cross_tenant_leaks":$PROBE_CROSS_TENANT_LEAKS,"noisy_neighbor_violations":$PROBE_NOISY_NEIGHBOR_VIOLATIONS}
JSON

  probe_write_cleanup_manifest

  cat "$summary_path"
}

probe_assertions_pass() {
  if [ "$PROBE_DRY_RUN" != "true" ] && [ "$PROBE_RUNTIME_COUNTERS_COLLECTED" != "true" ]; then
    probe_log "runtime counters were not collected; refusing vacuous assertion pass"
    return 1
  fi
  local silent_drops
  silent_drops="$(probe_silent_drops "$(probe_silent_drop_writes_scope)" "$PROBE_FAIL_FAST_DURING_WINDOW" "$PROBE_VISIBLE_IN_SEARCH_AFTER")"
  [ "$PROBE_CROSS_TENANT_LEAKS" -eq 0 ] || return 1
  [ "$PROBE_NOISY_NEIGHBOR_VIOLATIONS" -eq 0 ] || return 1
  [ "$silent_drops" -eq 0 ] || return 1
  return 0
}

probe_restart_api_once_if_requested() {
  if [ "$PROBE_RESTART_API_ONCE" != "true" ]; then
    return 0
  fi
  PROBE_RESTART_WINDOW_START_EPOCH="$(probe_now_epoch)"
  if [ "$PROBE_DRY_RUN" = "true" ]; then
    PROBE_RESTART_WINDOW_END_EPOCH="$PROBE_RESTART_WINDOW_START_EPOCH"
    return 0
  fi
  "$SCRIPT_DIR/ssm_exec_staging.sh" "sudo systemctl restart fjcloud-api && sleep 10 && systemctl is-active fjcloud-api"
  PROBE_RESTART_WINDOW_END_EPOCH="$(probe_now_epoch)"
  PROBE_RESTART_INVOKED="true"
}

probe_teardown_created_tenants() {
  if [ "$PROBE_DRY_RUN" = "true" ]; then
    return 0
  fi
  if [ -z "$PROBE_CREATED_TENANTS" ]; then
    return 0
  fi

  probe_teardown_tenant_letters "$PROBE_CREATED_TENANTS"
}

probe_teardown_tenant_letters() {
  local tenant_letters_csv="$1"
  if [ -z "$tenant_letters_csv" ]; then
    return 0
  fi

  local old_ifs="$IFS"
  local tenant_letter mapping_path customer_id delete_response delete_status
  IFS=','
  for tenant_letter in $tenant_letters_csv; do
    mapping_path="$(tenant_mapping_path "$tenant_letter")"
    customer_id="$(mapping_field_or_empty "$mapping_path" "customer_id")"
    if [ -z "$customer_id" ]; then
      probe_log "teardown skipped for tenant ${tenant_letter}: missing customer_id in ${mapping_path}"
      continue
    fi
    delete_response="$(admin_call DELETE "/admin/tenants/${customer_id}")"
    delete_status="$(http_response_status "$delete_response")"
    case "$delete_status" in
      200|202|204|404)
        probe_log "teardown processed tenant ${tenant_letter} (customer_id=${customer_id}, status=${delete_status})"
        ;;
      *)
        probe_die "teardown failed for tenant ${tenant_letter} (customer_id=${customer_id}, status=${delete_status}, body=$(http_response_body "$delete_response"))"
        ;;
    esac
  done
  IFS="$old_ifs"
}

probe_manifest_created_tenants_csv() {
  local manifest_path="$PROBE_OUTPUT_DIR/cleanup_manifest.json"
  if [ ! -f "$manifest_path" ]; then
    printf ''
    return 0
  fi

  python3 - "$manifest_path" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except (OSError, json.JSONDecodeError):
    print("")
    raise SystemExit(0)

created = payload.get("created_tenants_this_run")
if not isinstance(created, list):
    print("")
    raise SystemExit(0)

letters = []
for value in created:
    if isinstance(value, str) and value:
        letters.append(value)
print(",".join(letters))
PY
}

probe_clear_manifest_created_tenants() {
  PROBE_CREATED_TENANTS=""
  probe_write_cleanup_manifest
}

probe_consume_startup_cleanup_manifest() {
  if [ "$PROBE_DRY_RUN" = "true" ]; then
    return 0
  fi
  local pending_tenants
  pending_tenants="$(probe_manifest_created_tenants_csv)"
  if [ -z "$pending_tenants" ]; then
    return 0
  fi
  probe_log "consuming startup cleanup manifest tenants: $pending_tenants"
  probe_teardown_tenant_letters "$pending_tenants"
  probe_clear_manifest_created_tenants
}

probe_run() {
  probe_prepare_output_workspace
  if [ "$PROBE_DRY_RUN" = "true" ] && [ "$PROBE_RESTART_API_ONCE" = "true" ]; then
    probe_restart_api_once_if_requested
  fi

  if [ "$PROBE_DRY_RUN" != "true" ]; then
    # Thin ownership seam: call existing seed owners, no duplicated curl/admin logic.
    IFS=, read -r -a tenant_letters <<< "$PROBE_TENANTS_CSV"
    local tenant_count midpoint_after_processed processed_tenants original_write_offset_base
    local write_events_path search_events_path
    tenant_count="${#tenant_letters[@]}"
    midpoint_after_processed=$(((tenant_count + 1) / 2))
    processed_tenants=0
    mkdir -p "$PROBE_OUTPUT_DIR"
    probe_consume_startup_cleanup_manifest
    PROBE_OWNER_COUNTER_DIR="$PROBE_OUTPUT_DIR"
    write_events_path="$PROBE_OUTPUT_DIR/probe_owner_write_events.log"
    search_events_path="$PROBE_OUTPUT_DIR/probe_owner_search_events.log"
    : > "$write_events_path"
    : > "$search_events_path"
    original_write_offset_base="$SUSTAINED_WRITE_OFFSET_BASE"
    if [ -z "$PROBE_WRITES_COUNT_PATH" ]; then
      PROBE_WRITES_COUNT_PATH="$PROBE_OUTPUT_DIR/writes_attempted.count"
    fi
    if [ -z "$PROBE_VISIBLE_AFTER_COUNT_PATH" ]; then
      PROBE_VISIBLE_AFTER_COUNT_PATH="$PROBE_OUTPUT_DIR/visible_in_search_after.count"
    fi
    if [ -z "$PROBE_FAIL_FAST_COUNT_PATH" ]; then
      PROBE_FAIL_FAST_COUNT_PATH="$PROBE_OUTPUT_DIR/fail_fast_during_restart_window.count"
    fi
    if [ -z "$PROBE_LEAK_COUNT_PATH" ]; then
      PROBE_LEAK_COUNT_PATH="$PROBE_OUTPUT_DIR/cross_tenant_leaks.count"
    fi
    if [ -z "$PROBE_NOISY_NEIGHBOR_COUNT_PATH" ]; then
      PROBE_NOISY_NEIGHBOR_COUNT_PATH="$PROBE_OUTPUT_DIR/noisy_neighbor_violations.count"
    fi
    : > "$PROBE_WRITES_COUNT_PATH"
    : > "$PROBE_VISIBLE_AFTER_COUNT_PATH"
    : > "$PROBE_FAIL_FAST_COUNT_PATH"
    : > "$PROBE_LEAK_COUNT_PATH"
    : > "$PROBE_NOISY_NEIGHBOR_COUNT_PATH"
    PROBE_RUNTIME_COUNTERS_COLLECTED="true"

    local total_writes_attempted=0
    local total_restart_window_writes_attempted=0
    local total_visible_in_search_after=0
    local total_fail_fast_during_window=0
    local total_cross_tenant_leaks=0
    local total_noisy_neighbor_violations=0

    PROBE_CREATED_TENANTS=""
    for letter in "${tenant_letters[@]}"; do
      local mapping_path flapjack_url flapjack_uid
      mapping_path="$(tenant_mapping_path "$letter")"
      ENSURE_CUSTOMER_AND_TENANT_CREATED_THIS_CALL="false"
      ensure_customer_and_tenant "$letter"
      flapjack_url="$(mapping_field_or_empty "$mapping_path" "flapjack_url")"
      flapjack_uid="$(mapping_field_or_empty "$mapping_path" "flapjack_uid")"
      [ -n "$flapjack_url" ] || probe_die "missing flapjack_url for tenant ${letter} at ${mapping_path}"
      [ -n "$flapjack_uid" ] || probe_die "missing flapjack_uid for tenant ${letter} at ${mapping_path}"
      if [ "${ENSURE_CUSTOMER_AND_TENANT_CREATED_THIS_CALL:-false}" = "true" ]; then
        probe_append_created_tenant "$letter"
      fi
    done

    for letter in "${tenant_letters[@]}"; do
      local mapping_path flapjack_url flapjack_uid total_writes total_searches
      local tenant_writes_count_path tenant_visible_after_count_path
      local tenant_fail_fast_count_path tenant_leak_count_path tenant_noisy_neighbor_count_path
      local tenant_writes_attempted tenant_restart_window_writes_attempted tenant_visible_after tenant_fail_fast_during_window tenant_cross_tenant_leaks tenant_noisy_neighbor_violations
      local tenant_write_offset_base
      local counter_status
      mapping_path="$(tenant_mapping_path "$letter")"
      flapjack_url="$(mapping_field_or_empty "$mapping_path" "flapjack_url")"
      flapjack_uid="$(mapping_field_or_empty "$mapping_path" "flapjack_uid")"
      [ -n "$flapjack_url" ] || probe_die "missing flapjack_url for tenant ${letter} at ${mapping_path}"
      [ -n "$flapjack_uid" ] || probe_die "missing flapjack_uid for tenant ${letter} at ${mapping_path}"

      total_writes=$(( $(tenant_field "$letter" WRITES_PER_MINUTE) * PROBE_DURATION_MINUTES ))
      total_searches=$(( $(tenant_field "$letter" SEARCHES_PER_MINUTE) * PROBE_DURATION_MINUTES ))
      tenant_write_offset_base=$((original_write_offset_base + (processed_tenants * 1000000)))
      SUSTAINED_WRITE_OFFSET_BASE="$tenant_write_offset_base"
      printf '%s\n' "$tenant_write_offset_base" > "$PROBE_OUTPUT_DIR/${letter}_write_offset_base.count"
      tenant_writes_count_path="$PROBE_OUTPUT_DIR/${letter}_writes_attempted.count"
      tenant_visible_after_count_path="$PROBE_OUTPUT_DIR/${letter}_visible_in_search_after.count"
      tenant_fail_fast_count_path="$PROBE_OUTPUT_DIR/${letter}_fail_fast_during_restart_window.count"
      tenant_leak_count_path="$PROBE_OUTPUT_DIR/${letter}_cross_tenant_leaks.count"
      tenant_noisy_neighbor_count_path="$PROBE_OUTPUT_DIR/${letter}_noisy_neighbor_violations.count"
      : > "$tenant_writes_count_path"
      : > "$tenant_visible_after_count_path"
      : > "$tenant_fail_fast_count_path"
      : > "$tenant_leak_count_path"
      : > "$tenant_noisy_neighbor_count_path"

      PROBE_ACTIVE_TENANT_LETTER="$letter"
      if [ "$PROBE_RESTART_API_ONCE" = "true" ] \
        && [ "$PROBE_RESTART_INVOKED" != "true" ] \
        && [ $((processed_tenants + 1)) -eq "$midpoint_after_processed" ]; then
        run_direct_write_loop "$flapjack_url" "$flapjack_uid" "$total_writes" 0 "$tenant_writes_count_path" &
        local write_loop_pid
        local write_loop_status
        local fail_fast_count_status
        local fail_fast_count_after_wait
        write_loop_pid="$!"
        sleep 1
        probe_restart_api_once_if_requested
        # The backgrounded write loop runs straight through the API restart window,
        # where transient errors are expected. A non-zero exit here must NOT abort
        # the probe (set -e would otherwise kill it before assertion evaluation) —
        # but only if in-window fail-fast evidence is actually present for the
        # tenant. Unexpected early exits (no in-window fail-fast evidence) are
        # still hard failures because they can leave counters unset.
        if wait "$write_loop_pid"; then
          :
        else
          write_loop_status=$?
          fail_fast_count_status=0
          fail_fast_count_after_wait="$(probe_call_owner_counter_callback probe_owner_fail_fast_during_restart_window_count "$flapjack_url" "$flapjack_uid" "$PROBE_RESTART_WINDOW_START_EPOCH" "$PROBE_RESTART_WINDOW_END_EPOCH" "$letter")" || fail_fast_count_status=$?
          if [ "$fail_fast_count_status" -eq 0 ] && [ "${fail_fast_count_after_wait:-0}" -gt 0 ]; then
            probe_log "restart-window write loop (pid=${write_loop_pid}) exited non-zero; observed in-window fail-fast events=${fail_fast_count_after_wait}, continuing to assertion evaluation"
          else
            probe_die "restart-window write loop (pid=${write_loop_pid}) exited unexpectedly (status=${write_loop_status}); no in-window fail-fast evidence to justify continuation"
          fi
        fi
      else
        run_direct_write_loop "$flapjack_url" "$flapjack_uid" "$total_writes" 0 "$tenant_writes_count_path"
      fi
      run_direct_search_loop "$flapjack_url" "$flapjack_uid" "$total_searches" 0 "$tenant_visible_after_count_path"
      unset PROBE_ACTIVE_TENANT_LETTER
      node_api_key_for_url "$flapjack_url" >/dev/null

      tenant_writes_attempted="$(probe_read_count_file "$tenant_writes_count_path")"
      counter_status=0
      tenant_restart_window_writes_attempted="$(probe_call_owner_counter_callback probe_owner_writes_attempted_during_restart_window_count "$flapjack_url" "$flapjack_uid" "$PROBE_RESTART_WINDOW_START_EPOCH" "$PROBE_RESTART_WINDOW_END_EPOCH" "$letter")" || counter_status=$?
      if [ "$counter_status" -ne 0 ]; then
        PROBE_RUNTIME_COUNTERS_COLLECTED="false"
        probe_log "owner restart-window writes counter callback missing/invalid for tenant ${letter}; status=${counter_status}; falling back to tenant writes attempted"
        tenant_restart_window_writes_attempted="$tenant_writes_attempted"
      fi
      counter_status=0
      tenant_visible_after="$(probe_call_owner_counter_callback probe_owner_visible_in_search_after_count "$flapjack_url" "$flapjack_uid" "$PROBE_RESTART_WINDOW_START_EPOCH" "$PROBE_RESTART_WINDOW_END_EPOCH" "$letter")" || counter_status=$?
      if [ "$counter_status" -ne 0 ]; then
        PROBE_RUNTIME_COUNTERS_COLLECTED="false"
        probe_log "owner visibility-after counter callback missing/invalid for tenant ${letter}; status=${counter_status}; falling back to search-loop count"
        tenant_visible_after="$(probe_read_count_file "$tenant_visible_after_count_path")"
      fi
      counter_status=0
      tenant_fail_fast_during_window="$(probe_call_owner_counter_callback probe_owner_fail_fast_during_restart_window_count "$flapjack_url" "$flapjack_uid" "$PROBE_RESTART_WINDOW_START_EPOCH" "$PROBE_RESTART_WINDOW_END_EPOCH" "$letter")" || counter_status=$?
      if [ "$counter_status" -ne 0 ]; then
        PROBE_RUNTIME_COUNTERS_COLLECTED="false"
        probe_log "owner fail-fast counter callback missing/invalid for tenant ${letter}; status=${counter_status}"
        tenant_fail_fast_during_window=0
      fi
      counter_status=0
      tenant_cross_tenant_leaks="$(probe_call_owner_counter_callback probe_owner_cross_tenant_leak_count "$flapjack_url" "$flapjack_uid" "$letter")" || counter_status=$?
      if [ "$counter_status" -ne 0 ]; then
        PROBE_RUNTIME_COUNTERS_COLLECTED="false"
        probe_log "owner leak counter callback missing/invalid for tenant ${letter}; status=${counter_status}"
        tenant_cross_tenant_leaks=0
      fi
      counter_status=0
      tenant_noisy_neighbor_violations="$(probe_call_owner_counter_callback probe_owner_noisy_neighbor_violation_count "$flapjack_url" "$flapjack_uid" "$letter")" || counter_status=$?
      if [ "$counter_status" -ne 0 ]; then
        PROBE_RUNTIME_COUNTERS_COLLECTED="false"
        probe_log "owner noisy-neighbor counter callback missing/invalid for tenant ${letter}; status=${counter_status}"
        tenant_noisy_neighbor_violations=0
      fi

      total_writes_attempted=$((total_writes_attempted + tenant_writes_attempted))
      total_restart_window_writes_attempted=$((total_restart_window_writes_attempted + tenant_restart_window_writes_attempted))
      total_visible_in_search_after=$((total_visible_in_search_after + tenant_visible_after))
      total_fail_fast_during_window=$((total_fail_fast_during_window + tenant_fail_fast_during_window))
      total_cross_tenant_leaks=$((total_cross_tenant_leaks + tenant_cross_tenant_leaks))
      total_noisy_neighbor_violations=$((total_noisy_neighbor_violations + tenant_noisy_neighbor_violations))

      processed_tenants=$((processed_tenants + 1))
    done
    SUSTAINED_WRITE_OFFSET_BASE="$original_write_offset_base"

    if [ "$PROBE_RESTART_API_ONCE" = "true" ] && [ "$PROBE_RESTART_INVOKED" != "true" ]; then
      probe_restart_api_once_if_requested
    fi

    PROBE_WRITES_ATTEMPTED="$total_writes_attempted"
    PROBE_RESTART_WINDOW_WRITES_ATTEMPTED="$total_restart_window_writes_attempted"
    PROBE_VISIBLE_IN_SEARCH_AFTER="$total_visible_in_search_after"
    PROBE_FAIL_FAST_DURING_WINDOW="$total_fail_fast_during_window"
    PROBE_CROSS_TENANT_LEAKS="$total_cross_tenant_leaks"
    PROBE_NOISY_NEIGHBOR_VIOLATIONS="$total_noisy_neighbor_violations"
    printf '%s' "$PROBE_WRITES_ATTEMPTED" > "$PROBE_WRITES_COUNT_PATH"
    printf '%s' "$PROBE_VISIBLE_IN_SEARCH_AFTER" > "$PROBE_VISIBLE_AFTER_COUNT_PATH"
    printf '%s' "$PROBE_FAIL_FAST_DURING_WINDOW" > "$PROBE_FAIL_FAST_COUNT_PATH"
    printf '%s' "$PROBE_CROSS_TENANT_LEAKS" > "$PROBE_LEAK_COUNT_PATH"
    printf '%s' "$PROBE_NOISY_NEIGHBOR_VIOLATIONS" > "$PROBE_NOISY_NEIGHBOR_COUNT_PATH"
    if ! declare -F probe_owner_writes_attempted_during_restart_window_count >/dev/null 2>&1 \
      || ! declare -F probe_owner_visible_in_search_after_count >/dev/null 2>&1 \
      || ! declare -F probe_owner_fail_fast_during_restart_window_count >/dev/null 2>&1 \
      || ! declare -F probe_owner_cross_tenant_leak_count >/dev/null 2>&1 \
      || ! declare -F probe_owner_noisy_neighbor_violation_count >/dev/null 2>&1; then
      PROBE_RUNTIME_COUNTERS_COLLECTED="false"
    fi
    admin_call GET "/admin/tenants" >/dev/null
    probe_teardown_created_tenants
  fi

  local run_verdict="GREEN"
  probe_record_artifacts
  if [ "$PROBE_ASSERT_MODE" = "true" ] && ! probe_assertions_pass; then
    run_verdict="NONGREEN"
  fi
  probe_record_artifacts
  probe_finalize_output_workspace "$run_verdict"
  if [ "$run_verdict" = "NONGREEN" ]; then
    return 1
  fi
  return 0
}

if [ -n "${MULTI_TENANT_ISOLATION_PROBE_NO_AUTO_RUN:-}" ]; then
  return 0 2>/dev/null || exit 0
fi

probe_parse_args "$@"
probe_run
