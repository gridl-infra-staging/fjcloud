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

json_step_names_csv() {
    local json="$1"
    python3 - "$json" <<'PY' 2>/dev/null || echo ""
import json
import sys
payload = json.loads(sys.argv[1])
print(",".join(str(step.get("name", "")) for step in payload.get("steps", [])))
PY
}

registry_names_csv() {
    local json="$1"
    python3 - "$json" <<'PY' 2>/dev/null || echo ""
import json
import sys
payload = json.loads(sys.argv[1])
print(",".join(str(step.get("name", "")) for step in payload.get("steps", [])))
PY
}

owner_registry_names_csv() {
    __RUN_FULL_BACKEND_VALIDATION_SOURCED=1 bash -c '
set -euo pipefail
source "$1"
STEP_REGISTRY_MODE=collect
REGISTERED_STEP_NAMES=()
visit_paid_beta_rc_step_registry
(IFS=,; printf "%s\n" "${REGISTERED_STEP_NAMES[*]}")
' _ "$ORCH_SCRIPT"
}

run_orchestrator() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local stdout_file="$tmp_dir/stdout"
    local stderr_file="$tmp_dir/stderr"
    local default_browser_lane_script="$tmp_dir/mock_default_browser_lane.sh"
    local default_stripe_validation_script="$tmp_dir/mock_default_validate_stripe.sh"
    local default_web_runtime_root="$tmp_dir/default_web_runtime"
    write_mock_script "$default_browser_lane_script" 'exit 0'
    write_mock_script "$default_stripe_validation_script" '
if [ "$*" != "--test-clock" ]; then
    echo "validate-stripe should be delegated with --test-clock" >&2
    exit 88
fi
exit 0'
    write_mock_web_playwright_runtime "$default_web_runtime_root"
    local exit_code=0
    if FULL_VALIDATION_BROWSER_LANE_SCRIPT="$default_browser_lane_script" \
        FULL_VALIDATION_STRIPE_VALIDATION_SCRIPT="$default_stripe_validation_script" \
        FULL_VALIDATION_WEB_RUNTIME_REPO_ROOT="$default_web_runtime_root" \
        "$@" >"$stdout_file" 2>"$stderr_file"; then
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

assert_artifact_log_exists() {
    local artifact_dir="$1" step_name="$2"
    assert_file_exists "$artifact_dir/$step_name.log" "$step_name should keep using coordinator per-step log writer"
}

test_list_paid_beta_steps_matches_registry_owner() {
    local listed_names expected_names

    run_orchestrator bash "$ORCH_SCRIPT" --list-paid-beta-steps
    assert_eq "$RUN_EXIT_CODE" "0" "list-paid-beta-steps should exit 0"
    assert_valid_json "$RUN_STDOUT" "list-paid-beta-steps should emit valid JSON"
    assert_eq "$(json_step_count "$RUN_STDOUT")" "22" "list-paid-beta-steps should expose the complete paid-beta registry"
    assert_eq "$(json_step_field "$RUN_STDOUT" "browser_signup_paid" "section")" "1" "browser_signup_paid should map to section 1"
    assert_eq "$(json_step_field "$RUN_STDOUT" "cargo_workspace_tests" "section")" "2" "cargo_workspace_tests should map to section 2"
    assert_eq "$(json_step_field "$RUN_STDOUT" "ses_readiness" "section")" "3" "ses_readiness should map to section 3"
    assert_eq "$(json_step_field "$RUN_STDOUT" "admin_broadcast" "section")" "4" "admin_broadcast should map to section 4"
    assert_eq "$(json_step_field "$RUN_STDOUT" "billing_health_last_activity" "section")" "4" "billing_health_last_activity should map to section 4"
    assert_eq "$(json_step_field "$RUN_STDOUT" "backend_launch_gate" "section")" "6" "backend_launch_gate should map to section 6"

    listed_names="$(registry_names_csv "$RUN_STDOUT")"
    expected_names="$(owner_registry_names_csv)"
    assert_eq "$listed_names" "$expected_names" "list-paid-beta-steps order should match the registry dispatch owner"
}

