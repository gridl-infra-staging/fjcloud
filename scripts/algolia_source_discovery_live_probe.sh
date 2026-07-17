#!/usr/bin/env bash
# Live acceptance probe for fjcloud-owned Algolia source-index discovery.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=scripts/lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"

SECRET_FILE="${FJCLOUD_SECRET_FILE:-}"
FJCLOUD_API_URL="${FJCLOUD_API_URL:-}"
FJCLOUD_ZERO_INDEX_BEARER_TOKEN="${FJCLOUD_ZERO_INDEX_BEARER_TOKEN:-}"
PROBE_PREFIX="${ALGOLIA_SOURCE_DISCOVERY_PROBE_PREFIX:-fjcloud_source_discovery_probe}"
RUN_ID="${ALGOLIA_SOURCE_DISCOVERY_PROBE_RUN_ID:-$(date -u +%Y%m%d%H%M%S)_$$}"
INDEX_A="${PROBE_PREFIX}_${RUN_ID}_a"
INDEX_B="${PROBE_PREFIX}_${RUN_ID}_b"
ALGOLIA_AUTH_CONFIG=""
FJCLOUD_AUTH_CONFIG=""
TMP_DIR=""
RESTRICTED_LIST_KEY=""
ACL_DENIED_KEY=""
RETRY_EXHAUSTION_KEY="${ALGOLIA_SOURCE_DISCOVERY_RETRY_EXHAUSTION_KEY:-}"
EXPECTED_METADATA_FILE=""
CREATED_INDEXES=()
HTTP_BODY=""
HTTP_STATUS=""
CLEANUP_FAILED=0

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

load_named_secret_env_file() {
  local env_file="$1"
  local line line_number=0 parse_status

  [ -f "$env_file" ] || die "FJCLOUD_SECRET_FILE does not exist"
  while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    parse_env_assignment_line "$line" && parse_status=0 || parse_status=$?
    case "$parse_status" in
      0)
        case "$ENV_ASSIGNMENT_KEY" in
          ALGOLIA_APP_ID|ALGOLIA_ADMIN_KEY)
            printf -v "$ENV_ASSIGNMENT_KEY" '%s' "$ENV_ASSIGNMENT_VALUE"
            export "${ENV_ASSIGNMENT_KEY?}"
            ;;
        esac
        ;;
      2) ;;
      *) die "unsupported secret syntax in FJCLOUD_SECRET_FILE at line $line_number" ;;
    esac
  done < "$env_file"
}

curl_config_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

secure_temp_file() {
  local path
  path="$(mktemp "$TMP_DIR/file.XXXXXX")"
  chmod 600 "$path"
  printf '%s\n' "$path"
}

write_header_config() {
  local path="$1"
  shift
  : > "$path"
  while [ "$#" -gt 0 ]; do
    printf 'header = "%s"\n' "$(curl_config_escape "$1")" >> "$path"
    shift
  done
}

write_url_config() {
  local path="$1"
  local url="$2"
  printf 'url = "%s"\n' "$(curl_config_escape "$url")" > "$path"
}

capture_http_response() {
  local response="$1"
  HTTP_STATUS="${response##*$'\n'}"
  HTTP_BODY="${response%$'\n'*}"
  if [ "$HTTP_STATUS" = "$response" ]; then
    HTTP_BODY=""
  fi
}

curl_http() {
  local expected_statuses="$1"
  shift
  local response status

  response="$(curl -sS --connect-timeout 2 --max-time 8 -w "\n%{http_code}" "$@" || true)"
  capture_http_response "$response"
  for status in $expected_statuses; do
    [ "$HTTP_STATUS" = "$status" ] && return 0
  done
  return 1
}

json_field() {
  local payload="$1"
  local field="$2"
  printf '%s' "$payload" | python3 -c '
import json
import sys
data = json.load(sys.stdin)
value = data.get(sys.argv[1])
if value is None:
    print("")
elif isinstance(value, bool):
    print(str(value).lower())
else:
    print(value)
' "$field"
}

write_json_file() {
  local path="$1"
  shift
  python3 - "$path" "$@" <<'PY'
import json
import sys
path = sys.argv[1]
payload = json.loads(sys.argv[2])
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, separators=(",", ":"))
PY
}

algolia_url() {
  local path="$1"
  printf 'https://%s.algolia.net%s' "$(printf '%s' "$ALGOLIA_APP_ID" | tr '[:upper:]' '[:lower:]')" "$path"
}

algolia_request() {
  local expected="$1"
  local method="$2"
  local path="$3"
  local data_file="${4:-}"
  local args=(--config "$ALGOLIA_AUTH_CONFIG" -X "$method")
  if [ -n "$data_file" ]; then
    args+=(--data @"$data_file")
  fi
  curl_http "$expected" "${args[@]}" "$(algolia_url "$path")" \
    || die "Algolia $method $path returned HTTP $HTTP_STATUS"
}

