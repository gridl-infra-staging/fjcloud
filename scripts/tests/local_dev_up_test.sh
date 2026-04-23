#!/usr/bin/env bash
# Tests for scripts/local-dev-up.sh: postgres startup, migrations, flapjack,
# startup instructions. Uses mock binaries — does NOT start real services.

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

LOCAL_DEV_TEST_DB_URL="postgres://local-test:local-pass@localhost:5432/local_dev_test"
LOCAL_DEV_ALT_PORT_DB_URL="postgres://local-test:local-pass@localhost:15432/local_dev_test"
LOCAL_DEV_INVALID_PORT_DB_URL="postgres://local-test:local-pass@localhost:notaport/local_dev_test"
LOCAL_DEV_OUT_OF_RANGE_PORT_DB_URL="postgres://local-test:local-pass@localhost:70000/local_dev_test"

setup_local_dev_repo_state() {
    local tmp_dir="$1"
    LOCAL_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    LOCAL_DEV_RUNTIME_BACKUP=$(backup_repo_path "$REPO_ROOT/.local" "$tmp_dir/.local.backup")
    write_local_dev_env_file "$REPO_ROOT/.env.local" "$LOCAL_DEV_TEST_DB_URL"
}

restore_local_dev_repo_state() {
    restore_repo_path "$REPO_ROOT/.env.local" "${LOCAL_DEV_ENV_BACKUP:-}"
    restore_repo_path "$REPO_ROOT/.local" "${LOCAL_DEV_RUNTIME_BACKUP:-}"
    LOCAL_DEV_ENV_BACKUP=""
    LOCAL_DEV_RUNTIME_BACKUP=""
}

write_mock_script() {
    local path="$1" body="$2"
    cat > "$path" << MOCK
#!/usr/bin/env bash
$body
MOCK
    chmod +x "$path"
}

write_healthy_mock_curl() {
    local path="$1" call_log="$2"
    write_mock_script "$path" \
        'echo "curl $@" >> "'"$call_log"'"
if [[ "$*" == *"%{http_code}"* ]]; then
    echo 200
fi
exit 0'
}

# Create a standard mock bin directory with all required mocks.
# Writes all docker/curl/psql calls to $call_log for assertion.
setup_mock_bin() {
    local mock_dir="$1" call_log="$2"

    # Mock docker: log calls, succeed on compose up/exec/down
    write_mock_script "$mock_dir/docker" \
        'echo "LOCAL_DB_PORT=${LOCAL_DB_PORT:-} docker $@" >> "'"$call_log"'"; exit 0'

    # Mock curl: succeed (services healthy)
    write_healthy_mock_curl "$mock_dir/curl" "$call_log"

    # Mock psql: succeed (migrations pass)
    write_mock_script "$mock_dir/psql" \
        'echo "psql $@" >> "'"$call_log"'"; exit 0'

    # Mock lsof: report all ports as available (exit 1 = not found)
    write_mock_script "$mock_dir/lsof" \
        'echo "lsof $@" >> "'"$call_log"'"; exit 1'

    # Mock nohup: run the command directly (no backgrounding)
    write_mock_script "$mock_dir/nohup" \
        'echo "nohup $@" >> "'"$call_log"'"; "$@" &'
}

# ============================================================================
# Tests
# ============================================================================

test_calls_down_before_starting() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/local-dev-up.sh" 2>&1
    ) || exit_code=$?

    # Verify local-dev-down.sh was invoked (it calls docker compose down)
    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    assert_contains "$calls" "docker compose down" \
        "should call local-dev-down.sh (which runs docker compose down)"
}

test_starts_only_postgres_service() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/local-dev-up.sh" 2>&1
    ) || exit_code=$?

    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    assert_contains "$calls" "docker compose up -d postgres" \
        "should start only the postgres service"
}

test_waits_for_postgres_with_superuser_probe() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/local-dev-up.sh" 2>&1
    ) || exit_code=$?

    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    assert_contains "$calls" "docker compose exec -T postgres pg_isready -U postgres -d postgres" \
        "should wait for postgres using a server-ready probe that survives stale app roles"
}

