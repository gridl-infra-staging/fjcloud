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
    PRIVACY_CLIENT_BODY='{"token":"card_tok_unit","pan":"4111111111111111","cvv":"123","exp_month":"12","exp_year":"2030","state":"OPEN"}'
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
    if [ "$fn" = "admin_call" ] && [ "$method" = "POST" ] && [ "$path" = "/admin/billing/run" ]; then
        HTTP_RESPONSE_CODE="200"
        HTTP_RESPONSE_BODY='{"results":[{"invoice_id":"inv_unit","customer_id":"cus_unit"}]}'
        return 0
    fi
    if [ "$fn" = "curl" ] && [ "$method" = "-sS" ]; then
        HTTP_RESPONSE_CODE="200"
        HTTP_RESPONSE_BODY='{"client_secret":"seti_unit_secret"}'
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

    local billing_body
    billing_body="$(cat "$logs_dir/billing_trigger.response.json")"
    assert_contains "$billing_body" '"invoice_id":"inv_unit"' "billing_capture_body"
    local first_invoice_capture
    first_invoice_capture="$(ls "$logs_dir"/invoice_poll_*.response.json | head -n1)"
    assert_contains "$(cat "$first_invoice_capture")" '"status":"paid"' "invoice_capture_body"
    assert_contains "$(cat "$logs_dir/privacy_create_card.response.json")" '"token":"[REDACTED]"' "privacy_create_capture_token_redacted"
    assert_contains "$(cat "$logs_dir/privacy_create_card.response.json")" '"pan":"[REDACTED]"' "privacy_create_capture_pan_redacted"
    assert_contains "$(cat "$logs_dir/privacy_create_card.response.json")" '"cvv":"[REDACTED]"' "privacy_create_capture_cvv_redacted"
    assert_contains "$(cat "$logs_dir/stripe_setup_intent.response.json")" '"client_secret":"[REDACTED]"' "setup_intent_secret_redacted"
    assert_contains "$(cat "$logs_dir/stripe_attach.response.json")" '"pm_id":"[REDACTED]"' "attach_pm_id_redacted"

    local summary_file="$tmp_dir/evidence/$run_dir/summary.json"
    assert_contains "$(cat "$summary_file")" '"classification":"success"' "full_path_summary_success"
    assert_contains "$(cat "$summary_file")" '"webhook_ok":true' "full_path_summary_webhook_ok"
    assert_contains "$(cat "$summary_file")" '"pm_id":"[REDACTED]"' "summary_pm_id_redacted"
    assert_not_contains "$(cat "$summary_file")" 'card_tok_unit' "summary_card_token_not_leaked"
    assert_not_contains "$(cat "$summary_file")" 'pm_unit_test' "summary_pm_id_not_leaked"
}

run_success_dry_run_case
run_bad_prefix_case
run_bad_env_value_case
run_default_sweeper_path_case
run_missing_env_summary_case
run_test_shim_guard_case
run_billing_webhook_artifacts_case

echo "PASS: live_card_e2e_test dry-run smoke tests succeeded"