write_mock_web_playwright_runtime() {
    local root="$1"
    mkdir -p "$root/web/node_modules/@playwright/test"
    cat > "$root/web/node_modules/@playwright/test/package.json" <<'EOF'
{
  "name": "@playwright/test",
  "version": "0.0.0-test"
}
EOF
}

write_tier1_mock_cargo() {
    local path="$1"
    write_mock_script "$path" '
set -euo pipefail
args="$*"
if [ -n "${TIER1_CARGO_ARGS_LOG:-}" ]; then
    echo "$args" >> "$TIER1_CARGO_ARGS_LOG"
fi
if [[ "$args" == "test --workspace" ]]; then
    exit 0
fi
if [[ "$args" == *"--test auth_admin admin_broadcast_test::"* ]]; then
    echo "SKIP: DATABASE_URL not set — skipping admin broadcast integration tests"
    exit 0
fi
if [[ "$args" == *"--test platform pg_customer_repo_test::"* ]]; then
    echo "SKIP: DATABASE_URL not set — skipping PgCustomerRepo SQL tests"
    exit 0
fi
if [[ "$args" == *"--test auth_admin admin_audit_view_test::"* ]]; then
    echo "SKIP: DATABASE_URL not set — skipping admin audit view integration tests"
    exit 0
fi
if [[ "$args" == *"--test auth_admin admin_token_audit_test::"* ]]; then
    echo "SKIP: DATABASE_URL not set — skipping audit_log integration tests"
    exit 0
fi
exit 0'
}

test_paid_beta_rc_rust_steps_target_integration_binary() {
    local tmp_dir cargo_args
    tmp_dir="$(mktemp -d)"
    cargo_args="$tmp_dir/cargo_args.log"
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
    write_mock_script "$tmp_dir/mock_ses_inbound_roundtrip.sh" 'echo "ses_inbound should not run without prerequisites" >&2; exit 99'
    write_mock_script "$tmp_dir/mock_canary_customer_loop.sh" 'echo "canary_customer_loop should not run without prerequisites" >&2; exit 99'
    write_mock_script "$tmp_dir/bin/npx" 'exit 0'

    run_orchestrator env \
        TIER1_CARGO_ARGS_LOG="$cargo_args" \
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
        bash "$ORCH_SCRIPT" --paid-beta-rc --sha=aabbccddee00112233445566778899aabbccddee --billing-month=2026-03 --staging-smoke-api-ami-id=ami-12345678 --staging-smoke-flapjack-ami-id=ami-87654321

    cargo_args="$(cat "$cargo_args" 2>/dev/null || true)"
    rm -rf "$tmp_dir"

    assert_contains "$cargo_args" "test -p api --test auth_admin admin_broadcast_test::" "admin_broadcast must target auth_admin grouped binary with module selector"
    assert_contains "$cargo_args" "test -p api --test platform pg_customer_repo_test::" "billing_health_last_activity must target platform grouped binary for PgCustomerRepo module"
    assert_contains "$cargo_args" "test -p api --test platform tenants_test::" "billing_health_last_activity must target platform grouped binary for tenants module"
    assert_contains "$cargo_args" "test -p api --test auth_admin admin_audit_view_test::" "audit_timeline must target auth_admin grouped binary for admin audit module"
    assert_contains "$cargo_args" "test -p api --test auth_admin admin_token_audit_test::" "audit_timeline must target auth_admin grouped binary for admin token audit module"
    assert_contains "$cargo_args" "test -p api --test platform onboarding_test::status_response_uses_region_not_deployment_field_names" "status_runtime must target platform grouped binary by module path"
    assert_contains "$cargo_args" "test -p api --test billing stripe_webhook_signature_test::" "stripe_webhook step must target billing grouped binary for signature module"
    assert_contains "$cargo_args" "test -p api --test billing stripe_webhook_event_matrix_test::" "stripe_webhook step must target billing grouped binary for event-matrix module"
    assert_contains "$cargo_args" "test -p api --test billing stripe_webhook_idempotency_test::" "stripe_webhook step must target billing grouped binary for idempotency module"
    assert_contains "$cargo_args" "test -p api --test platform tenant_isolation_proptest::tenant_isolation_proptest_route_family" "tenant_isolation must target platform grouped binary with module and function selector"
    assert_contains "$cargo_args" "test -p api --test platform signup_abuse_test::" "signup_abuse must target platform grouped binary by module selector"
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
        bash "$ORCH_SCRIPT" --paid-beta-rc --sha=aabbccddee00112233445566778899aabbccddee --billing-month=2026-03 --staging-smoke-api-ami-id=ami-12345678 --staging-smoke-flapjack-ami-id=ami-87654321

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

test_paid_beta_rc_only_steps_dispatches_exact_selected_rows() {
    local tmp_dir artifact_dir cargo_args
    tmp_dir="$(mktemp -d)"
    artifact_dir="$tmp_dir/artifacts"
    cargo_args="$tmp_dir/cargo_args.log"
    mkdir -p "$tmp_dir/bin" "$artifact_dir"

    write_mock_script "$tmp_dir/mock_cargo.sh" '
set -euo pipefail
args="$*"
if [ -n "${TIER1_CARGO_ARGS_LOG:-}" ]; then
    echo "$args" >> "$TIER1_CARGO_ARGS_LOG"
fi
case "$args" in
    "test --workspace")
        echo "cargo_workspace_tests should not run in filtered RC mode" >&2
        exit 91 ;;
    *"--test auth_admin admin_broadcast_test::"*|*"--test platform pg_customer_repo_test::"*|*"--test platform tenants_test::"*|*"--test auth_admin admin_audit_view_test::"*|*"--test auth_admin admin_token_audit_test::"*)
        echo "running 1 test"
        echo "test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out"
        exit 0 ;;
