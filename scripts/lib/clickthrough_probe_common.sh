#!/usr/bin/env bash
# Shared helpers for auth-email clickthrough probes that prove the inbox path.
set -euo pipefail

CLICKTHROUGH_PROBE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CLICKTHROUGH_PROBE_LIB_DIR/env.sh"
source "$CLICKTHROUGH_PROBE_LIB_DIR/test_inbox_helpers.sh"

CLICKTHROUGH_S3_URI_DEFAULT="s3://flapjack-cloud-releases/e2e-emails/"
SSM_EXEC_STAGING_SCRIPT_DEFAULT="$CLICKTHROUGH_PROBE_LIB_DIR/../launch/ssm_exec_staging.sh"

probe_trim() {
    printf '%s' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

probe_sql_escape_literal() {
    printf '%s' "$1" | sed "s/'/''/g"
}

probe_env_file_maybe_load() {
    local env_file="${1:-}"
    if [[ -n "$env_file" && -f "$env_file" ]]; then
        load_layered_env_files "$env_file"
    fi
}

probe_materialize_app_base_url_from_staging_tool_env() {
    derive_staging_contract_env_aliases
    if [[ -z "${APP_BASE_URL:-}" && -n "${STAGING_CLOUD_URL:-}" ]]; then
        export APP_BASE_URL="$STAGING_CLOUD_URL"
    fi
    if [[ -z "${APP_BASE_URL:-}" ]]; then
        if ! hydrate_staging_tool_env_from_ssm staging; then
            echo "ERROR: staging tool env hydration failed while deriving APP_BASE_URL from STAGING_CLOUD_URL" >&2
            return 3
        fi
    fi
    if [[ -z "${APP_BASE_URL:-}" && -n "${STAGING_CLOUD_URL:-}" ]]; then
        export APP_BASE_URL="$STAGING_CLOUD_URL"
    fi
    if [[ -z "${APP_BASE_URL:-}" ]]; then
        echo "ERROR: staging tool env hydration did not produce STAGING_CLOUD_URL for APP_BASE_URL" >&2
        return 3
    fi
}

probe_post_json() {
    local api_url="$1"
    local route_path="$2"
    local json_payload="$3"

    local response http_code body
    response="$(
        curl -sS -w $'\n%{http_code}' \
            -H 'content-type: application/json' \
            -X POST \
            -d "$json_payload" \
            "${api_url%/}${route_path}" 2>&1
    )" || return 1
    http_code="$(printf '%s\n' "$response" | tail -n 1)"
    body="$(printf '%s\n' "$response" | sed '$d')"
    printf '%s\n%s\n' "$http_code" "$body"
}

probe_http_status() {
    local url="$1"
    curl -sSL -o /dev/null -w '%{http_code}' "$url"
}

probe_json_field() {
    local json_body="$1"
    local field="$2"
    python3 - "$json_body" "$field" <<'PY' || true
import json
import sys

body = sys.argv[1]
field = sys.argv[2]
try:
    payload = json.loads(body)
except Exception:
    print("")
    raise SystemExit(0)

value = payload.get(field, "")
if value is None:
    print("")
elif isinstance(value, bool):
    print("true" if value else "false")
else:
    print(str(value))
PY
}

probe_build_remote_sql_command() {
    local sql_query="$1"
    local escaped_sql
    escaped_sql="$(printf '%s' "$sql_query" | sed "s/'/'\"'\"'/g")"

    cat <<EOF
set -euo pipefail
if [[ -z "\${DATABASE_URL:-}" && -r /etc/fjcloud/env ]]; then
    source /etc/fjcloud/env
fi
if [[ -z "\${DATABASE_URL:-}" ]]; then
    echo "DATABASE_URL is required on staging host for clickthrough probe DB reads" >&2
    exit 1
fi
psql -X -t -A -v ON_ERROR_STOP=1 "\$DATABASE_URL" -c '$escaped_sql' | sed -n '1p'
EOF
}

probe_running_in_ssm_host_context() {
    [[ -n "${AWS_SSM_INSTANCE_ID:-}" ]]
}

probe_sql_single_value() {
    local sql_query="$1"
    local ssm_exec_script remote_command

    if probe_running_in_ssm_host_context && [[ -n "${DATABASE_URL:-}" ]] && command -v psql >/dev/null 2>&1; then
        psql -X -t -A -v ON_ERROR_STOP=1 "$DATABASE_URL" -c "$sql_query" | sed -n '1p'
        return $?
    fi

    ssm_exec_script="${PROBE_SSM_EXEC_STAGING_SCRIPT:-$SSM_EXEC_STAGING_SCRIPT_DEFAULT}"
    if [[ ! -x "$ssm_exec_script" ]]; then
        echo "ERROR: missing executable staging SSM exec script: $ssm_exec_script" >&2
        return 1
    fi

    remote_command="$(probe_build_remote_sql_command "$sql_query")" || return 1
    "$ssm_exec_script" "$remote_command"
}

