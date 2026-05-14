#!/usr/bin/env bash
# probe_organic_alert_dispatch.sh — staging in-process invoice failure alert probe.
#
# This probe seeds a synthetic finalized invoice in staging, replays a signed
# invoice.payment_failed webhook to the deployed API, then verifies the alert
# row persisted with delivery_status='sent'.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=lib/staging_db.sh
source "$SCRIPT_DIR/lib/staging_db.sh"
# shellcheck source=lib/validation_json.sh
source "$SCRIPT_DIR/lib/validation_json.sh"

append_step() { validation_append_step "$@"; }
emit_result() { validation_emit_result "$@"; }

SANCTIONED_STAGING_API_URL="https://api.flapjack.foo"
DEFAULT_SECRET_FILE="${FJCLOUD_SECRET_FILE:-$REPO_ROOT/.secret/.env.secret}"
REPLAY_FIXTURE_BIN_DEFAULT="$SCRIPT_DIR/stripe_webhook_replay_fixture.sh"
DEFAULT_DATABASE_URL_SSM_PARAM="/fjcloud/staging/database_url"
DEFAULT_DISCORD_WEBHOOK_URL_SSM_PARAM="/fjcloud/staging/discord_webhook_url"
DEFAULT_SSM_INSTANCE_ID="i-0afc7651593f12372"
EVIDENCE_ROOT="${ORGANIC_ALERT_EVIDENCE_ROOT:-$REPO_ROOT/docs/runbooks/evidence/alert-delivery}"

PROBE_RESULT="failed"
PROBE_RESULT_DETAIL=""
PROBE_DEPLOYED_SHA="<unknown>"
PROBE_DATE_UTC=""
PROBE_BUNDLE_TS=""
PROBE_BUNDLE_DIR=""
PROBE_STDOUT_LOG=""
PROBE_STDERR_LOG=""
PROBE_REPLAY_COMMAND=""
PROBE_ALERT_QUERY_RESULT="<empty>"
PROBE_CLEANUP_CONFIRMATION="not-run"
PROBE_FAILURE_ALERT_ROWS_PATH=""
PROBE_FAILURE_JOURNALCTL_PATH=""

PROBE_EMAIL=""
PROBE_CUSTOMER_ID=""
PROBE_INVOICE_ID=""
PROBE_STRIPE_INVOICE_ID=""
PROBE_ALERT_ID=""

API_URL_NORMALIZED=""
DISCORD_WEBHOOK_URL=""
REPLAY_FIXTURE_BIN="${REPLAY_FIXTURE_BIN:-}"
POLL_MAX_ATTEMPTS="${ORGANIC_ALERT_POLL_MAX_ATTEMPTS:-30}"
POLL_SLEEP_SECONDS="${ORGANIC_ALERT_POLL_SLEEP_SECONDS:-2}"
STRIPE_WEBHOOK_SECRET_SSM_PARAM="${STRIPE_WEBHOOK_SECRET_SSM_PARAM:-/fjcloud/staging/stripe_webhook_secret}"
DISCORD_WEBHOOK_URL_SSM_PARAM="${DISCORD_WEBHOOK_URL_SSM_PARAM:-$DEFAULT_DISCORD_WEBHOOK_URL_SSM_PARAM}"

usage() {
    cat <<'USAGE'
Usage:
  bash scripts/probe_organic_alert_dispatch.sh
  bash scripts/probe_organic_alert_dispatch.sh --help

Environment:
  API_URL                Optional. Unset defaults to https://api.flapjack.foo.
                         If set explicitly, it must be non-empty and exactly
                         the sanctioned staging target.
  REPLAY_FIXTURE_BIN     Optional override for webhook replay fixture script.
  DATABASE_URL_SSM_PARAM Optional DB source. Defaults to
                         /fjcloud/staging/database_url.
  DATABASE_URL           Optional direct DB URL, requires SSM_INSTANCE_ID.
  SSM_INSTANCE_ID        Optional staging API instance id. Defaults to
                         i-0afc7651593f12372.
  DISCORD_WEBHOOK_URL_SSM_PARAM
                         Optional webhook parameter path. Defaults to
                         /fjcloud/staging/discord_webhook_url.
  AWS_DEFAULT_REGION     Optional AWS region (default: us-east-1).

Notes:
  - Uses scripts/lib/staging_db.sh::staging_db_run_sql for all DB calls.
  - Uses scripts/stripe_webhook_replay_fixture.sh for signed webhook replay.
USAGE
}

