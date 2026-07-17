#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/algolia_source_discovery_live_probe.sh"

# shellcheck source=scripts/tests/lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=scripts/tests/lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

WORK_DIR=""
RUN_STDOUT=""
RUN_EXIT_CODE=0
REAL_PYTHON3="$(command -v python3)"

cleanup() {
  if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

setup_workspace() {
  cleanup
  WORK_DIR="$(mktemp -d)"
  mkdir -p "$WORK_DIR/bin"
  : > "$WORK_DIR/curl.log"
  : > "$WORK_DIR/cursor_page_1_count"
  : > "$WORK_DIR/fixture_metadata_count"
  : > "$WORK_DIR/replica_deleted"
  : > "$WORK_DIR/replica_detached"
  : > "$WORK_DIR/replica_detach_task_count"
  : > "$WORK_DIR/retry_exhaustion_count"
  : > "$WORK_DIR/python_argv.log"
  cat > "$WORK_DIR/secret.env" <<'ENV_EOF'
ALGOLIA_APP_ID=TESTAPP123
ALGOLIA_ADMIN_KEY=algolia-admin-secret
ALGOLIA_SEARCH_KEY=unused-search-key
ENV_EOF

  cat > "$WORK_DIR/bin/python3" <<'PYTHON_EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "$PYTHON_ARGV_LOG"
exec "$REAL_PYTHON3" "$@"
PYTHON_EOF

  cat > "$WORK_DIR/bin/sleep" <<'SLEEP_EOF'
#!/usr/bin/env bash
exit 0
SLEEP_EOF

  cat > "$WORK_DIR/bin/curl" <<'CURL_EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "$CURL_LOG"

method="GET"
data_file=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X|--request)
      method="$2"
      shift 2
      ;;
    --data|--data-binary|-d)
      data_file="${2#@}"
      shift 2
      ;;
    --config|-K|-H|--header|-s|-S|-sS|--max-time|--connect-timeout|-w)
      if [ "$1" = "--config" ] || [ "$1" = "-K" ]; then
        if [ -f "$2" ]; then
          config_url="$(sed -n 's/^url = "\(.*\)"$/\1/p' "$2" | tail -1)"
          if [ -n "$config_url" ]; then
            url="$config_url"
          fi
        fi
        shift 2
      elif [ "$1" = "--max-time" ] || [ "$1" = "--connect-timeout" ] || [ "$1" = "-w" ] || [ "$1" = "-H" ] || [ "$1" = "--header" ]; then
        shift 2
      else
        shift
      fi
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

