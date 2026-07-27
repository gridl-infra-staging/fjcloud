#!/usr/bin/env bash
# Local multinode migration boundary probe.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=scripts/lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=scripts/lib/docker.sh
source "$SCRIPT_DIR/lib/docker.sh"
# shellcheck source=scripts/lib/health.sh
source "$SCRIPT_DIR/lib/health.sh"
# shellcheck source=scripts/lib/flapjack_binary.sh
source "$SCRIPT_DIR/lib/flapjack_binary.sh"
# shellcheck source=scripts/lib/algolia_import_live_probe_common.sh
source "$SCRIPT_DIR/lib/algolia_import_live_probe_common.sh"

OWNED_ALGOLIA_INDEXES=()
OWNED_ALGOLIA_KEYS=()
OWNED_FLAPJACK_INDEXES=()
OWNED_FLAPJACK_PIDS=()
OWNED_DATA_DIRS=()
OWNED_RUNTIME_FILES=()
OWNED_DOCKER_NETWORKS=()
OWNED_DOCKER_VOLUMES=()
OWNED_CHILD_PIDS=()
RUNTIME_DIR=""
LIVE_CLEANUP_INSTALLED=0
RUN_ID=""
RUN_PREFIX=""
REPO_SHA=""
FLAPJACK_SOURCE_REVISION=""
ALGOLIA_AUTH_CONFIG=""
STANDALONE_URL=""
STANDALONE_PEER_COUNT=0
STANDALONE_DOCKER=false
HA_TARGET_URL=""
HA_PEER_COUNT=0
HA_DOCKER=false
LIVE_SCENARIO_MODE=positive
EXPECT_STALE_DESTINATION_SURVIVOR=false
STALE_DESTINATION_OBJECT_IDS_JSON='[]'
ACTIVE_FLAPJACK_URL=""
LIVE_CREATE_FIXTURE="$SCRIPT_DIR/tests/fixtures/local_multinode_migration_probe/live_create_source.json"
LIVE_OVERWRITE_FIXTURE="$SCRIPT_DIR/tests/fixtures/local_multinode_migration_probe/live_overwrite_source.json"
LIVE_STALE_FIXTURE="$SCRIPT_DIR/tests/fixtures/local_multinode_migration_probe/live_stale_destination.json"
PARITY_ORACLE="$SCRIPT_DIR/lib/algolia_migration_parity.py"
EVIDENCE_CLASSIFIER="$SCRIPT_DIR/lib/local_multinode_migration_evidence.py"
LIVE_JSON_HELPER="$SCRIPT_DIR/lib/local_multinode_migration_live.py"
source "$SCRIPT_DIR/lib/local_multinode_migration_live_modes.sh"
CREATE_PARITY_REPORT=""
OVERWRITE_PARITY_REPORT=""
OVERWRITE_HITS_FILE=""
CREATE_HITS_FILE=""
CREATE_SOURCE_HITS_FILE=""
OVERWRITE_SOURCE_HITS_FILE=""
CREATE_OUTCOME_FILE=""
OVERWRITE_OUTCOME_FILE=""
HA_CREATE_REFUSAL_JSON=""
HA_OVERWRITE_REFUSAL_JSON=""
CLEANUP_COUNTS_JSON=""
HTTP_STATUS="" HTTP_BODY=""
usage() {
    echo "usage: local_multinode_migration_probe.sh --assert-evidence <json> | --run-live <json> | --negative-ha-vs-standalone <json> | --negative-stale-survivor <json>" >&2
}
log() {
    echo "local_multinode_migration_probe: $*" >&2
}
live_fail() { log "$1"; exit 2; }
classify_evidence() {
    local evidence_path="$1" current_repo_sha classification classifier_rc
    current_repo_sha="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null)" || return 2
    classification="$(
        python3 "$EVIDENCE_CLASSIFIER" "$evidence_path" "$current_repo_sha" 2>/dev/null
    )"
    classifier_rc=$?
    case "$classifier_rc" in
        0|1)
            printf '%s\n' "$classification"
            return "$classifier_rc"
            ;;
        *)
            echo "local_multinode_migration_probe: classifier failed internally" >&2
            return 2
            ;;
    esac
}
run_assert_evidence_mode() {
    local evidence_path="$1"

    if [ ! -f "$evidence_path" ] || [ ! -r "$evidence_path" ]; then
        echo "local_multinode_migration_probe: evidence is not readable" >&2
        exit 2
    fi

    classify_evidence "$evidence_path"
    exit $?
}
validate_live_evidence_output_path() {
    local evidence_path="$1" parent_dir

    [ -n "$evidence_path" ] || {
        log "evidence path is not writable"
        exit 2
    }
    [ ! -d "$evidence_path" ] || {
        log "evidence path is not writable"
        exit 2
    }
    parent_dir="$(dirname "$evidence_path")"
    [ -d "$parent_dir" ] && [ -w "$parent_dir" ] || {
        log "evidence path is not writable"
        exit 2
    }
    : > "$evidence_path" 2>/dev/null || {
        log "evidence path is not writable"
        exit 2
    }
}
live_cleanup() {
    cleanup_owned_resources >/dev/null 2>&1 || true
}
owned_path_residue_count() {
    local count=0 path
    for path in "$@"; do
        [ -n "$path" ] || continue
        [ ! -e "$path" ] || count=$((count + 1))
    done
    printf '%s\n' "$count"
}
owned_pid_residue_count() {
    local count=0 pid
    for pid in "$@"; do
        [ -n "$pid" ] || continue
        kill -0 "$pid" >/dev/null 2>&1 && count=$((count + 1))
    done
    printf '%s\n' "$count"
}