test_starts_flapjack_with_shared_local_admin_key_default() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"

    local mock_flapjack_dir="$tmp_dir/flapjack/target/debug"
    mkdir -p "$mock_flapjack_dir"
    write_mock_script "$mock_flapjack_dir/flapjack" 'exit 0'

    write_mock_script "$tmp_dir/bin/nohup" \
        'echo "FLAPJACK_ADMIN_KEY=${FLAPJACK_ADMIN_KEY:-}" >> "'"$call_log"'"; "$@" &'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_ADMIN_KEY="" \
        FLAPJACK_DEV_DIR="$tmp_dir/flapjack" \
        FLAPJACK_PORT=7797 \
        bash "$REPO_ROOT/scripts/local-dev-up.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should start successfully with a mock flapjack binary"

    # Brief pause so the backgrounded nohup mock finishes writing to call_log
    sleep 0.3
    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    assert_contains "$calls" "FLAPJACK_ADMIN_KEY=fj_local_dev_admin_key_000000000000" \
        "should start local flapjack with the shared default admin key when none is configured"
}

test_summary_includes_flapjack_binary_path() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    write_mock_script "$tmp_dir/bin/lsof" 'exit 1'
    setup_local_dev_repo_state "$tmp_dir"

    local flapjack_bin="$tmp_dir/flapjack_dev/target/debug/flapjack"
    mkdir -p "$(dirname "$flapjack_bin")"
    write_mock_script "$flapjack_bin" 'exit 0'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_ADMIN_KEY="" \
        FLAPJACK_DEV_DIR="$tmp_dir/flapjack_dev" \
        bash "$REPO_ROOT/scripts/local-dev-up.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should start successfully when a flapjack binary is available"
    assert_contains "$output" "$flapjack_bin" \
        "startup summary should include the resolved flapjack binary path"
}

test_discovers_alternate_flapjack_checkout_when_unset() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    write_mock_script "$tmp_dir/bin/lsof" 'exit 1'
    setup_local_dev_repo_state "$tmp_dir"

    local first_candidate_bin="$tmp_dir/gridl-dev/flapjack_dev/engine/target/debug/flapjack"
    local second_candidate_bin="$tmp_dir/gridl-dev/flapjack_dev/target/debug/flapjack"
    mkdir -p "$(dirname "$first_candidate_bin")" "$(dirname "$second_candidate_bin")"
    write_mock_script "$first_candidate_bin" 'exit 0'
    write_mock_script "$second_candidate_bin" 'exit 0'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR_CANDIDATES="$tmp_dir/missing $tmp_dir/gridl-dev/flapjack_dev/engine $tmp_dir/gridl-dev/flapjack_dev" \
        bash "$REPO_ROOT/scripts/local-dev-up.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should start successfully when alternate Flapjack checkout is discoverable"
    assert_contains "$output" "$first_candidate_bin" \
        "startup summary should include the first discovered alternate Flapjack binary path"
    assert_not_contains "$output" "$second_candidate_bin" \
        "should prefer the earliest existing candidate directory in FLAPJACK_DEV_DIR_CANDIDATES order"
    assert_not_contains "$output" "skipping flapjack startup" \
        "should not skip Flapjack when an alternate checkout candidate has a binary"
}

