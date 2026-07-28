#!/usr/bin/env bash
# api-dev.sh email-routing and verification-mode regression tests, kept out of the
# main runner so that scripts/tests/api_dev_test.sh stays below the review hard
# file-size limit. Sourced by scripts/tests/api_dev_test.sh, which owns the
# pass/fail counters, mock helpers, and the run order in main().

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
SES_CONFIGURATION_SET=fjcloud-prod
EOF

    mkdir -p "$tmp_dir/bin"
    local cargo_log="$tmp_dir/cargo.log"
    write_mock_script "$tmp_dir/bin/cargo" '
echo "MAILPIT_API_URL=${MAILPIT_API_URL:-}" >> "'"$cargo_log"'"
echo "SES_FROM_ADDRESS=${SES_FROM_ADDRESS:-}" >> "'"$cargo_log"'"
echo "SES_REGION=${SES_REGION:-}" >> "'"$cargo_log"'"
echo "SES_CONFIGURATION_SET=${SES_CONFIGURATION_SET:-}" >> "'"$cargo_log"'"
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
    assert_contains "$cargo_calls" "SES_CONFIGURATION_SET=" \
        "api-dev should clear SES_CONFIGURATION_SET by default when Mailpit is configured"
    assert_not_contains "$cargo_calls" "SES_CONFIGURATION_SET=fjcloud-prod" \
        "a leftover SES configuration set alone still forces the API into SES startup mode"
}

# Email routing keys the API reads at startup. SES_CONFIGURATION_SET is part of
# the SES startup family in infra/api/src/startup_env.rs::ses_family_state, so a
# leftover value there alone still forces SesStartupMode::Ses.
API_DEV_EMAIL_ROUTING_ENV_KEYS=(
    MAILPIT_API_URL
    ENVIRONMENT
    NODE_SECRET_BACKEND
    SES_FROM_ADDRESS
    SES_REGION
    SES_CONFIGURATION_SET
    SKIP_EMAIL_VERIFICATION
)

write_mock_cargo_dumping_email_routing_env() {
    local mock_path="$1" cargo_log="$2"
    local body="" key

    for key in "${API_DEV_EMAIL_ROUTING_ENV_KEYS[@]}"; do
        body+="echo \"${key}=\${${key}:-}\" >> \"${cargo_log}\"
"
    done

    write_mock_script "$mock_path" "${body}exit 0"
}

assert_resolved_email_routing_is_mailpit_only() {
    local cargo_calls="$1" context="$2"

    assert_contains "$cargo_calls" "MAILPIT_API_URL=http://127.0.0.1:8025" \
        "local-email-delivery mode should preserve MAILPIT_API_URL (${context})"
    assert_contains "$cargo_calls" "ENVIRONMENT=local" \
        "local-email-delivery mode should put API startup in local environment mode (${context})"
    assert_contains "$cargo_calls" "NODE_SECRET_BACKEND=memory" \
        "local-email-delivery mode should put API startup in memory node-secret mode (${context})"
    assert_contains "$cargo_calls" "SES_FROM_ADDRESS=" \
        "local-email-delivery mode should clear SES_FROM_ADDRESS (${context})"
    assert_contains "$cargo_calls" "SES_REGION=" \
        "local-email-delivery mode should clear SES_REGION (${context})"
    assert_contains "$cargo_calls" "SES_CONFIGURATION_SET=" \
        "local-email-delivery mode should clear SES_CONFIGURATION_SET (${context})"
    assert_not_contains "$cargo_calls" "SES_FROM_ADDRESS=system@flapjack.foo" \
        "local-email-delivery mode must not leave a usable SES sender (${context})"
    assert_not_contains "$cargo_calls" "SES_REGION=us-east-1" \
        "local-email-delivery mode must not leave a usable SES region (${context})"
    assert_not_contains "$cargo_calls" "SES_CONFIGURATION_SET=fjcloud-prod" \
        "local-email-delivery mode must not leave a usable SES configuration set (${context})"
    assert_not_contains "$cargo_calls" "SKIP_EMAIL_VERIFICATION=1" \
        "local-email-delivery mode must not auto-verify signups (${context})"
}

test_api_dev_local_email_delivery_mode_defaults_local_zero_dependency_startup() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_path "'"$REPO_ROOT/.env.local"'" "${API_DEV_ENV_BACKUP:-}"; rm -rf "'"$tmp_dir"'"' RETURN

    API_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    cat > "$REPO_ROOT/.env.local" <<'EOF'