curl_status_no_body() {
    curl --silent --show-error --max-time 30 --output /dev/null \
        --write-out '%{http_code}' "$@"
}

algolia_residue_count() {
    local count=0 status item kind="$1"
    shift
    for item in "$@"; do
        [ -n "$item" ] || continue
        case "$kind" in
            index)
                status="$(curl_status_no_body --config "$ALGOLIA_AUTH_CONFIG" \
                    -X GET "$(algolia_url "/1/indexes/$item")" 2>/dev/null || true)"
                ;;
            key)
                status="$(curl_status_no_body --config "$ALGOLIA_AUTH_CONFIG" \
                    -X GET "$(algolia_url "/1/keys/$item")" 2>/dev/null || true)"
                ;;
            *) status="" ;;
        esac
        [ "$status" = "404" ] || count=$((count + 1))
    done
    printf '%s\n' "$count"
}

flapjack_index_residue_count() {
    local count=0 index status
    [ -n "$STANDALONE_URL" ] || {
        printf '0\n'
        return 0
    }
    for index in ${OWNED_FLAPJACK_INDEXES[@]+"${OWNED_FLAPJACK_INDEXES[@]}"}; do
        [ -n "$index" ] || continue
        status="$(curl_status_no_body -X DELETE \
            "$STANDALONE_URL/1/indexes/$index" 2>/dev/null || true)"
        [ "$status" = "404" ] || count=$((count + 1))
    done
    printf '%s\n' "$count"
}

docker_residue_count() {
    local count=0 item
    for item in ${OWNED_DOCKER_NETWORKS[@]+"${OWNED_DOCKER_NETWORKS[@]}"}; do
        [ -n "$item" ] || continue
        docker network inspect "$item" >/dev/null 2>&1 && count=$((count + 1))
    done
    for item in ${OWNED_DOCKER_VOLUMES[@]+"${OWNED_DOCKER_VOLUMES[@]}"}; do
        [ -n "$item" ] || continue
        docker volume inspect "$item" >/dev/null 2>&1 && count=$((count + 1))
    done
    printf '%s\n' "$count"
}

set_cleanup_counts_json() {
    local algolia_indexes="$1" flapjack_indexes="$2" algolia_keys="$3"
    local local_stack="$4" runtime_files="$5"
    CLEANUP_COUNTS_JSON="$(
        python3 "$LIVE_JSON_HELPER" cleanup-counts "$algolia_indexes" \
            "$flapjack_indexes" "$algolia_keys" "$local_stack" "$runtime_files"
    )"
}

