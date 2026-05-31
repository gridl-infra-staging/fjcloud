#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/live_card_e2e_test.sh"

assert_equals() {
    local actual="$1"
    local expected="$2"
    local context="$3"
    if [ "$actual" != "$expected" ]; then
        echo "FAIL: ${context} expected=${expected} actual=${actual}" >&2
        exit 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local context="$3"
    if ! printf '%s' "$haystack" | grep -Fq "$needle"; then
        echo "FAIL: ${context} missing needle=${needle}" >&2
        exit 1
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local context="$3"
    if printf '%s' "$haystack" | grep -Fq "$needle"; then
        echo "FAIL: ${context} unexpectedly contained needle=${needle}" >&2
        exit 1
    fi
}

assert_file_equals() {
    local file_a="$1"
    local file_b="$2"
    local context="$3"
    if ! cmp -s "$file_a" "$file_b"; then
        echo "FAIL: ${context} files differ: $file_a vs $file_b" >&2
        exit 1
    fi
}

make_sweeper_stub() {
    local sweeper_stub="$1"
    cat > "$sweeper_stub" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

args_file="${LIVE_E2E_SWEEPER_ARGS_FILE:?LIVE_E2E_SWEEPER_ARGS_FILE is required}"
printf '%s\n' "$*" > "$args_file"

if [ "${1:-}" = "--dry-run" ]; then
    printf '{"dry_run":true,"pages_scanned":0,"total_scanned":0,"skipped_non_lane":0,"skipped_fresh":0,"candidate_tokens":[],"closed_tokens":[]}\n'
else
    printf '{"dry_run":false,"pages_scanned":0,"total_scanned":0,"skipped_non_lane":0,"skipped_fresh":0,"candidate_tokens":[],"closed_tokens":[]}\n'
fi
EOS
    chmod +x "$sweeper_stub"
}

make_shim() {
    local shim_path="$1"
    local create_called_file="$2"
    cat > "$shim_path" <<EOS
#!/usr/bin/env bash
privacy_com_create_card() {
    printf 'called' > "$create_called_file"
    return 70
}

check_stripe_key_live() {
    return 0
}
EOS
}

make_bash_stub() {
    local stub_path="$1"
    cat > "$stub_path" <<'EOS'
#!/bin/bash
set -euo pipefail

expected_sweeper_path="${LIVE_E2E_EXPECTED_SWEEPER_PATH:?LIVE_E2E_EXPECTED_SWEEPER_PATH is required}"
args_file="${LIVE_E2E_BASH_STUB_ARGS_FILE:?LIVE_E2E_BASH_STUB_ARGS_FILE is required}"

printf '%s\n' "$*" > "$args_file"
if [ "${1:-}" != "$expected_sweeper_path" ]; then
    echo "unexpected sweeper path: ${1:-<missing>}" >&2
    exit 9
fi

shift
if [ "${1:-}" != "--dry-run" ]; then
    echo "unexpected sweeper args: $*" >&2
    exit 9
fi

printf '{"dry_run":true,"pages_scanned":0,"total_scanned":0,"skipped_non_lane":0,"skipped_fresh":0,"candidate_tokens":[],"closed_tokens":[]}\n'
EOS
    chmod +x "$stub_path"
}

run_success_dry_run_case() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' RETURN

    local sweeper_stub="$tmp_dir/privacy_card_sweeper.sh"
    local shim_path="$tmp_dir/live_card_e2e_shim.sh"
    local create_called_file="$tmp_dir/create_called"
    local sweeper_args_file="$tmp_dir/sweeper_args"

    make_sweeper_stub "$sweeper_stub"
    make_shim "$shim_path" "$create_called_file"

    local stdout_file="$tmp_dir/stdout"
    local stderr_file="$tmp_dir/stderr"

    set +e
    LIVE_E2E_TEST_SHIM="$shim_path" \
    LIVE_E2E_ALLOW_TEST_SHIM=1 \
    LIVE_E2E_SWEEPER_BIN="$sweeper_stub" \
    LIVE_E2E_EVIDENCE_DIR="$tmp_dir/evidence" \
    LIVE_E2E_SWEEPER_ARGS_FILE="$sweeper_args_file" \
    STRIPE_LIVE_CUTOVER=1 \
    STRIPE_SECRET_KEY=sk_live_unit_test_key \
    PRIVACY_API_KEY=privacy_unit_test_key \
    API_URL=http://127.0.0.1:65535 \
    ADMIN_KEY=admin_unit_test_key \
    PK_LIVE=pk_live_unit_test_key \
    LIVE_E2E_STRIPE_CUSTOMER_ID=cus_unit_test \
    BILLING_MONTH=2026-05 \
    /bin/bash "$RUNNER" --env=prod --dry-run >"$stdout_file" 2>"$stderr_file"
    local rc=$?
    set -e

    assert_equals "$rc" "0" "dry_run_success_rc"
    if [ -f "$create_called_file" ]; then
        echo "FAIL: dry-run unexpectedly called privacy_com_create_card" >&2
        exit 1
    fi

    local sweeper_args
    sweeper_args="$(cat "$sweeper_args_file")"
    assert_equals "$sweeper_args" "--dry-run" "sweeper_receives_dry_run_flag"

    local output
    output="$(cat "$stdout_file")"
    assert_contains "$output" '"dry_run":true' "summary_dry_run_true"
    assert_contains "$output" '"sweeper_summary"' "summary_has_sweeper"
    assert_contains "$output" '"env":"prod"' "summary_has_env_prod"
    assert_contains "$output" '"payment_intent_id":null' "summary_pi_null_dry_run"
    assert_contains "$output" '"charge_id":null' "summary_charge_null_dry_run"

    local run_dir
    run_dir="$(ls -1 "$tmp_dir/evidence" | head -n1)"
    if [ -z "$run_dir" ]; then
        echo "FAIL: expected run-scoped evidence directory under $tmp_dir/evidence" >&2
        exit 1
    fi

    local summary_file="$tmp_dir/evidence/$run_dir/summary.json"
    local sweeper_file="$tmp_dir/evidence/$run_dir/sweeper_summary.json"
    if [ ! -f "$summary_file" ] || [ ! -f "$sweeper_file" ]; then
        echo "FAIL: expected summary.json and sweeper_summary.json in run dir" >&2
        exit 1
    fi
    assert_file_equals "$stdout_file" "$summary_file" "summary_stdout_matches_file"
}

