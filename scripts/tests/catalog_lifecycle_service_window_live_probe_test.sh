#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/catalog_lifecycle_service_window_live_probe.sh"
DEFAULT_INVENTORY="$REPO_ROOT/scripts/tests/fixtures/catalog_lifecycle_writers.json"
DEFAULT_ORACLE="$REPO_ROOT/scripts/tests/fixtures/catalog_lifecycle_acceptance_oracles.json"

# shellcheck source=scripts/tests/lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=scripts/tests/lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=scripts/tests/lib/test_helpers.sh
source "$SCRIPT_DIR/lib/test_helpers.sh"
# shellcheck source=scripts/tests/lib/integration_up_mocks.sh
source "$SCRIPT_DIR/lib/integration_up_mocks.sh"

WORK_DIR=""
RUN_STDOUT=""
RUN_EXIT_CODE=0
COPIED_PROBE_ROOT=""
SELECTED_ROUTE_WRITER="catalog_writer__infra_api_src_routes_indexes_lifecycle__delete_index__flapjack_proxy_delete_index"
SELECTED_SERVICE_WRITER="catalog_writer__infra_api_src_services_replica__create_replica__replica_repo_create"
SELECTED_SOFT_DELETE_REPO_WRITER="catalog_writer__infra_api_src_repos_pg_customer_repo_lifecycle__soft_delete__pg_customer_repo_soft_delete"
SELECTED_SOFT_DELETE_ACCOUNT_WRITER="catalog_writer__infra_api_src_routes_account__delete_account__customer_repo_soft_delete"
SELECTED_SOFT_DELETE_ADMIN_WRITER="catalog_writer__infra_api_src_routes_admin_tenants__delete_tenant__customer_repo_soft_delete"
SELECTED_HARD_ERASE_WRITER="catalog_writer__infra_api_src_routes_admin_tenants__hard_erase_customer__customer_repo_hard_delete"
HARD_ERASE_CUSTOMER_ID="dddddddd-dddd-dddd-dddd-dddddddddd04"
HARD_ERASE_CASE_NAMES=(
  committed
  ambiguous
  pre_linkage
  cancelling
  cancelled_before_ack
  failed_resumable_with_lease
  credential_accepted_before_socket
  resuming
  resume_deadline_race
  local_no_dispatch
  seal_tombstone
  ambiguous_publication
)

