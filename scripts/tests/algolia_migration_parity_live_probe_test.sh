#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/algolia_migration_parity_live_probe.sh"

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
  mkdir -p "$WORK_DIR/bin" "$WORK_DIR/runtime"
  : > "$WORK_DIR/curl.log"
  : > "$WORK_DIR/git.log"
  : > "$WORK_DIR/psql.log"
  : > "$WORK_DIR/sleep.log"
  : > "$WORK_DIR/up.log"
  : > "$WORK_DIR/down.log"
  printf 'ALGOLIA_APP_ID=TESTAPP123\nALGOLIA_ADMIN_KEY=algolia-admin-secret\n' > "$WORK_DIR/secret.env"

  write_fake_command "$WORK_DIR/up.sh" '#!/usr/bin/env bash
set -euo pipefail
printf "db=%s pid_dir=%s enabled=%s\n" "${INTEGRATION_DB:-}" "${FJCLOUD_INTEGRATION_PID_DIR:-}" "${FJCLOUD_ALGOLIA_MIGRATION_ENABLED:-}" >> "$UP_LOG"
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

  write_fake_command "$WORK_DIR/bin/psql" '#!/usr/bin/env bash
printf "%s\n" "$*" >> "$PSQL_LOG"
if [[ "$*" == *"probe:engine_ack"* ]]; then
  case "${PSQL_SCENARIO:-success}" in
    delayed_ack)
      attempts_file="$WORK_DIR/engine-ack-attempts"
      attempts="$(cat "$attempts_file" 2>/dev/null || printf "0")"
      attempts=$((attempts + 1))
      printf "%s" "$attempts" > "$attempts_file"
      if [ "$attempts" -ge 3 ]; then
        touch "$WORK_DIR/engine-ack-ready"
        printf "1\n"
      else
        printf "0\n"
      fi
      exit 0
      ;;
    ack_missing)
      printf "0\n"
      exit 0
      ;;
    *)
      printf "1\n"
      exit 0
      ;;
  esac
fi
if [[ "$*" == *"probe:idempotency_source_unchanged"* ]]; then
  [ "${PSQL_SCENARIO:-success}" = "idempotency_source_changed" ] && { printf "0\n"; exit 0; }
  printf "1\n"
  exit 0
fi
if [[ "$*" == *"probe:idempotency_key_count"* ]]; then
  [ "${PSQL_SCENARIO:-success}" = "idempotency_key_count_wrong" ] && { printf "2\n"; exit 0; }
  printf "1\n"
  exit 0
fi
if [[ "$*" == *"probe:idempotency_terminal_job_count"* ]]; then
  [ "${PSQL_SCENARIO:-success}" = "idempotency_terminal_missing" ] && { printf "0\n"; exit 0; }
  printf "1\n"
  exit 0
fi
if [[ "$*" == *"probe:reconciliation_debug"* ]]; then
  printf "ack=outbox_pending,worker_claimed=false,worker_future=null,updated=1\n"
  exit 0
fi
if [[ "$*" == *"probe:cancel_intent"* ]]; then
  [ "${PSQL_SCENARIO:-success}" = "cancel_intent_wrong" ] && { printf "0\n"; exit 0; }
  printf "1\n"
  exit 0
fi
if [[ "$*" == *"probe:cancel_engine_link"* ]]; then
  [ "${PSQL_SCENARIO:-success}" = "cancel_engine_link_wrong" ] && { printf "2\n"; exit 0; }
  printf "1\n"
  exit 0
fi
if [[ "$*" == *"probe:resume_lifecycle_generation"* ]]; then
  if [ "${PSQL_SCENARIO:-success}" = "resume_generation_mutated" ]; then
    attempts_file="$WORK_DIR/resume-generation-attempts"
    attempts="$(cat "$attempts_file" 2>/dev/null || printf "0")"
    attempts=$((attempts + 1))
    printf "%s" "$attempts" > "$attempts_file"
    if [ "$attempts" -ge 2 ]; then
      printf "gen=2,resume_intent=1,resume_count=1,checkpoint=true\n"
      exit 0
    fi
  fi
  if [ "${PSQL_SCENARIO:-success}" = "resume_checkpoint_mutated" ]; then
    attempts_file="$WORK_DIR/resume-checkpoint-attempts"
    attempts="$(cat "$attempts_file" 2>/dev/null || printf "0")"
    attempts=$((attempts + 1))
    printf "%s" "$attempts" > "$attempts_file"
    if [ "$attempts" -ge 2 ]; then
      printf "gen=1,resume_intent=0,resume_count=0,checkpoint_hash=beta\n"
      exit 0
    fi
    printf "gen=1,resume_intent=0,resume_count=0,checkpoint_hash=alpha\n"
    exit 0
  fi
  printf "gen=1,resume_intent=0,resume_count=0,checkpoint_hash=null\n"
  exit 0
fi
if [[ "$*" == *"probe:resume_phase_job_count"* ]]; then
  [ "${PSQL_SCENARIO:-success}" = "resume_job_count_wrong" ] && { printf "2\n"; exit 0; }
  printf "1\n"
  exit 0
fi
[ "${PSQL_SCENARIO:-success}" = "database_residue" ] && { printf "1\n"; exit 0; }
printf "0\n"
'

  write_fake_command "$WORK_DIR/bin/sleep" '#!/usr/bin/env bash
printf "sleep %s\n" "${1:-}" >> "$SLEEP_LOG"
'

  write_fake_command "$WORK_DIR/bin/git" '#!/usr/bin/env bash
set -euo pipefail
printf "%s\n" "$*" >> "$GIT_LOG"
if [ "$1" = "grep" ]; then
  [ "${GIT_SCENARIO:-success}" = "w1_missing" ] && exit 1
  exit 0
fi
command git "$@"
'

  write_fake_command "$WORK_DIR/bin/curl" '#!/usr/bin/env bash
set -euo pipefail
printf "%s\n" "$*" >> "$CURL_LOG"
method="GET"
data_file=""
url=""
header_dump_file=""
config_file=""
idempotency_key=""
config_api_key=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X|--request) method="$2"; shift 2 ;;
    --data|-d|--data-binary) data_file="${2#@}"; shift 2 ;;
    --config|-K)
      config_file="$2"
      if [ -f "$2" ]; then
        cfg_url="$(sed -n "s/^url = \"\\(.*\\)\"$/\\1/p" "$2" | tail -1)"
        [ -n "$cfg_url" ] && url="$cfg_url"
        config_api_key="$(sed -n "s/^header = \"X-Algolia-API-Key: \\(.*\\)\"$/\\1/p" "$2" | tail -1)"
      fi
      shift 2
      ;;
    -D) header_dump_file="$2"; shift 2 ;;
    -H|--header)
      case "$2" in
        [Ii]dempotency-[Kk]ey:*)
          idempotency_key="${2#*: }"
          printf "IDEMPOTENCY_KEY %s\n" "$idempotency_key" >> "$CURL_LOG" ;;
      esac
      shift 2 ;;
    --connect-timeout|--max-time|-w) shift 2 ;;
    -s|-S|-sS|-f|-L) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf "REQUEST %s %s\n" "$method" "$url" >> "$CURL_LOG"
if [ "${CURL_SCENARIO:-success}" = "require_secret_file_credentials" ] \
  && [[ "$url" == *".algolia.net"* ]] \
  && [ ! -f "$WORK_DIR/credential-check-done" ]; then
  touch "$WORK_DIR/credential-check-done"
  if [ "$url" != "${url/explicitapp123/}" ] || [ "$config_api_key" != "algolia-admin-secret" ]; then
    printf "{\"error\":\"wrong_algolia_credentials\"}\n598"
    exit 0
  fi
fi

resource_exists() {
  local name="$1" created_file="$2" deleted_file="$3"
  grep -qxF "$name" "$created_file" 2>/dev/null || return 1
  ! grep -qxF "$name" "$deleted_file" 2>/dev/null
}

request_algolia_index() {
  local index="${url##*/1/indexes/}"
  index="${index%%/*}"
  index="${index%%\?*}"
  printf "%s\n" "$index"
}

request_algolia_key() {
  local key="${url##*/1/keys/}"
  key="${key%%/*}"
  key="${key%%\?*}"
  printf "%s\n" "$key"
}

request_flapjack_target() {
  local target="${url##*/indexes/}"
  target="${target%%/*}"
  target="${target%%\?*}"
  printf "%s\n" "$target"
}

record_created_key_authorizations() {
  local key="$1" payload="$2"
  python3 - "$payload" <<'"'"'PYKEYS'"'"' > "$WORK_DIR/key-indexes.tmp"
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
for index in payload.get("indexes", []):
    if isinstance(index, str):
        print(index)
PYKEYS
  while IFS= read -r index; do
    [ -n "$index" ] || continue
    if [ "${CURL_SCENARIO:-success}" = "idempotency_second_source_unauthorized" ] && [[ "$index" == *_id_source_alt ]]; then
      continue
    fi
    printf "%s\t%s\n" "$key" "$index" >> "$WORK_DIR/authorized-algolia-key-indexes"
  done < "$WORK_DIR/key-indexes.tmp"
}

restricted_key_authorizes_index() {
  local key="$1" index="$2"
  grep -qxF "$(printf "%s\t%s" "$key" "$index")" "$WORK_DIR/authorized-algolia-key-indexes" 2>/dev/null
}