case "$method $url" in
  "POST https://testapp123.algolia.net/1/indexes/fjcloud_source_discovery_probe_"*"/batch")
    printf '{"taskID":1}\n200'
    ;;
  "GET https://testapp123.algolia.net/1/indexes/fjcloud_source_discovery_probe_"*"/task/1")
    printf '{"status":"published"}\n200'
    ;;
  "GET https://testapp123.algolia.net/1/indexes/fjcloud_source_discovery_probe_"*"/task/2")
    detach_task_count="$(wc -l < "$REPLICA_DETACH_TASK_COUNT" | tr -d ' ')"
    printf 'x\n' >> "$REPLICA_DETACH_TASK_COUNT"
    if [ "${ALGOLIA_DELAY_REPLICA_DETACH_TASK:-}" = "1" ] && [ "$detach_task_count" = "0" ]; then
      printf '{"status":"notPublished"}\n200'
    else
      printf 'x\n' > "$REPLICA_DETACHED"
      printf '%s\n' "scenario=replica-detach-task-published" >> "$CURL_LOG"
      printf '{"status":"published"}\n200'
    fi
    ;;
  "GET https://testapp123.algolia.net/1/indexes?page=0&hitsPerPage=1")
    fixture_count="$(wc -l < "$FIXTURE_METADATA_COUNT" | tr -d ' ')"
    printf 'x\n' >> "$FIXTURE_METADATA_COUNT"
    if [ "${ALGOLIA_FIXTURE_METADATA_FIRST_STATUS:-}" = "403" ] && [ "$fixture_count" = "0" ]; then
      printf '{"message":"key not propagated yet"}\n403'
      exit 0
    fi
    if [ "${ALGOLIA_FIXTURE_METADATA_ALWAYS_FAIL:-}" = "1" ]; then
      printf '{"message":"fixture metadata unavailable"}\n500'
      exit 0
    fi
    printf '%s\n' "scenario=fixture-metadata-ready" >> "$CURL_LOG"
    printf '{"items":[{"name":"fjcloud_source_discovery_probe_test_a","entries":1,"dataSize":100,"fileSize":150,"updatedAt":"2026-07-15T12:00:00Z","lastBuildTimeS":3,"pendingTask":false,"primary":"fjcloud_source_discovery_probe_test_a","replicas":["fjcloud_source_discovery_probe_test_b"]}],"page":0,"nbPages":2}\n200'
    ;;
  "GET https://testapp123.algolia.net/1/indexes?page=1&hitsPerPage=1")
    printf '{"items":[{"name":"fjcloud_source_discovery_probe_test_b","entries":1,"dataSize":200,"fileSize":300,"updatedAt":"2026-07-15T12:01:00Z","lastBuildTimeS":4,"pendingTask":false,"primary":"fjcloud_source_discovery_probe_test_a","replicas":[]}],"page":1,"nbPages":2}\n200'
    ;;
  "GET https://testapp123.algolia.net/1/indexes?page=0&hitsPerPage=100")
    bulk_first_file_size="${ALGOLIA_BULK_FIXTURE_FIRST_FILE_SIZE:-150}"
    printf '{"items":[{"name":"fjcloud_source_discovery_probe_test_a","entries":1,"dataSize":100,"fileSize":%s,"updatedAt":"2026-07-15T12:00:00Z","lastBuildTimeS":3,"pendingTask":false,"primary":"fjcloud_source_discovery_probe_test_a","replicas":["fjcloud_source_discovery_probe_test_b"]},{"name":"fjcloud_source_discovery_probe_test_b","entries":1,"dataSize":200,"fileSize":300,"updatedAt":"2026-07-15T12:01:00Z","lastBuildTimeS":4,"pendingTask":false,"primary":"fjcloud_source_discovery_probe_test_a","replicas":[]}],"page":0,"nbPages":1}\n200' "$bulk_first_file_size"
    ;;
  "PUT https://testapp123.algolia.net/1/indexes/fjcloud_source_discovery_probe_"*"/settings")
    if [ -n "$data_file" ] && grep -q '"replicas":\[\]' "$data_file"; then
      printf '%s\n' "scenario=replica-detached" >> "$CURL_LOG"
      if [ "${ALGOLIA_DELAY_REPLICA_DETACH_TASK:-}" != "1" ]; then
        printf 'x\n' > "$REPLICA_DETACHED"
      fi
      printf '{"taskID":2}\n200'
      exit 0
    fi
    printf '{"taskID":1}\n200'
    ;;
  "POST https://testapp123.algolia.net/1/keys")
    if [ -n "$data_file" ]; then
      cp "$data_file" "$(dirname "$CURL_LOG")/key_payload_$(date +%s%N).json"
    fi
    if [ -n "$data_file" ] && grep -q '"search"' "$data_file"; then
      printf '{"key":"acl-denied-key"}\n201'
    else
      printf '{"key":"restricted-list-key"}\n201'
    fi
    ;;
  "DELETE https://testapp123.algolia.net/1/keys/restricted-list-key")
    printf '%s\n' "scenario=restricted-key-revoked" >> "$CURL_LOG"
    printf '{}\n200'
    ;;
  "DELETE https://testapp123.algolia.net/1/keys/acl-denied-key")
    printf '%s\n' "scenario=acl-denied-key-revoked" >> "$CURL_LOG"
    printf '{}\n200'
    ;;
  "DELETE https://testapp123.algolia.net/1/keys/retry-exhaustion-key")
    printf '%s\n' "scenario=retry-key-revoked" >> "$CURL_LOG"
    if [ "${ALGOLIA_FAIL_RETRY_KEY_DELETE:-}" = "1" ]; then
      printf '{"message":"delete failed"}\n500'
    else
      printf '{}\n200'
    fi
    ;;
  "DELETE https://testapp123.algolia.net/1/indexes/fjcloud_source_discovery_probe_"*)
    if [ "${ALGOLIA_FAIL_PRIMARY_DELETE_BEFORE_REPLICA:-}" = "1" ] && [[ "$url" == *"_a" ]]; then
      if [ ! -s "$REPLICA_DELETED" ]; then
        echo "primary deleted before replica" >&2
        exit 1
      fi
    fi
    if [[ "$url" == *"_b" ]]; then
      if [ "${ALGOLIA_REQUIRE_REPLICA_DETACH_BEFORE_DELETE:-}" = "1" ] && [ ! -s "$REPLICA_DETACHED" ]; then
        printf '{"message":"detach replica before deleting"}\n400'
        exit 0
      fi
      printf 'x\n' > "$REPLICA_DELETED"
      printf '%s\n' "scenario=replica-index-deleted" >> "$CURL_LOG"
    fi
    printf '{}\n200'
    ;;
  "POST https://api.staging.flapjack.foo/migration/algolia/list-indexes")
    if [ -n "$data_file" ] && grep -q '"hitsPerPage":1' "$data_file"; then
      printf '%s\n' "scenario=hits-per-page-one" >> "$CURL_LOG"
    fi
    if [ -n "$data_file" ] && grep -q '"cursor":"cursor-page-1"' "$data_file"; then
      printf '%s\n' "scenario=cursor-page-1" >> "$CURL_LOG"
      cursor_count="$(wc -l < "$CURSOR_PAGE_1_COUNT" | tr -d ' ')"
      printf 'x\n' >> "$CURSOR_PAGE_1_COUNT"
      if [ "$cursor_count" = "0" ]; then
        printf '{"items":[{"name":"fjcloud_source_discovery_probe_test_b","entries":1,"dataSize":200,"fileSize":300,"updatedAt":"2026-07-15T12:01:00Z","lastBuildTimeS":4,"pendingTask":false,"primary":"fjcloud_source_discovery_probe_test_a","replicas":[]}],"nextCursor":null}\n200'
      else
        printf '{"error":"invalid_algolia_discovery_cursor"}\n400'
      fi
    elif [ -n "$data_file" ] && grep -q '"cursor":""' "$data_file"; then
      printf '%s\n' "scenario=empty-cursor" >> "$CURL_LOG"
      printf '{"error":"invalid_algolia_discovery_cursor"}\n400'
    elif [ -n "$data_file" ] && grep -q '"cursor":"tampered-cursor"' "$data_file"; then
      printf '%s\n' "scenario=tampered-cursor" >> "$CURL_LOG"
      printf '{"error":"invalid_algolia_discovery_cursor"}\n400'
    elif [ -n "$data_file" ] && grep -q '"cursor":"cursor-page-1-repeated"' "$data_file"; then
      printf '{"error":"invalid_algolia_discovery_cursor"}\n400'
    elif [ -n "$data_file" ] && grep -q '"apiKey":"retry-exhaustion-key"' "$data_file"; then
      retry_count="$(wc -l < "$RETRY_EXHAUSTION_COUNT" | tr -d ' ')"
      printf 'x\n' >> "$RETRY_EXHAUSTION_COUNT"
      if [ "${FJCLOUD_RETRY_NEVER_EXHAUSTS:-}" = "1" ]; then
        printf '%s\n' "scenario=retry-preconsume-no-exhaustion" >> "$CURL_LOG"
        printf '{"items":[],"nextCursor":null}\n200'
      elif [ "$retry_count" = "0" ]; then
        printf '%s\n' "scenario=retry-preconsume" >> "$CURL_LOG"
        printf '{"items":[],"nextCursor":null}\n200'
      else
        printf '%s\n' "scenario=retry-exhausted" >> "$CURL_LOG"
        printf '{"error":"algolia_source_unavailable"}\n503'
      fi
    elif [ -n "$data_file" ] && grep -q '"apiKey":"acl-denied-key"' "$data_file"; then
      printf '%s\n' "scenario=acl-denied" >> "$CURL_LOG"
      printf '{"error":"Algolia discovery requires listIndexes. Migration requires settings and browse; seeUnretrievableAttributes is optional."}\n403'
    else
      printf '{"items":[{"name":"fjcloud_source_discovery_probe_test_a","entries":1,"dataSize":%s,"fileSize":%s,"updatedAt":"2026-07-15T12:00:00Z","lastBuildTimeS":3,"pendingTask":false,"primary":"fjcloud_source_discovery_probe_test_a","replicas":["fjcloud_source_discovery_probe_test_b"]}],"nextCursor":"cursor-page-1"}\n200' "${FJCLOUD_FIRST_DATA_SIZE:-100}" "${FJCLOUD_FIRST_FILE_SIZE:-150}"
    fi
    ;;
  *)
    echo "unexpected curl call: $method $url" >&2
    exit 1
    ;;
