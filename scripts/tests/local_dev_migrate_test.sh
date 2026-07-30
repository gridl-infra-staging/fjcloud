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
LOCAL_DEV_PROBE_SCRIPT=""
LOCAL_DEV_TEST_REPO_ROOT=""

setup_local_dev_repo_state() {
    local tmp_dir="$1"
    LOCAL_DEV_TEST_REPO_ROOT="$(create_local_dev_fixture_repo_root "$tmp_dir" "$LOCAL_DEV_MIGRATE_HOST_DB_URL")"
    mkdir -p "$LOCAL_DEV_TEST_REPO_ROOT/infra"
    cp -R "$REPO_ROOT/infra/migrations" "$LOCAL_DEV_TEST_REPO_ROOT/infra/"
}

restore_local_dev_repo_state() {
    LOCAL_DEV_PROBE_SCRIPT=""
    LOCAL_DEV_TEST_REPO_ROOT=""
}

run_local_dev_migrate() {
    FJCLOUD_REPO_ROOT="$LOCAL_DEV_TEST_REPO_ROOT" \
        bash "$REPO_ROOT/scripts/local-dev-migrate.sh"
}

write_probe_mock() {
    local tmp_dir="$1" exit_code="${2:-0}"
    LOCAL_DEV_PROBE_SCRIPT="$tmp_dir/probe_local_schema_drift.mock.sh"
    cat > "$LOCAL_DEV_PROBE_SCRIPT" <<MOCK
#!/usr/bin/env bash
echo "probe \${DATABASE_URL:-}" >> "\$MOCK_CALL_LOG"
echo "[probe] local schema drift probe ran"
exit $exit_code
MOCK
    chmod +x "$LOCAL_DEV_PROBE_SCRIPT"
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

if [[ "$*" == *"CREATE DATABASE"* ]]; then
    db_name="$(printf '%s\n' "$*" | sed -E 's/.*CREATE DATABASE "?([A-Za-z0-9_]+)"?.*/\1/')"
    printf 'create|%s\n' "$db_name" >> "$MOCK_ROUTE_LOG"
    printf '%s\n' "$db_name" > "$MOCK_SCRATCH_DB_FILE"
    exit 0
fi

if [[ "$*" == *"DROP DATABASE"* ]]; then
    db_name="$(printf '%s\n' "$*" | sed -E 's/.*DROP DATABASE IF EXISTS "?([A-Za-z0-9_]+)"?.*/\1/')"
    printf 'drop|%s\n' "$db_name" >> "$MOCK_ROUTE_LOG"
    exit 0
fi

if [[ "$*" == *"information_schema.columns"* ]]; then
    scratch_db="$(cat "$MOCK_SCRATCH_DB_FILE" 2>/dev/null || true)"

    if [ -n "${MOCK_TARGET_DB_NAME:-}" ] && [[ "$*" == *"-d ${MOCK_TARGET_DB_NAME}"* ]]; then
        printf 'target_schema_query\n' >> "$MOCK_ROUTE_LOG"
        cat "$MOCK_FIXTURE_DIR/target_identical.columns"
        exit 0
    fi

    if [ -n "$scratch_db" ] && [[ "$*" == *"-d ${scratch_db}"* ]]; then
        printf 'oracle_schema_query|%s\n' "$scratch_db" >> "$MOCK_ROUTE_LOG"
        cat "$MOCK_FIXTURE_DIR/oracle.columns"
        exit 0
    fi

    echo "schema query did not identify target or scratch database" >&2
    exit 2
fi

exit 0
MOCK
    chmod +x "$path"
}

