#!/usr/bin/env bash
# Validate customer quickstart contracts across staging/prod modes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/env.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/env.sh"

EXIT_USAGE=2
EXIT_RUNTIME=1

QUICKSTART_MODE=""
QUICKSTART_CONTRACT_ONLY=0
QUICKSTART_DOC_PATH="${QUICKSTART_DOC_PATH:-$REPO_ROOT/docs/getting-started/customer-quickstart.md}"
QUICKSTART_MIGRATION_DOC_PATH="${QUICKSTART_MIGRATION_DOC_PATH:-$REPO_ROOT/docs/getting-started/migrating_from_algolia.md}"
QUICKSTART_MARKER_INVENTORY=""
QUICKSTART_MIGRATION_MARKER_INVENTORY=""

# Each entry: marker_id|source_doc (quickstart or migration).
# Dispatch order is owned explicitly by run_quickstart_and_migration_sequence.
MARKER_CASES=(
    "auth_register|quickstart"
    "auth_verify_email|quickstart"
    "indexes_create|quickstart"
    "indexes_batch_add_object|quickstart"
    "indexes_search|quickstart"
    "migration_indexes_list|migration"
    "migration_indexes_create|migration"
    "migration_indexes_batch_add_object|migration"
    "migration_indexes_search|migration"
    "migration_indexes_get_object|migration"
    "migration_indexes_batch_update_object|migration"
    "migration_indexes_delete_object|migration"
    "migration_indexes_save_synonym|migration"
    "migration_indexes_save_rule|migration"
)

print_usage() {
    cat <<'USAGE'
Usage: validate_customer_quickstart.sh <staging|prod> [--contract-only]

Modes:
  staging              Run full quickstart validation flow.
  prod                 Run full quickstart validation flow.
  prod --contract-only Run non-destructive contract probes only.

Notes:
  --contract-only is only valid with prod mode.
USAGE
}

die_usage() {
    echo "ERROR: $*" >&2
    print_usage >&2
    exit "$EXIT_USAGE"
}

log() {
    echo "[validate_customer_quickstart] $*"
}

# run_signup_verify_search_flow sources scripts/canary/customer_loop_synthetic.sh,
# which redefines log() with prefix [customer-loop-canary]. validator_log()
# preserves the [validate_customer_quickstart] prefix for success markers that
# the Stage 4 evidence contract greps for (e.g. "migration case succeeded: ...").
# Do not consolidate with log() — that would shadow the validator prefix once
# the canary owner is sourced.
validator_log() {
    echo "[validate_customer_quickstart] $*"
}

load_validator_env() {
    local default_secret_file="$REPO_ROOT/.secret/.env.secret"
    local secret_file="${FJCLOUD_SECRET_FILE:-$default_secret_file}"

    # Keep local/dev behavior aligned with the secret-source precedence contract:
    # explicit FJCLOUD_SECRET_FILE override first, then repo-local default path.
    load_env_file "$secret_file"

    export API_URL="${API_URL:-}"
}

resolve_scripts_root() {
    if [ -n "${QUICKSTART_STUB_ROOT:-}" ]; then
        if [ "${QUICKSTART_ALLOW_STUB_ROOT:-0}" != "1" ]; then
            echo "ERROR: QUICKSTART_STUB_ROOT is test-only; set QUICKSTART_ALLOW_STUB_ROOT=1 to enable stubbed script ownership" >&2
            return 1
        fi
        printf '%s/scripts\n' "$QUICKSTART_STUB_ROOT"
    else
        printf '%s/scripts\n' "$REPO_ROOT"
    fi
}

