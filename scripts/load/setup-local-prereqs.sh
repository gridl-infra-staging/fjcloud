#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/env.sh
source "$SCRIPT_DIR/../lib/env.sh"

log() { echo "[load-setup] $*" >&2; }
die() { echo "[load-setup] ERROR: $*" >&2; exit 1; }

# Parse a KEY=value env file into the current shell environment. Silently
# skips if the file doesn't exist, so callers can point at optional overrides.
load_optional_env_file() {
    local env_file="$1"
    if [ ! -f "$env_file" ]; then
        return 0
    fi

    local line line_number=0 key value quote_char
    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))
        line="${line%$'\r'}"

        if [[ "$line" =~ ^[[:space:]]*$ ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi

        if ! [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            die "Unsupported syntax in ${env_file} at line ${line_number}; only KEY=value assignments are allowed"
        fi

        key="${BASH_REMATCH[2]}"
        value="${BASH_REMATCH[3]}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"

        if [ -n "$value" ]; then
            quote_char="${value:0:1}"
            if { [ "$quote_char" = "'" ] || [ "$quote_char" = '"' ]; } && [ "${value: -1}" = "$quote_char" ]; then
                value="${value:1:${#value}-2}"
            fi
        fi

        printf -v "$key" '%s' "$value"
        export "$key"
    done < "$env_file"
}

json_get() {
    local file_path="$1"
    local field_name="$2"
    python3 -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8"))[sys.argv[2]])' "$file_path" "$field_name"
}

json_string() {
    python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"
}

json_find_active_tenant_id_by_email() {
    local file_path="$1"
    local email="$2"
    python3 - "$file_path" "$email" <<'PY'
import json
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))
target_email = sys.argv[2]
for item in items:
    if item.get("email") == target_email and item.get("status") != "deleted":
        print(item.get("id", ""))
        break
PY
}

json_has_deleted_tenant_by_email() {
    local file_path="$1"
    local email="$2"
    python3 - "$file_path" "$email" <<'PY'
import json
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))
target_email = sys.argv[2]
for item in items:
    if item.get("email") == target_email and item.get("status") == "deleted":
        print("true")
        break
else:
    print("false")
PY
}

urlencode_path_component() {
    python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

require_http_url() {
    local var_name="$1"
    local url_value="$2"

    python3 - "$var_name" "$url_value" <<'PY'
import sys
from urllib.parse import urlparse

var_name, url_value = sys.argv[1:3]

if any(ch.isspace() for ch in url_value) or "\x00" in url_value:
    raise SystemExit(f"{var_name} must not contain whitespace or NUL bytes")

parsed = urlparse(url_value)
if parsed.scheme not in ("http", "https") or not parsed.netloc:
    raise SystemExit(f"{var_name} must be an absolute http(s) URL")
PY
}

derive_default_load_user_password() {
    local admin_key="$1"
    local email="$2"

    python3 - "$admin_key" "$email" <<'PY'
import hashlib
import sys

admin_key, email = sys.argv[1:3]
seed = f"load-harness:{email}:{admin_key}".encode("utf-8")
print(hashlib.sha256(seed).hexdigest())
PY
}

derive_rotated_load_user_email() {
    local email="$1"
    local local_part="${email%@*}"
    local domain_part="${email#*@}"
    local suffix="recreated-$(date +%s)-$$"

    if [ "$local_part" = "$email" ] || [ -z "$domain_part" ]; then
        printf '%s-%s' "$email" "$suffix"
        return 0
    fi

    printf '%s+%s@%s' "$local_part" "$suffix" "$domain_part"
}

api_request() {
    local method="$1"
    local url="$2"
    local body_file="$3"
    shift 3

    case "$method" in
        GET|POST|PUT|DELETE|PATCH)
            ;;
        *)
            die "Unsupported HTTP method: ${method}"
            ;;
    esac

    curl -sS -o "$body_file" -w '%{http_code}' --request "$method" --url "$url" "$@"
}

read_and_remove_file() {
    local file_path="$1"
    local content
    content="$(cat "$file_path")"
    rm -f "$file_path"
    printf '%s' "$content"
}

wait_for_healthcheck() {
    local service_name="$1"
    local base_url="$2"
    local max_wait="$3"
    local elapsed=0

    while [ "$elapsed" -lt "$max_wait" ]; do
        if curl -sf --url "${base_url}/health" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    die "${service_name} not reachable at ${base_url}/health after ${max_wait}s"
}

