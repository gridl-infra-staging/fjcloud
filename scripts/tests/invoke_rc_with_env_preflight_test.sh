#!/usr/bin/env bash
# Red-first preflight contract tests for scripts/launch/invoke_rc_with_env.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/launch/invoke_rc_with_env.sh"

# shellcheck source=lib/invoke_rc_with_env_harness.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/invoke_rc_with_env_harness.sh"

invoke_rc_with_env_after_setup() {
    install_present_vite_stub
}

write_long_lived_credentials_env() {
    local path="$1" access_key="$2"
    cat > "$path" <<ENVFILE
AWS_ACCESS_KEY_ID=$access_key
AWS_SECRET_ACCESS_KEY=fixture-secret
AWS_DEFAULT_REGION=us-east-1
STRIPE_SECRET_KEY_RESTRICTED=sk_test_wrapper_contract
STRIPE_WEBHOOK_SECRET=whsec_wrapper_contract
ENVFILE
}

write_billing_preflight_credentials_env() {
    local path="$1"
    cat > "$path" <<'ENVFILE'
AWS_ACCESS_KEY_ID=GOODFILEKEY
AWS_SECRET_ACCESS_KEY=fixture-secret
AWS_DEFAULT_REGION=us-east-1
STAGING_API_URL=https://staging-api.example.test
STAGING_STRIPE_WEBHOOK_URL=https://staging-api.example.test/webhooks/stripe
STRIPE_SECRET_KEY=sk_test_wrapper_contract
STRIPE_WEBHOOK_SECRET=whsec_wrapper_contract
ADMIN_KEY=credential-admin-key
DATABASE_URL=postgres://credential-db
INTEGRATION_DB_URL=postgres://credential-integration-db
MAILPIT_API_URL=https://mailpit.example.test
SES_REGION=us-east-1
REHEARSAL_SES_SEND_EVENTS_LOG_GROUP=/fjcloud/staging/ses/send-events
REHEARSAL_SES_LOOKBACK_MINUTES=30
ENVFILE
}

assert_refusal_classification() {
    local refusal_path="$1" expected="$2" msg="$3"
    local actual
    if [ ! -f "$refusal_path" ]; then
        fail "$msg (missing '$refusal_path')"
        return
    fi
    actual="$(python3 - "$refusal_path" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    print(json.load(fh).get("classification", ""))
PY
)"
    assert_eq "$actual" "$expected" "$msg"
}

assert_manifest_status() {
    local manifest_path="$1" var_name="$2" expected="$3" msg="$4"
    local actual
    actual="$(python3 - "$manifest_path" "$var_name" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)
print(payload.get("env", {}).get(sys.argv[2], ""))
PY
)"
    assert_eq "$actual" "$expected" "$msg"
}

test_loader_unsets_ambient_session_token_before_file_backed_sts_probe() {
    setup_workspace
    write_aws_sts_mock
    local credential_file sts_calls
    credential_file="$TEST_WORKSPACE/inputs/credentials.env"
    write_long_lived_credentials_env "$credential_file" "GOODFILEKEY"
    add_facade_env "AWS_ACCESS_KEY_ID=BADAMBIENTKEY"
    add_facade_env "AWS_SECRET_ACCESS_KEY=bad-ambient-secret"
    add_facade_env "AWS_SESSION_TOKEN=STALESESSIONTOKEN"
    add_facade_env "AWS_ID_MOCK_MODE=key_gated"
    add_facade_env "AWS_ID_MOCK_GOOD_KEY=GOODFILEKEY"

    run_rc_loader_child "$credential_file"
    sts_calls="$(grep '^aws|sts get-caller-identity|' "$TEST_CALL_LOG" || true)"

    assert_eq "$RUN_LOADER_EXIT_CODE" "0" "credential loader should recover to the file-backed long-lived key before STS"
    assert_contains "$RUN_LOADER_STDOUT" "AWS_ACCESS_KEY_ID=GOODFILEKEY" "loader child should export the file-backed access key"
    assert_contains "$RUN_LOADER_STDOUT" "AWS_SESSION_TOKEN=<unset>" "loader child should unset stale ambient session token"
    assert_eq "$sts_calls" "aws|sts get-caller-identity|key=GOODFILEKEY|session=" "STS mock should see exactly the file-backed long-lived key with no session token"
    assert_not_contains "$sts_calls" "key=BADAMBIENTKEY" "STS mock must not see the polluted ambient access key"
    assert_not_contains "$sts_calls" "session=STALESESSIONTOKEN" "STS mock must not see the stale ambient session token"
}

