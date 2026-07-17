#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/catalog_lifecycle_service_window_live_probe.sh"
DEFAULT_INVENTORY="$REPO_ROOT/scripts/tests/fixtures/catalog_lifecycle_writers.json"

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

cleanup() {
  if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

write_mock_binaries() {
  write_mock_script "$WORK_DIR/bin/api" 'exit 0'
  write_mock_script "$WORK_DIR/bin/flapjack" 'exit 0'
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
    if [[ "$*" == *"service-window-isolation"* ]]; then
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
    if [[ "$*" == *"service-window-isolation"* ]]; then
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
  *)
    printf "{}\n200"
    ;;
esac
'
}

setup_workspace() {
  cleanup
  WORK_DIR="$(mktemp -d)"
  mkdir -p "$WORK_DIR/bin" "$WORK_DIR/no-psql-bin" "$WORK_DIR/fixtures"
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

run_probe() {
  RUN_EXIT_CODE=0
  : > "$WORK_DIR/curl.log"
  : > "$WORK_DIR/nohup.log"
  RUN_STDOUT="$(
    PATH="$WORK_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    FLAPJACK_DEV_DIR="$WORK_DIR" \
    CATALOG_SERVICE_WINDOW_CURL_LOG="$WORK_DIR/curl.log" \
    CATALOG_SERVICE_WINDOW_NOHUP_LOG="$WORK_DIR/nohup.log" \
    CATALOG_SERVICE_WINDOW_PSQL_LOG="$WORK_DIR/psql.log" \
    CATALOG_SERVICE_WINDOW_DOCKER_LOG="$WORK_DIR/docker.log" \
    CATALOG_SERVICE_WINDOW_EVENT_LOG="$WORK_DIR/events.log" \
    ENGINE_INDEX_IDENTITY_OBSERVED_CALLERS_FILE="$WORK_DIR/observed-callers.json" \
    CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_EMAIL="service-window-probe@example.com" \
    CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_PASSWORD="Integration-Test-Pass-1!" \
    CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_INDEX="catalog_service_window_source" \
    CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_NODE_API_KEY="observed-node-api-key" \
    CATALOG_LIFECYCLE_SERVICE_WINDOW_RUNTIME_DIR="$WORK_DIR/runtime" \
    INTEGRATION_DB="catalog_service_window_live_probe_test" \
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
  RUN_STDOUT="$(
    PATH="$WORK_DIR/no-psql-bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    FLAPJACK_DEV_DIR="$WORK_DIR" \
    CATALOG_SERVICE_WINDOW_CURL_LOG="$WORK_DIR/curl.log" \
    CATALOG_SERVICE_WINDOW_NOHUP_LOG="$WORK_DIR/nohup.log" \
    CATALOG_SERVICE_WINDOW_PSQL_LOG="$WORK_DIR/psql.log" \
    CATALOG_SERVICE_WINDOW_DOCKER_LOG="$WORK_DIR/docker.log" \
    CATALOG_SERVICE_WINDOW_EVENT_LOG="$WORK_DIR/events.log" \
    ENGINE_INDEX_IDENTITY_OBSERVED_CALLERS_FILE="$WORK_DIR/observed-callers.json" \
    CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_EMAIL="service-window-probe@example.com" \
    CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_PASSWORD="Integration-Test-Pass-1!" \
    CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_INDEX="catalog_service_window_source" \
    CATALOG_LIFECYCLE_SERVICE_WINDOW_PROBE_NODE_API_KEY="observed-node-api-key" \
    CATALOG_LIFECYCLE_SERVICE_WINDOW_RUNTIME_DIR="$WORK_DIR/runtime" \
    DATABASE_URL="postgres://nondefault:secretpass@127.0.0.1:15432/fjcloud_dev" \
    INTEGRATION_DB="catalog_service_window_live_probe_test" \
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
  assert_contains "$RUN_STDOUT" "API_PORT" "help documents API port env"
  assert_contains "$RUN_STDOUT" "FLAPJACK_PORT" "help documents engine port env"
  assert_contains "$RUN_STDOUT" "FJCLOUD_INTEGRATION_PID_DIR" "help documents integration runtime dir env"
  assert_contains "$RUN_STDOUT" "INTEGRATION_DB_URL" "help documents integration database URL env"
  assert_contains "$RUN_STDOUT" "CATALOG_LIFECYCLE_SERVICE_WINDOW_RUNTIME_DIR" "help documents service-window runtime dir env"
  assert_contains "$RUN_STDOUT" "scripts/tests/fixtures/catalog_lifecycle_writers.json" "help documents default catalog writer inventory"
}

test_default_inventory_and_rejects_engine_inventory_shape() {
  setup_workspace

  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"
  assert_eq "$RUN_EXIT_CODE" "0" "default catalog lifecycle inventory should pass"
  assert_contains "$RUN_STDOUT" "\"inventory\":\"scripts/tests/fixtures/catalog_lifecycle_writers.json\"" \
    "success output names default inventory"

  local engine_inventory="$WORK_DIR/fixtures/engine-inventory.json"
  cat > "$engine_inventory" <<'JSON'
{"expected_caller_count":1,"callers":[{"caller_id":"x","expected_upstream_kind":"catalog_only","expected_upstream_headers":{}}]}
JSON
  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack" --inventory "$engine_inventory"
  assert_eq "$RUN_EXIT_CODE" "1" "engine caller inventory shape should not be accepted"
  assert_contains "$RUN_STDOUT" "catalog lifecycle writer inventory requires version" \
    "catalog validator rejects second writer shape"
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

test_rejects_unknown_and_incomplete_arguments
test_help_documents_environment_contract_and_default_inventory
test_default_inventory_and_rejects_engine_inventory_shape
test_recovery_seam_env_is_scoped_to_local_api_process
test_probe_drives_required_service_window_routes
test_restore_conflict_outcomes_are_probe_evidence
test_admin_cold_restore_filters_to_probe_snapshot
test_admin_cold_restore_uses_independent_index
test_migration_probes_use_active_source_index
test_existing_state_rerun_and_nonprovisioning_replica_are_accepted
test_cold_seed_uses_database_url_docker_fallback_without_host_psql
test_probe_rejects_missing_catalog_row_evidence
test_probe_counts_calls_and_rejects_unrelated_state_change
test_catalog_inventory_validator_fails_closed

run_test_summary
