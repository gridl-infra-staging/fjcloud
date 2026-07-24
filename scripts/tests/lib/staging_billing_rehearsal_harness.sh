#!/usr/bin/env bash
# Shared harness helpers for staging_billing_rehearsal shell tests.

# shellcheck source=staging_billing_rehearsal_reset_harness_blocks.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/staging_billing_rehearsal_reset_harness_blocks.sh"
RUN_STDOUT=""
RUN_EXIT_CODE=0
TEST_WORKSPACE=""
TEST_CALL_LOG=""
CLEANUP_DIRS=()
PARSED_CLI_ARGS=()

cleanup_test_workspaces() {
    local d
    for d in "${CLEANUP_DIRS[@]}"; do
        rm -rf "$d"
    done
}
trap cleanup_test_workspaces EXIT

baseline_rehearsal_env() {
    cat <<'EOV'
STAGING_API_URL=https://staging-api.example.test
STAGING_STRIPE_WEBHOOK_URL=https://staging-api.example.test/webhooks/stripe
STRIPE_SECRET_KEY=sk_test_rehearsal_contract
STRIPE_WEBHOOK_SECRET=whsec_rehearsal_contract
ADMIN_KEY=staging-admin-contract
DATABASE_URL=postgres://griddle:griddle_local@127.0.0.1:15432/fjcloud_dev
INTEGRATION_DB_URL=postgres://griddle:griddle_local@127.0.0.1:15432/fjcloud_dev
MAILPIT_API_URL=https://mailpit.example.test
AWS_ACCESS_KEY_ID=file-contract-test-key
AWS_SECRET_ACCESS_KEY=file-contract-test-secret
AWS_DEFAULT_REGION=us-east-1
EOV
}

shell_quote_for_script() {
    local quoted
    printf -v quoted '%q' "$1"
    printf '%s\n' "$quoted"
}

parse_cli_args_string() {
    local cli_args_string="$1"
    local arg

    PARSED_CLI_ARGS=()
    [ -n "$cli_args_string" ] || return 0

    while IFS= read -r -d '' arg; do
        PARSED_CLI_ARGS+=("$arg")
    done < <(python3 - "$cli_args_string" <<'PY'
import shlex
import sys

try:
    parsed = shlex.split(sys.argv[1])
except ValueError as exc:
    print(f"invalid cli args: {exc}", file=sys.stderr)
    raise SystemExit(1)

for arg in parsed:
    sys.stdout.write(arg)
    sys.stdout.write("\0")
PY
)
}

setup_workspace() {
    local test_tenant_allowlist="${1:-}"
    TEST_WORKSPACE="$(mktemp -d)"
    CLEANUP_DIRS+=("$TEST_WORKSPACE")
    TEST_CALL_LOG="$TEST_WORKSPACE/calls.log"

    mkdir -p "$TEST_WORKSPACE/scripts/lib" \
             "$TEST_WORKSPACE/scripts/launch" \
             "$TEST_WORKSPACE/bin" \
             "$TEST_WORKSPACE/tmp" \
             "$TEST_WORKSPACE/inputs"
    : > "$TEST_CALL_LOG"

    # Copy only the current shell owners + direct source dependencies used by
    # those owners. This keeps the harness orchestration-focused.
    cp "$REPO_ROOT/scripts/staging_billing_dry_run.sh" "$TEST_WORKSPACE/scripts/"
    cp "$REPO_ROOT/scripts/lib/env.sh" "$TEST_WORKSPACE/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/metering_checks.sh" "$TEST_WORKSPACE/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/psql_path.sh" "$TEST_WORKSPACE/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/stripe_request.sh" "$TEST_WORKSPACE/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/validation_json.sh" "$TEST_WORKSPACE/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/live_gate.sh" "$TEST_WORKSPACE/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/billing_rehearsal_steps.sh" "$TEST_WORKSPACE/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/staging_billing_input_env.sh" "$TEST_WORKSPACE/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/deployable_currency.sh" "$TEST_WORKSPACE/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/rc_invocation.sh" "$TEST_WORKSPACE/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/deployable_currency.sh" "$TEST_WORKSPACE/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/staging_billing_rehearsal"*.sh "$TEST_WORKSPACE/scripts/lib/"
    cp "$REPO_ROOT/scripts/launch/hydrate_seeder_env_from_ssm.sh" "$TEST_WORKSPACE/scripts/launch/"
    [ -f "$REPO_ROOT/scripts/launch/capture_billing_cross_check_inputs.sh" ] && \
        cp "$REPO_ROOT/scripts/launch/capture_billing_cross_check_inputs.sh" "$TEST_WORKSPACE/scripts/launch/" || true

    # Copy rehearsal runner only if it exists; Stage 1 is expected to be red
    # while this file is missing.
    [ -f "$REPO_ROOT/scripts/staging_billing_rehearsal.sh" ] && \
        cp "$REPO_ROOT/scripts/staging_billing_rehearsal.sh" "$TEST_WORKSPACE/scripts/" || true

    write_mock_deploy_status
    write_mock_psql
    write_mock_curl
    write_mock_stripe
    write_mock_aws
    write_explicit_env_file "$TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env" "$test_tenant_allowlist"
    write_malformed_env_file "$TEST_WORKSPACE/inputs/staging_rehearsal.malformed.env"
}

write_mock_psql() {
    local quoted_log
    quoted_log="$(shell_quote_for_script "$TEST_CALL_LOG")"
    local invoice_attempt_file webhook_attempt_file reset_deleted_file billing_run_call_file
    invoice_attempt_file="$(shell_quote_for_script "$TEST_WORKSPACE/tmp/mock_psql_invoice_attempt.txt")"
    webhook_attempt_file="$(shell_quote_for_script "$TEST_WORKSPACE/tmp/mock_psql_webhook_attempt.txt")"
    reset_deleted_file="$(shell_quote_for_script "$TEST_WORKSPACE/tmp/mock_psql_reset_deleted_ids.txt")"
    billing_run_call_file="$(shell_quote_for_script "$TEST_WORKSPACE/tmp/mock_curl_billing_run_count.txt")"

    cat > "$TEST_WORKSPACE/bin/psql" <<MOCK
#!/usr/bin/env bash
echo "psql|\$*" >> $quoted_log
RESET_DELETED_FILE=$reset_deleted_file
BILLING_RUN_CALL_FILE=$billing_run_call_file
sql=""
while [ "\$#" -gt 0 ]; do
    if [ "\$1" = "-c" ] && [ "\$#" -ge 2 ]; then
        sql="\$2"
        shift 2
        continue
    fi
    shift
done

if [[ "\$sql" == *"SELECT COUNT(*) FROM usage_records"* ]]; then
    echo "9"
    exit 0
fi
if [[ "\$sql" == *"SELECT COUNT(*) FROM usage_daily"* ]]; then
    echo "3"
    exit 0
fi

if [[ "\$sql" == *"stage3_invoice_rows"* ]]; then
    forced_exit="\${REHEARSAL_MOCK_INVOICE_QUERY_EXIT:-0}"
    if [ "\$forced_exit" -ne 0 ]; then
        stderr_line="\${REHEARSAL_MOCK_INVOICE_QUERY_STDERR:-}"
        [ -n "\$stderr_line" ] && printf '%s\n' "\$stderr_line" >&2
        exit "\$forced_exit"
    fi
    ready_after="\${REHEARSAL_MOCK_INVOICE_READY_AFTER:-1}"
    mode="\${REHEARSAL_MOCK_INVOICE_MODE:-complete}"
    attempt=\$((\$(cat $invoice_attempt_file 2>/dev/null || echo 0) + 1))
    printf '%s\n' "\$attempt" > $invoice_attempt_file

    if [ "\$attempt" -lt "\$ready_after" ]; then
        exit 0
    fi

    case "\$mode" in
        complete)
            printf '11111111-1111-4111-8111-111111111111|si_stage3_a|https://invoice.stripe.com/i/acct_test/stage3_a|2026-03-30T12:00:00Z|alpha@example.test\n'
            printf '22222222-2222-4222-8222-222222222222|si_stage3_b|https://invoice.stripe.com/i/acct_test/stage3_b|2026-03-30T12:00:05Z|beta@example.test\n'
            ;;
        plus_alias_email)
            printf '11111111-1111-4111-8111-111111111111|si_stage3_a|https://invoice.stripe.com/i/acct_test/stage3_a|2026-03-30T12:00:00Z|alpha+alerts@example.test\n'
            printf '22222222-2222-4222-8222-222222222222|si_stage3_b|https://invoice.stripe.com/i/acct_test/stage3_b|2026-03-30T12:00:05Z|beta@example.test\n'
            ;;
        missing_stripe)
            printf '11111111-1111-4111-8111-111111111111||https://invoice.stripe.com/i/acct_test/stage3_a|2026-03-30T12:00:00Z|alpha@example.test\n'
            printf '22222222-2222-4222-8222-222222222222|si_stage3_b|https://invoice.stripe.com/i/acct_test/stage3_b|2026-03-30T12:00:05Z|beta@example.test\n'
            ;;
        missing_paid_at)
            printf '11111111-1111-4111-8111-111111111111|si_stage3_a|https://invoice.stripe.com/i/acct_test/stage3_a||alpha@example.test\n'
            printf '22222222-2222-4222-8222-222222222222|si_stage3_b|https://invoice.stripe.com/i/acct_test/stage3_b||beta@example.test\n'
            ;;
        missing_email)
            printf '11111111-1111-4111-8111-111111111111|si_stage3_a|https://invoice.stripe.com/i/acct_test/stage3_a|2026-03-30T12:00:00Z|\n'
            printf '22222222-2222-4222-8222-222222222222|si_stage3_b|https://invoice.stripe.com/i/acct_test/stage3_b|2026-03-30T12:00:05Z|\n'
            ;;
        none)
            ;;
    esac
    exit 0
