#!/usr/bin/env bash
# Tier-1 paid-beta RC registry and classification contract tests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ORCH_SCRIPT="$REPO_ROOT/scripts/launch/run_full_backend_validation.sh"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/test_helpers.sh
source "$SCRIPT_DIR/lib/test_helpers.sh"

RUN_EXIT_CODE=0
RUN_STDOUT=""
RUN_STDERR=""

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

json_step_status() {
    json_step_field "$1" "$2" "status"
}

json_step_reason() {
    json_step_field "$1" "$2" "reason"
}

json_step_count() {
    local json="$1"
    python3 - "$json" <<'PY' 2>/dev/null || echo "0"
import json
import sys
payload = json.loads(sys.argv[1])
print(len(payload.get("steps", [])))
PY
}

run_orchestrator() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local stdout_file="$tmp_dir/stdout"
    local stderr_file="$tmp_dir/stderr"
    local exit_code=0
    if "$@" >"$stdout_file" 2>"$stderr_file"; then
        exit_code=0
    else
        exit_code=$?
    fi
    RUN_EXIT_CODE="$exit_code"
    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
    rm -rf "$tmp_dir"
}

assert_tier1_step_names_present() {
    local output_json="$1"
    assert_contains "$output_json" "\"name\": \"admin_broadcast\"" "paid-beta-rc should include admin_broadcast tier-1 step"
    assert_contains "$output_json" "\"name\": \"billing_health_last_activity\"" "paid-beta-rc should include billing_health_last_activity tier-1 step"
    assert_contains "$output_json" "\"name\": \"audit_timeline\"" "paid-beta-rc should include audit_timeline tier-1 step"
    assert_contains "$output_json" "\"name\": \"status_runtime\"" "paid-beta-rc should include status_runtime tier-1 step"
    assert_contains "$output_json" "\"name\": \"ses_inbound\"" "paid-beta-rc should include ses_inbound tier-1 step"
    assert_contains "$output_json" "\"name\": \"canary_customer_loop\"" "paid-beta-rc should include canary_customer_loop tier-1 step"
    assert_contains "$output_json" "\"name\": \"canary_outside_aws\"" "paid-beta-rc should include canary_outside_aws tier-1 step"
    assert_contains "$output_json" "\"name\": \"stripe_webhook_signature_matrix_idempotency\"" "paid-beta-rc should include stripe_webhook_signature_matrix_idempotency tier-1 step"
    assert_contains "$output_json" "\"name\": \"test_clock\"" "paid-beta-rc should include test_clock tier-1 step"
    assert_contains "$output_json" "\"name\": \"tenant_isolation\"" "paid-beta-rc should include tenant_isolation tier-1 step"
    assert_contains "$output_json" "\"name\": \"signup_abuse\"" "paid-beta-rc should include signup_abuse tier-1 step"
    assert_contains "$output_json" "\"name\": \"browser_signup_paid\"" "paid-beta-rc should include browser_signup_paid tier-1 step"
    assert_contains "$output_json" "\"name\": \"browser_portal_cancel\"" "paid-beta-rc should include browser_portal_cancel tier-1 step"
}

write_tier1_mock_cargo() {
    local path="$1"
    write_mock_script "$path" '
set -euo pipefail
args="$*"
if [[ "$args" == "test --workspace" ]]; then
    exit 0
fi
if [[ "$args" == *"--test admin_broadcast_test"* ]]; then
    echo "SKIP: DATABASE_URL not set — skipping admin broadcast integration tests"
    exit 0
fi
if [[ "$args" == *"--test pg_customer_repo_test"* ]]; then
    echo "SKIP: DATABASE_URL not set — skipping PgCustomerRepo SQL tests"
    exit 0
fi
if [[ "$args" == *"--test admin_audit_view_test"* ]]; then
    echo "SKIP: DATABASE_URL not set — skipping admin audit view integration tests"
    exit 0
fi
if [[ "$args" == *"--test admin_token_audit_test"* ]]; then
    echo "SKIP: DATABASE_URL not set — skipping audit_log integration tests"
    exit 0
fi
exit 0'
}

