#!/usr/bin/env bash
# customer_broadcast.sh — operator wrapper for POST /admin/broadcast

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_SECRET_FILE="$REPO_ROOT/.secret/.env.secret"

# shellcheck source=lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"

die() {
    echo "[customer-broadcast] ERROR: $*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Usage:
  scripts/customer_broadcast.sh --subject <text> [--html-body <html> | --html-body-file <path>] [--text-body <text> | --text-body-file <path>] [--dry-run | --live-send]
  scripts/customer_broadcast.sh --help

Notes:
  - Delivery is non-mutating by default (dry_run=true).
  - --live-send is the explicit opt-in to send emails.
  - API_URL and ADMIN_KEY are read from exported env vars first, then from FJCLOUD_SECRET_FILE or the repo default .secret/.env.secret.
USAGE
}

json_string() {
    python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"
}

http_response_status() {
    printf '%s\n' "$1" | tail -1
}

http_response_body() {
    printf '%s\n' "$1" | sed '$d'
}

trim_is_empty() {
    [ -z "${1//[[:space:]]/}" ]
}

env_file_value() {
    local env_file="$1"
    local requested_key="$2"
    local line line_number=0 parse_status

    [ -f "$env_file" ] || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))
        parse_env_assignment_line "$line" && parse_status=0 || parse_status=$?
        if [ "$parse_status" -eq 0 ]; then
            if [ "$ENV_ASSIGNMENT_KEY" = "$requested_key" ]; then
                printf '%s\n' "$ENV_ASSIGNMENT_VALUE"
                return 0
            fi
            continue
        fi

        if [ "$parse_status" -eq 2 ]; then
            continue
        fi

        die "unsupported syntax in ${env_file} at line ${line_number}; only KEY=value assignments are allowed"
    done < "$env_file"

    return 1
}

is_staging_admin_target() {
    local api_url="${1:-}"

    case "$api_url" in
        https://api.staging.*|http://api.staging.*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_shared_dev_checkout_secret_file() {
    local secret_file="$1"
    local secret_dir
    local canonical_secret_file

    secret_dir="$(dirname "$secret_file")"
    if ! canonical_secret_file="$(
        cd "$secret_dir" 2>/dev/null &&
            printf '%s/%s\n' "$(pwd -P)" "$(basename "$secret_file")"
    )"; then
        return 1
    fi

    case "$canonical_secret_file" in
        */gridl-infra-dev/fjcloud_dev/.secret/.env.secret)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

should_hydrate_staging_admin_key() {
    if [ "$ADMIN_KEY_EXPLICIT" = true ]; then
        return 1
    fi

    if is_staging_admin_target "$API_URL"; then
        return 0
    fi

    # The shared dev checkout secret file is an operator credential bundle, not
    # a reliable staging API contract. For the stage dry-run proof, hydrate
    # staging through the canonical SSM owner instead of sending a stale
    # file-provided admin key to the production host.
    if [ "$DRY_RUN" = true ] &&
        [ "$API_URL_EXPLICIT" = false ] &&
        is_shared_dev_checkout_secret_file "$SECRET_FILE"; then
        return 0
    fi

    return 1
}