fi

if [[ "\$sql" == *"stage3_webhook_rows"* ]]; then
    forced_exit="\${REHEARSAL_MOCK_WEBHOOK_QUERY_EXIT:-0}"
    if [ "\$forced_exit" -ne 0 ]; then
        stderr_line="\${REHEARSAL_MOCK_WEBHOOK_QUERY_STDERR:-}"
        [ -n "\$stderr_line" ] && printf '%s\n' "\$stderr_line" >&2
        exit "\$forced_exit"
    fi
    ready_after="\${REHEARSAL_MOCK_WEBHOOK_READY_AFTER:-1}"
    mode="\${REHEARSAL_MOCK_WEBHOOK_MODE:-processed}"
    attempt=\$((\$(cat $webhook_attempt_file 2>/dev/null || echo 0) + 1))
    printf '%s\n' "\$attempt" > $webhook_attempt_file

    if [ "\$attempt" -lt "\$ready_after" ]; then
        exit 0
    fi

    case "\$mode" in
        processed)
            printf '11111111-1111-4111-8111-111111111111|si_stage3_a|2026-03-30T12:02:00Z\n'
            printf '22222222-2222-4222-8222-222222222222|si_stage3_b|2026-03-30T12:02:05Z\n'
            ;;
        unprocessed|missing)
            printf '11111111-1111-4111-8111-111111111111|si_stage3_a|\n22222222-2222-4222-8222-222222222222|si_stage3_b|\n'
            ;;
    esac
    exit 0
fi

if [[ "\$sql" == *"stage3_same_month_rehearsal_invoice_rows"* ]] || [[ "\$sql" == *"stage3_existing_same_month_invoice_rows"* ]]; then
    forced_exit="\${REHEARSAL_MOCK_SAME_MONTH_LOOKUP_EXIT:-0}"
    if [ "\$forced_exit" -ne 0 ]; then
        stderr_line="\${REHEARSAL_MOCK_SAME_MONTH_LOOKUP_STDERR:-}"
        [ -n "\$stderr_line" ] && printf '%s\n' "\$stderr_line" >&2
        exit "\$forced_exit"
    fi
    mode="\${REHEARSAL_MOCK_SAME_MONTH_LOOKUP_MODE:-after_billing_run}"
    case "\$mode" in
        unrelated_non_synthetic)
            printf 'inv_unrelated_same_month|33333333-3333-3333-3333-333333333333|si_unrelated|https://invoice.stripe.com/i/acct_test/unrelated|2026-03-02T12:00:00Z|customer@example.test\n'
            ;;
        other_allowlisted_tenant)
            if [[ "\$sql" == *"22222222-2222-2222-2222-222222222222"* ]]; then
                printf 'inv_other_allowlisted_same_month|22222222-2222-2222-2222-222222222222|si_other_allowlisted|https://invoice.stripe.com/i/acct_test/other-allowlisted|2026-03-02T12:00:00Z|other@example.test\n'
            fi
            ;;
        notice_only)
            printf 'NOTICE: no reusable same-month invoice rows found\n' >&2
            ;;
        after_billing_run)
            if [ "\$(cat $billing_run_call_file 2>/dev/null || echo 0)" -ge 1 ]; then
                printf '11111111-1111-4111-8111-111111111111|11111111-1111-1111-1111-111111111111|si_stage3_a|https://invoice.stripe.com/i/acct_test/stage3_a|2026-03-30T12:00:00Z|alpha@example.test\n'
                printf '22222222-2222-4222-8222-222222222222|11111111-1111-1111-1111-111111111111|si_stage3_b|https://invoice.stripe.com/i/acct_test/stage3_b|2026-03-30T12:00:05Z|beta@example.test\n'
            fi
            ;;
        none)
            ;;
    esac
    exit 0
fi

if [[ "\$sql" == *"stage1_invoice_db_row"* ]]; then
    printf '{"id":"e7806ad2-977d-4f4b-9ff9-95c7ddab49e3","customer_id":"11111111-1111-1111-1111-111111111111","period_start":"2026-04-01","period_end":"2026-05-01","subtotal_cents":250,"total_cents":500,"minimum_applied":true,"stripe_invoice_id":"in_stage1","created_at":"2026-04-28T05:51:06.401081+00:00","paid_at":"2026-04-28T05:51:09.78566+00:00"}\n'
    exit 0
fi

if [[ "\$sql" == *"stage1_invoice_line_items"* ]]; then
    printf '[{"id":"line_1","invoice_id":"e7806ad2-977d-4f4b-9ff9-95c7ddab49e3","description":"Storage usage","quantity":"50.000000","unit":"mb_months","unit_price_cents":"5.0000","amount_cents":250,"region":"us-east-1","metadata":{}}]\n'
    exit 0
fi

if [[ "\$sql" == *"stage1_customer_billing_context"* ]]; then
    printf '{"id":"11111111-1111-1111-1111-111111111111","email":"alpha@example.test","billing_plan":"shared","object_storage_egress_carryforward_cents":"0.0000"}\n'
    exit 0
fi

if [[ "\$sql" == *"stage1_rate_card_selection"* ]]; then
    if [ "\${REHEARSAL_MOCK_STAGE1_RATE_CARD_SELECTION_MODE:-normal}" = "missing_effective" ]; then
        printf '{"selection_basis":"invoice_created_at","captured_at":"2026-04-29T00:00:00Z","invoice_created_at":"2026-04-28T05:51:06.401081+00:00","invoice_paid_at":"2026-04-28T05:51:09.78566+00:00","invoice_selection_timestamp":"2026-04-28T05:51:06.401081+00:00","effective_rate_card":null,"override_exists":false}\n'
        exit 0
    fi
    if [ "\${REHEARSAL_MOCK_STAGE1_RATE_CARD_SELECTION_MODE:-normal}" = "override_exists_spaced" ]; then
        printf '{"selection_basis" : "invoice_created_at", "captured_at" : "2026-04-29T00:00:00Z", "invoice_created_at" : "2026-04-28T05:51:06.401081+00:00", "invoice_paid_at" : "2026-04-28T05:51:09.78566+00:00", "invoice_selection_timestamp" : "2026-04-28T05:51:06.401081+00:00", "invoice_window" : {"period_start":"2026-04-01","period_end":"2026-05-01"}, "effective_rate_card" : {"id":"ratecard_hist_1","name":"launch-2026","effective_from":"2026-01-01T00:00:00Z","effective_until":"2026-05-01T00:00:00Z","storage_rate_per_mb_month":"0.050000","minimum_spend_cents":1000,"shared_minimum_spend_cents":500}, "override_exists" : true}\n'
        exit 0
    fi
    if [ "\${REHEARSAL_MOCK_STAGE1_RATE_CARD_SELECTION_MODE:-normal}" = "override_exists" ]; then
        printf '{"selection_basis":"invoice_created_at","captured_at":"2026-04-29T00:00:00Z","invoice_created_at":"2026-04-28T05:51:06.401081+00:00","invoice_paid_at":"2026-04-28T05:51:09.78566+00:00","invoice_selection_timestamp":"2026-04-28T05:51:06.401081+00:00","invoice_window":{"period_start":"2026-04-01","period_end":"2026-05-01"},"effective_rate_card":{"id":"ratecard_hist_1","name":"launch-2026","effective_from":"2026-01-01T00:00:00Z","effective_until":"2026-05-01T00:00:00Z","storage_rate_per_mb_month":"0.050000","minimum_spend_cents":1000,"shared_minimum_spend_cents":500},"override_exists":true}\n'
        exit 0
    fi
    printf '{"selection_basis":"invoice_created_at","captured_at":"2026-04-29T00:00:00Z","invoice_created_at":"2026-04-28T05:51:06.401081+00:00","invoice_paid_at":"2026-04-28T05:51:09.78566+00:00","invoice_selection_timestamp":"2026-04-28T05:51:06.401081+00:00","invoice_window":{"period_start":"2026-04-01","period_end":"2026-05-01"},"effective_rate_card":{"id":"ratecard_hist_1","name":"launch-2026","effective_from":"2026-01-01T00:00:00Z","effective_until":"2026-05-01T00:00:00Z","storage_rate_per_mb_month":"0.050000","minimum_spend_cents":1000,"shared_minimum_spend_cents":500},"override_exists":false}\n'
    exit 0
