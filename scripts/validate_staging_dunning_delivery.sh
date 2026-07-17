#!/usr/bin/env bash
# Validate staging dunning email delivery by reusing rehearsal artifacts and SES inbound S3 evidence.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_DIR="${RUNNER_DIR:-$SCRIPT_DIR}"
source "$SCRIPT_DIR/lib/env.sh"
source "$SCRIPT_DIR/lib/validation_json.sh"
source "$SCRIPT_DIR/lib/test_inbox_helpers.sh"
source "$SCRIPT_DIR/lib/live_gate.sh"
source "$SCRIPT_DIR/lib/staging_billing_rehearsal_impl.sh"
source "$SCRIPT_DIR/lib/metering_checks.sh"
SCRIPT_DIR="$RUNNER_DIR"

EXIT_RUNTIME=1
RUNNER_DIR="${RUNNER_DIR:-$SCRIPT_DIR}"
REHEARSAL_SCRIPT_DEFAULT="$SCRIPT_DIR/staging_billing_rehearsal.sh"
DUNNING_REPLAY_FIXTURE_SCRIPT_DEFAULT="$SCRIPT_DIR/stripe_webhook_replay_fixture.sh"
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

write_inbound_s3_scope_artifact() {
    local region="$1"
    local s3_uri="$2"

    {
        printf 'region=%s\n' "$region"
        printf 's3_uri=%s\n' "$s3_uri"
    } > "$ARTIFACT_DIR/inbound_s3_scope.txt"
    chmod 600 "$ARTIFACT_DIR/inbound_s3_scope.txt"
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
    local allowlist tenant reset_output reset_rc reset_result reset_classification reset_detail reset_count

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
            reset_detail="$(json_get_field "$reset_output" "detail")"
            RESULT="failed"
            CLASSIFICATION="rehearsal_reset_failed"
            # Surface the nested rehearsal classification + detail in the top-level
            # detail field so downstream parsers (notably Stage 4's SSM RunShellScript
            # caller) can distinguish reset-DB-unreachable from a bad-tenant rejection
            # without walking the steps array. Outer classification stays stable.
            DETAIL="Reset flow failed for tenant ${tenant}: ${reset_classification:-unknown_classification} — ${reset_detail:-no_detail}"
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
DUNNING_REPLAY_FIXTURE_SCRIPT="${STAGING_DUNNING_REPLAY_FIXTURE_SCRIPT:-$DUNNING_REPLAY_FIXTURE_SCRIPT_DEFAULT}"

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
if [[ ! -x "$DUNNING_REPLAY_FIXTURE_SCRIPT" ]]; then
    RESULT="blocked"; CLASSIFICATION="replay_fixture_missing"; DETAIL="Dunning replay fixture not executable: $DUNNING_REPLAY_FIXTURE_SCRIPT"
    append_step "guard" false "$DETAIL"; emit_result; exit "$EXIT_RUNTIME"
fi

clear_rehearsal_input_env
load_layered_env_files "$ENV_FILE"
derive_staging_contract_env_aliases
if [[ "$(validate_staging_hostname "${STAGING_API_URL:-}")" != "true" ]]; then
    RESULT="blocked"; CLASSIFICATION="non_staging_api_hostname"; DETAIL="STAGING_API_URL must target a staging hostname."
    append_step "guard" false "$DETAIL"; emit_result; exit "$EXIT_RUNTIME"
fi
if ! hydrate_staging_tool_env_from_ssm staging; then
    RESULT="blocked"; CLASSIFICATION="staging_ssm_hydration_failed"; DETAIL="Failed to hydrate canonical staging runtime credentials from SSM."
    append_step "guard" false "$DETAIL"; emit_result; exit "$EXIT_RUNTIME"
fi
derive_staging_contract_env_aliases
derive_staging_dunning_inbox_env_defaults
append_step "guard" true "Explicit staging env file, SSM hydration, and hostname checks passed."

run_allowlisted_rehearsal_resets

set +e
rehearsal_output="$(bash "$REHEARSAL_SCRIPT" --env-file "$ENV_FILE" --month "$BILLING_MONTH" --confirm-live-mutation 2>&1)"
rehearsal_rc=$?
set -e
ARTIFACT_DIR="$(json_get_field "$rehearsal_output" "artifact_dir")"
if [[ "$rehearsal_rc" -ne 0 ]]; then
    rehearsal_classification="$(json_get_field "$rehearsal_output" "classification")"
    if [[ "$rehearsal_classification" == "invoice_email_evidence_delegated" && -n "$ARTIFACT_DIR" ]]; then
        append_step "run_rehearsal" true "Rehearsal delegated invoice email evidence to SES/S3 validator with artifact_dir=$ARTIFACT_DIR"
    else
        RESULT="failed"; CLASSIFICATION="rehearsal_failed"; DETAIL="Rehearsal owner failed."
        append_step "run_rehearsal" false "$rehearsal_output"; emit_result; exit "$EXIT_RUNTIME"
    fi
else
    append_step "run_rehearsal" true "Rehearsal completed with artifact_dir=$ARTIFACT_DIR"
fi

if [[ -z "$ARTIFACT_DIR" ]]; then
    RESULT="failed"; CLASSIFICATION="artifact_dir_missing"; DETAIL="Rehearsal output missing artifact_dir."
    append_step "run_rehearsal" false "$rehearsal_output"; emit_result; exit "$EXIT_RUNTIME"
fi

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
write_inbound_s3_scope_artifact "$region" "${INBOUND_ROUNDTRIP_S3_URI:-}"

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
candidate_invoice_ids_json="$(python3 - "$invoice_rows_json" "$webhook_json" "$transition_invoice_ids_json" <<'PY'
import json
import sys

invoice_rows_payload = (json.loads(sys.argv[1]).get("payload") or {})
webhook_payload = (json.loads(sys.argv[2]).get("payload") or {})
transition_invoice_ids = json.loads(sys.argv[3])
invoice_ids = []
seen = set()

def add_invoice_id(value):
    if isinstance(value, str):
        value = value.strip()
    if not value or not isinstance(value, str) or value in seen:
        return
    seen.add(value)
    invoice_ids.append(value)

for payload in (webhook_payload, invoice_rows_payload):
    for key in ("required_invoice_ids", "invoice_ids"):
        values = payload.get(key)
        if isinstance(values, list):
            for value in values:
                add_invoice_id(value)

    rows = payload.get("rows")
    if isinstance(rows, list):
        for row in rows:
            if isinstance(row, dict):
                add_invoice_id(row.get("invoice_id"))

for value in transition_invoice_ids.values():
    add_invoice_id(value)

print(json.dumps(invoice_ids))
PY
)"
stripe_invoice_id_lookup_json="$(python3 - "$invoice_rows_json" "$webhook_json" <<'PY'
import json
import sys

