#!/usr/bin/env bash
# support_email_deliverability.sh — canary wrapper over inbound roundtrip probe.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUNDTRIP_SCRIPT_DEFAULT="$SCRIPT_DIR/../validate_inbound_email_roundtrip.sh"
ALERT_LIB_DEFAULT="$SCRIPT_DIR/../lib/alert_dispatch.sh"

ROUNDTRIP_SCRIPT="${SUPPORT_EMAIL_ROUNDTRIP_SCRIPT:-$ROUNDTRIP_SCRIPT_DEFAULT}"
ALERT_LIB="${SUPPORT_EMAIL_ALERT_LIB:-$ALERT_LIB_DEFAULT}"

source "$ALERT_LIB"

SUPPORT_EMAIL_TIMEOUT_EXIT=21
SUPPORT_EMAIL_AUTH_FAILURE_EXIT=22

support_email_classify_roundtrip_failure() {
    local exit_code="$1"
    case "$exit_code" in
        "$SUPPORT_EMAIL_TIMEOUT_EXIT")
            printf 'timeout\n'
            ;;
        "$SUPPORT_EMAIL_AUTH_FAILURE_EXIT")
            printf 'auth_failure\n'
            ;;
        *)
            printf 'runtime\n'
            ;;
    esac
}

support_email_extract_failure_detail() {
    local roundtrip_output="$1"
    python3 - "$roundtrip_output" <<'PY' || true
import json
import sys

payload = sys.argv[1]
fallback = payload.strip().replace("\n", " ")
if not fallback:
    fallback = "No delegated output."

try:
    data = json.loads(payload)
except Exception:
    print(fallback)
    raise SystemExit(0)

for step in data.get("steps", []):
    if step.get("passed") is False:
        detail = str(step.get("detail", "")).strip()
        if detail:
            print(detail)
            raise SystemExit(0)

print(fallback)
PY
}

roundtrip_output=""
if roundtrip_output="$("$ROUNDTRIP_SCRIPT" 2>&1)"; then
    printf '%s\n' "$roundtrip_output"
    exit 0
else
    roundtrip_exit_code=$?
fi
printf '%s\n' "$roundtrip_output"

failure_classification="$(support_email_classify_roundtrip_failure "$roundtrip_exit_code")"
failure_detail="$(support_email_extract_failure_detail "$roundtrip_output")"

environment="${ENVIRONMENT:-unknown}"
nonce="support-email-deliverability-$(date -u +%Y%m%dT%H%M%SZ)-${RANDOM}"
slack_url="${SLACK_WEBHOOK_URL:-}"
discord_url="${DISCORD_WEBHOOK_URL:-}"

alert_title="[fjcloud canary ${environment}] Support email deliverability failed ${nonce}"
alert_message="Delegated roundtrip failed (classification=${failure_classification}, exit_code=${roundtrip_exit_code}). detail=${failure_detail}"

dispatch_exit_code=0
alert_dispatch_send_critical \
    "$slack_url" \
    "$discord_url" \
    "$alert_title" \
    "$alert_message" \
    "support_email_deliverability.sh" \
    "$nonce" \
    "$environment" || dispatch_exit_code=$?

if [[ "$dispatch_exit_code" -eq 1 ]]; then
    echo "WARN: support email deliverability alert not sent because no webhook URL is configured." >&2
elif [[ "$dispatch_exit_code" -eq 2 ]]; then
    echo "WARN: support email deliverability alert dispatch failed for one or more channels." >&2
fi

exit "$roundtrip_exit_code"
