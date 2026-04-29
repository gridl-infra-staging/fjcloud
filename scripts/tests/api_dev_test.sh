#!/usr/bin/env bash
# Tests for scripts/api-dev.sh: env-loading safety and startup behavior.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "FAIL: $*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/local_dev_test_state.sh
source "$SCRIPT_DIR/lib/local_dev_test_state.sh"
# shellcheck source=lib/test_helpers.sh
source "$SCRIPT_DIR/lib/test_helpers.sh"

write_mock_lsof_reports_free() {
    local path="$1"
    write_mock_script "$path" 'exit 1'
}

test_api_dev_rejects_executable_env_local_content() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_path "'"$REPO_ROOT/.env.local"'" "${API_DEV_ENV_BACKUP:-}"; rm -rf "'"$tmp_dir"'"' RETURN

    local marker_path="$tmp_dir/should-not-exist"
    API_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    cat > "$REPO_ROOT/.env.local" <<EOF
DATABASE_URL=postgres://local-test:local-pass@localhost:5432/local_dev_test
LISTEN_ADDR=0.0.0.0:3001
touch "$marker_path"
EOF

    mkdir -p "$tmp_dir/bin"
    write_mock_script "$tmp_dir/bin/cargo" 'exit 0'
    write_mock_lsof_reports_free "$tmp_dir/bin/lsof"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        bash "$REPO_ROOT/scripts/api-dev.sh" 2>&1
    ) || exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        pass "should reject executable shell syntax in .env.local"
    else
        fail "should reject executable shell syntax in .env.local (expected non-zero exit)"
    fi
    assert_contains "$output" "Unsupported syntax" \
        "should explain that only KEY=value assignments are accepted from .env.local"

    if [ -e "$marker_path" ]; then
        fail "should not execute shell commands from .env.local"
    else
        pass "should not execute shell commands from .env.local"
    fi
}

test_api_dev_preserves_explicit_flapjack_admin_key() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_path "'"$REPO_ROOT/.env.local"'" "${API_DEV_ENV_BACKUP:-}"; rm -rf "'"$tmp_dir"'"' RETURN

    API_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    cat > "$REPO_ROOT/.env.local" <<'EOF'
DATABASE_URL=postgres://local-test:local-pass@localhost:5432/local_dev_test
FLAPJACK_ADMIN_KEY=file-admin-key
EOF

    mkdir -p "$tmp_dir/bin"
    local cargo_log="$tmp_dir/cargo.log"
    write_mock_script "$tmp_dir/bin/cargo" '
echo "FLAPJACK_ADMIN_KEY=${FLAPJACK_ADMIN_KEY:-}" >> "'"$cargo_log"'"
exit 0'
    write_mock_lsof_reports_free "$tmp_dir/bin/lsof"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_ADMIN_KEY="explicit-admin-key" \
        bash "$REPO_ROOT/scripts/api-dev.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should start successfully when an explicit FLAPJACK_ADMIN_KEY override is set"

    local cargo_calls
    cargo_calls=$(cat "$cargo_log" 2>/dev/null || true)
    assert_contains "$cargo_calls" "FLAPJACK_ADMIN_KEY=explicit-admin-key" \
        "should preserve explicit FLAPJACK_ADMIN_KEY over .env.local values"
}

test_api_dev_defaults_replication_orchestrator_to_effectively_disabled() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_path "'"$REPO_ROOT/.env.local"'" "${API_DEV_ENV_BACKUP:-}"; rm -rf "'"$tmp_dir"'"' RETURN

    API_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    cat > "$REPO_ROOT/.env.local" <<'EOF'
DATABASE_URL=postgres://local-test:local-pass@localhost:5432/local_dev_test
NODE_SECRET_BACKEND=memory
EOF

    mkdir -p "$tmp_dir/bin"
    local cargo_log="$tmp_dir/cargo.log"
    write_mock_script "$tmp_dir/bin/cargo" '
echo "REPLICATION_CYCLE_INTERVAL_SECS=${REPLICATION_CYCLE_INTERVAL_SECS:-}" >> "'"$cargo_log"'"
exit 0'
    write_mock_lsof_reports_free "$tmp_dir/bin/lsof"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        bash "$REPO_ROOT/scripts/api-dev.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" \
        "api-dev should start with local replication defaults"

    local cargo_calls
    cargo_calls=$(cat "$cargo_log" 2>/dev/null || true)
    assert_contains "$cargo_calls" "REPLICATION_CYCLE_INTERVAL_SECS=999999" \
        "api-dev should effectively disable replication orchestration by default"
}

