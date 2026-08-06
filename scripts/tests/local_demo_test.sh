#!/usr/bin/env bash
# Tests for scripts/local_demo.sh: safe env preparation and CLI behavior.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKOUT_REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/local_dev_test_state.sh
source "$SCRIPT_DIR/lib/local_dev_test_state.sh"

LOCAL_DEMO_SUITE_ROOT_TMP="$(mktemp -d)"
REPO_ROOT="$(create_script_fixture_repo_root "$LOCAL_DEMO_SUITE_ROOT_TMP" "$CHECKOUT_REPO_ROOT")"
trap 'rm -rf "$LOCAL_DEMO_SUITE_ROOT_TMP"' EXIT

LOCAL_DEMO_ENV_BACKUP=""

setup_repo_state() {
    local tmp_dir="$1"
    LOCAL_DEMO_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
}

restore_repo_state() {
    restore_repo_path "$REPO_ROOT/.env.local" "${LOCAL_DEMO_ENV_BACKUP:-}"
    restore_repo_path "$REPO_ROOT/.local" "${LOCAL_DEMO_LOCAL_BACKUP:-}"
    LOCAL_DEMO_ENV_BACKUP=""
    LOCAL_DEMO_LOCAL_BACKUP=""
}

setup_local_demo_launch_mocks() {
    local tmp_dir="$1"
    local mock_bin="$tmp_dir/bin"

    mkdir -p "$mock_bin"
    cat > "$mock_bin/bash" <<'EOF'
#!/bin/bash
case "${1##*/}" in
    local-dev-up.sh|web-dev.sh|seed_local.sh|dev_state_audit.sh|start-metering.sh)
        exit 0
        ;;
esac
exec /bin/bash "$@"
EOF
    cat > "$mock_bin/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    cat > "$mock_bin/lsof" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    cat > "$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    cat > "$mock_bin/env" <<'EOF'
#!/usr/bin/env bash
printf 'DATABASE_URL=%s\nLOCAL_DB_PORT=%s\n' \
    "${DATABASE_URL:-}" "${LOCAL_DB_PORT:-}" > "$LOCAL_DEMO_API_ENV_CAPTURE"
    exit 0
EOF
    chmod +x "$mock_bin/bash" "$mock_bin/docker" "$mock_bin/lsof" "$mock_bin/curl" "$mock_bin/env"
}

test_prepare_env_honors_supplied_repo_root_without_mutating_checkout_root() {
    local tmp_dir fixture_root
    tmp_dir=$(mktemp -d)
    fixture_root=$(create_local_dev_fixture_repo_root "$tmp_dir" "postgres://fixture-user:fixture-pass@localhost:5432/local_demo_fixture")
    trap 'restore_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    setup_repo_state "$tmp_dir"
    LOCAL_DEMO_LOCAL_BACKUP=$(backup_repo_path "$REPO_ROOT/.local" "$tmp_dir/.local.backup")
    cat > "$REPO_ROOT/.env.local" <<'EOF'
DATABASE_URL=postgres://checkout-user:checkout-pass@localhost:5432/local_demo_checkout
JWT_SECRET=checkout-jwt
ADMIN_KEY=checkout-admin
EOF
    mkdir -p "$REPO_ROOT/.local"
    printf 'checkout-demo-sentinel\n' > "$REPO_ROOT/.local/demo.sentinel"

    FJCLOUD_REPO_ROOT="$fixture_root" \
    bash "$REPO_ROOT/scripts/local_demo.sh" --prepare-env-only >/dev/null

    local fixture_env checkout_env
    fixture_env="$(sed -n '1,240p' "$fixture_root/.env.local")"
    checkout_env="$(sed -n '1,40p' "$REPO_ROOT/.env.local")"
    assert_contains "$fixture_env" "SKIP_EMAIL_VERIFICATION=1" \
        "prepare-env should add demo defaults to the supplied fixture root"
    assert_contains "$fixture_env" "FLAPJACK_REGIONS=us-east-1:7700 eu-west-1:7701 eu-central-1:7702" \
        "prepare-env should add multi-region defaults to the supplied fixture root"
    assert_contains "$checkout_env" "DATABASE_URL=postgres://checkout-user:checkout-pass@localhost:5432/local_demo_checkout" \
        "prepare-env should leave checkout-root .env.local unchanged when FJCLOUD_REPO_ROOT is supplied"
    assert_eq "$(cat "$REPO_ROOT/.local/demo.sentinel")" "checkout-demo-sentinel" \
        "prepare-env should leave checkout-root runtime sentinels unchanged"
}