resolve_doc_paths() {
    local override_present=0
    local default_quickstart_doc="$REPO_ROOT/docs/getting-started/customer-quickstart.md"
    local default_migration_doc="$REPO_ROOT/docs/getting-started/migrating_from_algolia.md"

    if [ -n "${QUICKSTART_DOC_PATH_OVERRIDE:-}" ]; then
        QUICKSTART_DOC_PATH="$QUICKSTART_DOC_PATH_OVERRIDE"
        override_present=1
    elif [ "${QUICKSTART_DOC_PATH:-$default_quickstart_doc}" != "$default_quickstart_doc" ]; then
        override_present=1
    fi

    if [ -n "${QUICKSTART_MIGRATION_DOC_PATH_OVERRIDE:-}" ]; then
        QUICKSTART_MIGRATION_DOC_PATH="$QUICKSTART_MIGRATION_DOC_PATH_OVERRIDE"
        override_present=1
    elif [ "${QUICKSTART_MIGRATION_DOC_PATH:-$default_migration_doc}" != "$default_migration_doc" ]; then
        override_present=1
    fi

    if [ "$override_present" -eq 1 ] && [ "${QUICKSTART_ALLOW_DOC_OVERRIDES:-0}" != "1" ]; then
        echo "ERROR: quickstart doc overrides are test-only; set QUICKSTART_ALLOW_DOC_OVERRIDES=1 to enable fixture docs" >&2
        return 1
    fi
}

case_source_doc() {
    local marker_id="$1"
    local entry id source

    for entry in "${MARKER_CASES[@]}"; do
        IFS='|' read -r id source <<< "$entry"
        if [ "$id" = "$marker_id" ]; then
            printf '%s\n' "$source"
            return 0
        fi
    done

    return 1
}

case_table_contains() {
    local marker_id="$1"

    case_source_doc "$marker_id" >/dev/null 2>&1
}

marker_inventory_contains() {
    local inventory="$1"
    local marker_id="$2"
    local marker

    while IFS= read -r marker; do
        if [ "$marker" = "$marker_id" ]; then
            return 0
        fi
    done <<< "$inventory"

    return 1
}

parse_doc_markers() {
    local doc_path="$1"
    local source_doc="$2"
    local line marker_id expected_source seen_markers=""

    if [ ! -f "$doc_path" ]; then
        echo "ERROR: missing ${source_doc} doc at ${doc_path}" >&2
        return 1
    fi

    while IFS= read -r line; do
        if [[ "$line" =~ validate_customer_quickstart:[[:space:]]*([A-Za-z0-9_]+) ]]; then
            marker_id="${BASH_REMATCH[1]}"
            if ! case_table_contains "$marker_id"; then
                echo "ERROR: unknown validate_customer_quickstart marker '${marker_id}' in ${source_doc} doc ${doc_path}" >&2
                return 1
            fi
            expected_source="$(case_source_doc "$marker_id")"
            if [ "$expected_source" != "$source_doc" ]; then
                echo "ERROR: marker '${marker_id}' belongs to ${expected_source} doc but was found in ${source_doc} doc ${doc_path}" >&2
                return 1
            fi
            if marker_inventory_contains "$seen_markers" "$marker_id"; then
                echo "ERROR: duplicate marker '${marker_id}' in ${source_doc} doc ${doc_path}" >&2
                return 1
            fi
            seen_markers="${seen_markers}${marker_id}"$'\n'
            printf '%s\n' "$marker_id"
        fi
    done < "$doc_path"
}

require_case_markers() {
    local source_doc="$1"
    local inventory="$2"
    local doc_path="$3"
    local entry id case_source
    local failures=0

    for entry in "${MARKER_CASES[@]}"; do
        IFS='|' read -r id case_source <<< "$entry"
        if [ "$case_source" != "$source_doc" ]; then
            continue
        fi
        if ! marker_inventory_contains "$inventory" "$id"; then
            echo "ERROR: required marker '${id}' missing from ${source_doc} doc ${doc_path}" >&2
            failures=$((failures + 1))
        fi
    done

    [ "$failures" -eq 0 ]
}