# Authenticate an existing user, retrying on 429 rate-limit responses.
# Returns the JWT on stdout; falls through to the registration path on
# any non-429 failure so the caller can create the account instead.
login_with_retry() {
    local email="$1"
    local password="$2"
    local attempt=0
    local max_attempts="${LOAD_SETUP_LOGIN_ATTEMPTS:-6}"

    while [ "$attempt" -lt "$max_attempts" ]; do
        local body_file
        body_file="$(mktemp)"
        local status
        local login_payload
        login_payload="$(printf '{"email":%s,"password":%s}' \
            "$(json_string "$email")" \
            "$(json_string "$password")")"
        status="$(
            api_request POST "${API_URL}/auth/login" "$body_file" \
                -H "Content-Type: application/json" \
                -d "$login_payload"
        )"

        if [ "$status" = "200" ]; then
            json_get "$body_file" token
            rm -f "$body_file"
            return 0
        fi

        if [ "$status" = "429" ]; then
            rm -f "$body_file"
            sleep 1
            attempt=$((attempt + 1))
            continue
        fi

        log "login returned HTTP ${status} for ${email}; continuing to registration path"
        rm -f "$body_file"
        return 1
    done

    die "login for ${email} stayed rate-limited after ${max_attempts} attempts"
}

# In local signoff runs, the canonical load user may survive across sessions
# even when ADMIN_KEY changes. Soft-delete that exact stale tenant so the
# harness can recreate a clean account with the current deterministic password.
delete_stale_user_by_email() {
    local email="$1"
    local allow_delete="${LOAD_SETUP_DELETE_STALE_USER:-1}"

    case "$allow_delete" in
        1|true|TRUE|yes|YES)
            ;;
        *)
            return 1
            ;;
    esac

    local tenants_body
    tenants_body="$(mktemp)"
    local tenants_status
    tenants_status="$(
        api_request GET "${API_URL}/admin/tenants" "$tenants_body" \
            -H "x-admin-key: ${ADMIN_KEY}"
    )"
    if [ "$tenants_status" != "200" ]; then
        rm -f "$tenants_body"
        return 1
    fi

    local tenant_id
    tenant_id="$(json_find_active_tenant_id_by_email "$tenants_body" "$email")"
    rm -f "$tenants_body"
    if [ -z "$tenant_id" ]; then
        return 1
    fi

    local delete_body
    delete_body="$(mktemp)"
    local delete_status
    delete_status="$(
        api_request DELETE "${API_URL}/admin/tenants/${tenant_id}" "$delete_body" \
            -H "x-admin-key: ${ADMIN_KEY}"
    )"

    case "$delete_status" in
        204|404)
            rm -f "$delete_body"
            log "Deleted stale load user ${email} after deterministic login failed"
            return 0
            ;;
        *)
            rm -f "$delete_body"
            return 1
            ;;
    esac
}

rotate_load_user_email_if_deleted_conflict() {
    local email="$1"
    local allow_rotate="${LOAD_SETUP_ROTATE_DELETED_USER_EMAIL:-1}"

    case "$allow_rotate" in
        1|true|TRUE|yes|YES)
            ;;
        *)
            return 1
            ;;
    esac

    local tenants_body
    tenants_body="$(mktemp)"
    local tenants_status
    tenants_status="$(
        api_request GET "${API_URL}/admin/tenants" "$tenants_body" \
            -H "x-admin-key: ${ADMIN_KEY}"
    )"
    if [ "$tenants_status" != "200" ]; then
        rm -f "$tenants_body"
        return 1
    fi

    local has_deleted_conflict
    has_deleted_conflict="$(json_has_deleted_tenant_by_email "$tenants_body" "$email")"
    rm -f "$tenants_body"
    if [ "$has_deleted_conflict" != "true" ]; then
        return 1
    fi

    LOAD_USER_EMAIL="$(derive_rotated_load_user_email "$email")"
    if [ "${LOAD_USER_PASSWORD_IS_EXPLICIT:-0}" != "1" ]; then
        LOAD_USER_PASSWORD="$(derive_default_load_user_password "$ADMIN_KEY" "$LOAD_USER_EMAIL")"
    fi

    log "Soft-deleted load user ${email} still reserves that email; rotating to ${LOAD_USER_EMAIL}"
    return 0
}