run_bad_prefix_case() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' RETURN

    local sweeper_stub="$tmp_dir/privacy_card_sweeper.sh"
    local shim_path="$tmp_dir/live_card_e2e_shim.sh"
    local create_called_file="$tmp_dir/create_called"
    local sweeper_args_file="$tmp_dir/sweeper_args"

    make_sweeper_stub "$sweeper_stub"
    make_shim "$shim_path" "$create_called_file"

    local stdout_file="$tmp_dir/stdout"
    local stderr_file="$tmp_dir/stderr"

    set +e
    LIVE_E2E_TEST_SHIM="$shim_path" \
    LIVE_E2E_ALLOW_TEST_SHIM=1 \
    LIVE_E2E_SWEEPER_BIN="$sweeper_stub" \
    LIVE_E2E_EVIDENCE_DIR="$tmp_dir/evidence" \
    LIVE_E2E_SWEEPER_ARGS_FILE="$sweeper_args_file" \
    STRIPE_SECRET_KEY=sk_live_unit_test_key \
    PRIVACY_API_KEY=privacy_unit_test_key \
    API_URL=http://127.0.0.1:65535 \
    ADMIN_KEY=admin_unit_test_key \
    PK_LIVE=pk_live_unit_test_key \
    LIVE_E2E_STRIPE_CUSTOMER_ID=cus_unit_test \
    BILLING_MONTH=2026-05 \
    /bin/bash "$RUNNER" --env=prod --dry-run >"$stdout_file" 2>"$stderr_file"
    local rc=$?
    set -e

    if [ "$rc" -eq 0 ]; then
        echo "FAIL: expected non-zero exit when STRIPE_LIVE_CUTOVER unset with sk_live key" >&2
        exit 1
    fi

    local stderr_output
    stderr_output="$(cat "$stderr_file")"
    assert_contains "$stderr_output" "stripe_key_bad_prefix" "bad_prefix_classification"
}

run_bad_env_value_case() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' RETURN

    local sweeper_stub="$tmp_dir/privacy_card_sweeper.sh"
    local shim_path="$tmp_dir/live_card_e2e_shim.sh"
    local create_called_file="$tmp_dir/create_called"
    local sweeper_args_file="$tmp_dir/sweeper_args"

    make_sweeper_stub "$sweeper_stub"
    make_shim "$shim_path" "$create_called_file"

    local stdout_file="$tmp_dir/stdout"
    local stderr_file="$tmp_dir/stderr"

    set +e
    LIVE_E2E_TEST_SHIM="$shim_path" \
    LIVE_E2E_ALLOW_TEST_SHIM=1 \
    LIVE_E2E_SWEEPER_BIN="$sweeper_stub" \
    LIVE_E2E_EVIDENCE_DIR="$tmp_dir/evidence" \
    LIVE_E2E_SWEEPER_ARGS_FILE="$sweeper_args_file" \
    STRIPE_LIVE_CUTOVER=1 \
    STRIPE_SECRET_KEY=sk_live_unit_test_key \
    PRIVACY_API_KEY=privacy_unit_test_key \
    API_URL=http://127.0.0.1:65535 \
    ADMIN_KEY=admin_unit_test_key \
    PK_LIVE=pk_live_unit_test_key \
    LIVE_E2E_STRIPE_CUSTOMER_ID=cus_unit_test \
    BILLING_MONTH=2026-05 \
    bash "$RUNNER" --env=qa --dry-run >"$stdout_file" 2>"$stderr_file"
    local rc=$?
    set -e

    assert_equals "$rc" "2" "bad_env_value_rc"
    assert_contains "$(cat "$stderr_file")" "unknown env value" "bad_env_value_message"
}

run_default_sweeper_path_case() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' RETURN

    local shim_path="$tmp_dir/live_card_e2e_shim.sh"
    local create_called_file="$tmp_dir/create_called"
    local bash_stub="$tmp_dir/bash"
    local bash_stub_args_file="$tmp_dir/bash_args"
    local expected_sweeper_path="$SCRIPT_DIR/privacy_card_sweeper.sh"

    make_shim "$shim_path" "$create_called_file"
    make_bash_stub "$bash_stub"

    local stdout_file="$tmp_dir/stdout"
    local stderr_file="$tmp_dir/stderr"

    set +e
    PATH="$tmp_dir:$PATH" \
    LIVE_E2E_TEST_SHIM="$shim_path" \
    LIVE_E2E_ALLOW_TEST_SHIM=1 \
    LIVE_E2E_EVIDENCE_DIR="$tmp_dir/evidence" \
    LIVE_E2E_EXPECTED_SWEEPER_PATH="$expected_sweeper_path" \
    LIVE_E2E_BASH_STUB_ARGS_FILE="$bash_stub_args_file" \
    STRIPE_LIVE_CUTOVER=1 \
    STRIPE_SECRET_KEY=sk_live_unit_test_key \
    PRIVACY_API_KEY=privacy_unit_test_key \
    API_URL=http://127.0.0.1:65535 \
    ADMIN_KEY=admin_unit_test_key \
    PK_LIVE=pk_live_unit_test_key \
    LIVE_E2E_STRIPE_CUSTOMER_ID=cus_unit_test \
    BILLING_MONTH=2026-05 \
    /bin/bash "$RUNNER" --env=prod --dry-run >"$stdout_file" 2>"$stderr_file"
    local rc=$?
    set -e

    assert_equals "$rc" "0" "default_sweeper_path_rc"
    assert_contains "$(cat "$bash_stub_args_file")" "$expected_sweeper_path --dry-run" "default_sweeper_path_args"
    assert_contains "$(cat "$stdout_file")" '"classification":"success"' "default_sweeper_path_summary"
}