test_api_dev_preserves_explicit_replication_cycle_interval() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_path "'"$REPO_ROOT/.env.local"'" "${API_DEV_ENV_BACKUP:-}"; rm -rf "'"$tmp_dir"'"' RETURN

    API_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    cat > "$REPO_ROOT/.env.local" <<'EOF'
DATABASE_URL=postgres://local-test:local-pass@localhost:5432/local_dev_test
REPLICATION_CYCLE_INTERVAL_SECS=120
EOF

    mkdir -p "$tmp_dir/bin"
    local cargo_log="$tmp_dir/cargo.log"
    write_mock_script "$tmp_dir/bin/cargo" '
echo "REPLICATION_CYCLE_INTERVAL_SECS=${REPLICATION_CYCLE_INTERVAL_SECS:-}" >> "'"$cargo_log"'"
exit 0'
    write_mock_lsof_reports_free "$tmp_dir/bin/lsof"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        REPLICATION_CYCLE_INTERVAL_SECS=45 \
        bash "$REPO_ROOT/scripts/api-dev.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" \
        "api-dev should start with explicit replication interval"

    local cargo_calls
    cargo_calls=$(cat "$cargo_log" 2>/dev/null || true)
    assert_contains "$cargo_calls" "REPLICATION_CYCLE_INTERVAL_SECS=45" \
        "api-dev should preserve explicit replication interval overrides"
}

test_api_dev_unsets_skip_email_verification_by_default() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_path "'"$REPO_ROOT/.env.local"'" "${API_DEV_ENV_BACKUP:-}"; rm -rf "'"$tmp_dir"'"' RETURN

    API_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    cat > "$REPO_ROOT/.env.local" <<'EOF'
DATABASE_URL=postgres://local-test:local-pass@localhost:5432/local_dev_test
LISTEN_ADDR=127.0.0.1:4311
SKIP_EMAIL_VERIFICATION=1
EOF

    mkdir -p "$tmp_dir/bin"
    local cargo_log="$tmp_dir/cargo.log"
    write_mock_script "$tmp_dir/bin/cargo" '
echo "SKIP_EMAIL_VERIFICATION=${SKIP_EMAIL_VERIFICATION:-}" >> "'"$cargo_log"'"
exit 0'
    write_mock_lsof_reports_free "$tmp_dir/bin/lsof"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        bash "$REPO_ROOT/scripts/api-dev.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" \
        "api-dev should start when SKIP_EMAIL_VERIFICATION is set in .env.local"

    local cargo_calls
    cargo_calls=$(cat "$cargo_log" 2>/dev/null || true)
    assert_contains "$cargo_calls" "SKIP_EMAIL_VERIFICATION=" \
        "api-dev should pass an explicit empty SKIP_EMAIL_VERIFICATION by default"
    assert_not_contains "$cargo_calls" "SKIP_EMAIL_VERIFICATION=1" \
        "api-dev should disable SKIP_EMAIL_VERIFICATION by default for strict local proofs"
}

test_api_dev_preserves_skip_email_verification_with_explicit_opt_in() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_path "'"$REPO_ROOT/.env.local"'" "${API_DEV_ENV_BACKUP:-}"; rm -rf "'"$tmp_dir"'"' RETURN

    API_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    cat > "$REPO_ROOT/.env.local" <<'EOF'
DATABASE_URL=postgres://local-test:local-pass@localhost:5432/local_dev_test
LISTEN_ADDR=127.0.0.1:4312
SKIP_EMAIL_VERIFICATION=1
EOF

    mkdir -p "$tmp_dir/bin"
    local cargo_log="$tmp_dir/cargo.log"
    write_mock_script "$tmp_dir/bin/cargo" '
