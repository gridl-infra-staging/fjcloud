#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/engine_index_identity_live_probe.sh"

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

setup_workspace() {
  cleanup
  WORK_DIR="$(mktemp -d)"
  mkdir -p "$WORK_DIR/bin" "$WORK_DIR/fixtures"
  : > "$WORK_DIR/curl.log"
  : > "$WORK_DIR/nohup.log"
  : > "$WORK_DIR/psql.log"

  write_mock_script "$WORK_DIR/bin/api" '
if [ -n "${ENGINE_INDEX_IDENTITY_TEST_OBSERVED_SEED_FILE:-}" ] \
    && [ -f "$ENGINE_INDEX_IDENTITY_TEST_OBSERVED_SEED_FILE" ]; then
  cp "$ENGINE_INDEX_IDENTITY_TEST_OBSERVED_SEED_FILE" \
    "$ENGINE_INDEX_IDENTITY_OBSERVED_CALLERS_FILE"
fi
exit 0
'
  write_mock_script "$WORK_DIR/bin/flapjack" 'exit 0'
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
printf "%s\n" "$*" >> "$ENGINE_INDEX_IDENTITY_PSQL_LOG"
if [[ "$*" == *"SELECT 1 FROM pg_database"* ]]; then
  echo "1"
fi
exit 0
'
  write_mock_script "$WORK_DIR/bin/nohup" '
printf "%s\n" "$*" >> "$ENGINE_INDEX_IDENTITY_NOHUP_LOG"
"$@" >/dev/null 2>&1 || true
exit 0
'
  write_mock_script "$WORK_DIR/bin/curl" '
set -euo pipefail
printf "%s\n" "$*" >> "$ENGINE_INDEX_IDENTITY_CURL_LOG"
url="${*: -1}"
status="${ENGINE_INDEX_IDENTITY_CURL_STATUS_OVERRIDE:-}"
if [ -n "$status" ] && [[ "$url" == *"/admin/migrations/cross-provider"* ]]; then
  printf "{\"migration_id\":\"11111111-1111-1111-1111-111111111111\",\"status\":\"pending\"}\n%s" "$status"
  exit 0
fi
case "$url" in
  *"/health")
    if [ "${ENGINE_INDEX_IDENTITY_FAIL_API_HEALTH:-}" = "1" ] \
        && [[ "$url" == *"localhost:${API_PORT:-3099}/health" ]]; then
      exit 1
    fi
    if [[ "$url" == *"localhost:${API_PORT:-3099}/health" ]] \
        && [ "${ENGINE_INDEX_IDENTITY_DISABLE_FAKE_OBSERVER:-}" != "1" ] \
        && [ -n "${ENGINE_INDEX_IDENTITY_TEST_OBSERVED_SEED_FILE:-}" ] \
        && [ -f "$ENGINE_INDEX_IDENTITY_TEST_OBSERVED_SEED_FILE" ]; then
      cp "$ENGINE_INDEX_IDENTITY_TEST_OBSERVED_SEED_FILE" \
        "$ENGINE_INDEX_IDENTITY_OBSERVED_CALLERS_FILE"
    fi
    exit 0
    ;;
  *"/auth/register")
    if [[ "$*" == *"identity-isolation"* ]]; then
      printf "{\"token\":\"isolation-register-token\",\"customer_id\":\"33333333-3333-3333-3333-333333333333\"}\n201"
    else
      printf "{\"token\":\"register-token\",\"customer_id\":\"11111111-1111-1111-1111-111111111111\"}\n201"
    fi
    ;;
  *"/auth/login")
    if [[ "$*" == *"identity-isolation"* ]]; then
      printf "{\"token\":\"isolation-login-token\",\"customer_id\":\"33333333-3333-3333-3333-333333333333\"}\n200"
    else
      printf "{\"token\":\"login-token\",\"customer_id\":\"11111111-1111-1111-1111-111111111111\"}\n200"
    fi
    ;;
  *"/indexes/engine_identity_source/metrics")
    printf "{\"index\":\"engine_identity_source\",\"documents_count\":11,\"storage_bytes\":22,\"search_requests_total\":33,\"write_operations_total\":44}\n200"
    ;;
  *"/indexes/engine_identity_source/batch")
    printf "{\"taskID\":1,\"objectIDs\":[\"engine-identity-doc-1\"]}\n200"
    ;;
  *"/indexes/engine_identity_source/replicas")
    if [[ "$*" == *"-X POST"* ]]; then
      printf "{\"id\":\"22222222-2222-2222-2222-222222222222\",\"status\":\"provisioning\"}\n201"
    else
      printf "[{\"id\":\"22222222-2222-2222-2222-222222222222\",\"status\":\"provisioning\"}]\n200"
    fi
    ;;
  *"/indexes/engine_identity_source/replicas/22222222-2222-2222-2222-222222222222")
    printf "{}\n204"
    ;;
  *"/indexes/engine_identity_source")
    if [[ "$*" == *"-X GET"* ]]; then
      index_count="$(grep -c -- "-X GET .*\/indexes\/engine_identity_source$" "$ENGINE_INDEX_IDENTITY_CURL_LOG" || true)"
      if [ "${ENGINE_INDEX_IDENTITY_UNRELATED_STATE_MUTATION:-}" = "1" ] && [ "$index_count" -gt 1 ]; then
        printf "{\"name\":\"engine_identity_source\",\"status\":\"ready\",\"entries\":99}\n200"
      else
        printf "{\"name\":\"engine_identity_source\",\"status\":\"ready\",\"entries\":0}\n200"
      fi
    else
      printf "{}\n204"
    fi
    ;;
  *"/indexes")
    printf "{}\n201"
    ;;
  *"/admin/migrations?status=active"*|*"/admin/migrations?status=completed"*)
    printf "[]\n200"
    ;;
  *"/admin/tenants/11111111-1111-1111-1111-111111111111/indexes")
    flapjack_port="${FLAPJACK_PORT:-7799}"
    printf "{\"name\":\"engine_identity_destination_seed\",\"region\":\"eu-central-1\",\"status\":\"healthy\",\"endpoint\":\"http://127.0.0.1:%s\"}\n201" "$flapjack_port"
    ;;
  *"/admin/vms")
    flapjack_port="${FLAPJACK_PORT:-7799}"
    printf "[{\"id\":\"00000000-0000-0000-0000-000000000002\",\"region\":\"eu-central-1\",\"flapjack_url\":\"http://127.0.0.1:%s\",\"hostname\":\"local-dev-eu-central-1\"}]\n200" "$flapjack_port"
    ;;
  *"/admin/migrations/cross-provider")
    printf "{\"migration_id\":\"11111111-1111-1111-1111-111111111111\",\"status\":\"completed\"}\n200"
    ;;
  *"/admin/migrations/probe/rollback-after-replication")
    printf "{\"migration_id\":\"11111111-1111-1111-1111-111111111112\",\"status\":\"rolled_back\",\"scenario\":\"rollback_after_replication\"}\n200"
    ;;
  *"/admin/migrations/probe/failure-after-replication")
    printf "{\"migration_id\":\"11111111-1111-1111-1111-111111111113\",\"status\":\"failed\",\"scenario\":\"failure_after_replication\"}\n200"
    ;;
  *"/admin/replicas"*)
    printf "[]\n200"
    ;;
  *"/api/1/indexes/"*|*"/indexes/"*|*"/admin/migrations"*|*"/admin/replicas"*)
    printf "{}\n200"
    ;;
  *)
    printf "{}\n200"
    ;;