fi

if [[ "\$sql" == *"stage1_rate_card_active_candidate"* ]]; then
    printf '{"id":"ratecard_hist_1","name":"launch-2026","effective_from":"2026-01-01T00:00:00Z","effective_until":"2026-05-01T00:00:00Z","storage_rate_per_mb_month":"0.050000","minimum_spend_cents":1000,"shared_minimum_spend_cents":500}\n'
    exit 0
fi

if [[ "\$sql" == *"stage1_customer_rate_override"* ]]; then
    if [ "\${REHEARSAL_MOCK_STAGE1_OVERRIDE_MODE:-none}" = "present" ]; then
        printf '{"customer_id":"11111111-1111-1111-1111-111111111111","rate_card_id":"ratecard_hist_1","overrides":{"minimum_spend_cents":400},"created_at":"2026-04-01T00:00:00Z"}\n'
    else
        printf 'null\n'
    fi
    exit 0
fi

if [[ "\$sql" == *"stage1_usage_daily_replay_rows"* ]]; then
    printf '[{"customer_id":"11111111-1111-1111-1111-111111111111","date":"2026-04-28","region":"us-east-1","search_requests":0,"write_operations":0,"storage_bytes_avg":52428800,"documents_count_avg":0,"aggregated_at":"2026-04-28T05:45:00Z"}]\n'
    exit 0
fi

if [[ "\$sql" == *"stage1_usage_records_provenance"* ]]; then
    printf '[{"id":1,"customer_id":"11111111-1111-1111-1111-111111111111","tenant_id":"tenant_a","region":"us-east-1","node_id":"node-a","event_type":"storage_bytes","value":52428800,"recorded_at":"2026-04-28T05:44:00Z","flapjack_ts":"2026-04-28T05:44:00Z"}]\n'
    exit 0
fi

MOCK
    mock_psql_reset_script_block >> "$TEST_WORKSPACE/bin/psql"
    cat >> "$TEST_WORKSPACE/bin/psql" <<'MOCK'

echo "1"
exit 0
MOCK
    chmod +x "$TEST_WORKSPACE/bin/psql"
}

mock_curl_parser_script_block() {
    cat <<'MOCK'
method="GET"
url=""
request_body=""
admin_key=""
write_out=""
body_output=""
header_output=""
fail_on_http=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        -K)
            shift 2
            ;;
        -D)
            header_output="$2"
            shift 2
            ;;
        -o)
            body_output="$2"
            shift 2
            ;;
        -X)
            method="$2"
            shift 2
            ;;
        -H)
            header="$2"
            if [[ "$header" == x-admin-key:* ]]; then
                admin_key="${header#x-admin-key: }"
            fi
            shift 2
            ;;
        -d|--data|--data-raw)
            request_body="$2"
            shift 2
            ;;
        -w|--write-out)
            write_out="$2"
            shift 2
            ;;
        http://*|https://*)
            url="$1"
            shift
            ;;
        -*f*)
            fail_on_http=1
            shift
            ;;
        *)
            shift
            ;;
    esac
done

response_code="200"
response_body='{}'
MOCK
}

mock_curl_route_script_block() {
    cat <<'MOCK'
case "$url" in
    https://api.stripe.com/v1/invoices\?*)
        forced_exit="${REHEARSAL_MOCK_STRIPE_LIST_EXIT:-0}"
        if [ "$forced_exit" -ne 0 ]; then
            exit "$forced_exit"
        fi
        if [ -n "${REHEARSAL_MOCK_STRIPE_LIST_JSON_FILE:-}" ]; then
            response_body="$(cat "$REHEARSAL_MOCK_STRIPE_LIST_JSON_FILE")"
        elif [ -n "${REHEARSAL_MOCK_STRIPE_LIST_JSON:-}" ]; then
            response_body="$REHEARSAL_MOCK_STRIPE_LIST_JSON"
        else
            response_body='{"data":[]}'
        fi
        ;;
    https://api.stripe.com/v1/invoices/*/void)
        invoice_id="${url%/void}"
        invoice_id="${invoice_id##*/}"
        case ",${REHEARSAL_MOCK_STRIPE_VOID_FAIL_IDS:-}," in
            *,"${invoice_id}",*)
                response_code="500"
                response_body='{"error":{"message":"mock void failure"}}'
                ;;
            *)
                response_body="{\"id\":\"${invoice_id}\",\"status\":\"void\"}"
                ;;
        esac
        ;;
    https://api.stripe.com/v1/invoices/*)
        invoice_id="${url##*/}"
        case ",${REHEARSAL_MOCK_STRIPE_DELETE_FAIL_IDS:-}," in
            *,"${invoice_id}",*)
                response_code="500"
                response_body='{"error":{"message":"mock delete failure"}}'
                ;;
            *)
                response_body="{\"id\":\"${invoice_id}\",\"deleted\":true}"
                ;;
        esac
        ;;
    */health)
        response_code="${REHEARSAL_MOCK_HEALTH_STATUS:-200}"
        response_body='{"status":"ok"}'
        ;;
    */admin/billing/run)
        billing_run_attempt=$(( $(cat "$BILLING_RUN_CALL_FILE" 2>/dev/null || echo 0) + 1 ))
        printf '%s\n' "$billing_run_attempt" > "$BILLING_RUN_CALL_FILE"
        forced_billing_exit="${REHEARSAL_MOCK_BILLING_CURL_EXIT:-0}"
        if [ "$forced_billing_exit" -ne 0 ]; then
            exit "$forced_billing_exit"
        fi
        if [ "$admin_key" != "staging-admin-contract" ]; then
            response_code="401"
            response_body='{"error":"invalid admin key"}'
        elif [[ "$request_body" != *'"month":"'* ]]; then
            response_code="400"
            response_body='{"error":"month is required"}'
        else
            case "${REHEARSAL_MOCK_BATCH_MODE:-created}" in
                no_created)
                    response_body='{"month":"2026-03","invoices_created":0,"invoices_skipped":2,"results":[{"customer_id":"cust_stage3_a","status":"skipped","invoice_id":null,"reason":"already_invoiced"},{"customer_id":"cust_stage3_b","status":"skipped","invoice_id":null,"reason":"already_invoiced"}]}'
                    ;;
                created_then_no_created)
                    if [ "$billing_run_attempt" -eq 1 ]; then
                        response_body='{"month":"2026-03","invoices_created":2,"invoices_skipped":0,"results":[{"customer_id":"cust_stage3_a","status":"created","invoice_id":"11111111-1111-4111-8111-111111111111","reason":null},{"customer_id":"cust_stage3_b","status":"created","invoice_id":"22222222-2222-4222-8222-222222222222","reason":null}]}'
                    else
                        response_body='{"month":"2026-03","invoices_created":0,"invoices_skipped":2,"results":[{"customer_id":"cust_stage3_a","status":"skipped","invoice_id":null,"reason":"already_invoiced"},{"customer_id":"cust_stage3_b","status":"skipped","invoice_id":null,"reason":"already_invoiced"}]}'
                    fi
                    ;;
                malformed)
                    response_body='{"not":"valid"'
                    ;;
                created)
                    response_body='{"month":"2026-03","invoices_created":2,"invoices_skipped":0,"results":[{"customer_id":"cust_stage3_a","status":"created","invoice_id":"11111111-1111-4111-8111-111111111111","reason":null},{"customer_id":"cust_stage3_b","status":"created","invoice_id":"22222222-2222-4222-8222-222222222222","reason":null}]}'
                    ;;
            esac
        fi
        ;;
    */api/v1/search*)
        forced_mailpit_exit="${REHEARSAL_MOCK_MAILPIT_CURL_EXIT:-0}"
        if [ "$forced_mailpit_exit" -ne 0 ]; then
            exit "$forced_mailpit_exit"
        fi
        attempt=$(( $(cat "$MAILPIT_ATTEMPT_FILE" 2>/dev/null || echo 0) + 1 ))
        printf '%s\n' "$attempt" > "$MAILPIT_ATTEMPT_FILE"
        ready_after="${REHEARSAL_MOCK_MAILPIT_READY_AFTER:-1}"
        mode="${REHEARSAL_MOCK_MAILPIT_MODE:-emails_found}"
        invoice_id="11111111-1111-4111-8111-111111111111"
        if [[ "$url" == *"beta@example.test"* ]] || [[ "$url" == *"beta%40example.test"* ]]; then
            invoice_id="22222222-2222-4222-8222-222222222222"
        fi
        if [ "$attempt" -lt "$ready_after" ] || [ "$mode" = "none" ]; then
            response_body='{"messages_count":0,"total":0,"messages":[]}'
        elif [ "$mode" = "invalid_search_json" ]; then
            response_body='{"messages":[}'
        elif [ "$mode" = "invalid_message_json" ]; then
            response_body="{\"messages_count\":1,\"total\":1,\"messages\":[{\"ID\":\"msg-${invoice_id}\",\"Subject\":\"Invoice ready\",\"Snippet\":\"message body lookup required\"}]}"
        elif [ "$mode" = "generic_without_invoice_ids" ]; then
            response_body='{"messages_count":1,"total":1,"messages":[{"ID":"msg-stale-generic","Subject":"Your invoice is ready","Text":"Your monthly invoice is ready to view."}]}'
        elif [ "$mode" = "summary_without_invoice_ids_body_has_invoice_id" ]; then
            response_body="{\"messages_count\":1,\"total\":1,\"messages\":[{\"ID\":\"msg-${invoice_id}\",\"Subject\":\"Invoice ready\",\"Snippet\":\"Your monthly invoice is available.\"}]}"
        else
            response_body="{\"messages_count\":1,\"total\":1,\"messages\":[{\"ID\":\"msg-${invoice_id}\",\"Subject\":\"Invoice ready\",\"Text\":\"invoice_id=${invoice_id}\"}]}"
        fi
        ;;
    */api/v1/message/*)
        forced_mailpit_exit="${REHEARSAL_MOCK_MAILPIT_CURL_EXIT:-0}"
        if [ "$forced_mailpit_exit" -ne 0 ]; then
            exit "$forced_mailpit_exit"
        fi
        mode="${REHEARSAL_MOCK_MAILPIT_MODE:-emails_found}"
        msg_id="${url##*/api/v1/message/}"
        invoice_id="${msg_id#msg-}"
        if [ "$mode" = "invalid_message_json" ]; then
            response_body='{"ID":"broken-message","Text":'
        else
            response_body="{\"ID\":\"${msg_id}\",\"Text\":\"invoice_id=${invoice_id}\",\"HTML\":\"<p>invoice_id=${invoice_id}</p>\"}"
        fi
        ;;