probe_assert_customer_visible_or_wrong_db() {
    local customer_id="$1"
    local probe_email="$2"
    local escaped_customer_id visibility_sql visibility_output visibility_marker

    escaped_customer_id="$(probe_sql_escape_literal "$customer_id")"
    # 2026-07-12 postmortem: distinguish wrong staging DB visibility from product mutation failures.
    visibility_sql="SELECT CASE WHEN EXISTS (SELECT 1 FROM customers WHERE id = '${escaped_customer_id}') THEN 'present' ELSE 'absent' END;"
    if visibility_output="$(probe_sql_single_value "$visibility_sql" 2>&1)"; then
        visibility_marker="$(probe_trim "$visibility_output")"
    else
        local visibility_status=$?
        echo "ERROR: failed reading customer visibility control for probe_email=$probe_email customer_id=$customer_id" >&2
        return "$visibility_status"
    fi

    if [[ "$visibility_marker" == "present" ]]; then
        return 0
    fi

    if [[ "$visibility_marker" == "absent" ]]; then
        echo "ERROR: probe_env_wrong_db customer row absent for probe_email=$probe_email customer_id=$customer_id" >&2
    else
        echo "ERROR: customer visibility control returned '$visibility_marker' for probe_email=$probe_email customer_id=$customer_id" >&2
    fi
    return 1
}

probe_required_env_value() {
    local var_name="$1"
    local value="${!var_name:-}"
    if [[ -z "$value" ]]; then
        return 1
    fi
    printf '%s\n' "$value"
}

probe_poll_rfc822_for_term() {
    local search_term="$1"
    local bucket prefix region max_attempts sleep_seconds object_key rfc822_payload

    parsed_s3="$(test_inbox_parse_s3_uri "${INBOUND_ROUNDTRIP_S3_URI:-$CLICKTHROUGH_S3_URI_DEFAULT}" 2>/dev/null)" || return 1
    IFS='|' read -r bucket prefix <<< "$parsed_s3"
    region="${SES_REGION:-}"
    max_attempts="${INBOUND_ROUNDTRIP_POLL_MAX_ATTEMPTS:-30}"
    sleep_seconds="${INBOUND_ROUNDTRIP_POLL_SLEEP_SEC:-2}"

    object_key="$(
        test_inbox_find_matching_object_key \
            "$bucket" \
            "$prefix" \
            "$search_term" \
            "$region" \
            "$max_attempts" \
            "$sleep_seconds"
    )" || return 1
    rfc822_payload="$(test_inbox_fetch_rfc822 "$bucket" "$object_key" "$region")" || return 1

    printf '%s\n%s\n' "$object_key" "$rfc822_payload"
}

probe_poll_rfc822_for_terms() {
    local primary_term="$1"
    local secondary_term="${2:-}"
    local bucket prefix region max_attempts sleep_seconds recent_keys_json key rfc822_payload

    parsed_s3="$(test_inbox_parse_s3_uri "${INBOUND_ROUNDTRIP_S3_URI:-$CLICKTHROUGH_S3_URI_DEFAULT}" 2>/dev/null)" || return 1
    IFS='|' read -r bucket prefix <<< "$parsed_s3"
    region="${SES_REGION:-}"
    max_attempts="${INBOUND_ROUNDTRIP_POLL_MAX_ATTEMPTS:-30}"
    sleep_seconds="${INBOUND_ROUNDTRIP_POLL_SLEEP_SEC:-2}"

    # Reuse the shared owner polling path to wait until this probe's unique
    # recipient nonce shows up in the inbox before scanning recent payloads for
    # the specific auth route fragment we expect.
    test_inbox_find_matching_object_key \
        "$bucket" \
        "$prefix" \
        "$primary_term" \
        "$region" \
        "$max_attempts" \
        "$sleep_seconds" >/dev/null

    recent_keys_json="$(test_inbox_list_recent_object_keys_json "$bucket" "$prefix" "$region" "25")" || return 1
    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        rfc822_payload="$(test_inbox_fetch_rfc822 "$bucket" "$key" "$region" 2>/dev/null || true)"
        [[ -n "$rfc822_payload" ]] || continue
        [[ "$rfc822_payload" == *"$primary_term"* ]] || continue
        if [[ -n "$secondary_term" && "$rfc822_payload" != *"$secondary_term"* ]]; then
            continue
        fi
        printf '%s\n%s\n' "$key" "$rfc822_payload"
        return 0
    done < <(python3 - "$recent_keys_json" <<'PY'
import json
import sys
for key in json.loads(sys.argv[1]):
    print(key)
PY
)

    return 1
}