source_hits="[{\"objectID\":\"doc-1\",\"title\":\"Alpha\",\"price\":100,\"tags\":[\"x\",\"y\"],\"_geoloc\":{\"lat\":40.0,\"lng\":-73.0}},{\"objectID\":\"doc-2\",\"title\":\"Beta\",\"price\":250,\"tags\":[\"y\"]},{\"objectID\":\"doc-3\",\"title\":\"Gamma\",\"price\":0,\"tags\":[]}]"
mutated_hits="[{\"objectID\":\"doc-1\",\"title\":\"Alpha\",\"price\":100,\"tags\":[\"x\",\"y\"],\"_geoloc\":{\"lat\":40.0,\"lng\":-73.0}},{\"objectID\":\"doc-2\",\"title\":\"Beta\",\"price\":251,\"tags\":[\"y\"]},{\"objectID\":\"doc-4\",\"title\":\"Delta\",\"price\":400,\"tags\":[\"z\"]}]"
migrated_hits="$source_hits"
case "${CURL_SCENARIO:-success}" in
  parity_mismatch|parity_mismatch_ack_guarded_delete)
    migrated_hits="[{\"objectID\":\"doc-1\",\"title\":\"Alpha\",\"price\":101,\"tags\":[\"x\",\"y\"],\"_geoloc\":{\"lat\":40.0,\"lng\":-73.0}},{\"objectID\":\"doc-2\",\"title\":\"Beta\",\"price\":250,\"tags\":[\"y\"]},{\"objectID\":\"doc-3\",\"title\":\"Gamma\",\"price\":0,\"tags\":[]}]"
    ;;
  idempotency_wrong_value)
    migrated_hits="[{\"objectID\":\"doc-1\",\"title\":\"Alpha\",\"price\":101,\"tags\":[\"x\",\"y\"],\"_geoloc\":{\"lat\":40.0,\"lng\":-73.0}},{\"objectID\":\"doc-2\",\"title\":\"Beta\",\"price\":250,\"tags\":[\"y\"]},{\"objectID\":\"doc-3\",\"title\":\"Gamma\",\"price\":0,\"tags\":[]}]"
    ;;
  idempotency_missing_hit)
    migrated_hits="[{\"objectID\":\"doc-1\",\"title\":\"Alpha\",\"price\":100,\"tags\":[\"x\",\"y\"],\"_geoloc\":{\"lat\":40.0,\"lng\":-73.0}},{\"objectID\":\"doc-2\",\"title\":\"Beta\",\"price\":250,\"tags\":[\"y\"]}]"
    ;;
  idempotency_extra_hit)
    migrated_hits="[{\"objectID\":\"doc-1\",\"title\":\"Alpha\",\"price\":100,\"tags\":[\"x\",\"y\"],\"_geoloc\":{\"lat\":40.0,\"lng\":-73.0}},{\"objectID\":\"doc-2\",\"title\":\"Beta\",\"price\":250,\"tags\":[\"y\"]},{\"objectID\":\"doc-3\",\"title\":\"Gamma\",\"price\":0,\"tags\":[]},{\"objectID\":\"doc-4\",\"title\":\"Delta\",\"price\":400,\"tags\":[\"z\"]}]"
    ;;
  idempotency_duplicate_object_id)
    migrated_hits="[{\"objectID\":\"doc-1\",\"title\":\"Alpha\",\"price\":100,\"tags\":[\"x\",\"y\"],\"_geoloc\":{\"lat\":40.0,\"lng\":-73.0}},{\"objectID\":\"doc-2\",\"title\":\"Beta\",\"price\":250,\"tags\":[\"y\"]},{\"objectID\":\"doc-2\",\"title\":\"Beta duplicate\",\"price\":250,\"tags\":[\"y\"]},{\"objectID\":\"doc-3\",\"title\":\"Gamma\",\"price\":0,\"tags\":[]}]"
    ;;
esac

case "$method $url" in
  "GET http://127.0.0.1:3099/health")
    printf "{\"status\":\"ok\"}\n200" ;;
  "GET http://127.0.0.1:7799/health")
    printf "{\"status\":\"ok\"}\n200" ;;
  "POST http://127.0.0.1:3099/auth/register")
    printf "{\"token\":\"register-token\"}\n201" ;;
  "POST http://127.0.0.1:3099/auth/login")
    printf "{\"token\":\"tenant-token\"}\n200" ;;
  "POST http://127.0.0.1:3099/indexes")
    touch "$WORK_DIR/warmup-created"
    printf "{\"name\":\"warmup\"}\n201" ;;
  "GET http://127.0.0.1:3099/migration/algolia/availability")
    if [ "${CURL_SCENARIO:-success}" = "pre_w1_unavailable" ]; then
      printf "{\"available\":false,\"capabilities\":{\"cancel\":false,\"resume\":false,\"replace\":false}}\n200"
    elif [ "${CURL_SCENARIO:-success}" = "overwrite_replace_unavailable" ]; then
      printf "{\"available\":true,\"capabilities\":{\"cancel\":true,\"resume\":false,\"replace\":false}}\n200"
    else
      printf "{\"available\":true,\"capabilities\":{\"cancel\":true,\"resume\":false,\"replace\":true}}\n200"
    fi ;;
  "GET https://"*".algolia.net/1/indexes?page=0&hitsPerPage=100")
    if [ "${ALGOLIA_RESIDUE:-0}" = "1" ]; then
      printf "{\"items\":[{\"name\":\"fjcloud_migration_parity_probe_test_leftover\"}]}\n200"
    else
      # Report every distinct source index still present (created via /batch and
      # not yet DELETEd), so a preserved-cleanup branch that skips those DELETEs
      # is correctly counted as source-index residue rather than silently zero.
      items=""
      seen=""
      if [ -f "$WORK_DIR/created-algolia-indexes" ]; then
        while IFS= read -r idx; do
          [ -n "$idx" ] || continue
          case ",$seen," in *,"$idx",*) continue ;; esac
          seen="${seen:+$seen,}$idx"
          grep -qxF "$idx" "$WORK_DIR/deleted-algolia-indexes" 2>/dev/null && continue
          items="${items:+$items,}{\"name\":\"$idx\"}"
        done < "$WORK_DIR/created-algolia-indexes"
      fi
      printf "{\"items\":[%s]}\n200" "$items"
    fi ;;
  "GET https://"*".algolia.net/1/keys/disposable-restricted-key")
    key="$(request_algolia_key)"
    if [ "${FAKE_ALGOLIA_KEY_RESIDUE:-0}" = "1" ]; then
      printf "{}\n200"
    elif [ "${CURL_SCENARIO:-success}" = "delayed_cleanup" ] && grep -qxF "$key" "$WORK_DIR/deleted-algolia-keys" 2>/dev/null && [ ! -f "$WORK_DIR/key-delete-observed-$key" ]; then
      touch "$WORK_DIR/key-delete-observed-$key"
      printf "{}\n200"
    elif resource_exists "$key" "$WORK_DIR/created-algolia-keys" "$WORK_DIR/deleted-algolia-keys"; then
      printf "{}\n200"
    else
      printf "{\"message\":\"not found\"}\n404"
    fi ;;
  "GET https://"*".algolia.net/1/keys/"*)
    key="$(request_algolia_key)"
    if resource_exists "$key" "$WORK_DIR/created-algolia-keys" "$WORK_DIR/deleted-algolia-keys"; then
      printf "{}\n200"
    else
      printf "{\"message\":\"not found\"}\n404"
    fi ;;
  "GET https://"*".algolia.net/1/indexes/"*"/task/1")
    printf "{\"status\":\"published\"}\n200" ;;
  "GET https://"*".algolia.net/1/indexes/"*)
    index="$(request_algolia_index)"
    if ! resource_exists "$index" "$WORK_DIR/created-algolia-indexes" "$WORK_DIR/deleted-algolia-indexes"; then
      printf "{\"message\":\"not found\"}\n404"
    elif [[ "$config_api_key" != disposable-restricted-key* ]] || restricted_key_authorizes_index "$config_api_key" "$index"; then
      printf "{\"name\":\"%s\"}\n200" "$index"
    else
      printf "{\"message\":\"not found\"}\n404"
    fi ;;
  "POST https://"*".algolia.net/1/indexes/"*"/batch")
    [ -n "$data_file" ] || exit 7
    if grep -q "\"action\":\"deleteObject\"" "$data_file"; then
      touch "$WORK_DIR/source-mutated"
    else
      grep -q "\"objectID\":\"doc-3\"" "$data_file" || exit 7
    fi
    batch_index="${url##*/1/indexes/}"; batch_index="${batch_index%%/batch*}"
    if grep -q "\"action\":\"deleteObject\"" "$data_file"; then
      printf "%s\n" "$batch_index" >> "$WORK_DIR/mutated-algolia-indexes"
    fi
    printf "%s\n" "$batch_index" >> "$WORK_DIR/created-algolia-indexes"
    printf "{\"taskID\":1}\n200" ;;
  "POST https://"*".algolia.net/1/keys")
    key_count="$(wc -l < "$WORK_DIR/created-algolia-keys" 2>/dev/null || printf "0")"
    key_count=$((key_count + 1))
    if [ "$key_count" -eq 1 ]; then
      key="disposable-restricted-key"
    else
      key="disposable-restricted-key-$key_count"
    fi
    printf "%s\n" "$key" >> "$WORK_DIR/created-algolia-keys"
    record_created_key_authorizations "$key" "$data_file"
    printf "{\"key\":\"%s\"}\n201" "$key" ;;
  "DELETE https://"*".algolia.net/1/keys/disposable-restricted-key")
    key="$(request_algolia_key)"
    if [ "${CURL_SCENARIO:-success}" = "combined_cleanup_leaks_later_resources" ] && [ "$key" != "disposable-restricted-key" ]; then
      printf "{}\n200"
    else
      printf "%s\n" "$key" >> "$WORK_DIR/deleted-algolia-keys"
      printf "{}\n200"
    fi ;;
  "DELETE https://"*".algolia.net/1/keys/"*)
    key="$(request_algolia_key)"
    if [ "${CURL_SCENARIO:-success}" = "combined_cleanup_leaks_later_resources" ] && [ "$key" != "disposable-restricted-key" ]; then
      printf "{}\n200"
    else
      printf "%s\n" "$key" >> "$WORK_DIR/deleted-algolia-keys"
      printf "{}\n200"
    fi ;;
  "DELETE https://"*".algolia.net/1/indexes/"*)
    touch "$WORK_DIR/source-index-deleted"
    deleted_index="${url##*/1/indexes/}"
    printf "%s\n" "$deleted_index" >> "$WORK_DIR/deleted-algolia-indexes"
    printf "{}\n200" ;;
  "POST https://"*".algolia.net/1/indexes/"*"/browse")
    index="$(request_algolia_index)"
    if ! resource_exists "$index" "$WORK_DIR/created-algolia-indexes" "$WORK_DIR/deleted-algolia-indexes"; then
      printf "{\"message\":\"not found\"}\n404"
      exit 0
    fi
    if grep -qxF "$index" "$WORK_DIR/mutated-algolia-indexes" 2>/dev/null; then
      printf "{\"hits\":%s}\n200" "$mutated_hits"
      exit 0
    fi
    printf "{\"hits\":%s}\n200" "$source_hits" ;;
  "POST http://127.0.0.1:3099/migration/algolia/destination-eligibility")
    if [ "${CURL_SCENARIO:-success}" = "destination_replace_provider_unsupported" ] \
      && [ -n "$data_file" ] \
      && grep -q "\"phase\":\"target\"" "$data_file" \
      && grep -q "\"mode\":\"replace\"" "$data_file"; then
      printf "{\"error\":\"migration_provider_unsupported\",\"code\":\"migration_provider_unsupported\"}\n400"
      exit 0
    fi
    if [ -n "$data_file" ] && grep -q "\"phase\":\"target\"" "$data_file"; then
      target_name="$(python3 - "$data_file" <<'"'"'PYTARGET'"'"'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
