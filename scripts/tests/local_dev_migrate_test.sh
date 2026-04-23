#!/usr/bin/env bash
# Tests for scripts/local-dev-migrate.sh host-psql behavior and Stage 3 fallback contracts.
# Uses mocked binaries and temp state — does NOT touch real services.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/test_helpers.sh
source "$SCRIPT_DIR/lib/test_helpers.sh"
# shellcheck source=lib/local_dev_test_state.sh
source "$SCRIPT_DIR/lib/local_dev_test_state.sh"

LOCAL_DEV_MIGRATE_HOST_DB_URL="postgres://host_user:host_secret@localhost:5432/host_db"
LOCAL_DEV_MIGRATE_FALLBACK_DB_URL="postgres://fallback_user:fallback_secret@localhost:5432/fallback_db"
LOCAL_DEV_MIGRATE_PARSE_DB_URL="postgres://parse_user:parse_secret@localhost:5432/parse_db"
LOCAL_DEV_MIGRATE_BAD_DB_URL="postgres://bad_user:bad_secret@localhost:notaport/bad_db"

setup_local_dev_repo_state() {
    local tmp_dir="$1"
    LOCAL_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    LOCAL_DEV_RUNTIME_BACKUP=$(backup_repo_path "$REPO_ROOT/.local" "$tmp_dir/.local.backup")
    write_local_dev_env_file "$REPO_ROOT/.env.local" "$LOCAL_DEV_MIGRATE_HOST_DB_URL"
    mkdir -p "$REPO_ROOT/.local"
}

restore_local_dev_repo_state() {
    restore_repo_path "$REPO_ROOT/.env.local" "${LOCAL_DEV_ENV_BACKUP:-}"
    restore_repo_path "$REPO_ROOT/.local" "${LOCAL_DEV_RUNTIME_BACKUP:-}"
    LOCAL_DEV_ENV_BACKUP=""
    LOCAL_DEV_RUNTIME_BACKUP=""
}

write_host_psql_mock() {
    local path="$1"
    cat > "$path" <<'MOCK'
#!/usr/bin/env bash
echo "psql $*" >> "$MOCK_CALL_LOG"

if [[ "$*" == *"-tAc"*"SELECT count(*) FROM _schema_migrations"* ]]; then
    echo "1"
    exit 0
fi

if [[ "$*" == *"-tAc"*"SELECT 1 FROM _schema_migrations WHERE filename="* ]]; then
    exit 0
fi

exit 0
MOCK
    chmod +x "$path"
}

write_docker_migration_mock() {
    local path="$1"
    cat > "$path" <<'MOCK'
#!/usr/bin/env bash
echo "docker $*" >> "$MOCK_CALL_LOG"

if [[ "$*" == *"-tAc"*"SELECT count(*) FROM _schema_migrations"* ]]; then
    echo "1"
    exit 0
fi

if [[ "$*" == *"-tAc"*"SELECT 1 FROM _schema_migrations WHERE filename="* ]]; then
    if [ "${MOCK_ALL_MIGRATIONS_TRACKED:-0}" = "1" ]; then
        echo "1"
    fi
    exit 0
fi

exit 0
MOCK
    chmod +x "$path"
}

write_unavailable_docker_mock() {
    local path="$1"
    cat > "$path" <<'MOCK'
#!/usr/bin/env bash
echo "docker $*" >> "$MOCK_CALL_LOG"
echo "docker compose exec failed" >&2
exit 1
MOCK
    chmod +x "$path"
}

test_host_psql_happy_path_uses_repo_migrations_and_redacts_output() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_local_dev_repo_state "$tmp_dir"

    mkdir -p "$tmp_dir/bin"
    write_host_psql_mock "$tmp_dir/bin/psql"

    export MOCK_CALL_LOG="$tmp_dir/calls.log"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:/usr/bin:/bin" \
        DATABASE_URL="$LOCAL_DEV_MIGRATE_HOST_DB_URL" \
        bash "$REPO_ROOT/scripts/local-dev-migrate.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "host psql path should succeed"

    local calls
    calls=$(cat "$MOCK_CALL_LOG" 2>/dev/null || true)
    assert_contains "$calls" "psql $LOCAL_DEV_MIGRATE_HOST_DB_URL" \
        "host psql should receive DATABASE_URL"
    assert_contains "$calls" "$REPO_ROOT/infra/migrations/" \
        "host psql should apply migrations from repo infra/migrations"

    assert_contains "$output" "postgres://host_user:***@localhost:5432/host_db" \
        "output should redact database URL password"
    assert_not_contains "$output" "host_secret" \
        "output should not leak the raw password"

    unset MOCK_CALL_LOG
}

