#!/usr/bin/env bash
# Tests for scripts/web-dev.sh: env loading, overrides, and startup command.

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

setup_repo_env() {
    local tmp_dir="$1"
    WEB_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    WEB_DEV_WEB_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/web/.env.local" "$tmp_dir/web.env.local.backup")
    WEB_DEV_VITE_BACKUP=$(backup_repo_path "$REPO_ROOT/web/node_modules/.bin/vite" "$tmp_dir/vite.backup")
}

restore_repo_env() {
    restore_repo_path "$REPO_ROOT/.env.local" "${WEB_DEV_ENV_BACKUP:-}"
    restore_repo_path "$REPO_ROOT/web/.env.local" "${WEB_DEV_WEB_ENV_BACKUP:-}"
    restore_repo_path "$REPO_ROOT/web/node_modules/.bin/vite" "${WEB_DEV_VITE_BACKUP:-}"
    WEB_DEV_ENV_BACKUP=""
    WEB_DEV_WEB_ENV_BACKUP=""
    WEB_DEV_VITE_BACKUP=""
}

ensure_repo_vite_runtime_stub() {
    mkdir -p "$REPO_ROOT/web/node_modules/.bin"
    cat > "$REPO_ROOT/web/node_modules/.bin/vite" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$REPO_ROOT/web/node_modules/.bin/vite"
}

write_mock_npm() {
    local path="$1" log_path="$2"
    cat > "$path" <<'MOCK'
#!/usr/bin/env bash
{
    echo "PWD=$PWD"
    echo "API_BASE_URL=${API_BASE_URL:-}"
    echo "JWT_SECRET=${JWT_SECRET:-}"
    echo "ADMIN_KEY=${ADMIN_KEY:-}"
    echo "EXTRA_LAYERED_VAR=${EXTRA_LAYERED_VAR:-}"
    echo "ROOT_ONLY_VAR=${ROOT_ONLY_VAR:-}"
    echo "ARGS=$*"
} >> "__LOG_PATH__"
exit 0
MOCK
    perl -0pi -e "s|__LOG_PATH__|$log_path|g" "$path"
    chmod +x "$path"
}

test_loads_repo_root_env_and_defaults_api_base_url() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env; rm -rf "'"$tmp_dir"'"' RETURN

    setup_repo_env "$tmp_dir"
    write_local_dev_env_file "$REPO_ROOT/.env.local" "postgres://local-test:local-pass@localhost:5432/local_dev_test"
    rm -f "$REPO_ROOT/web/.env.local"
    ensure_repo_vite_runtime_stub

    local call_log="$tmp_dir/npm.log"
    mkdir -p "$tmp_dir/bin"
    write_mock_npm "$tmp_dir/bin/npm" "$call_log"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        bash "$REPO_ROOT/scripts/web-dev.sh" --host 127.0.0.1 --port 4173 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should start the web dev wrapper successfully"

    local log_output
    log_output=$(cat "$call_log")
    assert_contains "$log_output" "PWD=$REPO_ROOT/web" \
        "should run npm from the web workspace"
    assert_contains "$log_output" "API_BASE_URL=http://localhost:3001" \
        "should default API_BASE_URL for local dev"
    assert_contains "$log_output" "JWT_SECRET=test-jwt-secret" \
        "should load JWT_SECRET from the root env file"
    assert_contains "$log_output" "ADMIN_KEY=test-admin-key" \
        "should load ADMIN_KEY from the root env file"
    assert_contains "$log_output" "ARGS=run dev -- --host 127.0.0.1 --port 4173 --strictPort" \
        "should append strictPort so occupied Vite ports fail closed"
}

test_forwards_caller_strictness_flags_once_without_contradictions() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env; rm -rf "'"$tmp_dir"'"' RETURN

    setup_repo_env "$tmp_dir"
    write_local_dev_env_file "$REPO_ROOT/.env.local" "postgres://local-test:local-pass@localhost:5432/local_dev_test"
    rm -f "$REPO_ROOT/web/.env.local"
    ensure_repo_vite_runtime_stub

    local call_log_with_flag="$tmp_dir/npm-with-flag.log"
    local call_log_with_value="$tmp_dir/npm-with-value.log"
    mkdir -p "$tmp_dir/bin-flag" "$tmp_dir/bin-value"
    write_mock_npm "$tmp_dir/bin-flag/npm" "$call_log_with_flag"
    write_mock_npm "$tmp_dir/bin-value/npm" "$call_log_with_value"

    local exit_code=0
    PATH="$tmp_dir/bin-flag:$PATH" \
    bash "$REPO_ROOT/scripts/web-dev.sh" --host 127.0.0.1 --port 4173 --strictPort >/dev/null 2>&1 || exit_code=$?
    assert_eq "$exit_code" "0" "should accept caller-provided --strictPort"

    local log_with_flag
    log_with_flag=$(cat "$call_log_with_flag")
    assert_contains "$log_with_flag" "ARGS=run dev -- --host 127.0.0.1 --port 4173 --strictPort" \
        "should keep caller-provided --strictPort without reordering"
    assert_not_contains "$log_with_flag" "--strictPort --strictPort" \
        "should not duplicate --strictPort when the caller already supplied it"

    exit_code=0
    PATH="$tmp_dir/bin-value:$PATH" \
    bash "$REPO_ROOT/scripts/web-dev.sh" --host 127.0.0.1 --port 4173 --strictPort=false >/dev/null 2>&1 || exit_code=$?
    assert_eq "$exit_code" "0" "should accept caller-provided --strictPort=value"

    local log_with_value
    log_with_value=$(cat "$call_log_with_value")
    assert_contains "$log_with_value" "ARGS=run dev -- --host 127.0.0.1 --port 4173 --strictPort=false" \
        "should forward caller-provided --strictPort=value unchanged"
    assert_not_contains "$log_with_value" "--strictPort=false --strictPort" \
        "should not append a contradictory strictness flag"
}

