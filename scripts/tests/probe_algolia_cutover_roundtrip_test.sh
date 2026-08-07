#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/probe_algolia_cutover_roundtrip.sh"

# shellcheck source=scripts/tests/lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=scripts/tests/lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

WORK_DIR=""
RUN_STDOUT=""
RUN_EXIT_CODE=0
SYSTEM_PYTHON3="$(command -v python3)"

# The Stage 2 deletion-proof rule, applied to a finished bundle rather than to a
# running probe. Prints "ok" only when the bundle records a passing run whose own
# follow-up inventory is readable and does not contain the source index it names.
# Every other outcome prints the reason it is not proof, so an indeterminate or
# aborted bundle can never read as a clean cutover.
cutover_bundle_proof_status() {
    python3 - "$1" <<'PY'
import json
import re
import sys
from pathlib import Path

bundle = Path(sys.argv[1])
summary = bundle / "SUMMARY.md"
if not summary.is_file():
    print("summary_missing")
    raise SystemExit(0)

fields = dict(re.findall(r"^- ([a-z_]+): (.*)$", summary.read_text(encoding="utf-8"), re.M))
if fields.get("verdict") != "pass":
    print("verdict_not_pass")
elif fields.get("deletion_proof_exact_source_absent") != "true":
    print("deletion_proof_not_true")
else:
    source_index = fields.get("source_index", "")
    if not source_index:
        print("source_index_missing")
        raise SystemExit(0)
    try:
        payload = json.loads((bundle / "list_indexes_after_cleanup.json").read_text(encoding="utf-8"))
        if payload.get("parse_error") is True:
            raise ValueError("inventory parse-error sentinel is set")
        items = payload["items"]
        if not isinstance(items, list):
            raise ValueError("items is not a list")
    except (OSError, KeyError, ValueError):
        print("inventory_unparsed")
    else:
        present = any(isinstance(item, dict) and item.get("name") == source_index for item in items)
        print("source_index_present_in_inventory" if present else "ok")
PY
}

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
    mkdir -p "$WORK_DIR/bin" "$WORK_DIR/runtime" "$WORK_DIR/evidence"
    : > "$WORK_DIR/curl.log"
    : > "$WORK_DIR/sleep.log"
    : > "$WORK_DIR/up.log"
    : > "$WORK_DIR/down.log"
    : > "$WORK_DIR/psql.log"

    write_fake_command "$WORK_DIR/up.sh" '#!/usr/bin/env bash
set -euo pipefail
printf "db=%s db_url=%s engine_version=%s override=%s pid_dir=%s enabled=%s\n" "${INTEGRATION_DB:-}" "${INTEGRATION_DB_URL:-}" "${FJCLOUD_FLAPJACK_VERSION:-}" "${FJCLOUD_FLAPJACK_VERSION_OVERRIDE:-}" "${FJCLOUD_INTEGRATION_PID_DIR:-}" "${FJCLOUD_ALGOLIA_MIGRATION_ENABLED:-}" >> "$UP_LOG"
mkdir -p "$FJCLOUD_INTEGRATION_PID_DIR"
'

    write_fake_command "$WORK_DIR/down.sh" '#!/usr/bin/env bash
set -euo pipefail
printf "db=%s pid_dir=%s\n" "${INTEGRATION_DB:-}" "${FJCLOUD_INTEGRATION_PID_DIR:-}" >> "$DOWN_LOG"
rmdir "$FJCLOUD_INTEGRATION_PID_DIR" 2>/dev/null || true
'

    write_fake_command "$WORK_DIR/bin/sleep" '#!/usr/bin/env bash
printf "sleep %s\n" "${1:-}" >> "$SLEEP_LOG"
'

    write_fake_command "$WORK_DIR/bin/rm" '#!/usr/bin/env bash
if [ "${CURL_SCENARIO:-success}" = "local_runtime_residue" ] && [ "${1:-}" = "-rf" ] && [[ "${2:-}" == *"fjcloud-cutover-roundtrip."* ]]; then
  exit 1
fi
exec /bin/rm "$@"
'

    write_fake_command "$WORK_DIR/bin/psql" '#!/usr/bin/env bash
printf "%s\n" "$*" >> "$PSQL_LOG"
if [[ "$*" == *"probe:cutover_engine_ack"* ]]; then
  printf "1\n"
  exit 0
fi
printf "0\n"
'

    write_fake_command "$WORK_DIR/flapjack" '#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "build-info" ] && [ "${2:-}" = "--json" ]; then
  printf "%s\n" "{\"build\":{\"version\":\"1.0.11\",\"revision\":\"test-revision\",\"workspaceDigest\":\"test-build\",\"dirty\":false}}"
  exit 0