run_missing_env_summary_case() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' RETURN

    local sweeper_stub="$tmp_dir/privacy_card_sweeper.sh"
    local shim_path="$tmp_dir/live_card_e2e_shim.sh"
    local create_called_file="$tmp_dir/create_called"
    local sweeper_args_file="$tmp_dir/sweeper_args"

    make_sweeper_stub "$sweeper_stub"
    make_shim "$shim_path" "$create_called_file"

    local stdout_file="$tmp_dir/stdout"
    local stderr_file="$tmp_dir/stderr"

    set +e
    LIVE_E2E_TEST_SHIM="$shim_path" \
    LIVE_E2E_ALLOW_TEST_SHIM=1 \
    LIVE_E2E_SWEEPER_BIN="$sweeper_stub" \
    LIVE_E2E_EVIDENCE_DIR="$tmp_dir/evidence" \
    LIVE_E2E_SWEEPER_ARGS_FILE="$sweeper_args_file" \
    STRIPE_LIVE_CUTOVER=1 \
    STRIPE_SECRET_KEY=sk_live_unit_test_key \
    PRIVACY_API_KEY=privacy_unit_test_key \
    API_URL=http://127.0.0.1:65535 \
    ADMIN_KEY=admin_unit_test_key \
    PK_LIVE=pk_live_unit_test_key \
    BILLING_MONTH=2026-05 \
    /bin/bash "$RUNNER" --env=prod --dry-run >"$stdout_file" 2>"$stderr_file"
    local rc=$?
    set -e

    if [ "$rc" -eq 0 ]; then
        echo "FAIL: expected non-zero exit when required env is missing" >&2
        exit 1
    fi
    assert_contains "$(cat "$stderr_file")" "classification=env_missing" "missing_env_classification"

    local run_dir
    run_dir="$(ls -1 "$tmp_dir/evidence" | head -n1)"
    if [ -z "$run_dir" ]; then
        echo "FAIL: expected run-scoped evidence directory for missing env failure" >&2
        exit 1
    fi

    local summary_file="$tmp_dir/evidence/$run_dir/summary.json"
    if [ ! -f "$summary_file" ]; then
        echo "FAIL: expected summary.json for missing env failure" >&2
        exit 1
    fi

    assert_contains "$(cat "$summary_file")" '"classification":"env_missing"' "missing_env_summary_classification"
}

if [ ! -x "$RUNNER" ] && [ ! -f "$RUNNER" ]; then
    echo "FAIL: runner not found at $RUNNER" >&2
    exit 1
fi

