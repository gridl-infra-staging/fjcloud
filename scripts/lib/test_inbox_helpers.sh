#!/usr/bin/env bash
# Shared inbound test-inbox helpers used by roundtrip probe and future canary wrappers.
set -euo pipefail

# AWS caller-identity triage SSOT. test_inbox_require_aws_inbox_prereqs below
# delegates its credential check here so a stale-ambient / valid-secret-file
# situation RECOVERS instead of being misclassified as a dead-credential skip
# (the 2026-07-08 root cause). Guarded so double-sourcing by callers is a no-op.
TEST_INBOX_HELPERS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -f aws_identity_ensure >/dev/null 2>&1; then
    # shellcheck source=scripts/lib/aws_identity.sh
    source "$TEST_INBOX_HELPERS_LIB_DIR/aws_identity.sh"
fi

TEST_INBOX_ARG_ERROR_EXIT_CODE=2
TEST_INBOX_PREREQ_SKIP_EXIT_CODE=100
TEST_INBOX_POLL_TIMEOUT_EXIT_CODE=124
TEST_INBOX_AWS_CREDENTIALS_UNAVAILABLE_TOKEN="probe_env_gap_aws_credentials_unavailable"
TEST_INBOX_AWS_CREDENTIALS_INVALID_TOKEN="probe_env_gap_aws_credentials_invalid"
TEST_INBOX_AWS_INBOX_ENV_MISSING_TOKEN="probe_env_gap_aws_inbox_env_missing"

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

# Classify caller-side prereqs before helpers start S3 list/get runtime work.
test_inbox_require_aws_inbox_prereqs() {
    if [[ "$#" -ne 2 ]]; then
        echo "usage: test_inbox_require_aws_inbox_prereqs CANARY_TEST_INBOX_S3_URI CANARY_TEST_INBOX_DOMAIN" >&2
        return "$TEST_INBOX_ARG_ERROR_EXIT_CODE"
    fi

    local inbox_s3_uri="$1"
    local inbox_domain="$2"

    if [[ -z "$inbox_s3_uri" || -z "$inbox_domain" ]]; then
        echo "$TEST_INBOX_AWS_INBOX_ENV_MISSING_TOKEN: missing CANARY_TEST_INBOX_S3_URI or CANARY_TEST_INBOX_DOMAIN" >&2
        return "$TEST_INBOX_PREREQ_SKIP_EXIT_CODE"
    fi

    test_inbox_require_nonempty "$inbox_s3_uri" "CANARY_TEST_INBOX_S3_URI" || return $?
    test_inbox_require_nonempty "$inbox_domain" "CANARY_TEST_INBOX_DOMAIN" || return $?
    test_inbox_parse_s3_uri "$inbox_s3_uri" >/dev/null || return $?

    # Delegate the credential check to the aws_identity SSOT. It probes STS and,
    # crucially, retries against the operator secret file when ambient AWS_* look
    # invalid — so environment pollution (a stale key/token shadowing a valid
    # .secret/.env.secret key) recovers instead of skipping. `|| true` keeps the
    # non-zero return from tripping `set -e`; we branch on AWS_IDENTITY_STATUS.
    aws_identity_ensure || true
    # The `token: <detail>` strings below are a cross-script contract: downstream
    # canary/RC harnesses capture this function's stderr verbatim as the single
    # skip-detail line and assert the exact phrase. So we emit EXACTLY ONE line
    # with the legacy phrase — no extra diagnostic lines, which would corrupt
    # that single-line capture. The richer aws_identity diagnostic (pollution vs
    # dead credential) stays available to callers via $AWS_IDENTITY_DIAGNOSTIC.
    case "$AWS_IDENTITY_STATUS" in
        valid|recovered)
            # A usable identity is available. On `recovered`, aws_identity_ensure
            # has already exported the good creds into this process, so the S3
            # list/get work that follows uses them.
            : ;;
        cli_missing)
            echo "$TEST_INBOX_AWS_CREDENTIALS_UNAVAILABLE_TOKEN: aws CLI unavailable" >&2
            return "$TEST_INBOX_PREREQ_SKIP_EXIT_CODE"
            ;;
        no_credentials)
            echo "$TEST_INBOX_AWS_CREDENTIALS_UNAVAILABLE_TOKEN: aws sts get-caller-identity could not locate credentials" >&2
            return "$TEST_INBOX_PREREQ_SKIP_EXIT_CODE"
            ;;
        *)
            # invalid_credentials: present but rejected even after the secret-file
            # retry — a genuinely dead/unusable credential, not pollution.
            echo "$TEST_INBOX_AWS_CREDENTIALS_INVALID_TOKEN: aws sts get-caller-identity failed; creds present but rejected by AWS" >&2
            return "$TEST_INBOX_PREREQ_SKIP_EXIT_CODE"
            ;;
    esac
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
    # Diagnostic counters surfaced on timeout so future callers can distinguish
    # "list returned no candidates" from "candidates were fetched but body never
    # matched the nonce" without needing to redeploy debug code.
    local total_candidates=0
    local total_fetch_failures=0
    local last_list_count=0

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
        local continuation_token=""
        while :; do
            local list_json match_candidates matched_key next_continuation
            if [[ -n "$continuation_token" ]]; then
                if ! list_json="$(AWS_PAGER="" aws s3api list-objects-v2 --bucket "$bucket" --prefix "$prefix" --continuation-token "$continuation_token" --region "$region" --output json --no-cli-pager 2>/dev/null)"; then
                    echo "aws s3api list-objects-v2 failed for s3://$bucket/$prefix" >&2
                    return 1
                fi
            else
                if ! list_json="$(AWS_PAGER="" aws s3api list-objects-v2 --bucket "$bucket" --prefix "$prefix" --region "$region" --output json --no-cli-pager 2>/dev/null)"; then
                    echo "aws s3api list-objects-v2 failed for s3://$bucket/$prefix" >&2
                    return 1
                fi
            fi
            # IMPORTANT: pass the list payload via stdin, not argv. With an active
            # SES inbound bucket the list JSON can easily exceed 100 KB, which
            # crosses the Lambda runtime ARG_MAX ceiling and produces
            # "Argument list too long" errors that silently degrade to zero
            # candidates being scanned.
            local list_json_file
            list_json_file="$(mktemp)"
            printf '%s' "$list_json" > "$list_json_file"

            last_list_count="$(python3 -c "
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as fh:
    print(len(json.load(fh).get('Contents', []) or []))