esac
MOCK
}

mock_curl_finalize_script_block() {
    cat <<'MOCK'
if [ -n "$header_output" ]; then
    printf 'Request-Id: req_rehearsal_mock\n' > "$header_output"
fi

if [ -n "$body_output" ]; then
    printf '%s' "$response_body" > "$body_output"
    if [ -n "$write_out" ] && [[ "$write_out" == *'%{http_code}'* ]]; then
        printf '%s' "$response_code"
    fi
    exit 0
fi

if [ -n "$write_out" ] && [[ "$write_out" == *'%{http_code}'* ]]; then
    printf '%s\n%s' "$response_body" "$response_code"
    exit 0
fi

if [ "$fail_on_http" -eq 1 ] && [ "$response_code" -ge 400 ]; then
    exit 22
fi
printf '%s' "$response_body"
exit 0
MOCK
}

mock_curl_log_script_block() {
    cat <<'MOCK'
sanitize_curl_args_for_log() {
    local arg redact_header=0
    while [ "$#" -gt 0 ]; do
        arg="$1"
        shift
        if [ "$redact_header" -eq 1 ]; then
            case "$arg" in
                x-admin-key:*|[Aa]uthorization:*)
                    printf ' %s' "${arg%%:*}: REDACTED"
                    ;;
                *)
                    printf ' %s' "$arg"
                    ;;
            esac
            redact_header=0
            continue
        fi

        case "$arg" in
            -H|--header)
                printf ' %s' "$arg"
                redact_header=1
                ;;
            x-admin-key:*|[Aa]uthorization:*)
                printf ' %s' "${arg%%:*}: REDACTED"
                ;;
            *)
                printf ' %s' "$arg"
                ;;
        esac
    done
}

printf 'curl|' >> "$CALL_LOG"
sanitize_curl_args_for_log "$@" >> "$CALL_LOG"
printf '\n' >> "$CALL_LOG"
MOCK
}

write_mock_curl() {
    local quoted_log
    local mailpit_attempt_file billing_run_call_file
    quoted_log="$(shell_quote_for_script "$TEST_CALL_LOG")"
    mailpit_attempt_file="$(shell_quote_for_script "$TEST_WORKSPACE/tmp/mock_curl_mailpit_attempt.txt")"
    billing_run_call_file="$(shell_quote_for_script "$TEST_WORKSPACE/tmp/mock_curl_billing_run_count.txt")"

    {
        cat <<MOCK
#!/usr/bin/env bash
CALL_LOG=$quoted_log
MAILPIT_ATTEMPT_FILE=$mailpit_attempt_file
BILLING_RUN_CALL_FILE=$billing_run_call_file
MOCK
        mock_curl_log_script_block
        mock_curl_parser_script_block
        mock_curl_route_script_block
        mock_curl_finalize_script_block
    } > "$TEST_WORKSPACE/bin/curl"
    chmod +x "$TEST_WORKSPACE/bin/curl"
}

write_mock_stripe() {
    local quoted_log
    quoted_log="$(shell_quote_for_script "$TEST_CALL_LOG")"

    {
        cat <<MOCK
#!/usr/bin/env bash
echo "stripe|\$*" >> $quoted_log
MOCK
        mock_stripe_reset_script_block
    } > "$TEST_WORKSPACE/bin/stripe"
    chmod +x "$TEST_WORKSPACE/bin/stripe"
}

write_mock_aws() {
    local quoted_log
    quoted_log="$(shell_quote_for_script "$TEST_CALL_LOG")"

    cat > "$TEST_WORKSPACE/bin/aws" <<MOCK
#!/usr/bin/env bash
echo "aws|\$*" >> $quoted_log
if [ "\${AWS_ACCESS_KEY_ID:-}" = "stale-parent-key" ]; then
    echo "stale parent AWS credential reached mock AWS" >&2
    exit 97
fi
if [ "\$1" = "ssm" ] && [ "\$2" = "get-parameter" ]; then
    name=""
    while [ "\$#" -gt 0 ]; do
        case "\$1" in
            --name)
                name="\$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done
    missing_keys=",\${REHEARSAL_MOCK_SSM_MISSING_KEYS:-},"
    parameter_key="\${name##*/}"
    case "\$missing_keys" in
        *,"\$parameter_key",*)
            printf '%s\n' "None"
            exit 0
            ;;
    esac
    case "\$name" in
        */admin_key)
            printf '%s\n' "staging-admin-contract"
            ;;
        */database_url)
            printf '%s\n' "postgres://griddle:griddle_local@127.0.0.1:15432/fjcloud_dev"
            ;;
        */dns_domain)
            printf '%s\n' "staging.example.test"
            ;;
        */stripe_secret_key)
            printf '%s\n' "\${REHEARSAL_MOCK_SSM_STRIPE_SECRET_KEY:-sk_test_rehearsal_contract}"
            ;;
        */ses_from_address)
            printf '%s\n' "system@example.test"
            ;;
        */ses_region)
            printf '%s\n' "us-east-1"
            ;;
        */stripe_webhook_secret)
            printf '%s\n' "whsec_rehearsal_contract"
            ;;
        *)
            printf '%s\n' "None"
            ;;
    esac
    exit 0
