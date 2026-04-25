#!/usr/bin/env bash
# Tests for scripts/validate_ses_readiness.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/tests/lib/assertions.sh"

PASS_COUNT=0
FAIL_COUNT=0

fail() {
    echo "FAIL: $*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

json_step_field() {
    local json="$1" step_name="$2" field_name="$3"
    python3 - "$json" "$step_name" "$field_name" <<'PY' 2>/dev/null || echo ""
import json
import sys
payload = json.loads(sys.argv[1])
step_name = sys.argv[2]
field_name = sys.argv[3]
for step in payload.get("steps", []):
    if step.get("name") == step_name:
        value = step.get(field_name, "")
        if isinstance(value, bool):
            print("true" if value else "false")
        else:
            print(str(value))
        break
else:
    print("")
PY
}

write_mock_aws() {
    local mock_path="$1"
    cat > "$mock_path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

echo "$*" >> "${SES_READINESS_AWS_CALL_LOG:?missing call log path}"
mode="${SES_READINESS_MOCK_MODE:-ready}"

if [[ "${1:-}" != "sesv2" ]]; then
    echo "unexpected aws service call: $*" >&2
    exit 91
fi

command="${2:-}"
if [[ "$command" == "get-account" ]]; then
    case "$mode" in
        ready|default_region|email_identity_ready|email_inherits_domain_ready)
            cat <<'JSON'
{"SendingEnabled":true,"ProductionAccessEnabled":true,"AccountId":"123456789012"}
JSON
            ;;
        sandbox)
            cat <<'JSON'
{"SendingEnabled":true,"ProductionAccessEnabled":false,"AccountId":"123456789012"}
JSON
            ;;
        disabled_sending)
            cat <<'JSON'
{"SendingEnabled":false,"ProductionAccessEnabled":true,"AccountId":"123456789012"}
JSON
            ;;
        get_account_error)
            echo "simulated get-account failure" >&2
            exit 1
            ;;
        identity_fail|identity_error)
            cat <<'JSON'
{"SendingEnabled":true,"ProductionAccessEnabled":true,"AccountId":"123456789012"}
JSON
            ;;
        *)
            echo "unexpected mock mode for get-account: $mode" >&2
            exit 92
            ;;
    esac
    exit 0
fi

if [[ "$command" == "get-email-identity" ]]; then
    case "$mode" in
        ready|default_region|sandbox|disabled_sending)
            cat <<'JSON'
{"IdentityType":"DOMAIN","VerificationStatus":"SUCCESS","DkimAttributes":{"Status":"SUCCESS"}}
JSON
            ;;
        email_identity_ready)
            cat <<'JSON'
{"IdentityType":"EMAIL_ADDRESS","VerificationStatus":"SUCCESS"}
JSON
            ;;
        email_inherits_domain_ready)
            if printf '%s\n' "$*" | grep -q -- '--email-identity=system@flapjack.foo'; then
                echo "simulated missing explicit email identity" >&2
                exit 1
            fi
            if printf '%s\n' "$*" | grep -q -- '--email-identity=flapjack.foo'; then
                cat <<'JSON'
{"IdentityType":"DOMAIN","VerificationStatus":"SUCCESS","DkimAttributes":{"Status":"SUCCESS"}}
JSON
                exit 0
            fi
            echo "unexpected inherited-domain identity lookup: $*" >&2
            exit 95
            ;;
        identity_fail)
            cat <<'JSON'
{"IdentityType":"DOMAIN","VerificationStatus":"PENDING","DkimAttributes":{"Status":"FAILED"}}
JSON
            ;;
        identity_error)
            echo "simulated get-email-identity failure" >&2
            exit 1
            ;;
        *)
            echo "unexpected mock mode for get-email-identity: $mode" >&2
            exit 93
            ;;
    esac
    exit 0
fi

echo "unexpected sesv2 command: $*" >&2
exit 94
MOCK
    chmod +x "$mock_path"
}

new_mock_aws_dir() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    write_mock_aws "$mock_dir/aws"
    echo "$mock_dir"
}

init_call_log() {
    local path="$1"
    : > "$path"
}