test_invalid_sts_identity_refuses_before_coordinator_delegation() {
    setup_workspace
    write_aws_sts_mock
    local credential_file refusal_path section1_manifest
    credential_file="$TEST_WORKSPACE/inputs/credentials.env"
    refusal_path="$TEST_WORKSPACE/artifacts/preflight_refusal.json"
    section1_manifest="$TEST_WORKSPACE/section1_bundle/manifest.json"
    write_long_lived_credentials_env "$credential_file" "REJECTEDFILEKEY"
    write_section1_manifest "$section1_manifest" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "2026-06"
    add_facade_env "AWS_ID_MOCK_MODE=invalid"

    _run_facade \
        --sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        --artifact-dir="$TEST_WORKSPACE/artifacts" \
        --credential-env-file="$credential_file" \
        --billing-month=2026-06 \
        --section1-manifest="$section1_manifest" \
        --staging-smoke-api-ami-id=ami-0123456789abcdef0 --staging-smoke-flapjack-ami-id=ami-0fedcba9876543210

    assert_eq "$RUN_EXIT_CODE" "3" "invalid STS identity should refuse the RC wrapper with exit 3"
    assert_refusal_classification "$refusal_path" "credential_invalid" "invalid STS identity refusal should write credential_invalid classification"
    assert_call_log_absent '^run_full_backend_validation\|' "invalid STS identity should not delegate to the RC coordinator"
}

test_missing_browser_admin_key_refuses_before_coordinator_delegation() {
    setup_workspace
    write_aws_sts_mock
    local credential_file refusal_path section1_manifest
    credential_file="$TEST_WORKSPACE/inputs/credentials.env"
    refusal_path="$TEST_WORKSPACE/artifacts/preflight_refusal.json"
    section1_manifest="$TEST_WORKSPACE/section1_bundle/manifest.json"
    write_long_lived_credentials_env "$credential_file" "GOODFILEKEY"
    write_section1_manifest "$section1_manifest" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "2026-06"
    add_facade_env "AWS_ID_MOCK_MODE=success"

    _run_facade \
        --sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        --artifact-dir="$TEST_WORKSPACE/artifacts" \
        --credential-env-file="$credential_file" \
        --billing-month=2026-06 \
        --section1-manifest="$section1_manifest" \
        --staging-smoke-api-ami-id=ami-0123456789abcdef0 --staging-smoke-flapjack-ami-id=ami-0fedcba9876543210

    assert_eq "$RUN_EXIT_CODE" "3" "missing ADMIN_KEY/E2E_ADMIN_KEY should refuse the RC wrapper with exit 3"
    assert_refusal_classification "$refusal_path" "browser_env_gap" "missing browser-critical admin key should write browser_env_gap classification"
    assert_call_log_absent '^run_full_backend_validation\|' "missing browser-critical admin key should not delegate to the RC coordinator"
}

