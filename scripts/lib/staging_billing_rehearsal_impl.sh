# shellcheck source=psql_path.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/psql_path.sh"

ENV_FILE=""
BILLING_MONTH=""
CONFIRM_LIVE_MUTATION=0
RESET_TEST_STATE=0
CONFIRM_TEST_TENANT_ID=""

ARTIFACT_DIR=""
SUMMARY_RESULT="blocked"
SUMMARY_CLASSIFICATION="not_started"
SUMMARY_DETAIL="Rehearsal has not started."
PLANNED_STEPS_JSON="[]"

STEP_PREFLIGHT_RESULT="blocked"
STEP_PREFLIGHT_CLASSIFICATION="not_run"
STEP_PREFLIGHT_DETAIL="Preflight did not run."

STEP_METERING_RESULT="blocked"
STEP_METERING_CLASSIFICATION="not_run"
STEP_METERING_DETAIL="Metering evidence did not run."

STEP_GUARD_RESULT="blocked"
STEP_GUARD_CLASSIFICATION="not_run"
STEP_GUARD_DETAIL="Live-mutation guard did not run."

STEP_ATTEMPT_RESULT="blocked"
STEP_ATTEMPT_CLASSIFICATION="not_run"
STEP_ATTEMPT_DETAIL="Live-mutation attempt did not run."

HEALTH_STEP_JSON=""

BILLING_RUN_RESULT="blocked"
BILLING_RUN_CLASSIFICATION="not_attempted"
BILLING_RUN_DETAIL="Billing run was not attempted."
BILLING_RUN_PAYLOAD='{}'

INVOICE_ROWS_RESULT="blocked"
INVOICE_ROWS_CLASSIFICATION="not_attempted"
INVOICE_ROWS_DETAIL="Invoice row evidence was not attempted."
INVOICE_ROWS_PAYLOAD='{}'

WEBHOOK_RESULT="blocked"
WEBHOOK_CLASSIFICATION="not_attempted"
WEBHOOK_DETAIL="Webhook evidence was not attempted."
WEBHOOK_PAYLOAD='{}'

INVOICE_EMAIL_RESULT="blocked"
INVOICE_EMAIL_CLASSIFICATION="not_attempted"
INVOICE_EMAIL_DETAIL="Invoice email evidence was not attempted."
INVOICE_EMAIL_PAYLOAD='{}'

CREATED_INVOICE_IDS_JSON='[]'
INVOICE_ROWS_JSON='[]'

HTTP_RESPONSE_BODY=""
HTTP_RESPONSE_CODE=""
REHEARSAL_QUERY_OUTPUT=""

EVIDENCE_LAST_CLASSIFICATION=""
EVIDENCE_LAST_DETAIL=""
EVIDENCE_TERMINAL_FAILURE=0
EVIDENCE_ATTEMPTS_USED=0

print_usage() {
    cat <<'USAGE'
Usage:
  staging_billing_rehearsal.sh --env-file <path> [--month YYYY-MM] [--confirm-live-mutation]
  staging_billing_rehearsal.sh --env-file <path> --reset-test-state --confirm-test-tenant <uuid>
  staging_billing_rehearsal.sh --help

Options:
  --env-file <path>            Required. Explicit staging env file.
  --month <YYYY-MM>            Billing month for live mutation.
  --confirm-live-mutation      Required when --month is set.
  --reset-test-state           Reset Stripe + DB invoice state for a test tenant.
  --confirm-test-tenant <uuid> Required with --reset-test-state.

Reset safety:
  FJCLOUD_TEST_TENANT_IDS in the explicit env file must include the tenant UUID.
  See docs/env-vars.md for the allowlist contract.
USAGE
}

extract_json_array_field() {
    local json_body="$1"
    local field="$2"
    python3 - "$json_body" "$field" <<'PY' || true
import json
import sys

body = sys.argv[1]
field = sys.argv[2]
try:
    payload = json.loads(body)
except Exception:
    print("[]")
    raise SystemExit(0)

value = payload.get(field)
if isinstance(value, list):
    print(json.dumps(value))
else:
    print("[]")
PY
}