echo "SKIP_EMAIL_VERIFICATION=${SKIP_EMAIL_VERIFICATION:-}" >> "'"$cargo_log"'"
exit 0'
    write_mock_lsof_reports_free "$tmp_dir/bin/lsof"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_DEV_ALLOW_SKIP_EMAIL_VERIFICATION=1 \
        bash "$REPO_ROOT/scripts/api-dev.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" \
        "api-dev should start when skip-email-verification opt-in is set"

    local cargo_calls
    cargo_calls=$(cat "$cargo_log" 2>/dev/null || true)
    assert_contains "$cargo_calls" "SKIP_EMAIL_VERIFICATION=1" \
        "api-dev should preserve SKIP_EMAIL_VERIFICATION when explicitly opted in"
}

test_api_dev_fails_fast_when_listen_port_is_in_use() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_path "'"$REPO_ROOT/.env.local"'" "${API_DEV_ENV_BACKUP:-}"; rm -rf "'"$tmp_dir"'"' RETURN

    API_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    cat > "$REPO_ROOT/.env.local" <<'EOF'
DATABASE_URL=postgres://local-test:local-pass@localhost:5432/local_dev_test
LISTEN_ADDR=127.0.0.1:4313
EOF

    mkdir -p "$tmp_dir/bin"
    local cargo_log="$tmp_dir/cargo.log"
    write_mock_script "$tmp_dir/bin/cargo" '
echo "cargo should not run when listen port is occupied" >> "'"$cargo_log"'"
exit 0'
    write_mock_script "$tmp_dir/bin/lsof" '
if [ "${1:-}" = "-i" ] && [ "${2:-}" = ":4313" ]; then
    exit 0
fi
exit 1'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        bash "$REPO_ROOT/scripts/api-dev.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" \
        "api-dev should fail fast when LISTEN_ADDR is already occupied"
    assert_contains "$output" "port 4313 is already in use" \
        "api-dev should report the occupied LISTEN_ADDR port"

    local cargo_calls
    cargo_calls=$(cat "$cargo_log" 2>/dev/null || true)
    assert_eq "$cargo_calls" "" \
        "api-dev should not invoke cargo when listen port availability checks fail"
}

test_api_dev_prefers_mailpit_over_ses_by_default() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_path "'"$REPO_ROOT/.env.local"'" "${API_DEV_ENV_BACKUP:-}"; rm -rf "'"$tmp_dir"'"' RETURN

    API_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    cat > "$REPO_ROOT/.env.local" <<'EOF'
DATABASE_URL=postgres://local-test:local-pass@localhost:5432/local_dev_test
LISTEN_ADDR=127.0.0.1:4314
MAILPIT_API_URL=http://localhost:8025
SES_FROM_ADDRESS=system@flapjack.foo
SES_REGION=us-east-1
EOF

    mkdir -p "$tmp_dir/bin"
    local cargo_log="$tmp_dir/cargo.log"
    write_mock_script "$tmp_dir/bin/cargo" '
echo "MAILPIT_API_URL=${MAILPIT_API_URL:-}" >> "'"$cargo_log"'"
echo "SES_FROM_ADDRESS=${SES_FROM_ADDRESS:-}" >> "'"$cargo_log"'"
echo "SES_REGION=${SES_REGION:-}" >> "'"$cargo_log"'"
exit 0'
    write_mock_lsof_reports_free "$tmp_dir/bin/lsof"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        bash "$REPO_ROOT/scripts/api-dev.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" \
        "api-dev should start when both Mailpit and SES env vars are present"

    local cargo_calls
    cargo_calls=$(cat "$cargo_log" 2>/dev/null || true)
    assert_contains "$cargo_calls" "MAILPIT_API_URL=http://localhost:8025" \
        "api-dev should preserve MAILPIT_API_URL for local verification flows"
    assert_contains "$cargo_calls" "SES_FROM_ADDRESS=" \
        "api-dev should clear SES_FROM_ADDRESS by default when Mailpit is configured"
    assert_contains "$cargo_calls" "SES_REGION=" \
        "api-dev should clear SES_REGION by default when Mailpit is configured"
    assert_not_contains "$cargo_calls" "SES_FROM_ADDRESS=system@flapjack.foo" \
        "api-dev should avoid SES mode by default in local Mailpit workflows"
    assert_not_contains "$cargo_calls" "SES_REGION=us-east-1" \
        "api-dev should avoid SES mode by default in local Mailpit workflows"
}