format_marker_inventory() {
    local inventory="$1"

    printf '%s\n' "$inventory" | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

validate_doc_marker_contracts() {
    if ! QUICKSTART_MARKER_INVENTORY="$(parse_doc_markers "$QUICKSTART_DOC_PATH" "quickstart")"; then
        return 1
    fi
    if ! QUICKSTART_MIGRATION_MARKER_INVENTORY="$(parse_doc_markers "$QUICKSTART_MIGRATION_DOC_PATH" "migration")"; then
        return 1
    fi

    require_case_markers "quickstart" "$QUICKSTART_MARKER_INVENTORY" "$QUICKSTART_DOC_PATH" || return 1
    require_case_markers "migration" "$QUICKSTART_MIGRATION_MARKER_INVENTORY" "$QUICKSTART_MIGRATION_DOC_PATH" || return 1

    log "quickstart markers: $(format_marker_inventory "$QUICKSTART_MARKER_INVENTORY")"
    log "migration markers: $(format_marker_inventory "$QUICKSTART_MIGRATION_MARKER_INVENTORY")"
}

curl_http_code() {
    local method="$1"
    local url="$2"

    curl -sS -o /dev/null -w '%{http_code}' -X "$method" "$url" 2>/dev/null || printf '000'
}

probe_success_endpoint() {
    local path="$1"
    local code

    code="$(curl_http_code GET "${API_URL}${path}")"
    if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
        log "probe succeeded: GET ${path} (http=${code})"
        return 0
    fi

    echo "ERROR: expected success for ${path}, got HTTP ${code}" >&2
    return 1
}

probe_documented_method_contract() {
    local method="$1"
    local path="$2"
    local code

    code="$(curl_http_code "$method" "${API_URL}${path}")"
    if [ "$code" = "000" ]; then
        echo "ERROR: documented method unreachable (transport failure) for ${method} ${path}" >&2
        return 1
    fi

    # Contract-only runs are intentionally unauthenticated and non-mutating, so
    # auth/validation failures are acceptable proof that the exact method route
    # exists. Missing routes, missing methods, and server faults are not.
    if [ "$code" = "404" ] || [ "$code" = "405" ] || [[ "$code" =~ ^5[0-9][0-9]$ ]]; then
        echo "ERROR: documented method returned HTTP ${code} for ${method} ${path}" >&2
        return 1
    fi

    log "documented method reachable: ${method} ${path} (http=${code})"
    return 0
}

parse_args() {
    if [ "$#" -lt 1 ]; then
        die_usage "missing mode argument"
    fi

    QUICKSTART_MODE="$1"
    shift

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --contract-only)
                QUICKSTART_CONTRACT_ONLY=1
                ;;
            --help|-h)
                print_usage
                exit 0
                ;;
            *)
                die_usage "unknown argument: $1"
                ;;
        esac
        shift
    done

    if [ "$QUICKSTART_MODE" != "staging" ] && [ "$QUICKSTART_MODE" != "prod" ]; then
        die_usage "mode must be staging or prod"
    fi

    if [ "$QUICKSTART_CONTRACT_ONLY" -eq 1 ] && [ "$QUICKSTART_MODE" != "prod" ]; then
        die_usage "--contract-only is only supported for prod mode"
    fi
}

validate_full_flow_prereqs() {
    local missing=()

    if [ -z "${API_URL:-}" ]; then
        missing+=("API_URL")
    fi

    for key in \
        SES_FROM_ADDRESS \
        SES_REGION \
        INBOUND_ROUNDTRIP_S3_URI \
        INBOUND_ROUNDTRIP_RECIPIENT_DOMAIN; do
        if [ -z "${!key:-}" ]; then
            missing+=("$key")
        fi
    done

    # The reused customer-loop owner requires ADMIN_KEY for admin cleanup.
    # Either ADMIN_KEY or FLAPJACK_ADMIN_KEY satisfies the requirement.
    if [ -z "${ADMIN_KEY:-}" ] && [ -z "${FLAPJACK_ADMIN_KEY:-}" ]; then
        missing+=("ADMIN_KEY")
    fi

    if [ "${#missing[@]}" -gt 0 ]; then
        echo "ERROR: full-flow mode requires these env vars: ${missing[*]}" >&2
        echo "ERROR: use 'prod --contract-only' for non-destructive contract probes when full-flow prerequisites are unavailable" >&2
        return 1
    fi

    return 0
}

run_contract_only_probes() {
    local failures=0

    probe_success_endpoint "/health" || failures=$((failures + 1))
    probe_success_endpoint "/docs" || failures=$((failures + 1))

    probe_documented_method_contract POST "/auth/register" || failures=$((failures + 1))
    probe_documented_method_contract POST "/auth/verify-email" || failures=$((failures + 1))
    probe_documented_method_contract GET "/indexes" || failures=$((failures + 1))
    probe_documented_method_contract POST "/indexes" || failures=$((failures + 1))
    probe_documented_method_contract POST "/indexes/contract-check/batch" || failures=$((failures + 1))
    probe_documented_method_contract POST "/indexes/contract-check/search" || failures=$((failures + 1))
    probe_documented_method_contract GET "/indexes/contract-check/objects/contract-object" || failures=$((failures + 1))
    probe_documented_method_contract DELETE "/indexes/contract-check/objects/contract-object" || failures=$((failures + 1))
    probe_documented_method_contract PUT "/indexes/contract-check/synonyms/contract-synonym" || failures=$((failures + 1))
    probe_documented_method_contract PUT "/indexes/contract-check/rules/contract-rule" || failures=$((failures + 1))

    if [ "$failures" -gt 0 ]; then
        echo "ERROR: ${failures} contract probe(s) failed" >&2
        return 1
    fi

    log "prod --contract-only completed non-destructive contract checks; full-flow coverage intentionally skipped"
}

