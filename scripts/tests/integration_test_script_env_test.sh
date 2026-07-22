#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../integration-test.sh
source "$REPO_ROOT/scripts/integration-test.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local actual="$1"
    local expected="$2"
    local msg="$3"
    if [ "$actual" != "$expected" ]; then
        fail "$msg (expected='$expected' actual='$actual')"
    fi
}

clear_env() {
    unset INTEGRATION INTEGRATION_API_BASE INTEGRATION_FLAPJACK_BASE INTEGRATION_DB_URL \
        INTEGRATION_DB INTEGRATION_DB_HOST INTEGRATION_DB_PORT INTEGRATION_DB_USER \
        INTEGRATION_DB_PASSWORD INTEGRATION_JWT_SECRET INTEGRATION_ADMIN_KEY \
        INTEGRATION_INTERNAL_AUTH_TOKEN || true
}

CAPTURED_DB_URL=""
CAPTURED_API_BASE=""
CAPTURED_FLAPJACK_BASE=""
CAPTURED_INTEGRATION=""
CAPTURED_INTERNAL_AUTH_TOKEN=""
CAPTURED_CARGO_ARGS=""

cargo() {
    CAPTURED_DB_URL="$INTEGRATION_DB_URL"
    CAPTURED_API_BASE="$INTEGRATION_API_BASE"
    CAPTURED_FLAPJACK_BASE="$INTEGRATION_FLAPJACK_BASE"
    CAPTURED_INTEGRATION="$INTEGRATION"
    CAPTURED_INTERNAL_AUTH_TOKEN="$INTEGRATION_INTERNAL_AUTH_TOKEN"
    CAPTURED_CARGO_ARGS="$*"
    return 0
}

test_run_integration_tests_uses_shared_db_url_defaults() {
    clear_env
    export INTEGRATION_DB_HOST="db.local"
    export INTEGRATION_DB_PORT="15432"
    export INTEGRATION_DB_USER="fjcloud"
    export INTEGRATION_DB_PASSWORD="secret"
    export INTEGRATION_DB="fjcloud_integration_test"

    run_integration_tests --test-threads=1

    assert_eq "$CAPTURED_INTEGRATION" "1" "INTEGRATION flag should be enabled"
    assert_eq "$CAPTURED_API_BASE" "http://localhost:3099" "default API base should be used"
    assert_eq "$CAPTURED_FLAPJACK_BASE" "http://127.0.0.1:7799" \
        "flapjack test base should match the metering agent's local stack URL"
    assert_eq "$CAPTURED_DB_URL" "postgres://fjcloud:secret@db.local:15432/fjcloud_integration_test" \
        "DB URL should include credentials from shared helper"
}

test_run_integration_tests_targets_platform_group() {
    clear_env
    export INTEGRATION_DB_URL="postgres://fjcloud:secret@db.local:15432/fjcloud_integration_test"

    run_integration_tests

    assert_eq "$CAPTURED_CARGO_ARGS" "test -p api --test platform integration_ -- --test-threads=1" \
        "integration_* slice should run through the generated platform grouped binary"
}

test_run_integration_tests_exports_internal_auth_token() {
    clear_env
    export INTEGRATION_DB_URL="postgres://fjcloud:secret@db.local:15432/fjcloud_integration_test"
    export INTEGRATION_INTERNAL_AUTH_TOKEN="shared-internal-token"

    run_integration_tests

    assert_eq "$CAPTURED_INTERNAL_AUTH_TOKEN" "shared-internal-token" \
        "Rust integration tests should receive the stack internal auth token"
}

main() {
    test_run_integration_tests_uses_shared_db_url_defaults
    test_run_integration_tests_targets_platform_group
    test_run_integration_tests_exports_internal_auth_token
    echo "PASS: integration_test_script_env_test"
}

main "$@"