test_paid_beta_rc_tier1_registry_and_missing_secret_classification() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    mkdir -p "$tmp_dir/bin"

    write_tier1_mock_cargo "$tmp_dir/mock_cargo.sh"
    write_mock_script "$tmp_dir/mock_backend_gate.sh" 'echo "{\"verdict\":\"pass\"}"; exit 0'
    write_mock_script "$tmp_dir/mock_local_signoff.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_ses.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_billing.sh" 'echo "{\"result\":\"passed\"}"; exit 0'
    write_mock_script "$tmp_dir/mock_browser_preflight.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_tf_static_stage7.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_tf_static_stage8.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_runtime_smoke.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_canary_outside_aws.sh" 'exit 9'
    write_mock_script "$tmp_dir/mock_ses_inbound_roundtrip.sh" 'echo "ses_inbound should not run without prerequisites" >&2; exit 99'
    write_mock_script "$tmp_dir/mock_canary_customer_loop.sh" 'echo "canary_customer_loop should not run without prerequisites" >&2; exit 99'
    write_mock_script "$tmp_dir/bin/npx" 'exit 0'

    run_orchestrator env \
        PATH="$tmp_dir/bin:$PATH" \
        FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
        FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
        FULL_VALIDATION_LOCAL_SIGNOFF_SCRIPT="$tmp_dir/mock_local_signoff.sh" \
        FULL_VALIDATION_SES_READINESS_SCRIPT="$tmp_dir/mock_ses.sh" \
        FULL_VALIDATION_STAGING_BILLING_REHEARSAL_SCRIPT="$tmp_dir/mock_billing.sh" \
        FULL_VALIDATION_BROWSER_PREFLIGHT_SCRIPT="$tmp_dir/mock_browser_preflight.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE7_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage7.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE8_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage8.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE7_RUNTIME_SMOKE_SCRIPT="$tmp_dir/mock_runtime_smoke.sh" \
        FULL_VALIDATION_OUTSIDE_AWS_HEALTH_SCRIPT="$tmp_dir/mock_canary_outside_aws.sh" \
        FULL_VALIDATION_SES_INBOUND_ROUNDTRIP_SCRIPT="$tmp_dir/mock_ses_inbound_roundtrip.sh" \
        FULL_VALIDATION_CANARY_CUSTOMER_LOOP_SCRIPT="$tmp_dir/mock_canary_customer_loop.sh" \
        bash "$ORCH_SCRIPT" --paid-beta-rc --sha=aabbccddee00112233445566778899aabbccddee --billing-month=2026-03 --staging-smoke-ami-id=ami-12345678

    rm -rf "$tmp_dir"

    assert_valid_json "$RUN_STDOUT" "tier-1 missing-secret path should emit valid JSON"
    assert_tier1_step_names_present "$RUN_STDOUT"
    assert_eq "$(json_step_count "$RUN_STDOUT")" "22" "paid-beta-rc should include Stage 1 plus Tier-1 registry rows"
    assert_eq "$(json_step_status "$RUN_STDOUT" "admin_broadcast")" "external_secret_missing" "db-backed admin_broadcast skip marker should map to external_secret_missing"
    assert_eq "$(json_step_status "$RUN_STDOUT" "billing_health_last_activity")" "external_secret_missing" "db-backed billing health skip marker should map to external_secret_missing"
    assert_eq "$(json_step_status "$RUN_STDOUT" "audit_timeline")" "external_secret_missing" "db-backed audit timeline skip marker should map to external_secret_missing"
    assert_eq "$(json_step_status "$RUN_STDOUT" "ses_inbound")" "external_secret_missing" "ses_inbound should report external_secret_missing when required inputs are absent"
    assert_eq "$(json_step_status "$RUN_STDOUT" "canary_customer_loop")" "external_secret_missing" "canary_customer_loop should report external_secret_missing when required inputs are absent"
    assert_eq "$(json_step_status "$RUN_STDOUT" "canary_outside_aws")" "fail" "canary_outside_aws non-zero exit should map to fail"
}