make_full_path_shim() {
    local shim_path="$1"
    cat > "$shim_path" <<'EOS'
#!/usr/bin/env bash
# Comprehensive shim: returns success for every owner along the live mutation
# chain so the runner reaches summary emission without hitting real services.

check_stripe_key_live() { return 0; }
resolve_stripe_secret_key() { printf 'sk_live_unit_test_key\n'; }

privacy_com_create_card() {
    PRIVACY_CLIENT_BODY='{"account_token":"privacy_account_unit","card_program_token":"privacy_program_unit","token":"card_tok_unit","pan":"4111111111111111","cvv":"123","exp_month":"12","exp_year":"2030","state":"OPEN"}'
    PRIVACY_CLIENT_EXIT_CLASS="ok"
    PRIVACY_CLIENT_HTTP_CODE="200"
    PRIVACY_CLIENT_ERROR_MESSAGE=""
    return 0
}

privacy_com_close_card() {
    PRIVACY_CLIENT_EXIT_CLASS="ok"
    PRIVACY_CLIENT_HTTP_CODE="200"
    PRIVACY_CLIENT_BODY='{}'
    PRIVACY_CLIENT_ERROR_MESSAGE=""
    return 0
}

stripe_curl_user_config() {
    local stripe_key="$1"
    cat <<CFG
user = ":${stripe_key}"
CFG
}

node() {
    printf '{"ok":true,"pm_id":"pm_unit_test"}\n'
}

# Stub the billing+invoice admin endpoints by intercepting capture_json_response.
capture_json_response() {
    HTTP_RESPONSE_EXIT_STATUS=0
    local fn="$1"
    shift
    local method="${1:-}"
    local path="${2:-}"
    local all_args="$*"
    if [ "$fn" = "admin_call" ] && [ "$method" = "POST" ] && [ "$path" = "/admin/billing/run" ]; then
        HTTP_RESPONSE_CODE="200"
        HTTP_RESPONSE_BODY='{"results":[{"invoice_id":"inv_unit","customer_id":"11111111-1111-4111-8111-111111111111"}]}'
        return 0
    fi
    if [ "$fn" = "curl" ] && printf '%s' "$all_args" | grep -Fq '/v1/invoices/inv_unit'; then
        HTTP_RESPONSE_CODE="200"
        HTTP_RESPONSE_BODY='{"id":"inv_unit","customer":"cus_unit_test","payment_intent":"pi_unit_test","charge":"ch_unit_test"}'
        return 0
    fi
    if [ "$fn" = "curl" ] && printf '%s' "$all_args" | grep -Fq '/v1/setup_intents'; then
        HTTP_RESPONSE_CODE="200"
        HTTP_RESPONSE_BODY='{"id":"seti_unit_id","customer":"cus_unit_test","client_secret":"seti_unit_secret"}'
        return 0
    fi
    if [ "$fn" = "admin_call" ] && [ "$method" = "GET" ] && [[ "$path" == /admin/tenants/*/invoices ]]; then
        HTTP_RESPONSE_CODE="200"
        HTTP_RESPONSE_BODY='[{"id":"inv_unit","status":"paid"}]'
        return 0
    fi
    HTTP_RESPONSE_CODE="200"
    HTTP_RESPONSE_BODY='{}'
}

cleanup_resources() { :; }
EOS
}

run_test_shim_guard_case() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' RETURN

    local sweeper_stub="$tmp_dir/privacy_card_sweeper.sh"
    local shim_path="$tmp_dir/live_card_e2e_shim.sh"
    local create_called_file="$tmp_dir/create_called"
    local sweeper_args_file="$tmp_dir/sweeper_args"

    make_sweeper_stub "$sweeper_stub"
    make_shim "$shim_path" "$create_called_file"

    local stdout_file="$tmp_dir/stdout"
    local stderr_file="$tmp_dir/stderr"

    set +e
    LIVE_E2E_TEST_SHIM="$shim_path" \
    LIVE_E2E_SWEEPER_BIN="$sweeper_stub" \
    LIVE_E2E_EVIDENCE_DIR="$tmp_dir/evidence" \
    LIVE_E2E_SWEEPER_ARGS_FILE="$sweeper_args_file" \
    STRIPE_LIVE_CUTOVER=1 \
    STRIPE_SECRET_KEY=sk_live_unit_test_key \
    PRIVACY_API_KEY=privacy_unit_test_key \
    API_URL=http://127.0.0.1:65535 \
    ADMIN_KEY=admin_unit_test_key \
    PK_LIVE=pk_live_unit_test_key \
    LIVE_E2E_STRIPE_CUSTOMER_ID=cus_unit_test \
    BILLING_MONTH=2026-05 \
    /bin/bash "$RUNNER" --env=prod --dry-run >"$stdout_file" 2>"$stderr_file"
    local rc=$?
    set -e

    assert_equals "$rc" "64" "test_shim_guard_rc"
    assert_contains "$(cat "$stderr_file")" "LIVE_E2E_TEST_SHIM requires LIVE_E2E_ALLOW_TEST_SHIM=1" "test_shim_guard_message"
}

assert_capture_redaction() {
    local logs_dir="$1"
    local summary_file="$2"

    local billing_body
    billing_body="$(cat "$logs_dir/billing_trigger.response.json")"
    assert_contains "$billing_body" '"invoice_id":"inv_unit"' "billing_capture_body"
    local first_invoice_capture
    first_invoice_capture="$(ls "$logs_dir"/invoice_poll_*.response.json | head -n1)"
    assert_contains "$(cat "$first_invoice_capture")" '"status":"paid"' "invoice_capture_body"
    assert_contains "$(cat "$logs_dir/privacy_create_card.response.json")" '"token":"[REDACTED]"' "privacy_create_capture_token_redacted"
    assert_contains "$(cat "$logs_dir/privacy_create_card.response.json")" '"account_token":"[REDACTED]"' "privacy_create_capture_account_token_redacted"
    assert_contains "$(cat "$logs_dir/privacy_create_card.response.json")" '"card_program_token":"[REDACTED]"' "privacy_create_capture_program_token_redacted"
    assert_contains "$(cat "$logs_dir/privacy_create_card.response.json")" '"pan":"[REDACTED]"' "privacy_create_capture_pan_redacted"
    assert_contains "$(cat "$logs_dir/privacy_create_card.response.json")" '"cvv":"[REDACTED]"' "privacy_create_capture_cvv_redacted"
    assert_contains "$(cat "$logs_dir/stripe_setup_intent.response.json")" '"client_secret":"[REDACTED]"' "setup_intent_secret_redacted"
    assert_contains "$(cat "$logs_dir/stripe_setup_intent.response.json")" '"id":"[REDACTED]"' "setup_intent_id_redacted"
    assert_contains "$(cat "$logs_dir/stripe_setup_intent.response.json")" '"customer":"[REDACTED]"' "setup_intent_customer_redacted"
    assert_not_contains "$(cat "$logs_dir/stripe_setup_intent.response.json")" 'seti_unit_id' "setup_intent_id_not_raw"
    assert_not_contains "$(cat "$logs_dir/stripe_setup_intent.response.json")" 'cus_unit_test' "setup_intent_customer_not_raw"
    assert_contains "$(cat "$logs_dir/stripe_attach.response.json")" '"pm_id":"[REDACTED]"' "attach_pm_id_redacted"
    assert_not_contains "$(cat "$logs_dir/stripe_invoice_lookup.response.json")" '"payment_intent":"pi_unit_test"' "stripe_invoice_lookup_pi_not_raw"
    assert_not_contains "$(cat "$logs_dir/stripe_invoice_lookup.response.json")" '"charge":"ch_unit_test"' "stripe_invoice_lookup_charge_not_raw"
    assert_contains "$(cat "$logs_dir/stripe_invoice_lookup.response.json")" '"payment_intent":"[REDACTED]"' "stripe_invoice_lookup_pi_redacted"
    assert_contains "$(cat "$logs_dir/stripe_invoice_lookup.response.json")" '"charge":"[REDACTED]"' "stripe_invoice_lookup_charge_redacted"
    assert_not_contains "$(cat "$summary_file")" 'card_tok_unit' "summary_card_token_not_leaked"
    assert_not_contains "$(cat "$summary_file")" 'pm_unit_test' "summary_pm_id_not_leaked"
}

assert_admin_poll_capture_redaction() {
    local poll_capture_path="$1"

    local poll_capture
    poll_capture="$(cat "$poll_capture_path")"
    assert_not_contains "$poll_capture" '"payment_intent_id":"pi_poll_unit"' "invoice_poll_pi_not_raw"
    assert_not_contains "$poll_capture" '"charge_id":"ch_poll_unit"' "invoice_poll_charge_not_raw"
    assert_contains "$poll_capture" '"payment_intent_id":"[REDACTED]"' "invoice_poll_pi_redacted"
    assert_contains "$poll_capture" '"charge_id":"[REDACTED]"' "invoice_poll_charge_redacted"
}

assert_summary_stdout_file_split() {
    local stdout_file="$1"
    local summary_file="$2"

    local stdout_summary file_summary
    stdout_summary="$(cat "$stdout_file")"
    file_summary="$(cat "$summary_file")"
    assert_contains "$file_summary" '"classification":"success"' "full_path_summary_success"
    assert_contains "$file_summary" '"webhook_ok":true' "full_path_summary_webhook_ok"
    assert_contains "$file_summary" '"payment_intent_id":' "summary_has_pi"
    assert_contains "$file_summary" '"charge_id":' "summary_has_charge"
    assert_contains "$file_summary" '"pm_id":"[REDACTED]"' "summary_pm_id_redacted"
    assert_contains "$stdout_summary" '"payment_intent_id":"pi_unit_test"' "stdout_summary_has_raw_pi"
    assert_contains "$stdout_summary" '"charge_id":"ch_unit_test"' "stdout_summary_has_raw_charge"
    assert_contains "$file_summary" '"payment_intent_id":"[REDACTED]"' "file_summary_has_redacted_pi"
    assert_contains "$file_summary" '"charge_id":"[REDACTED]"' "file_summary_has_redacted_charge"
}

run_billing_webhook_artifacts_case() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' RETURN

    local sweeper_stub="$tmp_dir/privacy_card_sweeper.sh"
    local shim_path="$tmp_dir/live_card_e2e_shim.sh"
    local sweeper_args_file="$tmp_dir/sweeper_args"

    make_sweeper_stub "$sweeper_stub"
    make_full_path_shim "$shim_path"

    local stdout_file="$tmp_dir/stdout"
    local stderr_file="$tmp_dir/stderr"

    set +e
    LIVE_E2E_TEST_SHIM="$shim_path" \
    LIVE_E2E_ALLOW_TEST_SHIM=1 \
    LIVE_E2E_SWEEPER_BIN="$sweeper_stub" \
    LIVE_E2E_EVIDENCE_DIR="$tmp_dir/evidence" \
    LIVE_E2E_SWEEPER_ARGS_FILE="$sweeper_args_file" \
    STRIPE_LIVE_CUTOVER=1 \
    STRIPE_SECRET_KEY=sk_live_unit_test_key \
    PRIVACY_API_KEY=privacy_unit_test_key \
    API_URL=http://127.0.0.1:65535 \
    ADMIN_KEY=admin_unit_test_key \
    PK_LIVE=pk_live_unit_test_key \
    LIVE_E2E_STRIPE_CUSTOMER_ID=cus_unit_test \
    BILLING_MONTH=2026-05 \
    /bin/bash "$RUNNER" --env=prod >"$stdout_file" 2>"$stderr_file"
    local rc=$?
    set -e

    if [ "$rc" -ne 0 ]; then
        echo "FAIL: full-path shim run exited non-zero: rc=$rc" >&2
        echo "----- stdout -----" >&2
        cat "$stdout_file" >&2
        echo "----- stderr -----" >&2
        cat "$stderr_file" >&2
        exit 1
    fi

    local run_dir
    run_dir="$(ls -1 "$tmp_dir/evidence" | head -n1)"
    if [ -z "$run_dir" ]; then
        echo "FAIL: expected run-scoped evidence directory" >&2
        exit 1
    fi

    local logs_dir="$tmp_dir/evidence/$run_dir/logs"
    if [ ! -f "$logs_dir/billing_trigger.response.json" ]; then
        echo "FAIL: expected $logs_dir/billing_trigger.response.json" >&2
        exit 1
    fi
    if ! ls "$logs_dir"/invoice_poll_*.response.json >/dev/null 2>&1; then
        echo "FAIL: expected at least one invoice_poll_*.response.json under $logs_dir" >&2
        exit 1
    fi
    if [ ! -f "$logs_dir/privacy_create_card.response.json" ]; then
        echo "FAIL: expected $logs_dir/privacy_create_card.response.json" >&2
        exit 1
    fi
    if [ ! -f "$logs_dir/stripe_setup_intent.response.json" ]; then
        echo "FAIL: expected $logs_dir/stripe_setup_intent.response.json" >&2
        exit 1
    fi
    if [ ! -f "$logs_dir/stripe_attach.response.json" ]; then
        echo "FAIL: expected $logs_dir/stripe_attach.response.json" >&2
        exit 1
    fi

    assert_capture_redaction "$logs_dir" "$tmp_dir/evidence/$run_dir/summary.json"
    assert_summary_stdout_file_split "$stdout_file" "$tmp_dir/evidence/$run_dir/summary.json"
}

make_admin_poll_identifier_shim() {
    local shim_path="$1"
    cat > "$shim_path" <<'EOS'
#!/usr/bin/env bash
check_stripe_key_live() { return 0; }
resolve_stripe_secret_key() { printf 'sk_live_unit_test_key\n'; }

privacy_com_create_card() {
    PRIVACY_CLIENT_BODY='{"account_token":"privacy_account_unit","card_program_token":"privacy_program_unit","token":"card_tok_unit","pan":"4111111111111111","cvv":"123","exp_month":"12","exp_year":"2030","state":"OPEN"}'
    PRIVACY_CLIENT_EXIT_CLASS="ok"
    PRIVACY_CLIENT_HTTP_CODE="200"
    PRIVACY_CLIENT_ERROR_MESSAGE=""
    return 0
}

privacy_com_close_card() {
    PRIVACY_CLIENT_EXIT_CLASS="ok"
    PRIVACY_CLIENT_HTTP_CODE="200"
    PRIVACY_CLIENT_BODY='{}'
    PRIVACY_CLIENT_ERROR_MESSAGE=""
    return 0
}

stripe_curl_user_config() {
    local stripe_key="$1"
    cat <<CFG
user = ":${stripe_key}"
CFG
}

node() {
    printf '{"ok":true,"pm_id":"pm_unit_test"}\n'
}

capture_json_response() {
    HTTP_RESPONSE_EXIT_STATUS=0
    local fn="$1"
    shift
    local method="${1:-}"
    local path="${2:-}"
    local all_args="$*"
    if [ "$fn" = "admin_call" ] && [ "$method" = "POST" ] && [ "$path" = "/admin/billing/run" ]; then
        HTTP_RESPONSE_CODE="200"
        HTTP_RESPONSE_BODY='{"results":[{"invoice_id":"inv_unit","customer_id":"11111111-1111-4111-8111-111111111111"}]}'
        return 0
    fi
    if [ "$fn" = "curl" ] && printf '%s' "$all_args" | grep -Fq '/v1/invoices/inv_unit'; then
        HTTP_RESPONSE_CODE="200"
        HTTP_RESPONSE_BODY='{"id":"inv_unit","customer":"cus_unit_test","payment_intent":"pi_lookup_should_not_persist","charge":"ch_lookup_should_not_persist"}'
        return 0
    fi
    if [ "$fn" = "curl" ] && printf '%s' "$all_args" | grep -Fq '/v1/setup_intents'; then
        HTTP_RESPONSE_CODE="200"
        HTTP_RESPONSE_BODY='{"id":"seti_unit_id","customer":"cus_unit_test","client_secret":"seti_unit_secret"}'
        return 0
    fi
    if [ "$fn" = "admin_call" ] && [ "$method" = "GET" ] && [[ "$path" == /admin/tenants/*/invoices ]]; then
        HTTP_RESPONSE_CODE="200"
        HTTP_RESPONSE_BODY='[{"id":"inv_unit","status":"paid","payment_intent_id":"pi_poll_unit","charge_id":"ch_poll_unit"}]'
        return 0
    fi
    HTTP_RESPONSE_CODE="200"
    HTTP_RESPONSE_BODY='{}'
}

cleanup_resources() { :; }
EOS
}

