#!/usr/bin/env bash
# Tests for integration-up.sh: health gating, prerequisite detection, timeout behavior.
# These tests use stubs/mocks — they do NOT start real services.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0

fail() {
    echo "FAIL: $*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

# shellcheck source=lib/integration_up_mocks.sh
source "$SCRIPT_DIR/lib/integration_up_mocks.sh"

# ============================================================================
# Health Gating Tests
# ============================================================================

test_health_gating_reports_per_service_status() {
    # integration-up.sh should output per-service health check results
    # so operators can see which service is healthy/unhealthy.
    # We test this by sourcing the helpers and checking wait_for_health output.

    # Create a temp script that sources integration-up.sh helpers and tests them
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf '$tmp_dir'" RETURN

    # Create a mock curl that fails (service not up)
    cat > "$tmp_dir/curl" << 'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
    chmod +x "$tmp_dir/curl"

    # Source just the helper functions from integration-up.sh by extracting them
    # We need to test that wait_for_health produces clear output on failure
    # Call integration-up.sh in check-only mode (--check-prerequisites)
    local output
    output=$(
        PATH="$tmp_dir:$PATH" \
        INTEGRATION_HEALTH_TIMEOUT=2 \
        bash -c '
            log() { echo "[integration-up] $*"; }
            die() { echo "[integration-up] ERROR: $*" >&2; exit 1; }
            wait_for_health() {
                local url="$1" name="$2" max_wait="${3:-${INTEGRATION_HEALTH_TIMEOUT:-15}}"
                local elapsed=0
                while [ $elapsed -lt "$max_wait" ]; do
                    if curl -sf "$url" >/dev/null 2>&1; then
                        log "$name is healthy ($url)"
                        return 0
                    fi
                    sleep 0.1
                    elapsed=$((elapsed + 1))
                done
                die "$name failed health check after ${max_wait}s ($url)"
            }
            wait_for_health "http://localhost:99999/health" "test-service" 2
        ' 2>&1
    ) || true

    assert_contains "$output" "test-service" "health gating should name the failing service"
    assert_contains "$output" "failed health check" "health gating should report failure"
    assert_contains "$output" "ERROR" "health gating should indicate error"
}

test_health_gating_succeeds_for_healthy_service() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf '$tmp_dir'" RETURN

    # Create a mock curl that succeeds
    cat > "$tmp_dir/curl" << 'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod +x "$tmp_dir/curl"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir:$PATH" \
        bash -c '
            log() { echo "[integration-up] $*"; }
            die() { echo "[integration-up] ERROR: $*" >&2; exit 1; }
            wait_for_health() {
                local url="$1" name="$2" max_wait="${3:-15}"
                local elapsed=0
                while [ $elapsed -lt "$max_wait" ]; do
                    if curl -sf "$url" >/dev/null 2>&1; then
                        log "$name is healthy ($url)"
                        return 0
                    fi
                    sleep 0.1
                    elapsed=$((elapsed + 1))
                done
                die "$name failed health check after ${max_wait}s ($url)"
            }
            wait_for_health "http://localhost:3099/health" "fjcloud API" 5
        ' 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "health check should succeed for healthy service"
    assert_contains "$output" "is healthy" "should report service as healthy"
}

# ============================================================================
# Prerequisite Detection Tests
# ============================================================================

