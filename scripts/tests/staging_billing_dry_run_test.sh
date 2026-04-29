#!/usr/bin/env bash
# Tests for scripts/staging_billing_dry_run.sh.
#
# This suite locks the staging billing dry-run safety contract before we add the
# script itself. The goal is to keep the runner small: validate configuration,
# classify known blockers clearly, and avoid mutating or external behavior in
# `--check` mode.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DRY_RUN_SCRIPT="$REPO_ROOT/scripts/staging_billing_dry_run.sh"
RUNBOOK_FILE="$REPO_ROOT/docs/runbooks/staging_billing_dry_run.md"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

RUN_STDOUT=""
RUN_EXIT_CODE=0
TEST_TMP_DIR=""

cleanup_test_tmp_dir() {
    if [ -n "${TEST_TMP_DIR:-}" ] && [ -d "$TEST_TMP_DIR" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap cleanup_test_tmp_dir EXIT

baseline_staging_env() {
    cat <<'EOF'
STAGING_API_URL=https://staging-api.example.test
STAGING_STRIPE_WEBHOOK_URL=https://staging-api.example.test/webhooks/stripe
STRIPE_SECRET_KEY=sk_test_valid_for_preflight
STRIPE_WEBHOOK_SECRET=whsec_valid_for_preflight
ADMIN_KEY=staging-admin-key
ENVIRONMENT=staging
EOF
}

make_test_tmp_dir() {
    cleanup_test_tmp_dir
    TEST_TMP_DIR="$(mktemp -d)"
    mkdir -p "$TEST_TMP_DIR/bin"
}

write_mock_curl() {
    local body="$1"
    cat > "$TEST_TMP_DIR/bin/curl" <<MOCK
#!/usr/bin/env bash
$body
MOCK
    chmod +x "$TEST_TMP_DIR/bin/curl"
}

run_dry_run_script() {
    local args=()
    local env_args=()

    while IFS= read -r line; do
        [ -n "$line" ] && env_args+=("$line")
    done < <(baseline_staging_env)

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --check|--run)
                args+=("$1")
                shift
                ;;
            --env-file)
                args+=("$1" "$2")
                shift 2
                ;;
            --env-file=*)
                args+=("$1")
                shift
                ;;
            *)
                env_args+=("$1")
                shift
                ;;
        esac
    done

    env_args+=("PATH=$TEST_TMP_DIR/bin:/usr/bin:/bin:/usr/local/bin")
    env_args+=("HOME=$TEST_TMP_DIR")
    env_args+=("TMPDIR=$TEST_TMP_DIR")

    RUN_EXIT_CODE=0
    RUN_STDOUT="$(env -i "${env_args[@]}" bash "$DRY_RUN_SCRIPT" "${args[@]}" 2>&1)" || RUN_EXIT_CODE=$?
}

json_field() {
    python3 - "$1" "$2" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
field = sys.argv[2]
value = data.get(field, "")
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
else:
    print(str(value))
PY
}

assert_json_string_field() {
    local payload="$1" field_name="$2" expected="$3" msg="$4"
    local actual
    actual="$(json_field "$payload" "$field_name")"
    assert_eq "$actual" "$expected" "$msg"
}

read_staging_billing_runbook() {
    cat "$RUNBOOK_FILE"
}

read_runbook_section_by_heading() {
    local heading="$1"
    awk -v heading="$heading" '
        $0 == "## " heading { in_section = 1; print; next }
        in_section && /^## / { exit }
        in_section { print }
    ' "$RUNBOOK_FILE"
}

read_runbook_email_evidence_contract_section() {
    read_runbook_section_by_heading "Email Evidence Contract"
}

test_missing_runtime_stripe_secret_key_fails_clearly() {
    make_test_tmp_dir
    write_mock_curl 'exit 99'
    run_dry_run_script --check "STRIPE_SECRET_KEY="

    assert_eq "$RUN_EXIT_CODE" "1" "missing Stripe runtime key should fail"
    assert_valid_json "$RUN_STDOUT" "missing Stripe runtime key output should be valid JSON"
    assert_json_bool_field "$RUN_STDOUT" "passed" "false" "missing Stripe runtime key should report passed=false"
    assert_contains "$RUN_STDOUT" "STRIPE_SECRET_KEY" "missing Stripe runtime key output should name the env var"
    assert_contains "$RUN_STDOUT" "stripe_secret_key_missing" "missing Stripe runtime key output should classify the failure"
}