hydrate_staging_admin_key_from_owner() {
    local hydrator="$SCRIPT_DIR/launch/hydrate_seeder_env_from_ssm.sh"
    local hydrated_admin_key
    local hydrated_api_url
    local hydrated_values
    local hydrated_env_file
    local secret_aws_access_key_id=""
    local secret_aws_secret_access_key=""
    local secret_aws_session_token=""
    local secret_aws_default_region=""
    local hydrator_env=(env)

    [ -f "$hydrator" ] || die "staging ADMIN_KEY hydration owner is missing: $hydrator"
    secret_aws_access_key_id="$(env_file_value "$SECRET_FILE" "AWS_ACCESS_KEY_ID" || true)"
    secret_aws_secret_access_key="$(env_file_value "$SECRET_FILE" "AWS_SECRET_ACCESS_KEY" || true)"
    secret_aws_session_token="$(env_file_value "$SECRET_FILE" "AWS_SESSION_TOKEN" || true)"
    secret_aws_default_region="$(env_file_value "$SECRET_FILE" "AWS_DEFAULT_REGION" || true)"

    if [ -n "$secret_aws_access_key_id" ] && [ -n "$secret_aws_secret_access_key" ]; then
        hydrator_env+=(
            -u AWS_PROFILE
            -u AWS_SESSION_TOKEN
            -u AWS_SECURITY_TOKEN
            "AWS_ACCESS_KEY_ID=$secret_aws_access_key_id"
            "AWS_SECRET_ACCESS_KEY=$secret_aws_secret_access_key"
        )
        if [ -n "$secret_aws_session_token" ]; then
            hydrator_env+=("AWS_SESSION_TOKEN=$secret_aws_session_token")
        fi
        if [ -n "$secret_aws_default_region" ]; then
            hydrator_env+=("AWS_DEFAULT_REGION=$secret_aws_default_region")
        fi
    fi

    # The staging API reads its admin key from SSM. When this wrapper targets
    # staging from a file-provided key, hydrate through the existing staging
    # tooling owner so stale local secret files cannot produce false 401s.
    hydrated_env_file="$(mktemp)"
    chmod 600 "$hydrated_env_file"
    if ! "${hydrator_env[@]}" bash "$hydrator" staging >"$hydrated_env_file" 2>/dev/null; then
        rm -f "$hydrated_env_file"
        die "failed to hydrate staging ADMIN_KEY via scripts/launch/hydrate_seeder_env_from_ssm.sh; configure AWS SSM access or export ADMIN_KEY explicitly"
    fi
    if ! hydrated_values="$(bash -c 'set -euo pipefail; source "$1"; printf "%s\n%s\n" "$ADMIN_KEY" "$API_URL"' _ "$hydrated_env_file" 2>/dev/null)"; then
        rm -f "$hydrated_env_file"
        die "failed to read hydrated staging ADMIN_KEY/API_URL from scripts/launch/hydrate_seeder_env_from_ssm.sh output"
    fi
    rm -f "$hydrated_env_file"
    hydrated_admin_key="$(printf '%s\n' "$hydrated_values" | sed -n '1p')"
    hydrated_api_url="$(printf '%s\n' "$hydrated_values" | sed -n '2p')"

    [ -n "$hydrated_admin_key" ] || die "staging ADMIN_KEY hydration returned an empty value"
    [ -n "$hydrated_api_url" ] || die "staging API_URL hydration returned an empty value"
    ADMIN_KEY="$hydrated_admin_key"
    export ADMIN_KEY
    if [ "$API_URL_EXPLICIT" = false ]; then
        API_URL="$hydrated_api_url"
        export API_URL
    fi
}

SUBJECT=""
HTML_BODY=""
TEXT_BODY=""
HTML_BODY_FILE=""
TEXT_BODY_FILE=""
HAS_HTML_BODY=false
HAS_TEXT_BODY=false
DRY_RUN=true
MODE_FLAG=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --subject)
            [ "$#" -ge 2 ] || die "--subject requires a value"
            SUBJECT="$2"
            shift 2
            ;;
        --html-body)
            [ "$#" -ge 2 ] || die "--html-body requires a value"
            HTML_BODY="$2"
            HAS_HTML_BODY=true
            shift 2
            ;;
        --html-body-file)
            [ "$#" -ge 2 ] || die "--html-body-file requires a path"
            HTML_BODY_FILE="$2"
            shift 2
            ;;
        --text-body)
            [ "$#" -ge 2 ] || die "--text-body requires a value"
            TEXT_BODY="$2"
            HAS_TEXT_BODY=true
            shift 2
            ;;
        --text-body-file)
            [ "$#" -ge 2 ] || die "--text-body-file requires a path"
            TEXT_BODY_FILE="$2"
            shift 2
            ;;
        --dry-run)
            [ "$MODE_FLAG" != "live_send" ] || die "--dry-run cannot be combined with --live-send"
            MODE_FLAG="dry_run"
            DRY_RUN=true
            shift
            ;;
        --live-send)
            [ "$MODE_FLAG" != "dry_run" ] || die "--live-send cannot be combined with --dry-run"
            MODE_FLAG="live_send"
            DRY_RUN=false
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1 (use --help for usage)"
            ;;
    esac