" "$list_json_file" 2>/dev/null || echo 0)"
            next_continuation="$(python3 - "$list_json_file" <<'PY' || true
import json
import sys

with open(sys.argv[1], 'r', encoding='utf-8') as fh:
    payload = json.load(fh)

token = payload.get("NextContinuationToken") or ""
print(token)
PY
)"

            match_candidates="$(python3 - "$list_json_file" "$nonce" <<'PY' || true
import json
import sys
from datetime import datetime, timezone

with open(sys.argv[1], 'r', encoding='utf-8') as fh:
    payload = json.load(fh)
nonce = sys.argv[2]

contents = payload.get("Contents", []) or []
for item in contents:
    key = item.get("Key", "")
    if nonce in key:
        print(f"KEY:{key}")
        raise SystemExit(0)

def parse_last_modified(item):
    value = item.get("LastModified", "")
    if not value:
        return datetime.min.replace(tzinfo=timezone.utc)
    try:
        if value.endswith("Z"):
            value = value[:-1] + "+00:00"
        return datetime.fromisoformat(value)
    except Exception:
        return datetime.min.replace(tzinfo=timezone.utc)

for item in sorted(contents, key=parse_last_modified, reverse=True)[:25]:
    key = item.get("Key", "")
    if key:
        print(f"CAND:{key}")
PY
)"
            rm -f "$list_json_file"

            matched_key="$(printf '%s\n' "$match_candidates" | awk -F'KEY:' 'NR==1 && /^KEY:/{print $2}')"
            if [[ -n "$matched_key" ]]; then
                printf '%s\n' "$matched_key"
                return 0
            fi

            # SES inbound keys are not required to contain the probe nonce, so fall back
            # to scanning recent message payloads for the nonce token when key-match fails.
            while IFS= read -r candidate_line; do
                local candidate_key candidate_rfc822
                if [[ "$candidate_line" != CAND:* ]]; then
                    continue
                fi
                candidate_key="${candidate_line#CAND:}"
                if [[ -z "$candidate_key" ]]; then
                    continue
                fi
                total_candidates=$((total_candidates + 1))

                candidate_rfc822="$(test_inbox_fetch_rfc822 "$bucket" "$candidate_key" "$region" 2>/dev/null || true)"
                if [[ -z "$candidate_rfc822" ]]; then
                    total_fetch_failures=$((total_fetch_failures + 1))
                    continue
                fi
                if [[ "$candidate_rfc822" == *"$nonce"* ]]; then
                    printf '%s\n' "$candidate_key"
                    return 0
                fi
            done <<< "$match_candidates"

            if [[ -z "$next_continuation" ]]; then
                break
            fi
            continuation_token="$next_continuation"
        done

        if [[ "$attempt" -lt "$max_attempts" && "$sleep_seconds" -gt 0 ]]; then
            sleep "$sleep_seconds"
        fi
        attempt=$((attempt + 1))
    done

    echo "inbox-poll exhausted: attempts=${max_attempts} last_list_count=${last_list_count} candidates_scanned=${total_candidates} fetch_failures=${total_fetch_failures} nonce=${nonce}" >&2
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