cleanup() {
  if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

write_mock_binaries() {
  mkdir -p "$WORK_DIR/target/debug" "$WORK_DIR/flapjack-src/target/debug"
  write_mock_script "$WORK_DIR/target/debug/fjcloud-api" 'exit 0'
  write_mock_script "$WORK_DIR/flapjack-src/target/debug/flapjack" 'exit 0'
  ln -s "$WORK_DIR/target/debug/fjcloud-api" "$WORK_DIR/bin/api"
  ln -s "$WORK_DIR/flapjack-src/target/debug/flapjack" "$WORK_DIR/bin/flapjack"
  printf '%s\n' "$WORK_DIR/target/debug/fjcloud-api" > "$WORK_DIR/source_api_binary"
  printf '%s\n' "$WORK_DIR/flapjack-src/target/debug/flapjack" > "$WORK_DIR/source_engine_binary"
  write_mock_script "$WORK_DIR/bin/docker" '
set -euo pipefail
printf "DOCKER %s\n" "$*" >> "$CATALOG_SERVICE_WINDOW_DOCKER_LOG"
if [[ "$*" == "compose ps --status running postgres" ]]; then
  exit 0
fi
if [[ "$*" == *"compose exec -T postgres"* ]]; then
  stdin_payload="$(cat)"
  printf "DOCKER_STDIN %s\n" "$stdin_payload" >> "$CATALOG_SERVICE_WINDOW_DOCKER_LOG"
  if [[ "$stdin_payload" == *"catalog_service_window_cold_seed"* ]]; then
    echo "seeded"
  fi
  if [[ "$stdin_payload" == *"catalog_service_window_expired_worker_claim_seed"* ]]; then
    echo "seeded"
  fi
  if [[ "$stdin_payload" == *"catalog_service_window_expired_worker_claim_snapshot"* ]]; then
    cat "$CATALOG_SERVICE_WINDOW_EXPIRED_SNAPSHOT_GOOD"
  fi
  if [[ "$stdin_payload" == *"catalog_service_window_soft_delete_seed"* ]]; then
    echo "seeded"
  fi
  if [[ "$stdin_payload" == *"catalog_service_window_soft_delete_snapshot:account"* ]]; then
    sd_phase="$(grep -c "catalog_service_window_soft_delete_snapshot:account" "$CATALOG_SERVICE_WINDOW_DOCKER_LOG" || true)"
    CATALOG_SD_ARM=account CATALOG_SD_PHASE="${sd_phase:-0}" python3 "$CATALOG_SERVICE_WINDOW_SOFT_DELETE_SNAPSHOT_PY"
  fi
  if [[ "$stdin_payload" == *"catalog_service_window_soft_delete_snapshot:admin"* ]]; then
    sd_phase="$(grep -c "catalog_service_window_soft_delete_snapshot:admin" "$CATALOG_SERVICE_WINDOW_DOCKER_LOG" || true)"
    CATALOG_SD_ARM=admin CATALOG_SD_PHASE="${sd_phase:-0}" python3 "$CATALOG_SERVICE_WINDOW_SOFT_DELETE_SNAPSHOT_PY"
  fi
  if [[ "$stdin_payload" == *"catalog_service_window_soft_delete_stale_matrix_seed"* ]]; then
    echo "seeded"
  fi
  if [[ "$stdin_payload" == *"catalog_service_window_soft_delete_stale_matrix_snapshot"* ]]; then
    CATALOG_STALE_PHASE="$(grep -c "catalog_service_window_soft_delete_stale_matrix_snapshot" "$CATALOG_SERVICE_WINDOW_DOCKER_LOG" || true)" \
      python3 "$CATALOG_SERVICE_WINDOW_STALE_MATRIX_PY"
  fi
  if [[ "$stdin_payload" == *"catalog_service_window_soft_delete_stale_matrix_repo_probe"* ]]; then
    CATALOG_STALE_REPO_PROBE=1 python3 "$CATALOG_SERVICE_WINDOW_STALE_MATRIX_PY"
  fi
  if [[ "$stdin_payload" == *"catalog_service_window_hard_erase_matrix_seed"* ]]; then
    CATALOG_HARD_ERASE_MODE=seed python3 "$CATALOG_SERVICE_WINDOW_HARD_ERASE_MATRIX_PY"
  fi
  if [[ "$stdin_payload" == *"catalog_service_window_hard_erase_matrix_clock"* ]]; then
    CATALOG_HARD_ERASE_MODE=clock \
      CATALOG_HARD_ERASE_PHASE="$(grep -c "catalog_service_window_hard_erase_matrix_clock" "$CATALOG_SERVICE_WINDOW_DOCKER_LOG" || true)" \
      python3 "$CATALOG_SERVICE_WINDOW_HARD_ERASE_MATRIX_PY"
  fi
  if [[ "$stdin_payload" == *"catalog_service_window_hard_erase_matrix_snapshot"* ]]; then
    CATALOG_HARD_ERASE_MODE=snapshot python3 "$CATALOG_SERVICE_WINDOW_HARD_ERASE_MATRIX_PY"
  fi
  exit 0
fi
exit 1
'
  write_mock_script "$WORK_DIR/bin/cargo" '
mkdir -p "$(pwd)/target/debug"
cat > "$(pwd)/target/debug/fj-metering-agent" <<'\''METERING'\''
#!/usr/bin/env bash
exit 0
METERING
chmod +x "$(pwd)/target/debug/fj-metering-agent"
exit 0
'
  write_mock_script "$WORK_DIR/bin/psql" '
stdin_payload="$(cat)"
printf "PSQL %s\n%s\n" "$*" "$stdin_payload" >> "$CATALOG_SERVICE_WINDOW_PSQL_LOG"
printf "PSQL %s\n%s\n" "$*" "$stdin_payload" >> "$CATALOG_SERVICE_WINDOW_EVENT_LOG"
if [[ "$*" == *"SELECT 1 FROM pg_database"* ]]; then
  echo "1"
fi
if [[ "$stdin_payload" == *"catalog_service_window_cold_seed"* ]]; then
  echo "seeded"
fi
if [[ "$stdin_payload" == *"catalog_service_window_expired_worker_claim_seed"* ]]; then
  if [ "${CATALOG_SERVICE_WINDOW_EXPIRED_OMIT_LEASE:-0}" = "1" ]; then
    echo "missing_expired_worker_claim_lease"
  elif [ "${CATALOG_SERVICE_WINDOW_EXPIRED_LEASE_NOT_EXPIRED:-0}" = "1" ]; then
    echo "expired_worker_claim_lease_not_elapsed"
  else
    echo "seeded"
  fi
fi
if [[ "$stdin_payload" == *"catalog_service_window_expired_worker_claim_snapshot"* ]]; then
  if [ "${CATALOG_SERVICE_WINDOW_EXPIRED_OMIT_ACTIVE_RESERVATION:-0}" = "1" ]; then
    cat "$CATALOG_SERVICE_WINDOW_EXPIRED_SNAPSHOT_MISSING_RESERVATION"
  elif [ "${CATALOG_SERVICE_WINDOW_EXPIRED_MUTATE_SNAPSHOT:-0}" = "1" ]; then
    cat "$CATALOG_SERVICE_WINDOW_EXPIRED_SNAPSHOT_MUTATED"
  elif [ "${CATALOG_SERVICE_WINDOW_EXPIRED_OMIT_LEASE:-0}" = "1" ]; then
    cat "$CATALOG_SERVICE_WINDOW_EXPIRED_SNAPSHOT_INVALID_LEASE"
  elif [ "${CATALOG_SERVICE_WINDOW_EXPIRED_LEASE_NOT_EXPIRED:-0}" = "1" ]; then
    cat "$CATALOG_SERVICE_WINDOW_EXPIRED_SNAPSHOT_INVALID_LEASE"
  else
    cat "$CATALOG_SERVICE_WINDOW_EXPIRED_SNAPSHOT_GOOD"
  fi
fi
if [[ "$stdin_payload" == *"catalog_service_window_soft_delete_seed"* ]]; then
  echo "seeded"
fi
if [[ "$stdin_payload" == *"catalog_service_window_soft_delete_snapshot:account"* ]]; then
  sd_phase="$(grep -c "catalog_service_window_soft_delete_snapshot:account" "$CATALOG_SERVICE_WINDOW_PSQL_LOG" || true)"
  CATALOG_SD_ARM=account CATALOG_SD_PHASE="${sd_phase:-0}" python3 "$CATALOG_SERVICE_WINDOW_SOFT_DELETE_SNAPSHOT_PY"
fi
if [[ "$stdin_payload" == *"catalog_service_window_soft_delete_snapshot:admin"* ]]; then
  sd_phase="$(grep -c "catalog_service_window_soft_delete_snapshot:admin" "$CATALOG_SERVICE_WINDOW_PSQL_LOG" || true)"
  CATALOG_SD_ARM=admin CATALOG_SD_PHASE="${sd_phase:-0}" python3 "$CATALOG_SERVICE_WINDOW_SOFT_DELETE_SNAPSHOT_PY"
fi
if [[ "$stdin_payload" == *"catalog_service_window_soft_delete_stale_matrix_seed"* ]]; then
  echo "seeded"
fi
if [[ "$stdin_payload" == *"catalog_service_window_soft_delete_stale_matrix_snapshot"* ]]; then
  CATALOG_STALE_PHASE="$(grep -c "catalog_service_window_soft_delete_stale_matrix_snapshot" "$CATALOG_SERVICE_WINDOW_PSQL_LOG" || true)" \
    python3 "$CATALOG_SERVICE_WINDOW_STALE_MATRIX_PY"
fi
if [[ "$stdin_payload" == *"catalog_service_window_soft_delete_stale_matrix_repo_probe"* ]]; then
  CATALOG_STALE_REPO_PROBE=1 python3 "$CATALOG_SERVICE_WINDOW_STALE_MATRIX_PY"
fi
if [[ "$stdin_payload" == *"catalog_service_window_hard_erase_matrix_seed"* ]]; then
  CATALOG_HARD_ERASE_MODE=seed python3 "$CATALOG_SERVICE_WINDOW_HARD_ERASE_MATRIX_PY"
fi
if [[ "$stdin_payload" == *"catalog_service_window_hard_erase_matrix_clock"* ]]; then
  CATALOG_HARD_ERASE_MODE=clock \
    CATALOG_HARD_ERASE_PHASE="$(grep -c "catalog_service_window_hard_erase_matrix_clock" "$CATALOG_SERVICE_WINDOW_PSQL_LOG" || true)" \
    python3 "$CATALOG_SERVICE_WINDOW_HARD_ERASE_MATRIX_PY"
fi
if [[ "$stdin_payload" == *"catalog_service_window_hard_erase_matrix_snapshot"* ]]; then
  CATALOG_HARD_ERASE_MODE=snapshot python3 "$CATALOG_SERVICE_WINDOW_HARD_ERASE_MATRIX_PY"
fi
exit 0
'
  write_mock_script "$WORK_DIR/bin/nohup" '
printf "ENV:%s\n" "${ENGINE_INDEX_IDENTITY_PROBE_RECOVERY_SEAMS:-unset}" >> "$CATALOG_SERVICE_WINDOW_NOHUP_LOG"
printf "%s\n" "$*" >> "$CATALOG_SERVICE_WINDOW_NOHUP_LOG"
"$@" >/dev/null 2>&1 || true
exit 0
'
}

write_mock_curl() {
  write_mock_script "$WORK_DIR/bin/curl" '
set -euo pipefail
printf "%s\n" "$*" >> "$CATALOG_SERVICE_WINDOW_CURL_LOG"
printf "CURL %s\n" "$*" >> "$CATALOG_SERVICE_WINDOW_EVENT_LOG"
url="${*: -1}"
case "$url" in
  *"/health")
    exit 0
    ;;
  *"/auth/register")
    if [[ "$*" == *"hard-erase"* ]]; then
      if [ "${CATALOG_SERVICE_WINDOW_EXISTING_STATE:-0}" = "1" ]; then
        printf "{\"error\":\"account_exists\"}\n409"
      else
        printf "{\"token\":\"hard-erase-token\",\"customer_id\":\"dddddddd-dddd-dddd-dddd-dddddddddd04\"}\n201"
      fi
    elif [[ "$*" == *"soft-delete-account"* ]]; then
      if [ "${CATALOG_SERVICE_WINDOW_EXISTING_STATE:-0}" = "1" ]; then
        printf "{\"error\":\"account_exists\"}\n409"
      else
        printf "{\"token\":\"soft-delete-account-token\",\"customer_id\":\"dddddddd-dddd-dddd-dddd-dddddddddda1\"}\n201"
      fi
    elif [[ "$*" == *"soft-delete-admin"* ]]; then
      if [ "${CATALOG_SERVICE_WINDOW_EXISTING_STATE:-0}" = "1" ]; then
        printf "{\"error\":\"account_exists\"}\n409"
      else
        printf "{\"token\":\"soft-delete-admin-token\",\"customer_id\":\"dddddddd-dddd-dddd-dddd-dddddddddda2\"}\n201"
      fi
    elif [[ "$*" == *"soft-delete-stale"* ]]; then
      if [ "${CATALOG_SERVICE_WINDOW_EXISTING_STATE:-0}" = "1" ]; then
        printf "{\"error\":\"account_exists\"}\n409"
      else
        printf "{\"token\":\"soft-delete-stale-token\",\"customer_id\":\"dddddddd-dddd-dddd-dddd-dddddddddda3\"}\n201"
      fi
    elif [[ "$*" == *"service-window-isolation"* ]]; then
      if [ "${CATALOG_SERVICE_WINDOW_EXISTING_STATE:-0}" = "1" ]; then
        printf "{\"error\":\"account_exists\"}\n409"
      else
        printf "{\"token\":\"isolation-register-token\",\"customer_id\":\"33333333-3333-3333-3333-333333333333\"}\n201"
      fi
    else
      if [ "${CATALOG_SERVICE_WINDOW_EXISTING_STATE:-0}" = "1" ]; then
        printf "{\"error\":\"account_exists\"}\n409"
      else
        printf "{\"token\":\"register-token\",\"customer_id\":\"11111111-1111-1111-1111-111111111111\"}\n201"
      fi
    fi
    ;;
  *"/auth/login")
    if [[ "$*" == *"hard-erase"* ]]; then
      printf "{\"token\":\"hard-erase-token\",\"customer_id\":\"dddddddd-dddd-dddd-dddd-dddddddddd04\"}\n200"
    elif [[ "$*" == *"soft-delete-account"* ]]; then
      printf "{\"token\":\"soft-delete-account-token\",\"customer_id\":\"dddddddd-dddd-dddd-dddd-dddddddddda1\"}\n200"
    elif [[ "$*" == *"soft-delete-admin"* ]]; then
      printf "{\"token\":\"soft-delete-admin-token\",\"customer_id\":\"dddddddd-dddd-dddd-dddd-dddddddddda2\"}\n200"
    elif [[ "$*" == *"soft-delete-stale"* ]]; then
      printf "{\"token\":\"soft-delete-stale-token\",\"customer_id\":\"dddddddd-dddd-dddd-dddd-dddddddddda3\"}\n200"
    elif [[ "$*" == *"service-window-isolation"* ]]; then
      printf "{\"token\":\"isolation-login-token\",\"customer_id\":\"33333333-3333-3333-3333-333333333333\"}\n200"
    else
      printf "{\"token\":\"login-token\",\"customer_id\":\"11111111-1111-1111-1111-111111111111\"}\n200"
    fi
    ;;
  *"/indexes/catalog_service_window_source/replicas")
    if [[ "$*" == *"-X POST"* ]]; then
      printf "{\"id\":\"22222222-2222-2222-2222-222222222222\",\"status\":\"provisioning\"}\n201"
    elif [ "${CATALOG_SERVICE_WINDOW_EMPTY_ROW_EVIDENCE:-0}" = "1" ]; then
      printf "[]\n200"
    else
      printf "[{\"id\":\"22222222-2222-2222-2222-222222222222\",\"replica_region\":\"eu-central-1\",\"status\":\"provisioning\"}]\n200"
    fi
    ;;
  *"/indexes/catalog_service_window_source_expired_claim/replicas")
    if [ "${CATALOG_SERVICE_WINDOW_EXPIRED_ENGINE_CALL:-0}" = "1" ]; then
      printf "CURL -sS -X DELETE http://127.0.0.1:${FLAPJACK_PORT:-37801}/1/indexes/catalog_service_window_source_expired_claim\n" >> "$CATALOG_SERVICE_WINDOW_EVENT_LOG"
      printf "%s\n" "{\"status\":\"observed\",\"callers\":[{\"caller_id\":\"routes.indexes.lifecycle.delete_index\",\"observed_upstream_kind\":\"physical_uid\"}],\"checks\":{\"identity\":\"checked\",\"auth\":\"checked\",\"status\":\"checked\"}}" > "$ENGINE_INDEX_IDENTITY_OBSERVED_CALLERS_FILE"
    fi
    if [ "${CATALOG_SERVICE_WINDOW_EXPIRED_DESTINATION_CHANGED:-0}" = "1" ]; then
      printf "{\"error\":\"destination_changed\"}\n409"
    else
      printf "{\"error\":\"destination_conflict\"}\n409"
    fi
    ;;
  *"/indexes/catalog_service_window_source_expired_claim")
    if [[ "$*" == *"-X DELETE"* ]]; then
      if [ "${CATALOG_SERVICE_WINDOW_EXPIRED_ENGINE_CALL:-0}" = "1" ]; then
        printf "CURL -sS -X DELETE http://127.0.0.1:${FLAPJACK_PORT:-37801}/1/indexes/catalog_service_window_source_expired_claim\n" >> "$CATALOG_SERVICE_WINDOW_EVENT_LOG"
        printf "%s\n" "{\"status\":\"observed\",\"callers\":[{\"caller_id\":\"routes.indexes.lifecycle.delete_index\",\"observed_upstream_kind\":\"physical_uid\"}],\"checks\":{\"identity\":\"checked\",\"auth\":\"checked\",\"status\":\"checked\"}}" > "$ENGINE_INDEX_IDENTITY_OBSERVED_CALLERS_FILE"
      fi
      if [ "${CATALOG_SERVICE_WINDOW_EXPIRED_DESTINATION_CHANGED:-0}" = "1" ]; then
        printf "{\"error\":\"destination_changed\"}\n409"
      else
        printf "{\"error\":\"destination_conflict\"}\n409"
      fi
    else
      printf "{\"name\":\"catalog_service_window_source_expired_claim\",\"status\":\"ready\",\"entries\":0}\n200"
    fi
    ;;
  *"/indexes/catalog_service_window_source/restore")
    if [ "${CATALOG_SERVICE_WINDOW_RESTORE_CONFLICTS:-0}" = "1" ]; then
      printf "{\"error\":\"destination_conflict\"}\n409"
    else
      printf "{\"restore_job_id\":\"44444444-4444-4444-4444-444444444444\",\"status\":\"queued\",\"poll_url\":\"/indexes/catalog_service_window_source/restore-status\"}\n202"
    fi
    ;;
  *"/indexes/catalog_service_window_source/batch")
    printf "{\"taskID\":1,\"objectIDs\":[\"catalog-service-window-doc-1\"]}\n200"
    ;;
  *"/indexes/catalog_service_window_source_migration/batch")
    printf "{\"taskID\":2,\"objectIDs\":[\"catalog-service-window-doc-1\"]}\n200"
    ;;
  *"/indexes/catalog_service_window_source")
    if [[ "$*" == *"-X GET"* ]]; then
      count="$(grep -c -- "-X GET .*\/indexes\/catalog_service_window_source$" "$CATALOG_SERVICE_WINDOW_CURL_LOG" || true)"
      if [ "${CATALOG_SERVICE_WINDOW_MUTATE_UNRELATED:-0}" = "1" ] && [ "$count" -gt 1 ]; then
        printf "{\"name\":\"catalog_service_window_source\",\"status\":\"ready\",\"entries\":99}\n200"
      else
        printf "{\"name\":\"catalog_service_window_source\",\"status\":\"ready\",\"entries\":0}\n200"
      fi
    else
      printf "{}\n204"
    fi
    ;;
  *"/indexes")
    if [[ "$*" == *"authorization: Bearer isolation-login-token"* ]] && [ "${CATALOG_SERVICE_WINDOW_EXISTING_STATE:-0}" = "1" ]; then
      printf "{\"error\":\"index_exists\"}\n409"
    elif [[ "$*" == *"catalog_service_window_source_expired_claim"* ]]; then
      if [ "${CATALOG_SERVICE_WINDOW_EXPIRED_ENGINE_CALL:-0}" = "1" ]; then
        printf "CURL -sS -X POST http://127.0.0.1:${FLAPJACK_PORT:-37801}/1/indexes/catalog_service_window_source_expired_claim\n" >> "$CATALOG_SERVICE_WINDOW_EVENT_LOG"
        printf "%s\n" "{\"status\":\"observed\",\"callers\":[{\"caller_id\":\"routes.indexes.lifecycle.create_index\",\"observed_upstream_kind\":\"physical_uid\"}],\"checks\":{\"identity\":\"checked\",\"auth\":\"checked\",\"status\":\"checked\"}}" > "$ENGINE_INDEX_IDENTITY_OBSERVED_CALLERS_FILE"
      fi
      if [ "${CATALOG_SERVICE_WINDOW_EXPIRED_DESTINATION_CHANGED:-0}" = "1" ]; then
        printf "{\"error\":\"destination_changed\"}\n409"
      else
        printf "{\"error\":\"destination_conflict\"}\n409"
      fi
    else
      printf "{}\n201"
    fi
    ;;
  *"/admin/tenants/11111111-1111-1111-1111-111111111111/indexes")
    flapjack_port="${FLAPJACK_PORT:-7801}"
    printf "{\"name\":\"catalog_service_window_destination_seed\",\"region\":\"eu-central-1\",\"status\":\"healthy\",\"endpoint\":\"http://127.0.0.1:%s\"}\n201" "$flapjack_port"
    ;;
  *"/admin/vms")
    flapjack_port="${FLAPJACK_PORT:-7801}"
    printf "[{\"id\":\"00000000-0000-0000-0000-000000000002\",\"region\":\"eu-central-1\",\"flapjack_url\":\"http://127.0.0.1:%s\",\"hostname\":\"local-dev-eu-central-1\"}]\n200" "$flapjack_port"
    ;;
  *"/admin/cold")
    if [ "${CATALOG_SERVICE_WINDOW_UNRELATED_COLD_FIRST:-0}" = "1" ]; then
      printf "[{\"snapshot_id\":\"99999999-9999-9999-9999-999999999999\",\"customer_id\":\"33333333-3333-3333-3333-333333333333\",\"tenant_id\":\"catalog_service_window_source\",\"status\":\"completed\"},{\"snapshot_id\":\"55555555-5555-5555-5555-555555555555\",\"customer_id\":\"11111111-1111-1111-1111-111111111111\",\"tenant_id\":\"catalog_service_window_source\",\"status\":\"completed\"},{\"snapshot_id\":\"77777777-7777-7777-7777-777777777777\",\"customer_id\":\"11111111-1111-1111-1111-111111111111\",\"tenant_id\":\"catalog_service_window_source_admin_restore\",\"status\":\"completed\"}]\n200"
    else
      printf "[{\"snapshot_id\":\"55555555-5555-5555-5555-555555555555\",\"customer_id\":\"11111111-1111-1111-1111-111111111111\",\"tenant_id\":\"catalog_service_window_source\",\"status\":\"completed\"},{\"snapshot_id\":\"77777777-7777-7777-7777-777777777777\",\"customer_id\":\"11111111-1111-1111-1111-111111111111\",\"tenant_id\":\"catalog_service_window_source_admin_restore\",\"status\":\"completed\"}]\n200"
    fi
    ;;
  *"/admin/cold/55555555-5555-5555-5555-555555555555/restore")
    if [ "${CATALOG_SERVICE_WINDOW_REQUIRE_INDEPENDENT_ADMIN_RESTORE:-0}" = "1" ]; then
      printf "{\"error\":\"admin_restore_replayed_customer_job\"}\n409"
      exit 0
    fi
    if [ "${CATALOG_SERVICE_WINDOW_RESTORE_CONFLICTS:-0}" = "1" ]; then
      printf "{\"error\":\"destination_changed\"}\n409"
    else
      printf "{\"restore_job_id\":\"66666666-6666-6666-6666-666666666666\",\"status\":\"queued\"}\n202"
    fi
    ;;
  *"/admin/cold/77777777-7777-7777-7777-777777777777/restore")
    if [ "${CATALOG_SERVICE_WINDOW_RESTORE_CONFLICTS:-0}" = "1" ]; then
      printf "{\"error\":\"destination_changed\"}\n409"
    else
      printf "{\"restore_job_id\":\"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\",\"status\":\"queued\"}\n202"
    fi
    ;;
  *"/admin/migrations?status=active"*)
    printf "[]\n200"
    ;;
  *"/admin/migrations?status=rolled_back"*)
    if [ "${CATALOG_SERVICE_WINDOW_OMIT_MIGRATION_ROW:-0}" = "1" ]; then
      printf "[{\"id\":\"99999999-9999-9999-9999-999999999999\",\"customer_id\":\"33333333-3333-3333-3333-333333333333\",\"index_name\":\"catalog_service_window_source_migration\",\"dest_vm_id\":\"00000000-0000-0000-0000-000000000002\",\"status\":\"rolled_back\"}]\n200"
    else
      printf "[{\"id\":\"77777777-7777-7777-7777-777777777777\",\"customer_id\":\"11111111-1111-1111-1111-111111111111\",\"index_name\":\"catalog_service_window_source_migration\",\"dest_vm_id\":\"00000000-0000-0000-0000-000000000002\",\"status\":\"rolled_back\"}]\n200"
    fi
    ;;
  *"/admin/migrations?status=failed"*)
    printf "[{\"id\":\"88888888-8888-8888-8888-888888888888\",\"customer_id\":\"11111111-1111-1111-1111-111111111111\",\"index_name\":\"catalog_service_window_source_migration\",\"dest_vm_id\":\"00000000-0000-0000-0000-000000000002\",\"status\":\"failed\"}]\n200"
    ;;
  *"/admin/replicas"*)
    if [ "${CATALOG_SERVICE_WINDOW_EMPTY_ROW_EVIDENCE:-0}" = "1" ]; then
      printf "[]\n200"
    else
      printf "[{\"id\":\"22222222-2222-2222-2222-222222222222\",\"customer_id\":\"11111111-1111-1111-1111-111111111111\",\"tenant_id\":\"catalog_service_window_source\",\"replica_region\":\"eu-central-1\",\"status\":\"%s\"}]\n200" "${CATALOG_SERVICE_WINDOW_ADMIN_REPLICA_STATUS:-provisioning}"
    fi
    ;;
  *"/admin/migrations/probe/rollback-after-replication")
    if [ "${CATALOG_SERVICE_WINDOW_FORBID_RECOVERY_SEAMS:-0}" = "1" ]; then
      printf "{\"error\":\"engine index identity probe recovery seams are disabled\"}\n403"
    else
      printf "{\"migration_id\":\"77777777-7777-7777-7777-777777777777\",\"status\":\"rolled_back\",\"scenario\":\"rollback_after_replication\"}\n200"
    fi
    ;;
  *"/admin/migrations/probe/failure-after-replication")
    printf "{\"migration_id\":\"88888888-8888-8888-8888-888888888888\",\"status\":\"failed\",\"scenario\":\"failure_after_replication\"}\n200"
    ;;
  *"/account")
    account_deletes="$(grep -c -- "http://localhost:38101/account\$" "$CATALOG_SERVICE_WINDOW_CURL_LOG" 2>/dev/null || true)"
    if [ "${account_deletes:-0}" -le 1 ]; then
      printf "\n204"
    else
      printf "{\"error\":\"invalid or expired token\"}\n401"
    fi
    ;;
  *"/admin/tenants/dddddddd-dddd-dddd-dddd-dddddddddda2")
    admin_deletes="$(grep -c -- "/admin/tenants/dddddddd-dddd-dddd-dddd-dddddddddda2\$" "$CATALOG_SERVICE_WINDOW_CURL_LOG" 2>/dev/null || true)"
    if [ "${admin_deletes:-0}" -le 1 ]; then
      printf "\n204"
    else
      printf "{\"error\":\"tenant not found\"}\n404"
    fi
    ;;
  *"/admin/tenants/dddddddd-dddd-dddd-dddd-dddddddddda3")
    stale_deletes="$(grep -c -- "/admin/tenants/dddddddd-dddd-dddd-dddd-dddddddddda3\$" "$CATALOG_SERVICE_WINDOW_CURL_LOG" 2>/dev/null || true)"
    if [ "${stale_deletes:-0}" -le 1 ]; then
      printf "\n204"
    else
      printf "{\"error\":\"tenant not found\"}\n404"
    fi
    ;;
  *"/admin/tenants/dddddddd-dddd-dddd-dddd-dddddddddd04")
    printf "\n204"
    ;;
  *"/admin/customers/dddddddd-dddd-dddd-dddd-dddddddddd04/hard-erase")
    if [[ "$*" != *"x-admin-key: catalog-service-window-admin-key"* ]]; then
      printf "{\"error\":\"missing admin key\"}\n403"
    else
      printf "\n204"
    fi
    ;;
  *"/migration/algolia/destination-eligibility")
    if [[ "$*" == *"catalog_service_window_source_soft_delete_stale"* ]]; then
      if [[ "$*" == *"stale-provider-token"* ]]; then
        printf "{\"eligibilityToken\":\"stale-target-token\"}\n200"
      else
        printf "{\"eligibilityToken\":\"stale-provider-token\"}\n200"
      fi
    else
      printf "{\"eligibilityToken\":\"migration-target-token\"}\n200"
    fi
    ;;
  *"/migration/algolia/jobs/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa02/cancel")
    if [ "${CATALOG_SERVICE_WINDOW_SOFT_DELETE_STALE_CANCEL_STATUS_OMITTED:-0}" = "1" ]; then
      printf "{}\n409"
    elif [ "${CATALOG_SERVICE_WINDOW_SOFT_DELETE_STALE_CANCEL_STATUS_ACCEPTED:-0}" = "1" ]; then
      printf "{\"id\":\"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa02\",\"status\":\"cancelling\"}\n202"
    else
      printf "{\"error\":\"cancel_not_permitted\",\"code\":\"cancel_not_permitted\"}\n409"
    fi
    ;;
  *"/migration/algolia/jobs/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa03/resume")
    if [ "${CATALOG_SERVICE_WINDOW_SOFT_DELETE_STALE_RESUME_STATUS_OMITTED:-0}" = "1" ]; then
      printf "{}\n409"
    elif [ "${CATALOG_SERVICE_WINDOW_SOFT_DELETE_STALE_RESUME_STATUS_ACCEPTED:-0}" = "1" ]; then
      printf "{\"id\":\"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa03\",\"status\":\"resuming\"}\n202"
    else
      printf "{\"error\":\"not_resumable\",\"code\":\"not_resumable\"}\n409"
    fi
    ;;
  *"/migration/algolia/jobs")
    if [ "${CATALOG_SERVICE_WINDOW_SOFT_DELETE_STALE_ENGINE_CALL:-0}" = "1" ]; then
      printf "soft_delete_stale_physical_dispatch\n" >> "$CATALOG_SERVICE_WINDOW_EVENT_LOG"
      printf "%s\n" "{\"status\":\"observed\",\"callers\":[{\"caller_id\":\"routes.migration.jobs.create_algolia_import_job\",\"observed_upstream_kind\":\"physical_uid\"}],\"checks\":{\"identity\":\"checked\",\"auth\":\"checked\",\"status\":\"checked\"}}" > "$ENGINE_INDEX_IDENTITY_OBSERVED_CALLERS_FILE"
    fi
    if [[ "$*" == *"idempotency-key: stale-new-admission"* ]] && [ "${CATALOG_SERVICE_WINDOW_SOFT_DELETE_STALE_NEW_ADMISSION_STATUS_OMITTED:-0}" = "1" ]; then
      printf "{}\n400"
    elif [[ "$*" == *"idempotency-key: stale-replay-admission"* ]] && [ "${CATALOG_SERVICE_WINDOW_SOFT_DELETE_STALE_REPLAY_ADMISSION_STATUS_OMITTED:-0}" = "1" ]; then
      printf "{}\n400"
    elif [[ "$*" == *"idempotency-key: stale-new-admission"* ]] && [ "${CATALOG_SERVICE_WINDOW_SOFT_DELETE_STALE_NEW_ADMISSION_STATUS_ACCEPTED:-0}" = "1" ]; then
      printf "{\"id\":\"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa11\",\"status\":\"queued\"}\n202"
    elif [[ "$*" == *"idempotency-key: stale-replay-admission"* ]] && [ "${CATALOG_SERVICE_WINDOW_SOFT_DELETE_STALE_REPLAY_ADMISSION_STATUS_ACCEPTED:-0}" = "1" ]; then
      printf "{\"id\":\"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01\",\"status\":\"queued\"}\n202"
    else
      printf "{\"error\":\"destination_changed\",\"code\":\"destination_changed\"}\n400"
    fi
    ;;
  *"/indexes/catalog_service_window_source_soft_delete_account/replicas"|*"/indexes/catalog_service_window_source_soft_delete_admin/replicas")
    if [ "${CATALOG_SERVICE_WINDOW_SOFT_DELETE_LEASE_MUTATION_ALLOWED:-0}" = "1" ]; then
      printf "{\"id\":\"eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee\",\"status\":\"provisioning\"}\n201"
    else
      printf "{\"error\":\"invalid or expired token\"}\n401"
    fi
    ;;
  *"/indexes/catalog_service_window_source_soft_delete_account"|*"/indexes/catalog_service_window_source_soft_delete_admin")
    if [[ "$*" == *"-X GET"* ]]; then
      if [ "${CATALOG_SERVICE_WINDOW_SOFT_DELETE_TARGET_VISIBLE:-0}" = "1" ]; then
        printf "{\"name\":\"soft-delete-target\",\"status\":\"ready\",\"entries\":0}\n200"
      else
        printf "{\"error\":\"invalid or expired token\"}\n401"
      fi
    else
      printf "{\"error\":\"invalid or expired token\"}\n401"
    fi
    ;;
  *)
    printf "{}\n200"
    ;;