test_paid_beta_rc_tier1_live_evidence_gap_and_browser_promotion() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    mkdir -p "$tmp_dir/bin"

    write_tier1_mock_cargo "$tmp_dir/mock_cargo.sh"
    write_mock_script "$tmp_dir/mock_backend_gate.sh" 'echo "{\"verdict\":\"pass\"}"; exit 0'
    write_mock_script "$tmp_dir/mock_local_signoff.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_ses.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_billing.sh" 'echo "{\"result\":\"passed\"}"; exit 0'
    write_mock_script "$tmp_dir/mock_browser_preflight.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_tf_static_stage7.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_tf_static_stage8.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_runtime_smoke.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_canary_outside_aws.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_ses_inbound_roundtrip.sh" '
if [ -z "${SES_FROM_ADDRESS:-}" ] || [ -z "${SES_REGION:-}" ]; then
    echo "SES_FROM_ADDRESS and SES_REGION are required" >&2
    exit 96
fi
exit "${MOCK_SES_INBOUND_EXIT_CODE:-0}"'
    write_mock_script "$tmp_dir/mock_canary_customer_loop.sh" '
if [ "${CANARY_RC_READINESS_MODE:-0}" != "1" ]; then
    echo "CANARY_RC_READINESS_MODE=1 is required in RC delegation mode" >&2
    exit 97
fi
if [ -z "${ADMIN_KEY:-}" ] || [ -z "${STRIPE_SECRET_KEY:-}" ]; then
    echo "ADMIN_KEY and STRIPE_SECRET_KEY are required" >&2
    exit 98
fi
exit "${MOCK_CANARY_CUSTOMER_LOOP_EXIT_CODE:-0}"'
    write_mock_script "$tmp_dir/bin/npx" 'exit 0'

    run_orchestrator env \
        SES_FROM_ADDRESS="ops@example.com" \
        SES_REGION="us-east-1" \
        ADMIN_KEY="admin-test-key" \
        STRIPE_SECRET_KEY="sk_test_123" \
        PATH="$tmp_dir/bin:$PATH" \
        FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
        FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
        FULL_VALIDATION_LOCAL_SIGNOFF_SCRIPT="$tmp_dir/mock_local_signoff.sh" \
        FULL_VALIDATION_SES_READINESS_SCRIPT="$tmp_dir/mock_ses.sh" \
        FULL_VALIDATION_STAGING_BILLING_REHEARSAL_SCRIPT="$tmp_dir/mock_billing.sh" \
        FULL_VALIDATION_BROWSER_PREFLIGHT_SCRIPT="$tmp_dir/mock_browser_preflight.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE7_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage7.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE8_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage8.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE7_RUNTIME_SMOKE_SCRIPT="$tmp_dir/mock_runtime_smoke.sh" \
        FULL_VALIDATION_OUTSIDE_AWS_HEALTH_SCRIPT="$tmp_dir/mock_canary_outside_aws.sh" \
        FULL_VALIDATION_SES_INBOUND_ROUNDTRIP_SCRIPT="$tmp_dir/mock_ses_inbound_roundtrip.sh" \
        FULL_VALIDATION_CANARY_CUSTOMER_LOOP_SCRIPT="$tmp_dir/mock_canary_customer_loop.sh" \
        bash "$ORCH_SCRIPT" --paid-beta-rc --sha=aabbccddee00112233445566778899aabbccddee --billing-month=2026-03 --staging-smoke-ami-id=ami-12345678

    rm -rf "$tmp_dir"

    assert_eq "$(json_step_status "$RUN_STDOUT" "ses_inbound")" "pass" "ses_inbound should report pass when inputs exist and delegated roundtrip owner succeeds"
    assert_eq "$(json_step_status "$RUN_STDOUT" "canary_customer_loop")" "pass" "canary_customer_loop should report pass when inputs exist and delegated canary owner succeeds"
    assert_eq "$(json_step_status "$RUN_STDOUT" "test_clock")" "live_evidence_gap" "test_clock should stay non-pass in readiness mode"
    assert_eq "$(json_step_status "$RUN_STDOUT" "browser_signup_paid")" "fail" "browser_signup_paid should be promoted from skipped to fail as critical surface"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "browser_signup_paid")" "critical_surface_skipped" "browser_signup_paid should expose critical_surface_skipped"
    assert_eq "$(json_step_status "$RUN_STDOUT" "browser_portal_cancel")" "fail" "browser_portal_cancel should be promoted from skipped to fail as critical surface"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "browser_portal_cancel")" "critical_surface_skipped" "browser_portal_cancel should expose critical_surface_skipped"
    assert_json_bool_field "$RUN_STDOUT" "ready" "false" "critical browser skip promotion should keep paid-beta-rc ready=false"
    assert_eq "$(json_step_status "$RUN_STDOUT" "canary_outside_aws")" "pass" "canary_outside_aws zero exit should map to pass"
}

