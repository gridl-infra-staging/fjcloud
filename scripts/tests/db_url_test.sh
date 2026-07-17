#!/usr/bin/env bash
# Tests for scripts/lib/db_url.sh: database URL parsing functions.
# These are pure string functions — no database or network access required.

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

# shellcheck source=../../scripts/lib/db_url.sh
source "$REPO_ROOT/scripts/lib/db_url.sh"

# ============================================================================
# redact_db_url tests
# ============================================================================

test_redact_db_url_masks_password() {
    local result
    result="$(redact_db_url "postgres://fjcloud:s3cret@localhost:5432/fjcloud_dev")"
    assert_eq "$result" "postgres://fjcloud:***@localhost:5432/fjcloud_dev" \
        "redact_db_url should mask the password"
}

test_redact_db_url_preserves_url_without_password() {
    local result
    result="$(redact_db_url "postgres://fjcloud@localhost:5432/fjcloud_dev")"
    assert_eq "$result" "postgres://fjcloud@localhost:5432/fjcloud_dev" \
        "redact_db_url should preserve URL without password"
}

test_redact_db_url_handles_complex_password() {
    local result
    result="$(redact_db_url "postgres://user:p%40ss!w0rd#123@host:5432/db")"
    assert_eq "$result" "postgres://user:***@host:5432/db" \
        "redact_db_url should mask complex passwords with special chars"
}

# ============================================================================
# db_url_userinfo tests
# ============================================================================

test_db_url_userinfo_extracts_user_and_password() {
    local result
    result="$(db_url_userinfo "postgres://fjcloud:s3cret@localhost:5432/db")"
    assert_eq "$result" "fjcloud:s3cret" \
        "db_url_userinfo should extract user:password"
}

test_db_url_userinfo_extracts_user_only() {
    local result
    result="$(db_url_userinfo "postgres://fjcloud@localhost:5432/db")"
    assert_eq "$result" "fjcloud" \
        "db_url_userinfo should extract user without password"
}

test_db_url_userinfo_fails_without_at_sign() {
    if db_url_userinfo "postgres://localhost:5432/db" >/dev/null 2>&1; then
        fail "db_url_userinfo should fail when no @ sign is present"
    else
        pass "db_url_userinfo returns non-zero without @ sign"
    fi
}

# ============================================================================
# db_url_user tests
# ============================================================================

test_db_url_user_extracts_username() {
    local result
    result="$(db_url_user "postgres://fjcloud:s3cret@localhost:5432/db")"
    assert_eq "$result" "fjcloud" \
        "db_url_user should extract username"
}

test_db_url_user_extracts_username_without_password() {
    local result
    result="$(db_url_user "postgres://admin@localhost:5432/db")"
    assert_eq "$result" "admin" \
        "db_url_user should extract username when no password present"
}

# ============================================================================
# db_url_password tests
# ============================================================================

test_db_url_password_extracts_password() {
    local result
    result="$(db_url_password "postgres://fjcloud:s3cret@localhost:5432/db")"
    assert_eq "$result" "s3cret" \
        "db_url_password should extract password"
}

test_db_url_password_returns_empty_without_password() {
    local result
    result="$(db_url_password "postgres://fjcloud@localhost:5432/db")"
    assert_eq "$result" "" \
        "db_url_password should return empty when no password"
}

# ============================================================================
# db_url_database tests
# ============================================================================

test_db_url_database_extracts_dbname() {
    local result
    result="$(db_url_database "postgres://fjcloud:s3cret@localhost:5432/fjcloud_dev")"
    assert_eq "$result" "fjcloud_dev" \
        "db_url_database should extract database name"
}

test_db_url_database_strips_query_params() {
    local result
    result="$(db_url_database "postgres://fjcloud:s3cret@localhost:5432/fjcloud_dev?sslmode=require")"
    assert_eq "$result" "fjcloud_dev" \
        "db_url_database should strip query parameters"
}

test_db_url_database_fails_without_path() {
    if db_url_database "postgres://fjcloud:s3cret@localhost:5432" >/dev/null 2>&1; then
        fail "db_url_database should fail when no database path is present"
    else
        pass "db_url_database returns non-zero without database path"
    fi
}

# ============================================================================
# db_url_hostport tests
# ============================================================================

test_db_url_hostport_extracts_host_and_port() {
    local result
    result="$(db_url_hostport "postgres://fjcloud:s3cret@myhost:5433/db")"
    assert_eq "$result" "myhost:5433" \
        "db_url_hostport should extract host:port"
}

test_db_url_hostport_extracts_host_without_port() {
    local result
    result="$(db_url_hostport "postgres://fjcloud:s3cret@myhost/db")"
    assert_eq "$result" "myhost" \
        "db_url_hostport should extract host without port"
}

# ============================================================================
# db_url_host tests
# ============================================================================

test_db_url_host_extracts_hostname() {
    local result
    result="$(db_url_host "postgres://fjcloud:s3cret@myhost:5432/db")"
    assert_eq "$result" "myhost" \
        "db_url_host should extract hostname"
}

test_db_url_host_extracts_localhost() {
    local result
    result="$(db_url_host "postgres://fjcloud:s3cret@localhost:5432/db")"
    assert_eq "$result" "localhost" \
        "db_url_host should extract localhost"
}

test_db_url_host_extracts_ip_address() {
    local result
    result="$(db_url_host "postgres://fjcloud:s3cret@192.168.1.100:5432/db")"
    assert_eq "$result" "192.168.1.100" \
        "db_url_host should extract IP address"
}