fi
if [ "\$1" = "logs" ] && [ "\$2" = "filter-log-events" ]; then
    next_token=""
    while [ "\$#" -gt 0 ]; do
        case "\$1" in
            --next-token)
                next_token="\$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done
    case "\${REHEARSAL_MOCK_SES_CLOUDWATCH_MODE:-emails_found}" in
        emails_found)
            cat <<'JSON'
{"events":[{"logStreamName":"eventbridge-send/1","timestamp":1720000000000,"message":"{\"source\":\"aws.ses\",\"detail-type\":\"Email Sent\",\"detail\":{\"eventType\":\"Send\",\"mail\":{\"messageId\":\"ses-msg-ready-11111111-1111-4111-8111-111111111111\",\"tags\":{\"invoice_id\":[\"11111111-1111-4111-8111-111111111111\"],\"email_type\":[\"invoice_ready\"],\"dispatch_source\":[\"admin_billing_run\"]}},\"send\":{}}}"},{"logStreamName":"eventbridge-send/1","timestamp":1720000000001,"message":"{\"source\":\"aws.ses\",\"detail-type\":\"Email Sent\",\"detail\":{\"eventType\":\"Send\",\"mail\":{\"messageId\":\"ses-msg-11111111-1111-4111-8111-111111111111\",\"tags\":{\"ses:configuration-set\":[\"fjcloud-staging-staging-flapjack-foo-feedback\"],\"invoice_id\":[\"11111111-1111-4111-8111-111111111111\"],\"email_type\":[\"invoice_ready\"],\"dispatch_source\":[\"invoice_payment_succeeded\"]}},\"send\":{}}}"},{"logStreamName":"eventbridge-send/1","timestamp":1720000000002,"message":"{\"source\":\"aws.ses\",\"detail-type\":\"Email Sent\",\"detail\":{\"eventType\":\"Send\",\"mail\":{\"messageId\":\"ses-msg-ready-22222222-2222-4222-8222-222222222222\",\"tags\":{\"invoice_id\":[\"22222222-2222-4222-8222-222222222222\"],\"email_type\":[\"invoice_ready\"],\"dispatch_source\":[\"admin_billing_run\"]}},\"send\":{}}}"},{"logStreamName":"eventbridge-send/1","timestamp":1720000000003,"message":"{\"source\":\"aws.ses\",\"detail-type\":\"Email Sent\",\"detail\":{\"eventType\":\"Send\",\"mail\":{\"messageId\":\"ses-msg-22222222-2222-4222-8222-222222222222\",\"tags\":{\"invoice_id\":[\"22222222-2222-4222-8222-222222222222\"],\"email_type\":[\"invoice_ready\"],\"dispatch_source\":[\"invoice_payment_succeeded\"]}},\"send\":{}}}"}]}
JSON
            ;;
        paginated_emails_found)
            if [ "\$next_token" = "invoice-email-page-2" ]; then
                cat <<'JSON'
{"events":[{"logStreamName":"eventbridge-send/1","timestamp":1720000000010,"message":"{\"source\":\"aws.ses\",\"detail-type\":\"Email Sent\",\"detail\":{\"eventType\":\"Send\",\"mail\":{\"messageId\":\"ses-msg-11111111-1111-4111-8111-111111111111\",\"tags\":{\"invoice_id\":[\"11111111-1111-4111-8111-111111111111\"],\"email_type\":[\"invoice_ready\"],\"dispatch_source\":[\"invoice_payment_succeeded\"]}},\"send\":{}}}"},{"logStreamName":"eventbridge-send/1","timestamp":1720000000011,"message":"{\"source\":\"aws.ses\",\"detail-type\":\"Email Sent\",\"detail\":{\"eventType\":\"Send\",\"mail\":{\"messageId\":\"ses-msg-22222222-2222-4222-8222-222222222222\",\"tags\":{\"invoice_id\":[\"22222222-2222-4222-8222-222222222222\"],\"email_type\":[\"invoice_ready\"],\"dispatch_source\":[\"invoice_payment_succeeded\"]}},\"send\":{}}}"}]}
JSON
            else
                cat <<'JSON'
{"events":[{"logStreamName":"eventbridge-send/0","timestamp":1720000000000,"message":"{\"source\":\"aws.ses\",\"detail-type\":\"Email Sent\",\"detail\":{\"eventType\":\"Send\",\"mail\":{\"messageId\":\"ses-msg-unrelated\",\"tags\":{\"invoice_id\":[\"00000000-0000-4000-8000-000000000000\"]}},\"send\":{}}}"}],"nextToken":"invoice-email-page-2"}
JSON
            fi
            ;;
        none)
            cat <<'JSON'
{"events":[]}
JSON
            ;;
        invalid_json)
            printf '{"events":[}\n'
            ;;
        *)
            echo "unknown REHEARSAL_MOCK_SES_CLOUDWATCH_MODE" >&2
            exit 92
            ;;
    esac
    exit 0
fi
echo "unsupported aws invocation" >&2
exit 1
MOCK
    chmod +x "$TEST_WORKSPACE/bin/aws"
}

write_explicit_env_file() {
    local path="$1"
    local test_tenant_allowlist="${2:-}"
    cat > "$path" <<'ENVFILE'
STAGING_API_URL=https://staging-api.example.test
STAGING_STRIPE_WEBHOOK_URL=https://staging-api.example.test/webhooks/stripe
STRIPE_SECRET_KEY=sk_test_rehearsal_contract
STRIPE_WEBHOOK_SECRET=whsec_rehearsal_contract
ADMIN_KEY=staging-admin-contract
DATABASE_URL=postgres://griddle:griddle_local@127.0.0.1:15432/fjcloud_dev
INTEGRATION_DB_URL=postgres://griddle:griddle_local@127.0.0.1:15432/fjcloud_dev
MAILPIT_API_URL=https://mailpit.example.test
AWS_ACCESS_KEY_ID=file-contract-test-key
AWS_SECRET_ACCESS_KEY=file-contract-test-secret
AWS_DEFAULT_REGION=us-east-1
ENVFILE
    if [ -n "$test_tenant_allowlist" ]; then
        printf 'FJCLOUD_TEST_TENANT_IDS=%s\n' "$test_tenant_allowlist" >> "$path"
    fi
}

write_explicit_env_file_without_keys() {
    local path="$1"
    shift

    if [ "$#" -eq 0 ]; then
        write_explicit_env_file "$path"
        return 0
    fi

    local key_pattern
    key_pattern="$(printf '%s\n' "$@" | paste -sd'|' -)"
    baseline_rehearsal_env | grep -Ev "^(${key_pattern})=" > "$path"
}

write_malformed_env_file() {
    local path="$1"
    cat > "$path" <<'ENVFILE'
STAGING_API_URL=https://staging-api.example.test
THIS IS NOT AN ASSIGNMENT
ENVFILE
}

write_mock_deploy_status() {
    cat > "$TEST_WORKSPACE/scripts/deploy_status.sh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

json_mode=0
env_filter=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --json)
            json_mode=1
            shift
            ;;
        --env)
            env_filter="$2"
            shift 2
            ;;
        *)
            echo "unknown deploy_status arg: $1" >&2
            exit 2
            ;;
    esac
done

[ "$json_mode" -eq 1 ] && [ "$env_filter" = "staging" ] || exit 2
case "${REHEARSAL_MOCK_DEPLOYABLE_CURRENCY:-clean}" in
    clean)
        deployable_drift=false
        doc_only_ahead=false
        ;;
    deployable_drift)
        deployable_drift=true
        doc_only_ahead=false
        ;;
    doc_only)
        deployable_drift=false
        doc_only_ahead=true
        ;;
    unknown|probe_failed)
        deployable_drift=unknown
        doc_only_ahead=unknown
        ;;
    *)
        echo "unsupported REHEARSAL_MOCK_DEPLOYABLE_CURRENCY" >&2
        exit 2
        ;;
esac

dev_sha="${REHEARSAL_MOCK_DEPLOYED_DEV_SHA:-3333333333333333333333333333333333333333}"
target_sha="${REHEARSAL_MOCK_TARGET_DEV_SHA:-$dev_sha}"
printf '{"dev_main_sha":"%s","envs":{"staging":{"dev_sha":"%s","deployable_drift":"%s","doc_only_ahead":"%s"}}}\n' \
    "$target_sha" "$dev_sha" "$deployable_drift" "$doc_only_ahead"
MOCK
    chmod +x "$TEST_WORKSPACE/scripts/deploy_status.sh"
}

wrap_preflight_owner_with_call_log() {
    local quoted_log
    quoted_log="$(shell_quote_for_script "$TEST_CALL_LOG")"

    mv "$TEST_WORKSPACE/scripts/staging_billing_dry_run.sh" \
       "$TEST_WORKSPACE/scripts/staging_billing_dry_run.owner.sh"

    cat > "$TEST_WORKSPACE/scripts/staging_billing_dry_run.sh" <<MOCK
#!/usr/bin/env bash
echo "dry_run|\$*" >> $quoted_log
exec /bin/bash "\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)/staging_billing_dry_run.owner.sh" "\$@"
MOCK
    chmod +x "$TEST_WORKSPACE/scripts/staging_billing_dry_run.sh"
}

