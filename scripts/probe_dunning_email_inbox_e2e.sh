#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test_inbox_helpers.sh"
source "$SCRIPT_DIR/lib/validation_json.sh"

EXIT_USAGE=2
EXIT_PRECONDITION=3
EXIT_RUNTIME=1

usage() {
    cat <<'USAGE'
Usage: bash scripts/probe_dunning_email_inbox_e2e.sh <env-file> [--month <YYYY-MM>]
   or: bash scripts/probe_dunning_email_inbox_e2e.sh --env-file <path> [--month <YYYY-MM>]
USAGE
}

usage_fail() {
    echo "ERROR: $1" >&2
    usage >&2
    exit "$EXIT_USAGE"
}

precondition_fail() {
    echo "ERROR: $1" >&2
    exit "$EXIT_PRECONDITION"
}

runtime_fail() {
    echo "ERROR: $1" >&2
    exit "$EXIT_RUNTIME"
}

env_file=""
month="$(date -u +%Y-%m)"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --env-file)
            [[ $# -ge 2 ]] || usage_fail "--env-file requires a value"
            env_file="$2"
            shift 2
            ;;
        --month)
            [[ $# -ge 2 ]] || usage_fail "--month requires a value"
            month="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            if [[ -z "$env_file" ]]; then
                env_file="$1"
                shift
            else
                usage_fail "unsupported argument '$1'"
            fi
            ;;
    esac
done

[[ -n "$env_file" ]] || usage_fail "env file is required"
[[ -f "$env_file" ]] || precondition_fail "env file not found: $env_file"

validator_script="${STAGING_DUNNING_VALIDATOR_SCRIPT:-$SCRIPT_DIR/validate_staging_dunning_delivery.sh}"
[[ -x "$validator_script" ]] || precondition_fail "missing executable dunning owner script: $validator_script"

validator_output="$(bash "$validator_script" --env-file "$env_file" --month "$month" --confirm-live-mutation 2>&1)" || runtime_fail "dunning owner script failed: $validator_output"
validator_result="$(validation_json_get_field "$validator_output" "result")"
validator_classification="$(validation_json_get_field "$validator_output" "classification")"
artifact_dir="$(validation_json_get_field "$validator_output" "artifact_dir")"
transitions_json="$(python3 - "$validator_output" <<'PY' || true
import json
import sys
try:
    payload = json.loads(sys.argv[1])
except Exception:
    print("[]")
    raise SystemExit(0)
print(json.dumps(payload.get("transitions", [])))
PY
)"

[[ "$validator_result" == "passed" ]] || runtime_fail "dunning owner returned result='$validator_result' classification='$validator_classification'"
[[ -n "$artifact_dir" ]] || runtime_fail "dunning owner output missing artifact_dir"

if [[ ! -f "$artifact_dir/inbound_s3_scope.txt" ]]; then
    runtime_fail "expected artifact missing: $artifact_dir/inbound_s3_scope.txt"
fi

s3_uri_line="$(cat "$artifact_dir/inbound_s3_scope.txt")"
region="$(printf '%s' "$s3_uri_line" | sed -n 's/^region=//p')"
s3_uri="$(printf '%s' "$s3_uri_line" | sed -n 's/^s3_uri=//p')"
[[ -n "$region" ]] || precondition_fail "SES region missing from artifact inbound_s3_scope.txt"
[[ -n "$s3_uri" ]] || precondition_fail "inbound S3 URI missing from artifact inbound_s3_scope.txt"

parsed_s3="$(test_inbox_parse_s3_uri "$s3_uri" 2>/dev/null || true)"
[[ -n "$parsed_s3" ]] || runtime_fail "invalid inbound S3 URI in artifact: $s3_uri"
IFS='|' read -r s3_bucket s3_prefix <<< "$parsed_s3"

hosted_url=""
matched_transition=""
while IFS='|' read -r transition_name key_name; do
    [[ -n "$transition_name" && -n "$key_name" ]] || continue
    rfc822_payload="$(test_inbox_fetch_rfc822 "$s3_bucket" "$key_name" "$region" 2>/dev/null || true)"
    [[ -n "$rfc822_payload" ]] || continue
    body_text="$(test_inbox_extract_body_text_from_rfc822 "$rfc822_payload")"
    hosted_url="$(python3 - "$body_text" <<'PY' || true
import re
import sys
body = sys.argv[1]
patterns = [
    r"https://invoice\.stripe\.com/[A-Za-z0-9_\-\./?=&%]+",
    r"https://pay\.stripe\.com/[A-Za-z0-9_\-\./?=&%]+",
]
for pattern in patterns:
    match = re.search(pattern, body)
    if match:
        print(match.group(0))
        break
PY
)"
    if [[ -n "$hosted_url" ]]; then
        matched_transition="$transition_name"
        break
    fi
done < <(python3 - "$transitions_json" <<'PY'
import json
import sys
for row in json.loads(sys.argv[1]):
    transition = row.get("transition") or ""
    key = row.get("s3_object_key") or ""
    if transition and key:
        print(f"{transition}|{key}")
PY
)

if [[ -z "$hosted_url" ]]; then
    runtime_fail "dunning email bodies did not contain a Stripe hosted invoice URL"
fi

echo "validator_classification=$validator_classification artifact_dir=$artifact_dir"
echo "TERMINUS: body contains hosted invoice url transition=$matched_transition url=$hosted_url"