is_valid_json() {
    python3 - "$1" <<'PY' >/dev/null 2>&1
import json
import sys
json.loads(sys.argv[1])
PY
}

json_array_length() {
    python3 - "$1" <<'PY' || true
import json
import sys
try:
    arr = json.loads(sys.argv[1])
    print(len(arr) if isinstance(arr, list) else 0)
except Exception:
    print(0)
PY
}

json_array_to_sql_in_list() {
    python3 - "$1" <<'PY' || true
import json
import sys
try:
    arr = json.loads(sys.argv[1])
except Exception:
    arr = []
vals = []
for v in arr:
    if isinstance(v, str) and v:
        vals.append("'" + v.replace("'", "''") + "'")
print(",".join(vals))
PY
}

json_array_to_lines() {
    python3 - "$1" <<'PY' || true
import json
import sys
try:
    arr = json.loads(sys.argv[1])
except Exception:
    arr = []
for v in arr:
    if isinstance(v, str) and v:
        print(v)
PY
}

extract_created_invoice_ids_json() {
    python3 - "$1" <<'PY' || true
import json
import sys

try:
    payload = json.loads(sys.argv[1])
except Exception:
    print("[]")
    raise SystemExit(0)

ids = []
for item in payload.get("results", []):
    if not isinstance(item, dict):
        continue
    if item.get("status") != "created":
        continue
    invoice_id = item.get("invoice_id")
    if invoice_id is None:
        continue
    invoice_id = str(invoice_id).strip()
    if invoice_id:
        ids.append(invoice_id)

print(json.dumps(ids))
PY
}

extract_invoice_row_emails_json() {
    python3 - "$1" <<'PY' || true
import json
import sys

try:
    rows = json.loads(sys.argv[1])
except Exception:
    print("[]")
    raise SystemExit(0)

emails = []
seen = set()
if isinstance(rows, list):
    for row in rows:
        if not isinstance(row, dict):
            continue
        email = str(row.get("email", "")).strip()
        if not email or email in seen:
            continue
        seen.add(email)
        emails.append(email)
print(json.dumps(emails))
PY
}

mailpit_messages_count() {
    python3 - "$1" <<'PY' || true
import json
import sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    print(0)
    raise SystemExit(0)
count = data.get("messages_count", data.get("total", 0))
try:
    print(int(count))
except Exception:
    print(0)
PY
}

build_step_json() {
    local name="$1"
    local result="$2"
    local classification="$3"
    local detail="$4"
    local classification_json detail_json
    classification_json="$(validation_json_escape "$classification")"
    detail_json="$(validation_json_escape "$detail")"
    printf '{"name":"%s","result":"%s","classification":%s,"detail":%s}\n' \
        "$name" "$result" "$classification_json" "$detail_json"
}

build_evidence_json() {
    local name="$1"
    local result="$2"
    local classification="$3"
    local detail="$4"
    local payload_json="${5-}"
    [ -n "$payload_json" ] || payload_json='{}'
    local classification_json detail_json
    classification_json="$(validation_json_escape "$classification")"
    detail_json="$(validation_json_escape "$detail")"
    printf '{"name":"%s","result":"%s","classification":%s,"detail":%s,"payload":%s}\n' \
        "$name" "$result" "$classification_json" "$detail_json" "$payload_json"
}

init_artifact_dir() {
    ARTIFACT_DIR="${TMPDIR:-/tmp}/fjcloud_staging_billing_rehearsal_$(date -u +%Y%m%dT%H%M%SZ)_$$"
    mkdir -p "$ARTIFACT_DIR/steps"
    chmod 700 "$ARTIFACT_DIR" "$ARTIFACT_DIR/steps"
}