test_validate_ses_readiness_ready_fixture() {
    local mock_dir call_log output exit_code calls line_count
    mock_dir="$(new_mock_aws_dir)"
    call_log="$mock_dir/aws_calls.log"
    init_call_log "$call_log"

    output="$(SES_READINESS_MOCK_MODE=ready SES_READINESS_AWS_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate_ses_readiness.sh" --identity flapjack.foo --region us-east-1 2>&1)" || exit_code=$?

    calls="$(cat "$call_log")"
    line_count="$(wc -l < "$call_log" | tr -d '[:space:]')"
    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "validate-ses-readiness should pass for a fully ready fixture"
    assert_valid_json "$output" "validate-ses-readiness ready output should be valid JSON"
    assert_json_bool_field "$output" "passed" "true" "validate-ses-readiness ready JSON should report passed=true"
    assert_contains "$output" '"name":"get_account"' "ready output should include get_account step"
    assert_contains "$output" '"name":"sending_enabled"' "ready output should include sending_enabled step"
    assert_contains "$output" '"name":"production_access"' "ready output should include production_access step"
    assert_contains "$output" '"name":"identity_verified"' "ready output should include identity_verified step"
    assert_contains "$output" '"name":"dkim_verified"' "ready output should include dkim_verified step"
    assert_contains "$output" '"name":"unproven_deliverability_items"' "ready output should include unproven_deliverability_items step"
    assert_contains "$(json_step_field "$output" "identity_verified" "detail")" "domain identity" "ready output should report checked identity type"
    assert_not_contains "$output" "123456789012" "ready output should not print AWS account IDs"
    assert_eq "$line_count" "2" "ready fixture should call AWS exactly twice"
    assert_contains "$calls" "sesv2 get-account" "ready fixture should call aws sesv2 get-account"
    assert_contains "$calls" "sesv2 get-email-identity" "ready fixture should call aws sesv2 get-email-identity"
    assert_contains "$calls" "sesv2 get-account --output json" "ready fixture should force JSON output for get-account"
    assert_contains "$calls" "sesv2 get-email-identity --email-identity=flapjack.foo --output json" "ready fixture should force JSON output for get-email-identity"
}

test_validate_ses_readiness_uses_ses_region_default() {
    local mock_dir call_log output exit_code calls
    mock_dir="$(new_mock_aws_dir)"
    call_log="$mock_dir/aws_calls.log"
    init_call_log "$call_log"

    output="$(SES_READINESS_MOCK_MODE=default_region SES_REGION=us-west-2 SES_READINESS_AWS_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate_ses_readiness.sh" --identity flapjack.foo 2>&1)" || exit_code=$?

    calls="$(cat "$call_log")"
    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "validate-ses-readiness should default --region from SES_REGION"
    assert_valid_json "$output" "validate-ses-readiness SES_REGION fallback output should be valid JSON"
    assert_contains "$calls" "--region=us-west-2" "SES_REGION fallback should be passed to both AWS calls"
}

test_validate_ses_readiness_reports_sandbox_state() {
    local mock_dir call_log output exit_code
    mock_dir="$(new_mock_aws_dir)"
    call_log="$mock_dir/aws_calls.log"
    init_call_log "$call_log"

    output="$(SES_READINESS_MOCK_MODE=sandbox SES_READINESS_AWS_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate_ses_readiness.sh" --identity flapjack.foo --region us-east-1 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "validate-ses-readiness should report sandbox mode without failing readiness"
    assert_valid_json "$output" "validate-ses-readiness sandbox output should be valid JSON"
    assert_json_bool_field "$output" "passed" "true" "sandbox output should still pass when other checks succeed"
    assert_contains "$(json_step_field "$output" "production_access" "detail")" "ProductionAccessEnabled=false" "sandbox output should report ProductionAccessEnabled=false"
    assert_contains "$(json_step_field "$output" "production_access" "detail")" "sandbox" "sandbox output should label sandbox state"
}

test_validate_ses_readiness_passes_verified_email_identity_without_dkim() {
    local mock_dir call_log output exit_code
    mock_dir="$(new_mock_aws_dir)"
    call_log="$mock_dir/aws_calls.log"
    init_call_log "$call_log"

    output="$(SES_READINESS_MOCK_MODE=email_identity_ready SES_READINESS_AWS_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate_ses_readiness.sh" --identity noreply@example.com --region us-east-1 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "validate-ses-readiness should pass for a verified email identity"
    assert_valid_json "$output" "validate-ses-readiness email-identity output should be valid JSON"
    assert_json_bool_field "$output" "passed" "true" "email-identity output should report passed=true"
    assert_contains "$(json_step_field "$output" "identity_verified" "detail")" "email identity" "email-identity output should report the checked identity type"
    assert_eq "$(json_step_field "$output" "dkim_verified" "passed")" "true" "dkim_verified should stay passing for email identities"
    assert_contains "$(json_step_field "$output" "dkim_verified" "detail")" "not applicable" "email-identity output should explain that DKIM is not applicable"
}