cleanup_owned_resources() {
    local pid path index restricted_key
    local algolia_indexes flapjack_indexes algolia_keys local_stack runtime_files

    if [ -n "$STANDALONE_URL" ]; then
        ACTIVE_FLAPJACK_URL="$STANDALONE_URL"
        for index in ${OWNED_FLAPJACK_INDEXES[@]+"${OWNED_FLAPJACK_INDEXES[@]}"}; do
            [ -n "$index" ] || continue
            flapjack_request "200 404" DELETE "/1/indexes/$index" \
                >/dev/null 2>&1 || true
        done
    fi
    flapjack_indexes="$(flapjack_index_residue_count)"
    for pid in ${OWNED_CHILD_PIDS[@]+"${OWNED_CHILD_PIDS[@]}"} \
        ${OWNED_FLAPJACK_PIDS[@]+"${OWNED_FLAPJACK_PIDS[@]}"}; do
        [ -n "$pid" ] || continue
        kill "$pid" >/dev/null 2>&1 || true
        wait "$pid" >/dev/null 2>&1 || true
    done
    for index in ${OWNED_ALGOLIA_INDEXES[@]+"${OWNED_ALGOLIA_INDEXES[@]}"}; do
        [ -n "$index" ] || continue
        algolia_import_probe_delete_algolia_index "$index" >/dev/null 2>&1 || true
    done
    for restricted_key in ${OWNED_ALGOLIA_KEYS[@]+"${OWNED_ALGOLIA_KEYS[@]}"}; do
        [ -n "$restricted_key" ] || continue
        algolia_request "200 204 404" DELETE "/1/keys/$restricted_key" \
            >/dev/null 2>&1 || true
        algolia_import_probe_wait_for_algolia_key_absence "$restricted_key" \
            >/dev/null 2>&1 || true
    done
    algolia_indexes="$(
        algolia_residue_count index ${OWNED_ALGOLIA_INDEXES[@]+"${OWNED_ALGOLIA_INDEXES[@]}"}
    )"
    algolia_keys="$(
        algolia_residue_count key ${OWNED_ALGOLIA_KEYS[@]+"${OWNED_ALGOLIA_KEYS[@]}"}
    )"
    local_stack="$(
        printf '%s\n' "$(
            owned_pid_residue_count ${OWNED_CHILD_PIDS[@]+"${OWNED_CHILD_PIDS[@]}"} \
                ${OWNED_FLAPJACK_PIDS[@]+"${OWNED_FLAPJACK_PIDS[@]}"}
        )" "$(
            docker_residue_count
        )" | awk '{sum += $1} END {print sum + 0}'
    )"
    for path in ${OWNED_RUNTIME_FILES[@]+"${OWNED_RUNTIME_FILES[@]}"} \
        ${OWNED_DATA_DIRS[@]+"${OWNED_DATA_DIRS[@]}"}; do
        [ -n "$path" ] || continue
        rm -rf "$path"
    done
    if [ -n "$RUNTIME_DIR" ]; then
        rm -rf "$RUNTIME_DIR"
    fi
    runtime_files="$(
        owned_path_residue_count "$RUNTIME_DIR" \
            ${OWNED_RUNTIME_FILES[@]+"${OWNED_RUNTIME_FILES[@]}"} \
            ${OWNED_DATA_DIRS[@]+"${OWNED_DATA_DIRS[@]}"}
    )"
    set_cleanup_counts_json "$algolia_indexes" "$flapjack_indexes" \
        "$algolia_keys" "$local_stack" "$runtime_files"
}

install_live_cleanup_trap() {
    [ "$LIVE_CLEANUP_INSTALLED" -eq 0 ] || return 0
    trap live_cleanup EXIT
    LIVE_CLEANUP_INSTALLED=1
}

prepare_live_runtime() {
    RUNTIME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/local_multinode_migration_probe.XXXXXX")"
    OWNED_DATA_DIRS+=("$RUNTIME_DIR")
    install_live_cleanup_trap
}

require_live_docker_daemon() {
    if ( require_docker_daemon ); then
        return 0
    fi
    log "docker daemon unavailable"
    exit 2
}

require_live_flapjack_binary() {
    local flapjack_dev_dir="${FLAPJACK_DEV_DIR:-}" binary_path
    [ -n "$flapjack_dev_dir" ] || {
        log "FLAPJACK_DEV_DIR is invalid"
        exit 2
    }
    binary_path="$(find_flapjack_binary "$flapjack_dev_dir" 2>/dev/null)" || {
        log "FLAPJACK_DEV_DIR is invalid"
        exit 2
    }
    [ -n "$binary_path" ] || {
        log "FLAPJACK_DEV_DIR is invalid"
        exit 2
    }
    FLAPJACK_BIN="$binary_path"
}

require_live_algolia_credentials() {
    local secret_file="${FJCLOUD_SECRET_FILE:-$REPO_ROOT/.secret/.env.secret}"
    if ! algolia_import_probe_load_algolia_secrets "$secret_file"; then
        log "Algolia credentials unavailable"
        exit 2
    fi
}