esac
echo "unexpected cargo command: $args" >&2
exit 92'
    write_mock_script "$tmp_dir/mock_backend_gate.sh" 'echo "backend_launch_gate should not run in filtered RC mode" >&2; exit 93'
    write_mock_script "$tmp_dir/mock_local_signoff.sh" 'echo "local_signoff should not run in filtered RC mode" >&2; exit 94'
    write_mock_script "$tmp_dir/mock_ses.sh" 'echo "ses_readiness should not run in filtered RC mode" >&2; exit 95'
    write_mock_script "$tmp_dir/mock_billing.sh" 'echo "staging_billing_rehearsal should not run in filtered RC mode" >&2; exit 96'
    write_mock_script "$tmp_dir/mock_browser_preflight.sh" 'echo "browser_preflight should not run in filtered RC mode" >&2; exit 97'
    write_mock_script "$tmp_dir/mock_tf_static_stage7.sh" 'echo "terraform_static_guardrails should not run in filtered RC mode" >&2; exit 98'
    write_mock_script "$tmp_dir/mock_tf_static_stage8.sh" 'echo "terraform_static_guardrails should not run in filtered RC mode" >&2; exit 98'
    write_mock_script "$tmp_dir/mock_runtime_smoke.sh" 'echo "staging_runtime_smoke should not run in filtered RC mode" >&2; exit 99'
    write_mock_script "$tmp_dir/mock_canary_outside_aws.sh" 'echo "canary_outside_aws should not run in filtered RC mode" >&2; exit 100'
    write_mock_script "$tmp_dir/mock_ses_inbound_roundtrip.sh" 'echo "ses_inbound should not run in filtered RC mode" >&2; exit 101'
    write_mock_script "$tmp_dir/mock_canary_customer_loop.sh" 'echo "canary_customer_loop should not run in filtered RC mode" >&2; exit 102'
    write_mock_script "$tmp_dir/bin/npx" '