run_admin_poll_identifier_redaction_case() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' RETURN

    local sweeper_stub="$tmp_dir/privacy_card_sweeper.sh"
    local shim_path="$tmp_dir/live_card_e2e_shim.sh"
    local sweeper_args_file="$tmp_dir/sweeper_args"
    local stdout_file="$tmp_dir/stdout"
    local stderr_file="$tmp_dir/stderr"

    make_sweeper_stub "$sweeper_stub"
    make_admin_poll_identifier_shim "$shim_path"

    set +e
    LIVE_E2E_TEST_SHIM="$shim_path" \
    LIVE_E2E_ALLOW_TEST_SHIM=1 \
    LIVE_E2E_SWEEPER_BIN="$sweeper_stub" \
    LIVE_E2E_EVIDENCE_DIR="$tmp_dir/evidence" \
    LIVE_E2E_SWEEPER_ARGS_FILE="$sweeper_args_file" \
    STRIPE_LIVE_CUTOVER=1 \
    STRIPE_SECRET_KEY=sk_live_unit_test_key \
    PRIVACY_API_KEY=privacy_unit_test_key \
    API_URL=http://127.0.0.1:65535 \
    ADMIN_KEY=admin_unit_test_key \
    PK_LIVE=pk_live_unit_test_key \
    LIVE_E2E_STRIPE_CUSTOMER_ID=cus_unit_test \
    BILLING_MONTH=2026-05 \
    /bin/bash "$RUNNER" --env=prod >"$stdout_file" 2>"$stderr_file"
    local rc=$?
    set -e

    if [ "$rc" -ne 0 ]; then
        echo "FAIL: admin-poll identifier run exited non-zero: rc=$rc" >&2
        cat "$stderr_file" >&2
        exit 1
    fi

    local run_dir
    run_dir="$(ls -1 "$tmp_dir/evidence" | head -n1)"
    if [ -z "$run_dir" ]; then
        echo "FAIL: expected run-scoped evidence directory for admin-poll identifier case" >&2
        exit 1
    fi

    local logs_dir="$tmp_dir/evidence/$run_dir/logs"
    local first_invoice_capture
    first_invoice_capture="$(ls "$logs_dir"/invoice_poll_*.response.json | head -n1)"
    assert_admin_poll_capture_redaction "$first_invoice_capture"
    if [ -f "$logs_dir/stripe_invoice_lookup.response.json" ]; then
        echo "FAIL: admin-poll identifier fast path should not persist fallback stripe_invoice_lookup.response.json" >&2
        exit 1
    fi

    local stdout_summary summary_file
    stdout_summary="$(cat "$stdout_file")"
    summary_file="$tmp_dir/evidence/$run_dir/summary.json"
    assert_contains "$stdout_summary" '"payment_intent_id":"pi_poll_unit"' "admin_poll_stdout_has_runtime_pi"
    assert_contains "$stdout_summary" '"charge_id":"ch_poll_unit"' "admin_poll_stdout_has_runtime_charge"
    assert_contains "$(cat "$summary_file")" '"payment_intent_id":"[REDACTED]"' "admin_poll_file_summary_has_redacted_pi"
    assert_contains "$(cat "$summary_file")" '"charge_id":"[REDACTED]"' "admin_poll_file_summary_has_redacted_charge"
}