selected_flapjack_source_revision() {
    local provenance receipt_path revision
    provenance="$(flapjack_source_provenance_summary)"
    revision="$(flapjack_provenance_token_after "$provenance" revision || true)"
    if [ -z "$revision" ] \
        && receipt_path="$(flapjack_receipt_path_from_provenance "$provenance" 2>/dev/null)"
    then
        revision="$(flapjack_receipt_value "$receipt_path" git_revision || true)"
        [ -n "$revision" ] \
            || revision="$(flapjack_receipt_value "$receipt_path" revision || true)"
    fi
    [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || return 1
    printf '%s\n' "$revision"
}

prepare_live_plan() {
    local repo_short_sha
    REPO_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null)" || return 1
    [[ "$REPO_SHA" =~ ^[0-9a-f]{40}$ ]] || return 1
    repo_short_sha="${REPO_SHA:0:12}"
    RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)_${repo_short_sha}_$$"
    [[ "$RUN_ID" =~ ^[A-Za-z0-9_]+$ ]] || return 1
    RUN_PREFIX="fj_multinode_${RUN_ID}"
    CREATE_SOURCE_INDEX="${RUN_PREFIX}_create_source"
    CREATE_TARGET_INDEX="${RUN_PREFIX}_create_target"
    OVERWRITE_SOURCE_INDEX="${RUN_PREFIX}_overwrite_source"
    OVERWRITE_TARGET_INDEX="${RUN_PREFIX}_overwrite_target"

    flapjack_export_required_artifact_identity "$FLAPJACK_BIN" || return 1
    FLAPJACK_SOURCE_REVISION="$(selected_flapjack_source_revision)" || return 1
    ALGOLIA_AUTH_CONFIG="$(algolia_import_probe_secure_temp_file "$RUNTIME_DIR")"
    OWNED_RUNTIME_FILES+=("$ALGOLIA_AUTH_CONFIG")
    algolia_import_probe_write_header_config "$ALGOLIA_AUTH_CONFIG" \
        "X-Algolia-Application-Id: $ALGOLIA_APP_ID" \
        "X-Algolia-API-Key: $ALGOLIA_ADMIN_KEY"
}

validate_flapjack_migration_contract() {
    local source_root handler contract_tests
    source_root="$(flapjack_source_root "$FLAPJACK_DEV_DIR" 2>/dev/null)" || return 1
    handler="$source_root/flapjack-http/src/handlers/migration/mod.rs"
    contract_tests="$source_root/flapjack-http/src/handlers/migration/import_contract_tests.rs"
    [ -r "$handler" ] && [ -r "$contract_tests" ] || return 1
    rg -F 'path = "/1/migrations/algolia"' "$handler" >/dev/null || return 1
    rg -F 'path = "/1/migrations/algolia/{job_id}"' "$handler" >/dev/null || return 1
    rg -F 'async_import_create_then_overwrite_replaces_exact_target' \
        "$contract_tests" >/dev/null || return 1
    rg -F 'overwrite=true async replacement should be admitted' \
        "$contract_tests" >/dev/null || return 1
    rg -F 'async_import_ha_state_is_refused_by_shared_admission_owner' \
        "$contract_tests" >/dev/null || return 1
}

choose_live_port() {
    python3 "$LIVE_JSON_HELPER" free-port
}

start_standalone_flapjack() {
    local port data_dir log_file pid
    port="$(choose_live_port)" || return 1
    data_dir="$RUNTIME_DIR/standalone_data"
    log_file="$(algolia_import_probe_secure_temp_file "$RUNTIME_DIR")"
    mkdir -p "$data_dir"
    OWNED_DATA_DIRS+=("$data_dir")
    OWNED_RUNTIME_FILES+=("$log_file")

    FLAPJACK_NO_AUTH=1 nohup "$FLAPJACK_BIN" \
        --port "$port" \
        --data-dir "$data_dir" \
        </dev/null >"$log_file" 2>&1 &
    pid=$!
    OWNED_FLAPJACK_PIDS+=("$pid")
    wait_for_health "http://127.0.0.1:${port}/health" "standalone Flapjack" 20 \
        || return 1
    STANDALONE_URL="http://127.0.0.1:${port}"
    ACTIVE_FLAPJACK_URL="$STANDALONE_URL"
    STANDALONE_DOCKER=false
}

measure_standalone_topology() {
    [ -n "$STANDALONE_URL" ] || {
        STANDALONE_PEER_COUNT=0
        return 0
    }
    STANDALONE_PEER_COUNT="$(flapjack_peer_count "$STANDALONE_URL")" || return 1
    [ "$STANDALONE_PEER_COUNT" -eq 0 ]
}

secure_temp_file() {
    algolia_import_probe_secure_temp_file "$RUNTIME_DIR"
}

new_owned_runtime_file() {
    local destination_name="$1" path
    path="$(algolia_import_probe_secure_temp_file "$RUNTIME_DIR")" || return 1
    OWNED_RUNTIME_FILES+=("$path")
    printf -v "$destination_name" '%s' "$path"
}

curl_http() {
    local expected="$1" body status
    shift
    new_owned_runtime_file body || return 1
    status="$(curl --silent --show-error --max-time 30 \
        --output "$body" --write-out '%{http_code}' "$@")" || return 1
    HTTP_STATUS="$status"
    HTTP_BODY="$(cat "$body")"
    [[ " $expected " == *" $status "* ]]
}

algolia_url() {
    printf 'https://%s.algolia.net%s' \
        "$(printf '%s' "$ALGOLIA_APP_ID" | tr '[:upper:]' '[:lower:]')" "$1"
}