set -euo pipefail
echo "playwright setup invoked base=${BASE_URL:-} api=${API_URL:-}: $*"
exit 0'

    run_orchestrator env \
        TIER1_CARGO_ARGS_LOG="$cargo_args" \
        PATH="$tmp_dir/bin:$PATH" \
        STAGING_CLOUD_URL="https://cloud.staging.flapjack.foo" \
        STAGING_API_URL="https://api.staging.flapjack.foo" \
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
        bash "$ORCH_SCRIPT" --paid-beta-rc --artifact-dir="$artifact_dir" --sha=aabbccddee00112233445566778899aabbccddee --billing-month=2026-03 --staging-smoke-api-ami-id=ami-12345678 --staging-smoke-flapjack-ami-id=ami-87654321 --only-steps=admin_broadcast,billing_health_last_activity,audit_timeline,browser_auth_setup

    assert_eq "$RUN_EXIT_CODE" "0" "filtered four-step RC run should pass when selected runners pass"
    assert_valid_json "$RUN_STDOUT" "filtered four-step RC run should emit valid JSON"
    assert_eq "$(json_step_names_csv "$RUN_STDOUT")" "admin_broadcast,billing_health_last_activity,audit_timeline,browser_auth_setup" "filtered RC run should emit exactly the requested summary rows in order"
    assert_eq "$(json_step_status "$RUN_STDOUT" "admin_broadcast")" "pass" "filtered admin_broadcast should use the existing rust runner"
    assert_eq "$(json_step_status "$RUN_STDOUT" "billing_health_last_activity")" "pass" "filtered billing_health_last_activity should use the existing rust runner"
    assert_eq "$(json_step_status "$RUN_STDOUT" "audit_timeline")" "pass" "filtered audit_timeline should use the existing rust runner"
    assert_eq "$(json_step_status "$RUN_STDOUT" "browser_auth_setup")" "pass" "filtered browser_auth_setup should use the existing Playwright setup runner"
    assert_artifact_log_exists "$artifact_dir" "admin_broadcast"
    assert_artifact_log_exists "$artifact_dir" "billing_health_last_activity"
    assert_artifact_log_exists "$artifact_dir" "audit_timeline"
    assert_artifact_log_exists "$artifact_dir" "browser_auth_setup"
    assert_contains "$(cat "$artifact_dir/browser_auth_setup.log" 2>/dev/null || true)" "base=https://cloud.staging.flapjack.foo api=https://api.staging.flapjack.foo" "browser_auth_setup should target the hydrated staging URLs, not ambient/local defaults"
    assert_file_exists "$artifact_dir/summary.json" "filtered RC run should keep using coordinator summary.json writer"
    cargo_args="$(cat "$cargo_args" 2>/dev/null || true)"
    assert_not_contains "$cargo_args" "test --workspace" "filtered RC run should suppress cargo_workspace_tests prelude"

    rm -rf "$tmp_dir"
}

test_paid_beta_rc_only_steps_rejects_unknown_name_before_dispatch() {
    local tmp_dir artifact_dir cargo_args
    tmp_dir="$(mktemp -d)"
    artifact_dir="$tmp_dir/artifacts"
    cargo_args="$tmp_dir/cargo_args.log"
    mkdir -p "$tmp_dir/bin" "$artifact_dir"

    write_mock_script "$tmp_dir/mock_cargo.sh" 'echo "$*" >> "$TIER1_CARGO_ARGS_LOG"; exit 91'
    write_mock_script "$tmp_dir/mock_backend_gate.sh" 'echo "backend_launch_gate should not run for invalid only-steps" >&2; exit 92'

    run_orchestrator env \
        TIER1_CARGO_ARGS_LOG="$cargo_args" \
        PATH="$tmp_dir/bin:$PATH" \
        FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
        FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
        bash "$ORCH_SCRIPT" --paid-beta-rc --artifact-dir="$artifact_dir" --sha=aabbccddee00112233445566778899aabbccddee --billing-month=2026-03 --staging-smoke-api-ami-id=ami-12345678 --staging-smoke-flapjack-ami-id=ami-87654321 --only-steps=not_a_real_step

    assert_ne "$RUN_EXIT_CODE" "0" "unknown only-steps value should fail before dispatch"
    assert_contains "$RUN_STDERR" "not_a_real_step" "unknown only-steps failure should report the invalid name"
    assert_eq "$(cat "$cargo_args" 2>/dev/null || true)" "" "unknown only-steps should reject before cargo dispatch"
    assert_not_contains "$RUN_STDOUT" "\"name\":" "unknown only-steps should not emit step rows"

    rm -rf "$tmp_dir"
}