esac
'
}

write_inventory() {
  local path="$1"
  local expected_count="$2"
  cat > "$path" <<JSON
{
  "expected_caller_count": $expected_count,
  "callers": [
    {
      "caller_id": "routes.indexes.index_metrics_route.get_index_metrics",
      "owner_path": "infra/api/src/routes/indexes/index_metrics_route.rs::get_index_metrics",
      "expected_upstream_kind": "physical_uid",
      "auth_secret_owner": "VmInventory::node_secret_id",
      "expected_upstream_path": "/metrics",
      "expected_upstream_headers": {
        "x-algolia-api-key": "sha256:*",
        "x-algolia-application-id": "flapjack"
      },
      "same_logical_name_isolation": true
    },
    {
      "caller_id": "routes.admin.migrations.list_migrations",
      "owner_path": "infra/api/src/routes/admin/migrations.rs::list_migrations",
      "expected_upstream_kind": "catalog_only",
      "auth_secret_owner": "no direct Flapjack request",
      "expected_upstream_path": null,
      "expected_upstream_headers": {},
      "same_logical_name_isolation": false
    }
  ]
}
JSON
}

write_observed() {
  local path="$1"
  shift
  python3 - "$path" "$@" <<'PY'
import hashlib
import json
import sys

path = sys.argv[1]
callers = sys.argv[2:]
physical_callers = {
    "routes.indexes.index_metrics_route.get_index_metrics",
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(
        {
            "status": "observed",
            "callers": [
                {
                    "caller_id": caller_id,
                    "observed_upstream_kind": "physical_uid" if caller_id in physical_callers else "catalog_only",
                    "physical_uid": "11111111111111111111111111111111_engine_identity_source" if caller_id in physical_callers else None,
                    "logical_uid": "engine_identity_source",
                    "auth_secret_owner": "VmInventory::node_secret_id" if caller_id in physical_callers else "no direct Flapjack request",
                    "auth_secret_id": "vm-engine-index-identity-source" if caller_id in physical_callers else None,
                    "node_secret_id": "vm-engine-index-identity-source" if caller_id in physical_callers else None,
                    "upstream_path": "/metrics" if caller_id in physical_callers else None,
                    "upstream_headers": {
                        "x-algolia-api-key": "sha256:" + hashlib.sha256(b"observed-node-api-key").hexdigest(),
                        "x-algolia-application-id": "flapjack",
                    } if caller_id in physical_callers else {},
                    "http_status": 200,
                    "terminal_migration_state": "completed",
                }
                for caller_id in callers
            ],
            "checks": {
                "identity": "checked",
                "auth": "checked",
                "status": "checked",
            },
        },
        handle,
    )
PY
}

write_mutated_observed_fixture() {
  local path="$1"
  local mutation="$2"
  python3 - "$path" "$mutation" <<'PY'
import copy
import hashlib
import json
import sys

path, mutation = sys.argv[1:]
base_callers = [
    {
        "caller_id": "routes.indexes.index_metrics_route.get_index_metrics",
        "observed_upstream_kind": "physical_uid",
        "physical_uid": "11111111111111111111111111111111_engine_identity_source",
        "logical_uid": "engine_identity_source",
        "auth_secret_owner": "VmInventory::node_secret_id",
        "auth_secret_id": "vm-engine-index-identity-source",
        "node_secret_id": "vm-engine-index-identity-source",
        "upstream_path": "/metrics",
        "upstream_headers": {
            "x-algolia-api-key": "sha256:" + hashlib.sha256(b"observed-node-api-key").hexdigest(),
            "x-algolia-application-id": "flapjack",
        },
        "http_status": 200,
        "terminal_migration_state": "completed",
    },
    {
        "caller_id": "routes.admin.migrations.list_migrations",
        "observed_upstream_kind": "catalog_only",
        "physical_uid": None,
        "logical_uid": "engine_identity_source",
        "auth_secret_owner": "no direct Flapjack request",
        "auth_secret_id": None,
        "upstream_path": None,
        "upstream_headers": {},
        "http_status": 200,
        "terminal_migration_state": "completed",
    },
]
payload = {
    "status": "observed",
    "callers": copy.deepcopy(base_callers),
    "checks": {
        "identity": "checked",
        "auth": "checked",
        "status": "checked",
    },
}

first = payload["callers"][0]
if mutation == "omitted_caller":
    payload["callers"] = payload["callers"][:1]
elif mutation == "logical_uid":
    first["physical_uid"] = first["logical_uid"]
elif mutation == "raw_vm_secret":
    first["auth_secret_owner"] = "vm.id"
    first["auth_secret_id"] = "00000000-0000-0000-0000-000000000001"
elif mutation == "sync_202":
    first["http_status"] = 202
elif mutation == "premature_terminal":
    first["terminal_migration_state"] = "running"
elif mutation == "cross_tenant_collision":
    pass
else:
    raise SystemExit(f"unknown mutation {mutation}")
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
}

mutate_observed_upstream_value() {
  local path="$1"
  local mutation="$2"
  python3 - "$path" "$mutation" <<'PY'
import json
import sys

path, mutation = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
physical = payload["callers"][0]
if mutation == "wrong_path":
    physical["upstream_path"] = "/wrong-but-present"
elif mutation == "wrong_auth_header":
    physical["upstream_headers"]["x-algolia-api-key"] = "<redacted>"
elif mutation == "wrong_valid_auth_digest":
    physical["upstream_headers"]["x-algolia-api-key"] = "sha256:" + "0" * 64
elif mutation == "wrong_app_id_header":
    physical["upstream_headers"]["x-algolia-application-id"] = "wrong-but-present"
else:
    raise SystemExit(f"unknown upstream mutation {mutation}")
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
}

fixture_json_field() {
  local fixture="$1"
  local field="$2"
  python3 - "$fixture" "$field" <<'PY'
import json
import sys

fixture, field = sys.argv[1:]
with open(fixture, encoding="utf-8") as handle:
    value = json.load(handle).get(field)
if not isinstance(value, str) or not value:
    raise SystemExit(f"{fixture} missing string field {field}")
print(value)
PY
}

write_unchecked_observed() {
  local path="$1"
  cat > "$path" <<'JSON'
{
  "status": "skipped",
  "callers": [{"caller_id": "routes.indexes.index_metrics_route.get_index_metrics"}],
  "checks": {
    "identity": "checked",
    "auth": "unchecked",
    "status": "checked",
    "tenant_isolation": "checked"
  }
}
JSON
}

run_probe() {
  local inventory="$1"
  local observed="$2"
  shift 2
  local observed_seed="$WORK_DIR/observed-seed.json"
  rm -f "$observed_seed"
  if [ "${ENGINE_INDEX_IDENTITY_DISABLE_FAKE_OBSERVER:-}" != "1" ] && [ -f "$observed" ]; then
    cp "$observed" "$observed_seed"
  fi
  : > "$WORK_DIR/curl.log"
  RUN_EXIT_CODE=0
  RUN_STDOUT="$(
    PATH="$WORK_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    FLAPJACK_DEV_DIR="$WORK_DIR" \
    FJCLOUD_INTEGRATION_API_BINARY="$WORK_DIR/bin/api" \
    FJCLOUD_INTEGRATION_ENGINE_BINARY="$WORK_DIR/bin/flapjack" \
    ENGINE_INDEX_IDENTITY_OBSERVED_CALLERS_FILE="$observed" \
    ENGINE_INDEX_IDENTITY_TEST_OBSERVED_SEED_FILE="$observed_seed" \
    ENGINE_INDEX_IDENTITY_CURL_LOG="$WORK_DIR/curl.log" \
    ENGINE_INDEX_IDENTITY_NOHUP_LOG="$WORK_DIR/nohup.log" \
    ENGINE_INDEX_IDENTITY_PSQL_LOG="$WORK_DIR/psql.log" \
    ENGINE_INDEX_IDENTITY_PROBE_EMAIL="identity-probe@example.com" \
    ENGINE_INDEX_IDENTITY_PROBE_PASSWORD="Integration-Test-Pass-1!" \
    ENGINE_INDEX_IDENTITY_PROBE_INDEX="engine_identity_source" \
    ENGINE_INDEX_IDENTITY_PROBE_NODE_API_KEY="observed-node-api-key" \
    INTEGRATION_DB="engine_index_identity_live_probe_test" \
    API_PORT=38111 \
    INTEGRATION_S3_PORT=38112 \
    FLAPJACK_PORT=37811 \
    METERING_AGENT_HEALTH_PORT=39192 \
    INTEGRATION_HEALTH_TIMEOUT=1 \
    bash "$TARGET_SCRIPT" \
      --api-binary "$WORK_DIR/bin/api" \
      --engine-binary "$WORK_DIR/bin/flapjack" \
      --inventory "$inventory" \
      "$@" 2>&1
  )" || RUN_EXIT_CODE=$?
}