esac
'
}

write_soft_delete_snapshot_emitter() {
  cat > "$WORK_DIR/soft_delete_snapshot.py" <<'PY'
import copy
import json
import os

GENERATION = 5
phase = int(os.environ.get("CATALOG_SD_PHASE", "0"))


def flag(name):
    return os.environ.get(name, "0") == "1"


evidence = {
    "catalog": {
        "customer_id": "sd-customer",
        "tenant_id": "sd-index",
        "deployment_id": "sd-deployment",
        "vm_id": "sd-vm",
        "tier": "active",
        "service_type": "flapjack",
    },
    "routing": {
        "deployment_id": "sd-deployment",
        "deployment_status": "running",
        "deployment_flapjack_url": "http://127.0.0.1:37801",
        "vm_id": "sd-vm",
        "vm_status": "active",
    },
    "import_operation": {
        "id": "sd-job",
        "status": "completed",
        "publication_disposition": "promoted",
        "engine_ack_state": "acknowledged",
        "dispatch_intent_state": "committed",
        "reserved_index_count": 1,
        "lifecycle_generation": GENERATION,
        "logical_target": "sd-index",
    },
}
if flag("CATALOG_SERVICE_WINDOW_SOFT_DELETE_MISSING_EVIDENCE_ROW"):
    evidence["import_operation"] = None
if flag("CATALOG_SERVICE_WINDOW_SOFT_DELETE_MISSING_CATALOG_ROW"):
    evidence["catalog"] = None
if flag("CATALOG_SERVICE_WINDOW_SOFT_DELETE_MISSING_ROUTING_ROW"):
    evidence["routing"] = None

if phase <= 1:
    customer = {"status": "active", "lifecycle_generation": GENERATION, "deleted_at": None}
    emitted_evidence = evidence
else:
    status = "deleted"
    generation = GENERATION + 1
    deleted_at = "2026-01-01T00:00:00.000000Z"
    if phase == 2:
        if flag("CATALOG_SERVICE_WINDOW_SOFT_DELETE_BAD_FIRST_STATUS"):
            status = "active"
        if flag("CATALOG_SERVICE_WINDOW_SOFT_DELETE_BAD_FIRST_GENERATION"):
            generation = GENERATION
        if flag("CATALOG_SERVICE_WINDOW_SOFT_DELETE_MISSING_DELETED_AT"):
            deleted_at = None
    if phase >= 3:
        if flag("CATALOG_SERVICE_WINDOW_SOFT_DELETE_REPEAT_BUMP_GENERATION"):
            generation = GENERATION + 2
        if flag("CATALOG_SERVICE_WINDOW_SOFT_DELETE_REPEAT_CHANGE_TIMESTAMP"):
            deleted_at = "2026-02-02T00:00:00.000000Z"
    emitted_evidence = evidence
    if flag("CATALOG_SERVICE_WINDOW_SOFT_DELETE_MUTATE_RETAINED_EVIDENCE"):
        emitted_evidence = copy.deepcopy(evidence)
        if emitted_evidence.get("import_operation"):
            emitted_evidence["import_operation"]["status"] = "mutated"
    customer = {"status": status, "lifecycle_generation": generation, "deleted_at": deleted_at}

if flag("CATALOG_SERVICE_WINDOW_SOFT_DELETE_MISSING_CUSTOMER_ROW"):
    customer = None

print(json.dumps(
    {"customer": customer, "evidence": emitted_evidence},
    separators=(",", ":"),
    sort_keys=True,
))
PY
}