test_paid_beta_rc_canary_customer_loop_reads_credential_env_file() {
    local tmp_dir credential_env_file
    tmp_dir="$(mktemp -d)"
    credential_env_file="$tmp_dir/credential.env"
    mkdir -p "$tmp_dir/bin"

    cat > "$credential_env_file" <<'EOF'
FLAPJACK_ADMIN_KEY=file_admin_key
STRIPE_TEST_SECRET_KEY=sk_test_from_file
EOF

    write_tier1_mock_cargo "$tmp_dir/mock_cargo.sh"
    write_mock_script "$tmp_dir/mock_backend_gate.sh" 'echo "{\"verdict\":\"pass\"}"; exit 0'
    write_mock_script "$tmp_dir/mock_local_signoff.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_ses.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_billing.sh" 'echo "{\"result\":\"passed\"}"; exit 0'
    write_mock_script "$tmp_dir/mock_browser_preflight.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_tf_static_stage7.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_tf_static_stage8.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_runtime_smoke.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_canary_outside_aws.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_ses_inbound_roundtrip.sh" '
if [ -z "${SES_FROM_ADDRESS:-}" ] || [ -z "${SES_REGION:-}" ]; then
    echo "SES_FROM_ADDRESS and SES_REGION are required" >&2
    exit 96
fi
exit 0'
    write_mock_script "$tmp_dir/mock_canary_customer_loop.sh" '
if [ "${CANARY_RC_READINESS_MODE:-0}" != "1" ]; then
    echo "CANARY_RC_READINESS_MODE=1 is required in RC delegation mode" >&2
    exit 97
fi
if [ -z "${ADMIN_KEY:-}" ] || [ -z "${STRIPE_SECRET_KEY:-}" ]; then
    echo "ADMIN_KEY and STRIPE_SECRET_KEY are required" >&2
    exit 98
fi
exit 0'
    write_mock_script "$tmp_dir/bin/npx" 'exit 0'

    run_orchestrator env \
        ADMIN_KEY= \
        FLAPJACK_ADMIN_KEY= \
        STRIPE_SECRET_KEY= \
        STRIPE_TEST_SECRET_KEY= \
        PATH="$tmp_dir/bin:$PATH" \
        FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
        FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
        FULL_VALIDATION_LOCAL_SIGNOFF_SCRIPT="$tmp_dir/mock_local_signoff.sh" \
        FULL_VALIDATION_SES_READINESS_SCRIPT="$tmp_dir/mock_ses.sh" \
        FULL_VALIDATION_STAGING_BILLING_REHEARSAL_SCRIPT="$tmp_dir/mock_billing.sh" \
        FULL_VALIDATION_BROWSER_PREFLIGHT_SCRIPT="$tmp_dir/mock_browser_preflight.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE7_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage7.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE8_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage8.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE7_RUNTIME_SMOKE_SCRIPT="$tmp_dir/mock_runtime_smoke.sh" \
        FULL_VALIDATION_OUTSIDE_AWS_HEALTH_SCRIPT="$tmp_dir/mock_canary_outside_aws.sh" \
        FULL_VALIDATION_SES_INBOUND_ROUNDTRIP_SCRIPT="$tmp_dir/mock_ses_inbound_roundtrip.sh" \
        FULL_VALIDATION_CANARY_CUSTOMER_LOOP_SCRIPT="$tmp_dir/mock_canary_customer_loop.sh" \
        bash "$ORCH_SCRIPT" --paid-beta-rc --credential-env-file="$credential_env_file" --sha=aabbccddee00112233445566778899aabbccddee --billing-month=2026-03 --staging-smoke-ami-id=ami-12345678

    rm -rf "$tmp_dir"

    assert_eq "$(json_step_status "$RUN_STDOUT" "canary_customer_loop")" "pass" "canary_customer_loop should use --credential-env-file secrets and execute delegated canary owner"
}