test_live_mode_looking_key_is_rejected() {
    make_test_tmp_dir
    write_mock_curl 'exit 99'
    run_dry_run_script --check "STRIPE_SECRET_KEY=sk_live_not_allowed"

    assert_eq "$RUN_EXIT_CODE" "1" "live-looking Stripe key should fail"
    assert_valid_json "$RUN_STDOUT" "live-looking Stripe key output should be valid JSON"
    assert_contains "$RUN_STDOUT" "sk_live_" "live-looking Stripe key output should explain the rejected prefix"
    assert_contains "$RUN_STDOUT" "stripe_live_key_rejected" "live-looking Stripe key output should classify the failure"
}

test_restricted_test_mode_key_is_accepted() {
    make_test_tmp_dir
    write_mock_curl 'exit 99'
    run_dry_run_script --check "STRIPE_SECRET_KEY=rk_test_not_allowed_yet"

    assert_eq "$RUN_EXIT_CODE" "0" "restricted test-mode Stripe key should pass dry-run runtime validation"
    assert_valid_json "$RUN_STDOUT" "restricted test-mode Stripe key output should be valid JSON"
    assert_json_bool_field "$RUN_STDOUT" "passed" "true" "restricted test-mode Stripe key should report passed=true"
}

test_alias_only_runtime_key_is_rejected_for_staging_contract() {
    make_test_tmp_dir
    write_mock_curl 'exit 99'
    run_dry_run_script --check "STRIPE_SECRET_KEY=" "STRIPE_TEST_SECRET_KEY=sk_test_alias_only"

    assert_eq "$RUN_EXIT_CODE" "1" "alias-only Stripe key should fail the staging runtime contract"
    assert_valid_json "$RUN_STDOUT" "alias-only Stripe key output should be valid JSON"
    assert_contains "$RUN_STDOUT" "STRIPE_SECRET_KEY" "alias-only Stripe key output should name the canonical runtime variable"
    assert_contains "$RUN_STDOUT" "stripe_secret_key_missing" "alias-only Stripe key should keep the missing-canonical classification"
}

test_restricted_live_mode_key_is_rejected() {
    make_test_tmp_dir
    write_mock_curl 'exit 99'
    run_dry_run_script --check "STRIPE_SECRET_KEY=rk_live_not_allowed"

    assert_eq "$RUN_EXIT_CODE" "1" "restricted live Stripe key should fail"
    assert_valid_json "$RUN_STDOUT" "restricted live Stripe key output should be valid JSON"
    assert_contains "$RUN_STDOUT" "rk_live_" "restricted live key output should explain the rejected prefix"
    assert_contains "$RUN_STDOUT" "stripe_live_key_rejected" "restricted live key output should classify the failure"
}

test_missing_operator_auth_path_fails_clearly() {
    make_test_tmp_dir
    write_mock_curl 'exit 99'
    run_dry_run_script --check "ADMIN_KEY=" "DATABASE_URL=" "INTEGRATION_DB_URL="

    assert_eq "$RUN_EXIT_CODE" "1" "missing operator auth path should fail"
    assert_valid_json "$RUN_STDOUT" "missing operator auth path output should be valid JSON"
    assert_contains "$RUN_STDOUT" "ADMIN_KEY or DATABASE_URL / INTEGRATION_DB_URL" "missing operator auth path output should explain the accepted inspection paths"
    assert_contains "$RUN_STDOUT" "operator_auth_missing" "missing operator auth path should classify the failure"
}

test_missing_webhook_secret_fails_clearly() {
    make_test_tmp_dir
    write_mock_curl 'exit 99'
    run_dry_run_script --check "STRIPE_WEBHOOK_SECRET="

    assert_eq "$RUN_EXIT_CODE" "1" "missing webhook secret should fail"
    assert_valid_json "$RUN_STDOUT" "missing webhook secret output should be valid JSON"
    assert_contains "$RUN_STDOUT" "STRIPE_WEBHOOK_SECRET" "missing webhook secret output should name the env var"
    assert_contains "$RUN_STDOUT" "stripe_webhook_secret_missing" "missing webhook secret output should classify the failure"
}