DATABASE_URL=postgres://local-test:local-pass@localhost:5432/local_dev_test
LISTEN_ADDR=127.0.0.1:4326
MAILPIT_API_URL=http://127.0.0.1:8025
EOF

    mkdir -p "$tmp_dir/bin"
    local cargo_log="$tmp_dir/cargo.log"
    write_mock_cargo_dumping_email_routing_env "$tmp_dir/bin/cargo" "$cargo_log"
    write_mock_lsof_reports_free "$tmp_dir/bin/lsof"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_DEV_REQUIRE_LOCAL_EMAIL_DELIVERY=1 \
        bash "$REPO_ROOT/scripts/api-dev.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" \
        "api-dev should start in local-email-delivery mode when local-zero-dep env is absent"
    assert_resolved_email_routing_is_mailpit_only \
        "$(cat "$cargo_log" 2>/dev/null || true)" "defaulted local zero-dep mode"
}

test_api_dev_local_email_delivery_mode_rejects_nonlocal_startup_mode() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_path "'"$REPO_ROOT/.env.local"'" "${API_DEV_ENV_BACKUP:-}"; rm -rf "'"$tmp_dir"'"' RETURN

    API_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    cat > "$REPO_ROOT/.env.local" <<'EOF'
DATABASE_URL=postgres://local-test:local-pass@localhost:5432/local_dev_test
LISTEN_ADDR=127.0.0.1:4327
MAILPIT_API_URL=http://127.0.0.1:8025
ENVIRONMENT=production
NODE_SECRET_BACKEND=memory
EOF

    mkdir -p "$tmp_dir/bin"
    local cargo_log="$tmp_dir/cargo.log"
    write_mock_cargo_dumping_email_routing_env "$tmp_dir/bin/cargo" "$cargo_log"
    write_mock_lsof_reports_free "$tmp_dir/bin/lsof"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_DEV_REQUIRE_LOCAL_EMAIL_DELIVERY=1 \
        bash "$REPO_ROOT/scripts/api-dev.sh" 2>&1
    ) || exit_code=$?

    assert_ne "$exit_code" "0" \
        "local-email-delivery mode should reject production startup mode"
    assert_contains "$output" "ENVIRONMENT=local/dev/development" \
        "nonlocal startup rejection should explain the local-only contract"
    [ ! -s "$cargo_log" ] || \
        fail "local-email-delivery mode must not launch Cargo when API startup would select SES"
}

test_api_dev_local_email_delivery_mode_overrides_env_file_ses_opt_in() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_path "'"$REPO_ROOT/.env.local"'" "${API_DEV_ENV_BACKUP:-}"; rm -rf "'"$tmp_dir"'"' RETURN

    API_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    cat > "$REPO_ROOT/.env.local" <<'EOF'
DATABASE_URL=postgres://local-test:local-pass@localhost:5432/local_dev_test
LISTEN_ADDR=127.0.0.1:4321
MAILPIT_API_URL=http://127.0.0.1:8025
API_DEV_REQUIRE_LOCAL_EMAIL_DELIVERY=0
API_DEV_ALLOW_SES_EMAIL=1
API_DEV_ALLOW_SKIP_EMAIL_VERIFICATION=1
SKIP_EMAIL_VERIFICATION=1
SES_FROM_ADDRESS=system@flapjack.foo
SES_REGION=us-east-1
SES_CONFIGURATION_SET=fjcloud-prod
EOF

    mkdir -p "$tmp_dir/bin"
    local cargo_log="$tmp_dir/cargo.log"
    write_mock_cargo_dumping_email_routing_env "$tmp_dir/bin/cargo" "$cargo_log"
    write_mock_lsof_reports_free "$tmp_dir/bin/lsof"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_DEV_REQUIRE_LOCAL_EMAIL_DELIVERY=1 \
        bash "$REPO_ROOT/scripts/api-dev.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" \
        "api-dev should start in local-email-delivery mode when Mailpit is configured"
    assert_resolved_email_routing_is_mailpit_only \
        "$(cat "$cargo_log" 2>/dev/null || true)" ".env.local opt-in"
}

test_api_dev_local_email_delivery_mode_can_be_enabled_by_env_file() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_path "'"$REPO_ROOT/.env.local"'" "${API_DEV_ENV_BACKUP:-}"; rm -rf "'"$tmp_dir"'"' RETURN

    API_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    cat > "$REPO_ROOT/.env.local" <<'EOF'
DATABASE_URL=postgres://local-test:local-pass@localhost:5432/local_dev_test
LISTEN_ADDR=127.0.0.1:4324
MAILPIT_API_URL=http://127.0.0.1:8025
API_DEV_REQUIRE_LOCAL_EMAIL_DELIVERY=1
API_DEV_ALLOW_SES_EMAIL=1
API_DEV_ALLOW_SKIP_EMAIL_VERIFICATION=1
SKIP_EMAIL_VERIFICATION=1
SES_FROM_ADDRESS=system@flapjack.foo
SES_REGION=us-east-1
SES_CONFIGURATION_SET=fjcloud-prod
EOF

    mkdir -p "$tmp_dir/bin"
    local cargo_log="$tmp_dir/cargo.log"
    write_mock_cargo_dumping_email_routing_env "$tmp_dir/bin/cargo" "$cargo_log"
    write_mock_lsof_reports_free "$tmp_dir/bin/lsof"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        bash "$REPO_ROOT/scripts/api-dev.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" \
        "api-dev should start when .env.local enables local-email-delivery mode"
    assert_resolved_email_routing_is_mailpit_only \
        "$(cat "$cargo_log" 2>/dev/null || true)" ".env.local mode flag"
}