test_discovers_default_repo_relative_fresh_host_candidates_when_unset() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    local fixture_repo_root="$tmp_dir/workspaces/fjcloud_dev"
    mkdir -p "$fixture_repo_root/scripts/lib"
    cp "$REPO_ROOT/scripts/local-dev-up.sh" "$fixture_repo_root/scripts/"
    cp "$REPO_ROOT/scripts/local-dev-down.sh" "$fixture_repo_root/scripts/"
    cp "$REPO_ROOT/scripts/lib/env.sh" "$fixture_repo_root/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/migrate.sh" "$fixture_repo_root/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/db_url.sh" "$fixture_repo_root/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/health.sh" "$fixture_repo_root/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/flapjack_binary.sh" "$fixture_repo_root/scripts/lib/"
    mkdir -p "$fixture_repo_root/infra"
    cp -R "$REPO_ROOT/infra/migrations" "$fixture_repo_root/infra/"
    write_local_dev_env_file "$fixture_repo_root/.env.local" "$LOCAL_DEV_TEST_DB_URL"

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"

    local expected_flapjack_bin="$fixture_repo_root/../../gridl-dev/flapjack_dev/engine/target/debug/flapjack"
    local later_flapjack_bin="$fixture_repo_root/../../gridl-dev/flapjack_dev/target/debug/flapjack"
    local expected_flapjack_bin_real="$tmp_dir/gridl-dev/flapjack_dev/engine/target/debug/flapjack"
    local later_flapjack_bin_real="$tmp_dir/gridl-dev/flapjack_dev/target/debug/flapjack"
    mkdir -p "$(dirname "$expected_flapjack_bin_real")" "$(dirname "$later_flapjack_bin_real")"
    write_mock_script "$expected_flapjack_bin_real" 'exit 0'
    write_mock_script "$later_flapjack_bin_real" 'exit 0'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="" \
        FLAPJACK_DEV_DIR_CANDIDATES="" \
        FLAPJACK_ADMIN_KEY="" \
        bash "$fixture_repo_root/scripts/local-dev-up.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" \
        "should discover flapjack from default repo-relative fresh-host candidates when candidate env vars are unset"
    assert_contains "$output" "$expected_flapjack_bin" \
        "startup summary should include the selected default fresh-host candidate binary path"
    assert_not_contains "$output" "$later_flapjack_bin" \
        "should prefer ../../gridl-dev/flapjack_dev/engine before ../../gridl-dev/flapjack_dev in default candidate order"
    assert_not_contains "$output" "skipping flapjack startup" \
        "should not skip Flapjack when default repo-relative fresh-host candidates resolve a binary"
}

test_prefers_engine_debug_over_root_release_when_both_exist() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    write_mock_script "$tmp_dir/bin/lsof" 'exit 1'
    setup_local_dev_repo_state "$tmp_dir"

    local flapjack_checkout="$tmp_dir/gridl-dev/flapjack_dev"
    local preferred_engine_debug="$flapjack_checkout/engine/target/debug/flapjack"
    local lower_priority_root_release="$flapjack_checkout/target/release/flapjack"
    mkdir -p "$(dirname "$preferred_engine_debug")" "$(dirname "$lower_priority_root_release")"
    write_mock_script "$preferred_engine_debug" 'exit 0'
    write_mock_script "$lower_priority_root_release" 'exit 0'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR_CANDIDATES="$tmp_dir/missing $flapjack_checkout" \
        bash "$REPO_ROOT/scripts/local-dev-up.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "startup should succeed when both engine debug and root release binaries exist"
    assert_contains "$output" "$preferred_engine_debug" \
        "shared binary contract should prefer engine target/debug/flapjack before checkout-root target/release/flapjack"
    assert_not_contains "$output" "$lower_priority_root_release" \
        "startup summary should not resolve to checkout-root release when higher-priority engine debug exists"
}

test_summary_includes_effective_admin_key() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_ADMIN_KEY="" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/local-dev-up.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should start successfully when flapjack startup is skipped"
    # Script truncates admin key to first 8 chars in summary for security
    # Summary uses column-aligned spacing (6 spaces after "key:").
    assert_contains "$output" "Admin key:" \
        "startup summary should include the admin key line"
    assert_contains "$output" "fj_local" \
        "startup summary should include the effective FLAPJACK_ADMIN_KEY value"
    assert_not_contains "$output" "fj_local_dev_admin_key" \
        "startup summary should not leak the full admin key"
}

test_preserves_explicit_flapjack_admin_key_override() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"
    cat >> "$REPO_ROOT/.env.local" <<'EOF'
