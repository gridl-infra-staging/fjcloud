#!/usr/bin/env bash
# Validate staging dunning email delivery by reusing rehearsal artifacts and SES inbound S3 evidence.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/env.sh"
source "$SCRIPT_DIR/lib/validation_json.sh"
source "$SCRIPT_DIR/lib/test_inbox_helpers.sh"
source "$SCRIPT_DIR/lib/staging_billing_rehearsal_impl.sh"

EXIT_RUNTIME=1
REHEARSAL_SCRIPT_DEFAULT="$SCRIPT_DIR/staging_billing_rehearsal.sh"
SANCTIONED_STAGING_API_HOST="api.flapjack.foo"

append_step() { validation_append_step "$@"; }
json_get_field() { validation_json_get_field "$@"; }

RESULT="blocked"
CLASSIFICATION="validator_not_started"
DETAIL="Validator did not run."
ARTIFACT_DIR=""
TRANSITIONS_JSON='[]'

emit_result() {
    local elapsed_ms
    elapsed_ms=$(( $(validation_ms_now) - VALIDATION_START_MS ))
    printf '{"result":"%s","classification":%s,"detail":%s,"artifact_dir":%s,"transitions":%s,"steps":[%s],"elapsed_ms":%s}\n' \
        "$RESULT" \
        "$(validation_json_escape "$CLASSIFICATION")" \
        "$(validation_json_escape "$DETAIL")" \
        "$(validation_json_escape "$ARTIFACT_DIR")" \
        "$TRANSITIONS_JSON" \
        "$VALIDATION_STEPS_JSON" \
        "$elapsed_ms"
}

validate_staging_hostname() {
    local staging_url="$1"
    python3 - "$staging_url" "$SANCTIONED_STAGING_API_HOST" <<'PY'
import sys
from urllib.parse import urlparse
url = sys.argv[1]
sanctioned_host = sys.argv[2].strip().lower()
host = urlparse(url).hostname or ""
host = host.lower()
is_staging_host = "staging" in host
is_sanctioned_host = host == sanctioned_host
print("true" if is_staging_host or is_sanctioned_host else "false")
PY
}

load_required_artifact() {
    local file_path="$1"
    if [[ ! -f "$file_path" ]]; then
        return 1
    fi
    cat "$file_path"
}

allowlisted_test_tenants() {
    python3 - "$1" <<'PY'
import sys

seen = set()
for raw in sys.argv[1].split(","):
    tenant = raw.strip()
    if not tenant or tenant in seen:
        continue
    seen.add(tenant)
    print(tenant)
PY
}

run_allowlisted_rehearsal_resets() {
    local allowlist tenant reset_output reset_rc reset_result reset_classification reset_count

    allowlist="${FJCLOUD_TEST_TENANT_IDS:-}"
    [[ -n "$allowlist" ]] || return 0

    reset_count=0
    while IFS= read -r tenant; do
        [[ -n "$tenant" ]] || continue
        reset_count=$((reset_count + 1))

        set +e
        reset_output="$(bash "$REHEARSAL_SCRIPT" \
            --env-file "$ENV_FILE" \
            --month "$BILLING_MONTH" \
            --reset-test-state \
            --confirm-test-tenant "$tenant" 2>&1)"
        reset_rc=$?
        set -e

        reset_result="$(json_get_field "$reset_output" "result")"
        reset_classification="$(json_get_field "$reset_output" "classification")"
        if [[ "$reset_rc" -ne 0 || "$reset_result" != "passed" || "$reset_classification" != "reset_completed" ]]; then
            RESULT="failed"
            CLASSIFICATION="rehearsal_reset_failed"
            DETAIL="Reset flow failed for allowlisted tenant ${tenant}."
            append_step "reset_test_state" false "$reset_output"
            emit_result
            exit "$EXIT_RUNTIME"
        fi
    done < <(allowlisted_test_tenants "$allowlist")

    if [[ "$reset_count" -gt 0 ]]; then
        append_step "reset_test_state" true "Reset completed for ${reset_count} allowlisted tenant(s)."
    fi
}

ENV_FILE=""
BILLING_MONTH=""
CONFIRM_LIVE_MUTATION=0
REHEARSAL_SCRIPT="${STAGING_DUNNING_REHEARSAL_SCRIPT:-$REHEARSAL_SCRIPT_DEFAULT}"

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --env-file)
            [[ "$#" -ge 2 ]] || { echo "--env-file requires value" >&2; exit 2; }
            ENV_FILE="$2"
            shift 2
            ;;
        --month)
            [[ "$#" -ge 2 ]] || { echo "--month requires value" >&2; exit 2; }
            BILLING_MONTH="$2"
            shift 2
            ;;
        --confirm-live-mutation)
            CONFIRM_LIVE_MUTATION=1
            shift
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