clear_rehearsal_input_env() {
    local var_name
    # The explicit env file is the single source of truth for rehearsal inputs.
    for var_name in \
        STAGING_API_URL \
        STAGING_STRIPE_WEBHOOK_URL \
        STRIPE_SECRET_KEY \
        STRIPE_WEBHOOK_SECRET \
        ADMIN_KEY \
        DATABASE_URL \
        INTEGRATION_DB_URL \
        MAILPIT_API_URL \
        FJCLOUD_TEST_TENANT_IDS
    do
        unset -v "$var_name"
    done
}

emit_required_step_artifacts() {
    build_step_json "preflight" \
        "$STEP_PREFLIGHT_RESULT" \
        "$STEP_PREFLIGHT_CLASSIFICATION" \
        "$STEP_PREFLIGHT_DETAIL" > "$ARTIFACT_DIR/steps/preflight.json"

    build_step_json "metering_evidence" \
        "$STEP_METERING_RESULT" \
        "$STEP_METERING_CLASSIFICATION" \
        "$STEP_METERING_DETAIL" > "$ARTIFACT_DIR/steps/metering_evidence.json"

    build_step_json "live_mutation_guard" \
        "$STEP_GUARD_RESULT" \
        "$STEP_GUARD_CLASSIFICATION" \
        "$STEP_GUARD_DETAIL" > "$ARTIFACT_DIR/steps/live_mutation_guard.json"

    build_step_json "live_mutation_attempt" \
        "$STEP_ATTEMPT_RESULT" \
        "$STEP_ATTEMPT_CLASSIFICATION" \
        "$STEP_ATTEMPT_DETAIL" > "$ARTIFACT_DIR/steps/live_mutation_attempt.json"

    if [ -n "$HEALTH_STEP_JSON" ]; then
        printf '%s\n' "$HEALTH_STEP_JSON" > "$ARTIFACT_DIR/steps/health.json"
    fi

    build_evidence_json "billing_run" \
        "$BILLING_RUN_RESULT" \
        "$BILLING_RUN_CLASSIFICATION" \
        "$BILLING_RUN_DETAIL" \
        "$BILLING_RUN_PAYLOAD" > "$ARTIFACT_DIR/billing_run.json"

    build_evidence_json "invoice_rows" \
        "$INVOICE_ROWS_RESULT" \
        "$INVOICE_ROWS_CLASSIFICATION" \
        "$INVOICE_ROWS_DETAIL" \
        "$INVOICE_ROWS_PAYLOAD" > "$ARTIFACT_DIR/invoice_rows.json"

    build_evidence_json "webhook" \
        "$WEBHOOK_RESULT" \
        "$WEBHOOK_CLASSIFICATION" \
        "$WEBHOOK_DETAIL" \
        "$WEBHOOK_PAYLOAD" > "$ARTIFACT_DIR/webhook.json"

    build_evidence_json "invoice_email" \
        "$INVOICE_EMAIL_RESULT" \
        "$INVOICE_EMAIL_CLASSIFICATION" \
        "$INVOICE_EMAIL_DETAIL" \
        "$INVOICE_EMAIL_PAYLOAD" > "$ARTIFACT_DIR/invoice_email.json"
}

write_json_artifact_file() {
    local artifact_path="$1"
    local json_payload="$2"

    if ! is_valid_json "$json_payload"; then
        return 1
    fi

    printf '%s\n' "$json_payload" > "$artifact_path"
    chmod 600 "$artifact_path"
    return 0
}