test_api_dev_local_email_delivery_mode_overrides_inherited_ses_opt_in() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_path "'"$REPO_ROOT/.env.local"'" "${API_DEV_ENV_BACKUP:-}"; rm -rf "'"$tmp_dir"'"' RETURN

    API_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    cat > "$REPO_ROOT/.env.local" <<'EOF'
DATABASE_URL=postgres://local-test:local-pass@localhost:5432/local_dev_test
LISTEN_ADDR=127.0.0.1:4322
MAILPIT_API_URL=http://127.0.0.1:8025
EOF

    mkdir -p "$tmp_dir/bin"
    local cargo_log="$tmp_dir/cargo.log"
    write_mock_cargo_dumping_email_routing_env "$tmp_dir/bin/cargo" "$cargo_log"
    write_mock_lsof_reports_free "$tmp_dir/bin/lsof"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_DEV_REQUIRE_LOCAL_EMAIL_DELIVERY=1 \
        API_DEV_ALLOW_SES_EMAIL=1 \
        API_DEV_ALLOW_SKIP_EMAIL_VERIFICATION=1 \
        SKIP_EMAIL_VERIFICATION=1 \
        SES_FROM_ADDRESS=system@flapjack.foo \
        SES_REGION=us-east-1 \
        SES_CONFIGURATION_SET=fjcloud-prod \
        bash "$REPO_ROOT/scripts/api-dev.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" \
        "api-dev should start in local-email-delivery mode with inherited SES env present"
    assert_resolved_email_routing_is_mailpit_only \
        "$(cat "$cargo_log" 2>/dev/null || true)" "inherited shell opt-in"
}

test_api_dev_local_email_delivery_mode_fails_closed_without_mailpit() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_path "'"$REPO_ROOT/.env.local"'" "${API_DEV_ENV_BACKUP:-}"; rm -rf "'"$tmp_dir"'"' RETURN

    API_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    cat > "$REPO_ROOT/.env.local" <<'EOF'
DATABASE_URL=postgres://local-test:local-pass@localhost:5432/local_dev_test
LISTEN_ADDR=127.0.0.1:4323
SES_FROM_ADDRESS=system@flapjack.foo
SES_REGION=us-east-1
EOF

    mkdir -p "$tmp_dir/bin"
    local cargo_log="$tmp_dir/cargo.log"
    write_mock_cargo_dumping_email_routing_env "$tmp_dir/bin/cargo" "$cargo_log"
    write_mock_lsof_reports_free "$tmp_dir/bin/lsof"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_DEV_REQUIRE_LOCAL_EMAIL_DELIVERY=1 \
        bash "$REPO_ROOT/scripts/api-dev.sh" 2>&1
    ) || exit_code=$?

    assert_ne "$exit_code" "0" \
        "local-email-delivery mode should fail closed when no Mailpit endpoint is configured"
    assert_contains "$output" "MAILPIT_API_URL" \
        "local-email-delivery failure should name the missing Mailpit endpoint"
    [ ! -s "$cargo_log" ] || \
        fail "local-email-delivery mode must not launch the API without a local Mailpit endpoint"
}

test_api_dev_local_email_delivery_mode_rejects_remote_mailpit_before_launch() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_path "'"$REPO_ROOT/.env.local"'" "${API_DEV_ENV_BACKUP:-}"; rm -rf "'"$tmp_dir"'"' RETURN

    API_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    cat > "$REPO_ROOT/.env.local" <<'EOF'
DATABASE_URL=postgres://local-test:local-pass@localhost:5432/local_dev_test
LISTEN_ADDR=127.0.0.1:4325
API_DEV_REQUIRE_LOCAL_EMAIL_DELIVERY=1
MAILPIT_API_URL=http://mail.example.test:8025
EOF

    mkdir -p "$tmp_dir/bin"
    local cargo_log="$tmp_dir/cargo.log"
    write_mock_cargo_dumping_email_routing_env "$tmp_dir/bin/cargo" "$cargo_log"
    write_mock_lsof_reports_free "$tmp_dir/bin/lsof"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        bash "$REPO_ROOT/scripts/api-dev.sh" 2>&1
    ) || exit_code=$?

    assert_ne "$exit_code" "0" \
        "local-email-delivery mode should fail closed when .env.local points Mailpit at a remote host"
    assert_contains "$output" "loopback HTTP MAILPIT_API_URL" \
        "remote Mailpit rejection should state the local-only URL contract"
    [ ! -s "$cargo_log" ] || \
        fail "local-email-delivery mode must reject remote Mailpit before launching Cargo"
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