write_stale_matrix_emitter() {
  cat > "$WORK_DIR/stale_matrix.py" <<'PY'
import copy
import json
import os

STATUS_EXPECTATIONS = {
    "stale_elapsed_resume_claim_status": "excluded",
    "stale_state_update_status": "conflict",
    "stale_terminal_ack_status": "excluded",
    "stale_terminal_finalization_status": "conflict",
    "stale_retention_gc_status": "excluded",
    "stale_active_reservation_status": "excluded",
    "stale_resume_intent_status": "conflict",
}


def flag(name):
    return os.environ.get(name, "0") == "1"


def env_name(key, suffix):
    return f"CATALOG_SERVICE_WINDOW_SOFT_DELETE_{key.upper()}_{suffix}"


if os.environ.get("CATALOG_STALE_REPO_PROBE") == "1":
    results = {}
    for key, expected in STATUS_EXPECTATIONS.items():
        if flag(env_name(key, "OMITTED")):
            continue
        results[key] = "accepted" if flag(env_name(key, "ACCEPTED")) else expected
    print(json.dumps(results, separators=(",", ":"), sort_keys=True))
    raise SystemExit(0)

phase = int(os.environ.get("CATALOG_STALE_PHASE", "0"))

evidence = {
    "catalog": {
        "customer_id": "stale-customer",
        "tenant_id": "catalog_service_window_source_soft_delete_stale",
        "tier": "active",
    },
    "routing": {
        "deployment_status": "running",
        "deployment_flapjack_url": "http://127.0.0.1:37801",
        "vm_status": "active",
    },
    "jobs": {
        "stale-replay-admission": {"id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01", "status": "queued", "lifecycle_generation": 5},
        "stale-cancel": {"id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa02", "status": "queued", "lifecycle_generation": 5},
        "stale-resume": {"id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa03", "status": "failed", "lifecycle_generation": 5},
        "stale-elapsed": {"id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa04", "status": "failed", "lifecycle_generation": 5},
        "stale-state": {"id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa05", "status": "copying_documents", "lifecycle_generation": 5},
        "stale-ack": {"id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa06", "status": "completed", "lifecycle_generation": 5},
        "stale-finalize": {"id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa07", "status": "verifying", "lifecycle_generation": 5},
        "stale-gc": {"id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa08", "status": "completed", "lifecycle_generation": 5},
        "stale-reservation": {"id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa09", "status": "queued", "lifecycle_generation": 5},
        "stale-resume-intent": {"id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa10", "status": "failed", "lifecycle_generation": 5},
    },
}
if phase > 1 and flag("CATALOG_SERVICE_WINDOW_SOFT_DELETE_STALE_MUTATE_RETAINED_EVIDENCE"):
    evidence = copy.deepcopy(evidence)
    evidence["jobs"]["stale-state"]["status"] = "mutated"

print(json.dumps(
    {
        "customer": {
            "status": "deleted",
            "lifecycle_generation": 6,
            "deleted_at_present": True,
        },
        "evidence": evidence,
    },
    separators=(",", ":"),
    sort_keys=True,
))
PY
}

write_hard_erase_matrix_emitter() {
  cat > "$WORK_DIR/hard_erase_matrix.py" <<'PY'
import copy
import json
import os

CASES = [
    ("committed", "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbb0001", "cccccccc-cccc-cccc-cccc-cccccccc0001", "eeeeeeee-eeee-eeee-eeee-eeeeeeee0001", "unchanged", "exact_target_absence_required", "pending"),
    ("ambiguous", "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbb0002", "cccccccc-cccc-cccc-cccc-cccccccc0002", "eeeeeeee-eeee-eeee-eeee-eeeeeeee0002", "unknown", "exact_target_absence_required", "pending"),
    ("pre_linkage", "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbb0003", None, None, "not_started", "exact_target_absence_required", "pending"),
    ("cancelling", "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbb0004", "cccccccc-cccc-cccc-cccc-cccccccc0004", "eeeeeeee-eeee-eeee-eeee-eeeeeeee0004", "unchanged", "exact_target_absence_required", "pending"),
    ("cancelled_before_ack", "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbb0005", "cccccccc-cccc-cccc-cccc-cccccccc0005", "eeeeeeee-eeee-eeee-eeee-eeeeeeee0005", "unchanged", "exact_target_absence_required", "outbox_pending"),
    ("failed_resumable_with_lease", "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbb0006", "cccccccc-cccc-cccc-cccc-cccccccc0006", "eeeeeeee-eeee-eeee-eeee-eeeeeeee0006", "unchanged", "exact_target_absence_required", "pending"),
    ("credential_accepted_before_socket", "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbb0007", None, None, "not_started", "exact_target_absence_required", "pending"),
    ("resuming", "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbb0008", "cccccccc-cccc-cccc-cccc-cccccccc0008", "eeeeeeee-eeee-eeee-eeee-eeeeeeee0008", "unchanged", "exact_target_absence_required", "pending"),
    ("resume_deadline_race", "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbb0009", "cccccccc-cccc-cccc-cccc-cccccccc0009", "eeeeeeee-eeee-eeee-eeee-eeeeeeee0009", "unchanged", "exact_target_absence_required", "pending"),
    ("local_no_dispatch", "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbb0010", None, None, "not_started", "engine_disposition_required", "not_applicable"),
    ("seal_tombstone", "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbb0011", None, None, "not_started", "engine_disposition_required", "seal_acknowledged"),
    ("ambiguous_publication", "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbb0012", "cccccccc-cccc-cccc-cccc-cccccccc0012", "eeeeeeee-eeee-eeee-eeee-eeeeeeee0012", "unknown", "exact_target_absence_required", "pending"),
]


def flag(name):
    return os.environ.get(name, "0") == "1"


def seed_rows():
    rows = [{"case_name": name, "id": row_id} for name, row_id, *_ in CASES]
    if flag("CATALOG_SERVICE_WINDOW_HARD_ERASE_EMPTY_SEED"):
        rows = []
    if flag("CATALOG_SERVICE_WINDOW_HARD_ERASE_DUPLICATE_SEED_ID"):
        rows[1]["id"] = rows[0]["id"]
    return rows


def snapshot_rows():
    rows = []
    erased_at = "2026-01-01T00:00:02.000000Z"
    if flag("CATALOG_SERVICE_WINDOW_HARD_ERASE_OUT_OF_WINDOW"):
        erased_at = "2026-01-01T00:00:05.000000Z"
    for name, row_id, engine_job_id, destination_vm_id, publication, cleanup, ack in CASES:
        rows.append({
            "case_name": name,
            "id": row_id,
            "engine_job_id": engine_job_id,
            "destination_vm_id": destination_vm_id,
            "publication_disposition": publication,
            "cleanup_phase": cleanup,
            "engine_ack_state": ack,
            "erasure_handle": f"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa{name.__hash__() & 0xffff:04x}",
            "erased_at": erased_at,
            "tombstone_compacted_at": None,
            "non_opaque_algolia_columns_null": True,
            "scrub_verdict": "scrubbed",
        })
    if flag("CATALOG_SERVICE_WINDOW_HARD_ERASE_SNAPSHOT_MISSING_CASE"):
        rows = rows[:-1]
    if flag("CATALOG_SERVICE_WINDOW_HARD_ERASE_SNAPSHOT_DUPLICATE_ID"):
        rows[1]["id"] = rows[0]["id"]
    if flag("CATALOG_SERVICE_WINDOW_HARD_ERASE_SNAPSHOT_MUTATE_OPAQUE"):
        rows[0] = copy.deepcopy(rows[0])
        rows[0]["cleanup_phase"] = "engine_disposition_required"
    if flag("CATALOG_SERVICE_WINDOW_HARD_ERASE_SNAPSHOT_UNSCRUBBED"):
        rows[0] = copy.deepcopy(rows[0])
        rows[0]["non_opaque_algolia_columns_null"] = False
        rows[0]["scrub_verdict"] = "pii_retained"
    return rows


mode = os.environ.get("CATALOG_HARD_ERASE_MODE")
if mode == "seed":
    if flag("CATALOG_SERVICE_WINDOW_HARD_ERASE_OMIT_SEED"):
        raise SystemExit(0)
    print(json.dumps(seed_rows(), separators=(",", ":"), sort_keys=True))
elif mode == "clock":
    if flag("CATALOG_SERVICE_WINDOW_HARD_ERASE_MISSING_CLOCK"):
        raise SystemExit(0)
    if flag("CATALOG_SERVICE_WINDOW_HARD_ERASE_MALFORMED_CLOCK"):
        print("not-a-timestamp")
        raise SystemExit(0)
    phase = int(os.environ.get("CATALOG_HARD_ERASE_PHASE", "0"))
    if flag("CATALOG_SERVICE_WINDOW_HARD_ERASE_REVERSED_CLOCK"):
        print("2026-01-01T00:00:03.000000Z" if phase <= 1 else "2026-01-01T00:00:01.000000Z")
    else:
        print("2026-01-01T00:00:01.000000Z" if phase <= 1 else "2026-01-01T00:00:03.000000Z")
elif mode == "snapshot":
    print(json.dumps({
        "customer_absent": not flag("CATALOG_SERVICE_WINDOW_HARD_ERASE_CUSTOMER_RETAINED"),
        "target_dependents_absent": not flag("CATALOG_SERVICE_WINDOW_HARD_ERASE_DEPENDENTS_RETAINED"),
        "audit_canary_absent": not flag("CATALOG_SERVICE_WINDOW_HARD_ERASE_AUDIT_RETAINED"),
        "tombstones": snapshot_rows(),
    }, separators=(",", ":"), sort_keys=True))
else:
    raise SystemExit(f"unknown hard erase matrix mode: {mode}")
PY
}

setup_workspace() {
  cleanup
  unset INTEGRATION_DB CATALOG_LIFECYCLE_SERVICE_WINDOW_RUNTIME_DIR || true
  TARGET_SCRIPT="$REPO_ROOT/scripts/catalog_lifecycle_service_window_live_probe.sh"
  WORK_DIR="$(mktemp -d)"
  mkdir -p "$WORK_DIR/bin" "$WORK_DIR/no-psql-bin" "$WORK_DIR/fixtures"
  for snapshot in good missing_reservation invalid_lease mutated; do
    cp "$REPO_ROOT/scripts/tests/fixtures/catalog_service_window_expired_snapshot_${snapshot}.json" \
      "$WORK_DIR/expired_snapshot_${snapshot}.json"
  done
  printf '{"status":"observed","callers":[],"checks":{"identity":"checked","auth":"checked","status":"checked"}}\n' > "$WORK_DIR/observed-callers.json"
  write_soft_delete_snapshot_emitter
  write_stale_matrix_emitter
  write_hard_erase_matrix_emitter
  : > "$WORK_DIR/curl.log"
  : > "$WORK_DIR/nohup.log"
  : > "$WORK_DIR/psql.log"
  : > "$WORK_DIR/docker.log"
  : > "$WORK_DIR/events.log"
  write_mock_binaries
  write_mock_curl
  cp "$WORK_DIR/bin/curl" "$WORK_DIR/no-psql-bin/curl"
  cp "$WORK_DIR/bin/docker" "$WORK_DIR/no-psql-bin/docker"
}