test_validate_ses_readiness_passes_email_identity_inherited_from_verified_domain() {
    local mock_dir call_log output exit_code calls line_count production_access_detail
    mock_dir="$(new_mock_aws_dir)"
    call_log="$mock_dir/aws_calls.log"
    init_call_log "$call_log"

    output="$(SES_READINESS_MOCK_MODE=email_inherits_domain_ready SES_READINESS_AWS_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate_ses_readiness.sh" --identity system@flapjack.foo --region us-east-1 2>&1)" || exit_code=$?

    calls="$(cat "$call_log")"
    line_count="$(wc -l < "$call_log" | tr -d '[:space:]')"
    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "validate-ses-readiness should pass when an email sender inherits a verified domain identity"
    assert_valid_json "$output" "validate-ses-readiness inherited-domain output should be valid JSON"
    assert_json_bool_field "$output" "passed" "true" "inherited-domain output should report passed=true"
    assert_eq "$(json_step_field "$output" "production_access" "passed")" "true" \
        "inherited-domain output should keep production_access step passed=true"
    production_access_detail="$(json_step_field "$output" "production_access" "detail")"
    assert_contains "$production_access_detail" "ProductionAccessEnabled=true (production access enabled)" "inherited-domain output should report production access enabled"
    assert_not_contains "$production_access_detail" "sandbox" "inherited-domain output should not label ProductionAccessEnabled=true as sandboxed"
    assert_not_contains "$output" "ProductionAccessEnabled=false" "inherited-domain output should not include a sandbox blocker state"
    assert_not_contains "$output" "current-state sandbox" "inherited-domain output should not regress to stale current-state sandbox wording"
    assert_contains "$(json_step_field "$output" "identity_verified" "detail")" "inherited domain identity 'flapjack.foo'" "inherited-domain output should name the domain identity"
    assert_contains "$(json_step_field "$output" "identity_verified" "detail")" "email identity 'system@flapjack.foo'" "inherited-domain output should name the requested sender"
    assert_not_contains "$output" "noreply@flapjack.foo" "inherited-domain output should not drift to non-canonical sender wording"
    assert_contains "$(json_step_field "$output" "dkim_verified" "detail")" "DkimAttributes.Status=SUCCESS" "inherited-domain output should verify DKIM on the domain identity"
    assert_eq "$line_count" "3" "inherited-domain path should call get-account, email identity, then domain identity"
    assert_contains "$calls" "sesv2 get-email-identity --email-identity=system@flapjack.foo" "inherited-domain path should first try the sender identity"
    assert_contains "$calls" "sesv2 get-email-identity --email-identity=flapjack.foo" "inherited-domain path should fall back to the parent domain identity"
}

test_validate_ses_readiness_fails_when_sending_disabled() {
    local mock_dir call_log output exit_code
    mock_dir="$(new_mock_aws_dir)"
    call_log="$mock_dir/aws_calls.log"
    init_call_log "$call_log"

    output="$(SES_READINESS_MOCK_MODE=disabled_sending SES_READINESS_AWS_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate_ses_readiness.sh" --identity flapjack.foo --region us-east-1 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "validate-ses-readiness should fail when SendingEnabled is false"
    assert_valid_json "$output" "validate-ses-readiness disabled-sending output should be valid JSON"
    assert_json_bool_field "$output" "passed" "false" "disabled-sending output should report passed=false"
    assert_eq "$(json_step_field "$output" "sending_enabled" "passed")" "false" "sending_enabled step should fail when account sending is disabled"
}

test_validate_ses_readiness_fails_when_identity_or_dkim_not_success() {
    local mock_dir call_log output exit_code
    mock_dir="$(new_mock_aws_dir)"
    call_log="$mock_dir/aws_calls.log"
    init_call_log "$call_log"

    output="$(SES_READINESS_MOCK_MODE=identity_fail SES_READINESS_AWS_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate_ses_readiness.sh" --identity flapjack.foo --region us-east-1 2>&1)" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "validate-ses-readiness should fail when identity or DKIM status is not SUCCESS"
    assert_valid_json "$output" "validate-ses-readiness identity-fail output should be valid JSON"
    assert_json_bool_field "$output" "passed" "false" "identity-fail output should report passed=false"
    assert_eq "$(json_step_field "$output" "identity_verified" "passed")" "false" "identity_verified should fail when verification status is not SUCCESS"
    assert_eq "$(json_step_field "$output" "dkim_verified" "passed")" "false" "dkim_verified should fail when DKIM status is not SUCCESS"
}

