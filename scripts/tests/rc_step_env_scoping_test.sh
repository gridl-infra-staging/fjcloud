#!/usr/bin/env bash
# Red-first RC coordinator step env-scoping KATs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/launch/invoke_rc_with_env.sh"

# shellcheck source=lib/invoke_rc_with_env_harness.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/invoke_rc_with_env_harness.sh"

SCOPING_HOST_REPO_ROOT="$REPO_ROOT"

reset_scoping_env() {
    unset DATABASE_URL INTEGRATION_DB_URL API_URL API_BASE_URL STAGING_API_URL
    unset ADMIN_KEY FLAPJACK_ADMIN_KEY E2E_ADMIN_KEY STRIPE_SECRET_KEY STRIPE_TEST_SECRET_KEY
}

write_step_credentials_env() {
    local path="$1"
    cat > "$path" <<'ENVFILE'
AWS_ACCESS_KEY_ID=AKIASTEPENVSCOPING
AWS_SECRET_ACCESS_KEY=fixture-secret
AWS_DEFAULT_REGION=us-east-1
STRIPE_SECRET_KEY_RESTRICTED=sk_test_wrapper_contract
STRIPE_WEBHOOK_SECRET=whsec_wrapper_contract
ENVFILE
}

write_step_credentials_env_with_database_url() {
    local path="$1"
    cat > "$path" <<'ENVFILE'
AWS_ACCESS_KEY_ID=AKIASTEPENVSCOPING
AWS_SECRET_ACCESS_KEY=fixture-secret
AWS_DEFAULT_REGION=us-east-1
STRIPE_SECRET_KEY_RESTRICTED=sk_test_wrapper_contract
STRIPE_WEBHOOK_SECRET=whsec_wrapper_contract
DATABASE_URL=postgres://credential-file-db/fjcloud_test
ENVFILE
}

prepare_direct_coordinator_workspace() {
    setup_workspace
    reset_scoping_env
    export PATH="$TEST_WORKSPACE/bin:/usr/bin:/bin:/usr/local/bin"
    mkdir -p "$TEST_WORKSPACE/infra" \
        "$TEST_WORKSPACE/web/node_modules/@playwright/test" \
        "$TEST_WORKSPACE/scripts/canary" \
        "$TEST_WORKSPACE/ops/terraform"
    printf '{}\n' > "$TEST_WORKSPACE/web/node_modules/@playwright/test/package.json"
    source_rc_coordinator_functions
    # shellcheck disable=SC1091
    source "$TEST_WORKSPACE/scripts/lib/rc_invocation.sh"
    ARTIFACT_DIR="$TEST_WORKSPACE/artifacts"
    CREDENTIAL_ENV_FILE="$TEST_WORKSPACE/inputs/credentials.env"
    BILLING_MONTH="2026-06"
    STAGING_SMOKE_API_AMI_ID="ami-0123456789abcdef0"
    STAGING_SMOKE_FLAPJACK_AMI_ID="ami-0fedcba9876543210"
    write_step_credentials_env "$CREDENTIAL_ENV_FILE"
}

test_paid_beta_rc_rust_step_does_not_inherit_poisoned_parent_database_url() {
    prepare_direct_coordinator_workspace
    local capture_path capture_quoted command
    capture_path="$TEST_WORKSPACE/tmp/rust_step_env.txt"
    printf -v capture_quoted '%q' "$capture_path"

    export DATABASE_URL="postgres://staging-internal.invalid:5432/x"
    unset INTEGRATION_DB_URL

    # Reuse the wrapper credential parser exactly as the facade does before
    # delegating into run_full_backend_validation.sh.
    rc_load_credential_env_file "$CREDENTIAL_ENV_FILE"

    command="printf 'DATABASE_URL=%s\n' \"\${DATABASE_URL-<unset>}\" > $capture_quoted; printf 'INTEGRATION_DB_URL=%s\n' \"\${INTEGRATION_DB_URL-<unset>}\" >> $capture_quoted"
    run_paid_beta_rc_rust_step "admin_broadcast" "admin_broadcast_failed" "1" "$command"

    assert_capture_var_eq "$capture_path" "DATABASE_URL" "<unset>" "run_paid_beta_rc_rust_step-class cargo invocation should not inherit poisoned parent DATABASE_URL"
    assert_capture_var_eq "$capture_path" "INTEGRATION_DB_URL" "<unset>" "run_paid_beta_rc_rust_step-class cargo invocation should keep absent INTEGRATION_DB_URL unset"
}