fi
printf "%s\n" "{\"status\":\"ok\"}"
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
    -D) header_dump_file="$2"; shift 2 ;;
    --config|-K) shift 2 ;;
    -s|-S|-sS|--fail|--show-error) shift ;;
    --connect-timeout|--max-time|-H) shift 2 ;;
    -w) shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf "REQUEST %s %s\n" "$method" "$url" >> "$CURL_LOG"
case "${CURL_SCENARIO:-success}" in
  network_error)
    if [[ "$url" == *"algolia.net"* ]]; then
      printf "curl: simulated connect failure\n" >&2
      exit 7
    fi
    ;;
esac

probe_index="fjcloud-cutover-probe-test-123"
destination_index="fjcloud-cutover-destination-test-123"
expected_match="{\"sourceIndex\":\"$probe_index\",\"destinationIndex\":\"$destination_index\",\"resultLimit\":3,\"queries\":[{\"query\":\"uniquealpha\",\"overlapCount\":1,\"sourceOnly\":[],\"destinationOnly\":[],\"hits\":[{\"objectID\":\"doc-alpha\",\"sourceRank\":1,\"destinationRank\":1,\"rankDelta\":0}]},{\"query\":\"uniqueshared\",\"overlapCount\":1,\"sourceOnly\":[],\"destinationOnly\":[],\"hits\":[{\"objectID\":\"doc-shared\",\"sourceRank\":1,\"destinationRank\":1,\"rankDelta\":0}]}]}"
mutation_report="{\"sourceIndex\":\"$probe_index\",\"destinationIndex\":\"$destination_index\",\"resultLimit\":3,\"queries\":[{\"query\":\"uniquealpha\",\"overlapCount\":0,\"sourceOnly\":[\"doc-mutated\"],\"destinationOnly\":[\"doc-alpha\"],\"hits\":[]},{\"query\":\"uniqueshared\",\"overlapCount\":1,\"sourceOnly\":[],\"destinationOnly\":[],\"hits\":[{\"objectID\":\"doc-shared\",\"sourceRank\":1,\"destinationRank\":1,\"rankDelta\":0}]}]}"