test_validate_ses_readiness_fails_when_get_account_errors() {
    local mock_dir call_log output exit_code calls line_count
    mock_dir="$(new_mock_aws_dir)"
    call_log="$mock_dir/aws_calls.log"
    init_call_log "$call_log"

    output="$(SES_READINESS_MOCK_MODE=get_account_error SES_READINESS_AWS_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate_ses_readiness.sh" --identity flapjack.foo --region us-east-1 2>&1)" || exit_code=$?

    calls="$(cat "$call_log")"
    line_count="$(wc -l < "$call_log" | tr -d '[:space:]')"
    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "validate-ses-readiness should fail when get-account errors"
    assert_valid_json "$output" "validate-ses-readiness get-account-error output should be valid JSON"
    assert_json_bool_field "$output" "passed" "false" "get-account-error output should report passed=false"
    assert_eq "$(json_step_field "$output" "get_account" "passed")" "false" "get_account step should fail when aws get-account errors"
    assert_eq "$(json_step_field "$output" "identity_verified" "passed")" "false" "identity_verified should be skipped when get-account errors"
    assert_eq "$line_count" "1" "get-account-error path should stop before get-email-identity"
    assert_contains "$calls" "sesv2 get-account" "get-account-error path should still attempt aws sesv2 get-account"
}

test_validate_ses_readiness_fails_when_identity_lookup_errors() {
    local mock_dir call_log output exit_code calls line_count
    mock_dir="$(new_mock_aws_dir)"
    call_log="$mock_dir/aws_calls.log"
    init_call_log "$call_log"

    output="$(SES_READINESS_MOCK_MODE=identity_error SES_READINESS_AWS_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate_ses_readiness.sh" --identity flapjack.foo --region us-east-1 2>&1)" || exit_code=$?

    calls="$(cat "$call_log")"
    line_count="$(wc -l < "$call_log" | tr -d '[:space:]')"
    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "validate-ses-readiness should fail when get-email-identity errors"
    assert_valid_json "$output" "validate-ses-readiness identity-error output should be valid JSON"
    assert_json_bool_field "$output" "passed" "false" "identity-error output should report passed=false"
    assert_eq "$(json_step_field "$output" "identity_verified" "passed")" "false" "identity_verified should fail when get-email-identity errors"
    assert_eq "$(json_step_field "$output" "dkim_verified" "passed")" "false" "dkim_verified should fail when get-email-identity errors"
    assert_eq "$line_count" "2" "identity-error path should call both AWS operations before failing"
    assert_contains "$calls" "sesv2 get-email-identity" "identity-error path should attempt aws sesv2 get-email-identity"
}

test_validate_ses_readiness_fails_when_identity_missing() {
    local mock_dir call_log output exit_code line_count
    mock_dir="$(new_mock_aws_dir)"
    call_log="$mock_dir/aws_calls.log"
    init_call_log "$call_log"

    output="$(SES_READINESS_MOCK_MODE=ready SES_READINESS_AWS_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate_ses_readiness.sh" --region us-east-1 2>&1)" || exit_code=$?

    line_count="$(wc -l < "$call_log" | tr -d '[:space:]')"
    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "validate-ses-readiness should fail with machine-readable JSON when identity input is missing"
    assert_valid_json "$output" "validate-ses-readiness missing-identity output should be valid JSON"
    assert_json_bool_field "$output" "passed" "false" "missing-identity output should report passed=false"
    assert_contains "$output" "--identity" "missing-identity output should explain required --identity input"
    assert_eq "$line_count" "0" "missing-identity path should not call AWS"
}

test_validate_ses_readiness_fails_when_region_value_missing() {
    local mock_dir call_log output exit_code line_count
    mock_dir="$(new_mock_aws_dir)"
    call_log="$mock_dir/aws_calls.log"
    init_call_log "$call_log"

    output="$(SES_READINESS_MOCK_MODE=ready SES_READINESS_AWS_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate_ses_readiness.sh" --identity flapjack.foo --region 2>&1)" || exit_code=$?

    line_count="$(wc -l < "$call_log" | tr -d '[:space:]')"
    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "validate-ses-readiness should fail with machine-readable JSON when --region has no value"
    assert_valid_json "$output" "validate-ses-readiness missing-region-value output should be valid JSON"
    assert_json_bool_field "$output" "passed" "false" "missing-region-value output should report passed=false"
    assert_contains "$output" "--region" "missing-region-value output should explain required --region value"
    assert_eq "$line_count" "0" "missing-region-value path should not call AWS"
}