algolia_request() {
    local expected="$1" method="$2" path="$3" data_file="${4:-}" args
    args=(--config "$ALGOLIA_AUTH_CONFIG" -X "$method")
    [ -z "$data_file" ] || args+=(--data @"$data_file")
    curl_http "$expected" "${args[@]}" "$(algolia_url "$path")"
}

seed_algolia_index() {
    local index="$1" fixture="$2" payload task_id
    new_owned_runtime_file payload || return 1
    python3 "$LIVE_JSON_HELPER" batch-add-payload "$fixture" "$payload" || return 1
    OWNED_ALGOLIA_INDEXES+=("$index")
    algolia_request "200 201" POST "/1/indexes/$index/batch" "$payload" || return 1
    task_id="$(algolia_import_probe_json_field "$HTTP_BODY" taskID 2>/dev/null || true)"
    [ -z "$task_id" ] || algolia_import_probe_wait_for_algolia_task "$index" "$task_id" || return 1
    algolia_import_probe_write_json_file "$payload" \
        '{"searchableAttributes":["title"],"attributesForFaceting":["category"]}'
    algolia_request "200 201" PUT "/1/indexes/$index/settings" "$payload" || return 1
    task_id="$(algolia_import_probe_json_field "$HTTP_BODY" taskID 2>/dev/null || true)"
    [ -z "$task_id" ] || algolia_import_probe_wait_for_algolia_task "$index" "$task_id"
}

create_restricted_algolia_key() {
    local payload indexes_json restricted_key index
    new_owned_runtime_file payload || return 1
    indexes_json="$(python3 - "$@" <<'PY'
import json
import sys
print(json.dumps(sys.argv[1:], separators=(",", ":")))
PY
)" || return 1
    algolia_import_probe_write_json_file "$payload" \
        "{\"acl\":[\"search\",\"browse\",\"settings\",\"listIndexes\"],\"indexes\":$indexes_json,\"description\":\"$RUN_PREFIX\"}"
    algolia_request "200 201" POST "/1/keys" "$payload" || return 1
    restricted_key="$(algolia_import_probe_json_field "$HTTP_BODY" key 2>/dev/null)" \
        || return 1
    algolia_import_probe_safe_response_identifier "$restricted_key" || return 1
    OWNED_ALGOLIA_KEYS+=("$restricted_key")
    for index in "$@"; do
        algolia_import_probe_wait_for_restricted_source_key "$index" "$restricted_key" \
            || return 1
    done
    DISPOSABLE_ALGOLIA_KEY="$restricted_key"
}

seed_live_algolia_sources() {
    seed_algolia_index "$CREATE_SOURCE_INDEX" "$LIVE_CREATE_FIXTURE" || return 1
    seed_algolia_index "$OVERWRITE_SOURCE_INDEX" "$LIVE_OVERWRITE_FIXTURE" || return 1
    create_restricted_algolia_key "$CREATE_SOURCE_INDEX" "$OVERWRITE_SOURCE_INDEX"
}

flapjack_request() {
    local expected="$1" method="$2" path="$3" data_file="${4:-}" args
    args=(-X "$method")
    [ -z "$data_file" ] || args+=(--header "content-type: application/json" --data @"$data_file")
    curl_http "$expected" "${args[@]}" "${ACTIVE_FLAPJACK_URL}${path}"
}

write_migration_payload() {
    local output="$1" source_index="$2" target_index="$3" overwrite="$4"
    ALGOLIA_SOURCE_KEY="$DISPOSABLE_ALGOLIA_KEY" python3 - \
        "$output" "$ALGOLIA_APP_ID" "$source_index" "$target_index" "$overwrite" <<'PY'
import json
import os
import sys

payload = {
    "appId": sys.argv[2],
    "apiKey": os.environ["ALGOLIA_SOURCE_KEY"],
    "sourceIndex": sys.argv[3],
    "targetIndex": sys.argv[4],
    "overwrite": sys.argv[5] == "true",
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, separators=(",", ":"))
PY
}

poll_migration_job() {
    local job_id="$1" outcome_file="$2" disposition
    for _ in $(seq 1 30); do
        flapjack_request "200" GET "/1/migrations/algolia/$job_id" || return 1
        disposition="$(algolia_import_probe_json_field "$HTTP_BODY" disposition 2>/dev/null)" \
            || return 1
        case "$disposition" in
            succeeded)
                # The classifier owns the benign-vs-unexpected warning verdict, so
                # capture the terminal outcome (settings/synonyms/rules/warnings)
                # verbatim rather than asserting a no-warning contract here.
                python3 "$LIVE_JSON_HELPER" capture-outcome "$HTTP_BODY" "$outcome_file"
                return $?
                ;;
            failed|cancelled) return 1 ;;
            running) sleep 1 ;;
            *) return 1 ;;
        esac
    done
    return 1
}