test_api_dev_preserves_ses_with_explicit_opt_in() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_path "'"$REPO_ROOT/.env.local"'" "${API_DEV_ENV_BACKUP:-}"; rm -rf "'"$tmp_dir"'"' RETURN

    API_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    cat > "$REPO_ROOT/.env.local" <<'EOF'
DATABASE_URL=postgres://local-test:local-pass@localhost:5432/local_dev_test
LISTEN_ADDR=127.0.0.1:4315
MAILPIT_API_URL=http://localhost:8025
SES_FROM_ADDRESS=system@flapjack.foo
SES_REGION=us-east-1
EOF

    mkdir -p "$tmp_dir/bin"
    local cargo_log="$tmp_dir/cargo.log"
    write_mock_script "$tmp_dir/bin/cargo" '
echo "SES_FROM_ADDRESS=${SES_FROM_ADDRESS:-}" >> "'"$cargo_log"'"
echo "SES_REGION=${SES_REGION:-}" >> "'"$cargo_log"'"
exit 0'
    write_mock_lsof_reports_free "$tmp_dir/bin/lsof"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_DEV_ALLOW_SES_EMAIL=1 \
        bash "$REPO_ROOT/scripts/api-dev.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" \
        "api-dev should start when SES opt-in is set"

    local cargo_calls
    cargo_calls=$(cat "$cargo_log" 2>/dev/null || true)
    assert_contains "$cargo_calls" "SES_FROM_ADDRESS=system@flapjack.foo" \
        "api-dev should preserve SES_FROM_ADDRESS when explicit SES opt-in is set"
    assert_contains "$cargo_calls" "SES_REGION=us-east-1" \
        "api-dev should preserve SES_REGION when explicit SES opt-in is set"
}

test_api_dev_defaults_to_local_stripe_mode_even_with_live_keys_present() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_path "'"$REPO_ROOT/.env.local"'" "${API_DEV_ENV_BACKUP:-}"; rm -rf "'"$tmp_dir"'"' RETURN

    API_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    cat > "$REPO_ROOT/.env.local" <<'EOF'
DATABASE_URL=postgres://local-test:local-pass@localhost:5432/local_dev_test
LISTEN_ADDR=127.0.0.1:4316
STRIPE_SECRET_KEY=sk_test_stage_lane_contract
STRIPE_PUBLISHABLE_KEY=pk_test_stage_lane_contract
EOF

    mkdir -p "$tmp_dir/bin"
    local cargo_log="$tmp_dir/cargo.log"
    write_mock_script "$tmp_dir/bin/cargo" '
echo "STRIPE_LOCAL_MODE=${STRIPE_LOCAL_MODE:-}" >> "'"$cargo_log"'"
echo "STRIPE_SECRET_KEY=${STRIPE_SECRET_KEY:-}" >> "'"$cargo_log"'"
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
        "api-dev should start with local-stripe defaults when live keys are present in .env.local"

    local cargo_calls
    cargo_calls=$(cat "$cargo_log" 2>/dev/null || true)
    assert_contains "$cargo_calls" "STRIPE_LOCAL_MODE=1" \
        "api-dev should enable STRIPE_LOCAL_MODE by default for local proof lanes"
    assert_contains "$cargo_calls" "STRIPE_SECRET_KEY=" \
        "api-dev should clear STRIPE_SECRET_KEY by default so API startup uses local stripe service"
    assert_contains "$cargo_calls" "STRIPE_PUBLISHABLE_KEY=" \
        "api-dev should clear STRIPE_PUBLISHABLE_KEY by default alongside STRIPE_SECRET_KEY"
    assert_contains "$cargo_calls" "STRIPE_WEBHOOK_SECRET=whsec_local_dev_secret" \
        "api-dev should provide a deterministic local webhook secret when defaulting to local stripe mode"
    assert_not_contains "$cargo_calls" "STRIPE_SECRET_KEY=sk_test_stage_lane_contract" \
        "api-dev should not keep live stripe secrets active unless explicitly opted in"
}

test_api_dev_preserves_live_stripe_keys_with_explicit_opt_in() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_path "'"$REPO_ROOT/.env.local"'" "${API_DEV_ENV_BACKUP:-}"; rm -rf "'"$tmp_dir"'"' RETURN

    API_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    cat > "$REPO_ROOT/.env.local" <<'EOF'