emit_summary_and_exit() {
    local exit_code="$1"
    local elapsed_ms summary_class_json summary_detail_json artifact_dir_json
    local preflight_step_json metering_step_json guard_step_json attempt_step_json

    emit_required_step_artifacts

    elapsed_ms=$(( $(validation_ms_now) - VALIDATION_START_MS ))
    summary_class_json="$(validation_json_escape "$SUMMARY_CLASSIFICATION")"
    summary_detail_json="$(validation_json_escape "$SUMMARY_DETAIL")"
    artifact_dir_json="$(validation_json_escape "$ARTIFACT_DIR")"

    preflight_step_json="$(build_step_json "preflight" "$STEP_PREFLIGHT_RESULT" "$STEP_PREFLIGHT_CLASSIFICATION" "$STEP_PREFLIGHT_DETAIL")"
    metering_step_json="$(build_step_json "metering_evidence" "$STEP_METERING_RESULT" "$STEP_METERING_CLASSIFICATION" "$STEP_METERING_DETAIL")"
    guard_step_json="$(build_step_json "live_mutation_guard" "$STEP_GUARD_RESULT" "$STEP_GUARD_CLASSIFICATION" "$STEP_GUARD_DETAIL")"
    attempt_step_json="$(build_step_json "live_mutation_attempt" "$STEP_ATTEMPT_RESULT" "$STEP_ATTEMPT_CLASSIFICATION" "$STEP_ATTEMPT_DETAIL")"

    printf '{"result":"%s","classification":%s,"detail":%s,"artifact_dir":%s,"planned_steps":%s,"steps":[%s,%s,%s,%s],"elapsed_ms":%s}\n' \
        "$SUMMARY_RESULT" \
        "$summary_class_json" \
        "$summary_detail_json" \
        "$artifact_dir_json" \
        "$PLANNED_STEPS_JSON" \
        "$preflight_step_json" \
        "$metering_step_json" \
        "$guard_step_json" \
        "$attempt_step_json" \
        "$elapsed_ms" > "$ARTIFACT_DIR/summary.json"

    cat "$ARTIFACT_DIR/summary.json"
    exit "$exit_code"
}

is_repo_default_env_file_name() {
    local env_path="$1"
    local base_name
    base_name="$(basename "$env_path")"
    case "$base_name" in
        .env|.env.local|.env.development|.env.test|.env.local.example)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

validate_explicit_env_file_syntax() {
    local env_file="$1"
    local line line_number=0 parse_status

    if [ ! -f "$env_file" ]; then
        SUMMARY_RESULT="blocked"
        SUMMARY_CLASSIFICATION="explicit_env_file_missing"
        SUMMARY_DETAIL="Explicit staging env file does not exist: ${env_file}"
        return 1
    fi

    if [ ! -r "$env_file" ]; then
        SUMMARY_RESULT="blocked"
        SUMMARY_CLASSIFICATION="explicit_env_file_unreadable"
        SUMMARY_DETAIL="Explicit staging env file is not readable: ${env_file}"
        return 1
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))
        parse_env_assignment_line "$line" && parse_status=0 || parse_status=$?
        if [ "$parse_status" -eq 0 ] || [ "$parse_status" -eq 2 ]; then
            continue
        fi

        SUMMARY_RESULT="blocked"
        SUMMARY_CLASSIFICATION="env_file_parse_failed"
        SUMMARY_DETAIL="Unsupported syntax in ${env_file} at line ${line_number}; only KEY=value assignments are allowed."
        return 1
    done < "$env_file"

    return 0
}

capture_health_artifact() {
    local health_url timeout_sec
    health_url="${STAGING_API_URL%/}/health"
    timeout_sec="$(rehearsal_http_timeout_sec)"
    if _gate_timeout "$timeout_sec" \
        curl -fsS --connect-timeout "$timeout_sec" --max-time "$timeout_sec" \
        "$health_url" >/dev/null 2>&1; then
        HEALTH_STEP_JSON="$(build_step_json "health" "passed" "healthy" "API responded at ${health_url}.")"
        return 0
    fi

    HEALTH_STEP_JSON="$(build_step_json "health" "failed" "staging_api_unreachable" "API health probe failed at ${health_url}.")"
    SUMMARY_RESULT="failed"
    SUMMARY_CLASSIFICATION="staging_api_unreachable"
    SUMMARY_DETAIL="Health probe failed after preflight succeeded."
    return 1
}

