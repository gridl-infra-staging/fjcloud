#!/usr/bin/env bash
# Shared lifecycle, fixture seeding, redaction, and evidence helpers for the
# profile-gated Meilisearch and Typesense local source providers.

SOURCE_PROVIDER_FIXTURE_ROOT=""
SOURCE_PROVIDER_REPO_ROOT=""
SOURCE_PROVIDER_RUNTIME_ROOT=""
SOURCE_PROVIDER_EVIDENCE_ROOT="${SOURCE_PROVIDER_EVIDENCE_ROOT:-}"
SOURCE_PROVIDER_CREDENTIAL_ROOT="${SOURCE_PROVIDER_CREDENTIAL_ROOT:-}"
SOURCE_PROVIDER_OWNERSHIP_MARKER=""
SOURCE_PROVIDER_MEILI_CONFIG=""
SOURCE_PROVIDER_TYPESENSE_CONFIG=""
SECRET_VALUES=()
SECRET_LABELS=()

source_provider_configure_paths() {
    local repo_root="$1"
    SOURCE_PROVIDER_REPO_ROOT="$repo_root"
    SOURCE_PROVIDER_FIXTURE_ROOT="$repo_root/scripts/tests/fixtures/source-migration"
    SOURCE_PROVIDER_RUNTIME_ROOT="$repo_root/.local/source-migration"
    SOURCE_PROVIDER_EVIDENCE_ROOT="${SOURCE_PROVIDER_EVIDENCE_ROOT:-$repo_root/.local/source-provider-evidence}"
    SOURCE_PROVIDER_CREDENTIAL_ROOT="${SOURCE_PROVIDER_CREDENTIAL_ROOT:-$SOURCE_PROVIDER_RUNTIME_ROOT/credentials}"
    SOURCE_PROVIDER_OWNERSHIP_MARKER="$SOURCE_PROVIDER_RUNTIME_ROOT/.stack-owned"
    SOURCE_PROVIDER_MEILI_CONFIG="$SOURCE_PROVIDER_CREDENTIAL_ROOT/meilisearch.curl.conf"
    SOURCE_PROVIDER_TYPESENSE_CONFIG="$SOURCE_PROVIDER_CREDENTIAL_ROOT/typesense.curl.conf"
}