run_standalone_migration() {
    local source_index="$1" target_index="$2" overwrite="$3" outcome_file="$4" payload job_id
    new_owned_runtime_file payload || return 1
    write_migration_payload "$payload" "$source_index" "$target_index" "$overwrite" || return 1
    OWNED_FLAPJACK_INDEXES+=("$target_index")
    flapjack_request "202" POST "/1/migrations/algolia" "$payload" || return 1
    job_id="$(algolia_import_probe_json_field "$HTTP_BODY" jobId 2>/dev/null)" || return 1
    [[ "$job_id" =~ ^[0-9a-fA-F-]{36}$ ]] || return 1
    poll_migration_job "$job_id" "$outcome_file"
}

browse_flapjack_index() {
    local index="$1" output="$2" payload
    new_owned_runtime_file payload || return 1
    algolia_import_probe_write_json_file "$payload" '{"hitsPerPage":1000}'
    flapjack_request "200" POST "/1/indexes/$index/browse" "$payload" || return 1
    python3 "$LIVE_JSON_HELPER" extract-hits "$HTTP_BODY" "$output"
}

browse_algolia_index() {
    local index="$1" output="$2" payload
    new_owned_runtime_file payload || return 1
    algolia_import_probe_write_json_file "$payload" '{"hitsPerPage":1000}'
    algolia_request "200" POST "/1/indexes/$index/browse" "$payload" || return 1
    python3 "$LIVE_JSON_HELPER" extract-hits "$HTTP_BODY" "$output"
}

assert_source_matches_fixture() {
    local fixture="$1" source_hits_file="$2" report="$3" expected_count="$4" expected_ids="$5"
    python3 "$PARITY_ORACLE" --source "$fixture" --migrated "$source_hits_file" >"$report" \
        || return 1
    python3 "$LIVE_JSON_HELPER" assert-parity \
        "$report" "$fixture" "$expected_count" "$expected_ids"
}

compare_migration_parity() {
    local source_hits_file="$1" target="$2" hits_file="$3" report="$4"
    browse_flapjack_index "$target" "$hits_file" || return 1
    python3 "$PARITY_ORACLE" --source "$source_hits_file" --migrated "$hits_file" >"$report"
}

assert_parity_report() {
    local report="$1" expected_count="$2" expected_ids="$3" fixture
    [ "$expected_count" = "2" ] && fixture="$LIVE_CREATE_FIXTURE" \
        || fixture="$LIVE_OVERWRITE_FIXTURE"
    python3 "$LIVE_JSON_HELPER" assert-parity \
        "$report" "$fixture" "$expected_count" "$expected_ids"
}

seed_stale_flapjack_target() {
    local payload
    new_owned_runtime_file payload || return 1
    python3 "$LIVE_JSON_HELPER" batch-add-payload "$LIVE_STALE_FIXTURE" "$payload" || return 1
    OWNED_FLAPJACK_INDEXES+=("$OVERWRITE_TARGET_INDEX")
    flapjack_request "200 201" POST "/1/indexes/$OVERWRITE_TARGET_INDEX/batch" "$payload"
}

assert_stale_destination_absent() {
    python3 - "$OVERWRITE_HITS_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    ids = {item.get("objectID") for item in json.load(handle)}
assert "stale-destination-doc" not in ids
PY
}

record_stale_destination_absence() {
    if [ "$EXPECT_STALE_DESTINATION_SURVIVOR" = true ]; then
        STALE_DESTINATION_OBJECT_IDS_JSON='["stale-destination-doc"]'
        return 0
    fi
    assert_stale_destination_absent || return 1
    STALE_DESTINATION_OBJECT_IDS_JSON='[]'
}