test_paid_beta_rc_only_steps_rejects_duplicate_names_before_dispatch() {
    local tmp_dir artifact_dir cargo_args
    tmp_dir="$(mktemp -d)"
    artifact_dir="$tmp_dir/artifacts"
    cargo_args="$tmp_dir/cargo_args.log"
    mkdir -p "$tmp_dir/bin" "$artifact_dir"

    write_mock_script "$tmp_dir/mock_cargo.sh" 'echo "$*" >> "$TIER1_CARGO_ARGS_LOG"; exit 91'
    write_mock_script "$tmp_dir/mock_backend_gate.sh" 'echo "backend_launch_gate should not run for duplicate only-steps" >&2; exit 92'

    run_orchestrator env \
        TIER1_CARGO_ARGS_LOG="$cargo_args" \
        PATH="$tmp_dir/bin:$PATH" \
        FULL_VALIDATION_CARGO_BIN="$tmp_dir/mock_cargo.sh" \
        FULL_VALIDATION_BACKEND_GATE_SCRIPT="$tmp_dir/mock_backend_gate.sh" \
        bash "$ORCH_SCRIPT" --paid-beta-rc --artifact-dir="$artifact_dir" --sha=aabbccddee00112233445566778899aabbccddee --billing-month=2026-03 --staging-smoke-api-ami-id=ami-12345678 --staging-smoke-flapjack-ami-id=ami-87654321 --only-steps=admin_broadcast,admin_broadcast

    assert_ne "$RUN_EXIT_CODE" "0" "duplicate only-steps value should fail before dispatch"
    assert_contains "$RUN_STDERR" "duplicate" "duplicate only-steps failure should report the repeated name"
    assert_contains "$RUN_STDERR" "admin_broadcast" "duplicate only-steps failure should name the offending step"
    assert_eq "$(cat "$cargo_args" 2>/dev/null || true)" "" "duplicate only-steps should reject before cargo dispatch"
    assert_not_contains "$RUN_STDOUT" "\"name\":" "duplicate only-steps should not emit step rows"

    rm -rf "$tmp_dir"
}