trim_compact() {
    printf '%s' "$1" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

sql_escape_literal() {
    printf '%s' "$1" | sed "s/'/''/g"
}

first_data_row() {
    printf '%s\n' "$1" | awk '
        /^[[:space:]]*$/ { next }
        /^-+$/ { next }
        /^\([0-9]+ rows?\)$/ { next }
        /^[[:space:]]*id[[:space:]]*\|/ { next }
        /^[[:space:]]*delivery_status[[:space:]]*$/ { next }
        {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
            if (length($0) > 0) {
                print $0
                exit
            }
        }
    '
}

require_positive_integer() {
    local value="$1"
    local name="$2"
    if [[ ! "$value" =~ ^[0-9]+$ ]] || [ "$value" -le 0 ]; then
        echo "ERROR: $name must be a positive integer (got '$value')." >&2
        exit 2
    fi
}

init_bundle_paths() {
    PROBE_DATE_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    PROBE_BUNDLE_TS="$(date -u +%Y%m%dT%H%M%SZ)"
    PROBE_BUNDLE_DIR="$EVIDENCE_ROOT/${PROBE_BUNDLE_TS}_organic_dispatch_probe"
    PROBE_STDOUT_LOG="$PROBE_BUNDLE_DIR/probe_stdout.log"
    PROBE_STDERR_LOG="$PROBE_BUNDLE_DIR/probe_stderr.log"
    PROBE_FAILURE_ALERT_ROWS_PATH="$PROBE_BUNDLE_DIR/failure_alert_rows.txt"
    PROBE_FAILURE_JOURNALCTL_PATH="$PROBE_BUNDLE_DIR/failure_journalctl_fjcloud_api.txt"
}

setup_bundle_logging() {
    mkdir -p "$PROBE_BUNDLE_DIR"
    : >"$PROBE_STDOUT_LOG"
    : >"$PROBE_STDERR_LOG"
    exec > >(tee -a "$PROBE_STDOUT_LOG") 2> >(tee -a "$PROBE_STDERR_LOG" >&2)
}

run_sql() {
    local sql="$1"
    local output cleaned

    if output="$(staging_db_run_sql "$DATABASE_URL" "$sql" 2>&1)"; then
        cleaned="$(printf '%s\n' "$output" | sed -E '/^\[staging_db\] /d')"
        printf '%s\n' "$cleaned"
        return 0
    fi

    # Compatibility seam: staging_db_run_sql currently parses SSM output with
    # a fragile text assumption and may return non-zero even when status is
    # actually Success. Keep staging_db_run_sql as the owner, but recover the
    # remote psql stdout for this known formatting case.
    if [[ "$output" == *"status=Success"* ]]; then
        cleaned="$(printf '%s\n' "$output" | sed -E '1s/^.*\):[[:space:]]*//' | sed -E '/^\[staging_db\] /d')"
        printf '%s\n' "$cleaned"
        return 0
    fi

    printf '%s\n' "$output" >&2
    return 1
}

capture_failure_diagnostics() {
    local escaped_invoice
    escaped_invoice="$(sql_escape_literal "$PROBE_INVOICE_ID")"

    {
        printf 'invoice_id=%s\n\n' "$PROBE_INVOICE_ID"
        run_sql "SELECT id::text, delivery_status, severity, title, created_at FROM alerts WHERE metadata->>'invoice_id' = '$escaped_invoice' ORDER BY created_at DESC LIMIT 5;" || true
    } >"$PROBE_FAILURE_ALERT_ROWS_PATH" 2>&1

    if [ -x "$SCRIPT_DIR/launch/ssm_exec_staging.sh" ]; then
        if "$SCRIPT_DIR/launch/ssm_exec_staging.sh" "journalctl -u fjcloud-api -n 200 --no-pager" >"$PROBE_FAILURE_JOURNALCTL_PATH" 2>&1; then
            :
        else
            {
                echo "journalctl capture command exited non-zero"
                cat "$PROBE_FAILURE_JOURNALCTL_PATH" 2>/dev/null || true
            } >"$PROBE_FAILURE_JOURNALCTL_PATH"
        fi
    else
        echo "journalctl capture skipped: missing scripts/launch/ssm_exec_staging.sh" >"$PROBE_FAILURE_JOURNALCTL_PATH"
    fi
}

runtime_fail() {
    local step_name="$1"
    local detail="$2"
    local with_diagnostics="${3:-false}"

    append_step "$step_name" false "$detail"
    PROBE_RESULT="failed"
    PROBE_RESULT_DETAIL="$detail"
    if [ "$with_diagnostics" = "true" ]; then
        capture_failure_diagnostics
    fi
    exit 1
}

write_summary() {
    local final_result="$1"
    local final_exit_code="$2"
    cat >"$PROBE_BUNDLE_DIR/SUMMARY.md" <<EOF
# Organic Alert Dispatch Probe Summary

- Date (UTC): ${PROBE_DATE_UTC}
- Result: ${final_result}
- Exit code: ${final_exit_code}
- Deployed SHA (SSM /fjcloud/staging/last_deploy_sha): ${PROBE_DEPLOYED_SHA}
- API URL: ${API_URL_NORMALIZED}
- Seed customer email: ${PROBE_EMAIL}
- Seed customer UUID: ${PROBE_CUSTOMER_ID}
- Seed invoice UUID: ${PROBE_INVOICE_ID}
- Seed stripe_invoice_id: ${PROBE_STRIPE_INVOICE_ID}
- Replay command: ${PROBE_REPLAY_COMMAND}
- Alert query result: ${PROBE_ALERT_QUERY_RESULT}
- Cleanup confirmation: ${PROBE_CLEANUP_CONFIRMATION}
- Probe stdout log: ${PROBE_STDOUT_LOG#$REPO_ROOT/}
- Probe stderr log: ${PROBE_STDERR_LOG#$REPO_ROOT/}
- Failure alert rows: $([ -f "$PROBE_FAILURE_ALERT_ROWS_PATH" ] && echo "${PROBE_FAILURE_ALERT_ROWS_PATH#$REPO_ROOT/}" || echo "n/a (probe passed)")
- Failure journalctl capture: $([ -f "$PROBE_FAILURE_JOURNALCTL_PATH" ] && echo "${PROBE_FAILURE_JOURNALCTL_PATH#$REPO_ROOT/}" || echo "n/a (probe passed)")
- Detail: ${PROBE_RESULT_DETAIL:-none}
EOF
}

cleanup() {
    local original_exit_code=$?
    local final_exit_code="$original_exit_code"
    local cleanup_errors=()
    local escaped_id

    set +e

    if [ -n "$PROBE_ALERT_ID" ]; then
        escaped_id="$(sql_escape_literal "$PROBE_ALERT_ID")"
        run_sql "DELETE FROM alerts WHERE id = '$escaped_id'::uuid;" >/dev/null 2>&1 || cleanup_errors+=("alerts:${PROBE_ALERT_ID}")
    fi

    if [ -n "$PROBE_INVOICE_ID" ]; then
        escaped_id="$(sql_escape_literal "$PROBE_INVOICE_ID")"
        run_sql "DELETE FROM alerts WHERE metadata->>'invoice_id' = '$escaped_id';" >/dev/null 2>&1 || cleanup_errors+=("alerts_by_metadata:${PROBE_INVOICE_ID}")
        run_sql "DELETE FROM invoices WHERE id = '$escaped_id'::uuid;" >/dev/null 2>&1 || cleanup_errors+=("invoices:${PROBE_INVOICE_ID}")
    fi

    if [ -n "$PROBE_CUSTOMER_ID" ]; then
        escaped_id="$(sql_escape_literal "$PROBE_CUSTOMER_ID")"
        run_sql "DELETE FROM customers WHERE id = '$escaped_id'::uuid;" >/dev/null 2>&1 || cleanup_errors+=("customers:${PROBE_CUSTOMER_ID}")
    fi

    if [ "${#cleanup_errors[@]}" -eq 0 ]; then
        PROBE_CLEANUP_CONFIRMATION="deleted captured rows only"
        append_step "cleanup" true "Deleted captured probe-owned alerts/invoices/customers."
    else
        PROBE_CLEANUP_CONFIRMATION="cleanup errors: ${cleanup_errors[*]}"
        append_step "cleanup" false "Cleanup failed for: ${cleanup_errors[*]}"
        final_exit_code=1
    fi

    if [ "$final_exit_code" -eq 0 ]; then
        PROBE_RESULT="passed"
        write_summary "PASS" "$final_exit_code"
        emit_result true
    else
        PROBE_RESULT="failed"
        if [ -z "$PROBE_RESULT_DETAIL" ]; then
            PROBE_RESULT_DETAIL="probe failed before completion"
        fi
        write_summary "FAIL" "$final_exit_code"
        emit_result false
    fi

    exit "$final_exit_code"
}

main() {
    if [ "${1:-}" = "--help" ]; then
        usage
        exit 0
    fi
    if [ "$#" -ne 0 ]; then
        echo "ERROR: unsupported argument(s): $*" >&2
        usage
        exit 2
    fi

    if [ -f "$DEFAULT_SECRET_FILE" ]; then
        load_env_file "$DEFAULT_SECRET_FILE"
    fi

    DATABASE_URL_SSM_PARAM="${DATABASE_URL_SSM_PARAM:-$DEFAULT_DATABASE_URL_SSM_PARAM}"
    DISCORD_WEBHOOK_URL_SSM_PARAM="${DISCORD_WEBHOOK_URL_SSM_PARAM:-$DEFAULT_DISCORD_WEBHOOK_URL_SSM_PARAM}"
    SSM_INSTANCE_ID="${SSM_INSTANCE_ID:-$DEFAULT_SSM_INSTANCE_ID}"
    export DATABASE_URL_SSM_PARAM DISCORD_WEBHOOK_URL_SSM_PARAM SSM_INSTANCE_ID
    # staging_db.sh snapshots the instance-id override at source time, so keep
    # its cache aligned with the finalized staging default or explicit override.
    _STAGING_DB_INSTANCE_ID="$SSM_INSTANCE_ID"

    init_bundle_paths
    setup_bundle_logging
    trap cleanup EXIT

    require_positive_integer "$POLL_MAX_ATTEMPTS" "ORGANIC_ALERT_POLL_MAX_ATTEMPTS"
    require_positive_integer "$POLL_SLEEP_SECONDS" "ORGANIC_ALERT_POLL_SLEEP_SECONDS"

    REPLAY_FIXTURE_BIN="${REPLAY_FIXTURE_BIN:-$REPLAY_FIXTURE_BIN_DEFAULT}"
    if [ ! -f "$REPLAY_FIXTURE_BIN" ] || [ ! -r "$REPLAY_FIXTURE_BIN" ]; then
        runtime_fail "preflight" "Replay fixture script is missing or not readable at $REPLAY_FIXTURE_BIN."
    fi

    if [ "${API_URL+x}" = "x" ]; then
        if [ -z "$API_URL" ]; then
            runtime_fail "preflight" "API_URL was set explicitly but resolved to an empty value."
        fi
        API_URL_NORMALIZED="${API_URL%/}"
    else
        API_URL_NORMALIZED="$SANCTIONED_STAGING_API_URL"
    fi
    if [ "$API_URL_NORMALIZED" != "$SANCTIONED_STAGING_API_URL" ]; then
        runtime_fail "preflight" "API_URL must be the sanctioned staging target ($SANCTIONED_STAGING_API_URL); got '$API_URL_NORMALIZED'."
    fi

    if [ -n "${DATABASE_URL:-}" ] && [ -z "${SSM_INSTANCE_ID:-}" ]; then
        runtime_fail "preflight" "When DATABASE_URL is provided directly, SSM_INSTANCE_ID is required for staging_db.sh."
    fi

    append_step "preflight" true "Replay fixture, API target, and DB env requirements are satisfied."

    if [ -z "${DATABASE_URL:-}" ]; then
        if [ -z "${DATABASE_URL_SSM_PARAM:-}" ]; then
            runtime_fail "hydrate_database_url" "DATABASE_URL_SSM_PARAM is required when DATABASE_URL is unset."
        fi
        if ! DATABASE_URL="$(aws ssm get-parameter --name "$DATABASE_URL_SSM_PARAM" --with-decryption --query 'Parameter.Value' --output text --region "${AWS_DEFAULT_REGION:-us-east-1}")"; then
            runtime_fail "hydrate_database_url" "Failed to resolve DATABASE_URL from SSM parameter '$DATABASE_URL_SSM_PARAM'."
        fi
        if [ -z "$DATABASE_URL" ] || [ "$DATABASE_URL" = "None" ]; then
            runtime_fail "hydrate_database_url" "SSM parameter '$DATABASE_URL_SSM_PARAM' returned an empty DATABASE_URL."
        fi
    fi
    append_step "hydrate_database_url" true "Hydrated DATABASE_URL once and reused for subsequent staging_db_run_sql calls."

    if ! PROBE_DEPLOYED_SHA="$(aws ssm get-parameter --name "/fjcloud/staging/last_deploy_sha" --with-decryption --query 'Parameter.Value' --output text --region "${AWS_DEFAULT_REGION:-us-east-1}")"; then
        runtime_fail "resolve_deployed_sha" "Failed to resolve deployed SHA from /fjcloud/staging/last_deploy_sha."
    fi
    if [ -z "$PROBE_DEPLOYED_SHA" ] || [ "$PROBE_DEPLOYED_SHA" = "None" ]; then
        runtime_fail "resolve_deployed_sha" "SSM /fjcloud/staging/last_deploy_sha returned an empty value."
    fi
    append_step "resolve_deployed_sha" true "Resolved deployed SHA from SSM."

    if ! DISCORD_WEBHOOK_URL="$(aws ssm get-parameter --name "$DISCORD_WEBHOOK_URL_SSM_PARAM" --with-decryption --query 'Parameter.Value' --output text --region "${AWS_DEFAULT_REGION:-us-east-1}")"; then
        runtime_fail "resolve_discord_webhook_url" "Failed to resolve Discord webhook URL from SSM parameter '$DISCORD_WEBHOOK_URL_SSM_PARAM'."
    fi
    if [ -z "$DISCORD_WEBHOOK_URL" ] || [ "$DISCORD_WEBHOOK_URL" = "None" ]; then
        runtime_fail "resolve_discord_webhook_url" "SSM '$DISCORD_WEBHOOK_URL_SSM_PARAM' returned an empty Discord webhook URL."
    fi
    append_step "resolve_discord_webhook_url" true "Hydrated Discord webhook URL from staging SSM."

    if ! STRIPE_WEBHOOK_SECRET="$(aws ssm get-parameter --name "$STRIPE_WEBHOOK_SECRET_SSM_PARAM" --with-decryption --query 'Parameter.Value' --output text --region "${AWS_DEFAULT_REGION:-us-east-1}")"; then
        runtime_fail "resolve_stripe_webhook_secret" "Failed to resolve STRIPE_WEBHOOK_SECRET from SSM parameter '$STRIPE_WEBHOOK_SECRET_SSM_PARAM'."
    fi
    if [ -z "$STRIPE_WEBHOOK_SECRET" ] || [ "$STRIPE_WEBHOOK_SECRET" = "None" ]; then
        runtime_fail "resolve_stripe_webhook_secret" "SSM '$STRIPE_WEBHOOK_SECRET_SSM_PARAM' returned an empty webhook secret."
    fi
    export STRIPE_WEBHOOK_SECRET
    append_step "resolve_stripe_webhook_secret" true "Hydrated STRIPE_WEBHOOK_SECRET from staging SSM for replay-fixture validation/signing."

    PROBE_EMAIL="organic-alert-probe-${PROBE_BUNDLE_TS}-$$@example.invalid"
    PROBE_CUSTOMER_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
    PROBE_INVOICE_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
    PROBE_STRIPE_INVOICE_ID="in_organic_probe_${PROBE_BUNDLE_TS}_$$"

    local escaped_customer_id escaped_invoice_id escaped_email escaped_stripe_invoice_id
    escaped_customer_id="$(sql_escape_literal "$PROBE_CUSTOMER_ID")"
    escaped_invoice_id="$(sql_escape_literal "$PROBE_INVOICE_ID")"
    escaped_email="$(sql_escape_literal "$PROBE_EMAIL")"
    escaped_stripe_invoice_id="$(sql_escape_literal "$PROBE_STRIPE_INVOICE_ID")"

    local customer_insert_output
    if ! customer_insert_output="$(run_sql "
INSERT INTO customers (id, name, email, status, created_at, updated_at)
VALUES ('$escaped_customer_id'::uuid, 'Organic alert dispatch probe customer', '$escaped_email', 'active', NOW(), NOW())
RETURNING id::text;")"; then
        runtime_fail "seed_customer" "Failed inserting probe customer row."
    fi
    if [[ "$customer_insert_output" != *"$PROBE_CUSTOMER_ID"* ]]; then
        runtime_fail "seed_customer" "Customer INSERT ... RETURNING id did not include expected UUID '$PROBE_CUSTOMER_ID'."
    fi
    append_step "seed_customer" true "Seeded probe customer UUID '$PROBE_CUSTOMER_ID'."

    local invoice_insert_output
    if ! invoice_insert_output="$(run_sql "
INSERT INTO invoices (
    id, customer_id, period_start, period_end, subtotal_cents, tax_cents, total_cents,
    currency, status, minimum_applied, stripe_invoice_id, created_at, finalized_at
)
VALUES (
    '$escaped_invoice_id'::uuid, '$escaped_customer_id'::uuid, CURRENT_DATE - INTERVAL '1 day', CURRENT_DATE,
    1000, 0, 1000, 'usd', 'finalized', false, '$escaped_stripe_invoice_id', NOW(), NOW()
)
RETURNING id::text;")"; then
        runtime_fail "seed_invoice" "Failed inserting probe invoice row."
    fi
    if [[ "$invoice_insert_output" != *"$PROBE_INVOICE_ID"* ]]; then
        runtime_fail "seed_invoice" "Invoice INSERT ... RETURNING id did not include expected UUID '$PROBE_INVOICE_ID'."
    fi
    append_step "seed_invoice" true "Seeded finalized probe invoice UUID '$PROBE_INVOICE_ID' with stripe_invoice_id '$PROBE_STRIPE_INVOICE_ID'."

    local next_payment_attempt
    next_payment_attempt=$(( $(date +%s) + 3600 ))
    local replay_target_url="${API_URL_NORMALIZED}/webhooks/stripe"
    PROBE_REPLAY_COMMAND="$(printf '%q ' bash "$REPLAY_FIXTURE_BIN" --run --allow-staging-target --target-url "$replay_target_url" --event-type invoice.payment_failed --invoice-id "$PROBE_STRIPE_INVOICE_ID" --next-payment-attempt "$next_payment_attempt" --attempt-count 1)"
    PROBE_REPLAY_COMMAND="${PROBE_REPLAY_COMMAND% }"

    if ! bash "$REPLAY_FIXTURE_BIN" \
        --run \
        --allow-staging-target \
        --target-url "$replay_target_url" \
        --event-type invoice.payment_failed \
        --invoice-id "$PROBE_STRIPE_INVOICE_ID" \
        --next-payment-attempt "$next_payment_attempt" \
        --attempt-count 1; then
        runtime_fail "replay_webhook" "Webhook replay fixture exited non-zero."
    fi
    append_step "replay_webhook" true "Replayed signed invoice.payment_failed webhook for synthetic stripe invoice id '$PROBE_STRIPE_INVOICE_ID'."

    local escaped_probe_invoice_id poll_attempt poll_output poll_row poll_status
    escaped_probe_invoice_id="$(sql_escape_literal "$PROBE_INVOICE_ID")"
    for poll_attempt in $(seq 1 "$POLL_MAX_ATTEMPTS"); do
        poll_output="$(run_sql "SELECT id::text || '|' || delivery_status FROM alerts WHERE metadata->>'invoice_id' = '$escaped_probe_invoice_id' ORDER BY created_at DESC LIMIT 1;" || true)"
        poll_row="$(first_data_row "$poll_output" || true)"
        PROBE_ALERT_QUERY_RESULT="${poll_row:-<empty>}"

        if [ -n "$poll_row" ]; then
            PROBE_ALERT_ID="${poll_row%%|*}"
            poll_status="${poll_row#*|}"
            if [ "$poll_status" = "sent" ]; then
                append_step "poll_alert_sent" true "Observed alert delivery_status='sent' for invoice '$PROBE_INVOICE_ID' on attempt ${poll_attempt}/${POLL_MAX_ATTEMPTS}."
                PROBE_RESULT_DETAIL="Alert persisted with delivery_status='sent'."
                return 0
            fi

            runtime_fail "poll_alert_sent" "Alert row found for invoice '$PROBE_INVOICE_ID' but delivery_status='$poll_status' (expected 'sent')." true
        fi

        if [ "$poll_attempt" -lt "$POLL_MAX_ATTEMPTS" ]; then
            sleep "$POLL_SLEEP_SECONDS"
        fi
    done

    runtime_fail "poll_alert_sent" "Timed out after ${POLL_MAX_ATTEMPTS} attempts waiting for alert row with delivery_status='sent' for invoice '$PROBE_INVOICE_ID'." true
}

main "$@"