test_db_url_host_extracts_ipv6_bracket() {
    local result
    result="$(db_url_host "postgres://fjcloud:s3cret@[::1]:5432/db")"
    assert_eq "$result" "[::1]" \
        "db_url_host should extract bracketed IPv6 address"
}

test_db_url_host_handles_host_without_port() {
    local result
    result="$(db_url_host "postgres://fjcloud:s3cret@myhost/db")"
    assert_eq "$result" "myhost" \
        "db_url_host should handle host without port"
}

# ============================================================================
# db_url_port_is_valid tests
# ============================================================================

test_db_url_port_is_valid_accepts_standard_port() {
    if db_url_port_is_valid "5432"; then
        pass "db_url_port_is_valid accepts 5432"
    else
        fail "db_url_port_is_valid should accept 5432"
    fi
}

test_db_url_port_is_valid_accepts_min_port() {
    if db_url_port_is_valid "1"; then
        pass "db_url_port_is_valid accepts port 1"
    else
        fail "db_url_port_is_valid should accept port 1"
    fi
}

test_db_url_port_is_valid_accepts_max_port() {
    if db_url_port_is_valid "65535"; then
        pass "db_url_port_is_valid accepts port 65535"
    else
        fail "db_url_port_is_valid should accept port 65535"
    fi
}

test_db_url_port_is_valid_rejects_zero() {
    if db_url_port_is_valid "0"; then
        fail "db_url_port_is_valid should reject port 0"
    else
        pass "db_url_port_is_valid rejects port 0"
    fi
}

test_db_url_port_is_valid_rejects_too_high() {
    if db_url_port_is_valid "65536"; then
        fail "db_url_port_is_valid should reject port 65536"
    else
        pass "db_url_port_is_valid rejects port 65536"
    fi
}

test_db_url_port_is_valid_rejects_non_numeric() {
    if db_url_port_is_valid "abc"; then
        fail "db_url_port_is_valid should reject non-numeric"
    else
        pass "db_url_port_is_valid rejects non-numeric"
    fi
}

test_db_url_port_is_valid_rejects_empty() {
    if db_url_port_is_valid ""; then
        fail "db_url_port_is_valid should reject empty string"
    else
        pass "db_url_port_is_valid rejects empty string"
    fi
}

# ============================================================================
# db_url_port tests
# ============================================================================

test_db_url_port_extracts_explicit_port() {
    local result
    result="$(db_url_port "postgres://fjcloud:s3cret@localhost:5433/db")"
    assert_eq "$result" "5433" \
        "db_url_port should extract explicit port"
}

test_db_url_port_defaults_to_5432() {
    local result
    result="$(db_url_port "postgres://fjcloud:s3cret@localhost/db")"
    assert_eq "$result" "5432" \
        "db_url_port should default to 5432 when no port specified"
}

test_db_url_port_extracts_ipv6_port() {
    local result
    result="$(db_url_port "postgres://fjcloud:s3cret@[::1]:5433/db")"
    assert_eq "$result" "5433" \
        "db_url_port should extract port from IPv6 URL"
}

test_db_url_port_defaults_ipv6_without_port() {
    local result
    result="$(db_url_port "postgres://fjcloud:s3cret@[::1]/db")"
    assert_eq "$result" "5432" \
        "db_url_port should default to 5432 for IPv6 without port"
}

test_db_url_port_rejects_invalid_port() {
    if db_url_port "postgres://fjcloud:s3cret@localhost:0/db" >/dev/null 2>&1; then
        fail "db_url_port should reject invalid port 0"
    else
        pass "db_url_port rejects invalid port 0"
    fi
}

# ============================================================================
# Run all tests
# ============================================================================

main() {
    echo "=== db_url.sh tests ==="
    echo ""

    # redact_db_url
    test_redact_db_url_masks_password
    test_redact_db_url_preserves_url_without_password
    test_redact_db_url_handles_complex_password

    # db_url_userinfo
    test_db_url_userinfo_extracts_user_and_password
    test_db_url_userinfo_extracts_user_only
    test_db_url_userinfo_fails_without_at_sign

    # db_url_user
    test_db_url_user_extracts_username
    test_db_url_user_extracts_username_without_password

    # db_url_password
    test_db_url_password_extracts_password
    test_db_url_password_returns_empty_without_password

    # db_url_database
    test_db_url_database_extracts_dbname
    test_db_url_database_strips_query_params
    test_db_url_database_fails_without_path

    # db_url_hostport
    test_db_url_hostport_extracts_host_and_port
    test_db_url_hostport_extracts_host_without_port

    # db_url_host
    test_db_url_host_extracts_hostname
    test_db_url_host_extracts_localhost
    test_db_url_host_extracts_ip_address
    test_db_url_host_extracts_ipv6_bracket
    test_db_url_host_handles_host_without_port

    # db_url_port_is_valid
    test_db_url_port_is_valid_accepts_standard_port
    test_db_url_port_is_valid_accepts_min_port
    test_db_url_port_is_valid_accepts_max_port
    test_db_url_port_is_valid_rejects_zero
    test_db_url_port_is_valid_rejects_too_high
    test_db_url_port_is_valid_rejects_non_numeric
    test_db_url_port_is_valid_rejects_empty

    # db_url_port
    test_db_url_port_extracts_explicit_port
    test_db_url_port_defaults_to_5432
    test_db_url_port_extracts_ipv6_port
    test_db_url_port_defaults_ipv6_without_port
    test_db_url_port_rejects_invalid_port

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