test_rejects_relative_binary_paths() {
  setup_workspace
  local inventory="$WORK_DIR/fixtures/inventory.json"
  write_inventory "$inventory" 2
  RUN_EXIT_CODE=0
  RUN_STDOUT="$(
    bash "$TARGET_SCRIPT" \
      --api-binary relative-api \
      --engine-binary "$WORK_DIR/bin/flapjack" \
      --inventory "$inventory" 2>&1
  )" || RUN_EXIT_CODE=$?

  assert_eq "$RUN_EXIT_CODE" "1" "relative API binary should fail"
  assert_contains "$RUN_STDOUT" "--api-binary must be an absolute executable path" \
    "relative API binary error names the contract"
}

test_requires_non_empty_inventory() {
  setup_workspace
  local inventory="$WORK_DIR/fixtures/inventory.json"
  local observed="$WORK_DIR/observed.json"
  write_inventory "$inventory" 0
  write_observed "$observed" "routes.indexes.index_metrics_route.get_index_metrics"

  run_probe "$inventory" "$observed"

  assert_eq "$RUN_EXIT_CODE" "1" "empty expected caller count should fail"
  assert_contains "$RUN_STDOUT" "expected_caller_count must be greater than zero" \
    "empty inventory failure is explicit"
}

test_fails_when_observed_artifact_is_missing() {
  setup_workspace
  local inventory="$WORK_DIR/fixtures/inventory.json"
  local observed="$WORK_DIR/missing-observed.json"
  write_inventory "$inventory" 2

  run_probe "$inventory" "$observed"

  assert_eq "$RUN_EXIT_CODE" "1" "missing observed artifact should fail"
  assert_contains "$RUN_STDOUT" "observed caller artifact is missing" \
    "missing observed artifact is explicit"
}