test_prepare_env_adds_demo_defaults() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_repo_state "$tmp_dir"
    write_local_dev_env_file "$REPO_ROOT/.env.local" "postgres://local-test:local-pass@localhost:5432/local_demo_test"

    bash "$REPO_ROOT/scripts/local_demo.sh" --prepare-env-only >/dev/null

    local env_text
    env_text="$(sed -n '1,220p' "$REPO_ROOT/.env.local")"
    assert_contains "$env_text" "SKIP_EMAIL_VERIFICATION=1" "prepare-env should enable simple local signup"
    assert_contains "$env_text" "STRIPE_LOCAL_MODE=1" "prepare-env should enable offline billing"
    assert_contains "$env_text" "FLAPJACK_REGIONS=us-east-1:7700 eu-west-1:7701 eu-central-1:7702" \
        "prepare-env should enable three-region local HA"
}

test_prepare_env_preserves_existing_values() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_repo_state "$tmp_dir"
    write_local_dev_env_file "$REPO_ROOT/.env.local" "postgres://local-test:local-pass@localhost:5432/local_demo_test"
    printf '%s\n' "API_BASE_URL=http://custom-api:3001" >> "$REPO_ROOT/.env.local"

    bash "$REPO_ROOT/scripts/local_demo.sh" --prepare-env-only >/dev/null

    local api_base_count
    api_base_count="$(grep -c '^API_BASE_URL=' "$REPO_ROOT/.env.local")"
    assert_eq "$api_base_count" "1" "prepare-env should not duplicate existing keys"
    assert_contains "$(sed -n '1,220p' "$REPO_ROOT/.env.local")" \
        "API_BASE_URL=http://custom-api:3001" \
        "prepare-env should preserve existing key values"
}

test_prepare_env_preserves_existing_flapjack_dev_dir() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_repo_state "$tmp_dir"
    write_local_dev_env_file "$REPO_ROOT/.env.local" "postgres://local-test:local-pass@localhost:5432/local_demo_test"
    printf '%s\n' "FLAPJACK_DEV_DIR=/custom/flapjack/engine" >> "$REPO_ROOT/.env.local"

    bash "$REPO_ROOT/scripts/local_demo.sh" --prepare-env-only >/dev/null

    local env_text flapjack_dir_count
    env_text="$(sed -n '1,240p' "$REPO_ROOT/.env.local")"
    flapjack_dir_count="$(grep -c '^FLAPJACK_DEV_DIR=' "$REPO_ROOT/.env.local")"
    assert_eq "$flapjack_dir_count" "1" "prepare-env should not duplicate FLAPJACK_DEV_DIR"
    assert_contains "$env_text" "FLAPJACK_DEV_DIR=/custom/flapjack/engine" \
        "prepare-env should preserve an explicit local Flapjack checkout"
}

test_web_start_contract_uses_strict_exact_port() {
    local script_text
    script_text="$(sed -n '1,220p' "$REPO_ROOT/scripts/local_demo.sh")"

    assert_contains "$script_text" "check_port_available" \
        "local demo should reject an occupied web port before trusting readiness"
    assert_contains "$script_text" "--port \"\$web_port\"" \
        "local demo should pass the exact checked web port to Vite"
    assert_contains "$script_text" "--strictPort" \
        "local demo should fail instead of silently moving to another web port"
    assert_contains "$script_text" "wait_for_health \"\$web_url\" \"web\"" \
        "local demo should wait on the same web URL it asked Vite to bind"
}

