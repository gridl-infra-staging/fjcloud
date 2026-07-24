# shellcheck source=psql_path.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/psql_path.sh"
# shellcheck source=deployable_currency.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/deployable_currency.sh"
# shellcheck source=staging_billing_input_env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/staging_billing_input_env.sh"
ENV_FILE=""
BILLING_MONTH=""
CONFIRM_LIVE_MUTATION=0
RESET_TEST_STATE=0
RESET_FIRST=0
CONFIRM_TEST_TENANT_ID=""

ARTIFACT_DIR=""
SUMMARY_RESULT="blocked"
SUMMARY_CLASSIFICATION="not_started"
SUMMARY_DETAIL="Rehearsal has not started."
SUMMARY_DEV_SHA="unknown"
PLANNED_STEPS_JSON="[]"
SUMMARY_DEPLOYABLE_DRIFT="unknown"
SUMMARY_DOC_ONLY_AHEAD="unknown"

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
    printf '%s' "$1" | python3 -c 'import json, sys; json.load(sys.stdin)' >/dev/null 2>&1
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
    clear_staging_billing_input_env
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
    local dev_sha_json deployable_drift_json doc_only_ahead_json

    emit_required_step_artifacts

    elapsed_ms=$(( $(validation_ms_now) - VALIDATION_START_MS ))
    summary_class_json="$(validation_json_escape "$SUMMARY_CLASSIFICATION")"
    summary_detail_json="$(validation_json_escape "$SUMMARY_DETAIL")"
    artifact_dir_json="$(validation_json_escape "$ARTIFACT_DIR")"
    dev_sha_json="$(validation_json_escape "$SUMMARY_DEV_SHA")"
    deployable_drift_json="$(deployable_currency_json_value "$SUMMARY_DEPLOYABLE_DRIFT")"
    doc_only_ahead_json="$(deployable_currency_json_value "$SUMMARY_DOC_ONLY_AHEAD")"

    preflight_step_json="$(build_step_json "preflight" "$STEP_PREFLIGHT_RESULT" "$STEP_PREFLIGHT_CLASSIFICATION" "$STEP_PREFLIGHT_DETAIL")"
    metering_step_json="$(build_step_json "metering_evidence" "$STEP_METERING_RESULT" "$STEP_METERING_CLASSIFICATION" "$STEP_METERING_DETAIL")"
    guard_step_json="$(build_step_json "live_mutation_guard" "$STEP_GUARD_RESULT" "$STEP_GUARD_CLASSIFICATION" "$STEP_GUARD_DETAIL")"
    attempt_step_json="$(build_step_json "live_mutation_attempt" "$STEP_ATTEMPT_RESULT" "$STEP_ATTEMPT_CLASSIFICATION" "$STEP_ATTEMPT_DETAIL")"

    printf '{"result":"%s","classification":%s,"detail":%s,"artifact_dir":%s,"dev_sha":%s,"deployable_currency":{"deployable_drift":%s,"doc_only_ahead":%s},"planned_steps":%s,"steps":[%s,%s,%s,%s],"elapsed_ms":%s}\n' \
        "$SUMMARY_RESULT" \
        "$summary_class_json" \
        "$summary_detail_json" \
        "$artifact_dir_json" "$dev_sha_json" "$deployable_drift_json" "$doc_only_ahead_json" \
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

set_deployable_currency_blocker() {
    SUMMARY_RESULT="blocked"
    SUMMARY_CLASSIFICATION="$1"
    SUMMARY_DETAIL="$2"
    STEP_PREFLIGHT_RESULT="blocked"
    STEP_PREFLIGHT_CLASSIFICATION="$1"
    STEP_PREFLIGHT_DETAIL="$2"
}