test_rejects_stale_observed_artifact_when_current_api_emits_nothing() {
  setup_workspace
  local inventory="$WORK_DIR/fixtures/inventory.json"
  local observed="$WORK_DIR/observed.json"
  write_inventory "$inventory" 2
  write_observed "$observed" \
    "routes.indexes.index_metrics_route.get_index_metrics" \
    "routes.admin.migrations.list_migrations"

  ENGINE_INDEX_IDENTITY_DISABLE_FAKE_OBSERVER=1 run_probe "$inventory" "$observed"

  assert_eq "$RUN_EXIT_CODE" "1" "stale caller evidence should not satisfy a new run"
  assert_contains "$RUN_STDOUT" "observed caller artifact is missing" \
    "probe requires the current API process to emit coverage"
}

test_partial_startup_failure_runs_integration_teardown() {
  setup_workspace
  local inventory="$WORK_DIR/fixtures/inventory.json"
  local observed="$WORK_DIR/observed.json"
  write_inventory "$inventory" 2
  write_observed "$observed" \
    "routes.indexes.index_metrics_route.get_index_metrics" \
    "routes.admin.migrations.list_migrations"

  ENGINE_INDEX_IDENTITY_FAIL_API_HEALTH=1 run_probe "$inventory" "$observed"

  assert_eq "$RUN_EXIT_CODE" "1" "partial API startup should fail the probe"
  assert_contains "$(cat "$WORK_DIR/psql.log")" "DROP DATABASE" \
    "partial startup invokes integration-down database cleanup"
}