ensure_user() {
    local attempt=0
    local max_attempts="${LOAD_SETUP_REGISTER_ATTEMPTS:-6}"

    while [ "$attempt" -lt "$max_attempts" ]; do
        local register_payload
        register_payload="$(printf '{"name":%s,"email":%s,"password":%s}' \
            "$(json_string "$LOAD_USER_NAME")" \
            "$(json_string "$LOAD_USER_EMAIL")" \
            "$(json_string "$LOAD_USER_PASSWORD")")"
        local register_body
        register_body="$(mktemp)"
        local register_status
        register_status="$(
            api_request POST "${API_URL}/auth/register" "$register_body" \
                -H "Content-Type: application/json" \
                -d "$register_payload"
        )"

        case "$register_status" in
            201)
                ENSURED_JWT="$(json_get "$register_body" token)"
                rm -f "$register_body"
                return 0
                ;;
            409)
                rm -f "$register_body"
                local existing_user_token
                if ! existing_user_token="$(login_with_retry "$LOAD_USER_EMAIL" "$LOAD_USER_PASSWORD")"; then
                    if delete_stale_user_by_email "$LOAD_USER_EMAIL"; then
                        attempt=$((attempt + 1))
                        continue
                    fi
                    if rotate_load_user_email_if_deleted_conflict "$LOAD_USER_EMAIL"; then
                        attempt=$((attempt + 1))
                        continue
                    fi
                    die "user ${LOAD_USER_EMAIL} already exists but login failed; verify LOAD_USER_PASSWORD or remove the stale account"
                fi
                ENSURED_JWT="$existing_user_token"
                return 0
                ;;
            429)
                rm -f "$register_body"
                sleep 1
                attempt=$((attempt + 1))
                continue
                ;;
            *)
                local body
                body="$(read_and_remove_file "$register_body")"
                die "register returned HTTP ${register_status} for ${LOAD_USER_EMAIL}: ${body}"
                ;;
        esac
    done

    die "register for ${LOAD_USER_EMAIL} stayed rate-limited after ${max_attempts} attempts"
}

ensure_shared_plan() {
    local customer_id="$1"
    local body_file
    body_file="$(mktemp)"
    local status
    status="$(
        api_request PUT "${API_URL}/admin/tenants/${customer_id}" "$body_file" \
            -H "Content-Type: application/json" \
            -H "x-admin-key: ${ADMIN_KEY}" \
            -d '{"billing_plan":"shared"}'
    )"

    case "$status" in
        200|204)
            rm -f "$body_file"
            return 0
            ;;
        *)
            local body
            body="$(read_and_remove_file "$body_file")"
            die "failed to set shared billing plan for ${customer_id}: HTTP ${status}: ${body}"
            ;;
    esac
}

cleanup_prior_load_indexes() {
    local token="$1"
    local body_file
    body_file="$(mktemp)"
    local status
    status="$(
        api_request GET "${API_URL}/indexes" "$body_file" \
            -H "Authorization: Bearer ${token}"
    )"

    if [ "$status" != "200" ]; then
        local body
        body="$(read_and_remove_file "$body_file")"
        die "failed to list existing indexes for ${LOAD_USER_EMAIL}: HTTP ${status}: ${body}"
    fi

    local existing_names
    existing_names="$(
        python3 - "$body_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    indexes = json.load(fh)

for item in indexes:
    name = item.get("name", "")
    if name:
        print(name)
PY
    )"
    rm -f "$body_file"

    if [ -z "$existing_names" ]; then
        return 0
    fi

    local deleted_count=0
    local name
    while IFS= read -r name; do
        [ -n "$name" ] || continue

        local delete_body
        local encoded_name
        delete_body="$(mktemp)"
        encoded_name="$(urlencode_path_component "$name")"
        local delete_status
        delete_status="$(
            api_request DELETE "${API_URL}/indexes/${encoded_name}" "$delete_body" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer ${token}" \
                -d '{"confirm":true}'
        )"

        case "$delete_status" in
            204|404)
                deleted_count=$((deleted_count + 1))
                ;;
            *)
                local delete_payload
                delete_payload="$(read_and_remove_file "$delete_body")"
                die "failed to delete stale load index ${name}: HTTP ${delete_status}: ${delete_payload}"
                ;;
        esac
        rm -f "$delete_body"
    done <<< "$existing_names"

    log "Deleted ${deleted_count} stale load index(es) for ${LOAD_USER_EMAIL}"
}

ensure_index() {
    local token="$1"
    local body_file
    local index_payload
    body_file="$(mktemp)"
    index_payload="$(printf '{"name":%s,"region":%s}' \
        "$(json_string "$INDEX_NAME")" \
        "$(json_string "$LOAD_INDEX_REGION")")"
    local status
    status="$(
        api_request POST "${API_URL}/indexes" "$body_file" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${token}" \
            -d "$index_payload"
    )"

    case "$status" in
        200|201|409)
            rm -f "$body_file"
            return 0
            ;;
        *)
            local body
            body="$(read_and_remove_file "$body_file")"
            die "failed to create or reuse ${INDEX_NAME}: HTTP ${status}: ${body}"
            ;;
    esac
}

