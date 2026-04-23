#!/usr/bin/env bash
# Mock helpers for integration_up_test.sh.
#
# Callers must define REPO_ROOT before sourcing.
# Shared helpers (write_mock_script, backup/restore_repo_env_file) come from
# test_helpers.sh — callers should source that first.

SCRIPT_DIR_MOCKS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helpers.sh
source "$SCRIPT_DIR_MOCKS/test_helpers.sh"

write_fake_api_binary() {
    local api_bin="$1"
    mkdir -p "$(dirname "$api_bin")"
    cat > "$api_bin" <<'MOCK'
#!/usr/bin/env bash
if [ -n "${INTEGRATION_UP_API_ENV_LOG:-}" ]; then
    {
        echo "LISTEN_ADDR=${LISTEN_ADDR:-}"
        echo "S3_LISTEN_ADDR=${S3_LISTEN_ADDR:-}"
        echo "JWT_SECRET=${JWT_SECRET:-}"
        echo "ADMIN_KEY=${ADMIN_KEY:-}"
        echo "STORAGE_ENCRYPTION_KEY=${STORAGE_ENCRYPTION_KEY:-}"
    } >> "$INTEGRATION_UP_API_ENV_LOG"
fi
exit 0
MOCK
    chmod +x "$api_bin"
}

create_fake_api_binary() {
    local api_bin="$REPO_ROOT/infra/target/debug/api"
    local backup_file=""
    if [ -e "$api_bin" ]; then
        backup_file="$(mktemp)"
        cp "$api_bin" "$backup_file"
    fi
    write_fake_api_binary "$api_bin"
    echo "$backup_file"
}

restore_fake_api_binary() {
    local backup_file="$1"
    local api_bin="$REPO_ROOT/infra/target/debug/api"
    if [ -n "$backup_file" ] && [ -f "$backup_file" ]; then
        cp "$backup_file" "$api_bin"
        rm -f "$backup_file"
    else
        rm -f "$api_bin"
    fi
}

# Standard mock set for a successful integration-up startup.
# Creates: whoami, cargo, nohup, psql (db-exists), curl (success), plus fake API binary.
# Sets _STARTUP_MOCK_API_BACKUP for cleanup_startup_mocks.
setup_startup_mocks() {
    local tmp_dir="$1"
    _STARTUP_MOCK_API_BACKUP="$(create_fake_api_binary)"
    write_mock_script "$tmp_dir/whoami" 'echo "tester"'
    # Some macOS bash RETURN traps from earlier tests can restore the backed-up
    # API binary after setup. Recreate the fake binary during the mocked cargo
    # build so the startup env assertions observe the process integration-up
    # actually launches.
    write_mock_script "$tmp_dir/cargo" '
api_bin="$(pwd)/target/debug/api"
mkdir -p "$(dirname "$api_bin")"
cat > "$api_bin" <<'\''MOCK_API'\''
#!/usr/bin/env bash
if [ -n "${INTEGRATION_UP_API_ENV_LOG:-}" ]; then
    {
        echo "LISTEN_ADDR=${LISTEN_ADDR:-}"
        echo "S3_LISTEN_ADDR=${S3_LISTEN_ADDR:-}"
        echo "JWT_SECRET=${JWT_SECRET:-}"
        echo "ADMIN_KEY=${ADMIN_KEY:-}"
        echo "STORAGE_ENCRYPTION_KEY=${STORAGE_ENCRYPTION_KEY:-}"
    } >> "$INTEGRATION_UP_API_ENV_LOG"
fi
exit 0
MOCK_API
chmod +x "$api_bin"
exit 0
'
    write_mock_script "$tmp_dir/nohup" '"$@" >/dev/null 2>&1 || true; exit 0'
    write_mock_script "$tmp_dir/psql" '
if [[ "$*" == *"SELECT 1 FROM pg_database"* ]]; then
    echo "1"
    exit 0
fi
exit 0
'
    write_mock_script "$tmp_dir/curl" 'exit 0'
}

cleanup_startup_mocks() {
    local tmp_dir="$1"
    rm -rf "$tmp_dir"
    restore_fake_api_binary "${_STARTUP_MOCK_API_BACKUP:-}"
}
