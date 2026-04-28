#!/usr/bin/env bash
# Shared inbound test-inbox helpers used by roundtrip probe and future canary wrappers.
set -euo pipefail

TEST_INBOX_ARG_ERROR_EXIT_CODE=2
TEST_INBOX_POLL_TIMEOUT_EXIT_CODE=124

# TODO: Document test_inbox_require_nonempty.
test_inbox_require_nonempty() {
    local value="$1"
    local label="$2"
    if [[ -z "$value" ]]; then
        echo "missing required value: $label" >&2
        return "$TEST_INBOX_ARG_ERROR_EXIT_CODE"
    fi
    if [[ "$value" == -* ]]; then
        echo "invalid value for $label: values must not start with -" >&2
        return "$TEST_INBOX_ARG_ERROR_EXIT_CODE"
    fi
}

# TODO: Document test_inbox_require_nonnegative_int.
test_inbox_require_nonnegative_int() {
    local value="$1"
    local label="$2"
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        echo "invalid integer value for $label: $value" >&2
        return "$TEST_INBOX_ARG_ERROR_EXIT_CODE"
    fi
}

# TODO: Document test_inbox_generate_nonce.
test_inbox_generate_nonce() {
    printf 'inbound-probe-%s-%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$RANDOM"
}

# TODO: Document test_inbox_build_probe_subject.
test_inbox_build_probe_subject() {
    local nonce="$1"
    test_inbox_require_nonempty "$nonce" "nonce" || return $?
    printf 'fjcloud inbound roundtrip probe %s\n' "$nonce"
}

# TODO: Document test_inbox_build_probe_body.
test_inbox_build_probe_body() {
    local nonce="$1"
    test_inbox_require_nonempty "$nonce" "nonce" || return $?
    printf 'Inbound roundtrip probe nonce=%s\n' "$nonce"
}