capture_deployable_currency_status() {
    local deploy_status_script="${STAGING_REHEARSAL_DEPLOY_STATUS_SCRIPT:-$RUNNER_DIR/deploy_status.sh}"
    local parsed detail

    if ! parsed="$(probe_staging_deployable_currency "$deploy_status_script")"; then
        detail="${parsed#*|}"; detail="${detail#*|}"; detail="${detail#*|}"
        set_deployable_currency_blocker "deployable_currency_unknown" "$detail"
        return 1
    fi
    SUMMARY_DEV_SHA="${parsed%%|*}"
    parsed="${parsed#*|}"
    SUMMARY_DEPLOYABLE_DRIFT="${parsed%%|*}"
    SUMMARY_DOC_ONLY_AHEAD="${parsed#*|}"

    case "$SUMMARY_DEPLOYABLE_DRIFT:$SUMMARY_DOC_ONLY_AHEAD" in
        true:*|false:true|false:false) ;;
        *)
            set_deployable_currency_blocker "deployable_currency_unknown" \
                "Deployable-currency probe returned unknown staging currency; live rehearsal remains blocked."
            return 1
            ;;
    esac

    if [ "$SUMMARY_DEPLOYABLE_DRIFT" = "true" ]; then
        set_deployable_currency_blocker "deployable_currency_drift" \
            "Staging deploy is behind deployable dev changes; deploy staging before running billing rehearsal."
        return 1
    fi
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
        if ! capture_deployable_currency_status; then
            return 1
        fi
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

has_rehearsal_db_evidence_access() {
    local staging_db_query_script="${STAGING_DB_QUERY_SCRIPT:-$RUNNER_DIR/launch/ssm_exec_staging.sh}"

    [ -n "$(_metering_db_url)" ] || [ -x "$staging_db_query_script" ]
}

sql_quote_for_remote_shell() {
    printf '%s' "$1" | sed "s/'/'\"'\"'/g"
}

build_staging_rehearsal_remote_sql_command() {
    local sql_query="$1"
    local escaped_sql

    escaped_sql="$(sql_quote_for_remote_shell "$sql_query")"
    cat <<EOF
set -euo pipefail
if [[ -z "\${DATABASE_URL:-}" && -r /etc/fjcloud/env ]]; then
    source /etc/fjcloud/env
fi
if [[ -z "\${DATABASE_URL:-}" ]]; then
    echo "DATABASE_URL is required on staging host for rehearsal DB queries" >&2
    exit 30
fi
psql -tAq "\$DATABASE_URL" -c "SET statement_timeout TO 10000" -c '$escaped_sql'
EOF
}

run_rehearsal_staging_db_query() {
    local sql="$1"
    local staging_db_query_script="${STAGING_DB_QUERY_SCRIPT:-$RUNNER_DIR/launch/ssm_exec_staging.sh}"
    local remote_command output status

    if [ ! -x "$staging_db_query_script" ]; then
        REHEARSAL_QUERY_OUTPUT=""
        return 30
    fi

    remote_command="$(build_staging_rehearsal_remote_sql_command "$sql")"
    set +e
    output="$("$staging_db_query_script" "$remote_command" 2>&1)"
    status=$?
    set -e

    REHEARSAL_QUERY_OUTPUT="$output"

    if [ "$status" -eq 0 ]; then
        return 0
    fi
    if [ "$status" -eq 124 ]; then
        return 124
    fi
    if [ "$status" -eq 30 ] || echo "$output" | grep -Eqi 'DATABASE_URL is required'; then
        return 30
    fi
    if echo "$output" | grep -Eqi 'statement timeout|canceling statement due to statement timeout'; then
        return 20
    fi
    if echo "$output" | grep -Eqi 'could not connect|connection refused|timeout expired|no route to host|could not translate host name'; then
        return 21
    fi
    return 22
}