esac
CURL_EOF
  chmod +x "$WORK_DIR/bin/curl" "$WORK_DIR/bin/python3" "$WORK_DIR/bin/sleep"
}

run_probe() {
  RUN_EXIT_CODE=0
  RUN_STDOUT="$(
    PATH="$WORK_DIR/bin:$PATH" \
    CURL_LOG="$WORK_DIR/curl.log" \
    CURSOR_PAGE_1_COUNT="$WORK_DIR/cursor_page_1_count" \
    FIXTURE_METADATA_COUNT="$WORK_DIR/fixture_metadata_count" \
    REPLICA_DELETED="$WORK_DIR/replica_deleted" \
    REPLICA_DETACHED="$WORK_DIR/replica_detached" \
    REPLICA_DETACH_TASK_COUNT="$WORK_DIR/replica_detach_task_count" \
    RETRY_EXHAUSTION_COUNT="$WORK_DIR/retry_exhaustion_count" \
    PYTHON_ARGV_LOG="$WORK_DIR/python_argv.log" \
    REAL_PYTHON3="$REAL_PYTHON3" \
    FJCLOUD_SECRET_FILE="$WORK_DIR/secret.env" \
    FJCLOUD_API_URL="https://api.staging.flapjack.foo" \
    FJCLOUD_ZERO_INDEX_BEARER_TOKEN="zero-index-token" \
    ALGOLIA_SOURCE_DISCOVERY_PROBE_PREFIX="fjcloud_source_discovery_probe" \
    ALGOLIA_SOURCE_DISCOVERY_PROBE_RUN_ID="test" \
    ALGOLIA_SOURCE_DISCOVERY_RETRY_EXHAUSTION_KEY="retry-exhaustion-key" \
    bash "$TARGET_SCRIPT" 2>&1
  )" || RUN_EXIT_CODE=$?
}

run_probe_without_retry_key() {
  RUN_EXIT_CODE=0
  RUN_STDOUT="$(
    env -u ALGOLIA_SOURCE_DISCOVERY_RETRY_EXHAUSTION_KEY \
    PATH="$WORK_DIR/bin:$PATH" \
    CURL_LOG="$WORK_DIR/curl.log" \
    CURSOR_PAGE_1_COUNT="$WORK_DIR/cursor_page_1_count" \
    FIXTURE_METADATA_COUNT="$WORK_DIR/fixture_metadata_count" \
    REPLICA_DELETED="$WORK_DIR/replica_deleted" \
    REPLICA_DETACHED="$WORK_DIR/replica_detached" \
    REPLICA_DETACH_TASK_COUNT="$WORK_DIR/replica_detach_task_count" \
    RETRY_EXHAUSTION_COUNT="$WORK_DIR/retry_exhaustion_count" \
    PYTHON_ARGV_LOG="$WORK_DIR/python_argv.log" \
    REAL_PYTHON3="$REAL_PYTHON3" \
    FJCLOUD_SECRET_FILE="$WORK_DIR/secret.env" \
    FJCLOUD_API_URL="https://api.staging.flapjack.foo" \
    FJCLOUD_ZERO_INDEX_BEARER_TOKEN="zero-index-token" \
    ALGOLIA_SOURCE_DISCOVERY_PROBE_PREFIX="fjcloud_source_discovery_probe" \
    ALGOLIA_SOURCE_DISCOVERY_PROBE_RUN_ID="test" \
    bash "$TARGET_SCRIPT" 2>&1
  )" || RUN_EXIT_CODE=$?
}

