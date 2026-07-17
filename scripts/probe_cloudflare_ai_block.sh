#!/usr/bin/env bash
# Read-only Cloudflare AI-bot-protection probe.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/validation_json.sh"
source "$SCRIPT_DIR/lib/env.sh"

EXIT_USAGE=2
EXIT_RUNTIME=1

append_step() { validation_append_step "$@"; }
emit_result() { validation_emit_result "$@"; }

cloudflare_readback() {
    local zone_id="$1"
    curl -sS -K - <<EOF
write-out = "\nHTTP_STATUS:%{http_code}\n"
header = "X-Auth-Key: ${global_key}"
header = "X-Auth-Email: ${auth_email}"
header = "Content-Type: application/json"
url = "https://api.cloudflare.com/client/v4/zones/${zone_id}/bot_management"
EOF
}

usage_failure() {
    local detail="$1"
    append_step "readback" false "$detail"
    emit_result false
    exit "$EXIT_USAGE"
}

runtime_failure() {
    local detail="$1"
    append_step "readback" false "$detail"
    emit_result false
    exit "$EXIT_RUNTIME"
}

default_secret_file="${FJCLOUD_SECRET_FILE:-./.secret/.env.secret}"
load_env_file "$default_secret_file"

run_dir="${CLOUDFLARE_AI_BLOCK_RUN_DIR:-}"
output_path="${CLOUDFLARE_AI_BLOCK_OUTPUT_PATH:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run-dir)
            run_dir="$2"
            shift 2
            ;;
        --output-path)
            output_path="$2"
            shift 2
            ;;
        --help|-h)
            cat <<'EOF'
Usage: bash scripts/probe_cloudflare_ai_block.sh [--run-dir <dir>] [--output-path <file>]
EOF
            exit 0
            ;;
        *)
            usage_failure "Unsupported argument '$1'."
            ;;
    esac
done

if [[ -z "$run_dir" ]]; then
    run_dir="."
fi

if [[ -z "$output_path" ]]; then
    output_path="${run_dir%/}/cloudflare_ai_block_readback.txt"
fi

mkdir -p "$(dirname "$output_path")"

zone_id="${CLOUDFLARE_ZONE_ID_FLAPJACK_FOO:-${CLOUDFLARE_ZONE_ID:-}}"
global_key="${CLOUDFLARE_GLOBAL_API_KEY:-}"
auth_email="${CLOUDFLARE_X_Auth_Email:-}"

if [[ -z "$global_key" ]]; then
    usage_failure "Missing CLOUDFLARE_GLOBAL_API_KEY; Cloudflare X-Auth global-key readback requires it."
fi
if [[ -z "$auth_email" ]]; then
    usage_failure "Missing CLOUDFLARE_X_Auth_Email; Cloudflare X-Auth global-key readback requires it."
fi
if [[ -z "$zone_id" ]]; then
    usage_failure "Missing CLOUDFLARE_ZONE_ID_FLAPJACK_FOO (or CLOUDFLARE_ZONE_ID); cannot target the zone readback endpoint."
fi

curl_stderr_file="$(mktemp)"
cleanup() {
    rm -f "$curl_stderr_file"
}
trap cleanup EXIT

readback_raw="$(
    cloudflare_readback "$zone_id" 2>"$curl_stderr_file"
)" || {
    printf '%s\n' "${readback_raw:-}" > "$output_path"
    curl_error="$(tr '\n' ' ' < "$curl_stderr_file" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
    runtime_failure "Cloudflare readback request failed for zone '${zone_id}': ${curl_error:-curl transport error}."
}

printf '%s\n' "$readback_raw" > "$output_path"

http_status="$(printf '%s\n' "$readback_raw" | awk -F: '/^HTTP_STATUS:/{print $2}' | tail -n 1 | tr -d '\r')"
json_body="$(printf '%s\n' "$readback_raw" | sed '/^HTTP_STATUS:/d')"

if [[ -z "$http_status" ]]; then
    runtime_failure "Cloudflare readback missing HTTP_STATUS marker. raw_readback='${output_path}'."
fi

if [[ "$http_status" != "200" ]]; then
    runtime_failure "Cloudflare readback returned HTTP_STATUS:${http_status}. raw_readback='${output_path}'."
fi

parse_result="$(
    python3 - "$json_body" <<'PY'
import json
import sys

body = sys.argv[1]
try:
    data = json.loads(body)
except Exception:
    print("PARSE_ERROR")
    raise SystemExit(0)

if data.get("success") is not True:
    print("SUCCESS_FALSE")
    raise SystemExit(0)

result = data.get("result", {})
if not isinstance(result, dict):
    print("MISSING_AI")
    raise SystemExit(0)

value = result.get("ai_bots_protection")
if not isinstance(value, str) or not value:
    print("MISSING_AI")
    raise SystemExit(0)

print(f"OK:{value}")
PY
)"

case "$parse_result" in
    OK:*)
        ai_value="${parse_result#OK:}"
        append_step "readback" true "Cloudflare bot_management readback succeeded for zone '${zone_id}' with ai_bots_protection='${ai_value}'. raw_readback='${output_path}'. HTTP_STATUS:${http_status}."
        emit_result true
        exit 0
        ;;
    PARSE_ERROR)
        runtime_failure "Cloudflare readback JSON parsing failed. raw_readback='${output_path}'."
        ;;
    SUCCESS_FALSE)
        runtime_failure "Cloudflare readback returned success=false. raw_readback='${output_path}'. HTTP_STATUS:${http_status}."
        ;;
    MISSING_AI)
        runtime_failure "Cloudflare readback missing result.ai_bots_protection. raw_readback='${output_path}'. HTTP_STATUS:${http_status}."
        ;;
    *)
        runtime_failure "Cloudflare readback returned unexpected parse status '${parse_result}'. raw_readback='${output_path}'."
        ;;
esac