run_rehearsal() {
    local cli_args=""
    local env_args=()

    while IFS= read -r line; do
        [ -n "$line" ] && env_args+=("$line")
    done < <(baseline_rehearsal_env)

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --args)
                cli_args="$2"
                shift 2
                ;;
            *)
                env_args+=("$1")
                shift
                ;;
        esac
    done

    env_args+=("PATH=$TEST_WORKSPACE/bin:/usr/bin:/bin:/usr/local/bin")
    env_args+=("HOME=$TEST_WORKSPACE")
    env_args+=("TMPDIR=$TEST_WORKSPACE/tmp")

    local rehearsal_script="$TEST_WORKSPACE/scripts/staging_billing_rehearsal.sh"
    RUN_EXIT_CODE=0
    if ! parse_cli_args_string "$cli_args"; then
        RUN_STDOUT="ERROR: invalid rehearsal CLI args"
        RUN_EXIT_CODE=1
        return
    fi
    if [ "${#PARSED_CLI_ARGS[@]}" -gt 0 ]; then
        RUN_STDOUT="$(env -i "${env_args[@]}" /bin/bash "$rehearsal_script" "${PARSED_CLI_ARGS[@]}" 2>&1)" || RUN_EXIT_CODE=$?
    else
        RUN_STDOUT="$(env -i "${env_args[@]}" /bin/bash "$rehearsal_script" 2>&1)" || RUN_EXIT_CODE=$?
    fi
}

run_reset_helper_direct() {
    local cli_args=""
    local env_args=()

    while IFS= read -r line; do
        [ -n "$line" ] && env_args+=("$line")
    done < <(baseline_rehearsal_env)

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --args)
                cli_args="$2"
                shift 2
                ;;
            *)
                env_args+=("$1")
                shift
                ;;
        esac
    done

    env_args+=("PATH=$TEST_WORKSPACE/bin:/usr/bin:/bin:/usr/local/bin")
    env_args+=("HOME=$TEST_WORKSPACE")
    env_args+=("TMPDIR=$TEST_WORKSPACE/tmp")

    local reset_helper_script="$TEST_WORKSPACE/scripts/lib/staging_billing_rehearsal_reset.sh"
    RUN_EXIT_CODE=0
    if ! parse_cli_args_string "$cli_args"; then
        RUN_STDOUT="ERROR: invalid reset-helper CLI args"
        RUN_EXIT_CODE=1
        return
    fi
    if [ "${#PARSED_CLI_ARGS[@]}" -gt 0 ]; then
        RUN_STDOUT="$(env -i "${env_args[@]}" /bin/bash "$reset_helper_script" "${PARSED_CLI_ARGS[@]}" 2>&1)" || RUN_EXIT_CODE=$?
    else
        RUN_STDOUT="$(env -i "${env_args[@]}" /bin/bash "$reset_helper_script" 2>&1)" || RUN_EXIT_CODE=$?
    fi
}

run_capture_billing_cross_check_inputs() {
    local cli_args=""
    local env_args=()

    while IFS= read -r line; do
        [ -n "$line" ] && env_args+=("$line")
    done < <(baseline_rehearsal_env)

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --args)
                cli_args="$2"
                shift 2
                ;;
            *)
                env_args+=("$1")
                shift
                ;;
        esac
    done

    env_args+=("AWS_ACCESS_KEY_ID=contract-test-key")
    env_args+=("AWS_SECRET_ACCESS_KEY=contract-test-secret")
    env_args+=("AWS_DEFAULT_REGION=us-east-1")
    env_args+=("PATH=$TEST_WORKSPACE/bin:/usr/bin:/bin:/usr/local/bin")
    env_args+=("HOME=$TEST_WORKSPACE")
    env_args+=("TMPDIR=$TEST_WORKSPACE/tmp")

    local capture_script="$TEST_WORKSPACE/scripts/launch/capture_billing_cross_check_inputs.sh"
    RUN_EXIT_CODE=0
    if ! parse_cli_args_string "$cli_args"; then
        RUN_STDOUT="ERROR: invalid capture CLI args"
        RUN_EXIT_CODE=1
        return
    fi
    if [ "${#PARSED_CLI_ARGS[@]}" -gt 0 ]; then
        RUN_STDOUT="$(env -i "${env_args[@]}" /bin/bash "$capture_script" "${PARSED_CLI_ARGS[@]}" 2>&1)" || RUN_EXIT_CODE=$?
    else
        RUN_STDOUT="$(env -i "${env_args[@]}" /bin/bash "$capture_script" 2>&1)" || RUN_EXIT_CODE=$?
    fi
}

assert_refusal_matrix_case() {
    local case_name="$1"
    local expected_classification="$2"
    local cli_suffix="$3"
    shift 3

    setup_workspace
    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env ${cli_suffix}" "$@"

    assert_rehearsal_fails_as_blocker

    local artifact_dir
    artifact_dir="$(find_artifact_dir)"

    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "$expected_classification" \
        "$case_name should emit stable blocker classification"
    assert_contains "$(read_file_or_empty "$artifact_dir/steps/live_mutation_attempt.json")" "blocked" \
        "$case_name should leave live-mutation attempt as blocked artifact"
    assert_no_live_mutation_attempt_logged
}

rehearsal_function_file() {
    local fn_name="$1"
    rg -l "^${fn_name}\\(\\) \\{" "$REPO_ROOT/scripts/lib/staging_billing_rehearsal"*.sh 2>/dev/null | head -1 || true
}

script_line_count() {
    wc -l < "$1" | tr -d ' '
}

function_line_count() {
    python3 - "$1" "$2" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
fn_name = sys.argv[2]
lines = path.read_text(encoding="utf-8").splitlines()
start_idx = -1
for idx, line in enumerate(lines):
    if re.match(rf"^{re.escape(fn_name)}\(\)\s*\{{\s*$", line):
        start_idx = idx
        break

if start_idx < 0:
    print("")
    raise SystemExit(0)

brace_balance = 0
for end_idx in range(start_idx, len(lines)):
    brace_balance += lines[end_idx].count("{")
    brace_balance -= lines[end_idx].count("}")
    if brace_balance == 0:
        print(end_idx - start_idx + 1)
        raise SystemExit(0)

print("")
PY
}

assert_line_count_lte() {
    local measured="$1" max_allowed="$2" msg="$3"
    if [ -z "$measured" ]; then
        fail "$msg (line count not found)"
        return
    fi
    if [ "$measured" -le "$max_allowed" ]; then
        pass "$msg"
    else
        fail "$msg (max=$max_allowed actual=$measured)"
    fi
}

json_field() {
    python3 - "$1" "$2" <<'PY'
import json
import sys

obj = json.loads(sys.argv[1])
value = obj.get(sys.argv[2], "")
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
else:
    print(str(value))
PY
}

json_file_field() {
    json_file_path_field "$1" "$2"
}

json_file_path_field() {
    if [ ! -f "$1" ]; then
        printf '\n'
        return 0
    fi
    python3 - "$1" "$2" <<'PY'
import json
import sys

path = sys.argv[1]
fields = [part for part in sys.argv[2].split(".") if part]
with open(path, "r", encoding="utf-8") as f:
    value = json.load(f)
for field in fields:
    if isinstance(value, dict):
        value = value.get(field, "")
    else:
        value = ""
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
elif isinstance(value, (dict, list)):
    print(json.dumps(value, sort_keys=True))
else:
    print(str(value))
PY
}

assert_file_exists() {
    local path="$1" msg="$2"
    if [ -f "$path" ]; then
        pass "$msg"
    else
        fail "$msg (missing file: $path)"
    fi
}

assert_valid_json_file() {
    local path="$1" msg="$2"
    local payload
    if [ ! -f "$path" ]; then
        fail "$msg (missing file: $path)"
        return
    fi
    payload="$(cat "$path")"
    assert_valid_json "$payload" "$msg"
}

assert_artifact_path_shape() {
    local path="$1" msg="$2"
    local base
    base="$(basename "$path")"
    if [[ "$base" =~ ^fjcloud_staging_billing_rehearsal_[0-9]{8}T[0-9]{6}Z_[0-9]+$ ]]; then
        pass "$msg"
    else
        fail "$msg (unexpected artifact directory name: $base)"
    fi
}

find_artifact_dir() {
    local d
    for d in "$TEST_WORKSPACE/tmp/fjcloud_staging_billing_rehearsal_"*; do
        [ -d "$d" ] && { printf '%s\n' "$d"; return 0; }
    done
    printf '\n'
    return 0
}