print(payload.get("target", {}).get("name", ""))
PYTARGET
)"
      [ -z "$target_name" ] || printf "%s\n" "$target_name" >> "$WORK_DIR/created-flapjack-targets"
    fi
    if [ -n "$data_file" ] && grep -q "\"phase\":\"provider\"" "$data_file"; then
      printf "{\"eligibilityToken\":\"provider.token\"}\n200"
    else
      printf "{\"eligibilityToken\":\"target.token\"}\n200"
    fi ;;
  "POST http://127.0.0.1:3099/migration/algolia/jobs")
    if [ -n "$data_file" ]; then
      job_mode="$(sed -n "s/.*\"mode\":\"\\([a-z_]*\\)\".*/\\1/p" "$data_file" | head -1)"
      printf "JOB_BODY mode=%s\n" "${job_mode:-none}" >> "$CURL_LOG"
      # Correlate the Idempotency-Key with the canonical full body for this exact
      # submission so a changed replay body or a mis-keyed replace fails the
      # ordered-tuple assertion.
      job_canonical_body="$(python3 - "$data_file" <<"PYCANON"
import json, sys
print(json.dumps(json.load(open(sys.argv[1])), sort_keys=True, separators=(",", ":")))
PYCANON
)"
      printf "JOB_REQUEST key=%s body=%s\n" "${idempotency_key:-none}" "$job_canonical_body" >> "$CURL_LOG"
    fi
    attempts_file="$WORK_DIR/job-create-attempts"
    attempts="$(cat "$attempts_file" 2>/dev/null || printf "0")"
    attempts=$((attempts + 1))
    printf "%s" "$attempts" > "$attempts_file"
    if [ "${CURL_SCENARIO:-success}" = "overwrite_dispatch_unrecoverable_accepted" ]; then
      [ -n "$header_dump_file" ] && printf "HTTP/1.1 202 Accepted\r\nLocation: /invalid/job-location\r\n\r\n" > "$header_dump_file"
      printf "{\"status\":\"queued\"}\n202"
      exit 0
    fi
    if [ "${CURL_SCENARIO:-success}" = "idempotency_replay_unrecoverable_accepted" ] && [ "$attempts" -eq 2 ]; then
      [ -n "$header_dump_file" ] && printf "HTTP/1.1 202 Accepted\r\nLocation: /invalid/job-location\r\n\r\n" > "$header_dump_file"
      printf "{\"status\":\"queued\"}\n202"
      exit 0
    fi
    if [ -n "$data_file" ] && grep -q "_id_source_alt" "$data_file"; then
      if [ "${CURL_SCENARIO:-success}" = "idempotency_changed_replay_accepted" ]; then
        [ -n "$header_dump_file" ] && printf "HTTP/1.1 202 Accepted\r\nLocation: /migration/algolia/jobs/job-456\r\n\r\n" > "$header_dump_file"
        printf "{\"id\":\"job-456\",\"status\":\"queued\"}\n202"
      elif [ "${CURL_SCENARIO:-success}" = "idempotency_changed_replay_location_only" ]; then
        [ -n "$header_dump_file" ] && printf "HTTP/1.1 202 Accepted\r\nLocation: /migration/algolia/jobs/job-456\r\n\r\n" > "$header_dump_file"
        printf "{\"id\":\"job-999\",\"status\":\"queued\"}\n202"
      else
        [ -n "$header_dump_file" ] && printf "HTTP/1.1 409 Conflict\r\n\r\n" > "$header_dump_file"
        printf "{\"code\":\"destination_conflict\",\"error\":\"destination_conflict\"}\n409"
      fi
      exit 0
    fi
    if [ "${CURL_SCENARIO:-success}" = "overwrite_dispatch_missing_body_id" ]; then
      [ -n "$header_dump_file" ] && printf "HTTP/1.1 202 Accepted\r\nLocation: /migration/algolia/jobs/job-123\r\n\r\n" > "$header_dump_file"
      printf "{\"status\":\"queued\"}\n202"
      exit 0
    fi
    if [ "${CURL_SCENARIO:-success}" = "idempotency_replay_missing_body_id" ] && [ "$attempts" -eq 2 ]; then
      [ -n "$header_dump_file" ] && printf "HTTP/1.1 202 Accepted\r\nLocation: /migration/algolia/jobs/job-123\r\n\r\n" > "$header_dump_file"
      printf "{\"status\":\"queued\"}\n202"
      exit 0
    fi
    job_id="job-123"
    if [ -n "$data_file" ] && grep -q "_cp_source" "$data_file"; then
      job_id="job-cp"
    elif [ -n "$data_file" ] && grep -q "_rr_source" "$data_file"; then
      job_id="job-rr"
    fi
    location="/migration/algolia/jobs/$job_id"
    if [ "${CURL_SCENARIO:-success}" = "idempotency_replay_changed_job" ] && [ "$attempts" -eq 2 ]; then
      job_id="job-456"
      location="/migration/algolia/jobs/job-456"
    fi
    if [ "${CURL_SCENARIO:-success}" = "idempotency_replay_changed_location" ] && [ "$attempts" -eq 2 ]; then
      location="/migration/algolia/jobs/job-456"
    fi
    [ -n "$header_dump_file" ] && printf "HTTP/1.1 202 Accepted\r\nLocation: %s\r\n\r\n" "$location" > "$header_dump_file"
    printf "{\"id\":\"%s\",\"status\":\"queued\"}\n202" "$job_id" ;;
  "GET http://127.0.0.1:3099/migration/algolia/jobs/"*)
    job_id="${url##*/}"
    if [ "$job_id" = "job-cp" ]; then
      if [ "${CURL_SCENARIO:-success}" = "cancel_partial_already_terminal" ]; then
        printf "{\"id\":\"job-cp\",\"status\":\"completed\",\"publicationDisposition\":\"promoted\",\"resumable\":false}\n200"
      elif [ ! -f "$WORK_DIR/cancel-requested-job-cp" ]; then
        printf "{\"id\":\"job-cp\",\"status\":\"copying_documents\",\"publicationDisposition\":\"not_started\",\"resumable\":false,\"cancelRequestedAt\":null}\n200"
      elif [ "${CURL_SCENARIO:-success}" = "cancel_partial_terminal_promoted" ]; then
        printf "{\"id\":\"job-cp\",\"status\":\"completed\",\"publicationDisposition\":\"promoted\",\"resumable\":false,\"cancelRequestedAt\":\"2026-07-22T00:00:01Z\"}\n200"
      else
        printf "{\"id\":\"job-cp\",\"status\":\"cancelled\",\"publicationDisposition\":\"unchanged\",\"resumable\":false,\"cancelRequestedAt\":\"2026-07-22T00:00:01Z\"}\n200"
      fi
      exit 0
    fi
    if [ "$job_id" = "job-rr" ]; then
      if [ "${CURL_SCENARIO:-success}" = "resume_refused_resumable_true" ]; then
        printf "{\"id\":\"job-rr\",\"status\":\"completed\",\"publicationDisposition\":\"promoted\",\"resumable\":true}\n200"
      else
        printf "{\"id\":\"job-rr\",\"status\":\"completed\",\"publicationDisposition\":\"promoted\",\"resumable\":false}\n200"
      fi
      exit 0
    fi
    case "${CURL_SCENARIO:-success}" in
      running_job) printf "{\"id\":\"%s\",\"status\":\"copying_documents\",\"publicationDisposition\":\"not_started\",\"resumable\":false}\n200" "$job_id" ;;
      failed_job) printf "{\"id\":\"%s\",\"status\":\"failed\",\"publicationDisposition\":\"unchanged\",\"resumable\":false}\n200" "$job_id" ;;
      malformed_job) printf "{\"id\":\"%s\",\"publicationDisposition\":\"promoted\"}\n200" "$job_id" ;;
      completed_with_warnings) printf "{\"id\":\"%s\",\"status\":\"completed_with_warnings\",\"publicationDisposition\":\"promoted\",\"resumable\":false}\n200" "$job_id" ;;
      *) printf "{\"id\":\"%s\",\"status\":\"completed\",\"publicationDisposition\":\"promoted\",\"resumable\":false}\n200" "$job_id" ;;
    esac ;;
  "POST http://127.0.0.1:3099/migration/algolia/jobs/job-cp/cancel")
    if [ ! -f "$WORK_DIR/cancel-requested-job-cp" ]; then
      touch "$WORK_DIR/cancel-requested-job-cp"
      printf "{\"id\":\"job-cp\",\"status\":\"cancelling\",\"publicationDisposition\":\"not_started\",\"resumable\":false,\"cancelRequestedAt\":\"2026-07-22T00:00:01Z\"}\n202"
    elif [ "${CURL_SCENARIO:-success}" = "cancel_partial_replay_not_ok" ]; then
      printf "{\"id\":\"job-cp\",\"status\":\"cancelling\",\"publicationDisposition\":\"not_started\",\"resumable\":false,\"cancelRequestedAt\":\"2026-07-22T00:00:01Z\"}\n202"
    elif [ "${CURL_SCENARIO:-success}" = "cancel_partial_cancel_at_changes" ]; then
      printf "{\"id\":\"job-cp\",\"status\":\"cancelling\",\"publicationDisposition\":\"not_started\",\"resumable\":false,\"cancelRequestedAt\":\"2026-07-22T00:00:09Z\"}\n200"
    else
      printf "{\"id\":\"job-cp\",\"status\":\"cancelling\",\"publicationDisposition\":\"not_started\",\"resumable\":false,\"cancelRequestedAt\":\"2026-07-22T00:00:01Z\"}\n200"
    fi ;;
  "POST http://127.0.0.1:3099/migration/algolia/jobs/job-rr/resume")
    if [ "${CURL_SCENARIO:-success}" = "resume_refused_resume_accepted" ]; then
      printf "{\"id\":\"job-rr\",\"status\":\"resuming\",\"publicationDisposition\":\"not_started\",\"resumable\":true}\n202"
    else
      printf "{\"code\":\"not_resumable\",\"error\":\"not_resumable\"}\n409"
    fi ;;
  "POST http://127.0.0.1:3099/indexes/"*"/browse")
    target="$(request_flapjack_target)"
    if grep -qxF "$target" "$WORK_DIR/deleted-flapjack-targets" 2>/dev/null; then
      if [ "${CURL_SCENARIO:-success}" = "delayed_cleanup" ] && [ ! -f "$WORK_DIR/target-delete-observed-$target" ]; then
        touch "$WORK_DIR/target-delete-observed-$target"
      else
        printf "{\"error\":\"not found\"}\n404"
        exit 0
      fi
    fi
    if [[ "$target" == *_cp_target ]]; then
      # A cancelled create-into-fresh never publishes: the target browse is an
      # empty successful browse (customer-visible 0). The RED scenario returns
      # documents to prove the phase fails when the cancel published anything.
      if [ "${CURL_SCENARIO:-success}" = "cancel_partial_customer_visible" ]; then
        printf "{\"hits\":%s}\n200" "$source_hits"
      elif [ "${CURL_SCENARIO:-success}" = "cancel_partial_browse_request_failed" ]; then
        printf "{\"error\":\"backend_unavailable\"}\n599"
      elif [ "${CURL_SCENARIO:-success}" = "cancel_partial_browse_malformed" ]; then
        printf "{not-json}\n200"
      else
        printf "{\"hits\":[]}\n200"
      fi
      exit 0
    fi
    if [ -f "$WORK_DIR/source-mutated" ] && [[ "$target" == *_ow_target ]]; then
      case "${CURL_SCENARIO:-success}" in
        overwrite_retains_doc3)
          printf "{\"hits\":[{\"objectID\":\"doc-1\",\"title\":\"Alpha\",\"price\":100,\"tags\":[\"x\",\"y\"],\"_geoloc\":{\"lat\":40.0,\"lng\":-73.0}},{\"objectID\":\"doc-2\",\"title\":\"Beta\",\"price\":251,\"tags\":[\"y\"]},{\"objectID\":\"doc-3\",\"title\":\"Gamma\",\"price\":0,\"tags\":[]},{\"objectID\":\"doc-4\",\"title\":\"Delta\",\"price\":400,\"tags\":[\"z\"]}]}\n200"
          exit 0
          ;;
        *) migrated_hits="$mutated_hits" ;;
      esac
    elif [ "${CURL_SCENARIO:-success}" = "overwrite_accumulates" ] && [[ "$target" == *_ow_target ]]; then
      printf "{\"hits\":%s}\n200" "${source_hits%]}$(printf ',')${source_hits#[}"
      exit 0
    fi
    printf "{\"hits\":%s}\n200" "$migrated_hits" ;;
  "DELETE http://127.0.0.1:3099/indexes/fjcloud_migration_parity_probe_test_warmup")
    touch "$WORK_DIR/warmup-deleted"; printf "\n204" ;;
  "DELETE http://127.0.0.1:3099/indexes/"*)
    if [ "${CURL_SCENARIO:-success}" = "parity_mismatch_ack_guarded_delete" ] && [ ! -f "$WORK_DIR/engine-ack-ready" ]; then
      printf "{\"error\":\"destination_conflict\"}\n409"
      exit 0
    fi
    if [ "${CURL_SCENARIO:-success}" = "target_delete_retry" ] && [ ! -f "$WORK_DIR/target-delete-first-failed" ]; then
      touch "$WORK_DIR/target-delete-first-failed"
      printf "{\"error\":\"rate_limited\"}\n429"
      exit 0
    fi
    if [ "${CURL_SCENARIO:-success}" = "target_delete_reconciliation_wait" ]; then
      attempts_file="$WORK_DIR/target-delete-attempts"
      attempts="$(cat "$attempts_file" 2>/dev/null || printf "0")"
      attempts=$((attempts + 1))
      printf "%s" "$attempts" >"$attempts_file"
      if [ "$attempts" -le 6 ]; then
        printf "{\"error\":\"destination_conflict\"}\n409"
        exit 0
      fi
    fi
    if [ "${CURL_SCENARIO:-success}" = "target_delete_conflict_persistent" ]; then
      printf "{\"error\":\"destination_conflict\"}\n409"
      exit 0
    fi
    target="$(request_flapjack_target)"
    if [ "${CURL_SCENARIO:-success}" = "combined_cleanup_leaks_later_resources" ] && [[ "$target" == *_id_target ]]; then
      printf "\n204"
    else
      printf "%s\n" "$target" >> "$WORK_DIR/deleted-flapjack-targets"
      printf "\n204"
    fi ;;
  *)
    printf "{\"error\":\"unexpected\",\"method\":\"%s\",\"url\":\"%s\"}\n599" "$method" "$url" ;;