case "$method $url" in
  "GET http://127.0.0.1:3099/health"|"GET http://127.0.0.1:7799/health")
    printf "{\"status\":\"ok\"}\n200" ;;
  "POST http://127.0.0.1:3099/auth/register")
    printf "{}\n201" ;;
  "POST http://127.0.0.1:3099/auth/login")
    printf "{\"token\":\"tenant-token\"}\n200" ;;
  "GET http://127.0.0.1:3099/migration/algolia/availability")
    if [ "${CURL_SCENARIO:-success}" = "early_unexpected_status" ]; then
      printf "{\"error\":\"unavailable\"}\n500"
    else
      printf "{\"available\":true,\"capabilities\":{\"verify\":true,\"cancel\":true,\"replace\":true,\"resume\":false}}\n200"
    fi ;;
  "POST http://127.0.0.1:3099/indexes")
    printf "{\"name\":\"fjcloud-cutover-warmup-test-123\"}\n201" ;;
  "DELETE http://127.0.0.1:3099/indexes/fjcloud-cutover-warmup-test-123")
    if [ "${CURL_SCENARIO:-success}" = "warmup_delete_500" ]; then
      printf "{\"error\":\"delete_failed\"}\n500"
    else
      printf "\n204"
    fi ;;
  "POST http://127.0.0.1:3099/migration/algolia/destination-eligibility")
    printf "{\"eligibilityToken\":\"target-token\"}\n200" ;;
  "POST http://127.0.0.1:3099/migration/algolia/jobs")
    [ -n "$header_dump_file" ] && printf "Location: /migration/algolia/jobs/job-123\r\n" > "$header_dump_file"
    printf "{\"id\":\"job-123\",\"status\":\"queued\",\"publicationDisposition\":\"not_started\",\"resumable\":false}\n202" ;;
  "GET http://127.0.0.1:3099/migration/algolia/jobs/job-123")
    if [ "${CURL_SCENARIO:-success}" = "terminal_failed_job" ]; then
      printf "{\"id\":\"job-123\",\"status\":\"failed\",\"publicationDisposition\":\"unchanged\",\"resumable\":false}\n200"
    else
      printf "{\"id\":\"job-123\",\"status\":\"completed\",\"publicationDisposition\":\"promoted\",\"resumable\":false}\n200"
    fi ;;
  "POST http://127.0.0.1:3099/migration/algolia/verify")
    if [ "${CURL_SCENARIO:-success}" = "bad_json" ]; then
      printf "{not-json}\n200"
    elif [ "${CURL_SCENARIO:-success}" = "unexpected_status" ]; then
      printf "{\"error\":\"boom\"}\n500"
    elif [ "${CURL_SCENARIO:-success}" = "parity_mismatch" ]; then
      printf "%s\n200" "$mutation_report"
    elif [ -f "$WORK_DIR/source-mutated" ]; then
      printf "%s\n200" "$mutation_report"
    else
      printf "%s\n200" "$expected_match"
    fi ;;
  "GET https://testapp123.algolia.net/1/indexes/$probe_index")
    if [ -f "$WORK_DIR/source-seeded" ]; then
      printf "{\"name\":\"%s\"}\n200" "$probe_index"
    else
      printf "{\"name\":\"%s\"}\n404" "$probe_index"
    fi ;;
  "POST https://testapp123.algolia.net/1/indexes/$probe_index/batch")
    touch "$WORK_DIR/source-seeded"
    [ -n "$data_file" ] && printf "BATCH %s\n" "$(cat "$data_file")" >> "$CURL_LOG"
    if [ -n "$data_file" ] && grep -q "\"objectID\":\"doc-alpha\",\"title\"" "$data_file"; then
      rm -f "$WORK_DIR/source-mutated"
    elif [ -n "$data_file" ] && grep -q "\"objectID\":\"doc-mutated\",\"title\"" "$data_file"; then
      touch "$WORK_DIR/source-mutated"
    fi
    printf "{\"taskID\":111}\n200" ;;
  "GET https://testapp123.algolia.net/1/indexes/$probe_index/task/111")
    printf "{\"status\":\"published\"}\n200" ;;
  "POST https://testapp123.algolia.net/1/keys")
    printf "{\"key\":\"restricted-key\"}\n201" ;;
  "GET https://testapp123.algolia.net/1/indexes")
    printf "{\"items\":[{\"name\":\"other-index\"}]}\n200" ;;
  "GET https://testapp123.algolia.net/1/indexes?page=0&hitsPerPage=100")
    if [ "${CURL_SCENARIO:-success}" = "cleanup_residue" ]; then
      printf "{\"items\":[{\"name\":\"%s\"}]}\n200" "$probe_index"
    elif [ "${CURL_SCENARIO:-success}" = "cleanup_list_bad_json" ]; then
      printf "{not-json}\n200"
    elif [ "${CURL_SCENARIO:-success}" = "cleanup_list_paginated_residue" ]; then
      printf "{\"items\":[{\"name\":\"other-index\"}],\"page\":0,\"nbPages\":2}\n200"
    else
      printf "{\"items\":[{\"name\":\"other-index\"}]}\n200"
    fi ;;
  "GET https://testapp123.algolia.net/1/indexes?page=1&hitsPerPage=100")
    if [ "${CURL_SCENARIO:-success}" = "cleanup_list_paginated_residue" ]; then
      printf "{\"items\":[{\"name\":\"%s\"}],\"page\":1,\"nbPages\":2}\n200" "$probe_index"
    else
      printf "{\"items\":[],\"page\":1,\"nbPages\":2}\n200"
    fi ;;
  "GET https://testapp123.algolia.net/1/indexes/$probe_index/task/"*)
    printf "{\"status\":\"published\"}\n200" ;;
  "DELETE https://testapp123.algolia.net/1/indexes/$probe_index")
    printf "{\"taskID\":222}\n200" ;;
  "GET https://testapp123.algolia.net/1/indexes/$probe_index/task/222")
    printf "{\"status\":\"published\"}\n200" ;;
  "GET https://testapp123.algolia.net/1/keys/restricted-key")
    printf "{}\n404" ;;
  "DELETE https://testapp123.algolia.net/1/keys/restricted-key")
    printf "{}\n200" ;;
  "DELETE http://127.0.0.1:3099/indexes/$destination_index")
    if [ "${CURL_SCENARIO:-success}" = "destination_delete_500" ]; then
      printf "{\"error\":\"delete_failed\"}\n500"
    else
      printf "\n204"
    fi ;;
  "POST http://127.0.0.1:3099/indexes/$destination_index/browse")
    printf "{\"error\":\"not_found\"}\n404" ;;
  *)
    printf "{\"error\":\"unexpected\",\"method\":\"%s\",\"url\":\"%s\"}\n599" "$method" "$url" ;;
esac
'
}