test_missing_staging_api_url_fails_clearly() {
    make_test_tmp_dir
    write_mock_curl 'exit 99'
    run_dry_run_script --check "STAGING_API_URL="

    assert_eq "$RUN_EXIT_CODE" "1" "missing staging API URL should fail"
    assert_valid_json "$RUN_STDOUT" "missing staging API URL output should be valid JSON"
    assert_contains "$RUN_STDOUT" "STAGING_API_URL" "missing staging API URL output should name the env var"
    assert_contains "$RUN_STDOUT" "staging_api_url_missing" "missing staging API URL output should classify the failure"
}

test_missing_public_webhook_url_is_cloudflare_dns_blocker() {
    make_test_tmp_dir
    write_mock_curl 'exit 99'
    run_dry_run_script --check "STAGING_STRIPE_WEBHOOK_URL="

    assert_eq "$RUN_EXIT_CODE" "1" "missing public webhook URL should fail"
    assert_valid_json "$RUN_STDOUT" "missing public webhook URL output should be valid JSON"
    assert_contains "$RUN_STDOUT" "STAGING_STRIPE_WEBHOOK_URL" "missing public webhook URL output should name the env var"
    assert_contains "$RUN_STDOUT" "dns_or_cloudflare_blocked" "missing public webhook URL should map to DNS/Cloudflare blocker classification"
}

test_non_https_public_webhook_url_is_cloudflare_dns_blocker() {
    make_test_tmp_dir
    write_mock_curl 'exit 99'
    run_dry_run_script --check "STAGING_STRIPE_WEBHOOK_URL=http://staging-api.example.test/webhooks/stripe"

    assert_eq "$RUN_EXIT_CODE" "1" "non-HTTPS public webhook URL should fail"
    assert_valid_json "$RUN_STDOUT" "non-HTTPS public webhook URL output should be valid JSON"
    assert_contains "$RUN_STDOUT" "https://" "non-HTTPS public webhook URL output should explain the HTTPS requirement"
    assert_contains "$RUN_STDOUT" "dns_or_cloudflare_blocked" "non-HTTPS public webhook URL should map to DNS/Cloudflare blocker classification"
}

test_explicit_missing_env_file_fails_as_machine_readable_error() {
    make_test_tmp_dir
    write_mock_curl 'exit 99'
    run_dry_run_script --check --env-file "$TEST_TMP_DIR/missing.env"

    assert_eq "$RUN_EXIT_CODE" "1" "missing explicit env file should fail"
    assert_valid_json "$RUN_STDOUT" "missing explicit env file output should be valid JSON"
    assert_contains "$RUN_STDOUT" "Explicit env file not found" "missing explicit env file output should explain the boundary failure"
    assert_contains "$RUN_STDOUT" "env_file_missing" "missing explicit env file should use env_file_missing classification"
}

test_explicit_invalid_env_file_fails_as_machine_readable_error() {
    make_test_tmp_dir
    write_mock_curl 'exit 99'
    cat > "$TEST_TMP_DIR/invalid.env" <<'EOF'
BAD LINE
EOF
    run_dry_run_script --check --env-file "$TEST_TMP_DIR/invalid.env"

    assert_eq "$RUN_EXIT_CODE" "1" "invalid explicit env file should fail"
    assert_valid_json "$RUN_STDOUT" "invalid explicit env file output should be valid JSON"
    assert_contains "$RUN_STDOUT" "Unsupported syntax" "invalid explicit env file output should surface parser context"
    assert_contains "$RUN_STDOUT" "env_file_invalid" "invalid explicit env file should use env_file_invalid classification"
}

test_check_mode_prints_plan_without_external_calls() {
    make_test_tmp_dir
    local curl_log="$TEST_TMP_DIR/curl_calls.log"
    write_mock_curl "echo curl >> \"$curl_log\"; exit 88"
    run_dry_run_script --check
    local curl_call_count="0"

    if [ -f "$curl_log" ]; then
        curl_call_count="$(wc -l < "$curl_log" | tr -d ' ')"
    fi

    assert_eq "$RUN_EXIT_CODE" "0" "check mode should pass with valid staging inputs"
    assert_valid_json "$RUN_STDOUT" "check mode output should be valid JSON"
    assert_json_bool_field "$RUN_STDOUT" "passed" "true" "check mode should report passed=true"
    assert_json_string_field "$RUN_STDOUT" "mode" "check" "check mode output should report mode=check"
    assert_contains "$RUN_STDOUT" "metering" "check mode output should describe the staged billing steps"
    assert_contains "$RUN_STDOUT" "aggregation" "check mode output should describe the staged billing steps"
    assert_contains "$RUN_STDOUT" "invoice" "check mode output should describe the staged billing steps"
    assert_eq "$curl_call_count" "0" "check mode should not call external APIs"
}