esac
'
}

run_probe() {
  local env_args=(-u ALGOLIA_APP_ID -u ALGOLIA_ADMIN_KEY)
  if [ "${RUN_WITH_EXPORTED_ALGOLIA:-0}" = "1" ]; then
    env_args=(ALGOLIA_APP_ID=EXPLICITAPP123 ALGOLIA_ADMIN_KEY=explicit-admin-secret)
  fi
  set +e
  RUN_STDOUT="$(
    env "${env_args[@]}" \
    PATH="$WORK_DIR/bin:$PATH" \
    FJCLOUD_SECRET_FILE="$WORK_DIR/secret.env" \
    ALGOLIA_MIGRATION_PARITY_RUN_ID="test" \
    ALGOLIA_MIGRATION_PARITY_RUNTIME_PARENT="$WORK_DIR/runtime" \
    ALGOLIA_MIGRATION_PARITY_POLL_SECONDS="${PROBE_POLL_SECONDS:-0}" \
    ALGOLIA_MIGRATION_PARITY_SETTLE_SECONDS=0 \
    ALGOLIA_MIGRATION_PARITY_INTEGRATION_UP="$WORK_DIR/up.sh" \
    ALGOLIA_MIGRATION_PARITY_INTEGRATION_DOWN="$WORK_DIR/down.sh" \
    API_PORT=3099 \
    FLAPJACK_PORT=7799 \
    UP_LOG="$WORK_DIR/up.log" \
    DOWN_LOG="$WORK_DIR/down.log" \
    CURL_LOG="$WORK_DIR/curl.log" \
    GIT_LOG="$WORK_DIR/git.log" \
    PSQL_LOG="$WORK_DIR/psql.log" \
    SLEEP_LOG="$WORK_DIR/sleep.log" \
    WORK_DIR="$WORK_DIR" \
    ALGOLIA_RESIDUE="${ALGOLIA_RESIDUE:-0}" \
    FAKE_ALGOLIA_KEY_RESIDUE="${FAKE_ALGOLIA_KEY_RESIDUE:-0}" \
    CURL_SCENARIO="${CURL_SCENARIO:-success}" \
    GIT_SCENARIO="${GIT_SCENARIO:-success}" \
    PSQL_SCENARIO="${PSQL_SCENARIO:-success}" \
    bash "$TARGET_SCRIPT" "$@" 2>&1
  )"
  RUN_EXIT_CODE=$?
  set -e
}

assert_no_algolia_http() {
  assert_not_contains "$(cat "$WORK_DIR/curl.log")" "algolia.net" "$1"
}

assert_request_logged() {
  local request="$1" msg="$2"
  if python3 - "$WORK_DIR/curl.log" "$request" <<'PY'
import sys

log_path, request = sys.argv[1:]
needle = f"REQUEST {request}\n"
with open(log_path, encoding="utf-8") as handle:
    raise SystemExit(0 if needle in handle.readlines() else 1)
PY
  then
    pass "$msg"
  else
    fail "$msg"
  fi
}

assert_request_order() {
  local first="$1" second="$2" msg="$3"
  if python3 - "$WORK_DIR/curl.log" "$first" "$second" <<'PY'
import sys

log_path, first, second = sys.argv[1:]
with open(log_path, encoding="utf-8") as handle:
    lines = handle.readlines()
try:
    first_line = next(i for i, line in enumerate(lines) if first in line)
    second_line = next(i for i, line in enumerate(lines) if second in line)
except StopIteration:
    raise SystemExit(1)
raise SystemExit(0 if first_line < second_line else 1)
PY
  then
    pass "$msg"
  else
    fail "$msg"
  fi
}

test_rejects_unknown_empty_and_missing_credentials_before_algolia() {
  setup_workspace
  run_probe --phases unknown
  assert_eq "$RUN_EXIT_CODE" "1" "unknown phase should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=invalid_phases" "unknown phase emits ACTION_REQUIRED"
  assert_no_algolia_http "unknown phase stops before Algolia"

  setup_workspace
  run_probe --phases ""
  assert_eq "$RUN_EXIT_CODE" "1" "empty phase should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=invalid_phases" "empty phase emits ACTION_REQUIRED"
  assert_no_algolia_http "empty phase stops before Algolia"

  setup_workspace
  run_probe --phases
  assert_eq "$RUN_EXIT_CODE" "1" "missing phase value should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=invalid_phases" "missing phase value emits ACTION_REQUIRED"
  assert_no_algolia_http "missing phase value stops before Algolia"

  setup_workspace
  rm -f "$WORK_DIR/secret.env"
  run_probe --phases create_into_fresh
  assert_eq "$RUN_EXIT_CODE" "1" "missing credentials should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=missing_credentials" "missing credentials emits ACTION_REQUIRED"
  assert_no_algolia_http "missing credentials stops before Algolia"
}

test_exported_credentials_supply_missing_secret_file_values() {
  setup_workspace
  : > "$WORK_DIR/secret.env"
  RUN_WITH_EXPORTED_ALGOLIA=1 run_probe --phases create_into_fresh
  assert_eq "$RUN_EXIT_CODE" "0" "exported Algolia credentials should supply missing secret file values"
  assert_contains "$RUN_STDOUT" "RESULT|status=PASS|phases=create_into_fresh" "exported credentials reach a passing live flow"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "https://explicitapp123.algolia.net" "exported app id is used for Algolia requests"
  assert_not_contains "$RUN_STDOUT" "explicit-admin-secret" "explicit admin key is redacted"
}

test_secret_file_credentials_override_conflicting_ambient_values() {
  setup_workspace
  RUN_WITH_EXPORTED_ALGOLIA=1 CURL_SCENARIO=require_secret_file_credentials \
    run_probe --phases create_into_fresh
  assert_eq "$RUN_EXIT_CODE" "0" "canonical secret file credentials should override ambient values"
  assert_contains "$RUN_STDOUT" "RESULT|status=PASS|phases=create_into_fresh" "canonical credentials reach a passing live flow"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "https://testapp123.algolia.net" "canonical app id is used for Algolia requests"
  assert_not_contains "$(cat "$WORK_DIR/curl.log")" "https://explicitapp123.algolia.net" "ambient app id is not used"
  assert_not_contains "$RUN_STDOUT" "algolia-admin-secret" "canonical admin key is redacted"
  assert_not_contains "$RUN_STDOUT" "explicit-admin-secret" "ambient admin key is not exposed"
}

