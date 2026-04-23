#!/usr/bin/env bash
# stripe_webhook_replay_fixture.sh — deterministic local webhook replay fixture.
#
# Purpose:
# - Build a safe Stripe webhook payload/signature pair for local replay checks.
# - Keep check mode non-mutating (no curl calls).
# - Allow an explicit run mode for one-shot webhook POST verification.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=lib/validation_json.sh
source "$SCRIPT_DIR/lib/validation_json.sh"
# shellcheck source=lib/stripe_checks.sh
source "$SCRIPT_DIR/lib/stripe_checks.sh"

append_step() { validation_append_step "$@"; }
json_escape() { validation_json_escape "$1"; }

MODE="check"
TARGET_URL_OVERRIDE=""
TARGET_URL=""
TIMESTAMP_OVERRIDE=""
TIMESTAMP_VALUE=""
EVENT_ID_OVERRIDE=""
EVENT_ID_VALUE=""
PAYLOAD=""
SIGNATURE_HEADER=""
ENV_FILE=""

RESULT="passed"
CLASSIFICATION="ready"
SUMMARY_DETAIL="check completed without network calls"
EXIT_CODE=0

print_usage() {
    cat <<'USAGE' >&2
Usage:
  stripe_webhook_replay_fixture.sh [--check|--run] [--env-file <path>] [--target-url <url>] [--timestamp <unix-seconds>] [--event-id <id>]
  stripe_webhook_replay_fixture.sh --help

Modes:
  --check    Build deterministic webhook payload + signature only (default).
  --run      Build payload + signature and POST exactly once to target URL.
USAGE
}

set_outcome() {
    RESULT="$1"
    CLASSIFICATION="$2"
    SUMMARY_DETAIL="$3"
    EXIT_CODE="$4"
}

redact_text() {
    local text="$1"
    local secret="${STRIPE_WEBHOOK_SECRET:-}"

    python3 - "$text" "$secret" <<'PY'
import re
import sys

text = sys.argv[1]
secret = sys.argv[2]
if secret:
    text = text.replace(secret, "REDACTED")
text = re.sub(r"whsec_[A-Za-z0-9_]+", "REDACTED", text)
print(text, end="")
PY
}

redacted_secret_field() {
    if [ -z "${STRIPE_WEBHOOK_SECRET:-}" ]; then
        printf '<missing>'
        return 0
    fi
    printf 'REDACTED'
}

load_explicit_env_file() {
    if [ -z "$ENV_FILE" ]; then
        return 0
    fi

    if [ ! -f "$ENV_FILE" ]; then
        append_step "load_env_file" false "explicit env file is missing"
        set_outcome "blocked" "explicit_env_file_missing" "explicit --env-file path does not exist" 0
        return 1
    fi

    if [ ! -r "$ENV_FILE" ]; then
        append_step "load_env_file" false "explicit env file is not readable"
        set_outcome "failed" "explicit_env_file_unreadable" "explicit --env-file path is not readable" 1
        return 1
    fi

    local line="" line_number=0 parse_status=0
    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))
        parse_env_assignment_line "$line" && parse_status=0 || parse_status=$?
        if [ "$parse_status" -eq 0 ] || [ "$parse_status" -eq 2 ]; then
            continue
        fi

        append_step "load_env_file" false "explicit env file contains unsupported syntax"
        set_outcome "failed" "explicit_env_file_invalid" \
            "explicit --env-file contains unsupported KEY=value syntax at line ${line_number}" 1
        return 1
    done < "$ENV_FILE"

    load_env_file "$ENV_FILE"
    append_step "load_env_file" true "loaded explicit env file"
    return 0
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --check)
                MODE="check"
                shift
                ;;
            --run)
                MODE="run"
                shift
                ;;
            --target-url)
                if [ "$#" -lt 2 ]; then
                    append_step "parse_args" false "--target-url requires a value"
                    set_outcome "failed" "cli_argument_missing_value" "--target-url requires a value" 1
                    return 1
                fi
                TARGET_URL_OVERRIDE="$2"
                shift 2
                ;;
            --target-url=*)
                TARGET_URL_OVERRIDE="${1#--target-url=}"
                shift
                ;;
            --timestamp)
                if [ "$#" -lt 2 ]; then
                    append_step "parse_args" false "--timestamp requires a value"
                    set_outcome "failed" "cli_argument_missing_value" "--timestamp requires a value" 1
                    return 1
                fi
                TIMESTAMP_OVERRIDE="$2"
                shift 2
                ;;
            --timestamp=*)
                TIMESTAMP_OVERRIDE="${1#--timestamp=}"
                shift
                ;;
            --event-id)
                if [ "$#" -lt 2 ]; then
                    append_step "parse_args" false "--event-id requires a value"
                    set_outcome "failed" "cli_argument_missing_value" "--event-id requires a value" 1
                    return 1
                fi
                EVENT_ID_OVERRIDE="$2"
                shift 2
                ;;
            --event-id=*)
                EVENT_ID_OVERRIDE="${1#--event-id=}"
                shift
                ;;
            --env-file)
                if [ "$#" -lt 2 ]; then
                    append_step "parse_args" false "--env-file requires a path"
                    set_outcome "failed" "cli_argument_missing_value" "--env-file requires a path" 1
                    return 1
                fi
                ENV_FILE="$2"
                shift 2
                ;;
            --env-file=*)
                ENV_FILE="${1#--env-file=}"
                shift
                ;;
            --help)
                print_usage
                exit 0
                ;;
            *)
                append_step "parse_args" false "unknown argument: $1"
                set_outcome "failed" "cli_argument_unknown" "unknown argument: $1" 1
                return 1
                ;;
        esac
    done

    return 0
}