test_runbook_email_evidence_contract_matches_runtime_owners() {
    local email_contract_section
    email_contract_section="$(read_runbook_email_evidence_contract_section)"

    assert_contains "$email_contract_section" "## Email Evidence Contract" \
        "runbook should retain the Email Evidence Contract heading"
    assert_contains "$email_contract_section" "infra/api/tests/invoice_email_test.rs" \
        "runbook should cite invoice email tests as code-level attempt evidence"
    assert_contains "$email_contract_section" "infra/api/src/startup.rs" \
        "runbook should cite startup.rs for runtime selection ownership"
    assert_contains "$email_contract_section" "MailpitEmailService" \
        "runbook should document Mailpit runtime service selection semantics"
    assert_contains "$email_contract_section" "SesEmailService" \
        "runbook should document SES runtime service selection semantics"
    assert_contains "$email_contract_section" "NoopEmailService" \
        "runbook should document local/dev noop fallback in startup runtime selection"
    assert_contains "$email_contract_section" "infra/api/src/invoicing/stripe_sync.rs" \
        "runbook should point to stripe_sync.rs for best-effort invoice-ready send semantics"
    assert_contains "$email_contract_section" "send_invoice_ready_email_best_effort" \
        "runbook should lock the best-effort invoice-ready send helper identifier"
    assert_contains "$email_contract_section" "infra/api/src/services/email.rs" \
        "runbook should still point to services/email.rs for Mailpit sink behavior"
    assert_contains "$email_contract_section" "scripts/lib/staging_billing_rehearsal_email_evidence.sh" \
        "runbook should cite runtime rehearsal email evidence owner script"
    assert_contains "$email_contract_section" "invoice_email_evidence_delegated" \
        "runbook should lock delegated staging classification for missing-Mailpit staging rehearsal runs"
    assert_contains "$email_contract_section" "scripts/launch/ses_deliverability_evidence.sh" \
        "runbook should route live SES delivery proof to the SES deliverability owner"
    assert_contains "$email_contract_section" "docs/runbooks/email-production.md" \
        "runbook should route SES inbox-delivery closure to the SES production runbook owner"
    assert_contains "$email_contract_section" "owned by the SES deliverability wrapper" \
        "runbook should explicitly describe delegated staging-to-SES ownership"
    assert_contains "$email_contract_section" "does not claim inbox-delivery closure when Mailpit is absent" \
        "runbook should keep missing-Mailpit staging classification as delegated evidence, not inbox closure"
    assert_not_contains "$email_contract_section" 'SES invoice-ready sends are fire-and-forget in `infra/api/src/services/email.rs`.' \
        "runbook should not attribute best-effort fire-and-forget behavior to services/email.rs"
    assert_not_contains "$email_contract_section" "invoice_email_evidence_unsupported" \
        "runbook should no longer describe missing-Mailpit staging as a generic unsupported runtime classification"
}

echo "=== staging_billing_dry_run.sh tests ==="
test_missing_runtime_stripe_secret_key_fails_clearly
test_live_mode_looking_key_is_rejected
test_restricted_test_mode_key_is_accepted
test_alias_only_runtime_key_is_rejected_for_staging_contract
test_restricted_live_mode_key_is_rejected
test_missing_webhook_secret_fails_clearly
test_missing_staging_api_url_fails_clearly
test_missing_public_webhook_url_is_cloudflare_dns_blocker
test_non_https_public_webhook_url_is_cloudflare_dns_blocker
test_explicit_missing_env_file_fails_as_machine_readable_error
test_explicit_invalid_env_file_fails_as_machine_readable_error
test_missing_operator_auth_path_fails_clearly
test_check_mode_prints_plan_without_external_calls
test_runbook_email_evidence_contract_matches_runtime_owners
run_test_summary