test_paid_beta_rc_rust_step_restores_credential_file_database_url() {
    prepare_direct_coordinator_workspace
    write_step_credentials_env_with_database_url "$CREDENTIAL_ENV_FILE"
    local capture_path capture_quoted command
    capture_path="$TEST_WORKSPACE/tmp/rust_step_credential_db_env.txt"
    printf -v capture_quoted '%q' "$capture_path"

    export DATABASE_URL="postgres://staging-internal.invalid:5432/x"
    rc_load_credential_env_file "$CREDENTIAL_ENV_FILE"
    export DATABASE_URL="postgres://staging-internal.invalid:5432/x"

    command="printf 'DATABASE_URL=%s\n' \"\${DATABASE_URL-<unset>}\" > $capture_quoted"
    run_paid_beta_rc_rust_step "admin_broadcast" "admin_broadcast_failed" "1" "$command"

    assert_capture_var_eq "$capture_path" "DATABASE_URL" "postgres://credential-file-db/fjcloud_test" "run_paid_beta_rc_rust_step should restore credential-file DATABASE_URL after wrapper staging hydration"
}

test_paid_beta_rc_rust_step_preserves_local_harness_database_url() {
    prepare_direct_coordinator_workspace
    local capture_path capture_quoted command
    capture_path="$TEST_WORKSPACE/tmp/rust_step_local_db_env.txt"
    printf -v capture_quoted '%q' "$capture_path"

    export DATABASE_URL="postgres://local-harness-db/fjcloud_test"
    rc_load_credential_env_file "$CREDENTIAL_ENV_FILE"

    command="printf 'DATABASE_URL=%s\n' \"\${DATABASE_URL-<unset>}\" > $capture_quoted"
    run_paid_beta_rc_rust_step "admin_broadcast" "admin_broadcast_failed" "1" "$command"

    assert_capture_var_eq "$capture_path" "DATABASE_URL" "postgres://local-harness-db/fjcloud_test" "run_paid_beta_rc_rust_step should preserve intentional local harness DATABASE_URL"
}

test_browser_auth_setup_does_not_pass_hydrated_remote_api_url_to_local_webserver_env() {
    prepare_direct_coordinator_workspace
    local capture_path
    capture_path="$TEST_WORKSPACE/tmp/browser_auth_env.txt"
    write_env_capture_command "$TEST_WORKSPACE/bin/npx" "browser_auth_setup" "$capture_path" \
        BASE_URL API_URL API_BASE_URL STAGING_API_URL E2E_ADMIN_KEY PLAYWRIGHT_TARGET_REMOTE

    export API_URL="https://staging-api.invalid"
    export STAGING_API_URL="https://staging-api.invalid"
    export STAGING_CLOUD_URL="https://cloud.staging.invalid"
    export E2E_ADMIN_KEY="admin_wrapper_contract"

    run_step_browser_auth_setup

    assert_capture_var_eq "$capture_path" "BASE_URL" "https://cloud.staging.invalid" "browser auth setup should target the hydrated staging cloud URL"
    assert_capture_var_eq "$capture_path" "API_URL" "https://staging-api.invalid" "browser auth setup should target the hydrated staging API URL"
    assert_capture_var_eq "$capture_path" "API_BASE_URL" "https://staging-api.invalid" "browser auth setup should align API_BASE_URL with the hydrated staging API URL"
    assert_capture_var_eq "$capture_path" "E2E_ADMIN_KEY" "admin_wrapper_contract" "browser auth setup should preserve wrapper-provided E2E_ADMIN_KEY"
    assert_capture_var_eq "$capture_path" "PLAYWRIGHT_TARGET_REMOTE" "1" "browser auth setup should keep the explicit remote-target Playwright marker"
}