run_inbound_roundtrip() {
    local scripts_root="$1"
    local roundtrip_script="$scripts_root/validate_inbound_email_roundtrip.sh"

    if [ ! -f "$roundtrip_script" ]; then
        echo "ERROR: missing roundtrip validator at $roundtrip_script" >&2
        return 1
    fi

    bash "$roundtrip_script"
}

run_canary_step() {
    local step_function="$1"
    local step_name="$2"

    if ! declare -F "$step_function" >/dev/null; then
        mark_failure "$step_name" "canary owner does not export ${step_function}"
        return 1
    fi

    "$step_function"
}

expect_http_status() {
    local step_name="$1"
    local allowed_codes="$2"
    local code="${HTTP_RESPONSE_CODE:-}"

    if [[ " ${allowed_codes} " == *" ${code} "* ]]; then
        return 0
    fi

    mark_failure "$step_name" "${step_name} returned HTTP ${code:-unknown} body=${HTTP_RESPONSE_BODY:-<empty>}"
    return 1
}

assert_json_contains_index() {
    local step_name="$1"

    python3 - "$HTTP_RESPONSE_BODY" "$CANARY_INDEX_NAME" <<'PY' || {
import json
import sys

payload = json.loads(sys.argv[1])
index_name = sys.argv[2]
if not isinstance(payload, list):
    raise SystemExit(1)
for item in payload:
    if isinstance(item, dict) and item.get("name") == index_name:
        raise SystemExit(0)
raise SystemExit(1)
PY
        mark_failure "$step_name" "list indexes response did not include ${CANARY_INDEX_NAME}"
        return 1
    }
}

assert_json_object_id() {
    local step_name="$1"
    local expected_object_id="$2"

    python3 - "$HTTP_RESPONSE_BODY" "$expected_object_id" <<'PY' || {
import json
import sys

payload = json.loads(sys.argv[1])
expected_object_id = sys.argv[2]
if isinstance(payload, dict) and payload.get("objectID") == expected_object_id:
    raise SystemExit(0)
raise SystemExit(1)
PY
        mark_failure "$step_name" "response did not include objectID=${expected_object_id}"
        return 1
    }
}

assert_json_field_value() {
    local step_name="$1"
    local field_name="$2"
    local expected_value="$3"

    python3 - "$HTTP_RESPONSE_BODY" "$field_name" "$expected_value" <<'PY' || {
import json
import sys

payload = json.loads(sys.argv[1])
field_name = sys.argv[2]
expected_value = sys.argv[3]
if isinstance(payload, dict) and str(payload.get(field_name, "")) == expected_value:
    raise SystemExit(0)
raise SystemExit(1)
PY
        mark_failure "$step_name" "response did not include ${field_name}=${expected_value}"
        return 1
    }
}

assert_json_saved_id() {
    local step_name="$1"
    local expected_id="$2"

    python3 - "$HTTP_RESPONSE_BODY" "$expected_id" <<'PY' || {
import json
import sys

payload = json.loads(sys.argv[1])
expected_id = sys.argv[2]
if isinstance(payload, dict) and (
    payload.get("objectID") == expected_id or payload.get("id") == expected_id
):
    raise SystemExit(0)
raise SystemExit(1)
PY
        mark_failure "$step_name" "save response did not include id=${expected_id}"
        return 1
    }
}