write_schema_probe_fixtures() {
    local fixture_dir="$1"
    mkdir -p "$fixture_dir"

    cat > "$fixture_dir/oracle.columns" <<'EOF'
public|accounts|id|uuid|NO|
public|accounts|email|text|NO|
EOF

    cp "$fixture_dir/oracle.columns" "$fixture_dir/target_identical.columns"
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

write_failing_host_psql_mock() {
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

if [[ "$*" == *" -f "* ]]; then
    echo "migration apply failed" >&2
    exit 9
fi

exit 0
MOCK
    chmod +x "$path"
}

assert_call_order() {
    local call_log="$1" first="$2" second="$3" message="$4"
    if python3 - "$call_log" "$first" "$second" <<'PY'
import sys

path, first, second = sys.argv[1:4]
with open(path, encoding="utf-8") as handle:
    lines = handle.read().splitlines()

first_index = next((index for index, line in enumerate(lines) if first in line), -1)
second_index = next((index for index, line in enumerate(lines) if second in line), -1)
if first_index < 0 or second_index < 0 or first_index >= second_index:
    raise SystemExit(1)
PY
    then
        pass "$message"
    else
        fail "$message (expected '$first' before '$second')"
    fi
}

assert_output_order() {
    local output="$1" first="$2" second="$3" message="$4"
    if python3 - "$output" "$first" "$second" <<'PY'
import sys

output, first, second = sys.argv[1:4]
first_index = output.find(first)
second_index = output.find(second)
if first_index < 0 or second_index < 0 or first_index >= second_index:
    raise SystemExit(1)
PY
    then
        pass "$message"
    else
        fail "$message (expected '$first' before '$second')"
    fi
}

test_host_psql_happy_path_uses_repo_migrations_and_redacts_output() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_local_dev_repo_state "$tmp_dir"
    write_probe_mock "$tmp_dir" "0"

    mkdir -p "$tmp_dir/bin"
    write_host_psql_mock "$tmp_dir/bin/psql"

    export MOCK_CALL_LOG="$tmp_dir/calls.log"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:/usr/bin:/bin" \
        DATABASE_URL="$LOCAL_DEV_MIGRATE_HOST_DB_URL" \
        FJCLOUD_TEST_SCHEMA_DRIFT_PROBE_SCRIPT="$LOCAL_DEV_PROBE_SCRIPT" \
        run_local_dev_migrate 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "host psql path should succeed"

    local calls
    calls=$(cat "$MOCK_CALL_LOG" 2>/dev/null || true)
    assert_contains "$calls" "psql $LOCAL_DEV_MIGRATE_HOST_DB_URL" \
        "host psql should receive DATABASE_URL"
    assert_contains "$calls" "$LOCAL_DEV_TEST_REPO_ROOT/infra/migrations/" \
        "host psql should apply migrations from the fixture repo infra/migrations"

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
    write_probe_mock "$tmp_dir" "0"

    mkdir -p "$tmp_dir/bin"
    write_docker_migration_mock "$tmp_dir/bin/docker"

    export MOCK_CALL_LOG="$tmp_dir/calls.log"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:/usr/bin:/bin" \
        DATABASE_URL="$LOCAL_DEV_MIGRATE_FALLBACK_DB_URL" \
        FJCLOUD_TEST_SCHEMA_DRIFT_PROBE_SCRIPT="$LOCAL_DEV_PROBE_SCRIPT" \
        run_local_dev_migrate 2>&1
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
    write_probe_mock "$tmp_dir" "0"

    mkdir -p "$tmp_dir/bin"
    write_docker_migration_mock "$tmp_dir/bin/docker"

    export MOCK_CALL_LOG="$tmp_dir/calls.log"

    local first_migration
    first_migration=$(ls "$LOCAL_DEV_TEST_REPO_ROOT/infra/migrations"/*.sql | sort | head -1)
    first_migration=$(basename "$first_migration")

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:/usr/bin:/bin" \
        DATABASE_URL="$LOCAL_DEV_MIGRATE_FALLBACK_DB_URL" \
        FJCLOUD_TEST_SCHEMA_DRIFT_PROBE_SCRIPT="$LOCAL_DEV_PROBE_SCRIPT" \
        run_local_dev_migrate 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "docker fallback should complete migration run"

    local calls
    calls=$(cat "$MOCK_CALL_LOG" 2>/dev/null || true)
    assert_contains "$calls" "-f /migrations/$first_migration" \
        "docker apply calls should use /migrations/<filename>.sql"
    assert_not_contains "$calls" "-f $LOCAL_DEV_TEST_REPO_ROOT/infra/migrations/$first_migration" \
        "docker apply calls should not use repo-host file paths"

    unset MOCK_CALL_LOG
}

test_docker_fallback_parses_database_url_and_keeps_password_secret() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_local_dev_repo_state "$tmp_dir"
    write_probe_mock "$tmp_dir" "0"

    mkdir -p "$tmp_dir/bin"
    write_docker_migration_mock "$tmp_dir/bin/docker"

    export MOCK_CALL_LOG="$tmp_dir/calls.log"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:/usr/bin:/bin" \
        DATABASE_URL="$LOCAL_DEV_MIGRATE_PARSE_DB_URL" \
        FJCLOUD_TEST_SCHEMA_DRIFT_PROBE_SCRIPT="$LOCAL_DEV_PROBE_SCRIPT" \
        run_local_dev_migrate 2>&1
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
        env -u DATABASE_URL \
        FJCLOUD_REPO_ROOT="$LOCAL_DEV_TEST_REPO_ROOT" \
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
        run_local_dev_migrate 2>&1
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
        run_local_dev_migrate 2>&1
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
    write_probe_mock "$tmp_dir" "0"

    mkdir -p "$tmp_dir/bin"
    write_docker_migration_mock "$tmp_dir/bin/docker"

    export MOCK_CALL_LOG="$tmp_dir/calls.log"
    export MOCK_ALL_MIGRATIONS_TRACKED="1"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:/usr/bin:/bin" \
        DATABASE_URL="$LOCAL_DEV_MIGRATE_FALLBACK_DB_URL" \
        FJCLOUD_TEST_SCHEMA_DRIFT_PROBE_SCRIPT="$LOCAL_DEV_PROBE_SCRIPT" \
        run_local_dev_migrate 2>&1
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

test_docker_fallback_runs_schema_drift_probe_with_wrapper() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_local_dev_repo_state "$tmp_dir"

    mkdir -p "$tmp_dir/bin" "$tmp_dir/fixtures"
    write_docker_migration_mock "$tmp_dir/bin/docker"
    write_schema_probe_fixtures "$tmp_dir/fixtures"

    export MOCK_CALL_LOG="$tmp_dir/calls.log"
    export MOCK_ROUTE_LOG="$tmp_dir/routes.log"
    export MOCK_SCRATCH_DB_FILE="$tmp_dir/scratch_db_name"
    export MOCK_FIXTURE_DIR="$tmp_dir/fixtures"
    export MOCK_TARGET_DB_NAME="fallback_db"
    export MOCK_ALL_MIGRATIONS_TRACKED="1"
    : > "$MOCK_CALL_LOG"
    : > "$MOCK_ROUTE_LOG"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:/usr/bin:/bin" \
        DATABASE_URL="$LOCAL_DEV_MIGRATE_FALLBACK_DB_URL" \
        run_local_dev_migrate 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "docker fallback plus wrapper-backed probe should succeed"
    assert_contains "$output" "no local schema drift" \
        "docker fallback probe should report clean schema"
    assert_output_order "$output" "no local schema drift" "[local-dev-migrate] Done" \
        "docker fallback probe should finish before Done"

    local routes created dropped
    routes=$(cat "$MOCK_ROUTE_LOG" 2>/dev/null || true)
    created="$(awk -F'|' '$1 == "create" { print $2; exit }' "$MOCK_ROUTE_LOG")"
    dropped="$(awk -F'|' '$1 == "drop" { print $2; exit }' "$MOCK_ROUTE_LOG")"

    assert_contains "$routes" "target_schema_query" \
        "docker fallback probe should inspect the target schema through docker psql"
    assert_contains "$routes" "oracle_schema_query" \
        "docker fallback probe should inspect the scratch oracle schema through docker psql"
    assert_ne "$created" "" \
        "docker fallback probe should create a scratch database"
    assert_eq "$dropped" "$created" \
        "docker fallback probe should drop the created scratch database"

    unset MOCK_CALL_LOG
    unset MOCK_ROUTE_LOG
    unset MOCK_SCRATCH_DB_FILE
    unset MOCK_FIXTURE_DIR
    unset MOCK_TARGET_DB_NAME
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
        run_local_dev_migrate 2>&1
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

test_successful_migration_runs_schema_drift_probe_before_done() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_local_dev_repo_state "$tmp_dir"
    write_probe_mock "$tmp_dir" "0"

    mkdir -p "$tmp_dir/bin"
    write_host_psql_mock "$tmp_dir/bin/psql"

    export MOCK_CALL_LOG="$tmp_dir/calls.log"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:/usr/bin:/bin" \
        DATABASE_URL="$LOCAL_DEV_MIGRATE_HOST_DB_URL" \
        FJCLOUD_TEST_SCHEMA_DRIFT_PROBE_SCRIPT="$LOCAL_DEV_PROBE_SCRIPT" \
        run_local_dev_migrate 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "successful migration plus drift probe should exit 0"

    local calls
    calls=$(cat "$MOCK_CALL_LOG" 2>/dev/null || true)
    assert_contains "$calls" "probe $LOCAL_DEV_MIGRATE_HOST_DB_URL" \
        "local-dev-migrate should invoke schema drift probe with DATABASE_URL"
    assert_call_order "$MOCK_CALL_LOG" " -f $LOCAL_DEV_TEST_REPO_ROOT/infra/migrations/" "probe $LOCAL_DEV_MIGRATE_HOST_DB_URL" \
        "schema drift probe should run after migration apply"
    assert_output_order "$output" "[probe] local schema drift probe ran" "[local-dev-migrate] Done" \
        "schema drift probe output should appear before Done"

    unset MOCK_CALL_LOG
}

test_migration_failure_skips_schema_drift_probe() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_local_dev_repo_state "$tmp_dir"
    write_probe_mock "$tmp_dir" "0"

    mkdir -p "$tmp_dir/bin"
    write_failing_host_psql_mock "$tmp_dir/bin/psql"

    export MOCK_CALL_LOG="$tmp_dir/calls.log"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:/usr/bin:/bin" \
        DATABASE_URL="$LOCAL_DEV_MIGRATE_HOST_DB_URL" \
        FJCLOUD_TEST_SCHEMA_DRIFT_PROBE_SCRIPT="$LOCAL_DEV_PROBE_SCRIPT" \
        run_local_dev_migrate 2>&1
    ) || exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        pass "migration failure should exit non-zero"
    else
        fail "migration failure should return non-zero"
    fi

    local calls
    calls=$(cat "$MOCK_CALL_LOG" 2>/dev/null || true)
    assert_not_contains "$calls" "probe $LOCAL_DEV_MIGRATE_HOST_DB_URL" \
        "migration failure should skip schema drift probe"
    assert_not_contains "$output" "[local-dev-migrate] Done" \
        "migration failure should not print Done"

    unset MOCK_CALL_LOG
}

test_schema_drift_probe_failure_propagates_and_skips_done() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_local_dev_repo_state "$tmp_dir"
    write_probe_mock "$tmp_dir" "7"

    mkdir -p "$tmp_dir/bin"
    write_host_psql_mock "$tmp_dir/bin/psql"

    export MOCK_CALL_LOG="$tmp_dir/calls.log"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:/usr/bin:/bin" \
        DATABASE_URL="$LOCAL_DEV_MIGRATE_HOST_DB_URL" \
        FJCLOUD_TEST_SCHEMA_DRIFT_PROBE_SCRIPT="$LOCAL_DEV_PROBE_SCRIPT" \
        run_local_dev_migrate 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" "schema drift probe failure should propagate as local-dev-migrate failure"

    local calls
    calls=$(cat "$MOCK_CALL_LOG" 2>/dev/null || true)
    assert_contains "$calls" "probe $LOCAL_DEV_MIGRATE_HOST_DB_URL" \
        "schema drift probe failure path should invoke the probe"
    assert_contains "$output" "schema drift probe failed" \
        "schema drift probe failure should explain failed post-migration validation"
    assert_not_contains "$output" "[local-dev-migrate] Done" \
        "schema drift probe failure should not print Done"

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
    test_docker_fallback_runs_schema_drift_probe_with_wrapper
    test_no_access_paths_fail_with_actionable_error_without_secret_leak
    test_successful_migration_runs_schema_drift_probe_before_done
    test_migration_failure_skips_schema_drift_probe
    test_schema_drift_probe_failure_propagates_and_skips_done

    run_test_summary
}

main "$@"