run_preflight_owner() {
    local preflight_output="" preflight_exit=0 preflight_passed preflight_classification
    set +e
    preflight_output="$(bash "$RUNNER_DIR/staging_billing_dry_run.sh" --check --env-file "$ENV_FILE" 2>&1)"
    preflight_exit=$?
    set -e

    preflight_classification="$(validation_json_get_field "$preflight_output" "classification")"
    preflight_passed="$(validation_json_get_field "$preflight_output" "passed")"

    [ -n "$preflight_classification" ] || preflight_classification="preflight_output_invalid"

    local extracted_planned_steps
    extracted_planned_steps="$(extract_json_array_field "$preflight_output" "planned_steps")"
    if [ "$extracted_planned_steps" != "[]" ]; then
        PLANNED_STEPS_JSON="$extracted_planned_steps"
    fi

    if [ "$preflight_exit" -eq 0 ] && [ "$preflight_passed" = "true" ]; then
        STEP_PREFLIGHT_RESULT="passed"
        STEP_PREFLIGHT_CLASSIFICATION="$preflight_classification"
        STEP_PREFLIGHT_DETAIL="$preflight_output"
        return 0
    fi

    STEP_PREFLIGHT_RESULT="failed"
    STEP_PREFLIGHT_CLASSIFICATION="$preflight_classification"
    STEP_PREFLIGHT_DETAIL="$preflight_output"

    SUMMARY_RESULT="failed"
    SUMMARY_CLASSIFICATION="$preflight_classification"
    SUMMARY_DETAIL="Preflight owner failed; later steps remain blocked."
    return 1
}

extract_reason_code() {
    local check_output="$1"
    local reason_line
    reason_line="$(printf '%s\n' "$check_output" | grep -m1 '^REASON:' || true)"
    if [ -n "$reason_line" ]; then
        _strip_reason_prefix "$reason_line"
    else
        printf 'metering_check_failed\n'
    fi
}

run_metering_check() {
    local check_fn="$1"
    local check_label="$2"
    local check_output="" check_exit=0 reason_code=""

    set +e
    check_output="$(
        (
            export BACKEND_LIVE_GATE=1
            "$check_fn"
        ) 2>&1
    )"
    check_exit=$?
    set -e

    if [ "$check_exit" -eq 0 ]; then
        return 0
    fi

    reason_code="$(extract_reason_code "$check_output")"
    STEP_METERING_RESULT="blocked"
    STEP_METERING_CLASSIFICATION="$reason_code"
    STEP_METERING_DETAIL="${check_label} failed: ${check_output}"
    SUMMARY_RESULT="blocked"
    SUMMARY_CLASSIFICATION="$reason_code"
    SUMMARY_DETAIL="Metering evidence failed and blocked live mutation."
    return 1
}

run_metering_evidence_step() {
    if ! run_metering_check "check_usage_records_populated" "usage_records check"; then
        return 1
    fi
    if ! run_metering_check "check_rollup_current" "usage_daily freshness check"; then
        return 1
    fi

    STEP_METERING_RESULT="passed"
    STEP_METERING_CLASSIFICATION="metering_evidence_ready"
    STEP_METERING_DETAIL="usage_records and usage_daily checks passed."
    return 0
}

capture_http_json_response() {
    local response curl_status=0 timeout_sec
    timeout_sec="$(rehearsal_http_timeout_sec)"
    set +e
    response="$(_gate_timeout "$timeout_sec" \
        curl --connect-timeout "$timeout_sec" --max-time "$timeout_sec" \
        -sS "$@" -w "\n%{http_code}" 2>/dev/null)"
    curl_status=$?
    set -e

    if [ "$curl_status" -ne 0 ]; then
        HTTP_RESPONSE_BODY=""
        HTTP_RESPONSE_CODE=""
        return "$curl_status"
    fi

    HTTP_RESPONSE_CODE="$(printf '%s\n' "$response" | tail -1)"
    HTTP_RESPONSE_BODY="$(printf '%s\n' "$response" | sed '$d')"
    return 0
}

rehearsal_http_timeout_sec() {
    printf '%s\n' "${REHEARSAL_HTTP_TIMEOUT_SEC:-10}"
}