FLAPJACK_ADMIN_KEY=file-admin-key
EOF

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_ADMIN_KEY="explicit-admin-key" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/local-dev-up.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should start successfully when flapjack startup is skipped"
    # Script truncates admin key to first 8 chars in summary for security
    # Summary uses column-aligned spacing (6 spaces after "key:").
    assert_contains "$output" "Admin key:" \
        "startup summary should include the admin key line"
    assert_contains "$output" "explicit" \
        "startup summary should preserve explicit FLAPJACK_ADMIN_KEY over .env.local values"
    assert_not_contains "$output" "explicit-admin-key" \
        "startup summary should not leak the full overridden admin key"
}

test_recreates_incompatible_postgres_volume_once() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_local_dev_repo_state "$tmp_dir"

    write_mock_script "$tmp_dir/bin/docker" \
        'echo "docker $@" >> "'"$call_log"'"
if [[ "$*" == *"compose down -v"* ]]; then
    echo 1 > "'"$tmp_dir"'/volume_recreated"
    exit 0
fi
if [[ "$*" == *"psql -h 127.0.0.1 -U local-test -d local_dev_test"* ]]; then
    if [ ! -f "'"$tmp_dir"'/volume_recreated" ]; then
        exit 1
    fi
fi
exit 0'
    write_healthy_mock_curl "$tmp_dir/bin/curl" "$call_log"
    write_mock_script "$tmp_dir/bin/psql" \
        'echo "psql $@" >> "'"$call_log"'"; exit 0'
    write_mock_script "$tmp_dir/bin/nohup" \
        'echo "nohup $@" >> "'"$call_log"'"; "$@" &'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/local-dev-up.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should recover from an incompatible postgres volume"
    assert_contains "$output" "incompatible with" \
        "should explain when an existing postgres volume must be recreated"

    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    assert_contains "$calls" "docker compose down -v" \
        "should clean the docker postgres volume before retrying"

    local up_count
    up_count=$(grep -c "docker compose up -d postgres" "$call_log" 2>/dev/null || true)
    assert_eq "$up_count" "2" "should restart postgres once after cleaning the stale volume"
}

test_waits_for_fresh_volume_initialization_before_recreating() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_local_dev_repo_state "$tmp_dir"

    write_mock_script "$tmp_dir/bin/docker" \
        'echo "docker $@" >> "'"$call_log"'"
if [[ "$*" == *"psql -h 127.0.0.1 -U local-test -d local_dev_test"* ]]; then
    attempts_file="'"$tmp_dir"'/psql_attempts"
    attempts=0
    if [ -f "$attempts_file" ]; then
        attempts=$(cat "$attempts_file")
    fi
    attempts=$((attempts + 1))
    echo "$attempts" > "$attempts_file"
    if [ "$attempts" -lt 3 ]; then
        exit 1
    fi
fi
exit 0'
    write_healthy_mock_curl "$tmp_dir/bin/curl" "$call_log"
    write_mock_script "$tmp_dir/bin/psql" \
        'echo "psql $@" >> "'"$call_log"'"; exit 0'
    write_mock_script "$tmp_dir/bin/nohup" \
        'echo "nohup $@" >> "'"$call_log"'"; "$@" &'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/local-dev-up.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should tolerate brief app-role initialization lag on a fresh volume"

    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    if [[ "$calls" == *"docker compose down -v"* ]]; then
        fail "should not recreate the volume when app credentials become available shortly after startup"
    else
        pass "should not recreate the volume when app credentials become available shortly after startup"
    fi

    local up_count
    up_count=$(grep -c "docker compose up -d postgres" "$call_log" 2>/dev/null || true)
    assert_eq "$up_count" "1" "should keep the original postgres startup when the fresh volume finishes initializing"
}

test_rejects_executable_env_local_content() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    local marker_path="$tmp_dir/should-not-exist"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    LOCAL_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    LOCAL_DEV_RUNTIME_BACKUP=$(backup_repo_path "$REPO_ROOT/.local" "$tmp_dir/.local.backup")
    cat > "$REPO_ROOT/.env.local" <<EOF