if [[ -z "$ENV_FILE" ]]; then
    RESULT="blocked"; CLASSIFICATION="explicit_env_file_required"; DETAIL="--env-file is required."
    append_step "guard" false "$DETAIL"; emit_result; exit "$EXIT_RUNTIME"
fi
if is_repo_default_env_file_name "$ENV_FILE"; then
    RESULT="blocked"; CLASSIFICATION="repo_default_env_file_rejected"; DETAIL="Repo-default env filenames are forbidden: $ENV_FILE"
    append_step "guard" false "$DETAIL"; emit_result; exit "$EXIT_RUNTIME"
fi
if [[ ! -f "$ENV_FILE" ]]; then
    RESULT="blocked"; CLASSIFICATION="explicit_env_file_missing"; DETAIL="Explicit env file missing: $ENV_FILE"
    append_step "guard" false "$DETAIL"; emit_result; exit "$EXIT_RUNTIME"
fi
if [[ "$CONFIRM_LIVE_MUTATION" -ne 1 || -z "$BILLING_MONTH" ]]; then
    RESULT="blocked"; CLASSIFICATION="live_mutation_confirmation_required"; DETAIL="--month and --confirm-live-mutation are required."
    append_step "guard" false "$DETAIL"; emit_result; exit "$EXIT_RUNTIME"
fi
if [[ ! -x "$REHEARSAL_SCRIPT" ]]; then
    RESULT="blocked"; CLASSIFICATION="rehearsal_script_missing"; DETAIL="Rehearsal script not executable: $REHEARSAL_SCRIPT"
    append_step "guard" false "$DETAIL"; emit_result; exit "$EXIT_RUNTIME"
fi

load_layered_env_files "$ENV_FILE"
  if [[ "$(validate_staging_hostname "${STAGING_API_URL:-}")" != "true" ]]; then
      RESULT="blocked"; CLASSIFICATION="non_staging_api_hostname"; DETAIL="STAGING_API_URL must target a staging hostname."
      append_step "guard" false "$DETAIL"; emit_result; exit "$EXIT_RUNTIME"
  fi
  append_step "guard" true "Explicit staging env file and hostname checks passed."

  run_allowlisted_rehearsal_resets

  set +e
  rehearsal_output="$(bash "$REHEARSAL_SCRIPT" --env-file "$ENV_FILE" --month "$BILLING_MONTH" --confirm-live-mutation 2>&1)"
  rehearsal_rc=$?
set -e
if [[ "$rehearsal_rc" -ne 0 ]]; then
    RESULT="failed"; CLASSIFICATION="rehearsal_failed"; DETAIL="Rehearsal owner failed."
    append_step "run_rehearsal" false "$rehearsal_output"; emit_result; exit "$EXIT_RUNTIME"
fi

ARTIFACT_DIR="$(json_get_field "$rehearsal_output" "artifact_dir")"
if [[ -z "$ARTIFACT_DIR" ]]; then
    RESULT="failed"; CLASSIFICATION="artifact_dir_missing"; DETAIL="Rehearsal output missing artifact_dir."
    append_step "run_rehearsal" false "$rehearsal_output"; emit_result; exit "$EXIT_RUNTIME"
fi
append_step "run_rehearsal" true "Rehearsal completed with artifact_dir=$ARTIFACT_DIR"

invoice_rows_json="$(load_required_artifact "$ARTIFACT_DIR/invoice_rows.json" || true)"
webhook_json="$(load_required_artifact "$ARTIFACT_DIR/webhook.json" || true)"
if [[ -z "$invoice_rows_json" || -z "$webhook_json" ]]; then
    RESULT="failed"; CLASSIFICATION="rehearsal_artifacts_missing"; DETAIL="Required rehearsal artifacts missing (invoice_rows.json/webhook.json)."
    append_step "load_artifacts" false "$DETAIL"; emit_result; exit "$EXIT_RUNTIME"
fi
append_step "load_artifacts" true "Loaded invoice_rows.json and webhook.json"

parsed_s3="$(test_inbox_parse_s3_uri "${INBOUND_ROUNDTRIP_S3_URI:-}" 2>/dev/null || true)"
if [[ -z "$parsed_s3" ]]; then
    RESULT="failed"; CLASSIFICATION="inbound_s3_uri_missing"; DETAIL="INBOUND_ROUNDTRIP_S3_URI is required."
    append_step "load_s3_scope" false "$DETAIL"; emit_result; exit "$EXIT_RUNTIME"
fi
IFS='|' read -r s3_bucket s3_prefix <<< "$parsed_s3"
region="${SES_REGION:-}"
if [[ -z "$region" ]]; then
    RESULT="failed"; CLASSIFICATION="ses_region_missing"; DETAIL="SES_REGION is required."
    append_step "load_s3_scope" false "$DETAIL"; emit_result; exit "$EXIT_RUNTIME"