test_only_steps_passthrough_reaches_coordinator_dry_run() {
    setup_workspace
    install_successful_wrapper_preflight_stubs
    local credential_file only_steps section1_manifest
    credential_file="$TEST_WORKSPACE/inputs/credentials.env"
    section1_manifest="$TEST_WORKSPACE/section1_bundle/manifest.json"
    only_steps="admin_broadcast,billing_health_last_activity,audit_timeline,browser_auth_setup"
    write_long_lived_credentials_env "$credential_file" "GOODFILEKEY"
    write_section1_manifest "$section1_manifest" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "2026-06"

    _run_facade \
        --dry-run \
        --sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        --artifact-dir="$TEST_WORKSPACE/artifacts" \
        --credential-env-file="$credential_file" \
        --billing-month=2026-06 \
        --staging-smoke-api-ami-id=ami-0123456789abcdef0 --staging-smoke-flapjack-ami-id=ami-0fedcba9876543210 \
        --section1-manifest="$section1_manifest" \
        "--only-steps=$only_steps"

    assert_eq "$RUN_EXIT_CODE" "0" "filtered dry-run should pass wrapper preflight"
    assert_contains "$RUN_STDOUT" "scripts/launch/run_full_backend_validation.sh" "dry-run should print coordinator delegation command"
    assert_contains "$RUN_STDOUT" "--paid-beta-rc" "dry-run should preserve paid-beta RC mode"
    assert_contains "$RUN_STDOUT" "--only-steps=admin_broadcast\\,billing_health_last_activity\\,audit_timeline\\,browser_auth_setup" "wrapper should forward exact only-steps CSV without local registry validation"
    assert_call_log_absent '^run_full_backend_validation\|' "dry-run should not execute the coordinator"
}

test_billing_preflight_probe_runs_after_wrapper_preflight_without_coordinator_delegation() {
    setup_workspace
    install_successful_wrapper_preflight_stubs
    local credential_file manifest_path calls section1_manifest
    credential_file="$TEST_WORKSPACE/inputs/billing_preflight.env"
    manifest_path="$TEST_WORKSPACE/artifacts/billing_preflight_input_manifest.json"
    section1_manifest="$TEST_WORKSPACE/section1_bundle/manifest.json"
    write_billing_preflight_credentials_env "$credential_file"
    write_section1_manifest "$section1_manifest" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "2026-06"
    add_facade_env "REHEARSAL_SES_CLOUDWATCH_LIMIT=50"

    _run_facade \
        --billing-preflight-check \
        --sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        --artifact-dir="$TEST_WORKSPACE/artifacts" \
        --credential-env-file="$credential_file" \
        --billing-month=2026-06 \
        --staging-smoke-api-ami-id=ami-0123456789abcdef0 --staging-smoke-flapjack-ami-id=ami-0fedcba9876543210 \
        --section1-manifest="$section1_manifest" \
        --input-manifest="$manifest_path"

    calls="$(cat "$TEST_CALL_LOG")"
    assert_eq "$RUN_EXIT_CODE" "0" "billing preflight probe should pass when wrapper preflight and dry-run owner pass"
    assert_contains "$calls" "aws|sts get-caller-identity" "billing preflight probe should run credential preflight"
    assert_contains "$calls" "curl|" "billing preflight probe should run browser readiness check"
    assert_contains "$calls" "staging_billing_dry_run|--check --env-file $credential_file" \
        "billing preflight probe should delegate check-mode billing validation to staging_billing_dry_run.sh"
    assert_call_log_absent '^run_full_backend_validation\|' "billing preflight probe must not delegate to the RC coordinator"
    assert_valid_json "$(cat "$manifest_path")" "billing preflight manifest should be valid JSON"
    assert_contains "$(cat "$manifest_path")" '"argv"' "billing preflight manifest should record argv"
    assert_manifest_status "$manifest_path" "STAGING_API_URL" "set" "manifest should record STAGING_API_URL presence only"
    assert_manifest_status "$manifest_path" "MAILPIT_API_URL" "set" "manifest should record MAILPIT_API_URL presence only"
    assert_manifest_status "$manifest_path" "REHEARSAL_SES_CLOUDWATCH_LIMIT" "set" "manifest should include set REHEARSAL_SES_* names"
    assert_not_contains "$(cat "$manifest_path")" "sk_test_wrapper_contract" "manifest must not contain Stripe secret values"
    assert_not_contains "$(cat "$manifest_path")" "credential-admin-key" "manifest must not contain admin key values"
    assert_not_contains "$(cat "$manifest_path")" "postgres://credential-db" "manifest must not contain database URLs"
}

test_loader_unsets_ambient_session_token_before_file_backed_sts_probe
test_invalid_sts_identity_refuses_before_coordinator_delegation
test_missing_browser_admin_key_refuses_before_coordinator_delegation
test_only_steps_passthrough_reaches_coordinator_dry_run
test_billing_preflight_probe_runs_after_wrapper_preflight_without_coordinator_delegation

run_test_summary