invoice_rows_payload = (json.loads(sys.argv[1]).get("payload") or {})
webhook_payload = (json.loads(sys.argv[2]).get("payload") or {})
lookup = {}

for payload in (webhook_payload, invoice_rows_payload):
    rows = payload.get("rows")
    if isinstance(rows, list):
        for row in rows:
            if not isinstance(row, dict):
                continue
            iid = str(row.get("invoice_id") or "").strip()
            sid = str(row.get("stripe_invoice_id") or "").strip()
            if iid and sid and iid not in lookup:
                lookup[iid] = sid

print(json.dumps(lookup))
PY
)"
hosted_invoice_url_lookup_json="$(python3 - "$invoice_rows_json" "$webhook_json" <<'PY'
import json
import sys

invoice_rows_payload = (json.loads(sys.argv[1]).get("payload") or {})
webhook_payload = (json.loads(sys.argv[2]).get("payload") or {})
lookup = {}

for payload in (webhook_payload, invoice_rows_payload):
    rows = payload.get("rows")
    if isinstance(rows, list):
        for row in rows:
            if not isinstance(row, dict):
                continue
            iid = str(row.get("invoice_id") or "").strip()
            hosted_url = str(row.get("hosted_invoice_url") or "").strip()
            if iid and hosted_url and iid not in lookup:
                lookup[iid] = hosted_url

print(json.dumps(lookup))
PY
)"

body_matches_invoice() {
    local body="$1" candidate_id="$2"
    if [[ "$body" == *"$candidate_id"* ]]; then
        return 0
    fi
    local stripe_id
    stripe_id="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2],''))" "$stripe_invoice_id_lookup_json" "$candidate_id" 2>/dev/null || true)"
    if [[ -n "$stripe_id" && "$body" == *"$stripe_id"* ]]; then
        return 0
    fi
    local hosted_invoice_url
    hosted_invoice_url="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2],''))" "$hosted_invoice_url_lookup_json" "$candidate_id" 2>/dev/null || true)"
    if [[ -n "$hosted_invoice_url" && "$body" == *"$hosted_invoice_url"* ]]; then
        return 0
    fi
    return 1
}