test_static_and_runtime_availability_stop_before_fixture_creation() {
  setup_workspace
  GIT_SCENARIO=w1_missing run_probe --phases create_into_fresh
  assert_eq "$RUN_EXIT_CODE" "1" "missing W1 static surface should fail"
  assert_contains "$RUN_STDOUT" "owner=W1" "static gate names W1 owner"
  assert_contains "$RUN_STDOUT" "infra/api/src/routes/migration.rs" "static gate names unblock file"
  assert_no_algolia_http "static gate stops before Algolia"

  setup_workspace
  CURL_SCENARIO=pre_w1_unavailable run_probe --phases create_into_fresh
  assert_eq "$RUN_EXIT_CODE" "1" "unavailable W1 response should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=w1_availability_unavailable" "unavailable response emits ACTION_REQUIRED"
  assert_not_contains "$(cat "$WORK_DIR/curl.log")" "/batch" "availability failure stops before fixture creation"
}

test_terminal_failures_and_parity_mismatch_are_action_required() {
  for scenario in running_job failed_job malformed_job; do
    setup_workspace
    CURL_SCENARIO="$scenario" run_probe --phases create_into_fresh
    assert_eq "$RUN_EXIT_CODE" "1" "$scenario should fail"
    assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=inconclusive_evidence" "$scenario emits inconclusive evidence"
  done

  setup_workspace
  ALGOLIA_MIGRATION_PARITY_PRESERVE_FAILURE_RUNTIME=1 CURL_SCENARIO=failed_job run_probe --phases create_into_fresh
  assert_eq "$RUN_EXIT_CODE" "1" "failed job diagnostic preserve should still fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=inconclusive_evidence" "failed job diagnostic preserve emits ACTION_REQUIRED"
  assert_contains "$RUN_STDOUT" "local_stack=1|runtime_files=1" "failed job diagnostic preserve reports local residue"
  assert_eq "$(cat "$WORK_DIR/down.log")" "" "failed job diagnostic preserve must not invoke integration-down"

  setup_workspace
  CURL_SCENARIO=parity_mismatch run_probe --phases create_into_fresh
  assert_eq "$RUN_EXIT_CODE" "1" "parity mismatch should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=parity_mismatch" "parity mismatch emits ACTION_REQUIRED"
  assert_contains "$RUN_STDOUT" "PARITY_DIFF|field_mismatches=doc-1:price" "parity mismatch names changed customer field"
}

test_success_emits_parity_phase_and_full_cleanup() {
  setup_workspace
  run_probe --phases create_into_fresh
  assert_eq "$RUN_EXIT_CODE" "0" "successful parity probe should pass"
  assert_request_logged "POST http://127.0.0.1:3099/indexes" "warmup creates a public index"
  assert_request_logged "DELETE http://127.0.0.1:3099/indexes/fjcloud_migration_parity_probe_test_warmup" "warmup removes the public index"
  assert_request_order "REQUEST POST http://127.0.0.1:3099/indexes" "REQUEST POST http://127.0.0.1:3099/migration/algolia/destination-eligibility" "warmup runs before destination eligibility"
  assert_contains "$RUN_STDOUT" "PHASE|name=parity_create_into_fresh|expected=count=3,diff=empty|observed=count_source=3,count_migrated=3,only_in_source=0,only_in_migrated=0,field_mismatches=0|pass=true" "success emits exact parity phase"
  assert_contains "$RUN_STDOUT" "CLEANUP|algolia_indexes=0|flapjack_indexes=0|algolia_keys=0|local_stack=0|runtime_files=0" "success cleanup reports all residues"
  assert_contains "$(cat "$WORK_DIR/psql.log")" "probe:engine_ack" "success waits for durable engine ACK before cleanup"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "DELETE https://testapp123.algolia.net/1/indexes/" "source index cleanup is attempted"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "DELETE https://testapp123.algolia.net/1/keys/disposable-restricted-key" "source key cleanup is attempted"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "DELETE http://127.0.0.1:3099/indexes/fjcloud_migration_parity_probe_test_target" "flapjack target cleanup is attempted"
  assert_not_contains "$RUN_STDOUT" "algolia-admin-secret" "probe output redacts admin key"

  setup_workspace
  CURL_SCENARIO=completed_with_warnings run_probe --phases create_into_fresh
  assert_eq "$RUN_EXIT_CODE" "0" "completed with promoted warnings should pass"
  assert_contains "$RUN_STDOUT" "RESULT|status=PASS|phases=create_into_fresh" "completed with promoted warnings emits PASS"
}

test_stage2_phases_are_accepted_and_emit_success_markers() {
  setup_workspace
  run_probe --phases overwrite_rerun
  assert_eq "$RUN_EXIT_CODE" "0" "overwrite_rerun should be accepted"
  assert_contains "$RUN_STDOUT" "PHASE|name=overwrite_initial|expected=count=3|observed=count=3|pass=true" "overwrite_rerun emits initial count"
  assert_contains "$RUN_STDOUT" "PHASE|name=overwrite_rerun|expected=count=3,object_ids=doc-1,doc-2,doc-3,diff=empty|observed=count_source=3,count_migrated=3,only_in_source=0,only_in_migrated=0,field_mismatches=0,object_ids=doc-1,doc-2,doc-3|pass=true" "overwrite_rerun emits post-rerun parity"
  assert_contains "$RUN_STDOUT" "PHASE|name=overwrite_rerun_mutated|expected=count=3,object_ids=doc-1,doc-2,doc-4,diff=empty|observed=count_source=3,count_migrated=3,only_in_source=0,only_in_migrated=0,field_mismatches=0,object_ids=doc-1,doc-2,doc-4|pass=true" "overwrite_rerun emits mutated-source parity"

  setup_workspace
  run_probe --phases idempotency
  assert_eq "$RUN_EXIT_CODE" "0" "idempotency should be accepted"
  assert_contains "$RUN_STDOUT" "PHASE|name=idempotency_replay|expected=same_job_and_location|observed=same_job_and_location|pass=true" "idempotency emits replay equality"
  assert_contains "$RUN_STDOUT" "PHASE|name=idempotency_conflict|expected=changed_body_409_destination_conflict|observed=changed_body_409_destination_conflict|pass=true" "idempotency emits changed-body conflict"
  assert_contains "$RUN_STDOUT" "PHASE|name=idempotency_db|expected=source_unchanged,row_count=1,terminal_jobs=1|observed=source_unchanged,row_count=1,terminal_jobs=1|pass=true" "idempotency emits DB evidence"
  assert_contains "$RUN_STDOUT" "PHASE|name=idempotency_parity|expected=count=3,object_ids=doc-1,doc-2,doc-3,diff=empty|observed=count_source=3,count_migrated=3,only_in_source=0,only_in_migrated=0,field_mismatches=0,object_ids=doc-1,doc-2,doc-3|pass=true" "idempotency emits exact target parity"

  setup_workspace
  run_probe --phases overwrite_rerun,idempotency
  assert_eq "$RUN_EXIT_CODE" "0" "combined Stage 2 phases should pass"
  assert_contains "$RUN_STDOUT" "RESULT|status=PASS|phases=overwrite_rerun,idempotency" "combined phases emit PASS"
}

test_stage2_overwrite_failures_are_action_required() {
  setup_workspace
  CURL_SCENARIO=overwrite_accumulates run_probe --phases overwrite_rerun
  assert_eq "$RUN_EXIT_CODE" "1" "replace append should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED" "replace append emits ACTION_REQUIRED"

  setup_workspace
  CURL_SCENARIO=overwrite_retains_doc3 run_probe --phases overwrite_rerun
  assert_eq "$RUN_EXIT_CODE" "1" "replace retaining doc-3 should fail"
  assert_contains "$RUN_STDOUT" "PARITY_DIFF|field_mismatches=none|only_in_source=0|only_in_migrated=1" "retained doc-3 is reported as migrated-only"
}

test_stage2_overwrite_requires_replace_capability() {
  setup_workspace
  CURL_SCENARIO=overwrite_replace_unavailable run_probe --phases overwrite_rerun
  assert_eq "$RUN_EXIT_CODE" "1" "overwrite_rerun without replace capability should fail closed"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=replace_unavailable" "missing replace capability emits ACTION_REQUIRED"
  assert_not_contains "$(cat "$WORK_DIR/curl.log")" "/batch" "replace gate stops before seeding or mutating Algolia state"
}

test_stage2_overwrite_replace_eligibility_provider_unsupported_fails_closed() {
  setup_workspace
  CURL_SCENARIO=destination_replace_provider_unsupported run_probe --phases overwrite_rerun
  assert_eq "$RUN_EXIT_CODE" "1" "replace eligibility 400 must fail closed"
  assert_contains "$RUN_STDOUT" "ERROR|reason=endpoint_unavailable|step=destination_eligibility_replace" "replace eligibility failure reports the exact step"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=endpoint_unavailable" "replace eligibility failure emits ACTION_REQUIRED"
}

test_stage2_location_only_accepted_replay_is_awaited() {
  setup_workspace
  CURL_SCENARIO=idempotency_changed_replay_location_only PSQL_SCENARIO=delayed_ack PROBE_POLL_SECONDS=4 run_probe --phases idempotency
  assert_eq "$RUN_EXIT_CODE" "1" "location-only accepted replay should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED" "location-only accepted replay emits ACTION_REQUIRED"
  assert_request_logged "GET http://127.0.0.1:3099/migration/algolia/jobs/job-456" "location-only accepted replay polls the header-named job before cleanup"
  assert_contains "$(cat "$WORK_DIR/psql.log")" "id = 'job-456'" "location-only accepted replay waits for header-named job ACK before cleanup"
}

