#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/integration_stack_env.sh
source "$SCRIPT_DIR/../lib/integration_stack_env.sh"

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

assert_contains() {
    local actual="$1"
    local expected_substr="$2"
    local msg="$3"
    if [[ "$actual" != *"$expected_substr"* ]]; then
        fail "$msg (expected substring '$expected_substr' in '$actual')"
    fi
}

clear_env() {
    unset INTEGRATION_DB INTEGRATION_DB_USER INTEGRATION_DB_PASSWORD INTEGRATION_DB_HOST INTEGRATION_DB_PORT INTEGRATION_DB_URL PGPASSWORD || true
}

test_db_url_builds_with_password() {
    clear_env
    export INTEGRATION_DB="fjcloud_integration_test"
    export INTEGRATION_DB_USER="fjcloud"
    export INTEGRATION_DB_PASSWORD="fjcloud"
    export INTEGRATION_DB_HOST="db.local"
    export INTEGRATION_DB_PORT="15432"

    init_integration_env_defaults
    assert_eq "$INTEGRATION_DB_URL" "postgres://fjcloud:fjcloud@db.local:15432/fjcloud_integration_test" "db URL should include user and password"
}

test_db_url_preserves_explicit_url() {
    clear_env
    export INTEGRATION_DB_URL="postgres://explicit-url.local/custom_db"

    init_integration_env_defaults
    assert_eq "$INTEGRATION_DB_URL" "postgres://explicit-url.local/custom_db" "explicit INTEGRATION_DB_URL should be preserved"
}

test_pgpassword_defaults_from_integration_db_password() {
    clear_env
    export INTEGRATION_DB_PASSWORD="db-secret"

    init_integration_env_defaults
    assert_eq "$PGPASSWORD" "db-secret" "PGPASSWORD should default from INTEGRATION_DB_PASSWORD when unset"
}

test_sanitized_db_url_masks_password() {
    clear_env
    export INTEGRATION_DB="fjcloud_integration_test"
    export INTEGRATION_DB_USER="fjcloud"
    export INTEGRATION_DB_PASSWORD="supersecret"
    export INTEGRATION_DB_HOST="localhost"
    export INTEGRATION_DB_PORT="15432"

    init_integration_env_defaults
    local sanitized
    sanitized="$(sanitized_integration_db_url)"
    assert_contains "$sanitized" "postgres://fjcloud:***@localhost:15432/fjcloud_integration_test" "sanitized DB URL should redact password"
}

test_sanitized_explicit_url_masks_embedded_password() {
    # Regression: sanitized_integration_db_url must redact passwords even when
    # INTEGRATION_DB_URL is set explicitly (old string-substitution approach missed this).
    clear_env
    export INTEGRATION_DB_URL="postgres://user:explicit-secret@host:9999/db"
    # INTEGRATION_DB_PASSWORD deliberately NOT set — old code skipped redaction here

    local sanitized
    sanitized="$(sanitized_integration_db_url)"
    assert_eq "$sanitized" "postgres://user:***@host:9999/db" "explicit URL with embedded password should be redacted"
}

test_redact_db_url_masks_embedded_password() {
    clear_env

    local redacted
    redacted="$(redact_db_url "postgres://user:explicit-secret@host:9999/db")"
    assert_eq "$redacted" "postgres://user:***@host:9999/db" "redact_db_url should mask embedded passwords"
}

test_validate_integration_db_name_accepts_safe_identifier() {
    clear_env
    if ! validate_integration_db_name "fjcloud_integration_test_2026"; then
        fail "safe database identifier should be accepted"
    fi
}

test_validate_integration_db_name_rejects_injection_chars() {
    clear_env
    if validate_integration_db_name "fjcloud_test; DROP DATABASE prod; --"; then
        fail "database identifier with SQL injection characters must be rejected"
    fi
}

test_db_url_without_password_omits_credentials() {
    clear_env
    export INTEGRATION_DB="fjcloud_integration_test"
    export INTEGRATION_DB_USER="fjcloud"
    export INTEGRATION_DB_PASSWORD=""
    export INTEGRATION_DB_HOST="localhost"
    export INTEGRATION_DB_PORT="5432"

    init_integration_env_defaults
    assert_eq "$INTEGRATION_DB_URL" "postgres://fjcloud@localhost:5432/fjcloud_integration_test" \
        "empty DB password should omit ':@' credentials segment in URL"
}

test_init_defaults_does_not_overwrite_explicit_vars() {
    clear_env
    export INTEGRATION_DB_HOST="custom-host"

    init_integration_env_defaults
    assert_eq "$INTEGRATION_DB_HOST" "custom-host" \
        "init_integration_env_defaults should preserve explicit INTEGRATION_DB_HOST"
}

main() {
    test_db_url_builds_with_password
    test_db_url_preserves_explicit_url
    test_pgpassword_defaults_from_integration_db_password
    test_sanitized_db_url_masks_password
    test_sanitized_explicit_url_masks_embedded_password
    test_redact_db_url_masks_embedded_password
    test_validate_integration_db_name_accepts_safe_identifier
    test_validate_integration_db_name_rejects_injection_chars
    test_db_url_without_password_omits_credentials
    test_init_defaults_does_not_overwrite_explicit_vars
    echo "PASS: integration_stack_env_test"
}

main "$@"