# TODO: Document resolve_target_url.
target_url_is_loopback() {
    python3 - "$1" <<'PY'
import ipaddress
import sys
from urllib.parse import urlparse

url = sys.argv[1]
hostname = urlparse(url).hostname
if not hostname:
    raise SystemExit(1)

try:
    if ipaddress.ip_address(hostname).is_loopback:
        raise SystemExit(0)
except ValueError:
    pass

if hostname == "localhost" or hostname.endswith(".localhost"):
    raise SystemExit(0)

raise SystemExit(1)
PY
}

resolve_target_url() {
    if [ -n "$TARGET_URL_OVERRIDE" ]; then
        TARGET_URL="$TARGET_URL_OVERRIDE"
    else
        TARGET_URL="$(stripe_webhook_forward_to)"
    fi

    if [[ ! "$TARGET_URL" =~ ^https?://[^[:space:]]+$ ]]; then
        append_step "resolve_target_url" false "target URL must be an absolute http(s) URL"
        set_outcome "failed" "target_url_invalid" "target URL must be absolute http(s)" 1
        return 1
    fi

    if [[ "$TARGET_URL" != */webhooks/stripe ]]; then
        append_step "resolve_target_url" false "target URL must end in /webhooks/stripe"
        set_outcome "failed" "target_url_invalid" "target URL must end in /webhooks/stripe" 1
        return 1
    fi

    if ! target_url_is_loopback "$TARGET_URL"; then
        append_step "resolve_target_url" false "target URL must resolve to a loopback host"
        set_outcome "failed" "target_url_invalid" "target URL must resolve to localhost or another loopback host" 1
        return 1
    fi

    append_step "resolve_target_url" true "resolved webhook target URL"
    return 0
}

resolve_timestamp_and_event_id() {
    if [ -n "$TIMESTAMP_OVERRIDE" ]; then
        if [[ ! "$TIMESTAMP_OVERRIDE" =~ ^[0-9]+$ ]]; then
            append_step "resolve_timestamp" false "timestamp must be a unix-seconds integer"
            set_outcome "failed" "timestamp_invalid" "timestamp must be unix seconds" 1
            return 1
        fi
        TIMESTAMP_VALUE="$TIMESTAMP_OVERRIDE"
    else
        TIMESTAMP_VALUE="$(date +%s)"
    fi

    if [ -n "$EVENT_ID_OVERRIDE" ]; then
        EVENT_ID_VALUE="$EVENT_ID_OVERRIDE"
    else
        EVENT_ID_VALUE="evt_replay_${TIMESTAMP_VALUE}"
    fi

    append_step "resolve_event" true "resolved event id and timestamp"
    return 0
}

build_payload() {
    PAYLOAD="$(python3 - "$EVENT_ID_VALUE" "$TIMESTAMP_VALUE" <<'PY'
import json
import sys

event_id = sys.argv[1]
timestamp = int(sys.argv[2])

payload = {
    "id": event_id,
    "type": "customer.updated",
    "created": timestamp,
    "data": {
        "object": {
            "id": "cus_replay_fixture"
        }
    }
}

print(json.dumps(payload, sort_keys=True, separators=(",", ":")))
PY
)"
    append_step "build_payload" true "built deterministic customer.updated payload"
}

validate_webhook_secret() {
    if [ -z "${STRIPE_WEBHOOK_SECRET:-}" ]; then
        append_step "require_webhook_secret" false "STRIPE_WEBHOOK_SECRET is required"
        set_outcome "blocked" "stripe_webhook_secret_missing" "STRIPE_WEBHOOK_SECRET is required for signature generation" 0
        return 1
    fi

    if [[ "$STRIPE_WEBHOOK_SECRET" != whsec_* ]]; then
        append_step "require_webhook_secret" false "STRIPE_WEBHOOK_SECRET must start with whsec_"
        set_outcome "failed" "stripe_webhook_secret_invalid" "STRIPE_WEBHOOK_SECRET must start with whsec_" 1
        return 1
    fi

    append_step "require_webhook_secret" true "webhook signing secret is present"
    return 0
}

generate_signature_header() {
    SIGNATURE_HEADER="$(python3 - "$TIMESTAMP_VALUE" "$PAYLOAD" "$STRIPE_WEBHOOK_SECRET" <<'PY'
import hashlib
import hmac
import sys

timestamp = sys.argv[1]
payload = sys.argv[2]
secret = sys.argv[3]

signed_payload = f"{timestamp}.{payload}".encode("utf-8")
signature = hmac.new(secret.encode("utf-8"), signed_payload, hashlib.sha256).hexdigest()
print(f"t={timestamp},v1={signature}")
PY
)"
    append_step "generate_signature" true "generated Stripe signature header"
}

