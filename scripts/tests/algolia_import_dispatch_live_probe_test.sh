#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/algolia_import_dispatch_live_probe.sh"

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

setup_workspace() {
  cleanup
  WORK_DIR="$(mktemp -d)"
  mkdir -p "$WORK_DIR/bin" "$WORK_DIR/flapjack_dev/engine" "$WORK_DIR/runtime" "$WORK_DIR/pids"
  : > "$WORK_DIR/curl.log"
  : > "$WORK_DIR/psql.log"
  : > "$WORK_DIR/sleep.log"
  : > "$WORK_DIR/up.log"
  : > "$WORK_DIR/down.log"
  : > "$WORK_DIR/contract_check.log"
  touch "$WORK_DIR/flapjack_dev/engine/Cargo.toml"
  printf '[package]\nname = "flapjack-server"\n' > "$WORK_DIR/flapjack_dev/engine/Cargo.toml"
  printf 'ALGOLIA_APP_ID=TESTAPP123\nALGOLIA_ADMIN_KEY=algolia-admin-secret\nALGOLIA_SEARCH_KEY=must-not-load\n' > "$WORK_DIR/secret.env"

  write_fake_command "$WORK_DIR/up.sh" '#!/usr/bin/env bash
set -euo pipefail
printf "db=%s pid_dir=%s enabled=%s preserve=%s\n" "${INTEGRATION_DB:-}" "${FJCLOUD_INTEGRATION_PID_DIR:-}" "${FJCLOUD_ALGOLIA_MIGRATION_ENABLED:-}" "${FJCLOUD_INTEGRATION_PRESERVE_DB:-}" >> "$UP_LOG"
mkdir -p "$FJCLOUD_INTEGRATION_PID_DIR"
printf "123\n" > "$FJCLOUD_INTEGRATION_PID_DIR/api.pid"
printf "456\n" > "$FJCLOUD_INTEGRATION_PID_DIR/flapjack.pid"
if [ "${LEAK_KEY_TO_LOG:-0}" = "1" ]; then
  printf "api log leaked disposable-restricted-key\n" > "$FJCLOUD_INTEGRATION_PID_DIR/api.log"
else
  printf "api log without secrets\n" > "$FJCLOUD_INTEGRATION_PID_DIR/api.log"
fi
printf "engine log without secrets\n" > "$FJCLOUD_INTEGRATION_PID_DIR/flapjack.log"
if [ "${WRITE_DOCUMENT_CANARY_TO_RUNTIME:-0}" = "1" ]; then
  printf "fjcloud_import_dispatch_probe_test_canary\n" >> "$FJCLOUD_INTEGRATION_PID_DIR/flapjack.log"
fi
'

  write_fake_command "$WORK_DIR/down.sh" '#!/usr/bin/env bash
set -euo pipefail
printf "db=%s pid_dir=%s\n" "${INTEGRATION_DB:-}" "${FJCLOUD_INTEGRATION_PID_DIR:-}" >> "$DOWN_LOG"
rm -f "$FJCLOUD_INTEGRATION_PID_DIR"/*.pid "$FJCLOUD_INTEGRATION_PID_DIR"/*.log 2>/dev/null || true
rmdir "$FJCLOUD_INTEGRATION_PID_DIR" 2>/dev/null || true
if [ "${DOWN_SCENARIO:-success}" = "failure_after_pid_cleanup" ]; then
  exit 1
fi
'

  write_fake_command "$WORK_DIR/contract_check.sh" '#!/usr/bin/env bash
set -euo pipefail
printf "flapjack_dev_dir=%s args=%s\n" "${FLAPJACK_DEV_DIR:-}" "$*" >> "$CONTRACT_CHECK_LOG"
if [ "${CONTRACT_CHECK_SCENARIO:-success}" = "mismatch" ]; then
  exit 1
fi
'

  write_fake_command "$WORK_DIR/bin/psql" '#!/usr/bin/env bash
set -euo pipefail
printf "%s\n" "$*" >> "$PSQL_LOG"
scenario="${PSQL_SCENARIO:-success}"
case "$*" in
  *"probe:cancel_intent"*)
    [ "$scenario" = "cancel_intent_missing" ] && { printf "0\n"; exit 0; }
    printf "1\n" ;;
  *"probe:reserved_active"*)
    [ "$scenario" = "lease_duplicated" ] && { printf "2\n"; exit 0; }
    [ "$scenario" = "lease_lost" ] && { printf "0\n"; exit 0; }
    printf "1\n" ;;
  *"probe:released"*)
    [ "$scenario" = "lease_released" ] && { printf "1\n"; exit 0; }
    printf "0\n" ;;
  *"probe:force_expiry"*)
    [ "$scenario" = "force_expiry_fails" ] && exit 1
    case "$scenario" in
      reidentity_after_expiry) touch "$WORK_DIR/reident.flag" ;;
      turnover_write_without_active_lease) touch "$WORK_DIR/turnover.flag" ;;
    esac
    printf "UPDATE 1\n" ;;
  *"probe:engine_identity"*)
    if [ "$scenario" = "reidentity_after_expiry" ] && [ -f "$WORK_DIR/reident.flag" ]; then
      printf "engine-2\n"; exit 0
    fi
    printf "11111111-1111-4111-8111-111111111111\n" ;;
  *"probe:fresh_lease"*)
    [ "$scenario" = "turnover_missing" ] && { printf "0\n"; exit 0; }
    [ "$scenario" = "turnover_write_without_active_lease" ] && { printf "0\n"; exit 0; }
    if [ "$scenario" = "turnover_after_wait" ]; then
      sleep_count="$(wc -l < "$SLEEP_LOG" | tr -d "[:space:]")"
      [ "${sleep_count:-0}" -ge 2 ] && { printf "1\n"; exit 0; }
      printf "0\n"
      exit 0
    fi
    printf "1\n" ;;
  *"probe:updated_epoch"*)
    if [ "$scenario" = "turnover_write_without_active_lease" ] && [ -f "$WORK_DIR/turnover.flag" ]; then
      printf "101\n"; exit 0
    fi
    printf "100\n" ;;
  *"probe:secret_leak"*)
    [ "$scenario" = "secret_match" ] && { printf "1\n"; exit 0; }
    printf "0\n" ;;
  *"probe:alert_duplicates"*)
    [ "$scenario" = "alert_duplicates" ] && { printf "1\n"; exit 0; }
    printf "0\n" ;;
  *"probe:database_residue"*)
    [ "$scenario" = "database_residue" ] && { printf "1\n"; exit 0; }
    printf "0\n" ;;
  *)
    printf "0\n" ;;
esac
'

  write_fake_command "$WORK_DIR/bin/sleep" '#!/usr/bin/env bash
printf "sleep %s\n" "${1:-}" >> "$SLEEP_LOG"
'

  write_fake_command "$WORK_DIR/bin/curl" '#!/usr/bin/env bash
set -euo pipefail
printf "%s\n" "$*" >> "$CURL_LOG"
method="GET"
data_file=""
url=""
header_dump_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X|--request) method="$2"; shift 2 ;;
    --data|-d|--data-binary) data_file="${2#@}"; shift 2 ;;
    --config|-K)
      if [ -f "$2" ]; then
        cfg_url="$(sed -n "s/^url = \"\\(.*\\)\"$/\\1/p" "$2" | tail -1)"
        [ -n "$cfg_url" ] && url="$cfg_url"
      fi
      shift 2
      ;;
    -D) header_dump_file="$2"; shift 2 ;;
    -H|--header|--connect-timeout|--max-time|-w) shift 2 ;;
    -s|-S|-sS|-f|-L) shift ;;
    *) url="$1"; shift ;;
  esac
done

case "$method $url" in
  "GET http://127.0.0.1:3099/health")
    [ "${CURL_SCENARIO:-success}" = "api_down" ] && { printf "down\n503"; exit 0; }
    printf "{\"status\":\"ok\"}\n200"
    ;;
  "GET http://127.0.0.1:7799/health")
    printf "{\"status\":\"ok\",\"version\":\"1.0.10\",\"build\":{\"dirty\":false}}\n200"
    ;;
  "GET http://127.0.0.1:7799/1/migrations/algolia/11111111-1111-4111-8111-111111111111")
    if [ "${CURL_SCENARIO:-success}" = "engine_status_missing" ]; then
      printf "{\"code\":\"migration_job_not_found\"}\n404"
    else
      printf "{\"jobId\":\"11111111-1111-4111-8111-111111111111\",\"phase\":\"exporting\",\"disposition\":\"running\",\"createdAt\":\"2026-07-22T00:00:00Z\",\"updatedAt\":\"2026-07-22T00:00:02Z\",\"exportProgress\":{\"completed\":0,\"total\":1}}\n200"
    fi
    ;;
  "GET https://testapp123.algolia.net/1/indexes/"*)
    if [[ "$url" == *"browse"* ]]; then
      printf "{\"hits\":[{\"objectID\":\"doc-1\"}]}\n200"
    else
      printf "{\"message\":\"not found\"}\n404"
    fi
    ;;
  "GET https://testapp123.algolia.net/1/indexes?page=0&hitsPerPage=100")
    if [ "${ALGOLIA_RESIDUE:-0}" = "1" ]; then
      printf "{\"items\":[{\"name\":\"fjcloud_import_dispatch_probe_test_leftover\"},{\"name\":\"unrelated\"}]}\n200"
    else
      printf "{\"items\":[{\"name\":\"unrelated\"}]}\n200"
    fi
    ;;
  "POST https://testapp123.algolia.net/1/indexes/"*"/batch")
    if [ "${CURL_SCENARIO:-success}" = "unsafe_task_id" ]; then
      printf "{\"taskID\":\"task/../../keys\"}\n200"
    else
      printf "{\"taskID\":1}\n200"
    fi
    ;;
  "GET https://testapp123.algolia.net/1/indexes/"*"/task/1")
    printf "{\"status\":\"published\"}\n200"
    ;;
  "POST https://testapp123.algolia.net/1/keys")
    if [ "${CURL_SCENARIO:-success}" = "unsafe_algolia_key" ]; then
      printf "{\"key\":\"key-123;DROP_TABLE\"}\n201"
    else
      printf "{\"key\":\"disposable-restricted-key\"}\n201"
    fi
    ;;
  "DELETE https://testapp123.algolia.net/1/keys/disposable-restricted-key")
    printf "{}\n200"
    ;;
  "GET https://testapp123.algolia.net/1/keys/disposable-restricted-key")
    if [ "${FAKE_ALGOLIA_KEY_RESIDUE:-0}" = "1" ]; then
      printf "{\"value\":\"disposable-restricted-key\"}\n200"
    else
      printf "{\"message\":\"key not found\"}\n404"
    fi
    ;;
  "DELETE https://testapp123.algolia.net/1/indexes/"*)
    if [ "${ALGOLIA_DELETE_TASK:-0}" = "1" ]; then
      printf "{\"taskID\":1}\n200"
    else
      printf "{}\n200"
    fi
    ;;
  "POST http://127.0.0.1:3099/auth/register")
    printf "{\"token\":\"register-token\",\"customer_id\":\"00000000-0000-4000-8000-000000000111\"}\n201"
    ;;
  "POST http://127.0.0.1:3099/auth/login")
    if [ "${CURL_SCENARIO:-success}" = "unsafe_tenant_token" ]; then
      printf "{\"token\":\"tenant-token\\\\nurl-injected\",\"customer_id\":\"00000000-0000-4000-8000-000000000111\"}\n200"
    else
      printf "{\"token\":\"tenant-token\",\"customer_id\":\"00000000-0000-4000-8000-000000000111\"}\n200"
    fi
    ;;
  "POST http://127.0.0.1:3099/indexes")
    if [ "${CURL_SCENARIO:-success}" = "node_key_warmup_fail" ]; then
      printf "{\"error\":\"backend unavailable\"}\n503"
    else
      printf "{\"name\":\"fjcloud_import_dispatch_probe_test_warmup\",\"region\":\"us-east-1\"}\n201"
    fi
    ;;
  "DELETE http://127.0.0.1:3099/indexes/fjcloud_import_dispatch_probe_test_warmup")
    printf "\n204"
    ;;
  "POST http://127.0.0.1:3099/migration/algolia/destination-eligibility")
    if [ -n "$data_file" ] && grep -q "\"phase\":\"provider\"" "$data_file"; then
      if [ "${CURL_SCENARIO:-success}" = "unsafe_eligibility_token" ]; then
        printf "{\"phase\":\"provider\",\"mode\":\"create\",\"provider\":\"aws\",\"target\":{\"kind\":\"create\",\"region\":\"us-east-1\",\"name\":\"target\"},\"eligibilityToken\":\"provider-token\\\\nurl-injected\",\"expiresAt\":\"2026-07-22T00:00:00Z\"}\n200"
      else
        printf "{\"phase\":\"provider\",\"mode\":\"create\",\"provider\":\"aws\",\"target\":{\"kind\":\"create\",\"region\":\"us-east-1\",\"name\":\"target\"},\"eligibilityToken\":\"provider.token_+=\",\"expiresAt\":\"2026-07-22T00:00:00Z\"}\n200"
      fi
    else
      printf "{\"phase\":\"target\",\"mode\":\"create\",\"provider\":\"aws\",\"target\":{\"kind\":\"create\",\"region\":\"us-east-1\",\"name\":\"target\"},\"eligibilityToken\":\"target/token+=\",\"expiresAt\":\"2026-07-22T00:00:00Z\"}\n200"
    fi
    ;;
  "POST http://127.0.0.1:3099/migration/algolia/jobs")
    if [ "${CURL_SCENARIO:-success}" = "inconclusive_create" ]; then
      printf "{\"id\":\"job-123\"}\n200"
      exit 0
    fi
    job_id="job-123"
    [ "${CURL_SCENARIO:-success}" = "unsafe_job_id" ] && job_id="job-123;DROP_TABLE"
    [ -n "$header_dump_file" ] && printf "HTTP/1.1 202 Accepted\r\nLocation: /migration/algolia/jobs/%s\r\n\r\n" "$job_id" > "$header_dump_file"
    printf "{\"id\":\"%s\",\"status\":\"queued\",\"mode\":\"create\",\"destination\":{\"kind\":\"create\",\"target\":\"target\",\"region\":\"us-east-1\"},\"source\":{\"appId\":\"TESTAPP123\",\"name\":\"source\"},\"summary\":{\"documentsExpected\":1,\"documentsImported\":0,\"documentsRejected\":0,\"settingsApplied\":0,\"settingsUnsupported\":0,\"synonymsExpected\":0,\"synonymsImported\":0,\"synonymsRejected\":0,\"rulesExpected\":0,\"rulesImported\":0,\"rulesRejected\":0},\"warnings\":[],\"error\":null,\"cancelRequestedAt\":null,\"resumeProvenance\":null,\"resumeDeadline\":null,\"resumable\":false,\"resumeCount\":0,\"publicationDisposition\":\"not_started\",\"createdAt\":\"2026-07-22T00:00:00Z\",\"updatedAt\":\"2026-07-22T00:00:00Z\"}\n202" "$job_id"
    ;;
  "GET http://127.0.0.1:3099/migration/algolia/jobs/job-123")
    printf "{\"id\":\"job-123\",\"status\":\"queued\",\"mode\":\"create\",\"destination\":{\"kind\":\"create\",\"target\":\"target\",\"region\":\"us-east-1\"},\"source\":{\"appId\":\"TESTAPP123\",\"name\":\"source\"},\"summary\":{\"documentsExpected\":1,\"documentsImported\":0,\"documentsRejected\":0,\"settingsApplied\":0,\"settingsUnsupported\":0,\"synonymsExpected\":0,\"synonymsImported\":0,\"synonymsRejected\":0,\"rulesExpected\":0,\"rulesImported\":0,\"rulesRejected\":0},\"warnings\":[],\"error\":null,\"cancelRequestedAt\":null,\"resumeProvenance\":null,\"resumeDeadline\":null,\"resumable\":false,\"resumeCount\":0,\"publicationDisposition\":\"not_started\",\"createdAt\":\"2026-07-22T00:00:00Z\",\"updatedAt\":\"2026-07-22T00:00:00Z\"}\n200"
    ;;
  "GET http://127.0.0.1:3099/migration/algolia/jobs?limit=10")
    if [ "${CURL_SCENARIO:-success}" = "list_extra_field" ]; then
      printf "{\"jobs\":[{\"id\":\"job-123\",\"status\":\"queued\",\"mode\":\"create\",\"destination\":{\"kind\":\"create\",\"target\":\"target\",\"region\":\"us-east-1\"},\"source\":{\"appId\":\"TESTAPP123\",\"name\":\"source\"},\"summary\":{\"documentsExpected\":1,\"documentsImported\":0,\"documentsRejected\":0,\"settingsApplied\":0,\"settingsUnsupported\":0,\"synonymsExpected\":0,\"synonymsImported\":0,\"synonymsRejected\":0,\"rulesExpected\":0,\"rulesImported\":0,\"rulesRejected\":0},\"warnings\":[],\"error\":null,\"cancelRequestedAt\":null,\"resumeProvenance\":null,\"resumeDeadline\":null,\"resumable\":false,\"resumeCount\":0,\"publicationDisposition\":\"not_started\",\"engineJobId\":\"leaked\",\"createdAt\":\"2026-07-22T00:00:00Z\",\"updatedAt\":\"2026-07-22T00:00:00Z\"}],\"nextCursor\":null}\n200"
    else
      printf "{\"jobs\":[{\"id\":\"job-123\",\"status\":\"queued\",\"mode\":\"create\",\"destination\":{\"kind\":\"create\",\"target\":\"target\",\"region\":\"us-east-1\"},\"source\":{\"appId\":\"TESTAPP123\",\"name\":\"source\"},\"summary\":{\"documentsExpected\":1,\"documentsImported\":0,\"documentsRejected\":0,\"settingsApplied\":0,\"settingsUnsupported\":0,\"synonymsExpected\":0,\"synonymsImported\":0,\"synonymsRejected\":0,\"rulesExpected\":0,\"rulesImported\":0,\"rulesRejected\":0},\"warnings\":[],\"error\":null,\"cancelRequestedAt\":null,\"resumeProvenance\":null,\"resumeDeadline\":null,\"resumable\":false,\"resumeCount\":0,\"publicationDisposition\":\"not_started\",\"createdAt\":\"2026-07-22T00:00:00Z\",\"updatedAt\":\"2026-07-22T00:00:00Z\"}],\"nextCursor\":null}\n200"
    fi
    ;;
  "POST http://127.0.0.1:3099/migration/algolia/jobs/job-123/cancel")
    if [ "${CURL_SCENARIO:-success}" = "cancel_fail" ]; then
      printf "{\"error\":\"backend unavailable\"}\n503"
    elif [ ! -f "$WORK_DIR/cancel.once" ]; then
      touch "$WORK_DIR/cancel.once"
      printf "{\"id\":\"job-123\",\"status\":\"cancelling\",\"mode\":\"create\",\"destination\":{\"kind\":\"create\",\"target\":\"target\",\"region\":\"us-east-1\"},\"source\":{\"appId\":\"TESTAPP123\",\"name\":\"source\"},\"summary\":{\"documentsExpected\":1,\"documentsImported\":0,\"documentsRejected\":0,\"settingsApplied\":0,\"settingsUnsupported\":0,\"synonymsExpected\":0,\"synonymsImported\":0,\"synonymsRejected\":0,\"rulesExpected\":0,\"rulesImported\":0,\"rulesRejected\":0},\"warnings\":[],\"error\":null,\"cancelRequestedAt\":\"2026-07-22T00:00:01Z\",\"resumeProvenance\":null,\"resumeDeadline\":null,\"resumable\":false,\"resumeCount\":0,\"publicationDisposition\":\"not_started\",\"createdAt\":\"2026-07-22T00:00:00Z\",\"updatedAt\":\"2026-07-22T00:00:01Z\"}\n202"
    else
      printf "{\"id\":\"job-123\",\"status\":\"cancelling\",\"mode\":\"create\",\"destination\":{\"kind\":\"create\",\"target\":\"target\",\"region\":\"us-east-1\"},\"source\":{\"appId\":\"TESTAPP123\",\"name\":\"source\"},\"summary\":{\"documentsExpected\":1,\"documentsImported\":0,\"documentsRejected\":0,\"settingsApplied\":0,\"settingsUnsupported\":0,\"synonymsExpected\":0,\"synonymsImported\":0,\"synonymsRejected\":0,\"rulesExpected\":0,\"rulesImported\":0,\"rulesRejected\":0},\"warnings\":[],\"error\":null,\"cancelRequestedAt\":\"2026-07-22T00:00:01Z\",\"resumeProvenance\":null,\"resumeDeadline\":null,\"resumable\":false,\"resumeCount\":0,\"publicationDisposition\":\"not_started\",\"createdAt\":\"2026-07-22T00:00:00Z\",\"updatedAt\":\"2026-07-22T00:00:01Z\"}\n200"
    fi
    ;;
  *)
    echo "unexpected curl call: $method $url" >&2
    exit 1
    ;;
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
    SLEEP_LOG="$WORK_DIR/sleep.log" \
    UP_LOG="$WORK_DIR/up.log" \
    DOWN_LOG="$WORK_DIR/down.log" \
    CONTRACT_CHECK_LOG="$WORK_DIR/contract_check.log" \
    FJCLOUD_SECRET_FILE="$WORK_DIR/secret.env" \
    FLAPJACK_DEV_DIR="$WORK_DIR/flapjack_dev" \
    ALGOLIA_IMPORT_DISPATCH_ENGINE_CONTRACT_CHECK="$WORK_DIR/contract_check.sh" \
    ALGOLIA_IMPORT_DISPATCH_INTEGRATION_UP="$WORK_DIR/up.sh" \
    ALGOLIA_IMPORT_DISPATCH_INTEGRATION_DOWN="$WORK_DIR/down.sh" \
    ALGOLIA_IMPORT_DISPATCH_RUN_ID="test" \
    ALGOLIA_IMPORT_DISPATCH_RUNTIME_PARENT="$WORK_DIR/runtime" \
    ALGOLIA_IMPORT_DISPATCH_API_URL="http://127.0.0.1:3099" \
    ALGOLIA_IMPORT_DISPATCH_ENGINE_URL="http://127.0.0.1:7799" \
    bash "$TARGET_SCRIPT" "$@" 2>&1
  )" || RUN_EXIT_CODE=$?
}

test_success_emits_phase_evidence_and_cleans_up() {
  setup_workspace
  run_probe --phases dispatch,cancel,lease_retention,restart_reconciliation

  assert_eq "$RUN_EXIT_CODE" "0" "complete mocked run should pass"
  assert_contains "$RUN_STDOUT" "PHASE|name=dispatch|expected=accepted_202_location|observed=accepted_202_location|pass=true" "dispatch phase marker"
  assert_contains "$RUN_STDOUT" "PHASE|name=cancel|expected=first_202_replay_200_single_intent|observed=first_202_replay_200_single_intent|pass=true" "cancel phase marker"
  assert_contains "$RUN_STDOUT" "PHASE|name=lease_retention|expected=reserved_through_claim_expiry|observed=reserved_through_claim_expiry|pass=true" "lease retention phase marker"
  assert_contains "$RUN_STDOUT" "PHASE|name=restart_reconciliation|expected=credential_free_reconciliation|observed=credential_free_reconciliation|pass=true" "restart reconciliation phase marker"
  assert_contains "$RUN_STDOUT" "EVIDENCE|public_fields=get_allowlisted,list_allowlisted|retained_job_id=job-123|secret_matches=0|alert_duplicates=0" "public field and secret evidence marker"
  assert_contains "$RUN_STDOUT" "CLEANUP|algolia_indexes=0|algolia_keys=0|local_stack=0|runtime_files=0" "zero-residue cleanup marker"
  assert_contains "$RUN_STDOUT" "RESULT|status=PASS|phases=dispatch,cancel,lease_retention,restart_reconciliation" "success result marker"
  assert_not_contains "$RUN_STDOUT" "algolia-admin-secret" "probe output redacts admin key"
  assert_not_contains "$(cat "$WORK_DIR/curl.log")" "algolia-admin-secret" "curl argv does not expose admin key"
  assert_contains "$(cat "$WORK_DIR/up.log")" "enabled=true" "integration-up receives migration enablement"
  assert_contains "$(cat "$WORK_DIR/up.log")" "preserve=1" "restart phase restarts with a preserved database"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "GET http://127.0.0.1:7799/1/migrations/algolia/11111111-1111-4111-8111-111111111111" \
    "restart phase observes the retained job through the restarted engine"
  assert_contains "$(cat "$WORK_DIR/psql.log")" "probe:fresh_lease" \
    "turnover phases prove a fresh reconciliation lease from the database"
  if python3 - "$WORK_DIR/curl.log" <<'PY'
import sys

calls = open(sys.argv[1], encoding="utf-8").read()
engine_status = calls.find("GET http://127.0.0.1:7799/1/migrations/algolia/")
cancel = calls.find("POST -D", calls.find("/migration/algolia/jobs/job-123/cancel") - 80)
if engine_status == -1 or cancel == -1 or not engine_status < cancel:
    raise SystemExit(1)
PY
  then
    pass "retention and restart evidence run before cancelling the retained job"
  else
    fail "retention and restart evidence should run before cancelling the retained job"
  fi
  assert_contains "$(cat "$WORK_DIR/down.log")" "pid_dir=" "teardown runs through integration-down"
  assert_contains "$(cat "$WORK_DIR/contract_check.log")" \
    "flapjack_dev_dir=$WORK_DIR/flapjack_dev args=--check" \
    "probe delegates pinned checkout validation to the engine contract owner"
}

test_default_settle_wait_covers_reconciliation_interval() {
  setup_workspace
  PSQL_SCENARIO=turnover_after_wait \
  run_probe --phases lease_retention
  assert_eq "$RUN_EXIT_CODE" "0" "lease retention should pass with default settle wait"
  assert_contains "$(cat "$WORK_DIR/sleep.log")" "sleep 1" \
    "default settle wait should poll through reconciliation turnover"
}

test_local_node_key_warmup_precedes_dispatch_and_fails_closed() {
  setup_workspace
  run_probe --phases dispatch
  assert_eq "$RUN_EXIT_CODE" "0" "dispatch should pass after local node-key warmup"
  if python3 - "$WORK_DIR/curl.log" <<'PY'
import sys

calls = open(sys.argv[1], encoding="utf-8").read().splitlines()

def call_index(method, url):
    return next(
        (index for index, call in enumerate(calls) if f"-X {method}" in call and url in call),
        -1,
    )

create = call_index("POST", "http://127.0.0.1:3099/indexes")
delete = call_index(
    "DELETE",
    "http://127.0.0.1:3099/indexes/fjcloud_import_dispatch_probe_test_warmup",
)
dispatch = call_index("POST", "http://127.0.0.1:3099/migration/algolia/jobs")
if min(create, delete, dispatch) == -1 or not create < delete < dispatch:
    raise SystemExit(1)
PY
  then
    pass "local node-key warmup is deleted before migration dispatch"
  else
    fail "local node-key warmup should be deleted before migration dispatch"
  fi

  setup_workspace
  CURL_SCENARIO=node_key_warmup_fail run_probe --phases dispatch
  assert_eq "$RUN_EXIT_CODE" "1" "failed local node-key warmup should fail closed"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=endpoint_unavailable" \
    "failed local node-key warmup emits ACTION_REQUIRED"
}

test_secret_leak_in_database_is_action_required() {
  setup_workspace
  PSQL_SCENARIO=secret_match run_probe --phases dispatch
  assert_eq "$RUN_EXIT_CODE" "1" "database secret leak should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=residue_detected" \
    "disposable credential match in the database emits ACTION_REQUIRED"
}

test_secret_leak_in_runtime_logs_is_action_required() {
  setup_workspace
  LEAK_KEY_TO_LOG=1 run_probe --phases dispatch
  assert_eq "$RUN_EXIT_CODE" "1" "runtime-log secret leak should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=residue_detected" \
    "disposable key in an API runtime capture emits ACTION_REQUIRED"
}

test_imported_document_canary_is_not_a_secret_leak() {
  setup_workspace
  WRITE_DOCUMENT_CANARY_TO_RUNTIME=1 run_probe --phases dispatch
  assert_eq "$RUN_EXIT_CODE" "0" \
    "expected imported document data should not trip the credential-leak oracle"
  assert_contains "$RUN_STDOUT" "EVIDENCE|public_fields=get_allowlisted,list_allowlisted|retained_job_id=job-123|secret_matches=0" \
    "privacy evidence remains zero when only the imported document canary is present"
}

test_lease_release_breaks_retention() {
  setup_workspace
  PSQL_SCENARIO=lease_released run_probe --phases lease_retention
  assert_eq "$RUN_EXIT_CODE" "1" "released reservation should fail lease retention"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=inconclusive_evidence" \
    "a released dispatch through claim expiry emits ACTION_REQUIRED"
}

test_lease_reservation_duplicated_fails() {
  setup_workspace
  PSQL_SCENARIO=lease_duplicated run_probe --phases lease_retention
  assert_eq "$RUN_EXIT_CODE" "1" "duplicated reservation should fail lease retention"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=inconclusive_evidence" \
    "a duplicated reservation through claim expiry emits ACTION_REQUIRED"
}

test_lease_reidentity_after_expiry_fails() {
  setup_workspace
  PSQL_SCENARIO=reidentity_after_expiry run_probe --phases lease_retention
  assert_eq "$RUN_EXIT_CODE" "1" "re-dispatched engine identity should fail lease retention"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=inconclusive_evidence" \
    "an engine-identity change through claim expiry emits ACTION_REQUIRED"
}

test_lease_without_fresh_turnover_fails() {
  setup_workspace
  PSQL_SCENARIO=turnover_missing run_probe --phases lease_retention
  assert_eq "$RUN_EXIT_CODE" "1" "missing reconciliation turnover should fail lease retention"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=inconclusive_evidence" \
    "same-tick lease evidence emits ACTION_REQUIRED"
}

test_failed_expiry_injection_fails_closed() {
  setup_workspace
  PSQL_SCENARIO=force_expiry_fails run_probe --phases lease_retention
  assert_eq "$RUN_EXIT_CODE" "1" "failed lease-expiry SQL should fail closed"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=inconclusive_evidence" \
    "failed lease-expiry injection emits ACTION_REQUIRED"
}

test_turnover_write_without_active_lease_passes() {
  setup_workspace
  PSQL_SCENARIO=turnover_write_without_active_lease run_probe --phases lease_retention
  assert_eq "$RUN_EXIT_CODE" "0" "fresh reconciliation write should prove turnover even when lease is released"
  assert_contains "$RUN_STDOUT" "PHASE|name=lease_retention|expected=reserved_through_claim_expiry|observed=reserved_through_claim_expiry|pass=true" \
    "fresh reconciliation write keeps lease retention phase evidence green"
}

test_restart_without_engine_observation_fails() {
  setup_workspace
  CURL_SCENARIO=engine_status_missing run_probe --phases restart_reconciliation
  assert_eq "$RUN_EXIT_CODE" "1" "missing post-restart engine observation should fail restart reconciliation"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=inconclusive_evidence" \
    "missing restarted-engine status emits ACTION_REQUIRED"
}

test_alert_duplicates_are_action_required() {
  setup_workspace
  PSQL_SCENARIO=alert_duplicates run_probe --phases dispatch
  assert_eq "$RUN_EXIT_CODE" "1" "duplicate reconciliation alerts should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=inconclusive_evidence" \
    "a duplicate reconciliation alert emits ACTION_REQUIRED"
}

test_list_projection_drift_is_action_required() {
  setup_workspace
  CURL_SCENARIO=list_extra_field run_probe --phases dispatch
  assert_eq "$RUN_EXIT_CODE" "1" "list field-set drift should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=inconclusive_evidence" \
    "an extra/forbidden field in the list projection emits ACTION_REQUIRED"
}

test_rejects_unknown_and_empty_phases() {
  setup_workspace
  run_probe --phases dispatch,unknown
  assert_eq "$RUN_EXIT_CODE" "1" "unknown phase should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=invalid_phases" "unknown phase emits ACTION_REQUIRED"

  setup_workspace
  run_probe --phases ""
  assert_eq "$RUN_EXIT_CODE" "1" "empty phase list should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=invalid_phases" "empty phase emits ACTION_REQUIRED"
}

test_missing_credentials_and_flapjack_mismatch_are_action_required() {
  setup_workspace
  rm -f "$WORK_DIR/secret.env"
  run_probe --phases dispatch
  assert_eq "$RUN_EXIT_CODE" "1" "missing credentials should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=missing_credentials" "missing credentials emits ACTION_REQUIRED"

  setup_workspace
  rm -rf "$WORK_DIR/flapjack_dev"
  run_probe --phases dispatch
  assert_eq "$RUN_EXIT_CODE" "1" "absent FLAPJACK_DEV_DIR should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=flapjack_dev_dir_unavailable" "absent FLAPJACK_DEV_DIR emits ACTION_REQUIRED"

  setup_workspace
  CONTRACT_CHECK_SCENARIO=mismatch run_probe --phases dispatch
  assert_eq "$RUN_EXIT_CODE" "1" "drifted FLAPJACK_DEV_DIR should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=flapjack_dev_dir_mismatch" \
    "unpinned FLAPJACK_DEV_DIR emits ACTION_REQUIRED"
}

test_unavailable_endpoint_and_inconclusive_evidence_are_action_required() {
  setup_workspace
  CURL_SCENARIO=api_down run_probe --phases dispatch
  assert_eq "$RUN_EXIT_CODE" "1" "unavailable API should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=endpoint_unavailable" "unavailable endpoint emits ACTION_REQUIRED"

  setup_workspace
  CURL_SCENARIO=inconclusive_create run_probe --phases dispatch
  assert_eq "$RUN_EXIT_CODE" "1" "wrong create status should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=inconclusive_evidence" "inconclusive evidence emits ACTION_REQUIRED"
  assert_contains "$RUN_STDOUT" "target=POST /migration/algolia/jobs" "inconclusive evidence names failing request target"

  setup_workspace
  CURL_SCENARIO=inconclusive_create ALGOLIA_DELETE_TASK=1 run_probe --phases dispatch
  assert_eq "$RUN_EXIT_CODE" "1" "cleanup task polling should preserve the primary failure"
  assert_contains "$RUN_STDOUT" "target=POST /migration/algolia/jobs" "cleanup polling does not replace primary failure target"
}

test_rejects_unsafe_http_response_values_before_reuse() {
  setup_workspace
  CURL_SCENARIO=unsafe_task_id run_probe --phases dispatch
  assert_eq "$RUN_EXIT_CODE" "1" "path-significant Algolia task id should fail closed"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=invalid_response_identifier" \
    "unsafe Algolia task id emits ACTION_REQUIRED"

  setup_workspace
  CURL_SCENARIO=unsafe_algolia_key run_probe --phases dispatch
  assert_eq "$RUN_EXIT_CODE" "1" "SQL-significant Algolia key should fail closed"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=invalid_response_identifier" \
    "unsafe Algolia key emits ACTION_REQUIRED"
  assert_not_contains "$(cat "$WORK_DIR/psql.log")" "DROP_TABLE" \
    "unsafe Algolia key never reaches SQL"

  setup_workspace
  CURL_SCENARIO=unsafe_job_id run_probe --phases dispatch
  assert_eq "$RUN_EXIT_CODE" "1" "SQL-significant job id should fail closed"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=invalid_response_identifier" \
    "unsafe job id emits ACTION_REQUIRED"
  assert_not_contains "$(cat "$WORK_DIR/psql.log")" "DROP_TABLE" \
    "unsafe job id never reaches SQL"

  setup_workspace
  CURL_SCENARIO=unsafe_eligibility_token run_probe --phases dispatch
  assert_eq "$RUN_EXIT_CODE" "1" "multi-line eligibility token should fail closed"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=invalid_response_identifier" \
    "unsafe eligibility token emits ACTION_REQUIRED"

  setup_workspace
  CURL_SCENARIO=unsafe_tenant_token run_probe --phases dispatch
  assert_eq "$RUN_EXIT_CODE" "1" "multi-line bearer token should fail closed"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=invalid_response_identifier" \
    "unsafe bearer token emits ACTION_REQUIRED"
}

test_residue_and_mid_phase_failure_cleanup_are_action_required() {
  setup_workspace
  ALGOLIA_RESIDUE=1 run_probe --phases dispatch
  assert_eq "$RUN_EXIT_CODE" "1" "residue should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=residue_detected" "residue emits ACTION_REQUIRED"
  assert_contains "$RUN_STDOUT" "CLEANUP|algolia_indexes=1" "residue denominator is reported"

  setup_workspace
  CURL_SCENARIO=cancel_fail run_probe --phases dispatch,cancel
  assert_eq "$RUN_EXIT_CODE" "1" "mid-phase cancel failure should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=inconclusive_evidence" "mid-phase failure emits ACTION_REQUIRED"
  assert_contains "$(cat "$WORK_DIR/down.log")" "pid_dir=" "mid-phase failure still tears down integration stack"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "DELETE https://testapp123.algolia.net/1/keys/disposable-restricted-key" "mid-phase failure revokes key"

  setup_workspace
  FAKE_ALGOLIA_KEY_RESIDUE=1 run_probe --phases dispatch
  assert_eq "$RUN_EXIT_CODE" "1" "surviving disposable Algolia key should fail"
  assert_contains "$RUN_STDOUT" "CLEANUP|algolia_indexes=0|algolia_keys=1" \
    "key residue denominator is queried from Algolia"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=residue_detected" \
    "surviving disposable key emits ACTION_REQUIRED"
}

test_database_and_late_teardown_failures_are_action_required() {
  setup_workspace
  PSQL_SCENARIO=database_residue run_probe --phases dispatch
  assert_eq "$RUN_EXIT_CODE" "1" "surviving isolated database should fail"
  assert_contains "$RUN_STDOUT" "CLEANUP|algolia_indexes=0|algolia_keys=0|local_stack=1|runtime_files=0" \
    "surviving database contributes to local-stack residue"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=residue_detected" \
    "surviving isolated database emits ACTION_REQUIRED"

  setup_workspace
  DOWN_SCENARIO=failure_after_pid_cleanup run_probe --phases dispatch
  assert_eq "$RUN_EXIT_CODE" "1" "late teardown failure should fail"
  assert_contains "$RUN_STDOUT" "CLEANUP|algolia_indexes=0|algolia_keys=0|local_stack=1|runtime_files=0" \
    "teardown failure contributes to local-stack residue after PID removal"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=residue_detected" \
    "late teardown failure emits ACTION_REQUIRED"
}

test_success_emits_phase_evidence_and_cleans_up
test_default_settle_wait_covers_reconciliation_interval
test_local_node_key_warmup_precedes_dispatch_and_fails_closed
test_rejects_unknown_and_empty_phases
test_missing_credentials_and_flapjack_mismatch_are_action_required
test_unavailable_endpoint_and_inconclusive_evidence_are_action_required
test_rejects_unsafe_http_response_values_before_reuse
test_residue_and_mid_phase_failure_cleanup_are_action_required
test_database_and_late_teardown_failures_are_action_required
test_secret_leak_in_database_is_action_required
test_secret_leak_in_runtime_logs_is_action_required
test_imported_document_canary_is_not_a_secret_leak
test_lease_release_breaks_retention
test_lease_reservation_duplicated_fails
test_lease_reidentity_after_expiry_fails
test_lease_without_fresh_turnover_fails
test_failed_expiry_injection_fails_closed
test_turnover_write_without_active_lease_passes
test_restart_without_engine_observation_fails
test_alert_duplicates_are_action_required
test_list_projection_drift_is_action_required

run_test_summary