assert_delete_object_success() {
    local step_name="$1"
    local expected_object_id="$2"

    python3 - "$HTTP_RESPONSE_BODY" "$expected_object_id" <<'PY' || {
import json
import sys

payload = json.loads(sys.argv[1] or "{}")
expected_object_id = sys.argv[2]
if not isinstance(payload, dict):
    raise SystemExit(1)

# The current route owner proxies flapjack's delete task payload, which carries
# `deletedAt`; the shell fixture uses `deleted: true` plus the objectID so tests
# can reject no-op deletes without depending on a timestamp string.
if "deletedAt" in payload or "taskID" in payload:
    raise SystemExit(0)
if payload.get("objectID") == expected_object_id and payload.get("deleted") is True:
    raise SystemExit(0)
raise SystemExit(1)
PY
        mark_failure "$step_name" "delete response did not prove objectID=${expected_object_id} was deleted"
        return 1
    }
}

search_response_has_hit() {
    local expected_object_id="$1"

    python3 - "$HTTP_RESPONSE_BODY" "$expected_object_id" <<'PY' || {
import json
import sys

payload = json.loads(sys.argv[1])
expected_object_id = sys.argv[2]
hits = payload.get("hits") if isinstance(payload, dict) else None
if not isinstance(hits, list):
    raise SystemExit(1)
for hit in hits:
    if isinstance(hit, dict) and hit.get("objectID") == expected_object_id:
        raise SystemExit(0)
raise SystemExit(1)
PY
        return 1
    }
}

assert_search_hit() {
    local step_name="$1"
    local expected_object_id="$2"

    search_response_has_hit "$expected_object_id" || {
        mark_failure "$step_name" "search response did not include objectID=${expected_object_id}"
        return 1
    }
}

assert_search_hit_with_retry() {
    local step_name="$1"
    local query_payload="$2"
    local expected_object_id="$3"
    local attempt

    for attempt in 1 2 3 4 5; do
        tenant_json_request "$step_name" POST "/indexes/${CANARY_INDEX_NAME}/search" "$query_payload" || return 1
        expect_http_status "$step_name" "200" || return 1
        if search_response_has_hit "$expected_object_id"; then
            return 0
        fi
        sleep 1
    done

    mark_failure "$step_name" "${step_name} did not return objectID=${expected_object_id} after retries"
    return 1
}

assert_batch_success() {
    local step_name="$1"

    python3 - "$HTTP_RESPONSE_BODY" <<'PY' || {
import json
import sys

payload = json.loads(sys.argv[1] or "{}")
if isinstance(payload, dict):
    if isinstance(payload.get("objectIDs"), list) or "taskID" in payload:
        raise SystemExit(0)
    results = payload.get("results")
    if isinstance(results, list) and results:
        for result in results:
            if not isinstance(result, dict):
                raise SystemExit(1)
            status = int(result.get("status", 200))
            if status < 200 or status >= 300:
                raise SystemExit(1)
        raise SystemExit(0)
raise SystemExit(1)
PY
        mark_failure "$step_name" "batch response did not include successful task or per-object result data"
        return 1
    }
}

tenant_json_request() {
    local step_name="$1"
    local method="$2"
    local path="$3"
    local payload="${4:-}"

    if [ -n "$payload" ]; then
        capture_json_response tenant_call "$method" "$path" "$CANARY_TOKEN" -d "$payload"
    else
        capture_json_response tenant_call "$method" "$path" "$CANARY_TOKEN"
    fi
    if [ "${HTTP_RESPONSE_EXIT_STATUS:-0}" != "0" ]; then
        mark_failure "$step_name" "${step_name} transport failed"
        return 1
    fi
}

log_migration_case_success() {
    local marker_id="$1"

    validator_log "migration case succeeded: ${marker_id}"
}

run_migration_list_indexes_case() {
    tenant_json_request "migration_indexes_list" GET "/indexes" || return 1
    expect_http_status "migration_indexes_list" "200" || return 1
    assert_json_contains_index "migration_indexes_list" || return 1
    log_migration_case_success "migration_indexes_list"
}

run_migration_batch_add_object_case() {
    local payload

    payload="$(printf '{"requests":[{"action":"addObject","body":{"objectID":%s,"title":"First"}},{"action":"addObject","body":{"objectID":%s,"title":"Second"}}]}' \
        "$(json_quote "${OBJECT_ID_PRIMARY:-obj-1}")" \
        "$(json_quote "${OBJECT_ID_SECONDARY:-obj-2}")")"
    tenant_json_request "migration_indexes_batch_add_object" POST "/indexes/${CANARY_INDEX_NAME}/batch" "$payload" || return 1
    expect_http_status "migration_indexes_batch_add_object" "200" || return 1
    assert_batch_success "migration_indexes_batch_add_object" || return 1
    log_migration_case_success "migration_indexes_batch_add_object"
}