find_artifact_dirs() {
    local d
    for d in "$TEST_WORKSPACE/tmp/fjcloud_staging_billing_rehearsal_"*; do
        [ -d "$d" ] && printf '%s\n' "$d"
    done
}

find_artifact_dir_by_index() {
    local target_index="$1"
    local current_index=1 d
    while IFS= read -r d; do
        if [ "$current_index" -eq "$target_index" ]; then
            printf '%s\n' "$d"
            return 0
        fi
        current_index=$((current_index + 1))
    done < <(find_artifact_dirs)
    printf '\n'
}

call_count_matching() {
    local pattern="$1"
    grep -c "$pattern" "$TEST_CALL_LOG" 2>/dev/null || true
}

reset_deleted_invoice_ids_file() {
    printf '%s\n' "$TEST_WORKSPACE/tmp/mock_psql_reset_deleted_ids.txt"
}

assert_repeat_same_month_reuse_contract() {
    local rehearsal_args first_artifact_dir second_artifact_dir calls reset_deleted_file
    local second_summary second_billing_run

    rehearsal_args="--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-03 --confirm-live-mutation"
    run_rehearsal --args "$rehearsal_args" "REHEARSAL_MOCK_BATCH_MODE=created_then_no_created"

    first_artifact_dir="$(find_artifact_dir_by_index 1)"
    assert_rehearsal_succeeds
    assert_eq "$(json_file_field "$first_artifact_dir/summary.json" "result")" "passed" \
        "first same-month invocation should pass through the live-mutation path"
    assert_eq "$(json_file_field "$first_artifact_dir/billing_run.json" "classification")" "billing_run_succeeded" \
        "first same-month invocation should record created invoice evidence"
    assert_contains "$(read_file_or_empty "$first_artifact_dir/billing_run.json")" '"11111111-1111-4111-8111-111111111111"' \
        "first same-month invocation should record created invoice 11111111-1111-4111-8111-111111111111"
    assert_contains "$(read_file_or_empty "$first_artifact_dir/billing_run.json")" '"22222222-2222-4222-8222-222222222222"' \
        "first same-month invocation should record created invoice 22222222-2222-4222-8222-222222222222"
    assert_eq "$(json_file_field "$first_artifact_dir/invoice_rows.json" "classification")" "invoice_rows_ready" \
        "first same-month invocation should converge DB invoice evidence"

    run_rehearsal --args "$rehearsal_args" "REHEARSAL_MOCK_BATCH_MODE=created_then_no_created"

    second_artifact_dir="$(find_artifact_dir_by_index 2)"
    calls="$(read_file_or_empty "$TEST_CALL_LOG")"
    reset_deleted_file="$(reset_deleted_invoice_ids_file)"
    second_summary="$(read_file_or_empty "$second_artifact_dir/summary.json")"
    second_billing_run="$(read_file_or_empty "$second_artifact_dir/billing_run.json")"

    assert_rehearsal_succeeds
    assert_eq "$(json_file_field "$second_artifact_dir/summary.json" "result")" "passed" \
        "second same-month invocation should pass by reusing existing same-month invoice evidence"
    assert_eq "$(json_file_field "$second_artifact_dir/summary.json" "classification")" "billing_run_repeat_pass_existing_same_month_invoice" \
        "second same-month invocation should use the repeat-pass classification"
    assert_eq "$(json_file_field "$second_artifact_dir/billing_run.json" "classification")" "billing_run_repeat_pass_existing_same_month_invoice" \
        "second same-month billing_run artifact should preserve repeat-pass classification"
    assert_eq "$(json_file_field "$second_artifact_dir/invoice_rows.json" "classification")" "invoice_rows_ready" \
        "second same-month repeat-pass should still converge invoice-row evidence"
    assert_eq "$(json_file_field "$second_artifact_dir/invoice_email.json" "classification")" "invoice_email_ready" \
        "second same-month repeat-pass should still converge invoice-email evidence"
    assert_contains "$second_summary" "11111111-1111-1111-1111-111111111111" \
        "second same-month summary detail should name the reused allowlisted tenant"
    assert_contains "$second_billing_run" "11111111-1111-1111-1111-111111111111" \
        "second same-month billing_run detail should name the reused allowlisted tenant"
    assert_contains "$second_billing_run" '"reused_tenant_ids": ["11111111-1111-1111-1111-111111111111"]' \
        "second same-month billing_run payload should name reused tenant ids from the DB row"
    assert_contains "$second_billing_run" '"invoice_ids": ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"]' \
        "second same-month billing_run payload should preserve canonical invoice_ids"
    assert_not_contains "$second_summary" "11111111-1111-1111-1111-111111111111,22222222-2222-2222-2222-222222222222" \
        "second same-month summary detail should not echo the full tenant allowlist"
    assert_not_contains "$second_billing_run" "11111111-1111-1111-1111-111111111111,22222222-2222-2222-2222-222222222222" \
        "second same-month billing_run detail should not echo the full tenant allowlist"
    assert_eq "$(call_count_matching '/admin/billing/run')" "1" \
        "same-month repeat should not add a second billing-run request"
    assert_eq "$(call_count_matching 'stage4_reset_')" "0" \
        "same-month repeat should not execute reset SQL ownership markers"
    assert_not_contains "$calls" "/v1/invoices/" \
        "same-month repeat should not perform Stripe invoice reset mutations"
    assert_not_contains "$calls" "stripe|invoices delete" \
        "same-month repeat should not delete Stripe invoices through the CLI"
    assert_not_contains "$calls" "stripe|invoices void" \
        "same-month repeat should not void Stripe invoices through the CLI"
    if [ ! -s "$reset_deleted_file" ]; then
        pass "same-month repeat should leave reset deleted-id state absent or empty"
    else
        fail "same-month repeat should leave reset deleted-id state absent or empty (file: $reset_deleted_file)"
    fi
}

test_live_mutation_ignores_unrelated_same_month_invoice_before_first_run() {
    setup_workspace "11111111-1111-1111-1111-111111111111"
    wrap_preflight_owner_with_call_log

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-03 --confirm-live-mutation" \
        "REHEARSAL_MOCK_SAME_MONTH_LOOKUP_MODE=unrelated_non_synthetic"

    assert_rehearsal_succeeds

    local artifact_dir
    artifact_dir="$(find_artifact_dir)"
    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "rehearsal_completed" \
        "unrelated same-month invoice rows should not trigger repeat-pass classification"
    assert_eq "$(json_file_field "$artifact_dir/billing_run.json" "classification")" "billing_run_succeeded" \
        "unrelated same-month invoice rows should preserve first-run billing mutation"
    assert_eq "$(call_count_matching '/admin/billing/run')" "1" \
        "unrelated same-month invoice rows should not suppress the first billing-run request"
    assert_not_contains "$(read_file_or_empty "$artifact_dir/billing_run.json")" "inv_unrelated_same_month" \
        "unrelated same-month invoice row should not be reused as billing-run evidence"
}

test_live_mutation_ignores_successful_same_month_lookup_noise_before_first_run() {
    setup_workspace "11111111-1111-1111-1111-111111111111"
    wrap_preflight_owner_with_call_log

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-03 --confirm-live-mutation" \
        "REHEARSAL_MOCK_SAME_MONTH_LOOKUP_MODE=notice_only"

    assert_rehearsal_succeeds

    local artifact_dir
    artifact_dir="$(find_artifact_dir)"
    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "rehearsal_completed" \
        "successful same-month lookup noise should not trigger repeat-pass classification"
    assert_eq "$(json_file_field "$artifact_dir/billing_run.json" "classification")" "billing_run_succeeded" \
        "successful same-month lookup noise should preserve first-run billing mutation"
    assert_eq "$(call_count_matching '/admin/billing/run')" "1" \
        "successful same-month lookup noise should not suppress the first billing-run request"
    assert_not_contains "$(read_file_or_empty "$artifact_dir/billing_run.json")" "NOTICE:" \
        "successful same-month lookup noise should not be reused as billing-run evidence"
}

test_live_mutation_blocks_when_repeat_pass_lookup_fails_before_mutation() {
    setup_workspace "11111111-1111-1111-1111-111111111111"
    wrap_preflight_owner_with_call_log

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-03 --confirm-live-mutation" \
        "REHEARSAL_MOCK_SAME_MONTH_LOOKUP_EXIT=21" \
        "REHEARSAL_MOCK_SAME_MONTH_LOOKUP_STDERR=could not connect to staging db"

    assert_rehearsal_fails_as_blocker

    local artifact_dir
    artifact_dir="$(find_artifact_dir)"
    assert_eq "$(json_file_field "$artifact_dir/summary.json" "classification")" "same_month_invoice_lookup_failed" \
        "same-month lookup failure should fail closed with stable classification"
    assert_eq "$(json_file_field "$artifact_dir/billing_run.json" "classification")" "same_month_invoice_lookup_failed" \
        "billing_run artifact should record lookup failure instead of HTTP mutation evidence"
    assert_no_live_mutation_attempt_logged
}