run_probe_with_wrong_metadata() {
  RUN_EXIT_CODE=0
  RUN_STDOUT="$(
    PATH="$WORK_DIR/bin:$PATH" \
    CURL_LOG="$WORK_DIR/curl.log" \
    CURSOR_PAGE_1_COUNT="$WORK_DIR/cursor_page_1_count" \
    FIXTURE_METADATA_COUNT="$WORK_DIR/fixture_metadata_count" \
    REPLICA_DELETED="$WORK_DIR/replica_deleted" \
    REPLICA_DETACHED="$WORK_DIR/replica_detached" \
    REPLICA_DETACH_TASK_COUNT="$WORK_DIR/replica_detach_task_count" \
    RETRY_EXHAUSTION_COUNT="$WORK_DIR/retry_exhaustion_count" \
    PYTHON_ARGV_LOG="$WORK_DIR/python_argv.log" \
    REAL_PYTHON3="$REAL_PYTHON3" \
    FJCLOUD_FIRST_DATA_SIZE="101" \
    FJCLOUD_SECRET_FILE="$WORK_DIR/secret.env" \
    FJCLOUD_API_URL="https://api.staging.flapjack.foo" \
    FJCLOUD_ZERO_INDEX_BEARER_TOKEN="zero-index-token" \
    ALGOLIA_SOURCE_DISCOVERY_PROBE_PREFIX="fjcloud_source_discovery_probe" \
    ALGOLIA_SOURCE_DISCOVERY_PROBE_RUN_ID="test" \
    ALGOLIA_SOURCE_DISCOVERY_RETRY_EXHAUSTION_KEY="retry-exhaustion-key" \
    bash "$TARGET_SCRIPT" 2>&1
  )" || RUN_EXIT_CODE=$?
}

run_probe_with_wrong_file_size() {
  RUN_EXIT_CODE=0
  RUN_STDOUT="$(
    PATH="$WORK_DIR/bin:$PATH" \
    CURL_LOG="$WORK_DIR/curl.log" \
    CURSOR_PAGE_1_COUNT="$WORK_DIR/cursor_page_1_count" \
    FIXTURE_METADATA_COUNT="$WORK_DIR/fixture_metadata_count" \
    REPLICA_DELETED="$WORK_DIR/replica_deleted" \
    REPLICA_DETACHED="$WORK_DIR/replica_detached" \
    REPLICA_DETACH_TASK_COUNT="$WORK_DIR/replica_detach_task_count" \
    RETRY_EXHAUSTION_COUNT="$WORK_DIR/retry_exhaustion_count" \
    PYTHON_ARGV_LOG="$WORK_DIR/python_argv.log" \
    REAL_PYTHON3="$REAL_PYTHON3" \
    FJCLOUD_FIRST_FILE_SIZE="151" \
    FJCLOUD_SECRET_FILE="$WORK_DIR/secret.env" \
    FJCLOUD_API_URL="https://api.staging.flapjack.foo" \
    FJCLOUD_ZERO_INDEX_BEARER_TOKEN="zero-index-token" \
    ALGOLIA_SOURCE_DISCOVERY_PROBE_PREFIX="fjcloud_source_discovery_probe" \
    ALGOLIA_SOURCE_DISCOVERY_PROBE_RUN_ID="test" \
    ALGOLIA_SOURCE_DISCOVERY_RETRY_EXHAUSTION_KEY="retry-exhaustion-key" \
    bash "$TARGET_SCRIPT" 2>&1
  )" || RUN_EXIT_CODE=$?
}

run_probe_with_bulk_fixture_file_size_drift() {
  RUN_EXIT_CODE=0
  RUN_STDOUT="$(
    PATH="$WORK_DIR/bin:$PATH" \
    CURL_LOG="$WORK_DIR/curl.log" \
    CURSOR_PAGE_1_COUNT="$WORK_DIR/cursor_page_1_count" \
    FIXTURE_METADATA_COUNT="$WORK_DIR/fixture_metadata_count" \
    REPLICA_DELETED="$WORK_DIR/replica_deleted" \
    REPLICA_DETACHED="$WORK_DIR/replica_detached" \
    REPLICA_DETACH_TASK_COUNT="$WORK_DIR/replica_detach_task_count" \
    RETRY_EXHAUSTION_COUNT="$WORK_DIR/retry_exhaustion_count" \
    PYTHON_ARGV_LOG="$WORK_DIR/python_argv.log" \
    REAL_PYTHON3="$REAL_PYTHON3" \
    ALGOLIA_BULK_FIXTURE_FIRST_FILE_SIZE="151" \
    FJCLOUD_SECRET_FILE="$WORK_DIR/secret.env" \
    FJCLOUD_API_URL="https://api.staging.flapjack.foo" \
    FJCLOUD_ZERO_INDEX_BEARER_TOKEN="zero-index-token" \
    ALGOLIA_SOURCE_DISCOVERY_PROBE_PREFIX="fjcloud_source_discovery_probe" \
    ALGOLIA_SOURCE_DISCOVERY_PROBE_RUN_ID="test" \
    ALGOLIA_SOURCE_DISCOVERY_RETRY_EXHAUSTION_KEY="retry-exhaustion-key" \
    bash "$TARGET_SCRIPT" 2>&1
  )" || RUN_EXIT_CODE=$?
}

