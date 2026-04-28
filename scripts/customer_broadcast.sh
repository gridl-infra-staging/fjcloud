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
if [ -z "${API_URL:-}" ] || [ -z "${ADMIN_KEY:-}" ]; then
    load_env_file "$SECRET_FILE"
fi

[ -n "${API_URL:-}" ] || die "API_URL is required (export it or set it in ${SECRET_FILE})"
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
