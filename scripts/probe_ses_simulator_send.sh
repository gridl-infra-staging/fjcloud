#!/usr/bin/env bash
# Send-only SES mailbox simulator probe for bounce/complaint proof.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/validation_json.sh"
source "$SCRIPT_DIR/lib/test_inbox_helpers.sh"

EXIT_USAGE=2
EXIT_RUNTIME=1

append_step() { validation_append_step "$@"; }
emit_result() { validation_emit_result "$@"; }
json_get_field() { validation_json_get_field "$@"; }

usage_failure() {
    local detail="$1"
    append_step "send_probe" false "$detail"
    emit_result false
    exit "$EXIT_USAGE"
}

runtime_failure() {
    local detail="$1"
    append_step "send_probe" false "$detail"
    emit_result false
    exit "$EXIT_RUNTIME"
}

send_stderr_file="$(mktemp)"
cleanup() {
    rm -f "$send_stderr_file"
}
trap cleanup EXIT

mode="${1:-}"
if [[ -z "$mode" ]]; then
    usage_failure "missing required mode argument. Usage: bash scripts/probe_ses_simulator_send.sh <bounce|complaint>."
fi

recipient_address=""
case "$mode" in
    bounce)
        recipient_address="bounce@simulator.amazonses.com"
        ;;
    complaint)
        recipient_address="complaint@simulator.amazonses.com"
        ;;
    *)
        usage_failure "Invalid mode '$mode'. Expected one of: bounce, complaint."
        ;;
esac

from_address="${SES_FROM_ADDRESS:-}"
region="${SES_REGION:-}"

if ! test_inbox_require_nonempty "$from_address" "SES_FROM_ADDRESS" >/dev/null 2>&1; then
    usage_failure "Missing SES_FROM_ADDRESS; set sender identity before running simulator probe."
fi
if ! test_inbox_require_nonempty "$region" "SES_REGION" >/dev/null 2>&1; then
    usage_failure "Missing SES_REGION; set SES region before running simulator probe."
fi

nonce="$(test_inbox_generate_nonce)"
subject="fjcloud SES simulator send probe mode=$mode nonce=$nonce"
body="SES simulator send probe mode=$mode nonce=$nonce"

if ! send_json="$(test_inbox_send_probe_email "$from_address" "$recipient_address" "$region" "$subject" "$body" 2>"$send_stderr_file")"; then
    send_error_detail="$(tr '\n' ' ' < "$send_stderr_file" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
    if [[ -n "$send_error_detail" ]]; then
        runtime_failure "aws sesv2 send-email failed for mode '$mode' recipient '$recipient_address': $send_error_detail"
    fi
    runtime_failure "aws sesv2 send-email failed for mode '$mode' recipient '$recipient_address'."
fi

message_id="$(json_get_field "$send_json" "MessageId")"
if [[ -z "$message_id" ]]; then
    runtime_failure "aws sesv2 send-email response missing MessageId for mode '$mode' recipient '$recipient_address'."
fi

append_step "send_probe" true "Sent simulator probe mode '$mode' from '$from_address' to '$recipient_address' (message_id='${message_id}')."
emit_result true
exit 0