if [[ "$transition_invoice_ids_json" == "{}" && "$candidate_invoice_ids_json" == "[]" ]]; then
    RESULT="failed"; CLASSIFICATION="transition_invoice_mapping_missing"; DETAIL="Rehearsal artifacts must provide payload.transition_invoice_ids or candidate invoice IDs for failed/suspended/recovered."
    append_step "load_artifacts" false "$DETAIL"; emit_result; exit "$EXIT_RUNTIME"
fi
if [[ "$transition_invoice_ids_json" == "{}" ]]; then
    append_step "load_artifacts" true "Loaded candidate invoice IDs for transition derivation from rehearsal artifacts."
else
    append_step "load_artifacts" true "Loaded transition invoice mapping from rehearsal artifacts."
fi

dunning_replay_target_json="$(python3 - "$invoice_rows_json" "$webhook_json" "$transition_invoice_ids_json" <<'PY'
import json
import sys

invoice_rows_payload = (json.loads(sys.argv[1]).get("payload") or {})
webhook_payload = (json.loads(sys.argv[2]).get("payload") or {})
transition_invoice_ids = json.loads(sys.argv[3])

rows_by_invoice_id = {}
ordered_invoice_ids = []

for payload in (invoice_rows_payload, webhook_payload):
    rows = payload.get("rows")
    if not isinstance(rows, list):
        continue
    for row in rows:
        if not isinstance(row, dict):
            continue
        invoice_id = str(row.get("invoice_id") or "").strip()
        stripe_invoice_id = str(row.get("stripe_invoice_id") or "").strip()
        if not invoice_id or not stripe_invoice_id:
            continue
        if invoice_id not in rows_by_invoice_id:
            ordered_invoice_ids.append(invoice_id)
            rows_by_invoice_id[invoice_id] = stripe_invoice_id

preferred_invoice_ids = []
for transition in ("failed", "suspended", "recovered"):
    value = transition_invoice_ids.get(transition)
    if isinstance(value, str) and value.strip():
        preferred_invoice_ids.append(value.strip())
preferred_invoice_ids.extend(ordered_invoice_ids)

seen = set()
for invoice_id in preferred_invoice_ids:
    if invoice_id in seen:
        continue
    seen.add(invoice_id)
    stripe_invoice_id = rows_by_invoice_id.get(invoice_id)
    if stripe_invoice_id:
        print(json.dumps({"invoice_id": invoice_id, "stripe_invoice_id": stripe_invoice_id}))
        raise SystemExit(0)

print("{}")
PY
)"
dunning_replay_invoice_id="$(json_get_field "$dunning_replay_target_json" "invoice_id")"
dunning_replay_stripe_invoice_id="$(json_get_field "$dunning_replay_target_json" "stripe_invoice_id")"
if [[ -z "$dunning_replay_invoice_id" || -z "$dunning_replay_stripe_invoice_id" ]]; then
    if [[ "$transition_invoice_ids_json" == "{}" ]]; then
        RESULT="failed"; CLASSIFICATION="transition_invoice_mapping_missing"; DETAIL="Rehearsal artifacts must include stripe_invoice_id rows to derive dunning transition evidence."
        append_step "replay_dunning_webhooks" false "$DETAIL"; emit_result; exit "$EXIT_RUNTIME"
    fi