run_probe_with_unavailable_live_retry_exhaustion() {
  RUN_EXIT_CODE=0
  RUN_STDOUT="$(
    PATH="$WORK_DIR/bin:$PATH" \
    CURL_LOG="$WORK_DIR/curl.log" \
    CURSOR_PAGE_1_COUNT="$WORK_DIR/cursor_page_1_count" \
    FIXTURE_METADATA_COUNT="$WORK_DIR/fixture_metadata_count" \
    REPLICA_DELETED="$WORK_DIR/replica_deleted" \
    REPLICA_DETACHED="$WORK_DIR/replica_detached" \
    REPLICA_DETACH_TASK_COUNT="$WORK_DIR/replica_detach_task_count" \
    RETRY_EXHAUSTION_COUNT="$WORK_DIR/retry_exhaustion_count" \
    PYTHON_ARGV_LOG="$WORK_DIR/python_argv.log" \
    REAL_PYTHON3="$REAL_PYTHON3" \
    FJCLOUD_RETRY_NEVER_EXHAUSTS="1" \
    FJCLOUD_SECRET_FILE="$WORK_DIR/secret.env" \
    FJCLOUD_API_URL="https://api.staging.flapjack.foo" \
    FJCLOUD_ZERO_INDEX_BEARER_TOKEN="zero-index-token" \
    ALGOLIA_SOURCE_DISCOVERY_PROBE_PREFIX="fjcloud_source_discovery_probe" \
    ALGOLIA_SOURCE_DISCOVERY_PROBE_RUN_ID="test" \
    ALGOLIA_SOURCE_DISCOVERY_RETRY_EXHAUSTION_KEY="retry-exhaustion-key" \
    bash "$TARGET_SCRIPT" 2>&1
  )" || RUN_EXIT_CODE=$?
}

run_probe_with_trapped_fixture_metadata_error() {
  RUN_EXIT_CODE=0
  RUN_STDOUT="$(
    PATH="$WORK_DIR/bin:$PATH" \
    CURL_LOG="$WORK_DIR/curl.log" \
    CURSOR_PAGE_1_COUNT="$WORK_DIR/cursor_page_1_count" \
    FIXTURE_METADATA_COUNT="$WORK_DIR/fixture_metadata_count" \
    REPLICA_DELETED="$WORK_DIR/replica_deleted" \
    REPLICA_DETACHED="$WORK_DIR/replica_detached" \
    REPLICA_DETACH_TASK_COUNT="$WORK_DIR/replica_detach_task_count" \
    RETRY_EXHAUSTION_COUNT="$WORK_DIR/retry_exhaustion_count" \
    PYTHON_ARGV_LOG="$WORK_DIR/python_argv.log" \
    REAL_PYTHON3="$REAL_PYTHON3" \
    ALGOLIA_FIXTURE_METADATA_ALWAYS_FAIL="1" \
    FJCLOUD_SECRET_FILE="$WORK_DIR/secret.env" \
    FJCLOUD_API_URL="https://api.staging.flapjack.foo" \
    FJCLOUD_ZERO_INDEX_BEARER_TOKEN="zero-index-token" \
    ALGOLIA_SOURCE_DISCOVERY_PROBE_PREFIX="fjcloud_source_discovery_probe" \
    ALGOLIA_SOURCE_DISCOVERY_PROBE_RUN_ID="test" \
    ALGOLIA_SOURCE_DISCOVERY_RETRY_EXHAUSTION_KEY="retry-exhaustion-key" \
    bash "$TARGET_SCRIPT" 2>&1
  )" || RUN_EXIT_CODE=$?
}

run_probe_with_retry_key_deletion_failure() {
  RUN_EXIT_CODE=0
  RUN_STDOUT="$(
    PATH="$WORK_DIR/bin:$PATH" \
    CURL_LOG="$WORK_DIR/curl.log" \
    CURSOR_PAGE_1_COUNT="$WORK_DIR/cursor_page_1_count" \
    FIXTURE_METADATA_COUNT="$WORK_DIR/fixture_metadata_count" \
    REPLICA_DELETED="$WORK_DIR/replica_deleted" \
    REPLICA_DETACHED="$WORK_DIR/replica_detached" \
    REPLICA_DETACH_TASK_COUNT="$WORK_DIR/replica_detach_task_count" \
    RETRY_EXHAUSTION_COUNT="$WORK_DIR/retry_exhaustion_count" \
    PYTHON_ARGV_LOG="$WORK_DIR/python_argv.log" \
    REAL_PYTHON3="$REAL_PYTHON3" \
    ALGOLIA_FAIL_RETRY_KEY_DELETE="1" \
    FJCLOUD_SECRET_FILE="$WORK_DIR/secret.env" \
    FJCLOUD_API_URL="https://api.staging.flapjack.foo" \
    FJCLOUD_ZERO_INDEX_BEARER_TOKEN="zero-index-token" \
    ALGOLIA_SOURCE_DISCOVERY_PROBE_PREFIX="fjcloud_source_discovery_probe" \
    ALGOLIA_SOURCE_DISCOVERY_PROBE_RUN_ID="test" \
    ALGOLIA_SOURCE_DISCOVERY_RETRY_EXHAUSTION_KEY="retry-exhaustion-key" \
    bash "$TARGET_SCRIPT" 2>&1
  )" || RUN_EXIT_CODE=$?
}

