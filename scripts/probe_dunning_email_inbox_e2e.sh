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

emit_probe_result() {
    local result="$1"
    local classification="$2"
    local detail="$3"
    printf '{"result":"%s","classification":%s,"detail":%s}\n' \
        "$result" \
        "$(validation_json_escape "$classification")" \
        "$(validation_json_escape "$detail")"
}

usage_fail() {
    local detail="$1"
    local classification="${2:-probe_usage_error}"
    echo "ERROR: $detail" >&2
    usage >&2
    emit_probe_result "blocked" "$classification" "$detail"
    exit "$EXIT_USAGE"
}

precondition_fail() {
    local detail="$1"
    local classification="${2:-probe_precondition_failed}"
    echo "ERROR: $detail" >&2
    emit_probe_result "blocked" "$classification" "$detail"
    exit "$EXIT_PRECONDITION"
}

runtime_fail() {
    local detail="$1"
    local classification="${2:-probe_runtime_failed}"
    echo "ERROR: $detail" >&2
    emit_probe_result "failed" "$classification" "$detail"
    exit "$EXIT_RUNTIME"
}

validator_result_is_terminal() {
    case "$1" in
        passed|failed|blocked)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

exit_with_validator_result() {
    local detail="$1"
    echo "ERROR: $detail" >&2
    emit_probe_result "$validator_result" "$validator_classification" "$detail"
    exit "$EXIT_RUNTIME"
}

env_file=""
month="$(date -u +%Y-%m)"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --env-file)
            [[ $# -ge 2 ]] || usage_fail "--env-file requires a value" "env_file_flag_value_missing"
            env_file="$2"
            shift 2
            ;;
        --month)
            [[ $# -ge 2 ]] || usage_fail "--month requires a value" "month_flag_value_missing"
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
                usage_fail "unsupported argument '$1'" "unsupported_argument"
            fi
            ;;
    esac
done

[[ -n "$env_file" ]] || usage_fail "env file is required" "env_file_required"
[[ -f "$env_file" ]] || precondition_fail "env file not found: $env_file" "env_file_missing"

validator_script="${STAGING_DUNNING_VALIDATOR_SCRIPT:-$SCRIPT_DIR/validate_staging_dunning_delivery.sh}"
[[ -x "$validator_script" ]] || precondition_fail "missing executable dunning owner script: $validator_script" "validator_script_missing"

set +e
validator_output="$(bash "$validator_script" --env-file "$env_file" --month "$month" --confirm-live-mutation 2>&1)"
validator_rc=$?
set -e
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

if [[ "$validator_rc" -ne 0 ]]; then
    if validator_result_is_terminal "$validator_result" && [[ -n "$validator_classification" ]]; then
        exit_with_validator_result "dunning owner script exited $validator_rc"
    fi
    runtime_fail "dunning owner script failed: $validator_output" "validator_script_failed"
fi

if ! validator_result_is_terminal "$validator_result" || [[ -z "$validator_classification" ]]; then
    runtime_fail "dunning owner output missing result/classification" "validator_result_invalid"
fi

if [[ "$validator_result" != "passed" ]]; then
    exit_with_validator_result "dunning owner returned result='$validator_result' classification='$validator_classification'"
fi

[[ -n "$artifact_dir" ]] || runtime_fail "dunning owner output missing artifact_dir" "artifact_dir_missing"

if [[ ! -f "$artifact_dir/inbound_s3_scope.txt" ]]; then
    runtime_fail "expected artifact missing: $artifact_dir/inbound_s3_scope.txt" "inbound_scope_artifact_missing"
fi

s3_uri_line="$(cat "$artifact_dir/inbound_s3_scope.txt")"
region="$(printf '%s' "$s3_uri_line" | sed -n 's/^region=//p')"
s3_uri="$(printf '%s' "$s3_uri_line" | sed -n 's/^s3_uri=//p')"
[[ -n "$region" ]] || precondition_fail "SES region missing from artifact inbound_s3_scope.txt" "ses_region_missing"
[[ -n "$s3_uri" ]] || precondition_fail "inbound S3 URI missing from artifact inbound_s3_scope.txt" "inbound_s3_uri_missing"

parsed_s3="$(test_inbox_parse_s3_uri "$s3_uri" 2>/dev/null || true)"
[[ -n "$parsed_s3" ]] || runtime_fail "invalid inbound S3 URI in artifact: $s3_uri" "inbound_s3_uri_invalid"
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
    runtime_fail "dunning email bodies did not contain a Stripe hosted invoice URL" "hosted_invoice_url_missing"
fi

echo "validator_classification=$validator_classification artifact_dir=$artifact_dir"
echo "TERMINUS: body contains hosted invoice url transition=$matched_transition url=$hosted_url"
emit_probe_result "passed" "$validator_classification" "Dunning email body contains a Stripe hosted invoice URL."