# TODO: Document test_inbox_parse_s3_uri.
test_inbox_parse_s3_uri() {
    local s3_uri="$1"
    local without_scheme bucket prefix

    test_inbox_require_nonempty "$s3_uri" "s3_uri" || return $?
    if [[ "$s3_uri" != s3://* ]]; then
        echo "invalid S3 URI (expected s3://...): $s3_uri" >&2
        return "$TEST_INBOX_ARG_ERROR_EXIT_CODE"
    fi

    without_scheme="${s3_uri#s3://}"
    bucket="${without_scheme%%/*}"
    prefix=""
    if [[ "$without_scheme" == */* ]]; then
        prefix="${without_scheme#*/}"
    fi

    test_inbox_require_nonempty "$bucket" "s3 bucket" || return $?
    printf '%s|%s\n' "$bucket" "$prefix"
}

# TODO: Document test_inbox_send_probe_email.
test_inbox_send_probe_email() {
    local from_address="$1"
    local recipient_address="$2"
    local region="$3"
    local subject="$4"
    local body="$5"

    test_inbox_require_nonempty "$from_address" "from_address" || return $?
    test_inbox_require_nonempty "$recipient_address" "recipient_address" || return $?
    test_inbox_require_nonempty "$region" "region" || return $?
    test_inbox_require_nonempty "$subject" "subject" || return $?
    test_inbox_require_nonempty "$body" "body" || return $?

    AWS_PAGER="" aws sesv2 send-email \
        --from-email-address "$from_address" \
        --destination "ToAddresses=$recipient_address" \
        --content "Simple={Subject={Data=$subject},Body={Text={Data=$body}}}" \
        --region "$region" \
        --output json \
        --no-cli-pager
}

# TODO: Document test_inbox_find_matching_object_key.
test_inbox_find_matching_object_key() {
    local bucket="$1"
    local prefix="$2"
    local nonce="$3"
    local region="$4"
    local max_attempts="$5"
    local sleep_seconds="$6"
    local attempt=1

    test_inbox_require_nonempty "$bucket" "bucket" || return $?
    test_inbox_require_nonempty "$nonce" "nonce" || return $?
    test_inbox_require_nonempty "$region" "region" || return $?
    test_inbox_require_nonnegative_int "$max_attempts" "max_attempts" || return $?
    test_inbox_require_nonnegative_int "$sleep_seconds" "sleep_seconds" || return $?
    if [[ "$max_attempts" == "0" ]]; then
        echo "max_attempts must be greater than zero" >&2
        return "$TEST_INBOX_ARG_ERROR_EXIT_CODE"
    fi

    while [[ "$attempt" -le "$max_attempts" ]]; do
        local list_json matched_key
        if ! list_json="$(AWS_PAGER="" aws s3api list-objects-v2 --bucket "$bucket" --prefix "$prefix" --region "$region" --output json --no-cli-pager 2>/dev/null)"; then
            echo "aws s3api list-objects-v2 failed for s3://$bucket/$prefix" >&2
            return 1
        fi

        matched_key="$(python3 - "$list_json" "$nonce" <<'PY' || true
import json
import sys
payload = json.loads(sys.argv[1])
nonce = sys.argv[2]
for item in payload.get("Contents", []) or []:
    key = item.get("Key", "")
    if nonce in key:
        print(key)
        break
PY
)"

        if [[ -n "$matched_key" ]]; then
            printf '%s\n' "$matched_key"
            return 0
        fi

        if [[ "$attempt" -lt "$max_attempts" && "$sleep_seconds" -gt 0 ]]; then
            sleep "$sleep_seconds"
        fi
        attempt=$((attempt + 1))
    done

    return "$TEST_INBOX_POLL_TIMEOUT_EXIT_CODE"
}

# TODO: Document test_inbox_fetch_rfc822.
test_inbox_fetch_rfc822() {
    local bucket="$1"
    local key="$2"
    local region="$3"
    local output_file

    test_inbox_require_nonempty "$bucket" "bucket" || return $?
    test_inbox_require_nonempty "$key" "key" || return $?
    test_inbox_require_nonempty "$region" "region" || return $?

    output_file="$(mktemp)"
    if ! AWS_PAGER="" aws s3api get-object --bucket "$bucket" --key "$key" --region "$region" --output json --no-cli-pager "$output_file" >/dev/null 2>&1; then
        rm -f "$output_file"
        echo "aws s3api get-object failed for s3://$bucket/$key" >&2
        return 1
    fi

    cat "$output_file"
    rm -f "$output_file"
}

# TODO: Document test_inbox_extract_verify_token_from_rfc822.
test_inbox_extract_verify_token_from_rfc822() {
    local rfc822_payload="$1"

    test_inbox_require_nonempty "$rfc822_payload" "rfc822_payload" || return $?

    python3 - "$rfc822_payload" <<'PY' || true
import re
import sys
from email import policy
from email.parser import Parser

rfc822_payload = sys.argv[1]

try:
    message = Parser(policy=policy.default).parsestr(rfc822_payload)
except Exception:
    message = None

fragments = []
if message is not None:
    if message.is_multipart():
        for part in message.walk():
            if part.get_content_type() not in ("text/plain", "text/html"):
                continue
            try:
                content = part.get_content()
            except Exception:
                continue
            if isinstance(content, bytes):
                content = content.decode("utf-8", "ignore")
            fragments.append(content)
    else:
        try:
            content = message.get_content()
            if isinstance(content, bytes):
                content = content.decode("utf-8", "ignore")
            fragments.append(content)
        except Exception:
            pass

body = "\n".join([fragment for fragment in fragments if fragment]) or rfc822_payload

match = re.search(r"/verify-email/([A-Za-z0-9_-]+)", body)
if match:
    print(match.group(1))
    raise SystemExit(0)

legacy_match = re.search(r"verify-email[?&]token=([A-Za-z0-9_-]+)", body)
if legacy_match:
    print(legacy_match.group(1))
PY
}