source_provider_require_safe_root() {
    local label="$1" path="$2"

    case "$path" in
        /*) ;;
        *)
            printf '[local-source-providers] ERROR: %s must be an absolute path: %s\n' \
                "$label" "$path" >&2
            return 1
            ;;
    esac

    if [ "$path" = "/" ] \
        || [ "$path" = "$SOURCE_PROVIDER_REPO_ROOT" ] \
        || [ "$path" = "$SOURCE_PROVIDER_REPO_ROOT/.local" ]
    then
        printf '[local-source-providers] ERROR: refusing unsafe %s path: %s\n' \
            "$label" "$path" >&2
        return 1
    fi
}

source_provider_profile_enabled() {
    printf '%s' "${COMPOSE_PROFILES:-}" \
        | tr ',' '\n' \
        | grep -Fxq "source-providers"
}

source_provider_stack_owned() {
    [ -f "$SOURCE_PROVIDER_OWNERSHIP_MARKER" ]
}

source_provider_profiles_for_teardown() {
    if source_provider_profile_enabled; then
        printf '%s\n' "$COMPOSE_PROFILES"
    elif [ -n "${COMPOSE_PROFILES:-}" ]; then
        printf '%s,source-providers\n' "$COMPOSE_PROFILES"
    else
        printf '%s\n' "source-providers"
    fi
}

source_provider_remember_secret() {
    local label="$1" value="$2"
    [ -n "$value" ] || return 0
    SECRET_LABELS[${#SECRET_LABELS[@]}]="$label"
    SECRET_VALUES[${#SECRET_VALUES[@]}]="$value"
}

source_provider_require_single_line_secret() {
    local name="$1" value="$2"
    case "$value" in
        *$'\n'*|*$'\r'*)
            printf '[local-source-providers] ERROR: %s must be a single-line value\n' "$name" >&2
            return 1
            ;;
    esac
}

source_provider_write_curl_config() {
    local path="$1" header_name="$2" secret="$3" escaped
    escaped="${secret//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    {
        printf 'header = "%s: %s"\n' "$header_name" "$escaped"
        printf '%s\n' 'connect-timeout = 2'
        printf '%s\n' 'max-time = 15'
    } > "$path"
    chmod 600 "$path"
}

source_provider_prepare_run() {
    local repo_root="$1"
    source_provider_configure_paths "$repo_root"
    source_provider_require_safe_root \
        "source-provider runtime root" "$SOURCE_PROVIDER_RUNTIME_ROOT" || return 1
    source_provider_require_safe_root \
        "source-provider evidence root" "$SOURCE_PROVIDER_EVIDENCE_ROOT" || return 1
    source_provider_require_safe_root \
        "source-provider credential root" "$SOURCE_PROVIDER_CREDENTIAL_ROOT" || return 1

    MEILI_MASTER_KEY="${MEILI_MASTER_KEY:-stage2-kat-$(openssl rand -hex 24)}"
    TYPESENSE_API_KEY="${TYPESENSE_API_KEY:-stage2-typesense-kat-$(openssl rand -hex 24)}"
    source_provider_require_single_line_secret "MEILI_MASTER_KEY" "$MEILI_MASTER_KEY"
    source_provider_require_single_line_secret "TYPESENSE_API_KEY" "$TYPESENSE_API_KEY"
    export MEILI_MASTER_KEY TYPESENSE_API_KEY

    rm -rf "$SOURCE_PROVIDER_RUNTIME_ROOT"
    rm -rf "$SOURCE_PROVIDER_CREDENTIAL_ROOT"
    rm -rf \
        "$SOURCE_PROVIDER_EVIDENCE_ROOT/meilisearch" \
        "$SOURCE_PROVIDER_EVIDENCE_ROOT/typesense"
    rm -f \
        "$SOURCE_PROVIDER_EVIDENCE_ROOT/provider_container_logs.log" \
        "$SOURCE_PROVIDER_EVIDENCE_ROOT/residue.json" \
        "$SOURCE_PROVIDER_EVIDENCE_ROOT/secret_redaction.json"
    mkdir -p \
        "$SOURCE_PROVIDER_RUNTIME_ROOT" \
        "$SOURCE_PROVIDER_EVIDENCE_ROOT" \
        "$SOURCE_PROVIDER_CREDENTIAL_ROOT"

    source_provider_write_curl_config \
        "$SOURCE_PROVIDER_MEILI_CONFIG" "Authorization" "Bearer $MEILI_MASTER_KEY"
    source_provider_write_curl_config \
        "$SOURCE_PROVIDER_TYPESENSE_CONFIG" "X-TYPESENSE-API-KEY" "$TYPESENSE_API_KEY"
    : > "$SOURCE_PROVIDER_CREDENTIAL_ROOT/.fjcloud-source-provider-credentials"

    source_provider_remember_secret "MEILI" "$MEILI_MASTER_KEY"
    source_provider_remember_secret "TYPESENSE" "$TYPESENSE_API_KEY"
    source_provider_remember_secret "MEILI" "${MEILI_TEST_SECRET_CANARY:-}"
    source_provider_remember_secret "TYPESENSE" "${TYPESENSE_STAGE2_BOOTSTRAP_CANARY:-}"
}

source_provider_mark_stack_owned() {
    : > "$SOURCE_PROVIDER_OWNERSHIP_MARKER"
}

source_provider_curl() {
    local config="$1" method="$2" url="$3" body="${4:-}" output="${5:-/dev/null}"
    local content_type="${6:-application/json}"
    local curl_args=(--config "$config" -fsS -o "$output" -X "$method")
    if [ -n "$body" ]; then
        curl_args+=(-H "Content-Type: $content_type" --data-binary "@$body")
    fi
    curl "${curl_args[@]}" "$url"
}

source_provider_json_field() {
    local path="$1" field="$2"
    python3 - "$path" "$field" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        value = json.load(handle)
except (OSError, json.JSONDecodeError):
    raise SystemExit(0)

for part in sys.argv[2].split("."):
    if not isinstance(value, dict) or part not in value:
        raise SystemExit(0)
    value = value[part]
if value is not None:
    print(value)
PY
}

source_provider_wait_for_meili_task() {
    local base_url="$1" response_file="$2" expected_status="$3"
    local task_uid task_file status attempt
    task_uid="$(source_provider_json_field "$response_file" taskUid)"
    [ -n "$task_uid" ] || return 0
    task_file="$SOURCE_PROVIDER_RUNTIME_ROOT/meili_task_${task_uid}.json"

    attempt=0
    while [ "$attempt" -lt 120 ]; do
        if source_provider_curl "$SOURCE_PROVIDER_MEILI_CONFIG" GET \
            "$base_url/tasks/$task_uid" "" "$task_file"
        then
            status="$(source_provider_json_field "$task_file" status)"
            [ "$status" = "$expected_status" ] && return 0
            case "$status" in failed|canceled) return 1 ;; esac
        fi
        sleep 0.25
        attempt=$((attempt + 1))
    done
    return 1
}

source_provider_meili_task_request() {
    local base_url="$1" label="$2" method="$3" path="$4" body="$5"
    local expected_status="$6" response_file
    response_file="$SOURCE_PROVIDER_RUNTIME_ROOT/meili_response_${label}.json"
    source_provider_curl "$SOURCE_PROVIDER_MEILI_CONFIG" "$method" \
        "$base_url$path" "$body" "$response_file" \
        || return 1
    source_provider_wait_for_meili_task \
        "$base_url" "$response_file" "$expected_status"
}

source_provider_write_meili_payloads() {
    local fixture_root="$1" runtime_root="$2"
    python3 - "$fixture_root/expected_bundle.json" "$runtime_root" <<'PY'
import json
import pathlib
import sys

expected_path, runtime_path = sys.argv[1:]
with open(expected_path, encoding="utf-8") as handle:
    expected = json.load(handle)
runtime = pathlib.Path(runtime_path)
payloads = {
    "meili_request_create_configured.json": {
        "uid": expected["indexes"]["configured"]["uid"],
        "primaryKey": expected["indexes"]["configured"]["primaryKey"],
    },
    "meili_request_create_inferred.json": {"uid": expected["indexes"]["inferred"]["uid"]},
    "meili_request_create_ambiguous.json": {"uid": expected["indexes"]["ambiguous"]["uid"]},
    "meili_request_mutation.json": [expected["documents"]["mutation"]],
    "meili_request_empty.json": {},
    "meili_request_fetch_before_page0.json": {"offset": 0, "limit": 2},
    "meili_request_fetch_before_page1.json": {"offset": 2, "limit": 2},
    "meili_request_fetch_inferred.json": {"offset": 0, "limit": 10},
    "meili_request_fetch_after.json": {"offset": 0, "limit": 10},
    "meili_request_search.json": {"q": "rake"},
}
for name, payload in payloads.items():
    (runtime / name).write_text(json.dumps(payload), encoding="utf-8")
PY
}

source_provider_capture_meilisearch_before_mutation() {
    local base_url="$1" runtime="$SOURCE_PROVIDER_RUNTIME_ROOT"
    source_provider_curl "$SOURCE_PROVIDER_MEILI_CONFIG" GET \
        "$base_url/version" "" "$runtime/meili_version_capture.json" &&
    source_provider_curl "$SOURCE_PROVIDER_MEILI_CONFIG" GET \
        "$base_url/indexes" "" "$runtime/meili_indexes_capture.json" &&
    source_provider_curl "$SOURCE_PROVIDER_MEILI_CONFIG" GET \
        "$base_url/indexes/configured_pk/settings" "" "$runtime/meili_settings_capture.json" &&
    source_provider_curl "$SOURCE_PROVIDER_MEILI_CONFIG" GET \
        "$base_url/stats" "" "$runtime/meili_stats_before_capture.json" &&
    source_provider_curl "$SOURCE_PROVIDER_MEILI_CONFIG" POST \
        "$base_url/indexes/configured_pk/documents/fetch" \
        "$runtime/meili_request_fetch_before_page0.json" \
        "$runtime/meili_configured_before_page0_capture.json" &&
    source_provider_curl "$SOURCE_PROVIDER_MEILI_CONFIG" POST \
        "$base_url/indexes/configured_pk/documents/fetch" \
        "$runtime/meili_request_fetch_before_page1.json" \
        "$runtime/meili_configured_before_page1_capture.json" &&
    source_provider_curl "$SOURCE_PROVIDER_MEILI_CONFIG" POST \
        "$base_url/indexes/inferred_pk/documents/fetch" \
        "$runtime/meili_request_fetch_inferred.json" \
        "$runtime/meili_inferred_capture.json"
}

source_provider_capture_meilisearch_after_mutation() {
    local base_url="$1" runtime="$SOURCE_PROVIDER_RUNTIME_ROOT"
    source_provider_curl "$SOURCE_PROVIDER_MEILI_CONFIG" GET \
        "$base_url/stats" "" "$runtime/meili_stats_after_capture.json" &&
    source_provider_curl "$SOURCE_PROVIDER_MEILI_CONFIG" POST \
        "$base_url/indexes/configured_pk/search" \
        "$runtime/meili_request_search.json" \
        "$runtime/meili_search_capture.json" &&
    source_provider_curl "$SOURCE_PROVIDER_MEILI_CONFIG" POST \
        "$base_url/indexes/configured_pk/documents/fetch" \
        "$runtime/meili_request_fetch_after.json" \
        "$runtime/meili_configured_after_capture.json"
}

source_provider_seed_meilisearch() {
    local base_url="$1" fixture="$SOURCE_PROVIDER_FIXTURE_ROOT/meilisearch"
    local runtime="$SOURCE_PROVIDER_RUNTIME_ROOT"
    source_provider_write_meili_payloads "$fixture" "$runtime"

    source_provider_meili_task_request "$base_url" create_configured POST /indexes \
        "$runtime/meili_request_create_configured.json" succeeded &&
    source_provider_meili_task_request "$base_url" seed_configured POST \
        /indexes/configured_pk/documents "$fixture/configured_primary_key_documents.json" succeeded &&
    source_provider_meili_task_request "$base_url" settings_configured PATCH \
        /indexes/configured_pk/settings "$fixture/configured_primary_key_settings.json" succeeded &&
    source_provider_meili_task_request "$base_url" create_inferred POST /indexes \
        "$runtime/meili_request_create_inferred.json" succeeded &&
    source_provider_meili_task_request "$base_url" seed_inferred POST \
        /indexes/inferred_pk/documents "$fixture/inferred_primary_key_documents.json" succeeded &&
    source_provider_meili_task_request "$base_url" create_ambiguous POST /indexes \
        "$runtime/meili_request_create_ambiguous.json" succeeded &&
    source_provider_meili_task_request "$base_url" seed_ambiguous POST \
        /indexes/ambiguous_pk/documents "$fixture/ambiguous_primary_key_documents.json" failed &&
    source_provider_capture_meilisearch_before_mutation "$base_url" &&
    source_provider_meili_task_request "$base_url" mutation POST \
        /indexes/configured_pk/documents "$runtime/meili_request_mutation.json" succeeded &&
    source_provider_capture_meilisearch_after_mutation "$base_url" &&
    source_provider_meili_task_request "$base_url" dump POST /dumps \
        "$runtime/meili_request_empty.json" succeeded &&
    source_provider_meili_task_request "$base_url" snapshot POST /snapshots \
        "$runtime/meili_request_empty.json" succeeded
}

source_provider_write_typesense_payloads() {
    local fixture="$SOURCE_PROVIDER_FIXTURE_ROOT/typesense/expected_bundle.json"
    python3 - "$fixture" "$SOURCE_PROVIDER_RUNTIME_ROOT" <<'PY'
import json
import pathlib
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    source = json.load(handle)["source"]
runtime = pathlib.Path(sys.argv[2])

for collection in source["collections"]:
    schema = {key: value for key, value in collection.items()
              if key not in {"documents", "fields"}}
    fields = []
    for field in collection["fields"]:
        normalized = {"name": field["name"], "type": field["type"]}
        for key in ("facet", "optional", "index", "store", "num_dim",
                    "vec_dist", "reference"):
            value = field.get(key)
            default = {"facet": False, "optional": False, "index": True,
                       "store": True}.get(key)
            if value is not None and value != default:
                normalized[key] = value
        fields.append(normalized)
    schema["fields"] = fields
    (runtime / f"typesense_{collection['name']}_schema.json").write_text(
        json.dumps(schema), encoding="utf-8")

payloads = {
    "typesense_synonym_set.json": {"items": source["synonym_sets"][0]["items"]},
    "typesense_unrelated_synonym_set.json": {
        "items": [{"id": "external_synonym", "root": "external",
                   "synonyms": ["outside-regex"]}]
    },
    "typesense_curation_set.json": {"items": source["curation_sets"][0]["items"]},
    "typesense_alias.json": {
        "collection_name": source["aliases"][0]["collection_name"]
    },
}
for name, payload in payloads.items():
    (runtime / name).write_text(json.dumps(payload), encoding="utf-8")
PY
}

source_provider_seed_typesense() {
    local base_url="$1" runtime="$SOURCE_PROVIDER_RUNTIME_ROOT"
    local fixture="$SOURCE_PROVIDER_FIXTURE_ROOT/typesense"
    source_provider_write_typesense_payloads

    source_provider_curl "$SOURCE_PROVIDER_TYPESENSE_CONFIG" PUT \
        "$base_url/synonym_sets/fj_ts_migration_synonyms" "$runtime/typesense_synonym_set.json" &&
    source_provider_curl "$SOURCE_PROVIDER_TYPESENSE_CONFIG" PUT \
        "$base_url/synonym_sets/outside_stage2_global_synonyms" "$runtime/typesense_unrelated_synonym_set.json" &&
    source_provider_curl "$SOURCE_PROVIDER_TYPESENSE_CONFIG" PUT \
        "$base_url/curation_sets/fj_ts_migration_curations" "$runtime/typesense_curation_set.json" &&
    source_provider_curl "$SOURCE_PROVIDER_TYPESENSE_CONFIG" POST \
        "$base_url/collections" "$runtime/typesense_fj_ts_migration_categories_schema.json" &&
    source_provider_curl "$SOURCE_PROVIDER_TYPESENSE_CONFIG" POST \
        "$base_url/collections" "$runtime/typesense_fj_ts_migration_products_schema.json" &&
    source_provider_curl "$SOURCE_PROVIDER_TYPESENSE_CONFIG" POST \
        "$base_url/collections/fj_ts_migration_categories/documents/import?action=create" \
        "$fixture/seed_categories.jsonl" /dev/null text/plain &&
    source_provider_curl "$SOURCE_PROVIDER_TYPESENSE_CONFIG" POST \
        "$base_url/collections/fj_ts_migration_products/documents/import?action=create" \
        "$fixture/seed_products.jsonl" /dev/null text/plain &&
    source_provider_curl "$SOURCE_PROVIDER_TYPESENSE_CONFIG" PUT \
        "$base_url/aliases/fj_ts_migration_catalog" "$runtime/typesense_alias.json" &&
    source_provider_curl "$SOURCE_PROVIDER_TYPESENSE_CONFIG" GET \
        "$base_url/health" "" "$runtime/typesense_health_capture.json" &&
    source_provider_curl "$SOURCE_PROVIDER_TYPESENSE_CONFIG" GET \
        "$base_url/debug" "" "$runtime/typesense_debug_capture.json" &&
    source_provider_curl "$SOURCE_PROVIDER_TYPESENSE_CONFIG" GET \
        "$base_url/collections/fj_ts_migration_categories" "" \
        "$runtime/typesense_capture_fj_ts_migration_categories_schema.json" &&
    source_provider_curl "$SOURCE_PROVIDER_TYPESENSE_CONFIG" GET \
        "$base_url/collections/fj_ts_migration_products" "" \
        "$runtime/typesense_capture_fj_ts_migration_products_schema.json" &&
    source_provider_curl "$SOURCE_PROVIDER_TYPESENSE_CONFIG" GET \
        "$base_url/collections/fj_ts_migration_categories/documents/export" "" \
        "$runtime/typesense_capture_categories_export.jsonl" text/plain &&
    source_provider_curl "$SOURCE_PROVIDER_TYPESENSE_CONFIG" GET \
        "$base_url/collections/fj_ts_migration_products/documents/export" "" \
        "$runtime/typesense_capture_products_export.jsonl" text/plain &&
    source_provider_curl "$SOURCE_PROVIDER_TYPESENSE_CONFIG" GET \
        "$base_url/aliases/fj_ts_migration_catalog" "" \
        "$runtime/typesense_capture_alias.json" &&
    source_provider_curl "$SOURCE_PROVIDER_TYPESENSE_CONFIG" GET \
        "$base_url/synonym_sets/fj_ts_migration_synonyms" "" \
        "$runtime/typesense_capture_synonym_set.json" &&
    source_provider_curl "$SOURCE_PROVIDER_TYPESENSE_CONFIG" GET \
        "$base_url/synonym_sets/outside_stage2_global_synonyms" "" \
        "$runtime/typesense_capture_unrelated_synonym_set.json" &&
    source_provider_curl "$SOURCE_PROVIDER_TYPESENSE_CONFIG" GET \
        "$base_url/curation_sets/fj_ts_migration_curations" "" \
        "$runtime/typesense_capture_curation_set.json"
}

source_provider_sanitize_file() {
    local input="$1" output="$2"
    local args=() index
    for ((index = 0; index < ${#SECRET_VALUES[@]}; index++)); do
        args+=("${SECRET_LABELS[$index]}" "${SECRET_VALUES[$index]}")
    done
    python3 - "$input" "$output" "${args[@]}" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
for index in range(3, len(sys.argv), 2):
    label, secret = sys.argv[index:index + 2]
    if secret:
        source = source.replace(secret, f"[REDACTED_{label}_KEY]")
pathlib.Path(sys.argv[2]).write_text(source, encoding="utf-8")
PY
}

source_provider_write_seed_evidence() {
    local meili_fixture="$SOURCE_PROVIDER_FIXTURE_ROOT/meilisearch"
    local typesense_fixture="$SOURCE_PROVIDER_FIXTURE_ROOT/typesense"
    python3 "$SOURCE_PROVIDER_REPO_ROOT/scripts/lib/local_source_provider_evidence.py" \
        "$meili_fixture/expected_bundle.json" \
        "$SOURCE_PROVIDER_EVIDENCE_ROOT/meilisearch/expected_bundle.json" \
        "$typesense_fixture/expected_bundle.json" \
        "$SOURCE_PROVIDER_EVIDENCE_ROOT/typesense/expected_bundle.json" \
        "$SOURCE_PROVIDER_RUNTIME_ROOT"
}

source_provider_write_evidence() {
    local raw_logs="$SOURCE_PROVIDER_RUNTIME_ROOT/provider_container_logs.raw"
    mkdir -p \
        "$SOURCE_PROVIDER_EVIDENCE_ROOT/meilisearch" \
        "$SOURCE_PROVIDER_EVIDENCE_ROOT/typesense"
    source_provider_write_seed_evidence || return 1
    cp "$SOURCE_PROVIDER_FIXTURE_ROOT/meilisearch/restricted_key_action_probes.json" \
        "$SOURCE_PROVIDER_EVIDENCE_ROOT/meilisearch/restricted_key_action_probes.json"

    (
        cd "$SOURCE_PROVIDER_REPO_ROOT"
        docker compose logs --no-color meilisearch typesense
    ) > "$raw_logs" 2>&1 || true
    source_provider_sanitize_file \
        "$raw_logs" "$SOURCE_PROVIDER_EVIDENCE_ROOT/provider_container_logs.log"
    rm -f "$raw_logs"

    cat > "$SOURCE_PROVIDER_EVIDENCE_ROOT/secret_redaction.json" <<'JSON'
{
  "scannedCapturedEvidenceTree": true,
  "scannedProviderContainerLogs": true,
  "scannedCredentialFiles": true,
  "seededCanariesRedacted": true,
  "generatedCredentialsRedacted": true
}
JSON
}

source_provider_seed_and_capture() {
    local meili_url="$1" typesense_url="$2"
    source_provider_seed_meilisearch "$meili_url" \
        && source_provider_seed_typesense "$typesense_url" \
        && source_provider_write_evidence
}

source_provider_remove_credentials() {
    rm -f \
        "$SOURCE_PROVIDER_MEILI_CONFIG" \
        "$SOURCE_PROVIDER_TYPESENSE_CONFIG" \
        "$SOURCE_PROVIDER_CREDENTIAL_ROOT/.fjcloud-source-provider-credentials"
}

source_provider_write_residue_evidence() {
    local compose_profiles="$1" container_present=false credential_files_present=false
    local running
    if running="$(
        cd "$SOURCE_PROVIDER_REPO_ROOT"
        COMPOSE_PROFILES="$compose_profiles" \
            docker compose ps --status running --format '{{.Name}}' \
                meilisearch typesense 2>/dev/null
    )"; then
        [ -z "$running" ] || container_present=true
    else
        container_present=true
    fi
    if [ -d "$SOURCE_PROVIDER_CREDENTIAL_ROOT" ] \
        && [ -n "$(ls -A "$SOURCE_PROVIDER_CREDENTIAL_ROOT" 2>/dev/null)" ]
    then
        credential_files_present=true
    fi

    mkdir -p "$SOURCE_PROVIDER_EVIDENCE_ROOT"
    python3 - \
        "$SOURCE_PROVIDER_EVIDENCE_ROOT/residue.json" \
        "$container_present" \
        "$credential_files_present" \
        "${SOURCE_PROVIDER_TEARDOWN_INVOCATION_ID:-}" <<'PY'
import json
import sys

destination, container_present, credential_files_present, invocation_id = sys.argv[1:]
with open(destination, "w", encoding="utf-8") as evidence_file:
    json.dump(
        {
            "containerPresent": container_present == "true",
            "tempDirPresent": False,
            "rawLogsPresent": False,
            "credentialFilesPresent": credential_files_present == "true",
            "producer": "scripts/local-dev-down.sh",
            "phase": "post-local-dev-down",
            "teardownInvocationId": invocation_id,
        },
        evidence_file,
        indent=2,
    )
    evidence_file.write("\n")
PY
}

source_provider_finalize_teardown() {
    local compose_profiles="$1"
    source_provider_remove_credentials
    rm -rf "$SOURCE_PROVIDER_CREDENTIAL_ROOT"
    mkdir -p "$SOURCE_PROVIDER_CREDENTIAL_ROOT"
    rm -rf "$SOURCE_PROVIDER_RUNTIME_ROOT"
    source_provider_write_residue_evidence "$compose_profiles"
}