DATABASE_URL=$LOCAL_DEV_TEST_DB_URL
touch "$marker_path"
EOF

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/local-dev-up.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" "should reject executable shell syntax in .env.local"
    assert_contains "$output" "Unsupported syntax" \
        "should explain that only env assignments are accepted from .env.local"

    if [ -e "$marker_path" ]; then
        fail "should not execute shell commands from .env.local"
    else
        pass "should not execute shell commands from .env.local"
    fi
}

test_missing_env_local_auto_bootstraps() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    LOCAL_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    LOCAL_DEV_RUNTIME_BACKUP=$(backup_repo_path "$REPO_ROOT/.local" "$tmp_dir/.local.backup")
    rm -f "$REPO_ROOT/.env.local"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/local-dev-up.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should succeed after auto-bootstrapping .env.local"
    assert_contains "$output" "Bootstrap created .env.local" \
        "should log bootstrap success when .env.local was auto-created"

    if [ -f "$REPO_ROOT/.env.local" ]; then
        pass "auto-bootstrap should create .env.local"
    else
        fail "auto-bootstrap should create .env.local (file not found)"
    fi
}

test_missing_env_local_and_example_fails() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; mv "'"$tmp_dir"'/.env.local.example.backup" "'"$REPO_ROOT"'/.env.local.example" 2>/dev/null; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    LOCAL_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    LOCAL_DEV_RUNTIME_BACKUP=$(backup_repo_path "$REPO_ROOT/.local" "$tmp_dir/.local.backup")
    rm -f "$REPO_ROOT/.env.local"
    mv "$REPO_ROOT/.env.local.example" "$tmp_dir/.env.local.example.backup"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/local-dev-up.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" "should fail when both .env.local and .env.local.example are missing"
    assert_contains "$output" "bootstrap failed" \
        "should mention bootstrap failure when template is also missing"
}

test_runs_migrations() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/local-dev-up.sh" 2>&1
    ) || exit_code=$?

    # run_migrations calls psql for each .sql file
    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    assert_contains "$calls" "docker compose exec -T postgres env PGPASSWORD=local-pass psql -h 127.0.0.1 -U local-test -d local_dev_test -f" \
        "should run migrations through the postgres container client"
    assert_contains "$output" "Applying:" \
        "log should mention applying migrations"
}

test_does_not_require_host_psql_when_container_client_is_available() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_local_dev_repo_state "$tmp_dir"

    write_mock_script "$tmp_dir/bin/docker" \
        'echo "LOCAL_DB_PORT=${LOCAL_DB_PORT:-} docker $@" >> "'"$call_log"'"; exit 0'
    write_healthy_mock_curl "$tmp_dir/bin/curl" "$call_log"
    write_mock_script "$tmp_dir/bin/nohup" \
        'echo "nohup $@" >> "'"$call_log"'"; "$@" &'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/local-dev-up.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should not require host psql when docker compose can exec the postgres client"
    assert_contains "$output" "Local dev infrastructure is up!" \
        "startup should complete without a host psql binary"
}

test_uses_database_url_port_for_postgres_bind_and_summary() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    LOCAL_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    LOCAL_DEV_RUNTIME_BACKUP=$(backup_repo_path "$REPO_ROOT/.local" "$tmp_dir/.local.backup")
    write_local_dev_env_file "$REPO_ROOT/.env.local" "$LOCAL_DEV_ALT_PORT_DB_URL"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/local-dev-up.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should support non-default host Postgres ports from DATABASE_URL"

    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    assert_contains "$calls" "LOCAL_DB_PORT=15432 docker compose up -d postgres" \
        "should pass the DATABASE_URL host port through to docker compose"
    # Summary uses column-aligned spacing for the Postgres line.
    assert_contains "$output" "Postgres:" \
        "should print the Postgres line in the startup summary"
    assert_contains "$output" "localhost:15432" \
        "should print the configured host Postgres port in the startup summary"
}

