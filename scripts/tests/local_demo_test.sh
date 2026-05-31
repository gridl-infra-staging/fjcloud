#!/usr/bin/env bash
# Tests for scripts/local_demo.sh: safe env preparation and CLI behavior.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/local_dev_test_state.sh
source "$SCRIPT_DIR/lib/local_dev_test_state.sh"

LOCAL_DEMO_ENV_BACKUP=""

setup_repo_state() {
    local tmp_dir="$1"
    LOCAL_DEMO_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
}

restore_repo_state() {
    restore_repo_path "$REPO_ROOT/.env.local" "${LOCAL_DEMO_ENV_BACKUP:-}"
    LOCAL_DEMO_ENV_BACKUP=""
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

test_prepare_env_adds_demo_defaults
test_prepare_env_preserves_existing_values
test_prepare_env_preserves_existing_flapjack_dev_dir
test_web_start_contract_uses_strict_exact_port
test_ports_are_env_overridable
test_api_port_is_preflighted_before_start
test_help_mentions_one_command
test_unknown_argument_exits_two

run_test_summary