copy_probe_workspace() {
  COPIED_PROBE_ROOT="$WORK_DIR/copied_probe_repo"
  local copied_root="$COPIED_PROBE_ROOT"
  mkdir -p "$copied_root/scripts/tests/fixtures" "$copied_root/scripts/lib" "$copied_root/infra/api/src"
  cp "$REPO_ROOT/scripts/catalog_lifecycle_service_window_live_probe.sh" \
    "$copied_root/scripts/catalog_lifecycle_service_window_live_probe.sh"
  cp "$REPO_ROOT"/scripts/lib/*.sh "$copied_root/scripts/lib/"
  cp "$DEFAULT_INVENTORY" "$copied_root/scripts/tests/fixtures/catalog_lifecycle_writers.json"
  cp "$DEFAULT_ORACLE" "$copied_root/scripts/tests/fixtures/catalog_lifecycle_acceptance_oracles.json"
  python3 - "$DEFAULT_INVENTORY" "$copied_root" <<'PY'
import json
import pathlib
import sys

inventory_path, copied_root = sys.argv[1:]
with open(inventory_path, encoding="utf-8") as handle:
    inventory = json.load(handle)
for writer in inventory["writers"]:
    owner = pathlib.Path(copied_root) / writer["owner_path"]
    owner.parent.mkdir(parents=True, exist_ok=True)
    owner.touch()
PY
  TARGET_SCRIPT="$copied_root/scripts/catalog_lifecycle_service_window_live_probe.sh"
}

mutate_copied_oracle() {
  local copied_root="$1"
  local mutation="$2"

  python3 - "$copied_root/scripts/tests/fixtures/catalog_lifecycle_acceptance_oracles.json" "$mutation" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
mutation = sys.argv[2]
if mutation == "malformed":
    path.write_text("{not-json\n", encoding="utf-8")
    raise SystemExit(0)
if mutation == "duplicate_oracle_key":
    path.write_text(
        """{
  "version": 1,
  "oracle_kind": "catalog_lifecycle_acceptance",
  "lane_composition": {
    "execute_every_inventoried_caller_before_route_activation": true,
    "missing_dependency_disposition": "failure"
  },
  "oracles": {
    "block_without_change": {
      "summary": "first",
      "leased_behavior": "refuse_without_mutation",
      "release_trigger": "engine_ack"
    },
    "block_without_change": {
      "summary": "second",
      "leased_behavior": "mutate_anyway",
      "release_trigger": "immediate"
    },
    "privacy_transition": {
      "summary": "privacy",
      "soft_delete": "mark_deleted_bump_generation_fence_future_writes",
      "hard_delete": "purge_dependents_then_target",
      "reaper_scrub": "reaper_scrubs_catalog_target_after_hard_delete"
    }
  }
}
""",
        encoding="utf-8",
    )
    raise SystemExit(0)

with path.open(encoding="utf-8") as handle:
    payload = json.load(handle)
if mutation == "missing_block_without_change":
    payload["oracles"].pop("block_without_change")
elif mutation == "missing_privacy_transition":
    payload["oracles"].pop("privacy_transition")
elif mutation == "drift_block_without_change":
    payload["oracles"]["block_without_change"]["leased_behavior"] = "mutate_anyway"
elif mutation == "drift_privacy_transition":
    payload["oracles"]["privacy_transition"]["soft_delete"] = "mark_deleted_without_generation_bump"
elif mutation == "unknown_top_level_field":
    payload["generated_at"] = "2026-07-19T00:00:00Z"
elif mutation == "unknown_lane_composition_field":
    payload["lane_composition"]["skip_missing_dependency"] = True
elif mutation == "lane_composition_skips_dependency":
    payload["lane_composition"]["missing_dependency_disposition"] = "skip"
elif mutation == "lane_composition_skips_callers":
    payload["lane_composition"]["execute_every_inventoried_caller_before_route_activation"] = False
elif mutation == "unknown_class_field":
    payload["oracles"]["block_without_change"]["retry_behavior"] = "retry_once"
elif mutation == "cross_class_field":
    payload["oracles"]["privacy_transition"]["leased_behavior"] = "refuse_without_mutation"
else:
    raise SystemExit(f"unknown oracle mutation {mutation}")
with path.open("w", encoding="utf-8") as handle:
    json.dump(payload, handle, separators=(",", ":"), sort_keys=True)
PY
}

mutate_copied_inventory_disposition() {
  local copied_root="$1"

  python3 - "$copied_root/scripts/tests/fixtures/catalog_lifecycle_writers.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
with path.open(encoding="utf-8") as handle:
    payload = json.load(handle)
payload["writers"][0]["disposition"] = "unknown_acceptance_oracle"
with path.open("w", encoding="utf-8") as handle:
    json.dump(payload, handle, separators=(",", ":"), sort_keys=True)
PY
}

run_probe() {
  RUN_EXIT_CODE=0
  : > "$WORK_DIR/curl.log"
  : > "$WORK_DIR/nohup.log"
  : > "$WORK_DIR/psql.log"
  RUN_STDOUT="$(
    PATH="$WORK_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    FLAPJACK_DEV_DIR="$WORK_DIR" \
    CATALOG_LIFECYCLE_SERVICE_WINDOW_API_BUILD_ROOT="$WORK_DIR" \
    CATALOG_LIFECYCLE_SERVICE_WINDOW_ENGINE_BUILD_ROOT="$WORK_DIR/flapjack-src" \
    CATALOG_SERVICE_WINDOW_CURL_LOG="$WORK_DIR/curl.log" \
    CATALOG_SERVICE_WINDOW_NOHUP_LOG="$WORK_DIR/nohup.log" \
    CATALOG_SERVICE_WINDOW_PSQL_LOG="$WORK_DIR/psql.log" \
    CATALOG_SERVICE_WINDOW_DOCKER_LOG="$WORK_DIR/docker.log" \
    CATALOG_SERVICE_WINDOW_EVENT_LOG="$WORK_DIR/events.log" \
    CATALOG_SERVICE_WINDOW_EXPIRED_SNAPSHOT_GOOD="$WORK_DIR/expired_snapshot_good.json" \
    CATALOG_SERVICE_WINDOW_EXPIRED_SNAPSHOT_MISSING_RESERVATION="$WORK_DIR/expired_snapshot_missing_reservation.json" \
    CATALOG_SERVICE_WINDOW_EXPIRED_SNAPSHOT_INVALID_LEASE="$WORK_DIR/expired_snapshot_invalid_lease.json" \
    CATALOG_SERVICE_WINDOW_EXPIRED_SNAPSHOT_MUTATED="$WORK_DIR/expired_snapshot_mutated.json" \
    ENGINE_INDEX_IDENTITY_OBSERVED_CALLERS_FILE="$WORK_DIR/observed-callers.json" \
    CATALOG_SERVICE_WINDOW_SOFT_DELETE_SNAPSHOT_PY="$WORK_DIR/soft_delete_snapshot.py" \
    CATALOG_SERVICE_WINDOW_STALE_MATRIX_PY="$WORK_DIR/stale_matrix.py" \
    CATALOG_SERVICE_WINDOW_HARD_ERASE_MATRIX_PY="$WORK_DIR/hard_erase_matrix.py" \
    CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_EMAIL="service-window-probe@example.com" \
    CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_PASSWORD="Integration-Test-Pass-1!" \
    CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_INDEX="catalog_service_window_source" \
    CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_NODE_API_KEY="observed-node-api-key" \
    CATALOG_LIFECYCLE_SERVICE_WINDOW_RUNTIME_DIR="${CATALOG_LIFECYCLE_SERVICE_WINDOW_RUNTIME_DIR:-$WORK_DIR/catalog-service-window-runtime}" \
    INTEGRATION_DB="${INTEGRATION_DB:-catalog_service_window_live_probe_test}" \
    API_PORT=38101 \
    INTEGRATION_S3_PORT=38102 \
    FLAPJACK_PORT=37801 \
    METERING_AGENT_HEALTH_PORT=39191 \
    INTEGRATION_HEALTH_TIMEOUT=1 \
    bash "$TARGET_SCRIPT" "$@" 2>&1
  )" || RUN_EXIT_CODE=$?
}

run_probe_without_host_psql() {
  RUN_EXIT_CODE=0
  : > "$WORK_DIR/curl.log"
  : > "$WORK_DIR/nohup.log"
  : > "$WORK_DIR/docker.log"
  : > "$WORK_DIR/psql.log"
  RUN_STDOUT="$(
    PATH="$WORK_DIR/no-psql-bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    FLAPJACK_DEV_DIR="$WORK_DIR" \
    CATALOG_LIFECYCLE_SERVICE_WINDOW_API_BUILD_ROOT="$WORK_DIR" \
    CATALOG_LIFECYCLE_SERVICE_WINDOW_ENGINE_BUILD_ROOT="$WORK_DIR/flapjack-src" \
    CATALOG_SERVICE_WINDOW_CURL_LOG="$WORK_DIR/curl.log" \
    CATALOG_SERVICE_WINDOW_NOHUP_LOG="$WORK_DIR/nohup.log" \
    CATALOG_SERVICE_WINDOW_PSQL_LOG="$WORK_DIR/psql.log" \
    CATALOG_SERVICE_WINDOW_DOCKER_LOG="$WORK_DIR/docker.log" \
    CATALOG_SERVICE_WINDOW_EVENT_LOG="$WORK_DIR/events.log" \
    CATALOG_SERVICE_WINDOW_EXPIRED_SNAPSHOT_GOOD="$WORK_DIR/expired_snapshot_good.json" \
    CATALOG_SERVICE_WINDOW_EXPIRED_SNAPSHOT_MISSING_RESERVATION="$WORK_DIR/expired_snapshot_missing_reservation.json" \
    CATALOG_SERVICE_WINDOW_EXPIRED_SNAPSHOT_INVALID_LEASE="$WORK_DIR/expired_snapshot_invalid_lease.json" \
    CATALOG_SERVICE_WINDOW_EXPIRED_SNAPSHOT_MUTATED="$WORK_DIR/expired_snapshot_mutated.json" \
    ENGINE_INDEX_IDENTITY_OBSERVED_CALLERS_FILE="$WORK_DIR/observed-callers.json" \
    CATALOG_SERVICE_WINDOW_SOFT_DELETE_SNAPSHOT_PY="$WORK_DIR/soft_delete_snapshot.py" \
    CATALOG_SERVICE_WINDOW_STALE_MATRIX_PY="$WORK_DIR/stale_matrix.py" \
    CATALOG_SERVICE_WINDOW_HARD_ERASE_MATRIX_PY="$WORK_DIR/hard_erase_matrix.py" \
    CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_EMAIL="service-window-probe@example.com" \
    CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_PASSWORD="Integration-Test-Pass-1!" \
    CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_INDEX="catalog_service_window_source" \
    CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_NODE_API_KEY="observed-node-api-key" \
    CATALOG_LIFECYCLE_SERVICE_WINDOW_RUNTIME_DIR="${CATALOG_LIFECYCLE_SERVICE_WINDOW_RUNTIME_DIR:-$WORK_DIR/catalog-service-window-runtime}" \
    DATABASE_URL="postgres://nondefault:secretpass@127.0.0.1:15432/fjcloud_dev" \
    INTEGRATION_DB="${INTEGRATION_DB:-catalog_service_window_live_probe_test}" \
    API_PORT=38101 \
    INTEGRATION_S3_PORT=38102 \
    FLAPJACK_PORT=37801 \
    METERING_AGENT_HEALTH_PORT=39191 \
    INTEGRATION_HEALTH_TIMEOUT=1 \
    bash "$TARGET_SCRIPT" "$@" 2>&1
  )" || RUN_EXIT_CODE=$?
}

assert_log_order() {
  local log_file="$1"
  local first_pattern="$2"
  local second_pattern="$3"
  local msg="$4"
  local first_line second_line

  first_line="$(grep -n -m 1 -- "$first_pattern" "$log_file" | cut -d: -f1 || true)"
  second_line="$(grep -n -m 1 -- "$second_pattern" "$log_file" | cut -d: -f1 || true)"
  if [ -n "$first_line" ] && [ -n "$second_line" ] && [ "$first_line" -lt "$second_line" ]; then
    pass "$msg"
  else
    fail "$msg (first='$first_line' second='$second_line')"
  fi
}

test_rejects_unknown_and_incomplete_arguments() {
  setup_workspace

  run_probe --bogus
  assert_eq "$RUN_EXIT_CODE" "1" "unknown argument should fail"
  assert_contains "$RUN_STDOUT" "unknown argument: --bogus" "unknown argument is named"

  run_probe --api-binary
  assert_eq "$RUN_EXIT_CODE" "1" "missing option value should fail"
  assert_contains "$RUN_STDOUT" "--api-binary requires a value" "missing value is named"

  run_probe --inventory "$DEFAULT_INVENTORY"
  assert_eq "$RUN_EXIT_CODE" "1" "missing binary args should fail"
  assert_contains "$RUN_STDOUT" "--api-binary is required" "missing api binary is named"
}

test_probe_rejects_non_source_built_binary_provenance() {
  setup_workspace
  local api_binary engine_binary
  api_binary="$(cat "$WORK_DIR/source_api_binary")"
  engine_binary="$(cat "$WORK_DIR/source_engine_binary")"

  rm -f "$api_binary"
  run_probe --api-binary "$api_binary" --engine-binary "$engine_binary"
  assert_eq "$RUN_EXIT_CODE" "1" "absent API binary should fail provenance"
  assert_contains "$RUN_STDOUT" "--api-binary must be an absolute executable path" \
    "absent API binary failure is explicit"

  setup_workspace
  api_binary="$(cat "$WORK_DIR/source_api_binary")"
  engine_binary="$(cat "$WORK_DIR/source_engine_binary")"
  chmod -x "$api_binary"
  run_probe --api-binary "$api_binary" --engine-binary "$engine_binary"
  assert_eq "$RUN_EXIT_CODE" "1" "non-executable API binary should fail provenance"
  assert_contains "$RUN_STDOUT" "--api-binary must be an absolute executable path" \
    "non-executable API binary failure is explicit"

  setup_workspace
  write_mock_script "$WORK_DIR/bin/random-api" 'exit 0'
  engine_binary="$(cat "$WORK_DIR/source_engine_binary")"
  run_probe --api-binary "$WORK_DIR/bin/random-api" --engine-binary "$engine_binary"
  assert_eq "$RUN_EXIT_CODE" "1" "API binary outside source build output should fail provenance"
  assert_contains "$RUN_STDOUT" "--api-binary must resolve under source-built target/debug output" \
    "API source-build provenance failure is explicit"

  setup_workspace
  api_binary="$(cat "$WORK_DIR/source_api_binary")"
  write_mock_script "$WORK_DIR/bin/random-engine" 'exit 0'
  run_probe --api-binary "$api_binary" --engine-binary "$WORK_DIR/bin/random-engine"
  assert_eq "$RUN_EXIT_CODE" "1" "engine binary outside source build output should fail provenance"
  assert_contains "$RUN_STDOUT" "--engine-binary must resolve under source-built target/debug output" \
    "engine source-build provenance failure is explicit"
}

test_help_documents_environment_contract_and_default_inventory() {
  setup_workspace

  run_probe --help
  assert_eq "$RUN_EXIT_CODE" "0" "help should succeed"
  assert_contains "$RUN_STDOUT" "ENGINE_INDEX_IDENTITY_API_URL" "help documents API URL env"
  assert_contains "$RUN_STDOUT" "ENGINE_INDEX_IDENTITY_OBSERVED_CALLERS_FILE" "help documents observed callers env"
  assert_contains "$RUN_STDOUT" "CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_EMAIL" "help documents probe email env"
  assert_contains "$RUN_STDOUT" "CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_PASSWORD" "help documents probe password env"
  assert_contains "$RUN_STDOUT" "CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_INDEX" "help documents probe index env"
  assert_contains "$RUN_STDOUT" "CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_REGION" "help documents probe region env"
  assert_contains "$RUN_STDOUT" "CATALOG_LIFECYCLE_SERVICE_WINDOW_DEST_VM_ID" "help documents destination VM env"
  assert_contains "$RUN_STDOUT" "CATALOG_LIFECYCLE_SERVICE_WINDOW_DEST_SEED_INDEX" "help documents destination index env"
  assert_contains "$RUN_STDOUT" "CATALOG_LIFECYCLE_SERVICE_WINDOW_ADMIN_KEY" "help documents admin key env"
  assert_contains "$RUN_STDOUT" "CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_NODE_API_KEY" "help documents node key env"
  assert_contains "$RUN_STDOUT" "CATALOG_LIFECYCLE_SERVICE_WINDOW_HARD_ERASE_EMAIL" "help documents hard-erasure email env"
  assert_contains "$RUN_STDOUT" "CATALOG_LIFECYCLE_SERVICE_WINDOW_HARD_ERASE_PASSWORD" "help documents hard-erasure password env"
  assert_contains "$RUN_STDOUT" "API_PORT" "help documents API port env"
  assert_contains "$RUN_STDOUT" "FLAPJACK_PORT" "help documents engine port env"
  assert_contains "$RUN_STDOUT" "FJCLOUD_INTEGRATION_PID_DIR" "help documents integration runtime dir env"
  assert_contains "$RUN_STDOUT" "INTEGRATION_DB_URL" "help documents integration database URL env"
  assert_contains "$RUN_STDOUT" "CATALOG_LIFECYCLE_SERVICE_WINDOW_RUNTIME_DIR" "help documents service-window runtime dir env"
  assert_contains "$RUN_STDOUT" "scripts/tests/fixtures/catalog_lifecycle_writers.json" "help documents default catalog writer inventory"
  assert_contains "$RUN_STDOUT" "scripts/tests/fixtures/catalog_lifecycle_acceptance_oracles.json" "help documents default catalog acceptance oracle"
}

test_default_inventory_and_rejects_engine_inventory_shape() {
  setup_workspace

  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"
  assert_eq "$RUN_EXIT_CODE" "0" "default catalog lifecycle inventory should pass"
  assert_contains "$RUN_STDOUT" "\"inventory\":\"scripts/tests/fixtures/catalog_lifecycle_writers.json\"" \
    "success output names default inventory"
  assert_contains "$RUN_STDOUT" "\"oracle\":\"scripts/tests/fixtures/catalog_lifecycle_acceptance_oracles.json\"" \
    "success output names default oracle"

  local engine_inventory="$WORK_DIR/fixtures/engine-inventory.json"
  cat > "$engine_inventory" <<'JSON'
{"expected_caller_count":1,"callers":[{"caller_id":"x","expected_upstream_kind":"catalog_only","expected_upstream_headers":{}}]}
JSON
  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack" --inventory "$engine_inventory"
  assert_eq "$RUN_EXIT_CODE" "1" "engine caller inventory shape should not be accepted"
  assert_contains "$RUN_STDOUT" "catalog lifecycle writer inventory requires version" \
    "catalog validator rejects second writer shape"
}

test_catalog_oracle_dependency_fails_closed() {
  setup_workspace
  local copied_root
  copy_probe_workspace
  copied_root="$COPIED_PROBE_ROOT"
  rm -f "$copied_root/scripts/tests/fixtures/catalog_lifecycle_acceptance_oracles.json"

  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"
  assert_eq "$RUN_EXIT_CODE" "1" "missing oracle should fail before stack startup"
  assert_contains "$RUN_STDOUT" "catalog lifecycle acceptance oracle does not exist" \
    "missing oracle dependency failure is explicit"
  assert_eq "$(cat "$WORK_DIR/nohup.log")" "" \
    "missing oracle dependency fails before local stack startup"

  setup_workspace
  copy_probe_workspace
  copied_root="$COPIED_PROBE_ROOT"
  mutate_copied_oracle "$copied_root" malformed
  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"
  assert_eq "$RUN_EXIT_CODE" "1" "malformed oracle should fail"
  assert_contains "$RUN_STDOUT" "catalog lifecycle acceptance oracle is not readable structured JSON" \
    "malformed oracle failure is explicit"

  setup_workspace
  copy_probe_workspace
  copied_root="$COPIED_PROBE_ROOT"
  cp "$copied_root/scripts/tests/fixtures/catalog_lifecycle_acceptance_oracles.json" \
    "$copied_root/scripts/tests/fixtures/non_canonical_oracles.json"
  python3 - "$copied_root/scripts/catalog_lifecycle_service_window_live_probe.sh" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = path.read_text(encoding="utf-8")
payload = payload.replace(
    'DEFAULT_ORACLE="$REPO_ROOT/scripts/tests/fixtures/catalog_lifecycle_acceptance_oracles.json"',
    'DEFAULT_ORACLE="$REPO_ROOT/scripts/tests/fixtures/non_canonical_oracles.json"',
)
path.write_text(payload, encoding="utf-8")
PY
  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"
  assert_eq "$RUN_EXIT_CODE" "1" "non-canonical oracle path should fail"
  assert_contains "$RUN_STDOUT" "canonical oracle path" \
    "non-canonical oracle path failure is explicit"
}

test_catalog_oracle_validator_fails_closed() {
  local copied_root mutation expected
  for mutation in missing_block_without_change missing_privacy_transition \
    drift_block_without_change drift_privacy_transition unknown_top_level_field \
    unknown_lane_composition_field lane_composition_skips_dependency \
    lane_composition_skips_callers unknown_class_field cross_class_field \
    duplicate_oracle_key; do
    setup_workspace
    copy_probe_workspace
    copied_root="$COPIED_PROBE_ROOT"
    mutate_copied_oracle "$copied_root" "$mutation"
    run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"
    assert_eq "$RUN_EXIT_CODE" "1" "${mutation} should fail"
    case "$mutation" in
      missing_block_without_change|missing_privacy_transition)
        expected="catalog lifecycle acceptance oracle classes drifted"
        ;;
      drift_block_without_change|drift_privacy_transition)
        expected="catalog lifecycle acceptance oracle behavior drifted"
        ;;
      unknown_top_level_field)
        expected="catalog lifecycle acceptance oracle has unknown fields"
        ;;
      unknown_lane_composition_field)
        expected="catalog lifecycle acceptance oracle lane_composition has unknown fields"
        ;;
      lane_composition_skips_dependency)
        expected="catalog lifecycle acceptance oracle lane composition must fail missing dependencies"
        ;;
      lane_composition_skips_callers)
        expected="catalog lifecycle acceptance oracle lane composition must execute every caller"
        ;;
      unknown_class_field)
        expected="catalog lifecycle acceptance oracle block_without_change has unknown fields"
        ;;
      cross_class_field)
        expected="catalog lifecycle acceptance oracle privacy_transition has unknown fields"
        ;;
      duplicate_oracle_key)
        expected="must not repeat object key block_without_change"
        ;;
    esac
    assert_contains "$RUN_STDOUT" "$expected" "${mutation} failure names oracle drift"
  done

  setup_workspace
  copy_probe_workspace
  copied_root="$COPIED_PROBE_ROOT"
  mutate_copied_inventory_disposition "$copied_root"
  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"
  assert_eq "$RUN_EXIT_CODE" "1" "inventory disposition without oracle should fail"
  assert_contains "$RUN_STDOUT" "writer disposition does not resolve to exactly one oracle" \
    "inventory-oracle join drift failure is explicit"
}

test_recovery_seam_env_is_scoped_to_local_api_process() {
  setup_workspace
  unset ENGINE_INDEX_IDENTITY_PROBE_RECOVERY_SEAMS || true

  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"

  assert_eq "$RUN_EXIT_CODE" "0" "probe should pass with scoped recovery seams"
  assert_eq "${ENGINE_INDEX_IDENTITY_PROBE_RECOVERY_SEAMS:-unset}" "unset" \
    "parent shell should not see recovery seams env"
  assert_contains "$(cat "$WORK_DIR/nohup.log")" "ENV:1" \
    "wrapper-launched local API process sees recovery seams env"

  CATALOG_SERVICE_WINDOW_FORBID_RECOVERY_SEAMS=1 run_probe \
    --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack" --no-start-stack
  assert_eq "$RUN_EXIT_CODE" "1" "non-probe invocation without stack recovery env should fail recovery seam call"
  assert_contains "$RUN_STDOUT" "recovery seams forbidden outside local probe stack" \
    "non-stack path proves recovery seam is not ambient"
}

test_probe_drives_required_service_window_routes() {
  setup_workspace

  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"

  assert_eq "$RUN_EXIT_CODE" "0" "required service-window route drive should pass"
  local curl_log
  curl_log="$(cat "$WORK_DIR/curl.log")"
  assert_contains "$curl_log" "/auth/register" "probe registers isolated tenants"
  assert_contains "$curl_log" "service-window-isolation" "probe creates same-name unrelated tenant"
  assert_contains "$curl_log" "authorization: Bearer isolation-login-token" "probe authenticates unrelated tenant"
  assert_contains "$curl_log" "-X POST" "probe issues POST calls"
  assert_contains "$curl_log" "http://localhost:38101/indexes" "probe creates source index"
  assert_contains "$curl_log" "/indexes/catalog_service_window_source/replicas" "probe creates and lists replicas"
  assert_contains "$curl_log" "/indexes/catalog_service_window_source/restore" "probe drives customer restore"
  assert_contains "$curl_log" "/admin/cold/77777777-7777-7777-7777-777777777777/restore" "probe drives admin cold restore"
  assert_contains "$curl_log" "/admin/migrations/probe/rollback-after-replication" "probe drives rollback recovery seam"
  assert_contains "$curl_log" "/admin/migrations/probe/failure-after-replication" "probe drives failure recovery seam"
  assert_contains "$curl_log" "x-admin-key: catalog-service-window-admin-key" "admin calls use admin auth"
  assert_contains "$curl_log" "authorization: Bearer login-token" "tenant calls use tenant auth"
  assert_contains "$curl_log" "/admin/tenants/11111111-1111-1111-1111-111111111111/indexes" "probe seeds destination VM through admin index boundary"
  assert_contains "$curl_log" "/admin/vms" "probe discovers destination VM"
  assert_contains "$(cat "$WORK_DIR/psql.log")" "cold_snapshots" "probe seeds cold snapshot state through local-only SQL"
  assert_contains "$(cat "$WORK_DIR/psql.log")" "tier = 'cold'" "probe marks the source tenant cold before restore"
  assert_contains "$(cat "$WORK_DIR/psql.log")" "catalog_service_window_source_admin_restore" \
    "probe seeds an independent admin restore index cold snapshot"
  assert_log_order "$WORK_DIR/events.log" "cold_snapshots" "/indexes/catalog_service_window_source/restore" \
    "probe seeds cold state before customer restore"
  assert_contains "$RUN_STDOUT" "\"replica_create_status\":\"provisioning\"" "success evidence includes replica state"
  assert_contains "$RUN_STDOUT" "\"customer_restore_status\":\"queued\"" "success evidence includes customer restore state"
  assert_contains "$RUN_STDOUT" "\"admin_restore_status\":\"queued\"" "success evidence includes admin restore state"
  assert_contains "$RUN_STDOUT" "\"rollback_status\":\"rolled_back\"" "success evidence includes rollback state"
  assert_contains "$RUN_STDOUT" "\"failure_status\":\"failed\"" "success evidence includes failure state"
}

test_restore_conflict_outcomes_are_probe_evidence() {
  setup_workspace

  CATALOG_SERVICE_WINDOW_RESTORE_CONFLICTS=1 run_probe \
    --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"

  assert_eq "$RUN_EXIT_CODE" "0" "restore conflict outcomes should be accepted as deterministic evidence"
  assert_contains "$RUN_STDOUT" "\"customer_restore_status\":\"destination_conflict\"" \
    "customer restore conflict reason is normalized into evidence"
  assert_contains "$RUN_STDOUT" "\"admin_restore_status\":\"destination_changed\"" \
    "admin restore conflict reason is normalized into evidence"
}

service_window_success_payload_has_public_contract() {
  local payload="$1"

  PAYLOAD="$payload" \
  SELECTED_ROUTE_WRITER="$SELECTED_ROUTE_WRITER" \
  SELECTED_SERVICE_WRITER="$SELECTED_SERVICE_WRITER" \
  SELECTED_SOFT_DELETE_REPO_WRITER="$SELECTED_SOFT_DELETE_REPO_WRITER" \
  SELECTED_SOFT_DELETE_ACCOUNT_WRITER="$SELECTED_SOFT_DELETE_ACCOUNT_WRITER" \
  SELECTED_SOFT_DELETE_ADMIN_WRITER="$SELECTED_SOFT_DELETE_ADMIN_WRITER" \
  SELECTED_HARD_ERASE_WRITER="$SELECTED_HARD_ERASE_WRITER" \
    python3 - <<'PY'
import json
import os

payload = os.environ["PAYLOAD"]
lines = [line for line in payload.splitlines() if line.strip()]
if lines.count("expired_worker_claim_reservation=passed") != 1:
    raise SystemExit(1)
evidence_lines = [line for line in lines if line.startswith("{") and "selected_evidence" in line]
if len(evidence_lines) != 1:
    raise SystemExit(1)
evidence = json.loads(evidence_lines[0])
if evidence.get("status") != "pass":
    raise SystemExit(1)
if evidence.get("inventory") != "scripts/tests/fixtures/catalog_lifecycle_writers.json":
    raise SystemExit(1)
if evidence.get("oracle") != "scripts/tests/fixtures/catalog_lifecycle_acceptance_oracles.json":
    raise SystemExit(1)

expected = [
    {
        "writer_id": os.environ["SELECTED_ROUTE_WRITER"],
        "owner_path": "infra/api/src/routes/indexes/lifecycle.rs",
        "source_anchor": "flapjack_proxy.delete_index",
        "oracle_class": "block_without_change",
        "operation_result_key": "expired_worker_claim_route_status",
        "operation_result": "destination_conflict",
    },
    {
        "writer_id": os.environ["SELECTED_SERVICE_WRITER"],
        "owner_path": "infra/api/src/services/replica.rs",
        "source_anchor": "replica_repo.create",
        "oracle_class": "block_without_change",
        "operation_result_key": "expired_worker_claim_service_status",
        "operation_result": "destination_conflict",
    },
    {
        "writer_id": os.environ["SELECTED_SOFT_DELETE_REPO_WRITER"],
        "owner_path": "infra/api/src/repos/pg_customer_repo/lifecycle.rs",
        "source_anchor": "pg_customer_repo.soft_delete",
        "oracle_class": "privacy_transition",
        "operation_result_key": "stale_state_update_status",
        "operation_result": "conflict",
    },
    {
        "writer_id": os.environ["SELECTED_SOFT_DELETE_ACCOUNT_WRITER"],
        "owner_path": "infra/api/src/routes/account.rs",
        "source_anchor": "customer_repo.soft_delete",
        "oracle_class": "privacy_transition",
        "operation_result_key": "soft_delete_account_route_status",
        "operation_result": "deleted",
    },
    {
        "writer_id": os.environ["SELECTED_SOFT_DELETE_ADMIN_WRITER"],
        "owner_path": "infra/api/src/routes/admin/tenants.rs",
        "source_anchor": "customer_repo.soft_delete",
        "oracle_class": "privacy_transition",
        "operation_result_key": "soft_delete_admin_route_status",
        "operation_result": "deleted",
    },
    {
        "writer_id": os.environ["SELECTED_HARD_ERASE_WRITER"],
        "owner_path": "infra/api/src/routes/admin/tenants.rs",
        "source_anchor": "customer_repo.hard_delete",
        "oracle_class": "privacy_transition",
        "operation_result_key": "hard_erase_tombstone_matrix_status",
        "operation_result": "passed",
    },
]
if evidence.get("selected_evidence") != expected:
    raise SystemExit(1)
PY
}

mutate_success_payload() {
  local payload="$1"
  local mutation="$2"

  PAYLOAD="$payload" MUTATION="$mutation" python3 - <<'PY'
import json
import os

lines = [line for line in os.environ["PAYLOAD"].splitlines() if line.strip()]
mutation = os.environ["MUTATION"]
for idx, line in enumerate(lines):
    if not (line.startswith("{") and "selected_evidence" in line):
        continue
    evidence = json.loads(line)
    selected = evidence.get("selected_evidence", [])
    if mutation == "remove_selected_member":
        evidence["selected_evidence"] = selected[:-1]
    elif mutation == "duplicate_selected_member":
        evidence["selected_evidence"] = [*selected, selected[0]]
    elif mutation == "reorder_selected_member":
        evidence["selected_evidence"] = [selected[1], selected[0], *selected[2:]]
    elif mutation == "corrupt_selected_member":
        selected[0]["operation_result"] = "destination_changed"
        evidence["selected_evidence"] = selected
    elif mutation == "remove_inventory":
        evidence.pop("inventory", None)
    elif mutation == "remove_oracle":
        evidence.pop("oracle", None)
    elif mutation == "corrupt_status":
        evidence["status"] = "fail"
    else:
        raise SystemExit(f"unknown success payload mutation {mutation}")
    lines[idx] = json.dumps(evidence, separators=(",", ":"), sort_keys=True)
    break
print("\n".join(lines))
PY
}

expired_worker_claim_has_public_success_markers() {
  service_window_success_payload_has_public_contract "$1"
}

test_expired_worker_claim_reservation_blocks_route_and_service_writers() {
  setup_workspace

  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"

  assert_eq "$RUN_EXIT_CODE" "0" "expired worker claim reservation should block route and service writers"
  expired_worker_claim_has_public_success_markers "$RUN_STDOUT" \
    && pass "expired-claim success output includes public marker and default inventory" \
    || fail "expired-claim success output includes public marker and default inventory"
  assert_contains "$RUN_STDOUT" "\"writer_id\":\"$SELECTED_ROUTE_WRITER\"" \
    "success evidence reports selected route-owned block_without_change writer"
  assert_contains "$RUN_STDOUT" "\"writer_id\":\"$SELECTED_SERVICE_WRITER\"" \
    "success evidence reports selected service-owned block_without_change writer"
  assert_contains "$RUN_STDOUT" "\"oracle\":\"scripts/tests/fixtures/catalog_lifecycle_acceptance_oracles.json\"" \
    "success output names default oracle"
  assert_contains "$RUN_STDOUT" "\"selected_evidence\":[{\"operation_result\":\"destination_conflict\",\"operation_result_key\":\"expired_worker_claim_route_status\"" \
    "selected evidence is emitted in deterministic route-first order"
  assert_contains "$RUN_STDOUT" "\"expired_worker_claim_route_status\":\"destination_conflict\"" \
    "route operation is exact destination_conflict evidence"
  assert_contains "$RUN_STDOUT" "\"expired_worker_claim_service_status\":\"destination_conflict\"" \
    "service operation is exact destination_conflict evidence"
  assert_not_contains "$RUN_STDOUT" "\"expired_worker_claim_route_status\":\"destination_changed\"" \
    "expired-claim route scenario must not normalize destination_changed"
  assert_not_contains "$RUN_STDOUT" "\"expired_worker_claim_service_status\":\"destination_changed\"" \
    "expired-claim service scenario must not normalize destination_changed"

  local psql_log event_log
  psql_log="$(cat "$WORK_DIR/psql.log")"
  event_log="$(cat "$WORK_DIR/events.log")"
  assert_contains "$psql_log" "catalog_service_window_expired_worker_claim_seed" \
    "probe seeds the dedicated expired-worker-claim reservation"
  assert_contains "$psql_log" "worker_lease_expires_at = NOW() - INTERVAL '10 minutes'" \
    "seed persists an elapsed worker lease"
  assert_contains "$psql_log" "worker_lease_expires_at < NOW()" \
    "probe validates the persisted lease is earlier than database NOW"
  assert_contains "$psql_log" "catalog_service_window_expired_worker_claim_snapshot" \
    "probe captures exact row evidence snapshots"
  assert_contains "$event_log" "/indexes/catalog_service_window_source_expired_claim/replicas" \
    "service-owned API seam is exercised through the selected writer"
  assert_contains "$event_log" "catalog_service_window_source_expired_claim" \
    "route-owned API seam is exercised against the dedicated target"
  assert_not_contains "$event_log" "http://127.0.0.1:37801/1/indexes/catalog_service_window_source_expired_claim" \
    "blocked calls produce no physical engine dispatch"
}

assert_expired_worker_claim_mutation_fails() {
  local mutation_env="$1"
  local expected="$2"
  local msg="$3"

  setup_workspace
  export "${mutation_env}=1"
  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"
  unset "$mutation_env"

  assert_eq "$RUN_EXIT_CODE" "1" "$msg"
  assert_contains "$RUN_STDOUT" "$expected" "$msg names the failed invariant"
}

test_expired_worker_claim_reservation_mutations_fail_closed() {
  assert_expired_worker_claim_mutation_fails \
    "CATALOG_SERVICE_WINDOW_EXPIRED_OMIT_LEASE" \
    "local expired worker claim reservation seed did not persist an elapsed worker lease" \
    "missing worker_lease_expires_at should fail"

  assert_expired_worker_claim_mutation_fails \
    "CATALOG_SERVICE_WINDOW_EXPIRED_LEASE_NOT_EXPIRED" \
    "local expired worker claim reservation seed did not persist an elapsed worker lease" \
    "non-expired worker_lease_expires_at should fail"

  assert_expired_worker_claim_mutation_fails \
    "CATALOG_SERVICE_WINDOW_EXPIRED_OMIT_ACTIVE_RESERVATION" \
    "expired worker claim snapshot missing active import reservation" \
    "missing active reservation should fail"

  assert_expired_worker_claim_mutation_fails \
    "CATALOG_SERVICE_WINDOW_EXPIRED_MUTATE_SNAPSHOT" \
    "expired worker claim row evidence changed" \
    "catalog or routing row mutation should fail"

  assert_expired_worker_claim_mutation_fails \
    "CATALOG_SERVICE_WINDOW_EXPIRED_ENGINE_CALL" \
    "expired worker claim blocked calls produced engine observations" \
    "engine dispatch during blocked calls should fail"

  assert_expired_worker_claim_mutation_fails \
    "CATALOG_SERVICE_WINDOW_EXPIRED_DESTINATION_CHANGED" \
    "expired worker claim route writer expected HTTP 409 destination_conflict" \
    "destination_changed must not be accepted for expired-claim operations"
}

test_expired_worker_claim_success_output_mutations_fail_closed() {
  setup_workspace
  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"
  assert_eq "$RUN_EXIT_CODE" "0" "success-output mutation baseline probe should pass"

  local mutation mutated missing_marker
  for mutation in remove_selected_member duplicate_selected_member reorder_selected_member \
    corrupt_selected_member remove_inventory remove_oracle corrupt_status; do
    mutated="$(mutate_success_payload "$RUN_STDOUT" "$mutation")"
    expired_worker_claim_has_public_success_markers "$mutated" \
      && fail "${mutation} should fail" \
      || pass "${mutation} should fail"
  done
  missing_marker="$(printf '%s\n' "$RUN_STDOUT" | sed 's/expired_worker_claim_reservation=passed//')"
  expired_worker_claim_has_public_success_markers "$missing_marker" \
    && fail "omitting expired_worker_claim_reservation=passed should fail" \
    || pass "omitting expired_worker_claim_reservation=passed should fail"
}

test_admin_cold_restore_filters_to_probe_snapshot() {
  setup_workspace

  CATALOG_SERVICE_WINDOW_UNRELATED_COLD_FIRST=1 run_probe \
    --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"

  assert_eq "$RUN_EXIT_CODE" "0" "admin cold restore should ignore unrelated global cold snapshots"
  assert_contains "$(cat "$WORK_DIR/curl.log")" \
    "/admin/cold/77777777-7777-7777-7777-777777777777/restore" \
    "admin restore uses the probe tenant snapshot"
  assert_not_contains "$(cat "$WORK_DIR/curl.log")" \
    "/admin/cold/99999999-9999-9999-9999-999999999999/restore" \
    "admin restore must not use the first unrelated global snapshot"
}

test_admin_cold_restore_uses_independent_index() {
  setup_workspace

  CATALOG_SERVICE_WINDOW_REQUIRE_INDEPENDENT_ADMIN_RESTORE=1 run_probe \
    --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"

  assert_eq "$RUN_EXIT_CODE" "0" "admin cold restore should prove an independent restore admission"
  assert_contains "$(cat "$WORK_DIR/curl.log")" \
    "/admin/cold/77777777-7777-7777-7777-777777777777/restore" \
    "admin restore targets the independent admin restore snapshot"
  assert_not_contains "$(cat "$WORK_DIR/curl.log")" \
    "/admin/cold/55555555-5555-5555-5555-555555555555/restore" \
    "admin restore must not replay the customer restore snapshot"
  assert_contains "$(cat "$WORK_DIR/psql.log")" "catalog_service_window_source_admin_restore" \
    "admin restore cold seed uses a distinct index name"
}

test_migration_probes_use_active_source_index() {
  setup_workspace

  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"

  assert_eq "$RUN_EXIT_CODE" "0" "migration probe should use a source index that restore seeding did not make cold"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "/indexes/catalog_service_window_source_migration/batch" \
    "probe seeds a separate active migration source index"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "\"index_name\":\"catalog_service_window_source_migration\"" \
    "migration recovery calls target the active migration index"
  assert_not_contains "$(cat "$WORK_DIR/psql.log")" "probe_index=catalog_service_window_source_migration" \
    "cold snapshot seed must not target the migration source index"
}

test_existing_state_rerun_and_nonprovisioning_replica_are_accepted() {
  setup_workspace

  CATALOG_SERVICE_WINDOW_EXISTING_STATE=1 \
  CATALOG_SERVICE_WINDOW_ADMIN_REPLICA_STATUS=active \
    run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack" --no-start-stack

  assert_eq "$RUN_EXIT_CODE" "0" "rerun should reuse existing accounts/index and accept an active replica"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "/auth/login" \
    "existing accounts are resolved through the authenticated login contract"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "/admin/replicas" \
    "admin replica evidence is queried"
  assert_not_contains "$(cat "$WORK_DIR/curl.log")" "/admin/replicas?status=provisioning" \
    "admin evidence must not filter away valid later replica states"
}

hard_erase_tombstone_matrix_has_public_success_contract() {
  local payload="$1"

  PAYLOAD="$payload" python3 - "${HARD_ERASE_CASE_NAMES[@]}" <<'PY'
import json
import os
import re
import sys

expected_cases = sys.argv[1:]
payload = os.environ["PAYLOAD"]
lines = [line for line in payload.splitlines() if line.strip()]
marker = "hard_erase_tombstone_matrix=passed"
if lines.count(marker) != 1:
    raise SystemExit(1)
evidence_indexes = [
    index for index, line in enumerate(lines)
    if line.startswith("{") and "hard_erase_tombstone_matrix_status" in line
]
if len(evidence_indexes) != 1:
    raise SystemExit(1)
if lines.index(marker) <= evidence_indexes[0]:
    raise SystemExit(1)
evidence = json.loads(lines[evidence_indexes[0]])
required = {
    "hard_erase_tombstone_matrix_status": "passed",
    "hard_erase_tombstone_matrix_seeded_count": 12,
    "hard_erase_tombstone_matrix_retained_count": 12,
}
for key, expected in required.items():
    if evidence.get(key) != expected:
        raise SystemExit(1)
rows = evidence.get("hard_erase_tombstone_matrix_evidence")
if not isinstance(rows, list) or len(rows) != len(expected_cases):
    raise SystemExit(1)
if [row.get("case_name") for row in rows] != expected_cases:
    raise SystemExit(1)
ids = [row.get("captured_id") for row in rows]
uuid_pattern = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
if len(ids) != len(set(ids)) or any(not isinstance(value, str) or not uuid_pattern.match(value) for value in ids):
    raise SystemExit(1)
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
for row in rows:
    name = row["case_name"]
    opaque = row.get("retained_opaque_state")
    if not isinstance(opaque, dict):
        raise SystemExit(1)
    engine_job_id, destination_vm_id, publication, cleanup, ack = expected_opaque[name]
    if opaque != {
        "engine_job_id": engine_job_id,
        "destination_vm_id": destination_vm_id,
        "publication_disposition": publication,
        "cleanup_phase": cleanup,
        "engine_ack_state": ack,
    }:
        raise SystemExit(1)
    if row.get("scrub_verdict") != "scrubbed":
        raise SystemExit(1)
PY
}

assert_hard_erase_verdict_contract_rejects() {
  local payload="$1"
  local msg="$2"

  hard_erase_tombstone_matrix_has_public_success_contract "$payload" >/dev/null 2>&1 \
    && fail "$msg" \
    || pass "$msg"
}

assert_hard_erase_mutation_fails() {
  local mutation_env="$1"
  local expected="$2"
  local msg="$3"

  setup_workspace
  export "${mutation_env}=1"
  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"
  unset "$mutation_env"

  assert_eq "$RUN_EXIT_CODE" "1" "$msg"
  assert_contains "$RUN_STDOUT" "$expected" "$msg names the failed invariant"
}

test_hard_erase_tombstone_matrix_route_and_evidence_contract() {
  setup_workspace

  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"

  assert_eq "$RUN_EXIT_CODE" "0" "hard-erasure matrix baseline should pass"
  local curl_log psql_log
  curl_log="$(cat "$WORK_DIR/curl.log")"
  psql_log="$(cat "$WORK_DIR/psql.log")"
  assert_contains "$curl_log" "hard-erase" "probe registers the dedicated hard-erasure customer"
  assert_contains "$curl_log" "/admin/customers/${HARD_ERASE_CUSTOMER_ID}/hard-erase" \
    "probe calls the hard-erasure admin route"
  assert_contains "$curl_log" "x-admin-key: catalog-service-window-admin-key" \
    "hard-erasure admin route uses admin auth"
  assert_contains "$psql_log" "catalog_service_window_hard_erase_matrix_seed" \
    "probe seeds hard-erasure matrix rows through local-only SQL"
  assert_contains "$psql_log" "catalog_service_window_hard_erase_matrix_clock" \
    "probe captures DB clock bounds around hard erase"
  assert_contains "$psql_log" "catalog_service_window_hard_erase_matrix_snapshot" \
    "probe reads back scoped hard-erasure tombstones"
  assert_contains "$RUN_STDOUT" "\"hard_erase_tombstone_matrix_status\":\"passed\"" \
    "success evidence includes hard-erasure status"
  hard_erase_tombstone_matrix_has_public_success_contract "$RUN_STDOUT" \
    && pass "hard-erasure success output satisfies the public verdict contract" \
    || fail "hard-erasure success output satisfies the public verdict contract"
  assert_stdout_order "\"hard_erase_tombstone_matrix_status\":\"passed\"" \
    "hard_erase_tombstone_matrix=passed" \
    "hard-erasure marker is emitted after structured evidence"
}

test_hard_erase_tombstone_matrix_mutations_fail_closed() {
  assert_hard_erase_mutation_fails \
    "CATALOG_SERVICE_WINDOW_HARD_ERASE_EMPTY_SEED" \
    "hard erase matrix seed returned no rows" \
    "empty hard-erasure seed should fail"
  assert_hard_erase_mutation_fails \
    "CATALOG_SERVICE_WINDOW_HARD_ERASE_DUPLICATE_SEED_ID" \
    "hard erase matrix seed IDs must be unique" \
    "duplicate hard-erasure seed IDs should fail"
  assert_hard_erase_mutation_fails \
    "CATALOG_SERVICE_WINDOW_HARD_ERASE_MISSING_CLOCK" \
    "hard erase matrix before DB clock missing" \
    "missing hard-erasure DB clock should fail"
  assert_hard_erase_mutation_fails \
    "CATALOG_SERVICE_WINDOW_HARD_ERASE_MALFORMED_CLOCK" \
    "hard erase matrix before DB clock malformed" \
    "malformed hard-erasure DB clock should fail"
  assert_hard_erase_mutation_fails \
    "CATALOG_SERVICE_WINDOW_HARD_ERASE_REVERSED_CLOCK" \
    "hard erase matrix DB clock bounds are reversed" \
    "reversed hard-erasure DB clock bounds should fail"
  assert_hard_erase_mutation_fails \
    "CATALOG_SERVICE_WINDOW_HARD_ERASE_SNAPSHOT_MISSING_CASE" \
    "hard erase matrix snapshot must retain exactly 12 scoped rows" \
    "missing hard-erasure tombstone case should fail"
  assert_hard_erase_mutation_fails \
    "CATALOG_SERVICE_WINDOW_HARD_ERASE_SNAPSHOT_DUPLICATE_ID" \
    "hard erase matrix snapshot IDs must match seeded IDs exactly once" \
    "duplicate hard-erasure snapshot ID should fail"
  assert_hard_erase_mutation_fails \
    "CATALOG_SERVICE_WINDOW_HARD_ERASE_SNAPSHOT_MUTATE_OPAQUE" \
    "committed cleanup_phase expected exact_target_absence_required" \
    "mutated hard-erasure opaque tombstone state should fail"
  assert_hard_erase_mutation_fails \
    "CATALOG_SERVICE_WINDOW_HARD_ERASE_OUT_OF_WINDOW" \
    "committed erased_at outside hard-erasure DB clock window" \
    "out-of-window erased_at should fail"
  assert_hard_erase_mutation_fails \
    "CATALOG_SERVICE_WINDOW_HARD_ERASE_SNAPSHOT_UNSCRUBBED" \
    "committed non-opaque Algolia columns must be scrubbed" \
    "unscrubbed hard-erasure PII columns should fail"
  assert_hard_erase_mutation_fails \
    "CATALOG_SERVICE_WINDOW_HARD_ERASE_DEPENDENTS_RETAINED" \
    "hard erase matrix target-dependent rows must be absent" \
    "retained hard-erasure dependent rows should fail"
}

test_hard_erase_success_output_mutations_fail_closed() {
  setup_workspace
  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"
  assert_eq "$RUN_EXIT_CODE" "0" "hard-erasure success-output mutation baseline probe should pass"

  local missing_marker missing_status missing_evidence
  missing_marker="$(printf '%s\n' "$RUN_STDOUT" | sed 's/hard_erase_tombstone_matrix=passed//')"
  assert_hard_erase_verdict_contract_rejects "$missing_marker" \
    "omitting hard_erase_tombstone_matrix=passed should fail"
  missing_status="$(printf '%s\n' "$RUN_STDOUT" | sed 's/\"hard_erase_tombstone_matrix_status\":\"passed\"//')"
  assert_hard_erase_verdict_contract_rejects "$missing_status" \
    "omitting hard-erasure status should fail"
  missing_evidence="$(RUN_STDOUT="$RUN_STDOUT" python3 - <<'PY'
import os
print(os.environ["RUN_STDOUT"].replace('"hard_erase_tombstone_matrix_evidence":[', "", 1))
PY
  )"
  assert_hard_erase_verdict_contract_rejects "$missing_evidence" \
    "omitting hard-erasure per-case evidence should fail"
}

test_no_start_stack_requires_dedicated_integration_runtime_identity() {
  setup_workspace
  CATALOG_LIFECYCLE_SERVICE_WINDOW_RUNTIME_DIR="$WORK_DIR/catalog-service-window-runtime" \
  INTEGRATION_DB="fjcloud_dev" \
    run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack" --no-start-stack
  assert_eq "$RUN_EXIT_CODE" "1" "--no-start-stack should reject non-dedicated database names"
  assert_contains "$RUN_STDOUT" "--no-start-stack requires INTEGRATION_DB to name a dedicated catalog service window database" \
    "non-dedicated database failure is explicit"

  setup_workspace
  CATALOG_LIFECYCLE_SERVICE_WINDOW_RUNTIME_DIR="$WORK_DIR/runtime" \
    run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack" --no-start-stack
  assert_eq "$RUN_EXIT_CODE" "1" "--no-start-stack should reject ambiguous runtime dirs"
  assert_contains "$RUN_STDOUT" "--no-start-stack requires a dedicated catalog service window runtime dir" \
    "ambiguous runtime dir failure is explicit"
}

test_cold_seed_uses_database_url_docker_fallback_without_host_psql() {
  setup_workspace

  run_probe_without_host_psql --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack" --no-start-stack

  assert_eq "$RUN_EXIT_CODE" "0" "probe should seed cold snapshots through docker compose fallback when DATABASE_URL owns credentials"
  assert_contains "$(cat "$WORK_DIR/docker.log")" "compose ps --status running postgres" \
    "probe checks canonical docker compose postgres fallback"
  assert_contains "$(cat "$WORK_DIR/docker.log")" "psql -h 127.0.0.1 -U nondefault -d catalog_service_window_live_probe_test" \
    "docker fallback uses DATABASE_URL username and integration DB name"
  assert_contains "$(cat "$WORK_DIR/docker.log")" "env PGPASSWORD=secretpass" \
    "docker fallback uses DATABASE_URL password without requiring INTEGRATION_DB_PASSWORD"
  assert_contains "$(cat "$WORK_DIR/docker.log")" "catalog_service_window_hard_erase_matrix_seed" \
    "docker fallback seeds hard-erasure matrix rows"
  assert_contains "$(cat "$WORK_DIR/docker.log")" "catalog_service_window_hard_erase_matrix_clock" \
    "docker fallback captures hard-erasure DB clock bounds"
  assert_contains "$(cat "$WORK_DIR/docker.log")" "catalog_service_window_hard_erase_matrix_snapshot" \
    "docker fallback reads back hard-erasure tombstones"
}

test_probe_rejects_missing_catalog_row_evidence() {
  setup_workspace

  CATALOG_SERVICE_WINDOW_EMPTY_ROW_EVIDENCE=1 run_probe \
    --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"

  assert_eq "$RUN_EXIT_CODE" "1" "empty row-state lists should fail deterministic evidence checks"
  assert_contains "$RUN_STDOUT" "replica list missing probe row" \
    "replica row evidence is required"

  setup_workspace
  CATALOG_SERVICE_WINDOW_OMIT_MIGRATION_ROW=1 run_probe \
    --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"

  assert_eq "$RUN_EXIT_CODE" "1" "migration lists that omit the probe rows should fail"
  assert_contains "$RUN_STDOUT" "migration list missing probe row" \
    "migration row evidence is required"
}

test_probe_counts_calls_and_rejects_unrelated_state_change() {
  setup_workspace

  CATALOG_SERVICE_WINDOW_MUTATE_UNRELATED=1 run_probe \
    --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"

  assert_eq "$RUN_EXIT_CODE" "1" "changed unrelated tenant state should fail"
  assert_contains "$RUN_STDOUT" "unrelated tenant state changed" \
    "tenant isolation failure comes from before/after snapshots"
}

test_catalog_inventory_validator_fails_closed() {
  setup_workspace
  local bad_inventory="$WORK_DIR/fixtures/bad.json"

  printf '{not-json\n' > "$bad_inventory"
  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack" --inventory "$bad_inventory"
  assert_eq "$RUN_EXIT_CODE" "1" "non-JSON inventory should fail"
  assert_contains "$RUN_STDOUT" "catalog lifecycle writer inventory is not readable structured JSON" \
    "non-JSON inventory failure is explicit"

  python3 - "$DEFAULT_INVENTORY" "$bad_inventory" <<'PY'
import json
import sys
source, target = sys.argv[1:]
with open(source, encoding="utf-8") as handle:
    payload = json.load(handle)
payload["writers"] = payload["writers"][:-1]
with open(target, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack" --inventory "$bad_inventory"
  assert_eq "$RUN_EXIT_CODE" "1" "mismatched writer count should fail"
  assert_contains "$RUN_STDOUT" "writers length must equal total_writer_count" \
    "mismatched count failure is explicit"

  python3 - "$DEFAULT_INVENTORY" "$bad_inventory" <<'PY'
import json
import sys
source, target = sys.argv[1:]
with open(source, encoding="utf-8") as handle:
    payload = json.load(handle)
payload["writers"][0]["id"] = payload["writers"][1]["id"]
with open(target, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack" --inventory "$bad_inventory"
  assert_eq "$RUN_EXIT_CODE" "1" "duplicate writer IDs should fail"
  assert_contains "$RUN_STDOUT" "writer ids must be unique" "duplicate writer failure is explicit"

  python3 - "$DEFAULT_INVENTORY" "$bad_inventory" <<'PY'
import json
import sys
source, target = sys.argv[1:]
removed_id = "catalog_writer__infra_api_src_services_restore__execute_restore_inner__tenant_repo_set_cold_snapshot_id"
with open(source, encoding="utf-8") as handle:
    payload = json.load(handle)
payload["writers"] = [writer for writer in payload["writers"] if writer["id"] != removed_id]
payload["total_writer_count"] = len(payload["writers"])
with open(target, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack" --inventory "$bad_inventory"
  assert_eq "$RUN_EXIT_CODE" "1" "missing exact Stage 6 writer ID should fail despite owner path coverage"
  assert_contains "$RUN_STDOUT" "missing Stage 6 writer ids" \
    "exact Stage 6 writer coverage failure is explicit"
}

# shellcheck source=scripts/tests/catalog_lifecycle_service_window_soft_delete_cases.sh
source "$SCRIPT_DIR/catalog_lifecycle_service_window_soft_delete_cases.sh"

test_rejects_unknown_and_incomplete_arguments
test_probe_rejects_non_source_built_binary_provenance
test_help_documents_environment_contract_and_default_inventory
test_default_inventory_and_rejects_engine_inventory_shape
test_catalog_oracle_dependency_fails_closed
test_catalog_oracle_validator_fails_closed
test_soft_delete_inventory_denominator_success_contract
test_soft_delete_inventory_denominator_mutations_fail_closed
test_soft_delete_generation_fence_transition_contract
test_soft_delete_stale_operation_matrix_contract
test_soft_delete_generation_fence_mutations_fail_closed
test_soft_delete_stale_operation_mutations_fail_closed
test_soft_delete_hidden_target_mutations_fail_closed
test_soft_delete_observer_and_verdict_mutations_fail_closed
test_hard_erase_tombstone_matrix_route_and_evidence_contract
test_hard_erase_tombstone_matrix_mutations_fail_closed
test_hard_erase_success_output_mutations_fail_closed
test_recovery_seam_env_is_scoped_to_local_api_process
test_probe_drives_required_service_window_routes
test_restore_conflict_outcomes_are_probe_evidence
test_expired_worker_claim_reservation_blocks_route_and_service_writers
test_expired_worker_claim_reservation_mutations_fail_closed
test_expired_worker_claim_success_output_mutations_fail_closed
test_admin_cold_restore_filters_to_probe_snapshot
test_admin_cold_restore_uses_independent_index
test_migration_probes_use_active_source_index
test_existing_state_rerun_and_nonprovisioning_replica_are_accepted
test_no_start_stack_requires_dedicated_integration_runtime_identity
test_cold_seed_uses_database_url_docker_fallback_without_host_psql
test_probe_rejects_missing_catalog_row_evidence
test_probe_counts_calls_and_rejects_unrelated_state_change
test_catalog_inventory_validator_fails_closed

run_test_summary