done

trim_is_empty "$SUBJECT" && die "--subject is required"

if [ -n "$HTML_BODY_FILE" ] && [ "$HAS_HTML_BODY" = true ]; then
    die "--html-body and --html-body-file cannot be combined"
fi
if [ -n "$TEXT_BODY_FILE" ] && [ "$HAS_TEXT_BODY" = true ]; then
    die "--text-body and --text-body-file cannot be combined"
fi

if [ -n "$HTML_BODY_FILE" ]; then
    [ -r "$HTML_BODY_FILE" ] || die "HTML body file is not readable: $HTML_BODY_FILE"
    HTML_BODY="$(cat "$HTML_BODY_FILE")"
    HAS_HTML_BODY=true
fi
if [ -n "$TEXT_BODY_FILE" ]; then
    [ -r "$TEXT_BODY_FILE" ] || die "Text body file is not readable: $TEXT_BODY_FILE"
    TEXT_BODY="$(cat "$TEXT_BODY_FILE")"
    HAS_TEXT_BODY=true
fi

if [ "$HAS_HTML_BODY" = false ] && [ "$HAS_TEXT_BODY" = false ]; then
    die "one body input is required (--html-body/--html-body-file or --text-body/--text-body-file)"
fi

if [ "$HAS_HTML_BODY" = true ] && trim_is_empty "$HTML_BODY"; then
    die "html body must not be empty"
fi
if [ "$HAS_TEXT_BODY" = true ] && trim_is_empty "$TEXT_BODY"; then
    die "text body must not be empty"
fi

SECRET_FILE="${FJCLOUD_SECRET_FILE:-$DEFAULT_SECRET_FILE}"
EXPLICIT_ENV_SNAPSHOT="$(export -p)"
ADMIN_KEY_EXPLICIT=false
API_URL_EXPLICIT=false
if env_snapshot_has_exported_var "$EXPLICIT_ENV_SNAPSHOT" "ADMIN_KEY"; then
    ADMIN_KEY_EXPLICIT=true
fi
if env_snapshot_has_exported_var "$EXPLICIT_ENV_SNAPSHOT" "API_URL"; then
    API_URL_EXPLICIT=true
fi

if [ -z "${API_URL:-}" ] || [ -z "${ADMIN_KEY:-}" ]; then
    load_env_file "$SECRET_FILE"
fi

[ -n "${API_URL:-}" ] || die "API_URL is required (export it or set it in ${SECRET_FILE})"
if should_hydrate_staging_admin_key; then
    hydrate_staging_admin_key_from_owner
fi
[ -n "${ADMIN_KEY:-}" ] || die "ADMIN_KEY is required (export it or set it in ${SECRET_FILE})"

payload_fields="\"subject\":$(json_string "$SUBJECT"),\"dry_run\":${DRY_RUN}"
if [ "$HAS_HTML_BODY" = true ]; then
    payload_fields+=",\"html_body\":$(json_string "$HTML_BODY")"
fi
if [ "$HAS_TEXT_BODY" = true ]; then
    payload_fields+=",\"text_body\":$(json_string "$TEXT_BODY")"
fi
payload="{${payload_fields}}"

api_base="${API_URL%/}"
endpoint="${api_base}/admin/broadcast"
response="$(curl -sS -X POST "$endpoint" \
    -H "Content-Type: application/json" \
    -H "x-admin-key: ${ADMIN_KEY}" \
    -d "$payload" \
    -w '\n%{http_code}' || true)"
http_status="$(http_response_status "$response")"
http_body="$(http_response_body "$response")"

if [ "$http_status" != "200" ]; then
    printf '%s\n' "$http_body"
    die "broadcast request failed with HTTP ${http_status}"
fi

printf '%s\n' "$http_body"