test_validate_ses_readiness_rejects_option_like_identity_value() {
    local mock_dir call_log output exit_code line_count
    mock_dir="$(new_mock_aws_dir)"
    call_log="$mock_dir/aws_calls.log"
    init_call_log "$call_log"

    output="$(SES_READINESS_MOCK_MODE=ready SES_READINESS_AWS_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate_ses_readiness.sh" --identity --query 2>&1)" || exit_code=$?

    line_count="$(wc -l < "$call_log" | tr -d '[:space:]')"
    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "validate-ses-readiness should reject option-like identity values"
    assert_valid_json "$output" "validate-ses-readiness option-like-identity output should be valid JSON"
    assert_json_bool_field "$output" "passed" "false" "option-like-identity output should report passed=false"
    assert_contains "$output" "Missing value for --identity" "option-like-identity output should treat a flag-like token as a missing identity value"
    assert_eq "$line_count" "0" "option-like-identity path should not call AWS"
}

test_validate_ses_readiness_rejects_option_like_region_value() {
    local mock_dir call_log output exit_code line_count
    mock_dir="$(new_mock_aws_dir)"
    call_log="$mock_dir/aws_calls.log"
    init_call_log "$call_log"

    output="$(SES_READINESS_MOCK_MODE=ready SES_READINESS_AWS_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate_ses_readiness.sh" --identity flapjack.foo --region --debug 2>&1)" || exit_code=$?

    line_count="$(wc -l < "$call_log" | tr -d '[:space:]')"
    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "validate-ses-readiness should reject option-like region values"
    assert_valid_json "$output" "validate-ses-readiness option-like-region output should be valid JSON"
    assert_json_bool_field "$output" "passed" "false" "option-like-region output should report passed=false"
    assert_contains "$output" "Missing value for --region" "option-like-region output should treat a flag-like token as a missing region value"
    assert_eq "$line_count" "0" "option-like-region path should not call AWS"
}

test_validate_ses_readiness_rejects_option_like_ses_region_env() {
    local mock_dir call_log output exit_code line_count
    mock_dir="$(new_mock_aws_dir)"
    call_log="$mock_dir/aws_calls.log"
    init_call_log "$call_log"

    output="$(SES_READINESS_MOCK_MODE=ready SES_REGION=--debug SES_READINESS_AWS_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate_ses_readiness.sh" --identity flapjack.foo 2>&1)" || exit_code=$?

    line_count="$(wc -l < "$call_log" | tr -d '[:space:]')"
    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "validate-ses-readiness should reject option-like SES_REGION fallback values"
    assert_valid_json "$output" "validate-ses-readiness option-like-SES_REGION output should be valid JSON"
    assert_json_bool_field "$output" "passed" "false" "option-like-SES_REGION output should report passed=false"
    assert_contains "$output" "Invalid value for --region" "option-like-SES_REGION output should explain the invalid region value"
    assert_eq "$line_count" "0" "option-like-SES_REGION path should not call AWS"
}

test_validate_ses_readiness_fails_on_unknown_argument() {
    local mock_dir call_log output exit_code line_count
    mock_dir="$(new_mock_aws_dir)"
    call_log="$mock_dir/aws_calls.log"
    init_call_log "$call_log"

    output="$(SES_READINESS_MOCK_MODE=ready SES_READINESS_AWS_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/validate_ses_readiness.sh" --unexpected 2>&1)" || exit_code=$?

    line_count="$(wc -l < "$call_log" | tr -d '[:space:]')"
    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "validate-ses-readiness should fail with machine-readable JSON on unknown arguments"
    assert_valid_json "$output" "validate-ses-readiness unknown-argument output should be valid JSON"
    assert_json_bool_field "$output" "passed" "false" "unknown-argument output should report passed=false"
    assert_contains "$output" "Unknown argument: --unexpected" "unknown-argument output should echo the unexpected argument"
    assert_eq "$line_count" "0" "unknown-argument path should not call AWS"
}

echo "=== validate-ses-readiness.sh tests ==="
test_validate_ses_readiness_ready_fixture
test_validate_ses_readiness_uses_ses_region_default
test_validate_ses_readiness_reports_sandbox_state
test_validate_ses_readiness_passes_verified_email_identity_without_dkim
test_validate_ses_readiness_passes_email_identity_inherited_from_verified_domain
test_validate_ses_readiness_fails_when_sending_disabled
test_validate_ses_readiness_fails_when_identity_or_dkim_not_success
test_validate_ses_readiness_fails_when_get_account_errors
test_validate_ses_readiness_fails_when_identity_lookup_errors
test_validate_ses_readiness_fails_when_identity_missing
test_validate_ses_readiness_fails_when_region_value_missing
test_validate_ses_readiness_rejects_option_like_identity_value
test_validate_ses_readiness_rejects_option_like_region_value
test_validate_ses_readiness_rejects_option_like_ses_region_env
test_validate_ses_readiness_fails_on_unknown_argument

echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