test_paid_beta_rc_delegated_tier1_exit_code_mappings() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    mkdir -p "$tmp_dir/bin"

    write_tier1_mock_cargo "$tmp_dir/mock_cargo.sh"
    write_mock_script "$tmp_dir/mock_backend_gate.sh" 'echo "{\"verdict\":\"pass\"}"; exit 0'
    write_mock_script "$tmp_dir/mock_local_signoff.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_ses.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_billing.sh" 'echo "{\"result\":\"passed\"}"; exit 0'
    write_mock_script "$tmp_dir/mock_browser_preflight.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_tf_static_stage7.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_tf_static_stage8.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_runtime_smoke.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_canary_outside_aws.sh" 'exit 0'
    write_mock_script "$tmp_dir/mock_ses_inbound_roundtrip.sh" '
if [ -z "${SES_FROM_ADDRESS:-}" ] || [ -z "${SES_REGION:-}" ]; then
    echo "SES_FROM_ADDRESS and SES_REGION are required" >&2
    exit 96
fi
exit "${MOCK_SES_INBOUND_EXIT_CODE:-0}"'
    write_mock_script "$tmp_dir/mock_canary_customer_loop.sh" '
if [ "${CANARY_RC_READINESS_MODE:-0}" != "1" ]; then
    echo "CANARY_RC_READINESS_MODE=1 is required in RC delegation mode" >&2
    exit 97
fi
if [ -z "${ADMIN_KEY:-}" ] || [ -z "${STRIPE_SECRET_KEY:-}" ]; then
    echo "ADMIN_KEY and STRIPE_SECRET_KEY are required" >&2
    exit 98