DATABASE_URL=postgres://local-test:local-pass@localhost:5432/local_dev_test
LISTEN_ADDR=127.0.0.1:4317
STRIPE_LOCAL_MODE=1
STRIPE_SECRET_KEY=sk_test_stage_lane_contract
STRIPE_PUBLISHABLE_KEY=pk_test_stage_lane_contract
STRIPE_WEBHOOK_SECRET=whsec_stage_lane_contract
EOF

    mkdir -p "$tmp_dir/bin"
    local cargo_log="$tmp_dir/cargo.log"
    write_mock_script "$tmp_dir/bin/cargo" '
echo "STRIPE_LOCAL_MODE=${STRIPE_LOCAL_MODE:-}" >> "'"$cargo_log"'"
echo "STRIPE_SECRET_KEY=${STRIPE_SECRET_KEY:-}" >> "'"$cargo_log"'"
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
        API_DEV_ALLOW_LIVE_STRIPE=1 \
        bash "$REPO_ROOT/scripts/api-dev.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" \
        "api-dev should start when explicit live-stripe opt-in is set"

    local cargo_calls
    cargo_calls=$(cat "$cargo_log" 2>/dev/null || true)
    assert_contains "$cargo_calls" "STRIPE_LOCAL_MODE=" \
        "api-dev should clear STRIPE_LOCAL_MODE when explicit live-stripe opt-in is set"
    assert_not_contains "$cargo_calls" "STRIPE_LOCAL_MODE=1" \
        "api-dev should not leave local-stripe mode enabled when live-stripe opt-in is set"
    assert_contains "$cargo_calls" "STRIPE_SECRET_KEY=sk_test_stage_lane_contract" \
        "api-dev should preserve STRIPE_SECRET_KEY when live-stripe opt-in is set"
    assert_contains "$cargo_calls" "STRIPE_PUBLISHABLE_KEY=pk_test_stage_lane_contract" \
        "api-dev should preserve STRIPE_PUBLISHABLE_KEY when live-stripe opt-in is set"
    assert_contains "$cargo_calls" "STRIPE_WEBHOOK_SECRET=whsec_stage_lane_contract" \
        "api-dev should preserve explicit webhook secret when live-stripe opt-in is set"
}

test_api_dev_live_stripe_opt_in_prefers_env_local_key_over_inherited_key() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_path "'"$REPO_ROOT/.env.local"'" "${API_DEV_ENV_BACKUP:-}"; rm -rf "'"$tmp_dir"'"' RETURN

    API_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    cat > "$REPO_ROOT/.env.local" <<'EOF'
DATABASE_URL=postgres://local-test:local-pass@localhost:5432/local_dev_test
LISTEN_ADDR=127.0.0.1:4318
STRIPE_SECRET_KEY=sk_test_from_env_local
STRIPE_PUBLISHABLE_KEY=pk_test_from_env_local
STRIPE_WEBHOOK_SECRET=whsec_from_env_local
EOF

    mkdir -p "$tmp_dir/bin"
    local cargo_log="$tmp_dir/cargo.log"
    write_mock_script "$tmp_dir/bin/cargo" '