run_probe() {
    set +e
    RUN_STDOUT="$(
        env \
            PATH="$WORK_DIR/bin:$PATH" \
            ALGOLIA_APP_ID="${ALGOLIA_APP_ID_VALUE:-TESTAPP123}" \
            ALGOLIA_ADMIN_KEY="${ALGOLIA_ADMIN_KEY_VALUE-algolia-admin-secret}" \
            ALGOLIA_CUTOVER_ROUNDTRIP_RUN_ID="test-123" \
            ALGOLIA_CUTOVER_ROUNDTRIP_RUNTIME_PARENT="$WORK_DIR/runtime" \
            ALGOLIA_CUTOVER_ROUNDTRIP_EVIDENCE_ROOT="$WORK_DIR/evidence" \
            ALGOLIA_CUTOVER_ROUNDTRIP_INTEGRATION_UP="$WORK_DIR/up.sh" \
            ALGOLIA_CUTOVER_ROUNDTRIP_INTEGRATION_DOWN="$WORK_DIR/down.sh" \
            ALGOLIA_CUTOVER_ROUNDTRIP_POLL_SECONDS=0 \
            INTEGRATION_DB_URL="${INTEGRATION_DB_URL_VALUE:-postgres://stale.example/stale_db}" \
            FJCLOUD_INTEGRATION_ENGINE_BINARY="$WORK_DIR/flapjack" \
            API_PORT=3099 \
            FLAPJACK_PORT=7799 \
            UP_LOG="$WORK_DIR/up.log" \
            DOWN_LOG="$WORK_DIR/down.log" \
            CURL_LOG="$WORK_DIR/curl.log" \
            SLEEP_LOG="$WORK_DIR/sleep.log" \
            PSQL_LOG="$WORK_DIR/psql.log" \
            WORK_DIR="$WORK_DIR" \
            SYSTEM_PYTHON3="$SYSTEM_PYTHON3" \
            CURL_SCENARIO="${CURL_SCENARIO:-success}" \
            bash "$TARGET_SCRIPT" 2>&1
    )"
    RUN_EXIT_CODE=$?
    set -e
}

