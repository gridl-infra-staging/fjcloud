#!/usr/bin/env bash

algolia_import_probe_generate_secret() {
    python3 - <<'PY'
import secrets

print(secrets.token_urlsafe(32))
PY
}

algolia_import_probe_secure_temp_file() {
    local runtime_dir="$1"
    local path
    path="$(mktemp "$runtime_dir/file.XXXXXX")"
    chmod 600 "$path"
    printf '%s\n' "$path"
}

algolia_import_probe_curl_config_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

algolia_import_probe_write_header_config() {
    local path="$1"
    shift
    : > "$path"
    while [ "$#" -gt 0 ]; do
        printf 'header = "%s"\n' "$(algolia_import_probe_curl_config_escape "$1")" >> "$path"
        shift
    done
}

algolia_import_probe_write_json_file() {
    local path="$1"
    local payload="$2"
    python3 - "$path" "$payload" <<'PY'
import json
import sys

payload = json.loads(sys.argv[2])
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, separators=(",", ":"))
PY
}

algolia_import_probe_json_field() {
    local payload="$1"
    local field="$2"
    python3 - "$payload" "$field" <<'PY'
import json
import sys

value = json.loads(sys.argv[1])
for part in sys.argv[2].split("."):
    if not isinstance(value, dict) or part not in value:
        raise SystemExit(1)
    value = value[part]
if value is None:
    print("")
elif isinstance(value, bool):
    print(str(value).lower())
else:
    print(value)
PY
}

algolia_import_probe_safe_response_identifier() {
    local value="$1"
    [ "${#value}" -le 256 ] && [[ "$value" =~ ^[A-Za-z0-9_-]+$ ]]
}

algolia_import_probe_safe_header_value() {
    local value="$1"
    [ -n "$value" ] && [ "${#value}" -le 4096 ] \
        && [[ "$value" != *$'\r'* ]] && [[ "$value" != *$'\n'* ]]
}

algolia_import_probe_safe_opaque_token() {
    local value="$1"
    algolia_import_probe_safe_header_value "$value" && [[ "$value" != *\"* ]] \
        && [[ "$value" != *\\* ]]
}

algolia_import_probe_wait_for_algolia_task() {
    local index="$1"
    local task_id="$2"
    local task_status
    for _ in 1 2 3 4 5; do
        algolia_request "200 404" GET "/1/indexes/$index/task/$task_id" || return 1
        [ "$HTTP_STATUS" = "404" ] && return 0
        task_status="$(
            algolia_import_probe_json_field "$HTTP_BODY" status 2>/dev/null || true
        )"
        [ "$task_status" = "published" ] && return 0
        sleep 1
    done
    return 1
}

algolia_import_probe_delete_algolia_index() {
    local index="$1"
    local task_id
    algolia_request "200 204 404" DELETE "/1/indexes/$index" || return 1
    [ "$HTTP_STATUS" = "404" ] && return 0
    task_id="$(
        algolia_import_probe_json_field "$HTTP_BODY" taskID 2>/dev/null || true
    )"
    [ -n "$task_id" ] || return 0
    algolia_import_probe_safe_response_identifier "$task_id" || return 1
    algolia_import_probe_wait_for_algolia_task "$index" "$task_id"
}

algolia_import_probe_obtain_target_envelope() {
    local target_index="$1"
    local payload provider_token
    payload="$(secure_temp_file)"
    write_json_file "$payload" \
        "{\"phase\":\"provider\",\"mode\":\"create\",\"target\":{\"region\":\"us-east-1\",\"name\":\"$target_index\"}}"
    api_request "200" POST "/migration/algolia/destination-eligibility" "$payload" \
        || finish_action_required "endpoint_unavailable"
    provider_token="$(
        algolia_import_probe_json_field "$HTTP_BODY" eligibilityToken 2>/dev/null || true
    )"
    [ -n "$provider_token" ] || finish_action_required "inconclusive_evidence"
    algolia_import_probe_safe_opaque_token "$provider_token" \
        || finish_action_required "invalid_response_identifier"

    payload="$(secure_temp_file)"
    write_json_file "$payload" \
        "{\"phase\":\"target\",\"mode\":\"create\",\"target\":{\"region\":\"us-east-1\",\"name\":\"$target_index\"},\"eligibilityToken\":\"$provider_token\"}"
    api_request "200" POST "/migration/algolia/destination-eligibility" "$payload" \
        || finish_action_required "endpoint_unavailable"
    TARGET_TOKEN="$(
        algolia_import_probe_json_field "$HTTP_BODY" eligibilityToken 2>/dev/null || true
    )"
    [ -n "$TARGET_TOKEN" ] || finish_action_required "inconclusive_evidence"
    algolia_import_probe_safe_opaque_token "$TARGET_TOKEN" \
        || finish_action_required "invalid_response_identifier"
}

algolia_import_probe_wait_for_restricted_source_key() {
    local source_index="$1"
    local restricted_key="$2"
    local key_config attempt
    key_config="$(secure_temp_file)"
    algolia_import_probe_write_header_config "$key_config" \
        "X-Algolia-Application-Id: $ALGOLIA_APP_ID" \
        "X-Algolia-API-Key: $restricted_key"
    for attempt in 1 2 3 4 5; do
        curl_http "200 403 404" --config "$key_config" -X GET "$(algolia_url "/1/indexes/$source_index")" \
            || return 1
        [ "$HTTP_STATUS" = "200" ] && return 0
        [ "$attempt" = "5" ] || sleep 1
    done
    return 1
}

algolia_import_probe_load_algolia_secrets() {
    local secret_file="$1"
    local line line_number=0 parse_status
    ALGOLIA_APP_ID=""
    ALGOLIA_ADMIN_KEY=""
    [ -n "$secret_file" ] || return 1
    [ -f "$secret_file" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))
        parse_env_assignment_line "$line" && parse_status=0 || parse_status=$?
        case "$parse_status" in
            0)
                case "$ENV_ASSIGNMENT_KEY" in
                    ALGOLIA_APP_ID) ALGOLIA_APP_ID="$ENV_ASSIGNMENT_VALUE" ;;
                    ALGOLIA_ADMIN_KEY) ALGOLIA_ADMIN_KEY="$ENV_ASSIGNMENT_VALUE" ;;
                esac
                ;;
            2) ;;
            *) return 1 ;;
        esac
    done < "$secret_file"
    [ -n "$ALGOLIA_APP_ID" ] || return 1
    [ -n "$ALGOLIA_ADMIN_KEY" ] || return 1
    [ "${#ALGOLIA_APP_ID}" -le 128 ] && [[ "$ALGOLIA_APP_ID" =~ ^[A-Za-z0-9-]+$ ]] \
        || return 2
    algolia_import_probe_safe_header_value "$ALGOLIA_ADMIN_KEY" || return 2
}

algolia_import_probe_validate_flapjack_dev_dir() {
    local flapjack_dev_dir="$1"
    local contract_check="$2"
    local contract_status=0
    [ -n "$flapjack_dev_dir" ] || return 1
    [ -d "$flapjack_dev_dir" ] || return 1
    flapjack_source_root "$flapjack_dev_dir" >/dev/null 2>&1 || return 1
    [ -x "$contract_check" ] || return 2
    FLAPJACK_DEV_DIR="$flapjack_dev_dir" "$contract_check" --check >/dev/null 2>&1 \
        || contract_status=$?
    [ "$contract_status" -eq 0 ] && return 0
    [ "$contract_status" -eq 3 ] && return 3
    return 2
}