echo "STRIPE_LOCAL_MODE=${STRIPE_LOCAL_MODE:-}" >> "'"$cargo_log"'"
echo "STRIPE_SECRET_KEY=${STRIPE_SECRET_KEY:-}" >> "'"$cargo_log"'"
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
        API_DEV_ALLOW_LIVE_STRIPE=1 \
        STRIPE_SECRET_KEY=sk_test_inherited_stale_key \
        STRIPE_PUBLISHABLE_KEY=pk_test_inherited_stale_key \
        STRIPE_WEBHOOK_SECRET=whsec_inherited_stale_key \
        bash "$REPO_ROOT/scripts/api-dev.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" \
        "api-dev should start when live-stripe opt-in is set with inherited Stripe env keys"

    local cargo_calls
    cargo_calls=$(cat "$cargo_log" 2>/dev/null || true)
    assert_contains "$cargo_calls" "STRIPE_LOCAL_MODE=" \
        "api-dev live-stripe opt-in should clear inherited STRIPE_LOCAL_MODE before launching the API"
    assert_not_contains "$cargo_calls" "STRIPE_LOCAL_MODE=1" \
        "api-dev live-stripe opt-in should not inherit stale STRIPE_LOCAL_MODE=1 into the API runtime"
    assert_contains "$cargo_calls" "STRIPE_SECRET_KEY=sk_test_from_env_local" \
        "api-dev live-stripe opt-in should prefer STRIPE_SECRET_KEY from .env.local over inherited shell exports"
    assert_contains "$cargo_calls" "STRIPE_PUBLISHABLE_KEY=pk_test_from_env_local" \
        "api-dev live-stripe opt-in should prefer STRIPE_PUBLISHABLE_KEY from .env.local over inherited shell exports"
    assert_contains "$cargo_calls" "STRIPE_WEBHOOK_SECRET=whsec_from_env_local" \
        "api-dev live-stripe opt-in should prefer STRIPE_WEBHOOK_SECRET from .env.local over inherited shell exports"
    assert_not_contains "$cargo_calls" "STRIPE_SECRET_KEY=sk_test_inherited_stale_key" \
        "api-dev live-stripe opt-in should not leak inherited stale STRIPE_SECRET_KEY into API runtime"
}

test_api_dev_live_stripe_opt_in_prefers_env_local_test_key_over_inherited_secret_key() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_path "'"$REPO_ROOT/.env.local"'" "${API_DEV_ENV_BACKUP:-}"; rm -rf "'"$tmp_dir"'"' RETURN

    API_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    cat > "$REPO_ROOT/.env.local" <<'EOF'
DATABASE_URL=postgres://local-test:local-pass@localhost:5432/local_dev_test
LISTEN_ADDR=127.0.0.1:43185
STRIPE_TEST_SECRET_KEY=sk_test_from_env_local_alias
EOF

    mkdir -p "$tmp_dir/bin"
    local cargo_log="$tmp_dir/cargo.log"
    write_mock_script "$tmp_dir/bin/cargo" '
echo "STRIPE_SECRET_KEY=${STRIPE_SECRET_KEY:-}" >> "'"$cargo_log"'"
echo "STRIPE_TEST_SECRET_KEY=${STRIPE_TEST_SECRET_KEY:-}" >> "'"$cargo_log"'"
exit 0'
    write_mock_lsof_reports_free "$tmp_dir/bin/lsof"
    write_mock_script "$tmp_dir/bin/curl" '
printf "%s\n" "{\"object\":\"balance\",\"available\":[]}"
printf "200\n"
exit 0'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_DEV_ALLOW_LIVE_STRIPE=1 \
        STRIPE_SECRET_KEY=sk_live_inherited_stale_key \
        bash "$REPO_ROOT/scripts/api-dev.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" \
        "api-dev should let .env.local STRIPE_TEST_SECRET_KEY win over inherited STRIPE_SECRET_KEY during live-stripe opt-in"

    local cargo_calls
    cargo_calls=$(cat "$cargo_log" 2>/dev/null || true)
    assert_contains "$cargo_calls" "STRIPE_SECRET_KEY=" \
        "api-dev should clear inherited STRIPE_SECRET_KEY when only STRIPE_TEST_SECRET_KEY is defined in .env.local"
    assert_not_contains "$cargo_calls" "STRIPE_SECRET_KEY=sk_live_inherited_stale_key" \
        "api-dev should not leak inherited canonical Stripe secrets when .env.local only defines the alias key"
    assert_contains "$cargo_calls" "STRIPE_TEST_SECRET_KEY=sk_test_from_env_local_alias" \
        "api-dev should preserve STRIPE_TEST_SECRET_KEY from .env.local for live-stripe validation"
}

test_api_dev_live_stripe_opt_in_empty_env_local_secret_clears_inherited_secret() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_path "'"$REPO_ROOT/.env.local"'" "${API_DEV_ENV_BACKUP:-}"; rm -rf "'"$tmp_dir"'"' RETURN

    API_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    cat > "$REPO_ROOT/.env.local" <<'EOF'
DATABASE_URL=postgres://local-test:local-pass@localhost:5432/local_dev_test
LISTEN_ADDR=127.0.0.1:43186
STRIPE_SECRET_KEY=
EOF

    mkdir -p "$tmp_dir/bin"
    local cargo_log="$tmp_dir/cargo.log"
    write_mock_script "$tmp_dir/bin/cargo" '