test_rejects_non_numeric_database_url_port() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    LOCAL_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    LOCAL_DEV_RUNTIME_BACKUP=$(backup_repo_path "$REPO_ROOT/.local" "$tmp_dir/.local.backup")
    write_local_dev_env_file "$REPO_ROOT/.env.local" "$LOCAL_DEV_INVALID_PORT_DB_URL"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/local-dev-up.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" "should reject non-numeric DATABASE_URL ports"
    assert_contains "$output" "DATABASE_URL must include a valid port" \
        "should explain why malformed ports are rejected"

    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    assert_eq "$calls" "" "should fail before invoking docker when the port is malformed"
}

test_rejects_out_of_range_database_url_port() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    LOCAL_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    LOCAL_DEV_RUNTIME_BACKUP=$(backup_repo_path "$REPO_ROOT/.local" "$tmp_dir/.local.backup")
    write_local_dev_env_file "$REPO_ROOT/.env.local" "$LOCAL_DEV_OUT_OF_RANGE_PORT_DB_URL"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/local-dev-up.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" "should reject out-of-range DATABASE_URL ports"
    assert_contains "$output" "DATABASE_URL must include a valid port" \
        "should explain why out-of-range ports are rejected"

    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    assert_eq "$calls" "" "should fail before invoking docker when the port exceeds TCP limits"
}

test_starts_flapjack_on_port_7700() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"

    # Create a fake flapjack binary
    local fj_dir="$tmp_dir/flapjack_dev/target/debug"
    mkdir -p "$fj_dir"
    write_mock_script "$fj_dir/flapjack-http" 'sleep 300'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="$tmp_dir/flapjack_dev" \
        bash "$REPO_ROOT/scripts/local-dev-up.sh" 2>&1
    ) || exit_code=$?

    assert_contains "$output" "port 7700" \
        "should start flapjack on port 7700"

    local flapjack_pid_file="$REPO_ROOT/.local/flapjack.pid"
    if [ -f "$flapjack_pid_file" ]; then
        local pid
        pid=$(cat "$flapjack_pid_file" 2>/dev/null || true)
        if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    fi
}

test_starts_flapjack_with_current_binary_name() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"

    local fj_dir="$tmp_dir/flapjack_dev/target/debug"
    mkdir -p "$fj_dir"
    write_mock_script "$fj_dir/flapjack" 'sleep 300'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="$tmp_dir/flapjack_dev" \
        bash "$REPO_ROOT/scripts/local-dev-up.sh" 2>&1
    ) || exit_code=$?

    assert_contains "$output" "port 7700" \
        "should start flapjack when the current binary name is present"

    local flapjack_pid_file="$REPO_ROOT/.local/flapjack.pid"
    if [ -f "$flapjack_pid_file" ]; then
        local pid
        pid=$(cat "$flapjack_pid_file" 2>/dev/null || true)
        if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    fi
}

test_migrations_skip_already_applied_on_rerun() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_local_dev_repo_state "$tmp_dir"

    # Smart docker mock: simulates a Postgres volume that already has all
    # migrations tracked in _schema_migrations (rerun scenario).
    write_mock_script "$tmp_dir/bin/docker" \
        'echo "docker $@" >> "'"$call_log"'"
if [[ "$*" == *"-tAc"*"SELECT 1 FROM _schema_migrations"* ]]; then
    echo "1"
fi
exit 0'

    write_healthy_mock_curl "$tmp_dir/bin/curl" "$call_log"
    write_mock_script "$tmp_dir/bin/nohup" \
        'echo "nohup $@" >> "'"$call_log"'"; "$@" &'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/local-dev-up.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "rerun should succeed when all migrations are already applied"
    assert_contains "$output" "skipped" \
        "should report that already-applied migrations were skipped on rerun"

    # No migration files should have been re-applied (no -f flags for migration SQL)
    local apply_calls
    apply_calls=$(grep -c "\-f /migrations/" "$call_log" 2>/dev/null || true)
    assert_eq "$apply_calls" "0" "should not re-apply migrations that are already tracked"
}