wait_for_index_search_ready() {
    local token="$1"
    local max_wait="${LOAD_SETUP_INDEX_WAIT_SEC:-20}"
    local elapsed=0
    local encoded_index_name
    local last_body=""
    local last_status=""
    encoded_index_name="$(urlencode_path_component "$INDEX_NAME")"

    while [ "$elapsed" -lt "$max_wait" ]; do
        local body_file
        body_file="$(mktemp)"
        local status
        status="$(
            api_request POST "${API_URL}/indexes/${encoded_index_name}/search" "$body_file" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer ${token}" \
                -d '{"query":"load"}'
        )"

        if [ "$status" = "200" ]; then
            rm -f "$body_file"
            return 0
        fi

        last_status="$status"
        last_body="$(read_and_remove_file "$body_file")"
        sleep 1
        elapsed=$((elapsed + 1))
    done

    die "index ${INDEX_NAME} was not search-ready for ${LOAD_USER_EMAIL} after ${max_wait}s (last HTTP ${last_status}: ${last_body})"
}

shell_export() {
    local name="$1"
    local value="$2"
    printf 'export %s=%q\n' "$name" "$value"
}

load_env_file "$REPO_ROOT/.env.local"

API_URL="${API_URL:-${BASE_URL:-http://127.0.0.1:3001}}"
BASE_URL="${BASE_URL:-$API_URL}"
ADMIN_KEY="${ADMIN_KEY:-}"
FLAPJACK_URL="${LOCAL_DEV_FLAPJACK_URL:-${FLAPJACK_URL:-http://127.0.0.1:${FLAPJACK_PORT:-7700}}}"
LOAD_USER_NAME="${LOAD_USER_NAME:-Local Load Harness}"
LOAD_USER_EMAIL="${LOAD_USER_EMAIL:-loadtest-signoff@example.com}"
LOAD_INDEX_REGION="${LOAD_INDEX_REGION:-us-east-1}"
INDEX_NAME="${INDEX_NAME:-load-harness-$(date +%s)-$$}"

[ -n "$ADMIN_KEY" ] || die "ADMIN_KEY is required; set it in .env.local or export it before running load setup"
LOAD_USER_PASSWORD_IS_EXPLICIT=0
if [ -n "${LOAD_USER_PASSWORD:-}" ]; then
    LOAD_USER_PASSWORD_IS_EXPLICIT=1
fi
LOAD_USER_PASSWORD="${LOAD_USER_PASSWORD:-$(derive_default_load_user_password "$ADMIN_KEY" "$LOAD_USER_EMAIL")}"

require_http_url API_URL "$API_URL" || die "API_URL must be an absolute http(s) URL without whitespace"
require_http_url BASE_URL "$BASE_URL" || die "BASE_URL must be an absolute http(s) URL without whitespace"
require_http_url FLAPJACK_URL "$FLAPJACK_URL" || die "FLAPJACK_URL must be an absolute http(s) URL without whitespace"

wait_for_healthcheck "API" "$API_URL" "${LOAD_SETUP_API_WAIT_SEC:-15}"
wait_for_healthcheck "Flapjack" "$FLAPJACK_URL" "${LOAD_SETUP_FLAPJACK_WAIT_SEC:-15}"

ENSURED_JWT=""
ensure_user
JWT="$ENSURED_JWT"

account_body="$(mktemp)"
account_status="$(
    api_request GET "${API_URL}/account" "$account_body" \
        -H "Authorization: Bearer ${JWT}"
)"
if [ "$account_status" != "200" ]; then
    account_payload="$(read_and_remove_file "$account_body")"
    die "failed to fetch account for ${LOAD_USER_EMAIL}: HTTP ${account_status}: ${account_payload}"
fi
CUSTOMER_ID="$(json_get "$account_body" id)"
rm -f "$account_body"

ensure_shared_plan "$CUSTOMER_ID"
cleanup_prior_load_indexes "$JWT"
ensure_index "$JWT"
wait_for_index_search_ready "$JWT"

log "Prepared local load user ${LOAD_USER_EMAIL} and index ${INDEX_NAME}"
shell_export BASE_URL "$BASE_URL"
shell_export API_URL "$API_URL"
shell_export ADMIN_KEY "$ADMIN_KEY"
shell_export JWT "$JWT"
shell_export INDEX_NAME "$INDEX_NAME"
shell_export LOAD_USER_EMAIL "$LOAD_USER_EMAIL"