run_probe_without_token() {
  RUN_EXIT_CODE=0
  RUN_STDOUT="$(
    PATH="$WORK_DIR/bin:$PATH" \
    CURL_LOG="$WORK_DIR/curl.log" \
    FIXTURE_METADATA_COUNT="$WORK_DIR/fixture_metadata_count" \
    REPLICA_DELETED="$WORK_DIR/replica_deleted" \
    REPLICA_DETACHED="$WORK_DIR/replica_detached" \
    REPLICA_DETACH_TASK_COUNT="$WORK_DIR/replica_detach_task_count" \
    PYTHON_ARGV_LOG="$WORK_DIR/python_argv.log" \
    REAL_PYTHON3="$REAL_PYTHON3" \
    FJCLOUD_SECRET_FILE="$WORK_DIR/secret.env" \
    FJCLOUD_API_URL="https://api.staging.flapjack.foo" \
    env -u FJCLOUD_ZERO_INDEX_BEARER_TOKEN bash "$TARGET_SCRIPT" 2>&1
  )" || RUN_EXIT_CODE=$?
}

run_probe_with_delayed_fixture_metadata_key() {
  RUN_EXIT_CODE=0
  RUN_STDOUT="$(
    PATH="$WORK_DIR/bin:$PATH" \
    CURL_LOG="$WORK_DIR/curl.log" \
    CURSOR_PAGE_1_COUNT="$WORK_DIR/cursor_page_1_count" \
    FIXTURE_METADATA_COUNT="$WORK_DIR/fixture_metadata_count" \
    REPLICA_DELETED="$WORK_DIR/replica_deleted" \
    REPLICA_DETACHED="$WORK_DIR/replica_detached" \
    REPLICA_DETACH_TASK_COUNT="$WORK_DIR/replica_detach_task_count" \
    RETRY_EXHAUSTION_COUNT="$WORK_DIR/retry_exhaustion_count" \
    PYTHON_ARGV_LOG="$WORK_DIR/python_argv.log" \
    REAL_PYTHON3="$REAL_PYTHON3" \
    FJCLOUD_SECRET_FILE="$WORK_DIR/secret.env" \
    FJCLOUD_API_URL="https://api.staging.flapjack.foo" \
    FJCLOUD_ZERO_INDEX_BEARER_TOKEN="zero-index-token" \
    ALGOLIA_SOURCE_DISCOVERY_PROBE_PREFIX="fjcloud_source_discovery_probe" \
    ALGOLIA_SOURCE_DISCOVERY_PROBE_RUN_ID="test" \
    ALGOLIA_SOURCE_DISCOVERY_RETRY_EXHAUSTION_KEY="retry-exhaustion-key" \
    ALGOLIA_FIXTURE_METADATA_FIRST_STATUS="403" \
    bash "$TARGET_SCRIPT" 2>&1
  )" || RUN_EXIT_CODE=$?
}

run_probe_with_replica_delete_order_guard() {
  RUN_EXIT_CODE=0
  RUN_STDOUT="$(
    PATH="$WORK_DIR/bin:$PATH" \
    CURL_LOG="$WORK_DIR/curl.log" \
    CURSOR_PAGE_1_COUNT="$WORK_DIR/cursor_page_1_count" \
    FIXTURE_METADATA_COUNT="$WORK_DIR/fixture_metadata_count" \
    REPLICA_DELETED="$WORK_DIR/replica_deleted" \
    REPLICA_DETACHED="$WORK_DIR/replica_detached" \
    REPLICA_DETACH_TASK_COUNT="$WORK_DIR/replica_detach_task_count" \
    RETRY_EXHAUSTION_COUNT="$WORK_DIR/retry_exhaustion_count" \
    PYTHON_ARGV_LOG="$WORK_DIR/python_argv.log" \
    REAL_PYTHON3="$REAL_PYTHON3" \
    FJCLOUD_SECRET_FILE="$WORK_DIR/secret.env" \
    FJCLOUD_API_URL="https://api.staging.flapjack.foo" \
    FJCLOUD_ZERO_INDEX_BEARER_TOKEN="zero-index-token" \
    ALGOLIA_SOURCE_DISCOVERY_PROBE_PREFIX="fjcloud_source_discovery_probe" \
    ALGOLIA_SOURCE_DISCOVERY_PROBE_RUN_ID="test" \
    ALGOLIA_SOURCE_DISCOVERY_RETRY_EXHAUSTION_KEY="retry-exhaustion-key" \
    ALGOLIA_FAIL_PRIMARY_DELETE_BEFORE_REPLICA="1" \
    bash "$TARGET_SCRIPT" 2>&1
  )" || RUN_EXIT_CODE=$?
}

run_probe_with_replica_detach_delete_guard() {
  RUN_EXIT_CODE=0
  RUN_STDOUT="$(
    PATH="$WORK_DIR/bin:$PATH" \
    CURL_LOG="$WORK_DIR/curl.log" \
    CURSOR_PAGE_1_COUNT="$WORK_DIR/cursor_page_1_count" \
    FIXTURE_METADATA_COUNT="$WORK_DIR/fixture_metadata_count" \
    REPLICA_DELETED="$WORK_DIR/replica_deleted" \
    REPLICA_DETACHED="$WORK_DIR/replica_detached" \
    REPLICA_DETACH_TASK_COUNT="$WORK_DIR/replica_detach_task_count" \
    RETRY_EXHAUSTION_COUNT="$WORK_DIR/retry_exhaustion_count" \
    PYTHON_ARGV_LOG="$WORK_DIR/python_argv.log" \
    REAL_PYTHON3="$REAL_PYTHON3" \
    FJCLOUD_SECRET_FILE="$WORK_DIR/secret.env" \
    FJCLOUD_API_URL="https://api.staging.flapjack.foo" \
    FJCLOUD_ZERO_INDEX_BEARER_TOKEN="zero-index-token" \
    ALGOLIA_SOURCE_DISCOVERY_PROBE_PREFIX="fjcloud_source_discovery_probe" \
    ALGOLIA_SOURCE_DISCOVERY_PROBE_RUN_ID="test" \
    ALGOLIA_SOURCE_DISCOVERY_RETRY_EXHAUSTION_KEY="retry-exhaustion-key" \
    ALGOLIA_REQUIRE_REPLICA_DETACH_BEFORE_DELETE="1" \
    bash "$TARGET_SCRIPT" 2>&1
  )" || RUN_EXIT_CODE=$?
}