test_web_env_file_overrides_repo_root_values_without_explicit_shell_overrides() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env; rm -rf "'"$tmp_dir"'"' RETURN

    setup_repo_env "$tmp_dir"
    cat > "$REPO_ROOT/.env.local" <<'EOF'
API_BASE_URL=http://localhost:3111
JWT_SECRET=root-file-jwt-secret
ADMIN_KEY=root-file-admin-key
EOF
    cat > "$REPO_ROOT/web/.env.local" <<'EOF'
API_BASE_URL=http://localhost:3222
JWT_SECRET=web-file-jwt-secret
ADMIN_KEY=web-file-admin-key
EOF
    ensure_repo_vite_runtime_stub

    local call_log="$tmp_dir/npm.log"
    mkdir -p "$tmp_dir/bin"
    write_mock_npm "$tmp_dir/bin/npm" "$call_log"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        bash "$REPO_ROOT/scripts/web-dev.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should start when both env files provide auth values"

    local log_output
    log_output=$(cat "$call_log")
    assert_contains "$log_output" "API_BASE_URL=http://localhost:3222" \
        "should let web/.env.local override root API_BASE_URL"
    assert_contains "$log_output" "JWT_SECRET=web-file-jwt-secret" \
        "should let web/.env.local override root JWT_SECRET"
    assert_contains "$log_output" "ADMIN_KEY=web-file-admin-key" \
        "should let web/.env.local override root ADMIN_KEY"
}

test_web_env_file_overrides_generic_root_env_keys_without_explicit_shell_overrides() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env; rm -rf "'"$tmp_dir"'"' RETURN

    setup_repo_env "$tmp_dir"
    cat > "$REPO_ROOT/.env.local" <<'EOF'
JWT_SECRET=root-file-jwt-secret
ADMIN_KEY=root-file-admin-key
EXTRA_LAYERED_VAR=root-file-value
ROOT_ONLY_VAR=root-only-value
EOF
    cat > "$REPO_ROOT/web/.env.local" <<'EOF'
EXTRA_LAYERED_VAR=web-file-value
EOF
    ensure_repo_vite_runtime_stub

    local call_log="$tmp_dir/npm.log"
    mkdir -p "$tmp_dir/bin"
    write_mock_npm "$tmp_dir/bin/npm" "$call_log"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        bash "$REPO_ROOT/scripts/web-dev.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should start when auth env comes from the root env file"

    local log_output
    log_output=$(cat "$call_log")
    assert_contains "$log_output" "EXTRA_LAYERED_VAR=web-file-value" \
        "should let web/.env.local override arbitrary root env keys"
    assert_contains "$log_output" "ROOT_ONLY_VAR=root-only-value" \
        "should preserve root-only env keys after applying layered overrides"
}

test_preserves_explicit_env_overrides() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env; rm -rf "'"$tmp_dir"'"' RETURN

    setup_repo_env "$tmp_dir"
    write_local_dev_env_file "$REPO_ROOT/.env.local" "postgres://local-test:local-pass@localhost:5432/local_dev_test"
    cat > "$REPO_ROOT/web/.env.local" <<'EOF'
API_BASE_URL=http://localhost:3444
JWT_SECRET=web-file-jwt-secret
ADMIN_KEY=web-file-admin-key
EOF
    ensure_repo_vite_runtime_stub

    local call_log="$tmp_dir/npm.log"
    mkdir -p "$tmp_dir/bin"
    write_mock_npm "$tmp_dir/bin/npm" "$call_log"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_BASE_URL="http://127.0.0.1:3999" \
        JWT_SECRET="explicit-jwt-secret" \
        ADMIN_KEY="explicit-admin-key" \
        bash "$REPO_ROOT/scripts/web-dev.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should allow explicit env overrides"

    local log_output
    log_output=$(cat "$call_log")
    assert_contains "$log_output" "API_BASE_URL=http://127.0.0.1:3999" \
        "should preserve explicit API_BASE_URL overrides"
    assert_contains "$log_output" "JWT_SECRET=explicit-jwt-secret" \
        "should preserve explicit JWT_SECRET overrides"
    assert_contains "$log_output" "ADMIN_KEY=explicit-admin-key" \
        "should preserve explicit ADMIN_KEY overrides"
}