fi
exit "${MOCK_CANARY_CUSTOMER_LOOP_EXIT_CODE:-0}"'
    write_mock_script "$tmp_dir/bin/npx" 'exit 0'

    local ses_exit expected_ses_reason
    for ses_exit in 21 22 1 2; do
        case "$ses_exit" in
            21) expected_ses_reason="ses_inbound_roundtrip_timeout" ;;
            22) expected_ses_reason="ses_inbound_auth_verdict_failed" ;;
            1) expected_ses_reason="ses_inbound_roundtrip_runtime_failed" ;;
            *) expected_ses_reason="ses_inbound_roundtrip_usage_failed" ;;
        esac
        run_orchestrator env \
            SES_FROM_ADDRESS="ops@example.com" \
            SES_REGION="us-east-1" \
            ADMIN_KEY="admin-test-key" \
            STRIPE_SECRET_KEY="sk_test_123" \
            MOCK_SES_INBOUND_EXIT_CODE="$ses_exit" \
            MOCK_CANARY_CUSTOMER_LOOP_EXIT_CODE="0" \
            PATH="$tmp_dir/bin:$PATH" \
            FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
            FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
            FULL_VALIDATION_LOCAL_SIGNOFF_SCRIPT="$tmp_dir/mock_local_signoff.sh" \
            FULL_VALIDATION_SES_READINESS_SCRIPT="$tmp_dir/mock_ses.sh" \
            FULL_VALIDATION_STAGING_BILLING_REHEARSAL_SCRIPT="$tmp_dir/mock_billing.sh" \
            FULL_VALIDATION_BROWSER_PREFLIGHT_SCRIPT="$tmp_dir/mock_browser_preflight.sh" \
            FULL_VALIDATION_TERRAFORM_STAGE7_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage7.sh" \
            FULL_VALIDATION_TERRAFORM_STAGE8_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage8.sh" \
            FULL_VALIDATION_TERRAFORM_STAGE7_RUNTIME_SMOKE_SCRIPT="$tmp_dir/mock_runtime_smoke.sh" \
            FULL_VALIDATION_OUTSIDE_AWS_HEALTH_SCRIPT="$tmp_dir/mock_canary_outside_aws.sh" \
            FULL_VALIDATION_SES_INBOUND_ROUNDTRIP_SCRIPT="$tmp_dir/mock_ses_inbound_roundtrip.sh" \
            FULL_VALIDATION_CANARY_CUSTOMER_LOOP_SCRIPT="$tmp_dir/mock_canary_customer_loop.sh" \
            bash "$ORCH_SCRIPT" --paid-beta-rc --sha=aabbccddee00112233445566778899aabbccddee --billing-month=2026-03 --staging-smoke-ami-id=ami-12345678
        assert_eq "$(json_step_status "$RUN_STDOUT" "ses_inbound")" "fail" "ses_inbound exit code ${ses_exit} should map to fail"
        assert_eq "$(json_step_reason "$RUN_STDOUT" "ses_inbound")" "$expected_ses_reason" "ses_inbound exit code ${ses_exit} should map to deterministic reason"
    done

    run_orchestrator env \
        SES_FROM_ADDRESS="ops@example.com" \
        SES_REGION="us-east-1" \
        ADMIN_KEY="admin-test-key" \
        STRIPE_SECRET_KEY="sk_test_123" \
        MOCK_SES_INBOUND_EXIT_CODE="0" \
        MOCK_CANARY_CUSTOMER_LOOP_EXIT_CODE="1" \
        PATH="$tmp_dir/bin:$PATH" \
        FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
        FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
        FULL_VALIDATION_LOCAL_SIGNOFF_SCRIPT="$tmp_dir/mock_local_signoff.sh" \
        FULL_VALIDATION_SES_READINESS_SCRIPT="$tmp_dir/mock_ses.sh" \
        FULL_VALIDATION_STAGING_BILLING_REHEARSAL_SCRIPT="$tmp_dir/mock_billing.sh" \
        FULL_VALIDATION_BROWSER_PREFLIGHT_SCRIPT="$tmp_dir/mock_browser_preflight.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE7_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage7.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE8_STATIC_SCRIPT="$tmp_dir/mock_tf_static_stage8.sh" \
        FULL_VALIDATION_TERRAFORM_STAGE7_RUNTIME_SMOKE_SCRIPT="$tmp_dir/mock_runtime_smoke.sh" \
        FULL_VALIDATION_OUTSIDE_AWS_HEALTH_SCRIPT="$tmp_dir/mock_canary_outside_aws.sh" \
        FULL_VALIDATION_SES_INBOUND_ROUNDTRIP_SCRIPT="$tmp_dir/mock_ses_inbound_roundtrip.sh" \
        FULL_VALIDATION_CANARY_CUSTOMER_LOOP_SCRIPT="$tmp_dir/mock_canary_customer_loop.sh" \
        bash "$ORCH_SCRIPT" --paid-beta-rc --sha=aabbccddee00112233445566778899aabbccddee --billing-month=2026-03 --staging-smoke-ami-id=ami-12345678
    assert_eq "$(json_step_status "$RUN_STDOUT" "canary_customer_loop")" "fail" "canary_customer_loop non-zero exit should map to fail"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "canary_customer_loop")" "canary_customer_loop_failed" "canary_customer_loop non-zero exit should map to deterministic reason"

    rm -rf "$tmp_dir"
}

echo "=== full backend validation tier1 registry tests ==="
test_paid_beta_rc_tier1_registry_and_missing_secret_classification
test_paid_beta_rc_tier1_live_evidence_gap_and_browser_promotion
test_paid_beta_rc_canary_customer_loop_reads_credential_env_file
test_paid_beta_rc_delegated_tier1_exit_code_mappings
run_test_summary