test_paid_beta_rc_browser_auth_setup_fails_closed_without_staging_targets() {
    local tmp_dir artifact_dir npx_marker
    tmp_dir="$(mktemp -d)"
    artifact_dir="$tmp_dir/artifacts"
    npx_marker="$tmp_dir/npx_invoked"
    mkdir -p "$tmp_dir/bin" "$artifact_dir"

    # Mock npx records any invocation so we can prove Playwright never ran
    # against ambient/local defaults when staging targets are absent.
    write_mock_script "$tmp_dir/bin/npx" '
set -euo pipefail
echo "invoked base=${BASE_URL:-} api=${API_URL:-}" >> "$NPX_INVOKED_MARKER"
exit 0'

    # STAGING_CLOUD_URL / STAGING_API_URL are deliberately unset while ambient
    # BASE_URL / API_URL / API_BASE_URL point at localhost — the exact false-green
    # trap: the staging proof must refuse rather than certify localhost.
    run_orchestrator env \
        PATH="$tmp_dir/bin:$PATH" \
        NPX_INVOKED_MARKER="$npx_marker" \
        BASE_URL="http://127.0.0.1:5173" \
        API_URL="http://127.0.0.1:3001" \
        API_BASE_URL="http://127.0.0.1:3001" \
        bash "$ORCH_SCRIPT" --paid-beta-rc --artifact-dir="$artifact_dir" --sha=aabbccddee00112233445566778899aabbccddee --billing-month=2026-03 --staging-smoke-api-ami-id=ami-12345678 --staging-smoke-flapjack-ami-id=ami-87654321 --only-steps=browser_auth_setup

    assert_ne "$RUN_EXIT_CODE" "0" "browser_auth_setup must fail closed when staging targets are not hydrated"
    assert_ne "$(json_step_status "$RUN_STDOUT" "browser_auth_setup")" "pass" "browser_auth_setup must not report pass against ambient/local targets"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "browser_auth_setup")" "browser_auth_setup_staging_target_missing" "browser_auth_setup should record the staging-target-missing refusal reason"
    assert_eq "$(cat "$npx_marker" 2>/dev/null || true)" "" "browser_auth_setup must not invoke Playwright against local defaults"

    rm -rf "$tmp_dir"
}