assert_request_logged() {
    local request="$1" msg="$2"
    assert_contains "$(cat "$WORK_DIR/curl.log")" "REQUEST $request" "$msg"
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

test_missing_credentials_stop_before_vendor_call() {
    setup_workspace
    ALGOLIA_ADMIN_KEY_VALUE="" run_probe
    assert_eq "$RUN_EXIT_CODE" "1" "missing credentials should fail"
    assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=missing_credentials" "missing credentials are named"
    assert_not_contains "$(cat "$WORK_DIR/curl.log")" "algolia.net" "missing credentials stop before Algolia"
    assert_not_contains "$RUN_STDOUT" "algolia-admin-secret" "missing credential output redacts admin key"
}

test_network_and_response_classifications_are_distinct() {
    setup_workspace
    CURL_SCENARIO=network_error run_probe
    assert_eq "$RUN_EXIT_CODE" "1" "network error should fail"
    assert_contains "$RUN_STDOUT" "reason=network_failure" "network error is classified"

    setup_workspace
    CURL_SCENARIO=bad_json run_probe
    assert_eq "$RUN_EXIT_CODE" "1" "unparsed response should fail"
    assert_contains "$RUN_STDOUT" "reason=unparsed_response" "unparsed response is classified"

    setup_workspace
    CURL_SCENARIO=unexpected_status run_probe
    assert_eq "$RUN_EXIT_CODE" "1" "unexpected status should fail"
    assert_contains "$RUN_STDOUT" "reason=unexpected_status" "unexpected status is classified"
}

test_mismatched_verify_report_fails_closed() {
    setup_workspace
    CURL_SCENARIO=parity_mismatch run_probe
    assert_eq "$RUN_EXIT_CODE" "1" "mismatched verify report should fail"
    assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=parity_mismatch" "mismatched report is classified"
}

test_success_match_mutation_restore_and_cleanup_are_proven() {
    setup_workspace
    run_probe
    assert_eq "$RUN_EXIT_CODE" "0" "successful roundtrip should pass"
    assert_contains "$RUN_STDOUT" "PHASE|name=verify_match|pass=true" "success names match arm"
    assert_contains "$RUN_STDOUT" "PHASE|name=verify_mutation_mismatch|pass=true" "success names mutation mismatch arm"
    assert_contains "$RUN_STDOUT" "PHASE|name=verify_restored_match|pass=true" "success names restored arm"
    assert_contains "$RUN_STDOUT" "RESULT|status=PASS" "success emits PASS"
    assert_request_logged "POST https://testapp123.algolia.net/1/indexes/fjcloud-cutover-probe-test-123/batch" "Algolia seed/mutation uses batch endpoint"
    assert_request_logged "GET https://testapp123.algolia.net/1/indexes/fjcloud-cutover-probe-test-123/task/111" "Algolia task polling is used"
    assert_request_logged "DELETE https://testapp123.algolia.net/1/indexes/fjcloud-cutover-probe-test-123" "Algolia source cleanup is used"
    assert_request_logged "GET https://testapp123.algolia.net/1/indexes?page=0&hitsPerPage=100" "Algolia follow-up list-indexes proof is used"
    assert_request_logged "POST http://127.0.0.1:3099/indexes" "warmup creates a local index"
    assert_request_logged "DELETE http://127.0.0.1:3099/indexes/fjcloud-cutover-warmup-test-123" "warmup removes the local index"
    assert_request_order "REQUEST POST http://127.0.0.1:3099/indexes" "REQUEST POST http://127.0.0.1:3099/migration/algolia/destination-eligibility" "warmup runs before destination eligibility"
    assert_request_logged "POST http://127.0.0.1:3099/migration/algolia/jobs" "fjcloud migration job route is used"
    assert_request_logged "GET http://127.0.0.1:3099/migration/algolia/jobs/job-123" "fjcloud job polling route is used"
    assert_request_logged "POST http://127.0.0.1:3099/migration/algolia/verify" "fjcloud verify route is used"
    assert_contains "$(cat "$WORK_DIR/down.log")" "db=fjcloud_cutover_probe_test_123" "cleanup calls integration-down"
    assert_not_contains "$RUN_STDOUT" "algolia-admin-secret" "stdout redacts admin key"
    assert_not_contains "$(cat "$WORK_DIR/evidence"/*/SUMMARY.md)" "algolia-admin-secret" "evidence redacts admin key"
    assert_contains "$(cat "$WORK_DIR/evidence"/*/SUMMARY.md)" "- record_count: 3" "summary records seed fixture count after cleanup"
    assert_not_contains "$(cat "$WORK_DIR/evidence"/*/list_indexes_after_cleanup.json)" "other-index" "persisted list-indexes proof omits unrelated vendor inventory"
    assert_not_contains "$(cat "$WORK_DIR/evidence"/*/SUMMARY.md)" "other-index" "summary list-indexes proof omits unrelated vendor inventory"
}

test_runtime_ignores_stale_inherited_db_url() {
    setup_workspace
    run_probe
    assert_not_contains "$(cat "$WORK_DIR/up.log")" "stale_db" "integration-up does not inherit stale DB URL"
    assert_contains "$(cat "$WORK_DIR/up.log")" "fjcloud_cutover_probe_test_123" "integration-up receives run-scoped DB URL"
}

test_runtime_uses_canonical_engine_version() {
    setup_workspace
    run_probe
    # The probe used to hand integration-up the SELECTED BINARY'S OWN version
    # through an override seam, which made the runtime version check tautological
    # for this lane: it compared the engine against itself and could not fail.
    # That seam existed only to work around exact-version equality; the pin is now
    # a floor, so the probe's engine passes on its own merits and the bypass is
    # gone. integration-up must receive the canonical pin, and no override.
    assert_contains "$(cat "$WORK_DIR/up.log")" "override=" \
        "probe must not hand integration-up an engine-derived version override"
    assert_not_contains "$(cat "$WORK_DIR/up.log")" "override=1." \
        "no version value may be passed through the retired override seam"
}

test_integration_up_ignores_inherited_version_override() {
    setup_workspace
    local api_bin="$WORK_DIR/api-bin" flapjack_bin="$WORK_DIR/flapjack-bin" nohup_log="$WORK_DIR/nohup.log"
    write_fake_command "$api_bin" '#!/usr/bin/env bash
exit 0
'
    write_fake_command "$flapjack_bin" '#!/usr/bin/env bash
if [ "${1:-}" = "build-info" ] && [ "${2:-}" = "--json" ]; then
  printf "%s\n" "{\"build\":{\"version\":\"1.0.11\",\"revision\":\"test-revision\",\"workspaceDigest\":\"test-build\",\"dirty\":false}}"
fi
'
    write_fake_command "$WORK_DIR/bin/psql" '#!/usr/bin/env bash
if [[ "$*" == *"SELECT 1 FROM pg_database"* ]]; then
  printf "1\n"
fi
exit 0
'
    write_fake_command "$WORK_DIR/bin/lsof" '#!/usr/bin/env bash
exit 1
'
    write_fake_command "$WORK_DIR/bin/curl" '#!/usr/bin/env bash
exit 0
'
    write_fake_command "$WORK_DIR/bin/nohup" '#!/usr/bin/env bash
printf "command=%s version=%s\n" "${1:-}" "${FJCLOUD_FLAPJACK_VERSION:-}" >> "$NOHUP_LOG"
exit 0
'
    PATH="$WORK_DIR/bin:$PATH" NOHUP_LOG="$nohup_log" \
        FJCLOUD_INTEGRATION_PID_DIR="$WORK_DIR/pids" \
        FJCLOUD_INTEGRATION_API_BINARY="$api_bin" \
        FJCLOUD_INTEGRATION_ENGINE_BINARY="$flapjack_bin" \
        FJCLOUD_INTEGRATION_SKIP_METERING_AGENT=1 \
        INTEGRATION_DB="fjcloud_cutover_probe_integration_up" \
        INTEGRATION_DB_URL="postgres://localhost/fjcloud_cutover_probe_integration_up" \
        FJCLOUD_FLAPJACK_VERSION_OVERRIDE="1.0.99" \
        bash "$REPO_ROOT/scripts/integration-up.sh" >/dev/null
    # Regression guard against reintroducing the bypass. The retired override let
    # a caller lower the version the API enforced, which under floor semantics
    # means admitting an engine OLDER than the repository supports. An inherited
    # value must now be ignored outright, exactly as an inherited
    # FJCLOUD_FLAPJACK_VERSION already is.
    assert_contains "$(cat "$nohup_log")" "command=$api_bin version=$(REPO_ROOT="$REPO_ROOT"; source "$REPO_ROOT/scripts/lib/flapjack_binary.sh"; printf '%s' "$FJCLOUD_FLAPJACK_VERSION")" \
        "integration-up enforces the canonical pin even when an override is inherited"
    assert_not_contains "$(cat "$nohup_log")" "version=1.0.99" \
        "an inherited version override must not reach the API runtime env"

    : > "$nohup_log"
    PATH="$WORK_DIR/bin:$PATH" NOHUP_LOG="$nohup_log" \
        FJCLOUD_INTEGRATION_PID_DIR="$WORK_DIR/pids" \
        FJCLOUD_INTEGRATION_API_BINARY="$api_bin" \
        FJCLOUD_INTEGRATION_ENGINE_BINARY="$flapjack_bin" \
        FJCLOUD_INTEGRATION_SKIP_METERING_AGENT=1 \
        INTEGRATION_DB="fjcloud_cutover_probe_integration_up" \
        INTEGRATION_DB_URL="postgres://localhost/fjcloud_cutover_probe_integration_up" \
        bash "$REPO_ROOT/scripts/integration-up.sh" >/dev/null
    # Read the pin from its canonical owner rather than restating it: a restated
    # literal here silently disagrees with the code under test the moment the pin
    # advances, which is the exact class of drift this file's subject exists for.
    assert_contains "$(cat "$nohup_log")" "command=$api_bin version=$(REPO_ROOT="$REPO_ROOT"; source "$REPO_ROOT/scripts/lib/flapjack_binary.sh"; printf '%s' "$FJCLOUD_FLAPJACK_VERSION")" \
        "integration-up keeps the canonical Flapjack version when no override is set"
}

test_cleanup_runs_on_failure() {
    setup_workspace
    CURL_SCENARIO=parity_mismatch run_probe
    assert_eq "$RUN_EXIT_CODE" "1" "failure remains red"
    assert_request_logged "DELETE https://testapp123.algolia.net/1/indexes/fjcloud-cutover-probe-test-123" "failure cleanup deletes source index"
    assert_request_logged "DELETE http://127.0.0.1:3099/indexes/fjcloud-cutover-destination-test-123" "failure cleanup deletes destination index"
    assert_contains "$RUN_STDOUT" "CLEANUP|algolia_index=0|destination_index=0|algolia_key=0|local_stack=0" "failure cleanup reports no residue"
}

test_cleanup_continues_after_destination_delete_failure() {
    setup_workspace
    CURL_SCENARIO=destination_delete_500 run_probe
    assert_eq "$RUN_EXIT_CODE" "1" "destination cleanup failure should fail"
    assert_request_logged "DELETE http://127.0.0.1:3099/indexes/fjcloud-cutover-destination-test-123" "cleanup attempts destination delete"
    assert_request_logged "DELETE https://testapp123.algolia.net/1/keys/restricted-key" "cleanup continues to delete restricted key"
    assert_contains "$(cat "$WORK_DIR/down.log")" "db=fjcloud_cutover_probe_test_123" "cleanup still calls integration-down"
    assert_contains "$RUN_STDOUT" "CLEANUP|" "cleanup emits a diagnostic line"
    assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=cleanup_residue" "cleanup failure has a named non-zero reason"
}

test_cleanup_continues_after_warmup_delete_failure() {
    setup_workspace
    CURL_SCENARIO=warmup_delete_500 run_probe
    assert_eq "$RUN_EXIT_CODE" "1" "warmup cleanup failure should fail"
    assert_request_logged "DELETE http://127.0.0.1:3099/indexes/fjcloud-cutover-warmup-test-123" "cleanup attempts warmup delete"
    assert_request_logged "DELETE https://testapp123.algolia.net/1/keys/restricted-key" "cleanup continues to delete restricted key"
    assert_contains "$(cat "$WORK_DIR/down.log")" "db=fjcloud_cutover_probe_test_123" "cleanup still calls integration-down"
    assert_contains "$RUN_STDOUT" "CLEANUP|" "cleanup emits a diagnostic line"
    assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=cleanup_residue" "cleanup failure has a named non-zero reason"
}

test_cleanup_residue_is_distinct_failure() {
    setup_workspace
    CURL_SCENARIO=cleanup_residue run_probe
    assert_eq "$RUN_EXIT_CODE" "1" "cleanup residue should fail"
    assert_contains "$RUN_STDOUT" "CLEANUP|algolia_index=1" "cleanup residue reports source index residue"
    assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=cleanup_residue" "cleanup residue is a distinct classification"
}

test_paginated_cleanup_inventory_does_not_claim_absence_from_page_zero() {
    setup_workspace
    CURL_SCENARIO=cleanup_list_paginated_residue run_probe
    assert_eq "$RUN_EXIT_CODE" "1" "paginated cleanup residue should fail"
    assert_request_logged "GET https://testapp123.algolia.net/1/indexes?page=1&hitsPerPage=100" \
        "cleanup residue proof follows Algolia list-indexes pagination"
    assert_contains "$RUN_STDOUT" "CLEANUP|algolia_index=1" "paginated cleanup residue reports source index residue"
    assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=cleanup_residue" \
        "paginated cleanup residue is a distinct classification"
}

test_local_runtime_residue_is_distinct_failure() {
    setup_workspace
    CURL_SCENARIO=local_runtime_residue run_probe
    assert_eq "$RUN_EXIT_CODE" "1" "local runtime residue should fail"
    assert_contains "$RUN_STDOUT" "CLEANUP|algolia_index=0|destination_index=0|algolia_key=0|local_stack=1" \
        "cleanup reports local runtime residue"
    assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=cleanup_residue" \
        "local runtime residue is a distinct classification"
}

test_runtime_trap_cleans_credentials_after_prepare_failure() {
    setup_workspace
    write_fake_command "$WORK_DIR/bin/python3" '#!/usr/bin/env bash
count_file="$WORK_DIR/python-count"
count=0
[ -f "$count_file" ] && count="$(cat "$count_file")"
count=$((count + 1))
printf "%s\n" "$count" > "$count_file"
if [ "${CURL_SCENARIO:-success}" = "prepare_fixture_crash" ] && [ "$count" -eq 2 ]; then
  exit 42
fi
if [ "$count" -eq 1 ]; then
  printf "generated-secret\n"
  exit 0
fi
exec "$SYSTEM_PYTHON3" "$@"
'
    CURL_SCENARIO=prepare_fixture_crash run_probe
    assert_eq "$RUN_EXIT_CODE" "42" "fixture preparation failure should preserve the original failing status"
    assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=unhandled_failure" \
        "fixture preparation failure emits a named terminal result"
    assert_eq "$(printf '%s\n' "$RUN_STDOUT" | grep -c '^RESULT|' || true)" "1" \
        "fixture preparation failure emits exactly one terminal result"
    assert_not_contains "$RUN_STDOUT" "algolia-admin-secret" \
        "fixture preparation failure redacts credentials from its terminal output"
    if [ -n "$(ls -A "$WORK_DIR/runtime")" ]; then
        fail "early runtime failure should remove the credential-bearing runtime directory"
    else
        pass "early runtime failure removes the credential-bearing runtime directory"
    fi
}

test_terminal_failed_job_is_distinct_failure() {
    setup_workspace
    CURL_SCENARIO=terminal_failed_job run_probe
    assert_eq "$RUN_EXIT_CODE" "1" "terminal failed job should fail"
    assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=migration_failed" "terminal failed job is classified distinctly"
}

test_early_abort_summary_records_step_without_false_deletion_proof() {
    setup_workspace
    CURL_SCENARIO=early_unexpected_status run_probe
    assert_eq "$RUN_EXIT_CODE" "1" "early unexpected status should fail"
    assert_contains "$(cat "$WORK_DIR/evidence"/*/SUMMARY.md)" "- step: migration_availability" "summary records failing step"
    assert_contains "$(cat "$WORK_DIR/evidence"/*/SUMMARY.md)" "- deletion_proof_exact_source_absent: not_created" "summary does not claim deletion proof before source creation"
}

test_unparsed_cleanup_inventory_does_not_claim_deletion_proof() {
    setup_workspace
    CURL_SCENARIO=cleanup_list_bad_json run_probe
    assert_eq "$RUN_EXIT_CODE" "1" "unparsed cleanup inventory should fail"
    assert_contains "$RUN_STDOUT" "RESULT|status=ACTION_REQUIRED|reason=cleanup_residue" "unparsed cleanup inventory is cleanup residue"
    assert_contains "$(cat "$WORK_DIR/evidence"/*/SUMMARY.md)" "- deletion_proof_exact_source_absent: unknown" "unparsed cleanup inventory is not exact absence proof"
}

# A bundle that a live run produced is only proof if it still reads as proof
# later. These two arms are the recurring owner of the Stage 2 deletion-proof
# check: the negative arm names the shapes that must come out red, the positive
# arm runs the same rule over every bundle actually committed to the repo.
write_synthetic_bundle() {
    local dir="$1" verdict="$2" deletion_proof="$3" inventory="$4"
    mkdir -p "$dir"
    printf -- '- verdict: %s\n- source_index: fjcloud-cutover-probe-synthetic-1\n- deletion_proof_exact_source_absent: %s\n' \
        "$verdict" "$deletion_proof" > "$dir/SUMMARY.md"
    printf '%s\n' "$inventory" > "$dir/list_indexes_after_cleanup.json"
}

write_synthetic_bundle_without_source_index() {
    local dir="$1" verdict="$2" deletion_proof="$3" inventory="$4"
    mkdir -p "$dir"
    printf -- '- verdict: %s\n- deletion_proof_exact_source_absent: %s\n' \
        "$verdict" "$deletion_proof" > "$dir/SUMMARY.md"
    printf '%s\n' "$inventory" > "$dir/list_indexes_after_cleanup.json"
}

test_committed_bundle_check_rejects_non_proof_bundles() {
    setup_workspace
    local root="$WORK_DIR/bundles"

    write_synthetic_bundle "$root/failed_run" "unexpected_status" "true" '{"items":[]}'
    assert_eq "$(cutover_bundle_proof_status "$root/failed_run")" "verdict_not_pass" \
        "a bundle recording a failed run is not proof"

    write_synthetic_bundle "$root/indeterminate" "pass" "unknown" '{"items":[]}'
    assert_eq "$(cutover_bundle_proof_status "$root/indeterminate")" "deletion_proof_not_true" \
        "an indeterminate deletion proof is not proof"

    write_synthetic_bundle "$root/leaked" "pass" "true" \
        '{"items":[{"name":"fjcloud-cutover-probe-synthetic-1"}]}'
    assert_eq "$(cutover_bundle_proof_status "$root/leaked")" "source_index_present_in_inventory" \
        "a bundle whose own inventory still lists the probe index is not proof"

    write_synthetic_bundle "$root/unparsed" "pass" "true" 'not json'
    assert_eq "$(cutover_bundle_proof_status "$root/unparsed")" "inventory_unparsed" \
        "an unreadable inventory cannot back an absence claim"

    write_synthetic_bundle_without_source_index "$root/missing_source" "pass" "true" '{"items":[]}'
    assert_eq "$(cutover_bundle_proof_status "$root/missing_source")" "source_index_missing" \
        "a bundle without a source index cannot prove exact source absence"

    write_synthetic_bundle "$root/parse_error_sentinel" "pass" "true" '{"items":[],"parse_error":true}'
    assert_eq "$(cutover_bundle_proof_status "$root/parse_error_sentinel")" "inventory_unparsed" \
        "a bundle with the parse-error sentinel cannot back an absence claim"

    write_synthetic_bundle "$root/valid" "pass" "true" '{"items":[]}'
    assert_eq "$(cutover_bundle_proof_status "$root/valid")" "ok" \
        "a passing bundle with an absent source index is proof"
}

test_committed_cutover_bundles_are_valid_proof() {
    local evidence_root="$REPO_ROOT/docs/runbooks/evidence/cutover-verification"
    local bundle checked=0

    for bundle in "$evidence_root"/*/; do
        [ -f "$bundle/SUMMARY.md" ] || continue
        checked=$((checked + 1))
        assert_eq "$(cutover_bundle_proof_status "${bundle%/}")" "ok" \
            "committed bundle $(basename "${bundle%/}") reads as cutover proof"
    done

    assert_ne "$checked" "0" "the cutover evidence directory holds at least one committed bundle"
}

test_missing_credentials_stop_before_vendor_call
test_network_and_response_classifications_are_distinct
test_mismatched_verify_report_fails_closed
test_success_match_mutation_restore_and_cleanup_are_proven
test_runtime_ignores_stale_inherited_db_url
test_runtime_uses_canonical_engine_version
test_integration_up_ignores_inherited_version_override
test_cleanup_runs_on_failure
test_cleanup_continues_after_destination_delete_failure
test_cleanup_continues_after_warmup_delete_failure
test_cleanup_residue_is_distinct_failure
test_paginated_cleanup_inventory_does_not_claim_absence_from_page_zero
test_local_runtime_residue_is_distinct_failure
test_runtime_trap_cleans_credentials_after_prepare_failure
test_terminal_failed_job_is_distinct_failure
test_early_abort_summary_records_step_without_false_deletion_proof
test_unparsed_cleanup_inventory_does_not_claim_deletion_proof
test_committed_bundle_check_rejects_non_proof_bundles
test_committed_cutover_bundles_are_valid_proof

run_test_summary