else

    # Reset invoice status to "finalized" so the API's dunning webhook handlers
    # will process the replayed events. Stripe test-mode auto-pays invoices, so
    # by the time we replay, the invoice is "paid" and all handlers return early.
    dunning_replay_did_reset_invoice=0
    if has_rehearsal_db_evidence_access; then
        dunning_reset_sql="UPDATE invoices SET status = 'finalized', paid_at = NULL WHERE stripe_invoice_id = '$(echo "$dunning_replay_stripe_invoice_id" | sed "s/'/''/g")'"
        if run_rehearsal_db_query "$dunning_reset_sql"; then
            dunning_replay_did_reset_invoice=1
            append_step "reset_invoice_for_dunning" true "Reset invoice ${dunning_replay_invoice_id} to finalized status for dunning replay."
        else
            RESULT="failed"; CLASSIFICATION="dunning_invoice_reset_failed"; DETAIL="Could not reset invoice ${dunning_replay_invoice_id} status to finalized before dunning replay (exit $?)."
            append_step "reset_invoice_for_dunning" false "$DETAIL"; emit_result; exit "$EXIT_RUNTIME"
        fi
    else
        RESULT="failed"; CLASSIFICATION="dunning_invoice_reset_unavailable"; DETAIL="No DB access path available to reset invoice ${dunning_replay_invoice_id} status before dunning replay. Set DATABASE_URL, INTEGRATION_DB_URL, or ensure ssm_exec_staging.sh is executable."
        append_step "reset_invoice_for_dunning" false "$DETAIL"; emit_result; exit "$EXIT_RUNTIME"
    fi

    # Always restore invoice status when reset succeeded, even on early exit due
    # to replay failure, so a failed validator run does not leave staging
    # invoice rows stuck in 'finalized'.
    restore_invoice_after_dunning_replay_if_needed() {
        local context="${1:-after dunning replay}"
        if [[ "$dunning_replay_did_reset_invoice" != "1" ]]; then
            return 0
        fi
        local restore_sql
        restore_sql="UPDATE invoices SET status = 'paid', paid_at = NOW() WHERE stripe_invoice_id = '$(echo "$dunning_replay_stripe_invoice_id" | sed "s/'/''/g")'"
        if run_rehearsal_db_query "$restore_sql"; then
            append_step "restore_invoice_after_dunning" true "Restored invoice ${dunning_replay_invoice_id} to paid status ${context}."
        else
            append_step "restore_invoice_after_dunning" false "Warning: could not restore invoice ${dunning_replay_invoice_id} to paid status ${context}."
        fi
    }

    replay_target_url="${STAGING_STRIPE_WEBHOOK_URL:-${STAGING_API_URL%/}/webhooks/stripe}"
    replay_next_payment_attempt=$(( $(date +%s) + 3600 ))
    replay_base_args=(--run --allow-staging-target --env-file "$ENV_FILE" --target-url "$replay_target_url" --invoice-id "$dunning_replay_stripe_invoice_id")
    if ! bash "$DUNNING_REPLAY_FIXTURE_SCRIPT" "${replay_base_args[@]}" --event-type invoice.payment_failed --next-payment-attempt "$replay_next_payment_attempt" --attempt-count 1 >/dev/null; then
        RESULT="failed"; CLASSIFICATION="dunning_webhook_replay_failed"; DETAIL="Retry-scheduled dunning webhook replay failed for invoice ${dunning_replay_invoice_id}."
        append_step "replay_dunning_webhooks" false "$DETAIL"
        restore_invoice_after_dunning_replay_if_needed "after retry-scheduled replay failure"
        emit_result; exit "$EXIT_RUNTIME"
    fi
    if ! bash "$DUNNING_REPLAY_FIXTURE_SCRIPT" "${replay_base_args[@]}" --event-type invoice.payment_failed --next-payment-attempt null --attempt-count 2 >/dev/null; then
        RESULT="failed"; CLASSIFICATION="dunning_webhook_replay_failed"; DETAIL="Retries-exhausted dunning webhook replay failed for invoice ${dunning_replay_invoice_id}."
        append_step "replay_dunning_webhooks" false "$DETAIL"
        restore_invoice_after_dunning_replay_if_needed "after retries-exhausted replay failure"
        emit_result; exit "$EXIT_RUNTIME"
    fi
    if ! bash "$DUNNING_REPLAY_FIXTURE_SCRIPT" "${replay_base_args[@]}" --event-type invoice.payment_succeeded >/dev/null; then
        RESULT="failed"; CLASSIFICATION="dunning_webhook_replay_failed"; DETAIL="Recovery dunning webhook replay failed for invoice ${dunning_replay_invoice_id}."
        append_step "replay_dunning_webhooks" false "$DETAIL"
        restore_invoice_after_dunning_replay_if_needed "after recovery replay failure"
        emit_result; exit "$EXIT_RUNTIME"
    fi
    append_step "replay_dunning_webhooks" true "Replayed retry, exhausted, and recovery dunning webhooks for invoice ${dunning_replay_invoice_id}."
    if [[ "$transition_invoice_ids_json" != "{}" ]]; then
        transition_invoice_ids_json="$(python3 - "$dunning_replay_invoice_id" <<'PY'