test_paid_beta_rc_tier1_live_evidence_gap_and_browser_promotion() {
    local tmp_dir credential_env_file
    tmp_dir="$(mktemp -d)"
    credential_env_file="$tmp_dir/credential.env"
    mkdir -p "$tmp_dir/bin"
    cat > "$credential_env_file" <<'EOF'
SES_FROM_ADDRESS=ops@example.com
SES_REGION=us-east-1
FLAPJACK_ADMIN_KEY=admin-test-key
STRIPE_TEST_SECRET_KEY=sk_test_123
EOF

    write_mock_script "$tmp_dir/mock_cargo.sh" 'exit 0'
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
if [ -n "${MOCK_CANARY_CUSTOMER_LOOP_OUTPUT:-}" ]; then
    printf "%s\n" "$MOCK_CANARY_CUSTOMER_LOOP_OUTPUT"
fi
exit "${MOCK_CANARY_CUSTOMER_LOOP_EXIT_CODE:-0}"'
    write_mock_script "$tmp_dir/bin/npx" 'exit 0'

    run_orchestrator env \
        SES_FROM_ADDRESS="ops@example.com" \
        SES_REGION="us-east-1" \
        ADMIN_KEY="admin-test-key" \
        STRIPE_SECRET_KEY="sk_test_123" \
        STAGING_CLOUD_URL="https://cloud.staging.flapjack.foo" \
        STAGING_API_URL="https://api.staging.flapjack.foo" \
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
        bash "$ORCH_SCRIPT" --paid-beta-rc --credential-env-file="$credential_env_file" --sha=aabbccddee00112233445566778899aabbccddee --billing-month=2026-03 --staging-smoke-api-ami-id=ami-12345678 --staging-smoke-flapjack-ami-id=ami-87654321

    rm -rf "$tmp_dir"

    assert_eq "$(json_step_status "$RUN_STDOUT" "ses_inbound")" "pass" "ses_inbound should report pass when inputs exist and delegated roundtrip owner succeeds"
    assert_eq "$(json_step_status "$RUN_STDOUT" "canary_customer_loop")" "pass" "canary_customer_loop should report pass when inputs exist and delegated canary owner succeeds"
    assert_eq "$(json_step_status "$RUN_STDOUT" "test_clock")" "pass" "test_clock should pass in paid-beta-rc readiness mode"
    assert_eq "$(json_step_status "$RUN_STDOUT" "browser_signup_paid")" "pass" "browser_signup_paid should pass when delegated browser lane succeeds"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "browser_signup_paid")" "" "browser_signup_paid should not expose placeholder critical skip reason"
    assert_eq "$(json_step_status "$RUN_STDOUT" "browser_portal_cancel")" "pass" "browser_portal_cancel should pass when delegated browser lane succeeds"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "browser_portal_cancel")" "" "browser_portal_cancel should not expose placeholder critical skip reason"
    assert_json_bool_field "$RUN_STDOUT" "ready" "true" "paid-beta-rc should report ready=true when Tier-1 registry proofs pass"
    assert_eq "$(json_step_count "$RUN_STDOUT")" "22" "paid-beta-rc should preserve Stage 1 plus Tier-1 registry cardinality"
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
        bash "$ORCH_SCRIPT" --paid-beta-rc --credential-env-file="$credential_env_file" --sha=aabbccddee00112233445566778899aabbccddee --billing-month=2026-03 --staging-smoke-api-ami-id=ami-12345678 --staging-smoke-flapjack-ami-id=ami-87654321

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
if [ -n "${MOCK_CANARY_CUSTOMER_LOOP_OUTPUT:-}" ]; then
    printf "%s\n" "$MOCK_CANARY_CUSTOMER_LOOP_OUTPUT"
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
            bash "$ORCH_SCRIPT" --paid-beta-rc --sha=aabbccddee00112233445566778899aabbccddee --billing-month=2026-03 --staging-smoke-api-ami-id=ami-12345678 --staging-smoke-flapjack-ami-id=ami-87654321
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
        bash "$ORCH_SCRIPT" --paid-beta-rc --sha=aabbccddee00112233445566778899aabbccddee --billing-month=2026-03 --staging-smoke-api-ami-id=ami-12345678 --staging-smoke-flapjack-ami-id=ami-87654321
    assert_eq "$(json_step_status "$RUN_STDOUT" "canary_customer_loop")" "fail" "canary_customer_loop non-zero exit should map to fail"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "canary_customer_loop")" "canary_customer_loop_failed" "canary_customer_loop non-zero exit should map to deterministic reason"

    run_orchestrator env \
        SES_FROM_ADDRESS="ops@example.com" \
        SES_REGION="us-east-1" \
        ADMIN_KEY="admin-test-key" \
        STRIPE_SECRET_KEY="sk_test_123" \
        MOCK_SES_INBOUND_EXIT_CODE="0" \
        MOCK_CANARY_CUSTOMER_LOOP_EXIT_CODE="100" \
        MOCK_CANARY_CUSTOMER_LOOP_OUTPUT="SKIPPED: probe_env_gap_aws_credentials_invalid: aws sts get-caller-identity failed; creds present but rejected by AWS" \
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
        bash "$ORCH_SCRIPT" --paid-beta-rc --sha=aabbccddee00112233445566778899aabbccddee --billing-month=2026-03 --staging-smoke-api-ami-id=ami-12345678 --staging-smoke-flapjack-ami-id=ami-87654321
    assert_eq "$(json_step_status "$RUN_STDOUT" "canary_customer_loop")" "skip" "canary_customer_loop exit 100 should map to canonical skip"
    assert_eq "$(json_step_reason "$RUN_STDOUT" "canary_customer_loop")" "probe_env_gap_aws_credentials_invalid" "canary_customer_loop exit 100 should preserve canonical skip token"

    rm -rf "$tmp_dir"
}

echo "=== full backend validation tier1 registry tests ==="
test_list_paid_beta_steps_matches_registry_owner
test_paid_beta_rc_rust_steps_target_integration_binary
test_paid_beta_rc_tier1_registry_and_missing_secret_classification
test_paid_beta_rc_only_steps_dispatches_exact_selected_rows
test_paid_beta_rc_only_steps_rejects_unknown_name_before_dispatch
test_paid_beta_rc_only_steps_rejects_duplicate_names_before_dispatch
test_paid_beta_rc_browser_auth_setup_fails_closed_without_staging_targets
test_paid_beta_rc_tier1_live_evidence_gap_and_browser_promotion
test_paid_beta_rc_canary_customer_loop_reads_credential_env_file
test_paid_beta_rc_delegated_tier1_exit_code_mappings
run_test_summary