run_migration_search_after_add_case() {
    local payload

    payload='{"query":"First"}'
    assert_search_hit_with_retry "migration_indexes_search" "$payload" "${OBJECT_ID_PRIMARY:-obj-1}" || return 1
    log_migration_case_success "migration_indexes_search"
}

run_migration_get_object_case() {
    tenant_json_request "migration_indexes_get_object" GET "/indexes/${CANARY_INDEX_NAME}/objects/${OBJECT_ID_PRIMARY:-obj-1}" || return 1
    expect_http_status "migration_indexes_get_object" "200" || return 1
    assert_json_object_id "migration_indexes_get_object" "${OBJECT_ID_PRIMARY:-obj-1}" || return 1
    assert_json_field_value "migration_indexes_get_object" "title" "First" || return 1
    log_migration_case_success "migration_indexes_get_object"
}

run_migration_batch_update_object_case() {
    local payload

    payload="$(printf '{"requests":[{"action":"updateObject","body":{"objectID":%s,"title":"First updated"}}]}' \
        "$(json_quote "${OBJECT_ID_PRIMARY:-obj-1}")")"
    tenant_json_request "migration_indexes_batch_update_object" POST "/indexes/${CANARY_INDEX_NAME}/batch" "$payload" || return 1
    expect_http_status "migration_indexes_batch_update_object" "200" || return 1
    assert_batch_success "migration_indexes_batch_update_object" || return 1
    assert_search_hit_with_retry "migration_indexes_batch_update_object_search" '{"query":"First updated"}' "${OBJECT_ID_PRIMARY:-obj-1}" || return 1
    log_migration_case_success "migration_indexes_batch_update_object"
}

run_migration_delete_object_case() {
    tenant_json_request "migration_indexes_delete_object" DELETE "/indexes/${CANARY_INDEX_NAME}/objects/${OBJECT_ID_SECONDARY:-obj-2}" || return 1
    expect_http_status "migration_indexes_delete_object" "200 202" || return 1
    assert_delete_object_success "migration_indexes_delete_object" "${OBJECT_ID_SECONDARY:-obj-2}" || return 1

    # The DELETE response proves the route accepted the operation; the refetch
    # proves the promised object is no longer readable through the fjcloud route.
    tenant_json_request "migration_indexes_delete_object_refetch" GET "/indexes/${CANARY_INDEX_NAME}/objects/${OBJECT_ID_SECONDARY:-obj-2}" || return 1
    if [ "${HTTP_RESPONSE_CODE:-}" != "404" ]; then
        mark_failure "migration_indexes_delete_object_refetch" "objectID=${OBJECT_ID_SECONDARY:-obj-2} was still readable after delete (http=${HTTP_RESPONSE_CODE:-unknown})"
        return 1
    fi
    log_migration_case_success "migration_indexes_delete_object"
}

run_migration_save_synonym_case() {
    local payload synonym_id="${SYNONYM_ID:-laptop-syn}"

    payload="$(printf '{"objectID":%s,"type":"synonym","synonyms":["laptop","notebook"]}' "$(json_quote "$synonym_id")")"
    tenant_json_request "migration_indexes_save_synonym" PUT "/indexes/${CANARY_INDEX_NAME}/synonyms/${synonym_id}" "$payload" || return 1
    expect_http_status "migration_indexes_save_synonym" "200 201" || return 1
    assert_json_saved_id "migration_indexes_save_synonym" "$synonym_id" || return 1
    log_migration_case_success "migration_indexes_save_synonym"
}

run_migration_save_rule_case() {
    local payload rule_id="${RULE_ID:-boost-shoes}"

    payload="$(printf '{"objectID":%s,"conditions":[{"pattern":"shoes","anchoring":"contains"}],"consequence":{"promote":[{"objectID":%s,"position":0}]},"description":"Boost shoes to top"}' \
        "$(json_quote "$rule_id")" \
        "$(json_quote "${OBJECT_ID_PRIMARY:-obj-1}")")"
    tenant_json_request "migration_indexes_save_rule" PUT "/indexes/${CANARY_INDEX_NAME}/rules/${rule_id}" "$payload" || return 1
    expect_http_status "migration_indexes_save_rule" "200 201" || return 1
    assert_json_saved_id "migration_indexes_save_rule" "$rule_id" || return 1
    log_migration_case_success "migration_indexes_save_rule"
}