run_standalone_specimens() {
    new_owned_runtime_file CREATE_SOURCE_HITS_FILE || return 1
    new_owned_runtime_file CREATE_HITS_FILE || return 1
    new_owned_runtime_file CREATE_PARITY_REPORT || return 1
    new_owned_runtime_file CREATE_OUTCOME_FILE || return 1
    new_owned_runtime_file OVERWRITE_SOURCE_HITS_FILE || return 1
    new_owned_runtime_file OVERWRITE_HITS_FILE || return 1
    new_owned_runtime_file OVERWRITE_PARITY_REPORT || return 1
    new_owned_runtime_file OVERWRITE_OUTCOME_FILE || return 1
    browse_algolia_index "$CREATE_SOURCE_INDEX" "$CREATE_SOURCE_HITS_FILE" || return 1
    assert_source_matches_fixture "$LIVE_CREATE_FIXTURE" "$CREATE_SOURCE_HITS_FILE" \
        "$CREATE_PARITY_REPORT" 2 "create-doc-1,create-doc-2" || return 1
    browse_algolia_index "$OVERWRITE_SOURCE_INDEX" "$OVERWRITE_SOURCE_HITS_FILE" || return 1
    assert_source_matches_fixture "$LIVE_OVERWRITE_FIXTURE" "$OVERWRITE_SOURCE_HITS_FILE" \
        "$OVERWRITE_PARITY_REPORT" 3 "overwrite-doc-1,overwrite-doc-2,overwrite-doc-3" \
        || return 1
    run_standalone_migration "$CREATE_SOURCE_INDEX" "$CREATE_TARGET_INDEX" false \
        "$CREATE_OUTCOME_FILE" || return 1
    compare_migration_parity "$CREATE_SOURCE_HITS_FILE" "$CREATE_TARGET_INDEX" \
        "$CREATE_HITS_FILE" "$CREATE_PARITY_REPORT" || return 1
    assert_parity_report "$CREATE_PARITY_REPORT" 2 "create-doc-1,create-doc-2" || return 1
    seed_stale_flapjack_target || return 1
    run_standalone_migration "$OVERWRITE_SOURCE_INDEX" "$OVERWRITE_TARGET_INDEX" true \
        "$OVERWRITE_OUTCOME_FILE" || return 1
    compare_migration_parity "$OVERWRITE_SOURCE_HITS_FILE" "$OVERWRITE_TARGET_INDEX" \
        "$OVERWRITE_HITS_FILE" "$OVERWRITE_PARITY_REPORT" || return 1
    assert_parity_report "$OVERWRITE_PARITY_REPORT" 3 "overwrite-doc-1,overwrite-doc-2,overwrite-doc-3" \
        && record_stale_destination_absence
}

resolve_safe_peer_host() {
    python3 "$LIVE_JSON_HELPER" safe-peer-host
}

write_peer_node_config() {
    local data_dir="$1" node_id="$2" bind_addr="$3" peer_id="$4" peer_url="$5"
    python3 "$LIVE_JSON_HELPER" peer-node-config "$data_dir/node.json" \
        "$node_id" "$bind_addr" "$peer_id" "$peer_url"
}