read_file_or_empty() {
    local path="$1"
    if [ -f "$path" ]; then
        cat "$path"
    else
        printf '\n'
    fi
}

path_mode() {
    stat -f '%Lp' "$1"
}

assert_summary_and_step_files_exist() {
    local artifact_dir="$1"
    assert_file_exists "$artifact_dir/summary.json" "summary.json should exist"
    assert_file_exists "$artifact_dir/steps/preflight.json" "preflight step artifact should exist"
    assert_file_exists "$artifact_dir/steps/metering_evidence.json" "metering evidence step artifact should exist"
    assert_file_exists "$artifact_dir/steps/live_mutation_guard.json" "live-mutation guard step artifact should exist"
    assert_file_exists "$artifact_dir/steps/live_mutation_attempt.json" "live-mutation attempt step artifact should exist"
}

assert_health_step_exists() {
    local artifact_dir="$1"
    local health_step_path="$artifact_dir/steps/health.json"
    assert_file_exists "$health_step_path" "health step artifact should exist after preflight passes"
    assert_valid_json_file "$health_step_path" "health step artifact should be valid JSON"
    assert_eq "$(json_file_field "$health_step_path" "name")" "health" \
        "health step artifact should preserve name field"
}

assert_health_step_absent() {
    local artifact_dir="$1"
    local health_step_path="$artifact_dir/steps/health.json"
    if [ ! -f "$health_step_path" ]; then
        pass "health step artifact should be absent when preflight does not pass"
    else
        fail "health step artifact should be absent when preflight does not pass (unexpected file: $health_step_path)"
    fi
}

assert_step_detail_shape() {
    local step_file="$1" step_name="$2"
    local name_value detail_value

    if [ ! -f "$step_file" ]; then
        fail "$step_name artifact should exist before checking detail shape"
        return
    fi

    assert_valid_json_file "$step_file" "$step_name artifact should be valid JSON"
    name_value="$(json_file_field "$step_file" "name")"
    detail_value="$(json_file_field "$step_file" "detail")"

    assert_eq "$name_value" "$step_name" "$step_name artifact should preserve name field"
    if [ -n "$detail_value" ]; then
        pass "$step_name artifact should include non-empty detail"
    else
        fail "$step_name artifact should include non-empty detail"
    fi
}

assert_no_live_mutation_attempt_logged() {
    local calls
    calls="$(cat "$TEST_CALL_LOG")"
    assert_not_contains "$calls" "/admin/billing/run" \
        "live mutation should not call POST /admin/billing/run"
}

test_live_mutation_redacts_admin_key_and_locks_artifact_permissions() {
    setup_workspace
    wrap_preflight_owner_with_call_log

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-03 --confirm-live-mutation"

    assert_rehearsal_succeeds

    local artifact_dir billing_call
    artifact_dir="$(find_artifact_dir)"
    billing_call="$(grep '^curl|.*/admin/billing/run' "$TEST_CALL_LOG" | head -1 || true)"

    assert_eq "$(path_mode "$artifact_dir")" "700" \
        "artifact directory should be owner-only"
    assert_eq "$(path_mode "$artifact_dir/steps")" "700" \
        "steps directory should be owner-only"
    assert_eq "$(path_mode "$artifact_dir/summary.json")" "600" \
        "summary artifact should not be group/world readable"
    assert_eq "$(path_mode "$artifact_dir/invoice_rows.json")" "600" \
        "invoice evidence artifact should not be group/world readable"
    assert_not_contains "$billing_call" "staging-admin-contract" \
        "mock curl call log must not persist the admin key"
    assert_contains "$billing_call" "x-admin-key: REDACTED" \
        "mock curl call log should retain a redacted admin-key marker"
}

assert_rehearsal_fails_as_blocker() {
    assert_eq "$RUN_EXIT_CODE" "1" "rehearsal should fail with blocker exit"
    local artifact_dir=""
    artifact_dir="$(find_artifact_dir)"
    if [ -z "$artifact_dir" ]; then
        fail "rehearsal should emit a deterministic artifact directory"
        return
    fi
    assert_artifact_path_shape "$artifact_dir" "artifact dir should match deterministic rehearsal pattern"
    assert_summary_and_step_files_exist "$artifact_dir"
    assert_valid_json_file "$artifact_dir/summary.json" "blocker summary should remain machine-readable"
    assert_step_detail_shape "$artifact_dir/steps/preflight.json" "preflight"
    assert_step_detail_shape "$artifact_dir/steps/metering_evidence.json" "metering_evidence"
    assert_step_detail_shape "$artifact_dir/steps/live_mutation_guard.json" "live_mutation_guard"
    assert_step_detail_shape "$artifact_dir/steps/live_mutation_attempt.json" "live_mutation_attempt"
}
assert_rehearsal_succeeds() {
    assert_eq "$RUN_EXIT_CODE" "0" "rehearsal should succeed when live mutation evidence converges"
    local artifact_dir=""
    artifact_dir="$(find_artifact_dir)"
    if [ -z "$artifact_dir" ]; then
        fail "rehearsal should emit a deterministic artifact directory"
        return
    fi
    assert_artifact_path_shape "$artifact_dir" "artifact dir should match deterministic rehearsal pattern"
    assert_summary_and_step_files_exist "$artifact_dir"
    assert_valid_json_file "$artifact_dir/summary.json" "success summary should remain machine-readable"
    assert_health_step_exists "$artifact_dir"
}

first_call_line_matching() {
    local pattern="$1"
    grep -n "$pattern" "$TEST_CALL_LOG" 2>/dev/null | head -1 | cut -d: -f1 || true
}

assert_stage3_evidence_artifacts_exist() {
    local artifact_dir="$1"
    assert_file_exists "$artifact_dir/billing_run.json" "billing_run artifact should exist"
    assert_file_exists "$artifact_dir/invoice_rows.json" "invoice_rows artifact should exist"
    assert_file_exists "$artifact_dir/webhook.json" "webhook artifact should exist"
    assert_file_exists "$artifact_dir/invoice_email.json" "invoice_email artifact should exist"
    assert_valid_json_file "$artifact_dir/billing_run.json" "billing_run artifact should be valid JSON"
    assert_valid_json_file "$artifact_dir/invoice_rows.json" "invoice_rows artifact should be valid JSON"
    assert_valid_json_file "$artifact_dir/webhook.json" "webhook artifact should be valid JSON"
    assert_valid_json_file "$artifact_dir/invoice_email.json" "invoice_email artifact should be valid JSON"
}

assert_cross_check_input_artifacts_exist() {
    local artifact_dir="$1"
    assert_file_exists "$artifact_dir/invoice_db_row.json" "invoice_db_row artifact should exist"
    assert_file_exists "$artifact_dir/invoice_line_items.json" "invoice_line_items artifact should exist"
    assert_file_exists "$artifact_dir/customer_billing_context.json" "customer_billing_context artifact should exist"
    assert_file_exists "$artifact_dir/rate_card_selection.json" "rate_card_selection artifact should exist"
    assert_file_exists "$artifact_dir/customer_rate_override.json" "customer_rate_override artifact should exist"
    assert_file_exists "$artifact_dir/usage_daily_replay_rows.json" "usage_daily_replay_rows artifact should exist"
    assert_file_exists "$artifact_dir/usage_records_provenance.json" "usage_records_provenance artifact should exist"
    assert_valid_json_file "$artifact_dir/invoice_db_row.json" "invoice_db_row artifact should be valid JSON"
    assert_valid_json_file "$artifact_dir/invoice_line_items.json" "invoice_line_items artifact should be valid JSON"
    assert_valid_json_file "$artifact_dir/customer_billing_context.json" "customer_billing_context artifact should be valid JSON"
    assert_valid_json_file "$artifact_dir/rate_card_selection.json" "rate_card_selection artifact should be valid JSON"
    assert_valid_json_file "$artifact_dir/customer_rate_override.json" "customer_rate_override artifact should be valid JSON"
    assert_valid_json_file "$artifact_dir/usage_daily_replay_rows.json" "usage_daily_replay_rows artifact should be valid JSON"
    assert_valid_json_file "$artifact_dir/usage_records_provenance.json" "usage_records_provenance artifact should be valid JSON"
}