test_flapjack_missing_warns_and_skips() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/local-dev-up.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should succeed even when flapjack binary is missing"
    assert_contains "$output" "WARNING" \
        "should warn about missing flapjack binary"
    assert_contains "$output" "skipping flapjack startup" \
        "should keep warning-only behavior and skip flapjack startup when no binary resolves"

    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    assert_not_contains "$calls" "nohup /" \
        "should not attempt to launch flapjack when binary lookup fails"
}

test_prints_startup_instructions() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/local-dev-up.sh" 2>&1
    ) || exit_code=$?

    assert_contains "$output" "scripts/api-dev.sh" \
        "should print API startup instructions that work from the repo root"
    assert_contains "$output" "scripts/web-dev.sh" \
        "should print the repo-owned web startup wrapper"
}

test_starts_seaweedfs_and_mailpit() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/local-dev-up.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should succeed with optional services"

    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    assert_contains "$calls" "docker compose up -d seaweedfs" \
        "should always start seaweedfs"
    assert_contains "$calls" "docker compose up -d mailpit" \
        "should always start mailpit"
}

test_optional_service_health_failure_nonfatal() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"

    # Docker mock: log calls, succeed on compose up/exec/down
    write_mock_script "$tmp_dir/bin/docker" \
        'echo "docker $@" >> "'"$call_log"'"; exit 0'
    # Curl mock: always fail (health checks fail for optional services)
    write_mock_script "$tmp_dir/bin/curl" \
        'echo "curl $@" >> "'"$call_log"'"; exit 1'
    write_mock_script "$tmp_dir/bin/psql" \
        'echo "psql $@" >> "'"$call_log"'"; exit 0'
    write_mock_script "$tmp_dir/bin/nohup" \
        'echo "nohup $@" >> "'"$call_log"'"; "$@" &'
    # Mock sleep to no-op so wait_for_health retries don't block
    write_mock_script "$tmp_dir/bin/sleep" \
        'exit 0'

    setup_local_dev_repo_state "$tmp_dir"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/local-dev-up.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" \
        "should exit 0 even when optional service health checks fail"
    assert_contains "$output" "failed health check" \
        "should log health-failure warning for optional services"
}

test_startup_summary_reflects_health_status() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    # --- Run 1: healthy optional services (curl succeeds) ---
    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"

    local output_healthy exit_code=0
    output_healthy=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/local-dev-up.sh" 2>&1
    ) || exit_code=$?

    assert_contains "$output_healthy" "SeaweedFS S3:" \
        "summary should include SeaweedFS when healthy"
    assert_contains "$output_healthy" "Mailpit UI:" \
        "summary should include Mailpit when healthy"

    restore_local_dev_repo_state

    # --- Run 2: unhealthy optional services (curl fails) ---
    rm -rf "$tmp_dir"
    tmp_dir=$(mktemp -d)
    local call_log2="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"

    write_mock_script "$tmp_dir/bin/docker" \
        'echo "docker $@" >> "'"$call_log2"'"; exit 0'
    write_mock_script "$tmp_dir/bin/curl" \
        'echo "curl $@" >> "'"$call_log2"'"; exit 1'
    write_mock_script "$tmp_dir/bin/psql" \
        'echo "psql $@" >> "'"$call_log2"'"; exit 0'
    write_mock_script "$tmp_dir/bin/nohup" \
        'echo "nohup $@" >> "'"$call_log2"'"; "$@" &'
    write_mock_script "$tmp_dir/bin/sleep" \
        'exit 0'

    setup_local_dev_repo_state "$tmp_dir"

    local output_unhealthy exit_code2=0
    output_unhealthy=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/local-dev-up.sh" 2>&1
    ) || exit_code2=$?

    assert_not_contains "$output_unhealthy" "SeaweedFS S3:" \
        "summary should omit SeaweedFS when unhealthy"
    assert_not_contains "$output_unhealthy" "Mailpit UI:" \
        "summary should omit Mailpit when unhealthy"
}

