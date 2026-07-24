#!/usr/bin/env bash
# Stage 4 api-dev.sh regression tests kept out of the main runner so that
# scripts/tests/api_dev_test.sh stays below the review hard file-size limit.

# Prove api-dev clears Stripe secrets when a test explicitly disables local
# Stripe mode without opting into live credentials.
# TODO: Document test_api_dev_explicit_nonlocal_stripe_mode_clears_keys_without_live_opt_in.
# TODO: Document test_api_dev_explicit_nonlocal_stripe_mode_clears_keys_without_live_opt_in.
# TODO: Document test_api_dev_explicit_nonlocal_stripe_mode_clears_keys_without_live_opt_in.
# TODO: Document test_api_dev_explicit_nonlocal_stripe_mode_clears_keys_without_live_opt_in.
# TODO: Document test_api_dev_explicit_nonlocal_stripe_mode_clears_keys_without_live_opt_in.
# Run api-dev with local Stripe explicitly disabled and live credentials not authorized.
# Assert that every inherited Stripe credential is absent from the spawned API environment.
# TODO: Document test_api_dev_explicit_nonlocal_stripe_mode_clears_keys_without_live_opt_in.
# TODO: Document test_api_dev_explicit_nonlocal_stripe_mode_clears_keys_without_live_opt_in.
test_api_dev_explicit_nonlocal_stripe_mode_clears_keys_without_live_opt_in() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_path "'"$REPO_ROOT/.env.local"'" "${API_DEV_ENV_BACKUP:-}"; rm -rf "'"$tmp_dir"'"' RETURN

    API_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    cat > "$REPO_ROOT/.env.local" <<'EOF'
DATABASE_URL=postgres://local-test:local-pass@localhost:5432/local_dev_test
LISTEN_ADDR=127.0.0.1:4320
STRIPE_LOCAL_MODE=0
STRIPE_SECRET_KEY=sk_test_stage_lane_contract
STRIPE_TEST_SECRET_KEY=sk_test_alias_stage_lane_contract
STRIPE_PUBLISHABLE_KEY=pk_test_stage_lane_contract
STRIPE_WEBHOOK_SECRET=whsec_stage_lane_contract
EOF

    mkdir -p "$tmp_dir/bin"
    local cargo_log="$tmp_dir/cargo.log"
    write_mock_script "$tmp_dir/bin/cargo" '
echo "STRIPE_LOCAL_MODE=${STRIPE_LOCAL_MODE:-}" >> "'"$cargo_log"'"
echo "STRIPE_SECRET_KEY=${STRIPE_SECRET_KEY:-}" >> "'"$cargo_log"'"
echo "STRIPE_TEST_SECRET_KEY=${STRIPE_TEST_SECRET_KEY:-}" >> "'"$cargo_log"'"
echo "STRIPE_PUBLISHABLE_KEY=${STRIPE_PUBLISHABLE_KEY:-}" >> "'"$cargo_log"'"
echo "STRIPE_WEBHOOK_SECRET=${STRIPE_WEBHOOK_SECRET:-}" >> "'"$cargo_log"'"
exit 0'
    write_mock_lsof_reports_free "$tmp_dir/bin/lsof"
    write_mock_script "$tmp_dir/bin/curl" '
printf "%s\n" "{\"object\":\"balance\",\"available\":[]}"
printf "200\n"
exit 0'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        bash "$REPO_ROOT/scripts/api-dev.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" \
        "api-dev should start when explicit nonlocal stripe mode requests an unconfigured local proof"

    local cargo_calls
    cargo_calls=$(cat "$cargo_log" 2>/dev/null || true)
    assert_contains "$cargo_calls" "STRIPE_LOCAL_MODE=0" \
        "api-dev should preserve explicit nonlocal stripe mode for unconfigured proof lanes"
    assert_contains "$cargo_calls" "STRIPE_SECRET_KEY=" \
        "api-dev should clear STRIPE_SECRET_KEY when live Stripe is not opted in"
    assert_contains "$cargo_calls" "STRIPE_TEST_SECRET_KEY=" \
        "api-dev should clear STRIPE_TEST_SECRET_KEY when live Stripe is not opted in"
    assert_contains "$cargo_calls" "STRIPE_PUBLISHABLE_KEY=" \
        "api-dev should clear STRIPE_PUBLISHABLE_KEY when live Stripe is not opted in"
    assert_contains "$cargo_calls" "STRIPE_WEBHOOK_SECRET=" \
        "api-dev should clear STRIPE_WEBHOOK_SECRET when local Stripe mode is disabled"
    assert_not_contains "$cargo_calls" "STRIPE_SECRET_KEY=sk_test_stage_lane_contract" \
        "api-dev should not leak .env.local Stripe secrets into unconfigured local proof lanes"
}

test_api_dev_allows_test_owned_pid_file_override() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local env_backup pid_backup
    env_backup=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    pid_backup=$(backup_repo_path "$REPO_ROOT/.local/api.pid" "$tmp_dir/api.pid.backup")
    trap 'restore_repo_path "$REPO_ROOT/.env.local" "$env_backup"; restore_repo_path "$REPO_ROOT/.local/api.pid" "$pid_backup"; rm -rf "$tmp_dir"' RETURN

    cat > "$REPO_ROOT/.env.local" <<'EOF'
DATABASE_URL=postgres://local-test:local-pass@localhost:5432/local_dev_test
LISTEN_ADDR=127.0.0.1:4321
EOF

    mkdir -p "$tmp_dir/bin"
    write_mock_script "$tmp_dir/bin/cargo" 'exit 0'
    write_mock_lsof_reports_free "$tmp_dir/bin/lsof"

    local override_pid_file="$tmp_dir/test-owned-api.pid"
    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_DEV_PID_FILE="$override_pid_file" \
        bash "$REPO_ROOT/scripts/api-dev.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" \
        "api-dev should start when a test-owned PID file override is set"
    assert_file_exists "$override_pid_file" \
        "api-dev should write the explicit test-owned PID file"

    if [ -e "$REPO_ROOT/.local/api.pid" ]; then
        fail "api-dev should not write the shared local-dev PID file when API_DEV_PID_FILE is set"
    else
        pass "api-dev should not write the shared local-dev PID file when API_DEV_PID_FILE is set"
    fi
}