make_setup_intent_failure_shim() {
    local shim_path="$1"
    cat > "$shim_path" <<'EOS'
#!/usr/bin/env bash
check_stripe_key_live() { return 0; }
resolve_stripe_secret_key() { printf 'sk_live_unit_test_key\n'; }

privacy_com_create_card() {
    PRIVACY_CLIENT_BODY='{"account_token":"privacy_account_unit","card_program_token":"privacy_program_unit","token":"card_tok_unit","pan":"4111111111111111","cvv":"123","exp_month":"12","exp_year":"2030","state":"OPEN"}'
    PRIVACY_CLIENT_EXIT_CLASS="ok"
    PRIVACY_CLIENT_HTTP_CODE="200"
    PRIVACY_CLIENT_ERROR_MESSAGE=""
    return 0
}

privacy_com_close_card() {
    PRIVACY_CLIENT_EXIT_CLASS="ok"
    PRIVACY_CLIENT_HTTP_CODE="200"
    PRIVACY_CLIENT_BODY='{}'
    PRIVACY_CLIENT_ERROR_MESSAGE=""
    return 0
}

stripe_curl_user_config() {
    local stripe_key="$1"
    cat <<CFG
user = ":${stripe_key}"
CFG
}

capture_json_response() {
    HTTP_RESPONSE_EXIT_STATUS=0
    local fn="$1"
    shift
    local all_args="$*"
    if [ "$fn" = "curl" ] && printf '%s' "$all_args" | grep -Fq '/v1/setup_intents'; then
        HTTP_RESPONSE_CODE="400"
        HTTP_RESPONSE_BODY='{"error":{"message":"No such customer: '\''cus_unit_test'\''","request_log_url":"https://dashboard.stripe.com/acct_unit/workbench/logs?object=req_unit","type":"invalid_request_error"}}'
        return 0
    fi
    HTTP_RESPONSE_CODE="200"
    HTTP_RESPONSE_BODY='{}'
}

cleanup_resources() { :; }
EOS
}

run_setup_intent_failure_redaction_case() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' RETURN

    local sweeper_stub="$tmp_dir/privacy_card_sweeper.sh"
    local shim_path="$tmp_dir/live_card_e2e_shim.sh"
    local sweeper_args_file="$tmp_dir/sweeper_args"
    local stdout_file="$tmp_dir/stdout"
    local stderr_file="$tmp_dir/stderr"

    make_sweeper_stub "$sweeper_stub"
    make_setup_intent_failure_shim "$shim_path"

    set +e
    LIVE_E2E_TEST_SHIM="$shim_path" \
    LIVE_E2E_ALLOW_TEST_SHIM=1 \
    LIVE_E2E_SWEEPER_BIN="$sweeper_stub" \
    LIVE_E2E_EVIDENCE_DIR="$tmp_dir/evidence" \
    LIVE_E2E_SWEEPER_ARGS_FILE="$sweeper_args_file" \
    STRIPE_LIVE_CUTOVER=1 \
    STRIPE_SECRET_KEY=sk_live_unit_test_key \
    PRIVACY_API_KEY=privacy_unit_test_key \
    API_URL=http://127.0.0.1:65535 \
    ADMIN_KEY=admin_unit_test_key \
    PK_LIVE=pk_live_unit_test_key \
    LIVE_E2E_STRIPE_CUSTOMER_ID=cus_unit_test \
    BILLING_MONTH=2026-05 \
    /bin/bash "$RUNNER" --env=prod >"$stdout_file" 2>"$stderr_file"
    local rc=$?
    set -e

    if [ "$rc" -eq 0 ]; then
        echo "FAIL: setup-intent failure case expected non-zero exit" >&2
        exit 1
    fi
    assert_contains "$(cat "$stderr_file")" 'classification=stripe_setup_intent_http_error' "setup_intent_failure_classification"

    local run_dir
    run_dir="$(ls -1 "$tmp_dir/evidence" | head -n1)"
    if [ -z "$run_dir" ]; then
        echo "FAIL: expected run-scoped evidence directory for setup-intent failure case" >&2
        exit 1
    fi

    local capture_path="$tmp_dir/evidence/$run_dir/logs/stripe_setup_intent.response.json"
    local summary_path="$tmp_dir/evidence/$run_dir/summary.json"
    local capture_body
    capture_body="$(cat "$capture_path")"
    assert_contains "$(cat "$summary_path")" '"classification":"stripe_setup_intent_http_error"' "setup_intent_failure_summary_classification"
    assert_not_contains "$(cat "$summary_path")" '"classification":"success"' "setup_intent_failure_summary_not_success"
    assert_not_contains "$capture_body" 'cus_unit_test' "setup_intent_failure_customer_not_raw"
    assert_not_contains "$capture_body" 'acct_unit' "setup_intent_failure_account_not_raw"
    assert_not_contains "$capture_body" 'req_unit' "setup_intent_failure_request_not_raw"
    assert_contains "$capture_body" '"request_log_url":"[REDACTED]"' "setup_intent_failure_request_url_redacted"
    assert_contains "$capture_body" 'No such customer: '\''[REDACTED]'\''' "setup_intent_failure_message_redacted"
}