test_multi_region_flapjack_starts_one_per_region() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"

    # Create a fake flapjack binary.
    local fj_dir="$tmp_dir/flapjack_dev/target/debug"
    mkdir -p "$fj_dir"
    # Mock flapjack that logs its arguments and sleeps.
    write_mock_script "$fj_dir/flapjack" \
        'echo "flapjack $@" >> "'"$call_log"'"; sleep 300'

    # Override nohup to log the FLAPJACK_ADMIN_KEY and args, then background.
    write_mock_script "$tmp_dir/bin/nohup" \
        'echo "nohup $@" >> "'"$call_log"'"; "$@" &'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="$tmp_dir/flapjack_dev" \
        FLAPJACK_REGIONS="us-east-1:7700 eu-west-1:7701" \
        bash "$REPO_ROOT/scripts/local-dev-up.sh" 2>&1
    ) || exit_code=$?

    # Brief pause for backgrounded processes to write to call_log.
    sleep 0.5

    assert_eq "$exit_code" "0" "multi-region flapjack startup should succeed"

    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)

    # Verify start_one_flapjack was called for each region.
    assert_contains "$calls" "--port 7700" \
        "should start flapjack on port 7700 for us-east-1"
    assert_contains "$calls" "--port 7701" \
        "should start flapjack on port 7701 for eu-west-1"

    assert_contains "$output" "flapjack (us-east-1)" \
        "should log flapjack startup for us-east-1"
    assert_contains "$output" "flapjack (eu-west-1)" \
        "should log flapjack startup for eu-west-1"

    # Verify PID files were created for each region.
    local pid_dir="$REPO_ROOT/.local"
    if [ -f "$pid_dir/flapjack-us-east-1.pid" ]; then
        pass "flapjack-us-east-1.pid was created"
    else
        fail "flapjack-us-east-1.pid should be created"
    fi
    if [ -f "$pid_dir/flapjack-eu-west-1.pid" ]; then
        pass "flapjack-eu-west-1.pid was created"
    else
        fail "flapjack-eu-west-1.pid should be created"
    fi

    # Clean up background flapjack processes.
    for pid_file in "$pid_dir"/flapjack-*.pid; do
        [ -f "$pid_file" ] || continue
        local pid
        pid=$(cat "$pid_file" 2>/dev/null || true)
        if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
}

# ============================================================================
# Run all tests
# ============================================================================

main() {
    echo "=== local-dev-up.sh tests ==="
    echo ""

    test_calls_down_before_starting
    test_starts_only_postgres_service
    test_waits_for_postgres_with_superuser_probe
    test_starts_flapjack_with_shared_local_admin_key_default
    test_summary_includes_flapjack_binary_path
    test_discovers_alternate_flapjack_checkout_when_unset
    test_discovers_default_repo_relative_fresh_host_candidates_when_unset
    test_prefers_engine_debug_over_root_release_when_both_exist
    test_summary_includes_effective_admin_key
    test_preserves_explicit_flapjack_admin_key_override
    test_recreates_incompatible_postgres_volume_once
    test_waits_for_fresh_volume_initialization_before_recreating
    test_rejects_executable_env_local_content
    test_missing_env_local_auto_bootstraps
    test_missing_env_local_and_example_fails
    test_runs_migrations
    test_does_not_require_host_psql_when_container_client_is_available
    test_uses_database_url_port_for_postgres_bind_and_summary
    test_rejects_non_numeric_database_url_port
    test_rejects_out_of_range_database_url_port
    test_starts_flapjack_on_port_7700
    test_starts_flapjack_with_current_binary_name
    test_migrations_skip_already_applied_on_rerun
    test_flapjack_missing_warns_and_skips
    test_prints_startup_instructions
    test_starts_seaweedfs_and_mailpit
    test_optional_service_health_failure_nonfatal
    test_startup_summary_reflects_health_status
    test_multi_region_flapjack_starts_one_per_region

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