test_fails_when_observed_callers_differ_from_inventory() {
  setup_workspace
  local inventory="$WORK_DIR/fixtures/inventory.json"
  local observed="$WORK_DIR/observed.json"
  write_inventory "$inventory" 2
  write_observed "$observed" "routes.indexes.index_metrics_route.get_index_metrics"

  run_probe "$inventory" "$observed"

  assert_eq "$RUN_EXIT_CODE" "1" "caller mismatch should fail"
  assert_contains "$RUN_STDOUT" "observed caller IDs do not match inventory" \
    "caller mismatch names coverage equality"
}

test_fails_on_skipped_or_unchecked_observed_state() {
  setup_workspace
  local inventory="$WORK_DIR/fixtures/inventory.json"
  local observed="$WORK_DIR/observed.json"
  write_inventory "$inventory" 2
  write_unchecked_observed "$observed"

  run_probe "$inventory" "$observed"

  assert_eq "$RUN_EXIT_CODE" "1" "skipped or unchecked state should fail"
  assert_contains "$RUN_STDOUT" "observed caller artifact reports skipped or unchecked state" \
    "skipped state failure is explicit"
}

test_matching_inventory_and_observed_callers_pass() {
  setup_workspace
  local inventory="$WORK_DIR/fixtures/inventory.json"
  local observed="$WORK_DIR/observed.json"
  write_inventory "$inventory" 2
  write_observed "$observed" \
    "routes.indexes.index_metrics_route.get_index_metrics" \
    "routes.admin.migrations.list_migrations"

  run_probe "$inventory" "$observed"

  assert_eq "$RUN_EXIT_CODE" "0" "matching caller coverage should pass"
  assert_contains "$RUN_STDOUT" "\"status\":\"pass\"" "success prints structured pass JSON"
  assert_contains "$(cat "$WORK_DIR/nohup.log")" "$WORK_DIR/bin/api" \
    "probe starts caller-supplied API binary through integration-up"
  assert_contains "$(cat "$WORK_DIR/nohup.log")" "$WORK_DIR/bin/flapjack" \
    "probe starts caller-supplied engine binary through integration-up"
}