import json
import sys
invoice_id = sys.argv[1]
print(json.dumps({"failed": invoice_id, "suspended": invoice_id, "recovered": invoice_id}))
PY
)"
        append_step "bind_dunning_transitions_to_replay" true "Bound transition assertions to replay invoice ${dunning_replay_invoice_id}."
    fi

    # Poll S3 listing until new dunning emails appear or timeout.
    # SES delivery roundtrip is ~30-40s; a single fixed sleep was insufficient.
    # Tests set STAGING_DUNNING_REPLAY_INBOX_SETTLE_SECONDS=0 to skip polling.
    pre_replay_key_count="${#inbound_keys[@]}"
    inbox_settle="${STAGING_DUNNING_REPLAY_INBOX_SETTLE_SECONDS:-10}"
    poll_timeout="${STAGING_DUNNING_REPLAY_INBOX_POLL_TIMEOUT_SECONDS:-90}"
    poll_interval="${STAGING_DUNNING_REPLAY_INBOX_POLL_INTERVAL_SECONDS:-10}"

    sleep "$inbox_settle"
    keys_json="$(test_inbox_list_recent_object_keys_json "$s3_bucket" "$s3_prefix" "$region" "50" 2>/dev/null || true)"
    inbound_keys=()
    while IFS= read -r key; do
        inbound_keys+=("$key")
    done < <(python3 - "$keys_json" <<'PY'
import json
import sys
for key in json.loads(sys.argv[1] or "[]"):
    print(key)
PY
)

    if [[ "$inbox_settle" -gt 0 && "${#inbound_keys[@]}" -le "$pre_replay_key_count" ]]; then
        poll_start="$(date +%s)"
        while [[ "${#inbound_keys[@]}" -le "$pre_replay_key_count" ]]; do
            poll_elapsed=$(( $(date +%s) - poll_start ))
            if [[ "$poll_elapsed" -ge "$poll_timeout" ]]; then
                break
            fi
            sleep "$poll_interval"
            keys_json="$(test_inbox_list_recent_object_keys_json "$s3_bucket" "$s3_prefix" "$region" "50" 2>/dev/null || true)"
            inbound_keys=()
            while IFS= read -r key; do
                inbound_keys+=("$key")
            done < <(python3 - "$keys_json" <<'PY'
import json
import sys
for key in json.loads(sys.argv[1] or "[]"):
    print(key)
PY
)
        done
    fi

    restore_invoice_after_dunning_replay_if_needed "after dunning replay"
fi

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
    transition_candidate_invoice_ids_json="$candidate_invoice_ids_json"
    if [[ -n "$invoice_id" ]]; then
        transition_candidate_invoice_ids_json="$(python3 - "$invoice_id" <<'PY'
import json
import sys
print(json.dumps([sys.argv[1]]))
PY
)"
    fi
    matched_key=""
    actual_subject=""
    matched_body=""

    while IFS= read -r candidate_invoice_id; do
        [[ -n "$candidate_invoice_id" ]] || continue
        for key in "${inbound_keys[@]}"; do
            [[ -n "$key" ]] || continue
            rfc822_payload="$(test_inbox_fetch_rfc822 "$s3_bucket" "$key" "$region" 2>/dev/null || true)"
            [[ -n "$rfc822_payload" ]] || continue
            if body_matches_invoice "$rfc822_payload" "$candidate_invoice_id"; then
                candidate_subject="$(test_inbox_extract_subject_from_rfc822 "$rfc822_payload")"
                candidate_body="$(test_inbox_extract_body_text_from_rfc822 "$rfc822_payload")"
                if [[ "$candidate_subject" == "$expected_subject" ]] && body_matches_invoice "$candidate_body" "$candidate_invoice_id"; then
                    invoice_id="$candidate_invoice_id"
                    matched_key="$key"
                    actual_subject="$candidate_subject"
                    matched_body="$candidate_body"
                    break
                fi
            fi
        done
        if [[ -n "$matched_key" ]]; then
            break
        fi
    done < <(python3 - "$transition_candidate_invoice_ids_json" <<'PY'
import json
import sys
for invoice_id in json.loads(sys.argv[1]):
    if isinstance(invoice_id, str) and invoice_id.strip():
        print(invoice_id.strip())
PY
)

    transition_result="failed"
    if [[ -n "$invoice_id" && -n "$matched_key" && "$actual_subject" == "$expected_subject" ]] && body_matches_invoice "$matched_body" "$invoice_id"; then
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