test_missing_host_psql_uses_docker_fallback_runner_shape() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_local_dev_repo_state "$tmp_dir"

    mkdir -p "$tmp_dir/bin"
    write_docker_migration_mock "$tmp_dir/bin/docker"

    export MOCK_CALL_LOG="$tmp_dir/calls.log"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:/usr/bin:/bin" \
        DATABASE_URL="$LOCAL_DEV_MIGRATE_FALLBACK_DB_URL" \
        bash "$REPO_ROOT/scripts/local-dev-migrate.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "missing host psql should fall back to docker runner"

    local calls
    calls=$(cat "$MOCK_CALL_LOG" 2>/dev/null || true)
    assert_contains "$calls" "docker compose exec -T postgres env PGPASSWORD=fallback_secret psql -h 127.0.0.1 -U fallback_user -d fallback_db" \
        "docker fallback should run psql through compose exec with parsed DB fields"
    assert_not_contains "$output" "install PostgreSQL client" \
        "fallback mode should not instruct host psql install"

    unset MOCK_CALL_LOG
}

test_docker_fallback_uses_migrations_runner_path_contract() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_local_dev_repo_state "$tmp_dir"

    mkdir -p "$tmp_dir/bin"
    write_docker_migration_mock "$tmp_dir/bin/docker"

    export MOCK_CALL_LOG="$tmp_dir/calls.log"

    local first_migration
    first_migration=$(ls "$REPO_ROOT/infra/migrations"/*.sql | sort | head -1)
    first_migration=$(basename "$first_migration")

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:/usr/bin:/bin" \
        DATABASE_URL="$LOCAL_DEV_MIGRATE_FALLBACK_DB_URL" \
        bash "$REPO_ROOT/scripts/local-dev-migrate.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "docker fallback should complete migration run"

    local calls
    calls=$(cat "$MOCK_CALL_LOG" 2>/dev/null || true)
    assert_contains "$calls" "-f /migrations/$first_migration" \
        "docker apply calls should use /migrations/<filename>.sql"
    assert_not_contains "$calls" "-f $REPO_ROOT/infra/migrations/$first_migration" \
        "docker apply calls should not use repo-host file paths"

    unset MOCK_CALL_LOG
}

test_docker_fallback_parses_database_url_and_keeps_password_secret() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_local_dev_repo_state "$tmp_dir"

    mkdir -p "$tmp_dir/bin"
    write_docker_migration_mock "$tmp_dir/bin/docker"

    export MOCK_CALL_LOG="$tmp_dir/calls.log"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:/usr/bin:/bin" \
        DATABASE_URL="$LOCAL_DEV_MIGRATE_PARSE_DB_URL" \
        bash "$REPO_ROOT/scripts/local-dev-migrate.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "docker fallback should succeed with parse-focused DATABASE_URL"

    local calls
    calls=$(cat "$MOCK_CALL_LOG" 2>/dev/null || true)
    assert_contains "$calls" "env PGPASSWORD=parse_secret psql -h 127.0.0.1 -U parse_user -d parse_db" \
        "docker runner should use parsed user/password/database values"
    assert_not_contains "$output" "parse_secret" \
        "stdout/stderr should not leak the raw password"

    unset MOCK_CALL_LOG
}

test_missing_database_url_reports_actionable_error() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_local_dev_repo_state "$tmp_dir"

    mkdir -p "$tmp_dir/bin"
    write_docker_migration_mock "$tmp_dir/bin/docker"

    export MOCK_CALL_LOG="$tmp_dir/calls.log"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:/usr/bin:/bin" \
        bash "$REPO_ROOT/scripts/local-dev-migrate.sh" 2>&1
    ) || exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        pass "missing DATABASE_URL should fail"
    else
        fail "missing DATABASE_URL should return non-zero"
    fi

    assert_contains "$output" "DATABASE_URL" \
        "missing DATABASE_URL should report an actionable DATABASE_URL error"
    assert_not_contains "$output" "install PostgreSQL client" \
        "missing DATABASE_URL should not suggest host psql install"

    unset MOCK_CALL_LOG
}

test_malformed_database_url_reports_actionable_error_without_install_hint() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_local_dev_repo_state "$tmp_dir"

    mkdir -p "$tmp_dir/bin"
    write_docker_migration_mock "$tmp_dir/bin/docker"

    export MOCK_CALL_LOG="$tmp_dir/calls.log"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:/usr/bin:/bin" \
        DATABASE_URL="$LOCAL_DEV_MIGRATE_BAD_DB_URL" \
        bash "$REPO_ROOT/scripts/local-dev-migrate.sh" 2>&1
    ) || exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        pass "malformed DATABASE_URL should fail"
    else
        fail "malformed DATABASE_URL should return non-zero"
    fi

    assert_contains "$output" "DATABASE_URL" \
        "malformed DATABASE_URL should report actionable parse guidance"
    assert_not_contains "$output" "install PostgreSQL client" \
        "malformed DATABASE_URL should not degrade to host psql install hint"
    assert_not_contains "$output" "bad_secret" \
        "malformed DATABASE_URL errors should not leak the raw password"

    unset MOCK_CALL_LOG
}

test_malformed_database_url_reports_configuration_error_when_docker_missing() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_local_dev_repo_state "$tmp_dir"

    mkdir -p "$tmp_dir/bin"
    export MOCK_CALL_LOG="$tmp_dir/calls.log"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:/usr/bin:/bin" \
        DATABASE_URL="$LOCAL_DEV_MIGRATE_BAD_DB_URL" \
        bash "$REPO_ROOT/scripts/local-dev-migrate.sh" 2>&1
    ) || exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        pass "malformed DATABASE_URL should fail before docker availability checks"
    else
        fail "malformed DATABASE_URL with docker missing should return non-zero"
    fi

    assert_contains "$output" "DATABASE_URL must include a valid port" \
        "malformed DATABASE_URL should remain a configuration error even without docker"
    assert_not_contains "$output" "install/start docker compose postgres" \
        "malformed DATABASE_URL should not degrade into a docker tooling hint"
    assert_not_contains "$output" "bad_secret" \
        "malformed DATABASE_URL errors should not leak raw password when docker is absent"

    unset MOCK_CALL_LOG
}

test_migration_tracking_preserved_when_all_migrations_already_applied() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_local_dev_repo_state "$tmp_dir"

    mkdir -p "$tmp_dir/bin"
    write_docker_migration_mock "$tmp_dir/bin/docker"

    export MOCK_CALL_LOG="$tmp_dir/calls.log"
    export MOCK_ALL_MIGRATIONS_TRACKED="1"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:/usr/bin:/bin" \
        DATABASE_URL="$LOCAL_DEV_MIGRATE_FALLBACK_DB_URL" \
        bash "$REPO_ROOT/scripts/local-dev-migrate.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "tracked migrations should not fail fallback runner"
    assert_contains "$output" "skipped" \
        "should report already-applied migrations as skipped"

    local apply_calls
    apply_calls=$(grep -c "\\-f /migrations/" "$MOCK_CALL_LOG" 2>/dev/null || true)
    assert_eq "$apply_calls" "0" "should not re-apply tracked migrations"

    unset MOCK_CALL_LOG
    unset MOCK_ALL_MIGRATIONS_TRACKED
}

test_no_access_paths_fail_with_actionable_error_without_secret_leak() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_local_dev_repo_state "$tmp_dir"

    mkdir -p "$tmp_dir/bin"
    write_unavailable_docker_mock "$tmp_dir/bin/docker"

    export MOCK_CALL_LOG="$tmp_dir/calls.log"

    local db_url="postgres://none_user:none_secret@localhost:5432/none_db"
    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:/usr/bin:/bin" \
        DATABASE_URL="$db_url" \
        bash "$REPO_ROOT/scripts/local-dev-migrate.sh" 2>&1
    ) || exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        pass "missing host psql + unavailable docker should fail"
    else
        fail "no database access path should return non-zero"
    fi

    assert_contains "$output" "psql" \
        "failure should mention host psql availability"
    assert_contains "$output" "docker" \
        "failure should mention docker/postgres access path"
    assert_not_contains "$output" "none_secret" \
        "failure output should not leak DATABASE_URL password"

    unset MOCK_CALL_LOG
}

main() {
    echo "=== local-dev-migrate.sh tests ==="
    echo ""

    test_host_psql_happy_path_uses_repo_migrations_and_redacts_output
    test_missing_host_psql_uses_docker_fallback_runner_shape
    test_docker_fallback_uses_migrations_runner_path_contract
    test_docker_fallback_parses_database_url_and_keeps_password_secret
    test_missing_database_url_reports_actionable_error
    test_malformed_database_url_reports_actionable_error_without_install_hint
    test_malformed_database_url_reports_configuration_error_when_docker_missing
    test_migration_tracking_preserved_when_all_migrations_already_applied
    test_no_access_paths_fail_with_actionable_error_without_secret_leak

    run_test_summary
}

main "$@"