# Ports must flow from env vars (LOCAL_WEB_PORT, PLAYWRIGHT_API_PORT) so a
# second worktree can run a parallel stack without colliding. Hardcoding
# the defaults inline broke this contract until 2026-05-31.
test_ports_are_env_overridable() {
    local script_text
    script_text="$(cat "$REPO_ROOT/scripts/local_demo.sh")"

    assert_contains "$script_text" 'LOCAL_WEB_PORT:-5173' \
        "local demo should honor \$LOCAL_WEB_PORT (default 5173) instead of hardcoding the port"
    assert_contains "$script_text" 'PLAYWRIGHT_API_PORT:-3001' \
        "local demo should honor \$PLAYWRIGHT_API_PORT (default 3001) instead of hardcoding the port"

    # Anti-pattern guard: catch any future regression that re-introduces a
    # bare hardcoded :3001 or :5173 outside the env-default expression.
    # `${VAR:-NNNN}` is the only allowed hardcoded form. Comment lines and
    # the documented multi-worktree override example are excluded.
    #
    # Using awk (not chained greps) because chained `grep | grep | wc` can
    # exit non-zero under `set -o pipefail` when a no-match short-circuits
    # the pipeline — masking the count and killing the test.
    local bare_api_count bare_web_count
    bare_api_count=$(awk '
        /[:"'\'']3001/ \
            && $0 !~ /:-3001\}/ \
            && $0 !~ /^[[:space:]]*#/ \
            && $0 !~ /PLAYWRIGHT_API_PORT=3101/ \
            { n++ }
        END { print n+0 }
    ' "$REPO_ROOT/scripts/local_demo.sh")
    bare_web_count=$(awk '
        /[:"'\'']5173/ \
            && $0 !~ /:-5173\}/ \
            && $0 !~ /^[[:space:]]*#/ \
            && $0 !~ /LOCAL_WEB_PORT=5273/ \
            { n++ }
        END { print n+0 }
    ' "$REPO_ROOT/scripts/local_demo.sh")
    assert_eq "$bare_api_count" "0" \
        "local demo should not hardcode 3001 outside the \${PLAYWRIGHT_API_PORT:-3001} default expression"
    assert_eq "$bare_web_count" "0" \
        "local demo should not hardcode 5173 outside the \${LOCAL_WEB_PORT:-5173} default expression"
}

# Pre-flighting the API port at the local_demo layer (not just inside
# api-dev.sh) means port collisions surface here with the
# check_port_available diagnostic, instead of being masked by a stale
# process answering /health. Anchored 2026-05-31.
test_api_port_is_preflighted_before_start() {
    local script_text
    script_text="$(cat "$REPO_ROOT/scripts/local_demo.sh")"

    assert_contains "$script_text" 'check_port_available "$api_port" "api"' \
        "local demo should check api port availability before start_tracked_process API"
}

test_api_start_exports_checked_ports_to_runtime() {
    local script_text
    script_text="$(cat "$REPO_ROOT/scripts/local_demo.sh")"

    assert_contains "$script_text" 'LISTEN_ADDR="${LISTEN_ADDR:-127.0.0.1:${api_port}}"' \
        "local demo should make the checked API port the runtime LISTEN_ADDR"
    assert_contains "$script_text" 'S3_LISTEN_ADDR="${S3_LISTEN_ADDR:-127.0.0.1:${s3_port}}"' \
        "local demo should make the checked S3 sidecar port the runtime S3_LISTEN_ADDR"
}

test_api_start_inherits_rewritten_local_stack_database_url() {
    local tmp_dir fixture_root api_env_capture captured_api_env launch_output
    local capture_wait=0 launch_status=0
    tmp_dir="$(mktemp -d)"
    fixture_root="$(create_local_dev_fixture_repo_root \
        "$tmp_dir" \
        "postgres://local-test:local-pass@127.0.0.1:5432/local_demo_test")"
    api_env_capture="$tmp_dir/api_env.txt"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN
    setup_local_demo_launch_mocks "$tmp_dir"

    launch_output="$(env -u DATABASE_URL \
        PATH="$tmp_dir/bin:/usr/bin:/bin" \
        FJCLOUD_REPO_ROOT="$fixture_root" \
        LOCAL_DB_PORT=15432 \
        LOCAL_DEMO_API_ENV_CAPTURE="$api_env_capture" \
        bash "$REPO_ROOT/scripts/local_demo.sh" 2>&1)" || launch_status=$?

    if [ "$launch_status" -eq 0 ]; then
        pass "local demo launch harness should reach API startup"
    else
        fail "local demo launch harness should reach API startup (output: $launch_output)"
    fi
    while [ ! -f "$api_env_capture" ] && [ "$capture_wait" -lt 50 ]; do
        /bin/sleep 0.02
        capture_wait=$((capture_wait + 1))
    done
    assert_file_exists "$api_env_capture" \
        "local demo should invoke api-dev.sh through the launch path"
    if [ -f "$api_env_capture" ]; then
        captured_api_env="$(cat "$api_env_capture")"
        assert_contains "$captured_api_env" \
            "DATABASE_URL=postgres://local-test:local-pass@127.0.0.1:15432/local_demo_test" \
            "api-dev should receive DATABASE_URL rewritten to the local stack database port"
        assert_contains "$captured_api_env" "LOCAL_DB_PORT=15432" \
            "api-dev should receive the same local stack database port"
    fi
}

test_dev_state_audit_runs_after_seed_before_metering() {
    local script_text seed_line audit_line metering_line audit_count
    script_text="$(cat "$REPO_ROOT/scripts/local_demo.sh")"

    assert_contains "$script_text" 'bash "$SCRIPT_DIR/dev_state_audit.sh"' \
        "local demo should run dev_state_audit.sh before starting metering"
    audit_count="$(grep -cF 'bash "$SCRIPT_DIR/dev_state_audit.sh"' "$REPO_ROOT/scripts/local_demo.sh")"
    assert_eq "$audit_count" "1" \
        "local demo should keep exactly one dev_state_audit.sh gate in the seed-to-metering flow"
    assert_not_contains "$script_text" 'bash "$SCRIPT_DIR/cleanup_dev_orphans.sh"' \
        "local demo should not absorb targeted stale fixture cleanup"
    assert_not_contains "$script_text" 'bash "$SCRIPT_DIR/local-dev-down.sh" --clean' \
        "local demo should not absorb full local reset remediation"

    seed_line="$(grep -nF 'bash "$SCRIPT_DIR/seed_local.sh"' "$REPO_ROOT/scripts/local_demo.sh" | cut -d: -f1)"
    audit_line="$(grep -nF 'bash "$SCRIPT_DIR/dev_state_audit.sh"' "$REPO_ROOT/scripts/local_demo.sh" | cut -d: -f1)"
    metering_line="$(grep -nF 'bash "$SCRIPT_DIR/start-metering.sh" --multi-region' "$REPO_ROOT/scripts/local_demo.sh" | cut -d: -f1)"

    if [ -n "$seed_line" ] && [ -n "$audit_line" ] && [ -n "$metering_line" ] \
        && [ "$seed_line" -lt "$audit_line" ] && [ "$audit_line" -lt "$metering_line" ]; then
        pass "local demo should run dev state audit after seeding and before metering"
    else
        fail "local demo audit ordering is wrong (seed=${seed_line:-missing} audit=${audit_line:-missing} metering=${metering_line:-missing})"
    fi
}

test_help_mentions_one_command() {
    local output
    output="$(bash "$REPO_ROOT/scripts/local_demo.sh" --help)"
    assert_contains "$output" "scripts/local_demo.sh" "help should show the one-command launcher"
}

test_unknown_argument_exits_two() {
    local exit_code=0
    bash "$REPO_ROOT/scripts/local_demo.sh" --nope >/dev/null 2>&1 || exit_code=$?
    assert_eq "$exit_code" "2" "unknown argument should exit with usage error"
}

test_prepare_env_honors_supplied_repo_root_without_mutating_checkout_root
test_prepare_env_adds_demo_defaults
test_prepare_env_preserves_existing_values
test_prepare_env_preserves_existing_flapjack_dev_dir
test_web_start_contract_uses_strict_exact_port
test_ports_are_env_overridable
test_api_port_is_preflighted_before_start
test_api_start_exports_checked_ports_to_runtime
test_api_start_inherits_rewritten_local_stack_database_url
test_dev_state_audit_runs_after_seed_before_metering
test_help_mentions_one_command
test_unknown_argument_exits_two

run_test_summary