wait_for_algolia_task() {
  local index="$1"
  local task_id="$2"
  local attempt status

  for attempt in 1 2 3 4 5; do
    curl_http "200 404" --config "$ALGOLIA_AUTH_CONFIG" -X GET \
      "$(algolia_url "/1/indexes/$index/task/$task_id")" || return 1
    [ "$HTTP_STATUS" = "404" ] && return 0
    status="$(json_field "$HTTP_BODY" status 2>/dev/null || true)"
    [ "$status" = "published" ] && return 0
    sleep 1
  done
  return 1
}

fjcloud_request() {
  local expected="$1"
  local payload_file="$2"
  curl_http "$expected" --config "$FJCLOUD_AUTH_CONFIG" -X POST \
    --data @"$payload_file" \
    "${FJCLOUD_API_URL%/}/migration/algolia/list-indexes"
}

cleanup_probe_resources() {
  local index index_position
  set +e
  if [ -n "$RESTRICTED_LIST_KEY" ]; then
    delete_key "$RESTRICTED_LIST_KEY" || CLEANUP_FAILED=1
  fi
  if [ -n "$ACL_DENIED_KEY" ]; then
    delete_key "$ACL_DENIED_KEY" || CLEANUP_FAILED=1
  fi
  if [ -n "$RETRY_EXHAUSTION_KEY" ]; then
    delete_key "$RETRY_EXHAUSTION_KEY" || CLEANUP_FAILED=1
  fi
  if [ "${#CREATED_INDEXES[@]}" -gt 0 ]; then
    detach_primary_replicas || CLEANUP_FAILED=1
  fi
  for ((index_position=${#CREATED_INDEXES[@]} - 1; index_position >= 0; index_position--)); do
    index="${CREATED_INDEXES[$index_position]}"
    curl_http "200 204 404" --config "$ALGOLIA_AUTH_CONFIG" -X DELETE \
      "$(algolia_url "/1/indexes/$index")" || CLEANUP_FAILED=1
  done
  set -e
  if [ "$CLEANUP_FAILED" -ne 0 ]; then
    echo "ERROR: cleanup failed for disposable Algolia source discovery resources" >&2
    exit 1
  fi
}

detach_primary_replicas() {
  local payload task_id

  payload="$(secure_temp_file)" || return 1
  write_json_file "$payload" '{"replicas":[]}' || return 1
  curl_http "200 201 404" --config "$ALGOLIA_AUTH_CONFIG" -X PUT \
    --data @"$payload" \
    "$(algolia_url "/1/indexes/$INDEX_A/settings")" || return 1
  [ "$HTTP_STATUS" = "404" ] && return 0
  task_id="$(json_field "$HTTP_BODY" taskID 2>/dev/null || true)"
  if [ -n "$task_id" ]; then
    wait_for_algolia_task "$INDEX_A" "$task_id" || return 1
  fi
}

delete_key() {
  local key="$1"
  local url_config

  url_config="$(secure_temp_file)"
  write_url_config "$url_config" "$(algolia_url "/1/keys/$key")"
  curl_http "200 204 404" --config "$ALGOLIA_AUTH_CONFIG" -X DELETE --config "$url_config"
}

validate_inputs() {
  [ -n "$SECRET_FILE" ] || die "FJCLOUD_SECRET_FILE is required"
  [ -n "$FJCLOUD_API_URL" ] || die "FJCLOUD_API_URL is required"
  [ -n "$FJCLOUD_ZERO_INDEX_BEARER_TOKEN" ] || die "FJCLOUD_ZERO_INDEX_BEARER_TOKEN is required"
  [ -n "$RETRY_EXHAUSTION_KEY" ] || die "ALGOLIA_SOURCE_DISCOVERY_RETRY_EXHAUSTION_KEY is required"
  [[ "$PROBE_PREFIX" =~ ^[A-Za-z0-9_]+$ ]] || die "ALGOLIA_SOURCE_DISCOVERY_PROBE_PREFIX must use only letters, digits, and underscores"
  [[ "$RUN_ID" =~ ^[A-Za-z0-9_]+$ ]] || die "ALGOLIA_SOURCE_DISCOVERY_PROBE_RUN_ID must use only letters, digits, and underscores"
}

create_index_with_object() {
  local index="$1"
  local object_id="$2"
  local payload task_id

  payload="$(secure_temp_file)"
  write_json_file "$payload" "{\"requests\":[{\"action\":\"addObject\",\"body\":{\"objectID\":\"$object_id\",\"probe\":\"$index\"}}]}"
  algolia_request "200 201" POST "/1/indexes/$index/batch" "$payload"
  CREATED_INDEXES+=("$index")
  task_id="$(json_field "$HTTP_BODY" taskID)"
  if [ -n "$task_id" ]; then
    wait_for_algolia_task "$index" "$task_id" || die "Algolia task $task_id for $index did not publish"
  fi
}

set_primary_replicas() {
  local payload task_id

  payload="$(secure_temp_file)"
  write_json_file "$payload" "{\"replicas\":[\"$INDEX_B\"]}"
  algolia_request "200 201" PUT "/1/indexes/$INDEX_A/settings" "$payload"
  task_id="$(json_field "$HTTP_BODY" taskID)"
  if [ -n "$task_id" ]; then
    wait_for_algolia_task "$INDEX_A" "$task_id" || die "Algolia task $task_id for $INDEX_A did not publish"
  fi
}

create_key() {
  local acl_json="$1"
  local payload key

  payload="$(secure_temp_file)"
  write_json_file "$payload" "{\"acl\":$acl_json,\"indexes\":[\"$INDEX_A\",\"$INDEX_B\"]}"
  algolia_request "200 201" POST "/1/keys" "$payload"
  key="$(json_field "$HTTP_BODY" key)"
  [ -n "$key" ] || die "Algolia key creation response omitted key"
  printf '%s\n' "$key"
}

write_discovery_payload() {
  local path="$1"
  local api_key="$2"
  local cursor="${3:-}"
  local cursor_mode="${4:-omit-empty}"
  printf '%s' "$api_key" | python3 -c '
import json
import sys
payload = {
    "appId": sys.argv[2],
    "apiKey": sys.stdin.read(),
    "hitsPerPage": 1,
}
if sys.argv[3] or sys.argv[4] == "include":
    payload["cursor"] = sys.argv[3]
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, separators=(",", ":"))
' "$path" "$ALGOLIA_APP_ID" "$cursor" "$cursor_mode"
}

assert_response_under_budget() {
  local started_ns="$1"
  local elapsed_ms
  elapsed_ms="$((($(date +%s%N) - started_ns) / 1000000))"
  [ "$elapsed_ms" -lt 8000 ] || die "fjcloud discovery request exceeded 8s budget"
}

preconsume_retry_key_until_exhausted() {
  local attempt payload started_ns

  for attempt in 1 2 3 4 5 6; do
    payload="$(secure_temp_file)"
    write_discovery_payload "$payload" "$RETRY_EXHAUSTION_KEY"
    started_ns="$(date +%s%N)"
    fjcloud_request "200 403 503" "$payload" || die "retry exhaustion preconsume returned HTTP $HTTP_STATUS"
    assert_response_under_budget "$started_ns"
    if [ "$HTTP_STATUS" = "503" ]; then
      return 0
    fi
    sleep 1
  done

  die "retry exhaustion did not observe fjcloud HTTP 503 within 6 attempts"
}

capture_expected_fixture_metadata() {
  local page="$1"
  local restricted_auth_config attempt

  restricted_auth_config="$(secure_temp_file)"
  write_header_config "$restricted_auth_config" \
    "X-Algolia-Application-Id: $ALGOLIA_APP_ID" \
    "X-Algolia-API-Key: $RESTRICTED_LIST_KEY"
  for attempt in 1 2 3 4 5; do
    if curl_http "200" --config "$restricted_auth_config" -X GET \
      "$(algolia_url "/1/indexes?page=$page&hitsPerPage=1")"; then
      break
    fi
    if [ "$HTTP_STATUS" != "403" ] || [ "$attempt" -eq 5 ]; then
      die "Algolia fixture metadata request returned HTTP $HTTP_STATUS"
    fi
    sleep 1
  done
  EXPECTED_METADATA_FILE="$(secure_temp_file)"
  printf '%s' "$HTTP_BODY" > "$EXPECTED_METADATA_FILE"
}

assert_discovery_page() {
  local actual_body="$1"
  local expected_index="$2"
  local cursor_expectation="$3"
  local success_marker="$4"
  python3 - "$actual_body" "$EXPECTED_METADATA_FILE" "$expected_index" "$cursor_expectation" "$success_marker" <<'PY'
import json
import sys
data = json.loads(sys.argv[1])
with open(sys.argv[2], encoding="utf-8") as handle:
    fixtures = json.load(handle)["items"]
actual = data["items"]
assert len(actual) == 1, actual
item = actual[0]
expected = next(candidate for candidate in fixtures if candidate["name"] == sys.argv[3])
exact_fields = (
    "name", "entries", "dataSize", "fileSize", "updatedAt",
    "lastBuildTimeS", "pendingTask", "primary", "replicas",
)
normalized_expected = {
    **expected,
    "pendingTask": expected.get("pendingTask", False),
    "primary": expected.get("primary"),
    "replicas": expected.get("replicas", []),
}
assert {f: item[f] for f in exact_fields} == {
    f: normalized_expected[f] for f in exact_fields
}, (item, normalized_expected)
if sys.argv[4] == "present":
    assert data.get("nextCursor"), data
else:
    assert data.get("nextCursor") is None, data
print(sys.argv[5])
PY
}

exercise_fjcloud_discovery() {
  local payload started_ns first_cursor first_body second_body

  payload="$(secure_temp_file)"
  write_discovery_payload "$payload" "$RESTRICTED_LIST_KEY"
  started_ns="$(date +%s%N)"
  fjcloud_request "200" "$payload" || die "fjcloud first discovery page returned HTTP $HTTP_STATUS"
  assert_response_under_budget "$started_ns"
  first_body="$HTTP_BODY"
  capture_expected_fixture_metadata 0
  assert_discovery_page "$first_body" "$INDEX_A" present "metadata-exact:fjp_first"
  first_cursor="$(json_field "$first_body" nextCursor)"

  payload="$(secure_temp_file)"
  write_discovery_payload "$payload" "$RESTRICTED_LIST_KEY" "$first_cursor"
  started_ns="$(date +%s%N)"
  fjcloud_request "200" "$payload" || die "fjcloud second discovery page returned HTTP $HTTP_STATUS"
  assert_response_under_budget "$started_ns"
  second_body="$HTTP_BODY"
  capture_expected_fixture_metadata 1
  assert_discovery_page "$second_body" "$INDEX_B" absent "metadata-exact:fjp_second"

  started_ns="$(date +%s%N)"
  fjcloud_request "400" "$payload" || die "repeated cursor should fail with HTTP 400"
  assert_response_under_budget "$started_ns"

  payload="$(secure_temp_file)"
  write_discovery_payload "$payload" "$RESTRICTED_LIST_KEY" "tampered-cursor"
  started_ns="$(date +%s%N)"
  fjcloud_request "400" "$payload" || die "tampered cursor should fail with HTTP 400"
  assert_response_under_budget "$started_ns"

  payload="$(secure_temp_file)"
  write_discovery_payload "$payload" "$RESTRICTED_LIST_KEY" "" "include"
  started_ns="$(date +%s%N)"
  fjcloud_request "400" "$payload" || die "explicit empty cursor should fail with HTTP 400"
  assert_response_under_budget "$started_ns"

  preconsume_retry_key_until_exhausted
  echo "retry-exhaustion:live"

  payload="$(secure_temp_file)"
  write_discovery_payload "$payload" "$ACL_DENIED_KEY"
  started_ns="$(date +%s%N)"
  fjcloud_request "403" "$payload" || die "ACL-denied key should fail with HTTP 403"
  assert_response_under_budget "$started_ns"
  printf '%s' "$HTTP_BODY" | grep -q 'listIndexes' || die "ACL guidance omitted listIndexes"
  printf '%s' "$HTTP_BODY" | grep -q 'settings' || die "ACL guidance omitted settings"
  printf '%s' "$HTTP_BODY" | grep -q 'browse' || die "ACL guidance omitted browse"
}

main() {
  require_command curl
  require_command python3
  validate_inputs
  TMP_DIR="$(mktemp -d)"
  trap 'cleanup_probe_resources; rm -rf "$TMP_DIR"' EXIT

  load_named_secret_env_file "$SECRET_FILE"
  [ -n "${ALGOLIA_APP_ID:-}" ] || die "ALGOLIA_APP_ID is required in FJCLOUD_SECRET_FILE"
  [ -n "${ALGOLIA_ADMIN_KEY:-}" ] || die "ALGOLIA_ADMIN_KEY is required in FJCLOUD_SECRET_FILE"

  ALGOLIA_AUTH_CONFIG="$(secure_temp_file)"
  FJCLOUD_AUTH_CONFIG="$(secure_temp_file)"
  write_header_config "$ALGOLIA_AUTH_CONFIG" \
    "X-Algolia-Application-Id: $ALGOLIA_APP_ID" \
    "X-Algolia-API-Key: $ALGOLIA_ADMIN_KEY" \
    "Content-Type: application/json"
  write_header_config "$FJCLOUD_AUTH_CONFIG" \
    "Authorization: Bearer $FJCLOUD_ZERO_INDEX_BEARER_TOKEN" \
    "Content-Type: application/json"

  create_index_with_object "$INDEX_A" "probe-a"
  create_index_with_object "$INDEX_B" "probe-b"
  set_primary_replicas
  RESTRICTED_LIST_KEY="$(create_key '["listIndexes"]')"
  ACL_DENIED_KEY="$(create_key '["search"]')"
  sleep 3
  exercise_fjcloud_discovery
  cleanup_probe_resources
  trap - EXIT
  rm -rf "$TMP_DIR"
  echo "PASS: Algolia source discovery live probe"
}

main "$@"