test_probe_drives_required_api_entrypoints() {
  setup_workspace
  local inventory="$WORK_DIR/fixtures/inventory.json"
  local observed="$WORK_DIR/observed.json"
  write_inventory "$inventory" 2
  write_observed "$observed" \
    "routes.indexes.index_metrics_route.get_index_metrics" \
    "routes.admin.migrations.list_migrations"

  run_probe "$inventory" "$observed"

  assert_eq "$RUN_EXIT_CODE" "0" "required API entrypoint drive should pass"
  local curl_log
  curl_log="$(cat "$WORK_DIR/curl.log")"
  assert_contains "$curl_log" "/auth/register" "probe registers a live user"
  assert_contains "$curl_log" "identity-isolation" \
    "probe registers and logs in an unrelated same-name tenant"
  assert_contains "$curl_log" "authorization: Bearer isolation-login-token" \
    "probe drives the unrelated tenant through its own authenticated boundary"
  assert_contains "$curl_log" "/auth/login" "probe logs in for a tenant JWT"
  assert_contains "$curl_log" "/indexes/engine_identity_source/metrics" \
    "probe drives same-name tenant metrics"
  assert_contains "$curl_log" "/indexes/engine_identity_source/batch" \
    "probe seeds source engine state through the document boundary"
  assert_contains "$curl_log" "/indexes/engine_identity_source/replicas" \
    "probe drives customer replica create/list"
  assert_contains "$curl_log" "/indexes/engine_identity_source/replicas/22222222-2222-2222-2222-222222222222" \
    "probe drives customer replica delete/status target"
  assert_contains "$curl_log" "/admin/migrations/cross-provider" \
    "probe drives explicit cross-provider admin migration execute"
  assert_contains "$curl_log" "/admin/migrations/probe/rollback-after-replication" \
    "probe drives the replicating rollback recovery boundary"
  assert_contains "$curl_log" "/admin/migrations/probe/failure-after-replication" \
    "probe drives the after-replication failure recovery boundary"
  assert_contains "$curl_log" "/admin/migrations?status=active" \
    "probe drives admin migration active list"
  assert_contains "$curl_log" '"customer_id":"11111111-1111-1111-1111-111111111111"' \
    "probe selects the intended same-name tenant for migration"
  assert_contains "$curl_log" "/admin/tenants/11111111-1111-1111-1111-111111111111/indexes" \
    "probe seeds destination VM capacity through existing admin boundary"
  assert_contains "$curl_log" "/admin/vms" "probe discovers the seeded destination VM"
  assert_contains "$curl_log" '"dest_vm_id":"00000000-0000-0000-0000-000000000002"' \
    "probe passes the discovered destination VM ID to migration"
  assert_contains "$curl_log" "/admin/replicas" "probe drives admin replica inventory"
  assert_contains "$curl_log" "-X DELETE" "probe drives destructive cleanup routes"
}

test_probe_rejects_non_terminal_migration_status() {
  setup_workspace
  local inventory="$WORK_DIR/fixtures/inventory.json"
  local observed="$WORK_DIR/observed.json"
  write_inventory "$inventory" 2
  write_observed "$observed" \
    "routes.indexes.index_metrics_route.get_index_metrics" \
    "routes.admin.migrations.list_migrations"

  ENGINE_INDEX_IDENTITY_CURL_STATUS_OVERRIDE=202 run_probe "$inventory" "$observed"

  assert_eq "$RUN_EXIT_CODE" "1" "non-terminal admin migration response should fail"
  assert_contains "$RUN_STDOUT" "admin migration execute expected HTTP 200 with completed status" \
    "migration status failure names terminal status contract"
}

test_probe_rejects_non_exact_upstream_values() {
  setup_workspace
  local inventory="$WORK_DIR/fixtures/inventory.json"
  write_inventory "$inventory" 2

  local mutation expected observed
  for mutation in wrong_path wrong_auth_header wrong_valid_auth_digest wrong_app_id_header; do
    observed="$WORK_DIR/${mutation}.json"
    write_observed "$observed" \
      "routes.indexes.index_metrics_route.get_index_metrics" \
      "routes.admin.migrations.list_migrations"
    case "$mutation" in
      wrong_path)
        expected="upstream path does not match inventory"
        ;;
      wrong_auth_header)
        expected="upstream auth header was not observed"
        ;;
      wrong_valid_auth_digest)
        expected="upstream auth header does not match expected node credential"
        ;;
      wrong_app_id_header)
        expected="upstream headers do not match inventory"
        ;;
    esac

    mutate_observed_upstream_value "$observed" "$mutation"
    run_probe "$inventory" "$observed"
    assert_eq "$RUN_EXIT_CODE" "1" "$mutation mutation should fail closed"
    assert_contains "$RUN_STDOUT" "$expected" "$mutation mutation reports exact-value mismatch"
  done
}

