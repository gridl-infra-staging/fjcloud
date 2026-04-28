#!/usr/bin/env bash
# Validate SES outbound-to-inbound roundtrip for the shared test inbox path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/validation_json.sh"
source "$SCRIPT_DIR/lib/test_inbox_helpers.sh"

EXIT_USAGE=2
EXIT_TIMEOUT=21
EXIT_AUTH_FAILURE=22
EXIT_RUNTIME=1

ROUNDTRIP_PARSER="$SCRIPT_DIR/lib/parse_inbound_auth_headers.py"
ROUNDTRIP_S3_URI_DEFAULT="s3://flapjack-cloud-releases/e2e-emails/"
ROUNDTRIP_RECIPIENT_DOMAIN_DEFAULT="test.flapjack.foo"

append_step() { validation_append_step "$@"; }
emit_result() { validation_emit_result "$@"; }
json_get_field() { validation_json_get_field "$@"; }

emit_usage_failure() {
    local detail="$1"
    append_step "send_probe" false "$detail"
    append_step "poll_inbox_s3" false "Skipped because send_probe preconditions failed."
    append_step "fetch_rfc822" false "Skipped because send_probe preconditions failed."
    append_step "auth_verdict" false "Skipped because send_probe preconditions failed."
    emit_result false
    exit "$EXIT_USAGE"
}

if [[ ! -f "$ROUNDTRIP_PARSER" ]]; then
    append_step "send_probe" false "Parser script not found at $ROUNDTRIP_PARSER."
    append_step "poll_inbox_s3" false "Skipped because parser precondition failed."
    append_step "fetch_rfc822" false "Skipped because parser precondition failed."
    append_step "auth_verdict" false "Skipped because parser precondition failed."
    emit_result false
    exit "$EXIT_RUNTIME"
fi

from_address="${SES_FROM_ADDRESS:-}"
region="${SES_REGION:-}"
s3_uri="${INBOUND_ROUNDTRIP_S3_URI:-$ROUNDTRIP_S3_URI_DEFAULT}"
poll_max_attempts="${INBOUND_ROUNDTRIP_POLL_MAX_ATTEMPTS:-30}"
poll_sleep_sec="${INBOUND_ROUNDTRIP_POLL_SLEEP_SEC:-2}"
nonce="${INBOUND_ROUNDTRIP_NONCE:-$(test_inbox_generate_nonce)}"
recipient_domain="${INBOUND_ROUNDTRIP_RECIPIENT_DOMAIN:-$ROUNDTRIP_RECIPIENT_DOMAIN_DEFAULT}"
recipient_local_part="${INBOUND_ROUNDTRIP_RECIPIENT_LOCALPART:-roundtrip-$nonce}"
recipient_address="${recipient_local_part}@${recipient_domain}"

if ! test_inbox_require_nonempty "$from_address" "SES_FROM_ADDRESS" >/dev/null 2>&1; then
    emit_usage_failure "Missing SES_FROM_ADDRESS; set sender identity before running roundtrip."
fi
if ! test_inbox_require_nonempty "$region" "SES_REGION" >/dev/null 2>&1; then
    emit_usage_failure "Missing SES_REGION; set SES region before running roundtrip."
fi
if ! test_inbox_require_nonempty "$nonce" "nonce" >/dev/null 2>&1; then
    emit_usage_failure "Generated nonce is empty; roundtrip cannot proceed."
fi

if ! parsed_s3="$(test_inbox_parse_s3_uri "$s3_uri" 2>/dev/null)"; then
    emit_usage_failure "Invalid INBOUND_ROUNDTRIP_S3_URI='${s3_uri}'."
fi
IFS='|' read -r s3_bucket s3_prefix <<< "$parsed_s3"

subject="$(test_inbox_build_probe_subject "$nonce")"
body="$(test_inbox_build_probe_body "$nonce")"

if ! send_json="$(test_inbox_send_probe_email "$from_address" "$recipient_address" "$region" "$subject" "$body" 2>/dev/null)"; then
    append_step "send_probe" false "aws sesv2 send-email failed for recipient '$recipient_address'."
    append_step "poll_inbox_s3" false "Skipped because send_probe failed."
    append_step "fetch_rfc822" false "Skipped because send_probe failed."
    append_step "auth_verdict" false "Skipped because send_probe failed."
    emit_result false
    exit "$EXIT_RUNTIME"
fi

message_id="$(json_get_field "$send_json" "MessageId")"
append_step "send_probe" true "Sent probe from '$from_address' to '$recipient_address' (message_id='${message_id:-unknown}')."

poll_key=""
if poll_key="$(test_inbox_find_matching_object_key "$s3_bucket" "$s3_prefix" "$nonce" "$region" "$poll_max_attempts" "$poll_sleep_sec" 2>/dev/null)"; then
    append_step "poll_inbox_s3" true "Found nonce '$nonce' at s3://$s3_bucket/$poll_key."
else
    poll_rc=$?
    if [[ "$poll_rc" -eq "$TEST_INBOX_POLL_TIMEOUT_EXIT_CODE" ]]; then
        append_step "poll_inbox_s3" false "Timed out waiting for nonce '$nonce' in $s3_uri after $poll_max_attempts attempts."
        append_step "fetch_rfc822" false "Skipped because poll_inbox_s3 timed out."
        append_step "auth_verdict" false "Skipped because poll_inbox_s3 timed out."
        emit_result false
        exit "$EXIT_TIMEOUT"
    fi

    append_step "poll_inbox_s3" false "aws s3api list-objects-v2 failed for $s3_uri."
    append_step "fetch_rfc822" false "Skipped because poll_inbox_s3 failed."
    append_step "auth_verdict" false "Skipped because poll_inbox_s3 failed."
    emit_result false
    exit "$EXIT_RUNTIME"
fi

if ! rfc822_payload="$(test_inbox_fetch_rfc822 "$s3_bucket" "$poll_key" "$region" 2>/dev/null)"; then
    append_step "fetch_rfc822" false "aws s3api get-object failed for s3://$s3_bucket/$poll_key."
    append_step "auth_verdict" false "Skipped because fetch_rfc822 failed."
    emit_result false
    exit "$EXIT_RUNTIME"
fi
append_step "fetch_rfc822" true "Fetched RFC822 payload for s3://$s3_bucket/$poll_key."

rfc822_file="$(mktemp)"
printf '%s' "$rfc822_payload" > "$rfc822_file"

parser_output=""
if parser_output="$(python3 "$ROUNDTRIP_PARSER" "$rfc822_file" 2>/dev/null)"; then
    parser_rc=0
else
    parser_rc=$?
fi
rm -f "$rfc822_file"

if [[ "$parser_rc" -eq 0 ]]; then
    append_step "auth_verdict" true "$(json_get_field "$parser_output" "detail")"
    emit_result true
    exit 0
fi

if [[ "$parser_rc" -eq "$EXIT_AUTH_FAILURE" ]]; then
    failed_components="$(json_get_field "$parser_output" "failed_components_csv")"
    parser_detail="$(json_get_field "$parser_output" "detail")"
    append_step "auth_verdict" false "${parser_detail:-Authentication-Results failed.} failed_components='${failed_components:-unknown}'."
    emit_result false
    exit "$EXIT_AUTH_FAILURE"
fi

append_step "auth_verdict" false "parse_inbound_auth_headers.py failed with exit code $parser_rc."
emit_result false
exit "$EXIT_RUNTIME"