test_stage2_idempotency_failures_are_action_required() {
  for scenario in idempotency_replay_changed_job idempotency_replay_changed_location idempotency_changed_replay_accepted; do
    setup_workspace
    CURL_SCENARIO="$scenario" PSQL_SCENARIO=delayed_ack PROBE_POLL_SECONDS=4 run_probe --phases idempotency
    assert_eq "$RUN_EXIT_CODE" "1" "$scenario should fail"
    assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED" "$scenario emits ACTION_REQUIRED"
    assert_contains "$(cat "$WORK_DIR/psql.log")" "probe:engine_ack" "$scenario waits for durable engine ACK before cleanup"
    if [ "$scenario" = "idempotency_changed_replay_accepted" ]; then
      assert_request_logged "GET http://127.0.0.1:3099/migration/algolia/jobs/job-456" "$scenario polls unexpected accepted job before cleanup"
      assert_contains "$(cat "$WORK_DIR/psql.log")" "id = 'job-456'" "$scenario waits for unexpected accepted job ACK before cleanup"
    fi
  done

  for scenario in idempotency_source_changed idempotency_key_count_wrong idempotency_terminal_missing; do
    setup_workspace
    PSQL_SCENARIO="$scenario" PROBE_POLL_SECONDS=4 run_probe --phases idempotency
    assert_eq "$RUN_EXIT_CODE" "1" "$scenario should fail"
    assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=inconclusive_evidence" "$scenario emits inconclusive evidence"
    assert_contains "$(cat "$WORK_DIR/psql.log")" "probe:engine_ack" "$scenario waits for durable engine ACK before cleanup"
  done

  setup_workspace
  CURL_SCENARIO=running_job run_probe --phases idempotency
  assert_eq "$RUN_EXIT_CODE" "1" "idempotency job left non-terminal should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=inconclusive_evidence" "non-terminal idempotency job emits inconclusive evidence"

  for scenario in idempotency_wrong_value idempotency_missing_hit idempotency_extra_hit idempotency_duplicate_object_id; do
    setup_workspace
    CURL_SCENARIO="$scenario" run_probe --phases idempotency
    assert_eq "$RUN_EXIT_CODE" "1" "$scenario should fail exact idempotency parity"
    assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED" "$scenario emits ACTION_REQUIRED"
  done
}

assert_request_count_at_least() {
  local request="$1" minimum="$2" msg="$3"
  if python3 - "$WORK_DIR/curl.log" "$request" "$minimum" <<'PY'
import sys

log_path, request, minimum = sys.argv[1:]
needle = f"REQUEST {request}"
with open(log_path, encoding="utf-8") as handle:
    count = sum(1 for line in handle if line.rstrip("\n") == needle)
raise SystemExit(0 if count >= int(minimum) else 1)
PY
  then
    pass "$msg"
  else
    fail "$msg"
  fi
}

test_stage2_overwrite_phase_set_preflights_replace_capability() {
  setup_workspace
  CURL_SCENARIO=overwrite_replace_unavailable run_probe --phases idempotency,overwrite_rerun
  assert_eq "$RUN_EXIT_CODE" "1" "phase set with overwrite_rerun must fail closed when replace is unavailable"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=replace_unavailable" "missing replace capability emits ACTION_REQUIRED for the whole set"
  assert_not_contains "$(cat "$WORK_DIR/curl.log")" "/batch" "phase-set preflight stops before any earlier phase seeds Algolia"
  assert_not_contains "$(cat "$WORK_DIR/curl.log")" "REQUEST POST http://127.0.0.1:3099/migration/algolia/jobs" "phase-set preflight stops before any idempotency job is accepted"
}

test_stage2_overwrite_dispatch_location_only_accepted_job_is_awaited() {
  setup_workspace
  CURL_SCENARIO=overwrite_dispatch_missing_body_id run_probe --phases overwrite_rerun
  assert_eq "$RUN_EXIT_CODE" "1" "overwrite dispatch with missing body id should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED" "overwrite dispatch missing body id emits ACTION_REQUIRED"
  assert_request_logged "GET http://127.0.0.1:3099/migration/algolia/jobs/job-123" "overwrite dispatch polls the header-named job before cleanup"
  assert_contains "$(cat "$WORK_DIR/psql.log")" "id = 'job-123'" "overwrite dispatch waits for header-named job ACK before cleanup"
}

test_stage2_identical_replay_location_only_accepted_job_is_awaited() {
  setup_workspace
  CURL_SCENARIO=idempotency_replay_missing_body_id PSQL_SCENARIO=delayed_ack PROBE_POLL_SECONDS=4 run_probe --phases idempotency
  assert_eq "$RUN_EXIT_CODE" "1" "identical replay with missing body id should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED" "identical replay missing body id emits ACTION_REQUIRED"
  assert_request_logged "GET http://127.0.0.1:3099/migration/algolia/jobs/job-123" "identical replay polls the header-named job before cleanup"
  assert_contains "$(cat "$WORK_DIR/psql.log")" "id = 'job-123'" "identical replay waits for header-named job ACK before cleanup"
}

assert_unrecoverable_acceptance_preserves_resources() {
  local phase="$1" target="$2" expected_indexes="$3"
  assert_eq "$RUN_EXIT_CODE" "1" "$phase unrecoverable accepted response should fail closed"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=invalid_response_identifier" "$phase unrecoverable accepted response reports its invalid identifier"
  assert_not_contains "$(cat "$WORK_DIR/curl.log")" "DELETE https://testapp123.algolia.net/1/indexes/" "$phase preserves every Algolia source index"
  assert_not_contains "$(cat "$WORK_DIR/curl.log")" "DELETE https://testapp123.algolia.net/1/keys/disposable-restricted-key" "$phase preserves its restricted key"
  assert_not_contains "$(cat "$WORK_DIR/curl.log")" "DELETE http://127.0.0.1:3099/indexes/$target" "$phase preserves its Flapjack target"
  assert_contains "$RUN_STDOUT" "CLEANUP|algolia_indexes=${expected_indexes}|flapjack_indexes=1|algolia_keys=1|local_stack=1|runtime_files=1" "$phase reports every preserved remote and local resource as residue"
  assert_eq "$(cat "$WORK_DIR/down.log")" "" "$phase does not tear down the integration stack or database"
}

test_stage2_unrecoverable_accepted_jobs_preserve_all_resources() {
  setup_workspace
  CURL_SCENARIO=overwrite_dispatch_unrecoverable_accepted run_probe --phases overwrite_rerun
  assert_unrecoverable_acceptance_preserves_resources \
    "overwrite_rerun" "fjcloud_migration_parity_probe_test_ow_target" "1"

  setup_workspace
  CURL_SCENARIO=idempotency_replay_unrecoverable_accepted run_probe --phases idempotency
  assert_unrecoverable_acceptance_preserves_resources \
    "idempotency" "fjcloud_migration_parity_probe_test_id_target" "2"
}

test_stage2_idempotency_final_poll_timeout_drains_accepted_job() {
  setup_workspace
  CURL_SCENARIO=running_job run_probe --phases idempotency
  assert_eq "$RUN_EXIT_CODE" "1" "idempotency final-poll timeout should fail closed"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=inconclusive_evidence" "final-poll timeout emits inconclusive evidence"
  assert_request_count_at_least "GET http://127.0.0.1:3099/migration/algolia/jobs/job-123" "2" "final-poll timeout routes through the accepted-job drain instead of racing cleanup"
}

test_stage2_drain_exhaustion_preserves_live_job_resources() {
  # A tracked job that never reaches terminal success (permanently running) must
  # leave its two seeded source indexes, restricted key, target, AND local stack
  # (processes + database) intact — deleting or killing them would race the live
  # worker. The verdict is ACTION_REQUIRED with every preserved resource reported
  # as residue, no remote DELETE may be issued, and integration-down must not run.
  setup_workspace
  CURL_SCENARIO=running_job run_probe --phases idempotency
  assert_eq "$RUN_EXIT_CODE" "1" "permanently running job should fail closed"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED" "permanently running job emits ACTION_REQUIRED"
  assert_not_contains "$(cat "$WORK_DIR/curl.log")" "DELETE https://testapp123.algolia.net/1/indexes/" "live job source index is not deleted"
  assert_not_contains "$(cat "$WORK_DIR/curl.log")" "DELETE https://testapp123.algolia.net/1/keys/disposable-restricted-key" "live job restricted key is not deleted"
  assert_not_contains "$(cat "$WORK_DIR/curl.log")" "DELETE http://127.0.0.1:3099/indexes/fjcloud_migration_parity_probe_test_id_target" "live job target is not deleted"
  assert_contains "$RUN_STDOUT" "CLEANUP|algolia_indexes=2|flapjack_indexes=1|algolia_keys=1|local_stack=1|runtime_files=1" "preserved live-job source indexes, key, target, and local stack are all reported as residue"
  assert_eq "$(cat "$WORK_DIR/down.log")" "" "live-job preservation does not tear down the local integration stack or drop its database"
}

test_stage2_combined_requires_second_source_authorization() {
  setup_workspace
  CURL_SCENARIO=idempotency_second_source_unauthorized run_probe --phases overwrite_rerun,idempotency
  assert_eq "$RUN_EXIT_CODE" "1" "combined run should fail when the second idempotency source is not authorized"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=inconclusive_evidence" "unauthorized second source emits ACTION_REQUIRED"
  assert_not_contains "$(cat "$WORK_DIR/curl.log")" "sourceName\":\"fjcloud_migration_parity_probe_test_id_source_alt" "changed replay is not submitted before second-source authorization succeeds"
}

test_stage2_combined_cleanup_detects_phase_scoped_key_and_target_leaks() {
  setup_workspace
  CURL_SCENARIO=combined_cleanup_leaks_later_resources run_probe --phases overwrite_rerun,idempotency
  assert_eq "$RUN_EXIT_CODE" "1" "combined run should fail when only one phase-scoped key and target is cleaned up"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=residue_detected" "combined resource leak emits residue failure"
  assert_contains "$RUN_STDOUT" "CLEANUP|algolia_indexes=0|flapjack_indexes=1|algolia_keys=1|local_stack=0|runtime_files=0" "combined cleanup reports the leaked key and target independently"
}

assert_job_request_tuples() {
  # Assert the ordered sequence of correlated (Idempotency-Key, canonical body)
  # tuples logged by the fake /migration/algolia/jobs owner matches exactly.
  # args: msg, then one expected "key=<key> body=<canonical-json>" per request.
  local msg="$1"
  shift
  if python3 - "$WORK_DIR/curl.log" "$@" <<'PY'
import sys

log_path = sys.argv[1]
expected = sys.argv[2:]
prefix = "JOB_REQUEST "
with open(log_path, encoding="utf-8") as handle:
    actual = [
        line.rstrip("\n")[len(prefix):]
        for line in handle
        if line.startswith(prefix)
    ]
raise SystemExit(0 if actual == expected else 1)
PY
  then
    pass "$msg"
  else
    fail "$msg"
  fi
}