run_quickstart_and_migration_sequence() {
    OBJECT_ID_PRIMARY="${OBJECT_ID_PRIMARY:-obj-1}"
    OBJECT_ID_SECONDARY="${OBJECT_ID_SECONDARY:-obj-2}"
    SYNONYM_ID="${SYNONYM_ID:-laptop-syn}"
    RULE_ID="${RULE_ID:-boost-shoes}"
    export OBJECT_ID_PRIMARY OBJECT_ID_SECONDARY SYNONYM_ID RULE_ID

    run_canary_step run_signup_step "auth_register" || return 1
    run_canary_step run_verify_email_step "auth_verify_email" || return 1
    run_canary_step run_index_create_step "indexes_create" || return 1
    log_migration_case_success "migration_indexes_create"
    run_canary_step run_index_batch_step "indexes_batch_add_object" || return 1
    run_canary_step run_index_search_step "indexes_search" || return 1

    run_migration_list_indexes_case || return 1
    run_migration_batch_add_object_case || return 1
    run_migration_search_after_add_case || return 1
    run_migration_get_object_case || return 1
    run_migration_batch_update_object_case || return 1
    run_migration_delete_object_case || return 1
    run_migration_save_synonym_case || return 1
    run_migration_save_rule_case || return 1

    run_canary_step run_delete_index_step "delete_index" || return 1
    run_canary_step run_delete_account_step "delete_account" || return 1
    run_canary_step run_admin_cleanup_step "admin_cleanup" || return 1
}

# TODO: Document run_signup_verify_search_flow.
run_signup_verify_search_flow() {
    local scripts_root="$1"
    local customer_loop_script="$scripts_root/canary/customer_loop_synthetic.sh"
    local flow_rc=0

    if [ ! -f "$customer_loop_script" ]; then
        echo "ERROR: missing customer loop owner at $customer_loop_script" >&2
        return 1
    fi

    # shellcheck disable=SC1090
    source "$customer_loop_script"

    load_canary_env
    # Bridge the validated roundtrip inbox contract into the reused canary owner
    # so roundtrip polling and verify-email read the same inbox target.
    CANARY_TEST_INBOX_DOMAIN="$INBOUND_ROUNDTRIP_RECIPIENT_DOMAIN"
    CANARY_TEST_INBOX_S3_URI="$INBOUND_ROUNDTRIP_S3_URI"
    export CANARY_TEST_INBOX_DOMAIN CANARY_TEST_INBOX_S3_URI
    CANARY_LIVE_MODE="0"
    export CANARY_LIVE_MODE

    run_quickstart_and_migration_sequence || flow_rc=$?
    cleanup_after_flow || true

    if [ "$flow_rc" -ne 0 ]; then
        echo "ERROR: customer quickstart flow failed at step '${FLOW_FAILURE_STEP:-unknown}': ${FLOW_FAILURE_DETAIL:-no detail}" >&2
        return 1
    fi

    log "customer quickstart signup/verify/search flow succeeded"
}

# TODO: Document main.
main() {
    local scripts_root

    parse_args "$@"
    load_validator_env
    resolve_doc_paths || exit "$EXIT_USAGE"
    validate_doc_marker_contracts || exit "$EXIT_RUNTIME"
    scripts_root="$(resolve_scripts_root)" || exit "$EXIT_USAGE"

    if [ "$QUICKSTART_MODE" = "prod" ] && [ "$QUICKSTART_CONTRACT_ONLY" -eq 1 ]; then
        run_contract_only_probes || exit "$EXIT_RUNTIME"
        exit 0
    fi

    if ! validate_full_flow_prereqs; then
        exit "$EXIT_USAGE"
    fi

    run_inbound_roundtrip "$scripts_root" || exit "$EXIT_RUNTIME"
    run_signup_verify_search_flow "$scripts_root" || exit "$EXIT_RUNTIME"

    log "${QUICKSTART_MODE} full-flow validation passed"
}

main "$@"