echo "cargo should not run when .env.local explicitly clears STRIPE_SECRET_KEY" >> "'"$cargo_log"'"
exit 0'
    write_mock_lsof_reports_free "$tmp_dir/bin/lsof"
    write_mock_script "$tmp_dir/bin/curl" '
printf "%s\n" "{\"error\":{\"type\":\"authentication_error\",\"message\":\"should not be called\"}}"
printf "401\n"
exit 0'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_DEV_ALLOW_LIVE_STRIPE=1 \
        STRIPE_SECRET_KEY=sk_test_inherited_stale_key \
        bash "$REPO_ROOT/scripts/api-dev.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" \
        "api-dev should fail closed when .env.local explicitly clears STRIPE_SECRET_KEY during live-stripe opt-in"
    assert_contains "$output" "REASON: stripe_key_unset" \
        "api-dev should report the missing runtime Stripe key instead of reusing an inherited secret"

    local cargo_calls
    cargo_calls=$(cat "$cargo_log" 2>/dev/null || true)
    assert_eq "$cargo_calls" "" \
        "api-dev should not invoke cargo after .env.local clears the live-stripe secret"
}

test_api_dev_live_stripe_opt_in_rejects_invalid_runtime_key_before_launch() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_path "'"$REPO_ROOT/.env.local"'" "${API_DEV_ENV_BACKUP:-}"; rm -rf "'"$tmp_dir"'"' RETURN

    API_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    cat > "$REPO_ROOT/.env.local" <<'EOF'
DATABASE_URL=postgres://local-test:local-pass@localhost:5432/local_dev_test
LISTEN_ADDR=127.0.0.1:4319
STRIPE_SECRET_KEY=sk_test_invalid_runtime_key
EOF

    mkdir -p "$tmp_dir/bin"
    local cargo_log="$tmp_dir/cargo.log"
    write_mock_script "$tmp_dir/bin/cargo" '
echo "cargo should not run when stripe key authentication fails" >> "'"$cargo_log"'"
exit 0'
    write_mock_lsof_reports_free "$tmp_dir/bin/lsof"
    write_mock_script "$tmp_dir/bin/curl" '
printf "%s\n" "{\"error\":{\"type\":\"authentication_error\",\"message\":\"Invalid API Key provided\"}}"
printf "401\n"
exit 0'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_DEV_ALLOW_LIVE_STRIPE=1 \
        bash "$REPO_ROOT/scripts/api-dev.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" \
        "api-dev should fail fast when live-stripe opt-in key cannot authenticate with Stripe"
    assert_contains "$output" "REASON: stripe_auth_failed" \
        "api-dev should surface Stripe auth failures before launching the API in live-stripe mode"

    local cargo_calls
    cargo_calls=$(cat "$cargo_log" 2>/dev/null || true)
    assert_eq "$cargo_calls" "" \
        "api-dev should not invoke cargo when live-stripe key validation fails"
}

main() {
    echo "=== api-dev.sh tests ==="
    echo ""

    test_api_dev_rejects_executable_env_local_content
    test_api_dev_preserves_explicit_flapjack_admin_key
    test_api_dev_defaults_replication_orchestrator_to_effectively_disabled
    test_api_dev_preserves_explicit_replication_cycle_interval
    test_api_dev_unsets_skip_email_verification_by_default
    test_api_dev_preserves_skip_email_verification_with_explicit_opt_in
    test_api_dev_fails_fast_when_listen_port_is_in_use
    test_api_dev_prefers_mailpit_over_ses_by_default
    test_api_dev_preserves_ses_with_explicit_opt_in
    test_api_dev_defaults_to_local_stripe_mode_even_with_live_keys_present
    test_api_dev_preserves_live_stripe_keys_with_explicit_opt_in
    test_api_dev_live_stripe_opt_in_prefers_env_local_key_over_inherited_key
    test_api_dev_live_stripe_opt_in_prefers_env_local_test_key_over_inherited_secret_key
    test_api_dev_live_stripe_opt_in_empty_env_local_secret_clears_inherited_secret
    test_api_dev_live_stripe_opt_in_rejects_invalid_runtime_key_before_launch

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