test_stage2_job_requests_are_exact_ordered_tuples() {
  local key="fjcloud_migration_parity_probe_test_idempotency_create"
  local create_body='{"apiKey":"disposable-restricted-key","appId":"TESTAPP123","mode":"create","sourceName":"fjcloud_migration_parity_probe_test_id_source","target":{"eligibilityToken":"target.token"}}'
  local changed_body='{"apiKey":"disposable-restricted-key","appId":"TESTAPP123","mode":"create","sourceName":"fjcloud_migration_parity_probe_test_id_source_alt","target":{"eligibilityToken":"target.token"}}'
  setup_workspace
  run_probe --phases idempotency
  assert_eq "$RUN_EXIT_CODE" "0" "idempotency success lane should pass"
  assert_job_request_tuples "idempotency emits exact ordered (key,body) tuples: identical replay then changed body" \
    "key=$key body=$create_body" \
    "key=$key body=$create_body" \
    "key=$key body=$changed_body"

  local ow_create='{"apiKey":"disposable-restricted-key","appId":"TESTAPP123","mode":"create","sourceName":"fjcloud_migration_parity_probe_test_ow_source","target":{"eligibilityToken":"target.token"}}'
  local ow_replace='{"apiKey":"disposable-restricted-key","appId":"TESTAPP123","mode":"replace","sourceName":"fjcloud_migration_parity_probe_test_ow_source","target":{"eligibilityToken":"target.token"}}'
  setup_workspace
  run_probe --phases overwrite_rerun
  assert_eq "$RUN_EXIT_CODE" "0" "overwrite_rerun success lane should pass"
  assert_job_request_tuples "overwrite_rerun emits exact ordered (key,body) tuples: create then two keyed replaces" \
    "key=fjcloud_migration_parity_probe_test_overwrite_create body=$ow_create" \
    "key=fjcloud_migration_parity_probe_test_overwrite_replace_same body=$ow_replace" \
    "key=fjcloud_migration_parity_probe_test_overwrite_replace_mutated body=$ow_replace"
}

test_stage2_success_lane_is_request_sensitive() {
  setup_workspace
  run_probe --phases idempotency
  assert_eq "$RUN_EXIT_CODE" "0" "idempotency success lane should pass"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "IDEMPOTENCY_KEY fjcloud_migration_parity_probe_test_idempotency_create" "idempotency create/replay send the stable Stage 2 idempotency key"

  setup_workspace
  run_probe --phases overwrite_rerun
  assert_eq "$RUN_EXIT_CODE" "0" "overwrite_rerun success lane should pass"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "JOB_BODY mode=create" "overwrite_rerun dispatches an initial create job"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "JOB_BODY mode=replace" "overwrite_rerun dispatches the required replace jobs"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "IDEMPOTENCY_KEY fjcloud_migration_parity_probe_test_overwrite_replace_same" "overwrite_rerun replays the same-source replace under its own idempotency key"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "IDEMPOTENCY_KEY fjcloud_migration_parity_probe_test_overwrite_replace_mutated" "overwrite_rerun mutates under a fresh idempotency key"
}

test_cleanup_waits_for_engine_ack_release() {
  setup_workspace
  PSQL_SCENARIO=delayed_ack PROBE_POLL_SECONDS=4 run_probe --phases create_into_fresh
  assert_eq "$RUN_EXIT_CODE" "0" "probe should wait for delayed engine ACK before cleanup"
  assert_contains "$(cat "$WORK_DIR/sleep.log")" "sleep 2" "delayed engine ACK triggers bounded wait"
  assert_contains "$RUN_STDOUT" "CLEANUP|algolia_indexes=0|flapjack_indexes=0|algolia_keys=0|local_stack=0|runtime_files=0" "cleanup runs after delayed ACK"

  setup_workspace
  PSQL_SCENARIO=ack_missing PROBE_POLL_SECONDS=0 run_probe --phases create_into_fresh
  assert_eq "$RUN_EXIT_CODE" "1" "missing engine ACK should fail closed"
  assert_contains "$RUN_STDOUT" "EVIDENCE|engine_ack=missing|job_state=ack=outbox_pending" "missing ACK emits reconciliation state evidence"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=inconclusive_evidence" "missing ACK emits inconclusive evidence"
}

test_mid_run_failures_still_attempt_source_and_target_cleanup() {
  setup_workspace
  CURL_SCENARIO=parity_mismatch run_probe --phases create_into_fresh
  assert_eq "$RUN_EXIT_CODE" "1" "parity mismatch should fail"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "DELETE https://testapp123.algolia.net/1/indexes/" "source index cleanup is attempted on failure"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "DELETE https://testapp123.algolia.net/1/keys/disposable-restricted-key" "source key cleanup is attempted on failure"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "DELETE http://127.0.0.1:3099/indexes/fjcloud_migration_parity_probe_test_target" "flapjack target cleanup is attempted on failure"

  setup_workspace
  CURL_SCENARIO=parity_mismatch_ack_guarded_delete PSQL_SCENARIO=delayed_ack PROBE_POLL_SECONDS=4 run_probe --phases create_into_fresh
  assert_eq "$RUN_EXIT_CODE" "1" "parity mismatch remains fail closed after cleanup waits for ACK"
  assert_contains "$(cat "$WORK_DIR/psql.log")" "probe:engine_ack" "parity failure cleanup waits for durable engine ACK"
  assert_contains "$RUN_STDOUT" "CLEANUP|algolia_indexes=0|flapjack_indexes=0|algolia_keys=0|local_stack=0|runtime_files=0" "parity failure cleanup releases target after ACK"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=parity_mismatch" "cleanup does not hide parity mismatch"
}

test_cleanup_waits_for_transient_residue_clearance() {
  setup_workspace
  CURL_SCENARIO=delayed_cleanup run_probe --phases create_into_fresh
  assert_eq "$RUN_EXIT_CODE" "0" "transient cleanup residue should clear before final verdict"
  assert_contains "$RUN_STDOUT" "CLEANUP|algolia_indexes=0|flapjack_indexes=0|algolia_keys=0|local_stack=0|runtime_files=0" "delayed cleanup reports all residues clear"
  assert_contains "$(cat "$WORK_DIR/sleep.log")" "sleep 1" "transient cleanup residue triggers a bounded wait"
}

test_cleanup_retries_transient_target_delete_failure() {
  setup_workspace
  CURL_SCENARIO=target_delete_retry run_probe --phases create_into_fresh
  assert_eq "$RUN_EXIT_CODE" "0" "transient target delete failure should be retried during cleanup"
  assert_contains "$RUN_STDOUT" "CLEANUP|algolia_indexes=0|flapjack_indexes=0|algolia_keys=0|local_stack=0|runtime_files=0" "retried target delete reports all residues clear"
}

test_cleanup_waits_for_reconciliation_delete_conflicts() {
  setup_workspace
  CURL_SCENARIO=target_delete_reconciliation_wait run_probe --phases create_into_fresh
  assert_eq "$RUN_EXIT_CODE" "0" "reconciliation-window target delete conflicts should clear before final verdict"
  assert_contains "$RUN_STDOUT" "CLEANUP|algolia_indexes=0|flapjack_indexes=0|algolia_keys=0|local_stack=0|runtime_files=0" "reconciliation-window cleanup reports all residues clear"
  assert_contains "$(cat "$WORK_DIR/sleep.log")" "sleep 1" "reconciliation-window delete conflicts trigger bounded waits"
}

test_cleanup_diagnostic_reports_persistent_target_delete_conflict_body() {
  setup_workspace
  CURL_SCENARIO=target_delete_conflict_persistent run_probe --phases create_into_fresh
  assert_eq "$RUN_EXIT_CODE" "1" "persistent target delete conflicts should fail closed"
  assert_contains "$RUN_STDOUT" "CLEANUP_DIAGNOSTIC|flapjack_delete_statuses=409" "persistent target delete conflict emits cleanup diagnostic"
  assert_contains "$RUN_STDOUT" "flapjack_delete_bodies=error:destination_conflict" "persistent target delete conflict body is summarized"
}

test_rejects_cleanup_residue() {
  setup_workspace
  ALGOLIA_RESIDUE=1 run_probe --phases create_into_fresh
  assert_eq "$RUN_EXIT_CODE" "1" "source Algolia residue should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=residue_detected" "Algolia residue emits ACTION_REQUIRED"

  setup_workspace
  FAKE_ALGOLIA_KEY_RESIDUE=1 run_probe --phases create_into_fresh
  assert_eq "$RUN_EXIT_CODE" "1" "Algolia key residue should fail"
  assert_contains "$RUN_STDOUT" "CLEANUP|algolia_indexes=0|flapjack_indexes=0|algolia_keys=1" "key residue is reported"
}

test_stage3_cancel_partial_publishes_nothing_and_reaches_cancelled_terminal() {
  setup_workspace
  run_probe --phases cancel_partial
  assert_eq "$RUN_EXIT_CODE" "0" "cancel_partial should pass"
  assert_request_order "REQUEST GET http://127.0.0.1:3099/migration/algolia/jobs/job-cp" "REQUEST POST http://127.0.0.1:3099/migration/algolia/jobs/job-cp/cancel" "cancel is requested only after observing a nonterminal status"
  assert_request_count_at_least "POST http://127.0.0.1:3099/migration/algolia/jobs/job-cp/cancel" "2" "cancel is posted twice through the shared route helper"
  assert_contains "$RUN_STDOUT" "PHASE|name=cancel_partial_replay|expected=first_202_replay_200_same_job_stable_intent|observed=first_202_replay_200_same_job_stable_intent|pass=true" "cancel emits 202 then 200 for the same job with stable intent"
  assert_contains "$RUN_STDOUT" "PHASE|name=cancel_partial_intent|expected=linked_job=1,cancel_intent=1|observed=linked_job=1,cancel_intent=1|pass=true" "cancel emits single durable intent and single engine-linked job"
  assert_contains "$RUN_STDOUT" "PHASE|name=cancel_partial|expected=cancelled_unchanged,resumable=false,customer_visible=0|observed=cancelled_unchanged,resumable=false,customer_visible=0|pass=true" "cancel reaches cancelled+unchanged with zero customer-visible documents"
  assert_contains "$(cat "$WORK_DIR/psql.log")" "probe:engine_ack" "cancel_partial waits for durable engine ACK"
  assert_contains "$RUN_STDOUT" "RESULT|status=PASS|phases=cancel_partial" "cancel_partial emits PASS"
  assert_contains "$RUN_STDOUT" "CLEANUP|algolia_indexes=0|flapjack_indexes=0|algolia_keys=0|local_stack=0|runtime_files=0" "cancel_partial cleans up all resources"
}