run_rehearsal_db_query() {
    local sql="$1"
    local db_url output status

    db_url="$(_metering_db_url)"
    if [ -z "$db_url" ]; then
        run_rehearsal_staging_db_query "$sql"
        return $?
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

# Builds the SQL IN-list payload from FJCLOUD_TEST_TENANT_IDS. When the allowlist
# is empty we substitute a sentinel that matches no real customer, so the lookup
# is still well-formed but cannot accidentally match production tenants.
existing_same_month_tenant_in_list() {
    local allowlist="${FJCLOUD_TEST_TENANT_IDS:-}"
    local rendered
    if [ "${RESET_FIRST:-0}" -eq 1 ] && [ -n "${CONFIRM_TEST_TENANT_ID:-}" ]; then
        allowlist="$CONFIRM_TEST_TENANT_ID"
    fi
    rendered="$(python3 - "$allowlist" <<'PY' || true
import sys
raw = sys.argv[1] if len(sys.argv) > 1 else ""
parts = [p.strip() for p in raw.split(",") if p.strip()]
print(",".join("'" + p.replace("'", "''") + "'" for p in parts))
PY
)"
    if [ -z "$rendered" ]; then
        rendered="'__fjcloud_no_allowlisted_tenant__'"
    fi
    printf '%s' "$rendered"
}
# Queries for reusable invoice rows already recorded for BILLING_MONTH under
# the test-tenant allowlist. Populates REHEARSAL_QUERY_OUTPUT
# on success (rows may be empty). Returns the underlying run_rehearsal_db_query
# status so callers can distinguish DB failures from a clean "no rows" result.
run_existing_same_month_invoice_lookup() {
    local month="$1"
    local in_list sql
    in_list="$(existing_same_month_tenant_in_list)"
    sql="SELECT i.id::text || '|' || c.id::text || '|' || COALESCE(i.stripe_invoice_id,'') || '|' || COALESCE(i.hosted_invoice_url,'') || '|' || COALESCE(to_char(i.paid_at AT TIME ZONE 'utc','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),'') || '|' || COALESCE(c.email,'') FROM invoices i JOIN customers c ON c.id = i.customer_id WHERE to_char(i.period_start,'YYYY-MM') = '${month}' AND c.id::text IN (${in_list}) AND i.stripe_invoice_id IS NOT NULL AND i.hosted_invoice_url IS NOT NULL AND i.paid_at IS NOT NULL /* stage3_existing_same_month_invoice_rows */"
    run_rehearsal_db_query "$sql"
}

# Parses the canonical same-month lookup output. Only complete allowlisted rows
# are reusable repeat-pass evidence; notices, warnings, wrapper text, and
# unrelated customer rows are ignored.
parse_existing_same_month_invoice_rows() {
    python3 - "$1" <<'PY' || true
import json
import os
import sys

raw = sys.argv[1]
invoice_ids = []
tenant_ids = []
allowlisted_tenants = {
    item.strip()
    for item in os.environ.get("FJCLOUD_TEST_TENANT_IDS", "").split(",")
    if item.strip()
}
confirmed_tenant = os.environ.get("CONFIRM_TEST_TENANT_ID", "").strip()
if os.environ.get("RESET_FIRST") == "1" and confirmed_tenant:
    allowlisted_tenants = {confirmed_tenant}
seen_tenants = set()
for line in raw.splitlines():
    line = line.strip()
    if not line:
        continue
    fields = [field.strip() for field in line.split("|")]
    if len(fields) != 6:
        continue
    invoice_id, tenant_id, stripe_invoice_id, hosted_invoice_url, paid_at, email = fields
    if not all([invoice_id, tenant_id, stripe_invoice_id, hosted_invoice_url, paid_at, email]):
        continue
    if tenant_id not in allowlisted_tenants:
        continue
    if invoice_id:
        invoice_ids.append(invoice_id)
    if tenant_id and tenant_id not in seen_tenants:
        seen_tenants.add(tenant_id)
        tenant_ids.append(tenant_id)
print(json.dumps({"invoice_ids": invoice_ids, "tenant_ids": tenant_ids}))
PY
}

same_month_invoice_rows_json_field() {
    python3 - "$1" "$2" <<'PY' || true
import json
import sys

payload = json.loads(sys.argv[1])
field_name = sys.argv[2]
print(json.dumps(payload.get(field_name, [])))
PY
}

# Extracts the invoice-id column from REHEARSAL_QUERY_OUTPUT into a JSON array,
# preserving order and skipping rows that are not reusable rehearsal evidence.
parse_existing_same_month_invoice_ids() {
    same_month_invoice_rows_json_field "$(parse_existing_same_month_invoice_rows "$1")" "invoice_ids"
}

parse_existing_same_month_invoice_tenant_ids() {
    same_month_invoice_rows_json_field "$(parse_existing_same_month_invoice_rows "$1")" "tenant_ids"
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

    if ! has_rehearsal_db_evidence_access; then
        STEP_GUARD_RESULT="blocked"
        STEP_GUARD_CLASSIFICATION="db_url_missing"
        STEP_GUARD_DETAIL="Either DATABASE_URL/INTEGRATION_DB_URL or an executable staging DB query owner is required for billing evidence."
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