make_attach_parse_failure_shim() {
    local shim_path="$1"
    cat > "$shim_path" <<'EOS'
#!/usr/bin/env bash
check_stripe_key_live() { return 0; }
resolve_stripe_secret_key() { printf 'sk_live_unit_test_key\n'; }

privacy_com_create_card() {
    PRIVACY_CLIENT_BODY='{"account_token":"privacy_account_unit","card_program_token":"privacy_program_unit","token":"card_tok_unit","pan":"4111111111111111","cvv":"123","exp_month":"12","exp_year":"2030","state":"OPEN"}'
    PRIVACY_CLIENT_EXIT_CLASS="ok"
    PRIVACY_CLIENT_HTTP_CODE="200"
    PRIVACY_CLIENT_ERROR_MESSAGE=""
    return 0
}

privacy_com_close_card() {
    PRIVACY_CLIENT_EXIT_CLASS="ok"
    PRIVACY_CLIENT_HTTP_CODE="200"
    PRIVACY_CLIENT_BODY='{}'
    PRIVACY_CLIENT_ERROR_MESSAGE=""
    return 0
}

stripe_curl_user_config() {
    local stripe_key="$1"
    cat <<CFG
user = ":${stripe_key}"
CFG
}

capture_json_response() {
    HTTP_RESPONSE_EXIT_STATUS=0
    local fn="$1"
    shift
    local all_args="$*"
    if [ "$fn" = "curl" ] && printf '%s' "$all_args" | grep -Fq '/v1/setup_intents'; then
        HTTP_RESPONSE_CODE="200"
        HTTP_RESPONSE_BODY='{"id":"seti_unit_id","customer":"cus_unit_test","client_secret":"seti_unit_secret"}'
        return 0
    fi
    HTTP_RESPONSE_CODE="200"
    HTTP_RESPONSE_BODY='{}'
}

node() {
    printf 'no success or error message detected\n'
    return 0
}

cleanup_resources() { :; }
EOS
}

run_attach_parse_failure_classification_case() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' RETURN

    local sweeper_stub="$tmp_dir/privacy_card_sweeper.sh"
    local shim_path="$tmp_dir/live_card_e2e_shim.sh"
    local sweeper_args_file="$tmp_dir/sweeper_args"
    local stdout_file="$tmp_dir/stdout"
    local stderr_file="$tmp_dir/stderr"

    make_sweeper_stub "$sweeper_stub"
    make_attach_parse_failure_shim "$shim_path"

    set +e
    LIVE_E2E_TEST_SHIM="$shim_path" \
    LIVE_E2E_ALLOW_TEST_SHIM=1 \
    LIVE_E2E_SWEEPER_BIN="$sweeper_stub" \
    LIVE_E2E_EVIDENCE_DIR="$tmp_dir/evidence" \
    LIVE_E2E_SWEEPER_ARGS_FILE="$sweeper_args_file" \
    STRIPE_LIVE_CUTOVER=1 \
    STRIPE_SECRET_KEY=sk_live_unit_test_key \
    PRIVACY_API_KEY=privacy_unit_test_key \
    API_URL=http://127.0.0.1:65535 \
    ADMIN_KEY=admin_unit_test_key \
    PK_LIVE=pk_live_unit_test_key \
    LIVE_E2E_STRIPE_CUSTOMER_ID=cus_unit_test \
    BILLING_MONTH=2026-05 \
    /bin/bash "$RUNNER" --env=prod >"$stdout_file" 2>"$stderr_file"
    local rc=$?
    set -e

    if [ "$rc" -eq 0 ]; then
        echo "FAIL: attach-parse failure case expected non-zero exit" >&2
        exit 1
    fi
    assert_contains "$(cat "$stderr_file")" 'classification=stripe_attach_failed' "attach_parse_failure_classification"
    assert_contains "$(cat "$stderr_file")" 'no success or error message detected' "attach_parse_failure_message"

    local run_dir
    run_dir="$(ls -1 "$tmp_dir/evidence" | head -n1)"
    if [ -z "$run_dir" ]; then
        echo "FAIL: expected run-scoped evidence directory for attach-parse failure case" >&2
        exit 1
    fi

    local summary_path="$tmp_dir/evidence/$run_dir/summary.json"
    assert_contains "$(cat "$summary_path")" '"classification":"stripe_attach_failed"' "attach_parse_failure_summary_classification"
    assert_not_contains "$(cat "$summary_path")" '"classification":"success"' "attach_parse_failure_summary_not_success"
}