start_peer_node_async() {
    local label="$1" port="$2" data_dir="$3" log_file="$4" bind_addr="$5" pid
    FLAPJACK_NO_AUTH=1 FLAPJACK_ALLOW_NO_AUTH_PUBLIC_BIND=1 FLAPJACK_STARTUP_CATCHUP_STRICT=0 nohup "$FLAPJACK_BIN" --port "$port" \
        --bind-addr "$bind_addr" --data-dir "$data_dir" </dev/null >"$log_file" 2>&1 &
    pid=$!
    OWNED_FLAPJACK_PIDS+=("$pid")
}
wait_peer_node_health() {
    local label="$1" health_url="$2"
    wait_for_health "$health_url" "$label Flapjack" 20
}
start_peer_connected_flapjack() {
    local seed_port target_port seed_dir target_dir seed_log target_log
    local peer_host seed_bind_addr target_bind_addr seed_peer target_peer
    peer_host="$(resolve_safe_peer_host)" || {
        log "no routable non-loopback peer address available"
        return 1
    }
    seed_port="$(choose_live_port)" || return 1
    target_port="$(choose_live_port)" || return 1
    seed_dir="$RUNTIME_DIR/ha_seed_data"
    target_dir="$RUNTIME_DIR/ha_target_data"
    new_owned_runtime_file seed_log || return 1
    new_owned_runtime_file target_log || return 1
    mkdir -p "$seed_dir" "$target_dir"
    OWNED_DATA_DIRS+=("$seed_dir" "$target_dir")
    seed_bind_addr="${peer_host}:${seed_port}"; target_bind_addr="${peer_host}:${target_port}"
    HA_TARGET_URL="http://${target_bind_addr}"; seed_peer="http://${seed_bind_addr}"
    target_peer="http://${target_bind_addr}"
    # local-dev-up multi-region starts independent nodes; this probe needs connected peers.
    write_peer_node_config "$seed_dir" "seed" "$seed_bind_addr" \
        "target" "$target_peer" || return 1
    write_peer_node_config "$target_dir" "target" "$target_bind_addr" \
        "seed" "$seed_peer" || return 1
    start_peer_node_async "seed" "$seed_port" "$seed_dir" "$seed_log" "$seed_bind_addr" \
        || return 1
    start_peer_node_async "target" "$target_port" "$target_dir" "$target_log" "$target_bind_addr" \
        || return 1
    wait_peer_node_health "seed" "http://${seed_bind_addr}/health" || return 1
    wait_peer_node_health "target" "http://${target_bind_addr}/health" || return 1
    wait_for_peer_count "$HA_TARGET_URL" 1 || return 1
    HA_PEER_COUNT="$(flapjack_peer_count "$HA_TARGET_URL")" || return 1
    HA_DOCKER=false
}
flapjack_peer_count() {
    local base_url="$1" peer_count
    ACTIVE_FLAPJACK_URL="$base_url"
    flapjack_request "200" GET "/internal/cluster/status" || return 1
    peer_count="$(
        python3 - "$HTTP_BODY" <<'PY'
import json
import sys

try:
    payload = json.loads(sys.argv[1])
    if isinstance(payload.get("peers_total"), int):
        print(payload["peers_total"])
    elif isinstance(payload.get("peers"), list):
        print(len(payload["peers"]))
    else:
        raise ValueError
except (json.JSONDecodeError, ValueError):
    raise SystemExit(1)
PY
    )" || return 1
    [[ "$peer_count" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$peer_count"
}
wait_for_peer_count() {
    local base_url="$1" minimum="$2" observed
    for _ in $(seq 1 20); do
        observed="$(flapjack_peer_count "$base_url" 2>/dev/null || true)"
        [ -z "$observed" ] || [ "$observed" -lt "$minimum" ] || return 0
        sleep 1
    done
    return 1
}
classify_ha_refusal_evidence() {
    local peer_count="$1" status="$2" body="$3"
    python3 "$LIVE_JSON_HELPER" ha-refusal "$peer_count" "$status" "$body"
}
run_ha_refusal_specimen() {
    local base_url="$1" source_index="$2" target_index="$3" overwrite="$4"
    local payload status body
    ACTIVE_FLAPJACK_URL="$base_url"
    new_owned_runtime_file payload || return 1
    new_owned_runtime_file body || return 1
    write_migration_payload "$payload" "$source_index" "$target_index" "$overwrite" || return 1
    status="$(curl --silent --show-error --max-time 30 --output "$body" \
        --write-out '%{http_code}' --header "content-type: application/json" \
        --data @"$payload" "$base_url/1/migrations/algolia")" || return 1
    HTTP_BODY="$(cat "$body")"
    classify_ha_refusal_evidence "$HA_PEER_COUNT" "$status" "$HTTP_BODY"
}
run_ha_refusal_specimens() {
    HA_CREATE_REFUSAL_JSON="$(
        run_ha_refusal_specimen "$HA_TARGET_URL" "$CREATE_SOURCE_INDEX" \
            "$CREATE_TARGET_INDEX" false
    )" || return 1
    HA_OVERWRITE_REFUSAL_JSON="$(
        run_ha_refusal_specimen "$HA_TARGET_URL" "$OVERWRITE_SOURCE_INDEX" \
            "$OVERWRITE_TARGET_INDEX" true
    )" || return 1
}
write_live_evidence() {
    local output="$1"
    python3 "$LIVE_JSON_HELPER" write-evidence \
        "$output" "$REPO_SHA" "$FJCLOUD_FLAPJACK_REQUIRED_SHA256" \
        "$FLAPJACK_SOURCE_REVISION" "$STANDALONE_PEER_COUNT" "$STANDALONE_DOCKER" \
        "$HA_PEER_COUNT" "$HA_DOCKER" "$CREATE_SOURCE_HITS_FILE" "$CREATE_HITS_FILE" \
        "$CREATE_PARITY_REPORT" "$CREATE_OUTCOME_FILE" "$OVERWRITE_SOURCE_HITS_FILE" \
        "$OVERWRITE_HITS_FILE" "$OVERWRITE_PARITY_REPORT" "$OVERWRITE_OUTCOME_FILE" \
        "$HA_CREATE_REFUSAL_JSON" "$HA_OVERWRITE_REFUSAL_JSON" "$CLEANUP_COUNTS_JSON" \
        "$STALE_DESTINATION_OBJECT_IDS_JSON"
}
case "${1:-}" in
    --assert-evidence)
        if [ "$#" -ne 2 ]; then
            usage
            exit 2
        fi
        run_assert_evidence_mode "$2"
        ;;
    --run-live)
        if [ "$#" -ne 2 ]; then
            usage
            exit 2
        fi
        run_live_mode "$2" positive
        ;;
    --negative-ha-vs-standalone)
        if [ "$#" -ne 2 ]; then
            usage
            exit 2
        fi
        run_live_mode "$2" negative_ha_vs_standalone
        ;;
    --negative-stale-survivor)
        if [ "$#" -ne 2 ]; then
            usage
            exit 2
        fi
        run_live_mode "$2" negative_stale_survivor
        ;;
    *)
        usage
        exit 2
        ;;
esac