run_probe_with_delayed_replica_detach_task() {
  RUN_EXIT_CODE=0
  RUN_STDOUT="$(
    PATH="$WORK_DIR/bin:$PATH" \
    CURL_LOG="$WORK_DIR/curl.log" \
    CURSOR_PAGE_1_COUNT="$WORK_DIR/cursor_page_1_count" \
    FIXTURE_METADATA_COUNT="$WORK_DIR/fixture_metadata_count" \
    REPLICA_DELETED="$WORK_DIR/replica_deleted" \
    REPLICA_DETACHED="$WORK_DIR/replica_detached" \
    REPLICA_DETACH_TASK_COUNT="$WORK_DIR/replica_detach_task_count" \
    RETRY_EXHAUSTION_COUNT="$WORK_DIR/retry_exhaustion_count" \
    PYTHON_ARGV_LOG="$WORK_DIR/python_argv.log" \
    REAL_PYTHON3="$REAL_PYTHON3" \
    FJCLOUD_SECRET_FILE="$WORK_DIR/secret.env" \
    FJCLOUD_API_URL="https://api.staging.flapjack.foo" \
    FJCLOUD_ZERO_INDEX_BEARER_TOKEN="zero-index-token" \
    ALGOLIA_SOURCE_DISCOVERY_PROBE_PREFIX="fjcloud_source_discovery_probe" \
    ALGOLIA_SOURCE_DISCOVERY_PROBE_RUN_ID="test" \
    ALGOLIA_SOURCE_DISCOVERY_RETRY_EXHAUSTION_KEY="retry-exhaustion-key" \
    ALGOLIA_REQUIRE_REPLICA_DETACH_BEFORE_DELETE="1" \
    ALGOLIA_DELAY_REPLICA_DETACH_TASK="1" \
    bash "$TARGET_SCRIPT" 2>&1
  )" || RUN_EXIT_CODE=$?
}

test_requires_explicit_inputs() {
  setup_workspace
  run_probe_without_token
  assert_eq "$RUN_EXIT_CODE" "1" "missing zero-index bearer token should fail"
  assert_contains "$RUN_STDOUT" "FJCLOUD_ZERO_INDEX_BEARER_TOKEN is required" "missing token names required env"
}

test_success_path_creates_pages_and_cleans_without_secret_argv() {
  setup_workspace
  run_probe
  assert_eq "$RUN_EXIT_CODE" "0" "probe should pass against fake curl"
  assert_contains "$RUN_STDOUT" "PASS: Algolia source discovery live probe" "success verdict is printed"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "/1/keys" "probe creates restricted key"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "scenario=hits-per-page-one" "probe forces one-item pages"
  assert_contains "$(cat "$WORK_DIR"/key_payload_*.json)" '"indexes":["fjcloud_source_discovery_probe_test_a","fjcloud_source_discovery_probe_test_b"]' "restricted list key is scoped to current run indexes"
  assert_not_contains "$(cat "$WORK_DIR"/key_payload_*.json)" 'fjcloud_source_discovery_probe_*' "restricted list key must not include stale-prefix wildcard"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "scenario=cursor-page-1" "probe follows the opaque cursor"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "scenario=empty-cursor" "probe checks explicit empty cursor failure"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "scenario=tampered-cursor" "probe checks tampered cursor failure"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "scenario=retry-preconsume" "probe pre-consumes retry key through fjcloud"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "scenario=retry-exhausted" "probe checks bounded retry exhaustion failure"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "scenario=acl-denied" "probe checks typed ACL failure"
  assert_contains "$RUN_STDOUT" "metadata-exact:fjp_first" "probe asserts exact first-page metadata"
  assert_contains "$RUN_STDOUT" "metadata-exact:fjp_second" "probe asserts exact second-page metadata"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "scenario=restricted-key-revoked" "probe revokes key"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "scenario=retry-key-revoked" "probe revokes retry-exhaustion key"
  assert_not_contains "$(cat "$WORK_DIR/curl.log")" "algolia-admin-secret" "admin key must not be in argv"
  assert_not_contains "$(cat "$WORK_DIR/curl.log")" "zero-index-token" "bearer token must not be in argv"
  assert_not_contains "$(cat "$WORK_DIR/curl.log")" "restricted-list-key" "restricted key must not be in argv"
  assert_not_contains "$(cat "$WORK_DIR/python_argv.log")" "restricted-list-key" "restricted key must not be in payload-writer argv"
  assert_not_contains "$(cat "$WORK_DIR/python_argv.log")" "acl-denied-key" "ACL-denied key must not be in payload-writer argv"
  assert_not_contains "$(cat "$WORK_DIR/python_argv.log")" "retry-exhaustion-key" "retry key must not be in payload-writer argv"
  assert_not_contains "$RUN_STDOUT" "restricted-list-key" "restricted key must not be printed"
}

test_retries_fixture_metadata_until_restricted_key_propagates() {
  setup_workspace
  run_probe_with_delayed_fixture_metadata_key
  assert_eq "$RUN_EXIT_CODE" "0" "probe should tolerate transient key-propagation 403 before fixture metadata read"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "scenario=fixture-metadata-ready" "probe retries fixture metadata after key propagation"
}