post_webhook_once() {
    local response_file http_code curl_output curl_exit redacted_body redacted_error
    response_file="$(mktemp)"

    curl_exit=0
    if curl_output="$(curl -sS -o "$response_file" -w "%{http_code}" \
        -X POST "$TARGET_URL" \
        -H "Content-Type: application/json" \
        -H "Stripe-Signature: $SIGNATURE_HEADER" \
        --data "$PAYLOAD" 2>&1)"; then
        curl_exit=0
    else
        curl_exit=$?
    fi

    if [ "$curl_exit" -ne 0 ]; then
        redacted_error="$(redact_text "curl failed while posting webhook (exit $curl_exit): $curl_output")"
        append_step "post_webhook" false "$redacted_error"
        set_outcome "failed" "webhook_post_request_failed" "$redacted_error" 1
        rm -f "$response_file"
        return 1
    fi

    http_code="$curl_output"
    if [[ ! "$http_code" =~ ^[0-9]{3}$ ]]; then
        redacted_error="$(redact_text "curl did not return a valid HTTP status code")"
        append_step "post_webhook" false "$redacted_error"
        set_outcome "failed" "webhook_post_request_failed" "$redacted_error" 1
        rm -f "$response_file"
        return 1
    fi

    if [[ "$http_code" =~ ^2[0-9]{2}$ ]]; then
        append_step "post_webhook" true "webhook endpoint accepted replay payload"
        set_outcome "passed" "webhook_post_succeeded" "webhook endpoint returned HTTP ${http_code}" 0
        rm -f "$response_file"
        return 0
    fi

    redacted_body="$(redact_text "$(cat "$response_file" 2>/dev/null || true)")"
    append_step "post_webhook" false "webhook endpoint returned HTTP ${http_code}: ${redacted_body}"
    set_outcome "failed" "webhook_post_failed" "webhook endpoint returned HTTP ${http_code}: ${redacted_body}" 1
    rm -f "$response_file"
    return 1
}

emit_summary_json() {
    local elapsed_ms
    local result_json classification_json target_json secret_json event_id_json timestamp_json payload_json signature_json detail_json

    elapsed_ms=$(( $(validation_ms_now) - VALIDATION_START_MS ))
    result_json="$(json_escape "$RESULT")"
    classification_json="$(json_escape "$CLASSIFICATION")"
    target_json="$(json_escape "$TARGET_URL")"
    secret_json="$(json_escape "$(redacted_secret_field)")"
    event_id_json="$(json_escape "$EVENT_ID_VALUE")"
    timestamp_json="$(json_escape "$TIMESTAMP_VALUE")"
    payload_json="$(json_escape "$PAYLOAD")"
    signature_json="$(json_escape "$SIGNATURE_HEADER")"
    detail_json="$(json_escape "$(redact_text "$SUMMARY_DETAIL")")"

    printf '{"result":%s,"classification":%s,"mode":"%s","target_url":%s,"stripe_webhook_secret":%s,"event_id":%s,"timestamp":%s,"payload":%s,"stripe_signature":%s,"detail":%s,"steps":[%s],"elapsed_ms":%s}\n' \
        "$result_json" "$classification_json" "$MODE" "$target_json" "$secret_json" "$event_id_json" "$timestamp_json" "$payload_json" "$signature_json" "$detail_json" "$VALIDATION_STEPS_JSON" "$elapsed_ms"
}

main() {
    if ! parse_args "$@"; then
        emit_summary_json
        exit "$EXIT_CODE"
    fi

    if ! load_explicit_env_file; then
        emit_summary_json
        exit "$EXIT_CODE"
    fi

    if ! resolve_target_url; then
        emit_summary_json
        exit "$EXIT_CODE"
    fi

    if ! resolve_timestamp_and_event_id; then
        emit_summary_json
        exit "$EXIT_CODE"
    fi

    build_payload

    if ! validate_webhook_secret; then
        emit_summary_json
        exit "$EXIT_CODE"
    fi

    generate_signature_header

    if [ "$MODE" = "check" ]; then
        append_step "check_mode" true "check mode does not call curl"
        set_outcome "passed" "check_ready" "check completed without network calls" 0
    else
        post_webhook_once || true
    fi

    emit_summary_json
    exit "$EXIT_CODE"
}

main "$@"