run_rehearsal_db_query() {
    local sql="$1"
    local db_url output status

    db_url="$(_metering_db_url)"
    if [ -z "$db_url" ]; then
        REHEARSAL_QUERY_OUTPUT=""
        return 30
    fi

    set +e
    output="$(_gate_timeout "${REHEARSAL_DB_TIMEOUT_SEC:-10}" \
        env PGCONNECTTIMEOUT=5 psql -tAq "$db_url" \
        -c "SET statement_timeout TO 10000" \
        -c "$sql" 2>&1)"
    status=$?
    set -e

    REHEARSAL_QUERY_OUTPUT="$output"

    if [ "$status" -eq 0 ]; then
        return 0
    fi
    if [ "$status" -eq 124 ]; then
        return 124
    fi
    if echo "$output" | grep -Eqi 'statement timeout|canceling statement due to statement timeout'; then
        return 20
    fi
    if echo "$output" | grep -Eqi 'could not connect|connection refused|timeout expired|no route to host|could not translate host name'; then
        return 21
    fi
    return 22
}
run_live_mutation_guard() {
    if [ -z "$BILLING_MONTH" ]; then
        STEP_GUARD_RESULT="blocked"
        STEP_GUARD_CLASSIFICATION="billing_month_required"
        STEP_GUARD_DETAIL="Provide --month YYYY-MM before live mutation."
        SUMMARY_RESULT="blocked"
        SUMMARY_CLASSIFICATION="billing_month_required"
        SUMMARY_DETAIL="Live mutation refused because billing month is missing."
        return 1
    fi

    if [ "$CONFIRM_LIVE_MUTATION" -ne 1 ]; then
        STEP_GUARD_RESULT="blocked"
        STEP_GUARD_CLASSIFICATION="live_mutation_confirmation_required"
        STEP_GUARD_DETAIL="Provide --confirm-live-mutation to acknowledge live mutation intent."
        SUMMARY_RESULT="blocked"
        SUMMARY_CLASSIFICATION="live_mutation_confirmation_required"
        SUMMARY_DETAIL="Live mutation refused because confirmation flag is missing."
        return 1
    fi

    if [ -z "${ADMIN_KEY:-}" ]; then
        STEP_GUARD_RESULT="blocked"
        STEP_GUARD_CLASSIFICATION="admin_key_missing"
        STEP_GUARD_DETAIL="ADMIN_KEY is required for authenticated live mutation paths."
        SUMMARY_RESULT="blocked"
        SUMMARY_CLASSIFICATION="admin_key_missing"
        SUMMARY_DETAIL="Live mutation refused because ADMIN_KEY is missing."
        return 1
    fi

    if [ -z "$(_metering_db_url)" ]; then
        STEP_GUARD_RESULT="blocked"
        STEP_GUARD_CLASSIFICATION="db_url_missing"
        STEP_GUARD_DETAIL="Either DATABASE_URL or INTEGRATION_DB_URL is required for billing evidence."
        SUMMARY_RESULT="blocked"
        SUMMARY_CLASSIFICATION="db_url_missing"
        SUMMARY_DETAIL="Live mutation refused because DB evidence path is missing."
        return 1
    fi

    STEP_GUARD_RESULT="passed"
    STEP_GUARD_CLASSIFICATION="live_mutation_guard_passed"
    STEP_GUARD_DETAIL="Live mutation preconditions are satisfied."
    return 0
}

staging_billing_rehearsal_main_impl() {
    # Rehearsal artifacts and transient evidence can include invoice IDs,
    # customer emails, and operator-supplied credentials.
    umask 077
    PLANNED_STEPS_JSON="$(billing_rehearsal_planned_steps_json)"
    init_artifact_dir
    run_rehearsal_flow "$@"
    if [ "$SUMMARY_RESULT" = "passed" ]; then
        emit_summary_and_exit 0
    fi
    emit_summary_and_exit 1
}