test_deletes_replica_before_primary_during_cleanup() {
  setup_workspace
  run_probe_with_replica_delete_order_guard
  assert_eq "$RUN_EXIT_CODE" "0" "probe cleanup should delete replica before primary"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "scenario=replica-index-deleted" "probe deletes replica during cleanup"
}

test_detaches_replica_before_deleting_indexes_during_cleanup() {
  setup_workspace
  run_probe_with_replica_detach_delete_guard
  assert_eq "$RUN_EXIT_CODE" "0" "probe cleanup should detach replica before deletion"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "scenario=replica-detached" "probe clears primary replica settings during cleanup"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "scenario=replica-index-deleted" "probe deletes detached replica during cleanup"
}

test_waits_for_replica_detach_task_before_deleting_indexes() {
  setup_workspace
  run_probe_with_delayed_replica_detach_task
  assert_eq "$RUN_EXIT_CODE" "0" "probe cleanup should wait for replica detach task publication"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "scenario=replica-detach-task-published" "probe waits until detach task is published"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "scenario=replica-index-deleted" "probe deletes replica after detach task publication"
}

test_metadata_must_match_algolia_fixture_exactly() {
  setup_workspace
  run_probe_with_wrong_metadata
  assert_eq "$RUN_EXIT_CODE" "1" "probe should reject metadata that differs from Algolia"
}

test_file_size_must_match_algolia_fixture_exactly() {
  setup_workspace
  run_probe_with_wrong_file_size
  assert_eq "$RUN_EXIT_CODE" "1" "probe should reject first-page fileSize that differs from Algolia"
}

test_page_shaped_fixture_metadata_avoids_bulk_file_size_race() {
  setup_workspace
  run_probe_with_bulk_fixture_file_size_drift
  assert_eq "$RUN_EXIT_CODE" "0" "probe should compare against page-shaped fixture metadata"
  assert_contains "$RUN_STDOUT" "metadata-exact:fjp_first" "page-shaped fixture still asserts first-page metadata"
  assert_contains "$RUN_STDOUT" "PASS: Algolia source discovery live probe" "page-shaped fixture race should not block live proof"
}

test_retry_exhaustion_must_observe_live_503() {
  setup_workspace
  run_probe_with_unavailable_live_retry_exhaustion
  assert_eq "$RUN_EXIT_CODE" "1" "probe should fail when retry preconsumption never reaches fjcloud HTTP 503"
  assert_contains "$RUN_STDOUT" "retry exhaustion did not observe fjcloud HTTP 503" "retry exhaustion failure is fatal and explicit"
  assert_not_contains "$RUN_STDOUT" "retry-exhaustion:hermetic-only" "retry exhaustion must not fall back to hermetic-only"
  assert_not_contains "$RUN_STDOUT" "PASS: Algolia source discovery live probe" "retry exhaustion failure must not print pass verdict"
}

test_trapped_error_revokes_retry_key_and_preserves_failure() {
  setup_workspace
  run_probe_with_trapped_fixture_metadata_error
  assert_eq "$RUN_EXIT_CODE" "1" "fixture metadata failure should remain the probe verdict"
  assert_contains "$RUN_STDOUT" "Algolia fixture metadata request returned HTTP 500" "original fixture metadata failure is preserved"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "scenario=restricted-key-revoked" "trapped cleanup revokes restricted key"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "scenario=acl-denied-key-revoked" "trapped cleanup revokes ACL-denied key"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "scenario=retry-key-revoked" "trapped cleanup revokes retry-exhaustion key"
  assert_not_contains "$RUN_STDOUT" "PASS: Algolia source discovery live probe" "trapped failure must not print pass verdict"
}

test_retry_key_cleanup_failure_is_fatal() {
  setup_workspace
  run_probe_with_retry_key_deletion_failure
  assert_eq "$RUN_EXIT_CODE" "1" "retry-key deletion failure should fail the probe"
  assert_contains "$RUN_STDOUT" "ERROR: cleanup failed for disposable Algolia source discovery resources" "retry-key cleanup failure uses existing cleanup error"
  assert_not_contains "$RUN_STDOUT" "PASS: Algolia source discovery live probe" "cleanup failure must not print pass verdict"
}

test_retry_exhaustion_key_is_required() {
  setup_workspace
  run_probe_without_retry_key
  assert_eq "$RUN_EXIT_CODE" "1" "probe must fail when retry-exhaustion coverage is unavailable"
  assert_contains "$RUN_STDOUT" "ALGOLIA_SOURCE_DISCOVERY_RETRY_EXHAUSTION_KEY is required" "missing retry key names required env"
}

test_script_is_executable() {
  if [ -x "$TARGET_SCRIPT" ]; then
    pass "probe script is executable"
  else
    fail "probe script is executable"
  fi
}

test_requires_explicit_inputs
test_success_path_creates_pages_and_cleans_without_secret_argv
test_retries_fixture_metadata_until_restricted_key_propagates
test_deletes_replica_before_primary_during_cleanup
test_detaches_replica_before_deleting_indexes_during_cleanup
test_waits_for_replica_detach_task_before_deleting_indexes
test_metadata_must_match_algolia_fixture_exactly
test_file_size_must_match_algolia_fixture_exactly
test_page_shaped_fixture_metadata_avoids_bulk_file_size_race
test_retry_exhaustion_must_observe_live_503
test_trapped_error_revokes_retry_key_and_preserves_failure
test_retry_key_cleanup_failure_is_fatal
test_retry_exhaustion_key_is_required
test_script_is_executable

run_test_summary