test_staging_targeting_steps_keep_hydrated_staging_env() {
    prepare_direct_coordinator_workspace
    local billing_capture canary_capture smoke_capture
    billing_capture="$TEST_WORKSPACE/tmp/staging_billing_env.txt"
    canary_capture="$TEST_WORKSPACE/tmp/canary_loop_env.txt"
    smoke_capture="$TEST_WORKSPACE/tmp/staging_runtime_smoke_env.txt"

    write_env_capture_command "$TEST_WORKSPACE/scripts/staging_billing_rehearsal.sh" "staging_billing_rehearsal" "$billing_capture" \
        API_URL STAGING_API_URL ADMIN_KEY DATABASE_URL
    write_env_capture_command "$TEST_WORKSPACE/scripts/canary/customer_loop_synthetic.sh" "canary_customer_loop" "$canary_capture" \
        API_URL STAGING_API_URL ADMIN_KEY STRIPE_SECRET_KEY DATABASE_URL CANARY_RC_READINESS_MODE
    write_env_capture_command "$TEST_WORKSPACE/ops/terraform/tests_stage7_runtime_smoke.sh" "staging_runtime_smoke" "$smoke_capture" \
        API_URL STAGING_API_URL ADMIN_KEY DATABASE_URL

    export API_URL="https://staging-api.invalid"
    export STAGING_API_URL="https://staging-api.invalid"
    export ADMIN_KEY="hydrated_admin_key"
    export STRIPE_SECRET_KEY="sk_test_hydrated_staging"
    export DATABASE_URL="postgres://staging-internal.invalid:5432/x"

    run_step_staging_billing_rehearsal
    run_step_paid_beta_rc_canary_customer_loop
    build_staging_runtime_smoke_command
    run_delegated_command_step "staging_runtime_smoke" "staging_runtime_smoke_failed" "" "${STEP_COMMAND[@]}"

    assert_capture_var_eq "$billing_capture" "API_URL" "https://staging-api.invalid" "staging billing rehearsal should keep hydrated API_URL"
    assert_capture_var_eq "$billing_capture" "ADMIN_KEY" "hydrated_admin_key" "staging billing rehearsal should keep hydrated ADMIN_KEY"
    assert_capture_var_eq "$canary_capture" "ADMIN_KEY" "hydrated_admin_key" "canary customer loop should keep hydrated ADMIN_KEY"
    assert_capture_var_eq "$canary_capture" "STRIPE_SECRET_KEY" "sk_test_hydrated_staging" "canary customer loop should keep hydrated STRIPE_SECRET_KEY"
    assert_capture_var_eq "$canary_capture" "CANARY_RC_READINESS_MODE" "1" "canary customer loop should set RC readiness mode"
    assert_capture_var_eq "$smoke_capture" "API_URL" "https://staging-api.invalid" "staging runtime smoke should keep hydrated API_URL"
    assert_capture_var_eq "$smoke_capture" "DATABASE_URL" "postgres://staging-internal.invalid:5432/x" "staging runtime smoke should keep hydrated DATABASE_URL"
}

test_paid_beta_rc_rust_step_does_not_inherit_poisoned_parent_database_url
test_paid_beta_rc_rust_step_restores_credential_file_database_url
test_paid_beta_rc_rust_step_preserves_local_harness_database_url
test_browser_auth_setup_does_not_pass_hydrated_remote_api_url_to_local_webserver_env
test_staging_targeting_steps_keep_hydrated_staging_env

REPO_ROOT="$SCOPING_HOST_REPO_ROOT"
run_test_summary