test_probe_rejects_changed_unrelated_tenant_snapshot() {
  setup_workspace
  local inventory="$WORK_DIR/fixtures/inventory.json"
  local observed="$WORK_DIR/observed.json"
  write_inventory "$inventory" 2
  write_observed "$observed" \
    "routes.indexes.index_metrics_route.get_index_metrics" \
    "routes.admin.migrations.list_migrations"

  ENGINE_INDEX_IDENTITY_UNRELATED_STATE_MUTATION=1 run_probe "$inventory" "$observed"

  assert_eq "$RUN_EXIT_CODE" "1" "changed unrelated tenant state should fail"
  assert_contains "$RUN_STDOUT" "unrelated tenant state changed" \
    "tenant isolation failure comes from the live before/after snapshot"
}

test_probe_rejects_placeholder_auth_observation() {
  setup_workspace
  local inventory="$WORK_DIR/fixtures/inventory.json"
  local observed="$WORK_DIR/observed.json"
  write_inventory "$inventory" 2
  write_observed "$observed" \
    "routes.indexes.index_metrics_route.get_index_metrics" \
    "routes.admin.migrations.list_migrations"
  mutate_observed_upstream_value "$observed" wrong_auth_header

  run_probe "$inventory" "$observed"

  assert_eq "$RUN_EXIT_CODE" "1" "placeholder auth observation should fail"
  assert_contains "$RUN_STDOUT" "upstream auth header was not observed" \
    "placeholder auth failure names actual-header evidence"
}

test_mutation_fixtures_fail_closed_for_identity_and_status_regressions() {
  setup_workspace
  local inventory="$WORK_DIR/fixtures/inventory.json"
  write_inventory "$inventory" 2

  local fixture mutation expected
  for fixture in \
    "$SCRIPT_DIR/fixtures/engine_index_identity_mutation_omitted_caller.json" \
    "$SCRIPT_DIR/fixtures/engine_index_identity_mutation_logical_uid.json" \
    "$SCRIPT_DIR/fixtures/engine_index_identity_mutation_raw_vm_secret.json" \
    "$SCRIPT_DIR/fixtures/engine_index_identity_mutation_sync_202.json" \
    "$SCRIPT_DIR/fixtures/engine_index_identity_mutation_premature_terminal.json" \
    "$SCRIPT_DIR/fixtures/engine_index_identity_mutation_cross_tenant_collision.json"
  do
    mutation="$(fixture_json_field "$fixture" mutation)"
    expected="$(fixture_json_field "$fixture" expected_failure)"
    local observed="$WORK_DIR/${mutation}.json"
    write_mutated_observed_fixture "$observed" "$mutation"
    if [ "$mutation" = "cross_tenant_collision" ]; then
      ENGINE_INDEX_IDENTITY_UNRELATED_STATE_MUTATION=1 run_probe "$inventory" "$observed"
    else
      run_probe "$inventory" "$observed"
    fi
    assert_eq "$RUN_EXIT_CODE" "1" "$mutation mutation should fail closed"
    assert_contains "$RUN_STDOUT" "$expected" "$mutation mutation reports intended reason"
  done
}

test_rejects_relative_binary_paths
test_requires_non_empty_inventory
test_fails_when_observed_artifact_is_missing
test_rejects_stale_observed_artifact_when_current_api_emits_nothing
test_partial_startup_failure_runs_integration_teardown
test_fails_when_observed_callers_differ_from_inventory
test_fails_on_skipped_or_unchecked_observed_state
test_matching_inventory_and_observed_callers_pass
test_probe_drives_required_api_entrypoints
test_probe_rejects_non_terminal_migration_status
test_probe_rejects_non_exact_upstream_values
test_probe_rejects_placeholder_auth_observation
test_probe_rejects_changed_unrelated_tenant_snapshot
test_mutation_fixtures_fail_closed_for_identity_and_status_regressions

run_test_summary
