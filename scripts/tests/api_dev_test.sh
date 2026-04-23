#!/usr/bin/env bash
# Tests for scripts/api-dev.sh: env-loading safety and startup behavior.

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
# shellcheck source=lib/test_helpers.sh
source "$SCRIPT_DIR/lib/test_helpers.sh"

test_api_dev_rejects_executable_env_local_content() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_path "'"$REPO_ROOT/.env.local"'" "${API_DEV_ENV_BACKUP:-}"; rm -rf "'"$tmp_dir"'"' RETURN

    local marker_path="$tmp_dir/should-not-exist"
    API_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    cat > "$REPO_ROOT/.env.local" <<EOF
DATABASE_URL=postgres://local-test:local-pass@localhost:5432/local_dev_test
LISTEN_ADDR=0.0.0.0:3001
touch "$marker_path"
EOF

    mkdir -p "$tmp_dir/bin"
    write_mock_script "$tmp_dir/bin/cargo" 'exit 0'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        bash "$REPO_ROOT/scripts/api-dev.sh" 2>&1
    ) || exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        pass "should reject executable shell syntax in .env.local"
    else
        fail "should reject executable shell syntax in .env.local (expected non-zero exit)"
    fi
    assert_contains "$output" "Unsupported syntax" \
        "should explain that only KEY=value assignments are accepted from .env.local"

    if [ -e "$marker_path" ]; then
        fail "should not execute shell commands from .env.local"
    else
        pass "should not execute shell commands from .env.local"
    fi
}

test_api_dev_preserves_explicit_flapjack_admin_key() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_path "'"$REPO_ROOT/.env.local"'" "${API_DEV_ENV_BACKUP:-}"; rm -rf "'"$tmp_dir"'"' RETURN

    API_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    cat > "$REPO_ROOT/.env.local" <<'EOF'
DATABASE_URL=postgres://local-test:local-pass@localhost:5432/local_dev_test
FLAPJACK_ADMIN_KEY=file-admin-key
EOF

    mkdir -p "$tmp_dir/bin"
    local cargo_log="$tmp_dir/cargo.log"
    write_mock_script "$tmp_dir/bin/cargo" '
echo "FLAPJACK_ADMIN_KEY=${FLAPJACK_ADMIN_KEY:-}" >> "'"$cargo_log"'"
exit 0'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_ADMIN_KEY="explicit-admin-key" \
        bash "$REPO_ROOT/scripts/api-dev.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should start successfully when an explicit FLAPJACK_ADMIN_KEY override is set"

    local cargo_calls
    cargo_calls=$(cat "$cargo_log" 2>/dev/null || true)
    assert_contains "$cargo_calls" "FLAPJACK_ADMIN_KEY=explicit-admin-key" \
        "should preserve explicit FLAPJACK_ADMIN_KEY over .env.local values"
}

test_api_dev_defaults_replication_orchestrator_to_effectively_disabled() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_path "'"$REPO_ROOT/.env.local"'" "${API_DEV_ENV_BACKUP:-}"; rm -rf "'"$tmp_dir"'"' RETURN

    API_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    cat > "$REPO_ROOT/.env.local" <<'EOF'
DATABASE_URL=postgres://local-test:local-pass@localhost:5432/local_dev_test
NODE_SECRET_BACKEND=memory
EOF

    mkdir -p "$tmp_dir/bin"
    local cargo_log="$tmp_dir/cargo.log"
    write_mock_script "$tmp_dir/bin/cargo" '
echo "REPLICATION_CYCLE_INTERVAL_SECS=${REPLICATION_CYCLE_INTERVAL_SECS:-}" >> "'"$cargo_log"'"
exit 0'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        bash "$REPO_ROOT/scripts/api-dev.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" \
        "api-dev should start with local replication defaults"

    local cargo_calls
    cargo_calls=$(cat "$cargo_log" 2>/dev/null || true)
    assert_contains "$cargo_calls" "REPLICATION_CYCLE_INTERVAL_SECS=999999" \
        "api-dev should effectively disable replication orchestration by default"
}

test_api_dev_preserves_explicit_replication_cycle_interval() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_path "'"$REPO_ROOT/.env.local"'" "${API_DEV_ENV_BACKUP:-}"; rm -rf "'"$tmp_dir"'"' RETURN

    API_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
    cat > "$REPO_ROOT/.env.local" <<'EOF'
DATABASE_URL=postgres://local-test:local-pass@localhost:5432/local_dev_test
REPLICATION_CYCLE_INTERVAL_SECS=120
EOF

    mkdir -p "$tmp_dir/bin"
    local cargo_log="$tmp_dir/cargo.log"
    write_mock_script "$tmp_dir/bin/cargo" '
echo "REPLICATION_CYCLE_INTERVAL_SECS=${REPLICATION_CYCLE_INTERVAL_SECS:-}" >> "'"$cargo_log"'"
exit 0'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        REPLICATION_CYCLE_INTERVAL_SECS=45 \
        bash "$REPO_ROOT/scripts/api-dev.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" \
        "api-dev should start with explicit replication interval"

    local cargo_calls
    cargo_calls=$(cat "$cargo_log" 2>/dev/null || true)
    assert_contains "$cargo_calls" "REPLICATION_CYCLE_INTERVAL_SECS=45" \
        "api-dev should preserve explicit replication interval overrides"
}

main() {
    echo "=== api-dev.sh tests ==="
    echo ""

    test_api_dev_rejects_executable_env_local_content
    test_api_dev_preserves_explicit_flapjack_admin_key
    test_api_dev_defaults_replication_orchestrator_to_effectively_disabled
    test_api_dev_preserves_explicit_replication_cycle_interval

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