# TODO: Document test_inbox_extract_reset_token_from_rfc822.
test_inbox_extract_reset_token_from_rfc822() {
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

match = re.search(r"/reset-password/([A-Za-z0-9_-]+)", body)
if match:
    print(match.group(1))
    raise SystemExit(0)

legacy_match = re.search(r"reset-password[?&]token=([A-Za-z0-9_-]+)", body)
if legacy_match:
    print(legacy_match.group(1))
PY
}

# TODO: Document test_inbox_extract_subject_from_rfc822.
test_inbox_extract_subject_from_rfc822() {
    local rfc822_payload="$1"
    test_inbox_require_nonempty "$rfc822_payload" "rfc822_payload" || return $?

    python3 - "$rfc822_payload" <<'PY' || true
import sys
from email import policy
from email.parser import Parser

payload = sys.argv[1]
try:
    message = Parser(policy=policy.default).parsestr(payload)
except Exception:
    print("")
    raise SystemExit(0)

subject = message.get("Subject", "")
print(str(subject).strip())
PY
}

# TODO: Document test_inbox_extract_body_text_from_rfc822.
test_inbox_extract_body_text_from_rfc822() {
    local rfc822_payload="$1"
    test_inbox_require_nonempty "$rfc822_payload" "rfc822_payload" || return $?

    python3 - "$rfc822_payload" <<'PY' || true
import sys
from email import policy
from email.parser import Parser

payload = sys.argv[1]
try:
    message = Parser(policy=policy.default).parsestr(payload)
except Exception:
    print(payload)
    raise SystemExit(0)

fragments = []
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
        if content:
            fragments.append(content)
else:
    try:
        content = message.get_content()
        if isinstance(content, bytes):
            content = content.decode("utf-8", "ignore")
        if content:
            fragments.append(content)
    except Exception:
        pass

print("\n".join(fragments) if fragments else payload)
PY
}

# TODO: Document test_inbox_list_recent_object_keys_json.
test_inbox_list_recent_object_keys_json() {
    local bucket="$1"
    local prefix="$2"
    local region="$3"
    local max_keys="$4"
    local list_json

    test_inbox_require_nonempty "$bucket" "bucket" || return $?
    test_inbox_require_nonempty "$region" "region" || return $?
    test_inbox_require_nonnegative_int "$max_keys" "max_keys" || return $?
    if [[ "$max_keys" == "0" ]]; then
        echo "max_keys must be greater than zero" >&2
        return "$TEST_INBOX_ARG_ERROR_EXIT_CODE"
    fi

    if ! list_json="$(AWS_PAGER="" aws s3api list-objects-v2 --bucket "$bucket" --prefix "$prefix" --region "$region" --output json --no-cli-pager 2>/dev/null)"; then
        echo "aws s3api list-objects-v2 failed for s3://$bucket/$prefix" >&2
        return 1
    fi

    local list_json_file
    list_json_file="$(mktemp)"
    printf '%s' "$list_json" > "$list_json_file"

    python3 - "$list_json_file" "$max_keys" <<'PY' || true
import json
import sys
from datetime import datetime, timezone

with open(sys.argv[1], 'r', encoding='utf-8') as fh:
    payload = json.load(fh)
max_keys = int(sys.argv[2])
contents = payload.get("Contents", []) or []

def parse_last_modified(item):
    raw = item.get("LastModified", "")
    if not raw:
        return datetime.min.replace(tzinfo=timezone.utc)
    try:
        if raw.endswith("Z"):
            raw = raw[:-1] + "+00:00"
        return datetime.fromisoformat(raw)
    except Exception:
        return datetime.min.replace(tzinfo=timezone.utc)

ordered = sorted(contents, key=parse_last_modified, reverse=True)
keys = [item.get("Key", "") for item in ordered if item.get("Key", "")]
print(json.dumps(keys[:max_keys]))
PY
    rm -f "$list_json_file"
}
