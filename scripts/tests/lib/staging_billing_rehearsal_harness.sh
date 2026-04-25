#!/usr/bin/env bash
# Shared harness helpers for staging_billing_rehearsal shell tests.

RUN_STDOUT=""
RUN_EXIT_CODE=0
TEST_WORKSPACE=""
TEST_CALL_LOG=""
CLEANUP_DIRS=()

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
EOV
}

shell_quote_for_script() {
    local quoted
    printf -v quoted '%q' "$1"
    printf '%s\n' "$quoted"
}

setup_workspace() {
    TEST_WORKSPACE="$(mktemp -d)"
    CLEANUP_DIRS+=("$TEST_WORKSPACE")
    TEST_CALL_LOG="$TEST_WORKSPACE/calls.log"

    mkdir -p "$TEST_WORKSPACE/scripts/lib" \
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
    cp "$REPO_ROOT/scripts/lib/validation_json.sh" "$TEST_WORKSPACE/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/live_gate.sh" "$TEST_WORKSPACE/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/billing_rehearsal_steps.sh" "$TEST_WORKSPACE/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/staging_billing_rehearsal"*.sh "$TEST_WORKSPACE/scripts/lib/"

    # Copy rehearsal runner only if it exists; Stage 1 is expected to be red
    # while this file is missing.
    [ -f "$REPO_ROOT/scripts/staging_billing_rehearsal.sh" ] && \
        cp "$REPO_ROOT/scripts/staging_billing_rehearsal.sh" "$TEST_WORKSPACE/scripts/" || true

    write_mock_psql
    write_mock_curl
    write_mock_stripe
    write_explicit_env_file "$TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env"
    write_malformed_env_file "$TEST_WORKSPACE/inputs/staging_rehearsal.malformed.env"
}

write_mock_psql() {
    local quoted_log
    quoted_log="$(shell_quote_for_script "$TEST_CALL_LOG")"
    local invoice_attempt_file webhook_attempt_file
    invoice_attempt_file="$(shell_quote_for_script "$TEST_WORKSPACE/tmp/mock_psql_invoice_attempt.txt")"
    webhook_attempt_file="$(shell_quote_for_script "$TEST_WORKSPACE/tmp/mock_psql_webhook_attempt.txt")"

    cat > "$TEST_WORKSPACE/bin/psql" <<MOCK
#!/usr/bin/env bash
echo "psql|\$*" >> $quoted_log
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
            printf 'inv_stage3_a|si_stage3_a|2026-03-30T12:00:00Z|alpha@example.test\n'
            printf 'inv_stage3_b|si_stage3_b|2026-03-30T12:00:05Z|beta@example.test\n'
            ;;
        plus_alias_email)
            printf 'inv_stage3_a|si_stage3_a|2026-03-30T12:00:00Z|alpha+alerts@example.test\n'
            printf 'inv_stage3_b|si_stage3_b|2026-03-30T12:00:05Z|beta@example.test\n'
            ;;
        missing_stripe)
            printf 'inv_stage3_a||2026-03-30T12:00:00Z|alpha@example.test\n'
            printf 'inv_stage3_b|si_stage3_b|2026-03-30T12:00:05Z|beta@example.test\n'
            ;;
        missing_paid_at)
            printf 'inv_stage3_a|si_stage3_a||alpha@example.test\n'
            printf 'inv_stage3_b|si_stage3_b||beta@example.test\n'
            ;;
        missing_email)
            printf 'inv_stage3_a|si_stage3_a|2026-03-30T12:00:00Z|\n'
            printf 'inv_stage3_b|si_stage3_b|2026-03-30T12:00:05Z|\n'
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
            printf 'inv_stage3_a|si_stage3_a|2026-03-30T12:02:00Z\n'
            printf 'inv_stage3_b|si_stage3_b|2026-03-30T12:02:05Z\n'
            ;;
        unprocessed|missing)
            printf 'inv_stage3_a|si_stage3_a|\ninv_stage3_b|si_stage3_b|\n'
            ;;
    esac
    exit 0
fi

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
fail_on_http=0

while [ "$#" -gt 0 ]; do
    case "$1" in
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
    */health)
        response_code="${REHEARSAL_MOCK_HEALTH_STATUS:-200}"
        response_body='{"status":"ok"}'
        ;;
    */admin/billing/run)
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
                malformed)
                    response_body='{"not":"valid"'
                    ;;
                created)
                    response_body='{"month":"2026-03","invoices_created":2,"invoices_skipped":0,"results":[{"customer_id":"cust_stage3_a","status":"created","invoice_id":"inv_stage3_a","reason":null},{"customer_id":"cust_stage3_b","status":"created","invoice_id":"inv_stage3_b","reason":null}]}'
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
        invoice_id="inv_stage3_a"
        if [[ "$url" == *"beta@example.test"* ]] || [[ "$url" == *"beta%40example.test"* ]]; then
            invoice_id="inv_stage3_b"
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
    local mailpit_attempt_file
    quoted_log="$(shell_quote_for_script "$TEST_CALL_LOG")"
    mailpit_attempt_file="$(shell_quote_for_script "$TEST_WORKSPACE/tmp/mock_curl_mailpit_attempt.txt")"

    {
        cat <<MOCK
#!/usr/bin/env bash
CALL_LOG=$quoted_log
MAILPIT_ATTEMPT_FILE=$mailpit_attempt_file
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

    cat > "$TEST_WORKSPACE/bin/stripe" <<MOCK
#!/usr/bin/env bash
echo "stripe|\$*" >> $quoted_log
exit 0
MOCK
    chmod +x "$TEST_WORKSPACE/bin/stripe"
}

write_explicit_env_file() {
    local path="$1"
    cat > "$path" <<'ENVFILE'
STAGING_API_URL=https://staging-api.example.test
STAGING_STRIPE_WEBHOOK_URL=https://staging-api.example.test/webhooks/stripe
STRIPE_SECRET_KEY=sk_test_rehearsal_contract
STRIPE_WEBHOOK_SECRET=whsec_rehearsal_contract
ADMIN_KEY=staging-admin-contract
DATABASE_URL=postgres://griddle:griddle_local@127.0.0.1:15432/fjcloud_dev
INTEGRATION_DB_URL=postgres://griddle:griddle_local@127.0.0.1:15432/fjcloud_dev
MAILPIT_API_URL=https://mailpit.example.test
ENVFILE
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
    if [ -n "$cli_args" ]; then
        # shellcheck disable=SC2086
        RUN_STDOUT="$(env -i "${env_args[@]}" /bin/bash "$rehearsal_script" $cli_args 2>&1)" || RUN_EXIT_CODE=$?
    else
        RUN_STDOUT="$(env -i "${env_args[@]}" /bin/bash "$rehearsal_script" 2>&1)" || RUN_EXIT_CODE=$?
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
    if [ ! -f "$1" ]; then
        printf '\n'
        return 0
    fi
    python3 - "$1" "$2" <<'PY'
import json
import sys

path = sys.argv[1]
field = sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    obj = json.load(f)
value = obj.get(field, "")
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
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