fi
append_step "load_s3_scope" true "Using s3://$s3_bucket/$s3_prefix in region $region"

keys_json="$(test_inbox_list_recent_object_keys_json "$s3_bucket" "$s3_prefix" "$region" "50" 2>/dev/null || true)"
if [[ -z "$keys_json" || "$keys_json" == "[]" ]]; then
    RESULT="failed"; CLASSIFICATION="inbound_messages_missing"; DETAIL="No inbound RFC822 objects found for run scope."
    append_step "list_rfc822_objects" false "$DETAIL"; emit_result; exit "$EXIT_RUNTIME"
fi
append_step "list_rfc822_objects" true "Loaded inbound RFC822 object keys for run scope."

inbound_keys=()
while IFS= read -r key; do
    inbound_keys+=("$key")
done < <(python3 - "$keys_json" <<'PY'
import json
import sys
for key in json.loads(sys.argv[1]):
    print(key)
PY
)
transition_invoice_ids_json="$(python3 - "$invoice_rows_json" "$webhook_json" <<'PY'
import json
import sys

invoice_rows_payload = (json.loads(sys.argv[1]).get("payload") or {})
webhook_payload = (json.loads(sys.argv[2]).get("payload") or {})
transition_map = webhook_payload.get("transition_invoice_ids") or invoice_rows_payload.get("transition_invoice_ids") or {}
allowed = ("failed", "suspended", "recovered")
sanitized = {}
for key in allowed:
    value = transition_map.get(key)
    if isinstance(value, str) and value.strip():
        sanitized[key] = value
print(json.dumps(sanitized))
PY
)"
if [[ "$transition_invoice_ids_json" == "{}" ]]; then
    RESULT="failed"; CLASSIFICATION="transition_invoice_mapping_missing"; DETAIL="Rehearsal artifacts must provide payload.transition_invoice_ids for failed/suspended/recovered."
    append_step "load_artifacts" false "$DETAIL"; emit_result; exit "$EXIT_RUNTIME"
fi
append_step "load_artifacts" true "Loaded transition invoice mapping from rehearsal artifacts."

transition_names=("failed" "suspended" "recovered")
transition_subjects=("Payment retry scheduled" "Payment retries exhausted" "Payment recovered")
transition_entries=()
transition_failures=0

for idx in "${!transition_names[@]}"; do
    transition="${transition_names[$idx]}"
    expected_subject="${transition_subjects[$idx]}"
    invoice_id="$(python3 - "$transition_invoice_ids_json" "$transition" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
print(payload.get(sys.argv[2], ""))
PY
)"
    matched_key=""
    actual_subject=""
    matched_body=""

    for key in "${inbound_keys[@]}"; do
        [[ -n "$key" ]] || continue
        rfc822_payload="$(test_inbox_fetch_rfc822 "$s3_bucket" "$key" "$region" 2>/dev/null || true)"
        [[ -n "$rfc822_payload" ]] || continue
        if [[ -n "$invoice_id" && "$rfc822_payload" == *"$invoice_id"* ]]; then
            candidate_subject="$(test_inbox_extract_subject_from_rfc822 "$rfc822_payload")"
            candidate_body="$(test_inbox_extract_body_text_from_rfc822 "$rfc822_payload")"
            if [[ "$candidate_subject" == "$expected_subject" && "$candidate_body" == *"$invoice_id"* ]]; then
                matched_key="$key"
                actual_subject="$candidate_subject"
                matched_body="$candidate_body"
                break
            fi
        fi
    done

    transition_result="failed"
    if [[ -n "$invoice_id" && -n "$matched_key" && "$actual_subject" == "$expected_subject" && "$matched_body" == *"$invoice_id"* ]]; then
        transition_result="passed"
    else
        transition_failures=$((transition_failures + 1))
    fi

    transition_entries+=("{\"transition\":\"$transition\",\"invoice_id\":$(validation_json_escape "$invoice_id"),\"expected_subject\":$(validation_json_escape "$expected_subject"),\"actual_subject\":$(validation_json_escape "$actual_subject"),\"s3_object_key\":$(validation_json_escape "$matched_key"),\"result\":\"$transition_result\"}")
done
TRANSITIONS_JSON="[$(IFS=,; echo "${transition_entries[*]}")]"

if [[ "$transition_failures" == "0" ]]; then
    RESULT="passed"
    CLASSIFICATION="dunning_delivery_verified"
    DETAIL="Verified failed/suspended/recovered dunning emails against inbound RFC822 artifacts."
    append_step "assert_dunning_transitions" true "$DETAIL"
    emit_result
    exit 0
fi

RESULT="failed"
CLASSIFICATION="dunning_subject_or_body_mismatch"
DETAIL="One or more dunning transitions failed subject/body invoice-id assertions."
append_step "assert_dunning_transitions" false "$DETAIL"
emit_result
exit "$EXIT_RUNTIME"