test_stage3_cancel_partial_failures_are_action_required() {
  # Cancel requested against an already-terminal job must fail closed.
  setup_workspace
  CURL_SCENARIO=cancel_partial_already_terminal run_probe --phases cancel_partial
  assert_eq "$RUN_EXIT_CODE" "1" "cancel against an already-terminal job should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=inconclusive_evidence" "already-terminal cancel emits inconclusive evidence"
  assert_not_contains "$(cat "$WORK_DIR/curl.log")" "REQUEST POST http://127.0.0.1:3099/migration/algolia/jobs/job-cp/cancel" "cancel is not posted once the job is already terminal"

  # A cancel replay that is not exactly 200 must fail.
  setup_workspace
  CURL_SCENARIO=cancel_partial_replay_not_ok run_probe --phases cancel_partial
  assert_eq "$RUN_EXIT_CODE" "1" "cancel replay that is not 200 should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED" "non-200 cancel replay emits ACTION_REQUIRED"
  assert_contains "$(cat "$WORK_DIR/psql.log")" "probe:engine_ack" "non-200 cancel replay drains the already-cancelled job through ACK"
  assert_contains "$RUN_STDOUT" "CLEANUP|algolia_indexes=0|flapjack_indexes=0|algolia_keys=0|local_stack=0|runtime_files=0" "non-200 cancel replay cleanup releases cancelled-job resources"

  # A changing cancelRequestedAt across replays must fail.
  setup_workspace
  CURL_SCENARIO=cancel_partial_cancel_at_changes run_probe --phases cancel_partial
  assert_eq "$RUN_EXIT_CODE" "1" "changing cancelRequestedAt should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED" "changing cancelRequestedAt emits ACTION_REQUIRED"

  # A terminal that is promoted (not cancelled+unchanged) must fail.
  setup_workspace
  CURL_SCENARIO=cancel_partial_terminal_promoted run_probe --phases cancel_partial
  assert_eq "$RUN_EXIT_CODE" "1" "promoted terminal after cancel should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=inconclusive_evidence" "promoted terminal emits inconclusive evidence"

  # Any customer-visible document after a cancel must fail.
  setup_workspace
  CURL_SCENARIO=cancel_partial_customer_visible run_probe --phases cancel_partial
  assert_eq "$RUN_EXIT_CODE" "1" "customer-visible documents after cancel should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=parity_mismatch" "customer-visible documents emit parity_mismatch"

  # Failed or malformed target browse must report from the parent shell, not
  # disappear inside the customer-count command substitution.
  for scenario in cancel_partial_browse_request_failed cancel_partial_browse_malformed; do
    setup_workspace
    CURL_SCENARIO="$scenario" run_probe --phases cancel_partial
    assert_eq "$RUN_EXIT_CODE" "1" "$scenario should fail"
    assert_contains "$RUN_STDOUT" "ERROR|reason=inconclusive_evidence|step=customer_visible_browse" "$scenario emits the customer-visible browse error"
    assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=inconclusive_evidence" "$scenario emits ACTION_REQUIRED"
    assert_contains "$RUN_STDOUT" "CLEANUP|algolia_indexes=0|flapjack_indexes=0|algolia_keys=0|local_stack=0|runtime_files=0" "$scenario emits cleanup evidence"
  done

  # A missing durable cancel intent must fail.
  setup_workspace
  PSQL_SCENARIO=cancel_intent_wrong run_probe --phases cancel_partial
  assert_eq "$RUN_EXIT_CODE" "1" "missing durable cancel intent should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=inconclusive_evidence" "missing cancel intent emits inconclusive evidence"

  # More than one phase-scoped engine-linked job must fail.
  setup_workspace
  PSQL_SCENARIO=cancel_engine_link_wrong run_probe --phases cancel_partial
  assert_eq "$RUN_EXIT_CODE" "1" "wrong engine-linked job count should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=inconclusive_evidence" "wrong engine-link count emits inconclusive evidence"
}

test_stage3_resume_refused_stays_fail_closed() {
  setup_workspace
  run_probe --phases resume_refused
  assert_eq "$RUN_EXIT_CODE" "0" "resume_refused should pass"
  assert_contains "$RUN_STDOUT" "PHASE|name=resume_refused_availability|expected=available=true,cancel=true,replace=true,resume=false|observed=available=true,cancel=true,replace=true,resume=false|pass=true" "resume_refused asserts the exact enabled availability payload"
  assert_contains "$RUN_STDOUT" "PHASE|name=resume_refused|expected=409_not_resumable,resumable=false,generation_unchanged,job_count=1|observed=409_not_resumable,resumable=false,generation_unchanged,job_count=1|pass=true" "resume_refused proves 409/not_resumable with no lifecycle mutation"
  assert_request_logged "POST http://127.0.0.1:3099/migration/algolia/jobs/job-rr/resume" "resume is posted to the retained job"
  assert_contains "$RUN_STDOUT" "RESULT|status=PASS|phases=resume_refused" "resume_refused emits PASS"
  assert_contains "$RUN_STDOUT" "CLEANUP|algolia_indexes=0|flapjack_indexes=0|algolia_keys=0|local_stack=0|runtime_files=0" "resume_refused cleans up all resources"
}

test_stage3_resume_refused_failures_are_action_required() {
  # A completed specimen advertised resumable=true must fail.
  setup_workspace
  CURL_SCENARIO=resume_refused_resumable_true run_probe --phases resume_refused
  assert_eq "$RUN_EXIT_CODE" "1" "resumable=true specimen should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=inconclusive_evidence" "resumable specimen emits inconclusive evidence"

  # A resume that is accepted (not 409/not_resumable) must fail.
  setup_workspace
  CURL_SCENARIO=resume_refused_resume_accepted run_probe --phases resume_refused
  assert_eq "$RUN_EXIT_CODE" "1" "accepted resume should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=inconclusive_evidence" "accepted resume emits inconclusive evidence"

  # Enabled availability that advertises replace=false must fail the exact tuple.
  setup_workspace
  CURL_SCENARIO=overwrite_replace_unavailable run_probe --phases resume_refused
  assert_eq "$RUN_EXIT_CODE" "1" "availability without replace should fail the exact tuple"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=w1_availability_unavailable" "inexact availability emits ACTION_REQUIRED"

  # A mutated lifecycle generation after a refused resume must fail.
  setup_workspace
  PSQL_SCENARIO=resume_generation_mutated run_probe --phases resume_refused
  assert_eq "$RUN_EXIT_CODE" "1" "mutated lifecycle generation should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=inconclusive_evidence" "mutated generation emits inconclusive evidence"

  # A changed non-null checkpoint value after a refused resume must fail even
  # when nullness stays unchanged.
  setup_workspace
  PSQL_SCENARIO=resume_checkpoint_mutated run_probe --phases resume_refused
  assert_eq "$RUN_EXIT_CODE" "1" "mutated non-null resume checkpoint should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=inconclusive_evidence" "mutated checkpoint emits inconclusive evidence"

  # A forked phase-scoped job row after a refused resume must fail.
  setup_workspace
  PSQL_SCENARIO=resume_job_count_wrong run_probe --phases resume_refused
  assert_eq "$RUN_EXIT_CODE" "1" "forked phase-scoped job should fail"
  assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=inconclusive_evidence" "forked job emits inconclusive evidence"
}

test_stage3_combined_phases_pass_and_are_self_contained() {
  setup_workspace
  run_probe --phases cancel_partial,resume_refused
  assert_eq "$RUN_EXIT_CODE" "0" "combined Stage 3 phases should pass"
  assert_contains "$RUN_STDOUT" "PHASE|name=cancel_partial|expected=cancelled_unchanged,resumable=false,customer_visible=0|observed=cancelled_unchanged,resumable=false,customer_visible=0|pass=true" "combined run reaches cancel terminal"
  assert_contains "$RUN_STDOUT" "PHASE|name=resume_refused|expected=409_not_resumable,resumable=false,generation_unchanged,job_count=1|observed=409_not_resumable,resumable=false,generation_unchanged,job_count=1|pass=true" "combined run refuses resume"
  assert_contains "$RUN_STDOUT" "RESULT|status=PASS|phases=cancel_partial,resume_refused" "combined phases emit PASS"
  assert_contains "$RUN_STDOUT" "CLEANUP|algolia_indexes=0|flapjack_indexes=0|algolia_keys=0|local_stack=0|runtime_files=0" "combined phases clean up all resources"
}

test_rejects_unknown_empty_and_missing_credentials_before_algolia
test_exported_credentials_supply_missing_secret_file_values
test_secret_file_credentials_override_conflicting_ambient_values
test_static_and_runtime_availability_stop_before_fixture_creation
test_terminal_failures_and_parity_mismatch_are_action_required
test_success_emits_parity_phase_and_full_cleanup
test_stage2_phases_are_accepted_and_emit_success_markers
test_stage2_overwrite_failures_are_action_required
test_stage2_overwrite_requires_replace_capability
test_stage2_overwrite_replace_eligibility_provider_unsupported_fails_closed
test_stage2_location_only_accepted_replay_is_awaited
test_stage2_idempotency_failures_are_action_required
test_stage2_overwrite_phase_set_preflights_replace_capability
test_stage2_overwrite_dispatch_location_only_accepted_job_is_awaited
test_stage2_identical_replay_location_only_accepted_job_is_awaited
test_stage2_unrecoverable_accepted_jobs_preserve_all_resources
test_stage2_idempotency_final_poll_timeout_drains_accepted_job
test_stage2_drain_exhaustion_preserves_live_job_resources
test_stage2_combined_requires_second_source_authorization
test_stage2_combined_cleanup_detects_phase_scoped_key_and_target_leaks
test_stage2_job_requests_are_exact_ordered_tuples
test_stage2_success_lane_is_request_sensitive
test_cleanup_waits_for_engine_ack_release
test_mid_run_failures_still_attempt_source_and_target_cleanup
test_cleanup_waits_for_transient_residue_clearance
test_cleanup_retries_transient_target_delete_failure
test_cleanup_waits_for_reconciliation_delete_conflicts
test_cleanup_diagnostic_reports_persistent_target_delete_conflict_body
test_rejects_cleanup_residue
test_stage3_cancel_partial_publishes_nothing_and_reaches_cancelled_terminal
test_stage3_cancel_partial_failures_are_action_required
test_stage3_resume_refused_stays_fail_closed
test_stage3_resume_refused_failures_are_action_required
test_stage3_combined_phases_pass_and_are_self_contained

run_test_summary