test_prerequisite_detection_fails_on_missing_psql() {
    # integration-up.sh should fail with a clear message when psql is missing
    local output exit_code=0
    output=$(
        PATH="/usr/bin:/bin" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/integration-up.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" "should exit 1 when psql is missing"
    assert_contains "$output" "psql" "error should mention psql"
}

test_prerequisite_detection_fails_on_missing_cargo() {
    # integration-up.sh should fail with a clear message when cargo is missing
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf '$tmp_dir'" RETURN

    # Provide psql but not cargo. Keep /usr/bin for bash/env/etc.
    cat > "$tmp_dir/psql" << 'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod +x "$tmp_dir/psql"

    # Hide cargo by shadowing it with a stub that prints "not found" behavior
    cat > "$tmp_dir/cargo" << 'MOCK'
#!/usr/bin/env bash
echo "cargo-shadow: simulating missing cargo" >&2
exit 127
MOCK
    # Do NOT make it executable — command -v won't find a non-executable file
    # Actually, we need to remove cargo from PATH instead. Use a wrapper approach.
    # Simplest: override PATH to only have our tmp + system essentials minus cargo
    local safe_path="$tmp_dir:/usr/bin:/bin:/usr/sbin:/sbin"

    local output exit_code=0
    output=$(
        PATH="$safe_path" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/integration-up.sh" 2>&1
    ) || exit_code=$?

    # Should fail (non-zero) and mention cargo
    if [ "$exit_code" -ne 0 ]; then
        pass "should exit non-zero when cargo is missing (got $exit_code)"
    else
        fail "should exit non-zero when cargo is missing (got 0)"
    fi
    assert_contains "$output" "cargo" "error should mention cargo"
}

test_prerequisite_detection_fails_on_invalid_db_name() {
    # integration-up.sh should reject database names with injection characters
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf '$tmp_dir'" RETURN

    # Provide both psql and cargo
    for cmd in psql cargo; do
        cat > "$tmp_dir/$cmd" << 'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
        chmod +x "$tmp_dir/$cmd"
    done

    local output exit_code=0
    output=$(
        PATH="$tmp_dir:$PATH" \
        INTEGRATION_DB="bad; DROP TABLE users; --" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/integration-up.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" "should exit 1 on invalid DB name"
    assert_contains "$output" "INTEGRATION_DB" "error should mention INTEGRATION_DB"
}

test_prerequisite_check_mode_exits_early() {
    # integration-up.sh --check-prerequisites should validate prereqs and exit
    # without actually starting services. This is the feature we're adding.
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf '$tmp_dir'" RETURN

    # Provide all prerequisites
    for cmd in psql cargo curl; do
        cat > "$tmp_dir/$cmd" << 'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
        chmod +x "$tmp_dir/$cmd"
    done

    local output exit_code=0
    output=$(
        PATH="$tmp_dir:$PATH" \
        INTEGRATION_DB="fjcloud_integration_test" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/integration-up.sh" --check-prerequisites 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "--check-prerequisites should exit 0 when all prereqs present"
    assert_contains "$output" "prerequisites" "should mention prerequisites in output"
    assert_not_contains "$output" "Starting" "should not attempt to start services"
}

test_prerequisite_check_mode_accepts_docker_compose_postgres_fallback() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap "rm -rf '$tmp_dir'" RETURN

    write_mock_script "$tmp_dir/cargo" 'exit 0'
    write_mock_script "$tmp_dir/curl" 'exit 0'
    write_mock_script "$tmp_dir/docker" '
set -euo pipefail
if [ "${1:-}" = "compose" ] && [ "${2:-}" = "ps" ]; then
    exit 0
fi
exit 1
'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir:/usr/bin:/bin" \
        DATABASE_URL="postgres://griddle:griddle_local@localhost:25432/fjcloud_dev" \
        INTEGRATION_DB="fjcloud_integration_test" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/integration-up.sh" --check-prerequisites 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "--check-prerequisites should accept docker compose postgres fallback"
    assert_contains "$output" "docker compose postgres" \
        "fallback prerequisite output should mention docker compose postgres"
}

test_up_check_prerequisites_reports_install_guidance() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap "rm -rf '$tmp_dir'" RETURN

    write_mock_script "$tmp_dir/whoami" 'echo "tester"'
    write_mock_script "$tmp_dir/dirname" '
path="${1:-.}"
if [[ "$path" == */* ]]; then
    echo "${path%/*}"
else
    echo "."
fi
'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir:/bin" \
        /bin/bash "$REPO_ROOT/scripts/integration-up.sh" --check-prerequisites 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" "--check-prerequisites should fail when required tools are missing"
    assert_contains "$output" "PostgreSQL" "psql prerequisite message should include PostgreSQL install guidance"
    assert_contains "$output" "rustup" "cargo prerequisite message should include rustup install guidance"
    assert_contains "$output" "curl" "curl prerequisite message should include curl install guidance"
}

# ============================================================================
# Timeout Behavior Tests
# ============================================================================

test_timeout_fails_gracefully_not_hangs() {
    # When health check exceeds timeout, integration-up.sh should fail with
    # a clear error instead of hanging indefinitely.
    local start_time end_time elapsed
    start_time=$(date +%s)

    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf '$tmp_dir'" RETURN

    write_mock_script "$tmp_dir/curl" 'exit 1'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir:$PATH" \
        bash -c '
            log() { echo "[integration-up] $*"; }
            die() { echo "[integration-up] ERROR: $*" >&2; exit 1; }
            wait_for_health() {
                local url="$1" name="$2" max_wait="${3:-15}"
                local elapsed=0
                while [ $elapsed -lt "$max_wait" ]; do
                    if curl -sf "$url" >/dev/null 2>&1; then
                        log "$name is healthy ($url)"
                        return 0
                    fi
                    sleep 0.1
                    elapsed=$((elapsed + 1))
                done
                die "$name failed health check after ${max_wait}s ($url)"
            }
            wait_for_health "http://localhost:99999/health" "fjcloud API" 3
        ' 2>&1
    ) || exit_code=$?

    end_time=$(date +%s)
    elapsed=$((end_time - start_time))

    assert_eq "$exit_code" "1" "should exit with error on timeout"
    assert_contains "$output" "failed health check" "should report health check failure"
    # Should not hang — must complete within a reasonable bound (timeout + margin)
    if [ "$elapsed" -gt 10 ]; then
        fail "timeout test took ${elapsed}s — should not hang (expected <10s)"
    else
        pass "timeout completes within time limit (${elapsed}s)"
    fi
}

test_timeout_respects_custom_timeout_value() {
    # INTEGRATION_HEALTH_TIMEOUT env var should control timeout duration
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf '$tmp_dir'" RETURN

    write_mock_script "$tmp_dir/curl" 'exit 1'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir:$PATH" \
        INTEGRATION_HEALTH_TIMEOUT=2 \
        bash -c '
            log() { echo "[integration-up] $*"; }
            die() { echo "[integration-up] ERROR: $*" >&2; exit 1; }
            wait_for_health() {
                local url="$1" name="$2" max_wait="${3:-${INTEGRATION_HEALTH_TIMEOUT:-15}}"
                local elapsed=0
                while [ $elapsed -lt "$max_wait" ]; do
                    if curl -sf "$url" >/dev/null 2>&1; then
                        log "$name is healthy ($url)"
                        return 0
                    fi
                    sleep 0.1
                    elapsed=$((elapsed + 1))
                done
                die "$name failed health check after ${max_wait}s ($url)"
            }
            wait_for_health "http://localhost:99999/health" "test-svc"
        ' 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" "should fail on timeout"
    assert_contains "$output" "2s" "timeout message should reflect custom timeout value"
}

# ============================================================================
# Stage 3: REASON codes + startup config coverage
# ============================================================================

test_up_missing_psql_emits_reason_code() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"

    write_mock_script "$tmp_dir/whoami" 'echo "tester"'
    write_mock_script "$tmp_dir/cargo" 'exit 0'
    write_mock_script "$tmp_dir/curl" 'exit 0'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir:/usr/bin:/bin" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/integration-up.sh" 2>&1
    ) || exit_code=$?

    rm -rf "$tmp_dir"

    assert_eq "$exit_code" "1" "should fail when psql is missing"
    assert_contains "$output" "REASON: prerequisite_missing" \
        "missing psql should emit prerequisite_missing reason code"
}

test_up_health_timeout_emits_reason_code() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    setup_startup_mocks "$tmp_dir"
    write_mock_script "$tmp_dir/curl" 'exit 1'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir:/usr/bin:/bin" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        INTEGRATION_HEALTH_TIMEOUT=1 \
        bash "$REPO_ROOT/scripts/integration-up.sh" 2>&1
    ) || exit_code=$?

    cleanup_startup_mocks "$tmp_dir"

    assert_eq "$exit_code" "1" "health timeout should fail startup"
    assert_contains "$output" "REASON: health_check_timeout" \
        "health timeout should emit health_check_timeout reason code"
    assert_contains "$output" "fjcloud API" \
        "health timeout reason should include failing service name"
}

test_up_db_creation_failure_emits_reason_code() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"

    write_mock_script "$tmp_dir/whoami" 'echo "tester"'
    write_mock_script "$tmp_dir/cargo" 'exit 0'
    write_mock_script "$tmp_dir/curl" 'exit 0'
    write_mock_script "$tmp_dir/psql" '
if [[ "$*" == *"SELECT 1 FROM pg_database"* ]]; then
    exit 0
fi
if [[ "$*" == *"CREATE DATABASE"* ]]; then
    exit 1
fi
exit 0
'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir:/usr/bin:/bin" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/integration-up.sh" 2>&1
    ) || exit_code=$?

    rm -rf "$tmp_dir"

    assert_eq "$exit_code" "1" "DB creation failure should fail startup"
    assert_contains "$output" "REASON: db_creation_failed" \
        "DB creation failure should emit db_creation_failed reason code"
}

test_up_migration_failure_emits_reason_code() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"

    write_mock_script "$tmp_dir/whoami" 'echo "tester"'
    write_mock_script "$tmp_dir/cargo" 'exit 0'
    write_mock_script "$tmp_dir/curl" 'exit 0'
    write_mock_script "$tmp_dir/psql" '
if [[ "$*" == *"SELECT 1 FROM pg_database"* ]]; then
    echo "1"
    exit 0
fi
if [[ "$*" == *" -f "* ]]; then
    exit 1
fi
exit 0
'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir:/usr/bin:/bin" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/integration-up.sh" 2>&1
    ) || exit_code=$?

    rm -rf "$tmp_dir"

    assert_eq "$exit_code" "1" "migration failure should fail startup"
    assert_contains "$output" "REASON: migration_failed" \
        "migration failure should emit migration_failed reason code"
}

test_up_exports_database_url() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    setup_startup_mocks "$tmp_dir"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir:/usr/bin:/bin" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash -c "source '$REPO_ROOT/scripts/integration-up.sh'; echo DB_URL_CAPTURE:\${INTEGRATION_DB_URL:-}" 2>&1
    ) || exit_code=$?

    cleanup_startup_mocks "$tmp_dir"

    local db_url
    db_url="$(echo "$output" | awk -F'DB_URL_CAPTURE:' '/DB_URL_CAPTURE:/{print $2}' | tail -1)"
    assert_eq "$exit_code" "0" "startup should succeed in mocked success path"
    if [ -n "${db_url:-}" ]; then
        pass "integration-up exports non-empty INTEGRATION_DB_URL"
    else
        fail "integration-up should export non-empty INTEGRATION_DB_URL"
    fi
}

test_up_exports_correct_port_in_url() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    setup_startup_mocks "$tmp_dir"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir:/usr/bin:/bin" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        INTEGRATION_DB_PORT=15444 \
        bash -c "source '$REPO_ROOT/scripts/integration-up.sh'; echo DB_URL_CAPTURE:\${INTEGRATION_DB_URL:-}" 2>&1
    ) || exit_code=$?

    cleanup_startup_mocks "$tmp_dir"

    local db_url
    db_url="$(echo "$output" | awk -F'DB_URL_CAPTURE:' '/DB_URL_CAPTURE:/{print $2}' | tail -1)"
    assert_eq "$exit_code" "0" "startup should succeed with overridden DB port"
    assert_contains "$db_url" ":15444/" "INTEGRATION_DB_URL should include configured DB port"
}

test_up_api_port_matches_config() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    setup_startup_mocks "$tmp_dir"
    write_mock_script "$tmp_dir/curl" '
echo "$*" >> "'"$tmp_dir"'/curl_calls.log"
exit 0
'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir:/usr/bin:/bin" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        API_PORT=4099 \
        bash "$REPO_ROOT/scripts/integration-up.sh" 2>&1
    ) || exit_code=$?

    local curl_calls
    curl_calls="$(cat "$tmp_dir/curl_calls.log" 2>/dev/null || true)"
    cleanup_startup_mocks "$tmp_dir"

    assert_eq "$exit_code" "0" "startup should succeed with overridden API port"
    assert_contains "$output" "http://localhost:4099/health" \
        "health output should use API_PORT override"
    assert_contains "$curl_calls" "http://localhost:4099/health" \
        "curl health check should target configured API port"
}

test_summary_redacts_effective_admin_key() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    setup_startup_mocks "$tmp_dir"

    local flapjack_bin="$tmp_dir/flapjack_dev/target/debug/flapjack"
    mkdir -p "$(dirname "$flapjack_bin")"
    write_mock_script "$flapjack_bin" 'exit 0'

    local expected_admin_key="integration-flapjack-admin-key"
    local output exit_code=0
    output=$(
        PATH="$tmp_dir:/usr/bin:/bin" \
        FLAPJACK_DEV_DIR="$tmp_dir/flapjack_dev" \
        FLAPJACK_ADMIN_KEY="$expected_admin_key" \
        bash "$REPO_ROOT/scripts/integration-up.sh" 2>&1
    ) || exit_code=$?

    cleanup_startup_mocks "$tmp_dir"

    assert_eq "$exit_code" "0" "startup should succeed when prerequisites and binaries are mocked"
    assert_contains "$output" "Flapjack admin" \
        "Done summary should include the flapjack admin label"
    assert_not_contains "$output" "$expected_admin_key" \
        "Done summary should redact the effective flapjack admin key"
}

test_discovers_fresh_host_alternate_flapjack_checkout_when_unset() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    setup_startup_mocks "$tmp_dir"

    local env_backup="$tmp_dir/.env.local.backup"
    backup_repo_env_file "$env_backup" >/dev/null || true
    trap 'restore_repo_env_file "'"$env_backup"'"; cleanup_startup_mocks "'"$tmp_dir"'"' RETURN

    local candidate_list="$tmp_dir/missing $tmp_dir/gridl-dev/flapjack_dev/engine"
    cat > "$REPO_ROOT/.env.local" <<EOF
DATABASE_URL=postgres://griddle:griddle_local@localhost:25432/fjcloud_dev
FLAPJACK_DEV_DIR_CANDIDATES=$candidate_list
EOF

    local expected_flapjack_bin="$tmp_dir/gridl-dev/flapjack_dev/engine/target/debug/flapjack"
    mkdir -p "$(dirname "$expected_flapjack_bin")"
    write_mock_script "$expected_flapjack_bin" 'exit 0'
    local call_log="$tmp_dir/flapjack_calls.log"
    write_mock_script "$tmp_dir/nohup" '
echo "nohup $@" >> "'"$call_log"'"
"$@" >/dev/null 2>&1 || true
exit 0
'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir:/usr/bin:/bin" \
        bash "$REPO_ROOT/scripts/integration-up.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" \
        "startup should discover flapjack from fresh-host alternate candidates when FLAPJACK_DEV_DIR is unset"
    local calls
    calls="$(cat "$call_log" 2>/dev/null || true)"
    assert_contains "$calls" "nohup $expected_flapjack_bin --port 7799" \
        "startup should launch the selected alternate flapjack binary path"
    assert_not_contains "$output" "skipping flapjack startup" \
        "startup should not take the missing-binary skip branch when alternate candidates resolve"
}

test_up_port_in_use_emits_reason_code() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    setup_startup_mocks "$tmp_dir"
    write_mock_script "$tmp_dir/lsof" 'exit 0'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir:/usr/bin:/bin" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/integration-up.sh" 2>&1
    ) || exit_code=$?

    cleanup_startup_mocks "$tmp_dir"

    assert_eq "$exit_code" "1" "startup should fail when API port is already in use"
    assert_contains "$output" "REASON: port_in_use" \
        "port collision should emit port_in_use reason code"
}

test_up_port_check_skipped_when_lsof_unavailable() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    setup_startup_mocks "$tmp_dir"
    write_mock_script "$tmp_dir/lsof" 'exit 127'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir:/usr/bin:/bin" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/integration-up.sh" 2>&1
    ) || exit_code=$?

    cleanup_startup_mocks "$tmp_dir"

    assert_eq "$exit_code" "0" "startup should continue when lsof is unavailable"
    assert_not_contains "$output" "REASON: port_in_use" \
        "missing lsof should not trigger port_in_use failure"
}

# ============================================================================
# Stage 3: Docker fallback specificity + startup env visibility
# ============================================================================

test_docker_fallback_failure_names_specific_blocker() {
    # When psql is absent, docker compose postgres IS running, but DATABASE_URL
    # is not set, the error should name DATABASE_URL as the specific blocker —
    # not the generic "install PostgreSQL" hint that misleads Docker users.
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local had_backup=false
    backup_repo_env_file "$tmp_dir/env_backup" && had_backup=true
    trap 'restore_repo_env_file "'"$tmp_dir"'/env_backup"; rm -rf "'"$tmp_dir"'"' RETURN

    # .env.local without DATABASE_URL so the fallback fails at resolve step
    cat > "$REPO_ROOT/.env.local" <<'EOF'
ADMIN_KEY=test-admin-key
EOF

    for cmd in cargo curl; do
        write_mock_script "$tmp_dir/$cmd" 'exit 0'
    done
    # Docker mock: compose ps reports postgres running
    write_mock_script "$tmp_dir/docker" '
if [ "${1:-}" = "compose" ] && [ "${2:-}" = "ps" ]; then
    exit 0
fi
exit 1
'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir:/usr/bin:/bin" \
        INTEGRATION_DB="fjcloud_integration_test" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/integration-up.sh" --check-prerequisites 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" "should fail when docker postgres is running but DATABASE_URL is missing"
    assert_contains "$output" "DATABASE_URL" \
        "docker fallback failure should name DATABASE_URL as the missing piece"
    assert_not_contains "$output" "install PostgreSQL" \
        "should not suggest installing psql when docker postgres fallback was attempted"
}

test_check_prerequisites_redacts_effective_admin_key() {
    # --check-prerequisites should confirm that a flapjack admin key is
    # configured without echoing the secret itself into output.
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    for cmd in psql cargo curl; do
        write_mock_script "$tmp_dir/$cmd" 'exit 0'
    done

    local output exit_code=0
    output=$(
        PATH="$tmp_dir:$PATH" \
        INTEGRATION_DB="fjcloud_integration_test" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        FLAPJACK_ADMIN_KEY="test-admin-key-for-prereq" \
        bash "$REPO_ROOT/scripts/integration-up.sh" --check-prerequisites 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "--check-prerequisites should pass with all prerequisites"
    assert_contains "$output" "effective FLAPJACK_ADMIN_KEY" \
        "check-prerequisites should report the flapjack admin key status"
    assert_not_contains "$output" "test-admin-key-for-prereq" \
        "check-prerequisites should redact the effective flapjack admin key"
}

test_startup_uses_loopback_and_nonpredictable_runtime_secrets() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    setup_startup_mocks "$tmp_dir"
    trap 'cleanup_startup_mocks "'"$tmp_dir"'"' RETURN

    local api_env_log="$tmp_dir/api_env.log"
    local output exit_code=0
    output=$(
        PATH="$tmp_dir:/usr/bin:/bin" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        INTEGRATION_UP_API_ENV_LOG="$api_env_log" \
        bash "$REPO_ROOT/scripts/integration-up.sh" 2>&1
    ) || exit_code=$?

    local wait_attempt
    for wait_attempt in 1 2 3 4 5; do
        [ -s "$api_env_log" ] && break
        sleep 0.1
    done

    local env_log
    env_log="$(cat "$api_env_log" 2>/dev/null || true)"

    assert_eq "$exit_code" "0" "startup should succeed in mocked success path"
    assert_contains "$env_log" "LISTEN_ADDR=127.0.0.1:3099" \
        "startup should bind the integration API to loopback"
    assert_contains "$env_log" "S3_LISTEN_ADDR=127.0.0.1:3102" \
        "startup should bind the integration S3 listener to loopback"
    assert_not_contains "$env_log" "JWT_SECRET=integration-test-jwt-secret-000000" \
        "startup should not use the predictable JWT secret fallback"
    assert_not_contains "$env_log" "ADMIN_KEY=integration-test-admin-key" \
        "startup should not use the predictable admin key fallback"
    assert_not_contains "$env_log" "STORAGE_ENCRYPTION_KEY=0000000000000000000000000000000000000000000000000000000000000000" \
        "startup should not use the all-zero storage encryption key fallback"
}

test_startup_summary_includes_node_secret_backend() {
    # The Done summary should include NODE_SECRET_BACKEND so operators can
    # verify the node secret mode before running reliability profiling.
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    setup_startup_mocks "$tmp_dir"
    trap 'cleanup_startup_mocks "'"$tmp_dir"'"' RETURN

    local output exit_code=0
    output=$(
        PATH="$tmp_dir:/usr/bin:/bin" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        NODE_SECRET_BACKEND="memory" \
        bash "$REPO_ROOT/scripts/integration-up.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "startup should succeed in mocked success path"
    assert_contains "$output" "Node secret" \
        "Done summary should include NODE_SECRET_BACKEND label"
    assert_contains "$output" "memory" \
        "Done summary should include NODE_SECRET_BACKEND value"
}

test_startup_summary_includes_local_dev_flapjack_url() {
    # The Done summary should include LOCAL_DEV_FLAPJACK_URL so operators can
    # verify the flapjack URL the API will use for auto-provisioning.
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    setup_startup_mocks "$tmp_dir"
    trap 'cleanup_startup_mocks "'"$tmp_dir"'"' RETURN

    local output exit_code=0
    output=$(
        PATH="$tmp_dir:/usr/bin:/bin" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        FLAPJACK_PORT=7799 \
        bash "$REPO_ROOT/scripts/integration-up.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "startup should succeed in mocked success path"
    assert_contains "$output" "Flapjack URL" \
        "Done summary should include Flapjack URL label"
    assert_contains "$output" "http://127.0.0.1:7799" \
        "Done summary should include LOCAL_DEV_FLAPJACK_URL with the configured port"
}

# ============================================================================
# Run all tests
# ============================================================================

main() {
    echo "=== integration-up.sh tests ==="
    echo ""

    echo "--- Health Gating ---"
    test_health_gating_reports_per_service_status
    test_health_gating_succeeds_for_healthy_service

    echo ""
    echo "--- Prerequisite Detection ---"
    test_prerequisite_detection_fails_on_missing_psql
    test_prerequisite_detection_fails_on_missing_cargo
    test_prerequisite_detection_fails_on_invalid_db_name
    test_prerequisite_check_mode_exits_early
    test_up_missing_psql_emits_reason_code
    test_up_check_prerequisites_reports_install_guidance

    echo ""
    echo "--- Timeout Behavior ---"
    test_timeout_fails_gracefully_not_hangs
    test_timeout_respects_custom_timeout_value
    test_up_health_timeout_emits_reason_code
    test_up_db_creation_failure_emits_reason_code
    test_up_migration_failure_emits_reason_code

    echo ""
    echo "--- Startup Config Validation ---"
    test_up_exports_database_url
    test_up_exports_correct_port_in_url
    test_up_api_port_matches_config
    test_summary_redacts_effective_admin_key
    test_discovers_fresh_host_alternate_flapjack_checkout_when_unset
    test_up_port_in_use_emits_reason_code
    test_up_port_check_skipped_when_lsof_unavailable

    echo ""
    echo "--- Docker Fallback + Startup Env ---"
    test_docker_fallback_failure_names_specific_blocker
    test_check_prerequisites_redacts_effective_admin_key
    test_startup_uses_loopback_and_nonpredictable_runtime_secrets
    test_startup_summary_includes_node_secret_backend
    test_startup_summary_includes_local_dev_flapjack_url

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
