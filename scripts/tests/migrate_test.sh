#!/usr/bin/env bash
# Tests for scripts/lib/migrate.sh: run_migrations function.
# These tests use mock psql — they do NOT touch a real database.

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

# Caller-provided log() required by migrate.sh
LOG_OUTPUT=""
log() { LOG_OUTPUT+="[migrate] $*"$'\n'; }

# shellcheck source=../../scripts/lib/migrate.sh
source "$REPO_ROOT/scripts/lib/migrate.sh"

# ============================================================================
# Tests
# ============================================================================

test_applies_all_sql_files_in_sorted_order() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf '$tmp_dir'" RETURN

    # Create numbered SQL fixture files
    touch "$tmp_dir/001_first.sql"
    touch "$tmp_dir/002_second.sql"
    touch "$tmp_dir/003_third.sql"

    # Mock psql that records which files it was called with
    local mock_bin="$tmp_dir/bin"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/psql" << 'MOCK'
#!/usr/bin/env bash
# Record the -f argument
for arg in "$@"; do
    if [ "$prev" = "-f" ]; then
        echo "$arg" >> "$MOCK_CALL_LOG"
    fi
    prev="$arg"
done
exit 0
MOCK
    chmod +x "$mock_bin/psql"

    export MOCK_CALL_LOG="$tmp_dir/psql_calls.log"
    LOG_OUTPUT=""

    PATH="$mock_bin:$PATH" run_migrations "postgres://test@localhost/testdb" "$tmp_dir"
    local exit_code=$?

    assert_eq "$exit_code" "0" "run_migrations should return 0 on success"

    # Verify all three files were applied
    local call_count
    call_count=$(wc -l < "$MOCK_CALL_LOG" | tr -d ' ')
    assert_eq "$call_count" "3" "should apply all 3 migration files"

    # Verify sorted order
    local first_file
    first_file=$(head -1 "$MOCK_CALL_LOG")
    assert_contains "$first_file" "001_first.sql" "first migration should be 001"

    local last_file
    last_file=$(tail -1 "$MOCK_CALL_LOG")
    assert_contains "$last_file" "003_third.sql" "last migration should be 003"

    # Verify log output mentions each file
    assert_contains "$LOG_OUTPUT" "001_first.sql" "log should mention first migration"
    assert_contains "$LOG_OUTPUT" "003_third.sql" "log should mention last migration"

    unset MOCK_CALL_LOG
}

test_returns_nonzero_on_migration_failure() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf '$tmp_dir'" RETURN

    touch "$tmp_dir/001_good.sql"
    touch "$tmp_dir/002_bad.sql"
    touch "$tmp_dir/003_never_reached.sql"

    local mock_bin="$tmp_dir/bin"
    mkdir -p "$mock_bin"
    export MOCK_CALL_LOG="$tmp_dir/psql_calls.log"
    cat > "$mock_bin/psql" << 'MOCK'
#!/usr/bin/env bash
# Record each migration and fail on the second migration file
for arg in "$@"; do
    if [ "$prev" = "-f" ]; then
        echo "$arg" >> "$MOCK_CALL_LOG"
        if [[ "$arg" == *"002_bad"* ]]; then
            exit 1
        fi
    fi
    prev="$arg"
done
exit 0
MOCK
    chmod +x "$mock_bin/psql"

    LOG_OUTPUT=""

    local exit_code=0
    PATH="$mock_bin:$PATH" run_migrations "postgres://test@localhost/testdb" "$tmp_dir" || exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        pass "run_migrations returns non-zero on psql failure"
    else
        fail "run_migrations should return non-zero when psql fails (got 0)"
    fi

    assert_contains "$LOG_OUTPUT" "002_bad.sql" "log should mention the failed migration"

    local call_count
    call_count=$(wc -l < "$MOCK_CALL_LOG" | tr -d ' ')
    assert_eq "$call_count" "2" "run_migrations should stop after the failed migration"

    unset MOCK_CALL_LOG
}

test_passes_db_url_to_psql() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf '$tmp_dir'" RETURN

    touch "$tmp_dir/001_test.sql"

    local mock_bin="$tmp_dir/bin"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/psql" << 'MOCK'
#!/usr/bin/env bash
echo "$1" >> "$MOCK_CALL_LOG"
exit 0
MOCK
    chmod +x "$mock_bin/psql"

    export MOCK_CALL_LOG="$tmp_dir/psql_args.log"
    LOG_OUTPUT=""

    PATH="$mock_bin:$PATH" run_migrations "postgres://fjcloud:fjcloud@localhost:5432/fjcloud_dev" "$tmp_dir"

    local first_arg
    first_arg=$(head -1 "$MOCK_CALL_LOG")
    assert_eq "$first_arg" "postgres://fjcloud:fjcloud@localhost:5432/fjcloud_dev" \
        "first psql argument should be the database URL"

    unset MOCK_CALL_LOG
}

test_run_migrations_with_runner_uses_custom_runner_path() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf '$tmp_dir'" RETURN

    touch "$tmp_dir/001_test.sql"

    local mock_bin="$tmp_dir/bin"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/docker" << 'MOCK'
#!/usr/bin/env bash
echo "$*" >> "$MOCK_CALL_LOG"
exit 0
MOCK
    chmod +x "$mock_bin/docker"

    export MOCK_CALL_LOG="$tmp_dir/runner_calls.log"
    LOG_OUTPUT=""

    PATH="$mock_bin:$PATH" run_migrations_with_runner "$tmp_dir" "/container/migrations" \
        docker compose exec -T postgres psql -h 127.0.0.1 -U test -d testdb

    local migration_call
    migration_call="$(grep -- ' -f ' "$MOCK_CALL_LOG" | head -1 || true)"
    assert_contains "$migration_call" "compose exec -T postgres psql -h 127.0.0.1 -U test -d testdb -f" \
        "custom runner should prefix every migration command"
    assert_contains "$migration_call" "/container/migrations/001_test.sql" \
        "custom runner should receive the runner-visible migration path"

    unset MOCK_CALL_LOG
}

test_no_sql_files_returns_nonzero() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf '$tmp_dir'" RETURN

    # Empty directory — no .sql files
    LOG_OUTPUT=""

    local exit_code=0
    run_migrations "postgres://test@localhost/testdb" "$tmp_dir" || exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        pass "run_migrations returns non-zero when no SQL files are present"
    else
        fail "run_migrations should return non-zero when no SQL files are present (got 0)"
    fi

    assert_contains "$LOG_OUTPUT" "No SQL migration files found" \
        "run_migrations should explain when the migration directory is empty"
}

test_email_log_suppressed_status_migration_quotes_delivery_status_literals() {
    # Path tracks the renumbered file (was 044, now 045 — see this file's
    # commit history for the dup-042 collision fix that shifted versions).
    local migration_file="$REPO_ROOT/infra/migrations/045_email_log_suppressed_status.sql"
    local migration_sql
    migration_sql="$(cat "$migration_file")"

    assert_contains "$migration_sql" "CHECK (delivery_status IN ('success', 'failed', 'suppressed'));" \
        "045 migration should quote delivery_status literals to keep the CHECK constraint valid SQL"
}

# ============================================================================
# Run all tests
# ============================================================================

main() {
    echo "=== migrate.sh tests ==="
    echo ""

    test_applies_all_sql_files_in_sorted_order
    test_returns_nonzero_on_migration_failure
    test_passes_db_url_to_psql
    test_run_migrations_with_runner_uses_custom_runner_path
    test_no_sql_files_returns_nonzero
    test_email_log_suppressed_status_migration_quotes_delivery_status_literals

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