test_rejects_executable_shell_content_in_repo_env_file() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env; rm -rf "'"$tmp_dir"'"' RETURN

    setup_repo_env "$tmp_dir"
    local call_log="$tmp_dir/npm.log"
    mkdir -p "$tmp_dir/bin"
    write_mock_npm "$tmp_dir/bin/npm" "$call_log"
    local marker_path="$tmp_dir/repo-env-should-not-exist"
    cat > "$REPO_ROOT/.env.local" <<EOF
JWT_SECRET=file-jwt-secret
ADMIN_KEY=file-admin-key
touch "$marker_path"
EOF

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        bash "$REPO_ROOT/scripts/web-dev.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" "should reject executable shell syntax in repo .env.local"
    assert_contains "$output" "Unsupported syntax" \
        "should explain that only env assignments are accepted from repo .env.local"

    if [ -e "$marker_path" ]; then
        fail "should not execute shell commands from repo .env.local"
    else
        pass "should not execute shell commands from repo .env.local"
    fi
}

test_rejects_executable_shell_content_in_web_env_file() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env; rm -rf "'"$tmp_dir"'"' RETURN

    setup_repo_env "$tmp_dir"
    local call_log="$tmp_dir/npm.log"
    mkdir -p "$tmp_dir/bin"
    write_mock_npm "$tmp_dir/bin/npm" "$call_log"
    cat > "$REPO_ROOT/.env.local" <<'EOF'
JWT_SECRET=root-file-jwt-secret
ADMIN_KEY=root-file-admin-key
EOF
    local marker_path="$tmp_dir/web-env-should-not-exist"
    cat > "$REPO_ROOT/web/.env.local" <<EOF
API_BASE_URL=http://localhost:3555
touch "$marker_path"
EOF

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        bash "$REPO_ROOT/scripts/web-dev.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" "should reject executable shell syntax in web/.env.local"
    assert_contains "$output" "Unsupported syntax" \
        "should explain that only env assignments are accepted from web/.env.local"

    if [ -e "$marker_path" ]; then
        fail "should not execute shell commands from web/.env.local"
    else
        pass "should not execute shell commands from web/.env.local"
    fi
}

test_requires_auth_env_after_loading() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env; rm -rf "'"$tmp_dir"'"' RETURN

    setup_repo_env "$tmp_dir"
    cat > "$REPO_ROOT/.env.local" <<'EOF'
DATABASE_URL=postgres://local-test:local-pass@localhost:5432/local_dev_test
LISTEN_ADDR=0.0.0.0:3001
EOF
    rm -f "$REPO_ROOT/web/.env.local"

    local output exit_code=0
    output=$(bash "$REPO_ROOT/scripts/web-dev.sh" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "1" "should fail fast when auth env is missing"
    assert_contains "$output" "JWT_SECRET is required" \
        "should explain the missing JWT secret requirement"
}

test_fails_fast_with_actionable_message_when_vite_runtime_missing() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env; rm -rf "'"$tmp_dir"'"' RETURN

    setup_repo_env "$tmp_dir"
    write_local_dev_env_file "$REPO_ROOT/.env.local" "postgres://local-test:local-pass@localhost:5432/local_dev_test"
    rm -f "$REPO_ROOT/web/.env.local"
    rm -f "$REPO_ROOT/web/node_modules/.bin/vite"

    local call_log="$tmp_dir/npm.log"
    mkdir -p "$tmp_dir/bin"
    write_mock_npm "$tmp_dir/bin/npm" "$call_log"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        bash "$REPO_ROOT/scripts/web-dev.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" "should fail fast when vite runtime is missing"
    assert_contains "$output" "web/node_modules/.bin/vite is missing or not executable" \
        "should name the missing vite runtime path"
    assert_contains "$output" "cd web && npm ci" \
        "should include an actionable install command for missing vite runtime"

    if [ -e "$call_log" ]; then
        fail "should fail before invoking npm when vite runtime is missing"
    else
        pass "should fail before invoking npm when vite runtime is missing"
    fi
}

test_web_wrapper_uses_shared_env_parser_contract() {
    local script_content
    script_content=$(cat "$REPO_ROOT/scripts/web-dev.sh")

    if printf '%s\n' "$script_content" | grep -Fq "parse_env_assignment_line"; then
        fail "web-dev.sh should not call parse_env_assignment_line directly"
    else
        pass "web-dev.sh keeps env parsing in scripts/lib/env.sh"
    fi
}

main() {
    echo "=== web-dev.sh tests ==="
    echo ""

    test_loads_repo_root_env_and_defaults_api_base_url
    test_forwards_caller_strictness_flags_once_without_contradictions
    test_web_env_file_overrides_repo_root_values_without_explicit_shell_overrides
    test_web_env_file_overrides_generic_root_env_keys_without_explicit_shell_overrides
    test_preserves_explicit_env_overrides
    test_rejects_executable_shell_content_in_repo_env_file
    test_rejects_executable_shell_content_in_web_env_file
    test_requires_auth_env_after_loading
    test_fails_fast_with_actionable_message_when_vite_runtime_missing
    test_web_wrapper_uses_shared_env_parser_contract

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