make_multi_invoice_selection_shim() {
    local shim_path="$1"
    cat > "$shim_path" <<'EOS'
#!/usr/bin/env bash
check_stripe_key_live() { return 0; }
resolve_stripe_secret_key() { printf 'sk_live_unit_test_key\n'; }

privacy_com_create_card() {
    PRIVACY_CLIENT_BODY='{"account_token":"privacy_account_unit","card_program_token":"privacy_program_unit","token":"card_tok_unit","pan":"4111111111111111","cvv":"123","exp_month":"12","exp_year":"2030","state":"OPEN"}'
    PRIVACY_CLIENT_EXIT_CLASS="ok"
    PRIVACY_CLIENT_HTTP_CODE="200"
    PRIVACY_CLIENT_ERROR_MESSAGE=""
    return 0
}

privacy_com_close_card() {
    PRIVACY_CLIENT_EXIT_CLASS="ok"
    PRIVACY_CLIENT_HTTP_CODE="200"
    PRIVACY_CLIENT_BODY='{}'
    PRIVACY_CLIENT_ERROR_MESSAGE=""
    return 0
}

stripe_curl_user_config() {
    local stripe_key="$1"
    cat <<CFG
user = ":${stripe_key}"
CFG
}

node() {
    printf '{"ok":true,"pm_id":"pm_unit_test"}\n'
}

capture_json_response() {
    HTTP_RESPONSE_EXIT_STATUS=0
    local fn="$1"
    shift
    local method="${1:-}"
    local path="${2:-}"
    local all_args="$*"
    if [ "$fn" = "admin_call" ] && [ "$method" = "POST" ] && [ "$path" = "/admin/billing/run" ]; then
        HTTP_RESPONSE_CODE="200"
        HTTP_RESPONSE_BODY='{"results":[{"invoice_id":"inv_other","customer_id":"00000000-0000-4000-8000-000000000001"},{"invoice_id":"inv_target","customer_id":"00000000-0000-4000-8000-000000000002"}]}'
        return 0
    fi
    if [ "$fn" = "curl" ] && printf '%s' "$all_args" | grep -Fq '/v1/setup_intents'; then
        HTTP_RESPONSE_CODE="200"
        HTTP_RESPONSE_BODY='{"id":"seti_unit_id","customer":"cus_target","client_secret":"seti_unit_secret"}'
        return 0
    fi
    if [ "$fn" = "curl" ] && printf '%s' "$all_args" | grep -Fq '/v1/invoices/inv_other'; then
        HTTP_RESPONSE_CODE="200"
        HTTP_RESPONSE_BODY='{"id":"inv_other","customer":"cus_other","payment_intent":"pi_other_should_not_be_used","charge":"ch_other_should_not_be_used"}'
        return 0
    fi
    if [ "$fn" = "curl" ] && printf '%s' "$all_args" | grep -Fq '/v1/invoices/inv_target'; then
        HTTP_RESPONSE_CODE="200"
        HTTP_RESPONSE_BODY='{"id":"inv_target","customer":"cus_target","payment_intent":"pi_target_should_not_be_needed","charge":"ch_target_should_not_be_needed"}'
        return 0
    fi
    if [ "$fn" = "admin_call" ] && [ "$method" = "GET" ] && [ "$path" = "/admin/tenants/00000000-0000-4000-8000-000000000001/invoices" ]; then
        HTTP_RESPONSE_CODE="200"
        HTTP_RESPONSE_BODY='[{"id":"inv_other","status":"paid"}]'
        return 0
    fi
    if [ "$fn" = "admin_call" ] && [ "$method" = "GET" ] && [ "$path" = "/admin/tenants/00000000-0000-4000-8000-000000000002/invoices" ]; then
        HTTP_RESPONSE_CODE="200"
        HTTP_RESPONSE_BODY='[{"id":"inv_target","status":"paid"}]'
        return 0
    fi
    HTTP_RESPONSE_CODE="200"
    HTTP_RESPONSE_BODY='{}'
}

cleanup_resources() { :; }
EOS
}

run_multi_invoice_lane_selection_case() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' RETURN

    local sweeper_stub="$tmp_dir/privacy_card_sweeper.sh"
    local shim_path="$tmp_dir/live_card_e2e_shim.sh"
    local sweeper_args_file="$tmp_dir/sweeper_args"
    local stdout_file="$tmp_dir/stdout"
    local stderr_file="$tmp_dir/stderr"

    make_sweeper_stub "$sweeper_stub"
    make_multi_invoice_selection_shim "$shim_path"

    set +e
    LIVE_E2E_TEST_SHIM="$shim_path" \
    LIVE_E2E_ALLOW_TEST_SHIM=1 \
    LIVE_E2E_SWEEPER_BIN="$sweeper_stub" \
    LIVE_E2E_EVIDENCE_DIR="$tmp_dir/evidence" \
    LIVE_E2E_SWEEPER_ARGS_FILE="$sweeper_args_file" \
    STRIPE_LIVE_CUTOVER=1 \
    STRIPE_SECRET_KEY=sk_live_unit_test_key \
    PRIVACY_API_KEY=privacy_unit_test_key \
    API_URL=http://127.0.0.1:65535 \
    ADMIN_KEY=admin_unit_test_key \
    PK_LIVE=pk_live_unit_test_key \
    LIVE_E2E_STRIPE_CUSTOMER_ID=cus_target \
    BILLING_MONTH=2026-05 \
    /bin/bash "$RUNNER" --env=prod >"$stdout_file" 2>"$stderr_file"
    local rc=$?
    set -e

    if [ "$rc" -ne 0 ]; then
        echo "FAIL: multi-invoice lane-selection run exited non-zero: rc=$rc" >&2
        cat "$stderr_file" >&2
        exit 1
    fi

    local output
    output="$(cat "$stdout_file")"
    assert_contains "$output" '"payment_intent_id":"pi_target_should_not_be_needed"' "multi_invoice_stdout_pi_uses_target_invoice"
    assert_contains "$output" '"charge_id":"ch_target_should_not_be_needed"' "multi_invoice_stdout_charge_uses_target_invoice"
    assert_not_contains "$output" '"payment_intent_id":"pi_other_should_not_be_used"' "multi_invoice_stdout_pi_not_other_invoice"
    assert_not_contains "$output" '"charge_id":"ch_other_should_not_be_used"' "multi_invoice_stdout_charge_not_other_invoice"
}

run_success_dry_run_case
run_bad_prefix_case
run_bad_env_value_case
run_default_sweeper_path_case
run_missing_env_summary_case
run_test_shim_guard_case
run_billing_webhook_artifacts_case
run_admin_poll_identifier_redaction_case
run_setup_intent_failure_redaction_case
run_attach_parse_failure_classification_case
run_multi_invoice_lane_selection_case

echo "PASS: live_card_e2e_test dry-run smoke tests succeeded"
