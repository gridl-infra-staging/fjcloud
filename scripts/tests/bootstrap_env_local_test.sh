#!/usr/bin/env bash
# Tests for scripts/bootstrap-env-local.sh: first-run creation, idempotent rerun,
# and "do not overwrite hand-edited .env.local" contract.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SUITE_TMP_DIR="$(mktemp -d)"
REPO_ROOT="$SUITE_TMP_DIR/repo"
trap 'rm -rf "$SUITE_TMP_DIR"' EXIT

mkdir -p "$REPO_ROOT/scripts/lib"
cp "$SOURCE_REPO_ROOT/.env.local.example" "$REPO_ROOT/.env.local.example"
cp "$SOURCE_REPO_ROOT/scripts/bootstrap-env-local.sh" \
    "$REPO_ROOT/scripts/bootstrap-env-local.sh"
cp "$SOURCE_REPO_ROOT/scripts/lib/env.sh" "$REPO_ROOT/scripts/lib/env.sh"

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
# shellcheck source=lib/test_helpers.sh
source "$SCRIPT_DIR/lib/test_helpers.sh"

BOOTSTRAP_SCRIPT="$REPO_ROOT/scripts/bootstrap-env-local.sh"

test_suite_uses_isolated_fixture_repo() {
    assert_ne "$REPO_ROOT" "$SOURCE_REPO_ROOT" \
        "bootstrap env local tests should target an isolated fixture repo"
}

# ---------------------------------------------------------------------------
# Test: first-run creation from .env.local.example
# ---------------------------------------------------------------------------
test_first_run_creates_env_local() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; rm -rf "'"$tmp_dir"'"' RETURN

    backup_repo_env_file "$tmp_dir/.env.local.backup" || true
    rm -f "$REPO_ROOT/.env.local"

    local output exit_code=0
    output=$(bash "$BOOTSTRAP_SCRIPT" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "0" "bootstrap should succeed on first run"
    assert_contains "$output" "BOOTSTRAP_OK" \
        "bootstrap should emit BOOTSTRAP_OK on creation"

    if [ -f "$REPO_ROOT/.env.local" ]; then
        pass "bootstrap should create .env.local"
    else
        fail "bootstrap should create .env.local (file not found)"
    fi
}

# ---------------------------------------------------------------------------
# Test: generated file has real values (not placeholders) for JWT_SECRET and ADMIN_KEY
# ---------------------------------------------------------------------------
test_generated_values_are_not_placeholders() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; rm -rf "'"$tmp_dir"'"' RETURN

    backup_repo_env_file "$tmp_dir/.env.local.backup" || true
    rm -f "$REPO_ROOT/.env.local"

    bash "$BOOTSTRAP_SCRIPT" >/dev/null 2>&1

    local jwt_secret admin_key
    jwt_secret=$(grep '^JWT_SECRET=' "$REPO_ROOT/.env.local" | head -1 | cut -d= -f2-)
    admin_key=$(grep '^ADMIN_KEY=' "$REPO_ROOT/.env.local" | head -1 | cut -d= -f2-)

    assert_not_contains "$jwt_secret" "replace-with" \
        "JWT_SECRET should not contain placeholder text"
    assert_not_contains "$admin_key" "replace-with" \
        "ADMIN_KEY should not contain placeholder text"

    # JWT_SECRET should be 64 hex chars (openssl rand -hex 32)
    if [[ "$jwt_secret" =~ ^[0-9a-f]{64}$ ]]; then
        pass "JWT_SECRET should be a 64-char hex string"
    else
        fail "JWT_SECRET should be a 64-char hex string (got: '$jwt_secret')"
    fi

    # ADMIN_KEY should be 32 hex chars (openssl rand -hex 16)
    if [[ "$admin_key" =~ ^[0-9a-f]{32}$ ]]; then
        pass "ADMIN_KEY should be a 32-char hex string"
    else
        fail "ADMIN_KEY should be a 32-char hex string (got: '$admin_key')"
    fi
}

# ---------------------------------------------------------------------------
# Test: generated file is parseable by load_env_file
# ---------------------------------------------------------------------------
test_generated_file_is_parseable() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; rm -rf "'"$tmp_dir"'"' RETURN

    backup_repo_env_file "$tmp_dir/.env.local.backup" || true
    rm -f "$REPO_ROOT/.env.local"

    bash "$BOOTSTRAP_SCRIPT" >/dev/null 2>&1

    # Source the env loader and try to parse the generated file.
    # load_env_file exits 1 on any unsupported syntax.
    local parse_exit=0
    (
        source "$REPO_ROOT/scripts/lib/env.sh"
        load_env_file "$REPO_ROOT/.env.local"
    ) || parse_exit=$?

    assert_eq "$parse_exit" "0" \
        "generated .env.local should be parseable by load_env_file"
}

# ---------------------------------------------------------------------------
# Test: idempotent rerun does not overwrite existing file
# ---------------------------------------------------------------------------
test_rerun_does_not_overwrite() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; rm -rf "'"$tmp_dir"'"' RETURN

    backup_repo_env_file "$tmp_dir/.env.local.backup" || true

    # Write a hand-edited .env.local with a known sentinel value
    cat > "$REPO_ROOT/.env.local" <<'EOF'
DATABASE_URL=postgres://hand:edited@localhost:5432/mydb
JWT_SECRET=hand-edited-jwt-secret-value
ADMIN_KEY=hand-edited-admin-key
EOF

    local original_content
    original_content=$(cat "$REPO_ROOT/.env.local")

    local output exit_code=0
    output=$(bash "$BOOTSTRAP_SCRIPT" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "0" "rerun should exit 0 when .env.local already exists"
    assert_contains "$output" "BOOTSTRAP_SKIP" \
        "rerun should emit BOOTSTRAP_SKIP when file exists"

    local current_content
    current_content=$(cat "$REPO_ROOT/.env.local")
    assert_eq "$current_content" "$original_content" \
        "rerun should not modify existing .env.local content"
}

# ---------------------------------------------------------------------------
# Test: fails when .env.local.example is missing
# ---------------------------------------------------------------------------
test_fails_without_example_template() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; mv "'"$tmp_dir"'/.env.local.example.backup" "'"$REPO_ROOT"'/.env.local.example" 2>/dev/null; rm -rf "'"$tmp_dir"'"' RETURN

    backup_repo_env_file "$tmp_dir/.env.local.backup" || true
    rm -f "$REPO_ROOT/.env.local"

    # Temporarily hide the example template
    mv "$REPO_ROOT/.env.local.example" "$tmp_dir/.env.local.example.backup"

    local output exit_code=0
    output=$(bash "$BOOTSTRAP_SCRIPT" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "1" "should fail when .env.local.example is missing"
    assert_contains "$output" "BOOTSTRAP_ERROR" \
        "should emit BOOTSTRAP_ERROR when template is missing"
}

# ---------------------------------------------------------------------------
# Test: generated values differ across runs (randomness)
# ---------------------------------------------------------------------------
test_generated_values_are_random() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; rm -rf "'"$tmp_dir"'"' RETURN

    backup_repo_env_file "$tmp_dir/.env.local.backup" || true

    # First run
    rm -f "$REPO_ROOT/.env.local"
    bash "$BOOTSTRAP_SCRIPT" >/dev/null 2>&1
    local jwt1 admin1
    jwt1=$(grep '^JWT_SECRET=' "$REPO_ROOT/.env.local" | cut -d= -f2-)
    admin1=$(grep '^ADMIN_KEY=' "$REPO_ROOT/.env.local" | cut -d= -f2-)

    # Second run (remove to allow fresh generation)
    rm -f "$REPO_ROOT/.env.local"
    bash "$BOOTSTRAP_SCRIPT" >/dev/null 2>&1
    local jwt2 admin2
    jwt2=$(grep '^JWT_SECRET=' "$REPO_ROOT/.env.local" | cut -d= -f2-)
    admin2=$(grep '^ADMIN_KEY=' "$REPO_ROOT/.env.local" | cut -d= -f2-)

    if [ "$jwt1" != "$jwt2" ]; then
        pass "JWT_SECRET should differ across fresh runs"
    else
        fail "JWT_SECRET should differ across fresh runs (both were '$jwt1')"
    fi

    if [ "$admin1" != "$admin2" ]; then
        pass "ADMIN_KEY should differ across fresh runs"
    else
        fail "ADMIN_KEY should differ across fresh runs (both were '$admin1')"
    fi
}

# ---------------------------------------------------------------------------
# Test: DATABASE_URL and other non-placeholder values are preserved from example
# ---------------------------------------------------------------------------
test_preserves_non_placeholder_values() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; rm -rf "'"$tmp_dir"'"' RETURN

    backup_repo_env_file "$tmp_dir/.env.local.backup" || true
    rm -f "$REPO_ROOT/.env.local"

    bash "$BOOTSTRAP_SCRIPT" >/dev/null 2>&1

    local db_url environment
    db_url=$(grep '^DATABASE_URL=' "$REPO_ROOT/.env.local" | head -1 | cut -d= -f2-)
    environment=$(grep '^ENVIRONMENT=' "$REPO_ROOT/.env.local" | head -1 | cut -d= -f2-)

    assert_eq "$db_url" "postgres://griddle:griddle_local@localhost:5432/fjcloud_dev" \
        "DATABASE_URL should be preserved from example template"
    assert_eq "$environment" "local" \
        "ENVIRONMENT should be preserved from example template"
}

# ---------------------------------------------------------------------------
# Test: secret source values override template when secret file exists
# ---------------------------------------------------------------------------
test_secret_source_overrides_template() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; rm -rf "'"$tmp_dir"'"' RETURN

    backup_repo_env_file "$tmp_dir/.env.local.backup" || true
    rm -f "$REPO_ROOT/.env.local"

    # Create a mock secret file with known values
    local mock_secret="$tmp_dir/mock.env.secret"
    cat > "$mock_secret" <<'EOF'
FLAPJACK_ADMIN_KEY=secret_fj_admin_key_from_external
STRIPE_SECRET_KEY=sk_test_from_secret_source
EOF

    local output exit_code=0
    output=$(FJCLOUD_SECRET_FILE="$mock_secret" bash "$BOOTSTRAP_SCRIPT" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "0" "bootstrap should succeed with secret source"
    assert_contains "$output" "BOOTSTRAP_OK" \
        "should emit BOOTSTRAP_OK with secret source"

    # FLAPJACK_ADMIN_KEY should come from secret source, not template
    local fj_key
    fj_key=$(grep '^FLAPJACK_ADMIN_KEY=' "$REPO_ROOT/.env.local" | head -1 | cut -d= -f2-)
    assert_eq "$fj_key" "secret_fj_admin_key_from_external" \
        "FLAPJACK_ADMIN_KEY should be overridden by secret source"

    # STRIPE_SECRET_KEY from secret source should appear even though it's
    # commented out in the template — the secret source adds it as an active key
    local stripe_key
    stripe_key=$(grep '^STRIPE_SECRET_KEY=' "$REPO_ROOT/.env.local" | head -1 | cut -d= -f2-)
    assert_eq "$stripe_key" "sk_test_from_secret_source" \
        "STRIPE_SECRET_KEY from secret source should be injected"
}

# ---------------------------------------------------------------------------
# Test: default secret path resolves from repo root when override is unset
# ---------------------------------------------------------------------------
test_default_secret_path_uses_repo_root() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local repo_secret_dir="$REPO_ROOT/.secret"
    local repo_secret_file="$repo_secret_dir/.env.secret"
    local repo_secret_backup="$tmp_dir/repo.env.secret.backup"
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; if [ -f "'"$repo_secret_backup"'" ]; then mkdir -p "'"$repo_secret_dir"'"; cp "'"$repo_secret_backup"'" "'"$repo_secret_file"'"; else rm -f "'"$repo_secret_file"'"; fi; rm -rf "'"$tmp_dir"'"' RETURN

    backup_repo_env_file "$tmp_dir/.env.local.backup" || true
    rm -f "$REPO_ROOT/.env.local"

    if [ -f "$repo_secret_file" ]; then
        cp "$repo_secret_file" "$repo_secret_backup"
    fi

    mkdir -p "$repo_secret_dir"
    # FLAPJACK_ADMIN_KEY is a legitimate secret key (not a deny-listed target) — use
    # it to assert "default repo-root secret path is consulted." For the deny-list
    # behavior on ADMIN_KEY itself, see test_denylist_admin_key_not_overridden below.
    cat > "$repo_secret_file" <<'EOF'
FLAPJACK_ADMIN_KEY=fj_admin_from_repo_root_default_secret
EOF

    local output exit_code=0
    output=$(env -u FJCLOUD_SECRET_FILE bash "$BOOTSTRAP_SCRIPT" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "0" "bootstrap should succeed when default repo-root secret file exists"
    assert_contains "$output" "BOOTSTRAP_OK" \
        "should emit BOOTSTRAP_OK when using default repo-root secret file"

    local fj_key
    fj_key=$(grep '^FLAPJACK_ADMIN_KEY=' "$REPO_ROOT/.env.local" | head -1 | cut -d= -f2-)
    assert_eq "$fj_key" "fj_admin_from_repo_root_default_secret" \
        "FLAPJACK_ADMIN_KEY should come from default repo-root secret file when override is unset"
}

# ---------------------------------------------------------------------------
# Test: FJCLOUD_SECRET_FILE env var overrides default secret path
# ---------------------------------------------------------------------------
test_secret_file_env_override() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; rm -rf "'"$tmp_dir"'"' RETURN

    backup_repo_env_file "$tmp_dir/.env.local.backup" || true
    rm -f "$REPO_ROOT/.env.local"

    local mock_secret="$tmp_dir/custom.env.secret"
    # Use a legitimate (non-deny-listed) secret to assert the FJCLOUD_SECRET_FILE
    # override is honored. ADMIN_KEY is on the deny-list — see
    # test_denylist_admin_key_not_overridden for its specific contract.
    cat > "$mock_secret" <<'EOF'
FLAPJACK_ADMIN_KEY=fj_admin_from_custom_secret_path
EOF

    local output exit_code=0
    output=$(FJCLOUD_SECRET_FILE="$mock_secret" bash "$BOOTSTRAP_SCRIPT" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "0" "bootstrap should succeed with custom secret file"

    local fj_key
    fj_key=$(grep '^FLAPJACK_ADMIN_KEY=' "$REPO_ROOT/.env.local" | head -1 | cut -d= -f2-)
    assert_eq "$fj_key" "fj_admin_from_custom_secret_path" \
        "FLAPJACK_ADMIN_KEY should come from FJCLOUD_SECRET_FILE override"
}

# ---------------------------------------------------------------------------
# Regression: deny-list of environment-targeting keys must NOT flow from
# .secret/.env.secret into the local .env.local. This is the contract that
# closes the 2026-05-22 local_demo-seeds-prod incident — see
# docs/decisions/2026_05_22_bootstrap_local_env_deny_list.md.
# ---------------------------------------------------------------------------
test_denylist_API_URL_not_appended_from_secrets() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; rm -rf "'"$tmp_dir"'"' RETURN

    backup_repo_env_file "$tmp_dir/.env.local.backup" || true
    rm -f "$REPO_ROOT/.env.local"

    # Simulate the historical leak: API_URL pointing at prod present in the
    # secret source. The template does NOT declare API_URL, so without the
    # deny-list it would be silently appended verbatim into .env.local.
    local mock_secret="$tmp_dir/leaky.env.secret"
    cat > "$mock_secret" <<'EOF'
API_URL=https://api.flapjack.foo
STRIPE_SECRET_KEY=sk_test_a_legitimate_secret
EOF

    FJCLOUD_SECRET_FILE="$mock_secret" bash "$BOOTSTRAP_SCRIPT" >/dev/null 2>&1

    # The deny-listed key must NOT appear at all.
    local api_url_lines
    api_url_lines=$(grep -c '^API_URL=' "$REPO_ROOT/.env.local" || true)
    assert_eq "$api_url_lines" "0" \
        "API_URL from secret source must NOT be appended to .env.local (deny-list)"

    # The legitimate secret must still flow through, confirming the deny-list
    # didn't break non-denied secret injection.
    local stripe_key
    stripe_key=$(grep '^STRIPE_SECRET_KEY=' "$REPO_ROOT/.env.local" | head -1 | cut -d= -f2-)
    assert_eq "$stripe_key" "sk_test_a_legitimate_secret" \
        "non-denied STRIPE_SECRET_KEY should still flow from secret source"
}

test_denylist_admin_key_not_overridden() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; rm -rf "'"$tmp_dir"'"' RETURN

    backup_repo_env_file "$tmp_dir/.env.local.backup" || true
    rm -f "$REPO_ROOT/.env.local"

    # The template DOES declare ADMIN_KEY (with a placeholder) — without the
    # deny-list, the secret source would win on Priority 1 and overwrite the
    # template's random-generated value with the leaked prod admin key.
    local mock_secret="$tmp_dir/leaky.env.secret"
    cat > "$mock_secret" <<'EOF'
ADMIN_KEY=this_value_must_not_win
EOF

    FJCLOUD_SECRET_FILE="$mock_secret" bash "$BOOTSTRAP_SCRIPT" >/dev/null 2>&1

    local admin_key
    admin_key=$(grep '^ADMIN_KEY=' "$REPO_ROOT/.env.local" | head -1 | cut -d= -f2-)

    # The denied secret-source value must NOT win.
    assert_ne "$admin_key" "this_value_must_not_win" \
        "ADMIN_KEY from secret source must NOT override the template default (deny-list)"

    # Confirm it fell back to the template's random-hex generation (32 hex chars).
    if [[ "$admin_key" =~ ^[0-9a-f]{32}$ ]]; then
        pass "ADMIN_KEY should fall back to random-hex generation when secret source is denied"
    else
        fail "ADMIN_KEY should fall back to random-hex generation when secret source is denied (got: '$admin_key')"
    fi
}

test_denylist_database_url_not_overridden() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; rm -rf "'"$tmp_dir"'"' RETURN

    backup_repo_env_file "$tmp_dir/.env.local.backup" || true
    rm -f "$REPO_ROOT/.env.local"

    local mock_secret="$tmp_dir/leaky.env.secret"
    cat > "$mock_secret" <<'EOF'
DATABASE_URL=postgres://fake:fake@prod.rds.example/prod_db
EOF

    FJCLOUD_SECRET_FILE="$mock_secret" bash "$BOOTSTRAP_SCRIPT" >/dev/null 2>&1

    local db_url
    db_url=$(grep '^DATABASE_URL=' "$REPO_ROOT/.env.local" | head -1 | cut -d= -f2-)

    # Denied secret value must NOT win — template's localhost default must remain.
    assert_eq "$db_url" "postgres://griddle:griddle_local@localhost:5432/fjcloud_dev" \
        "DATABASE_URL must keep the template localhost default even when secret source has a value (deny-list)"
}

# ---------------------------------------------------------------------------
# Test: graceful fallback when secret source does not exist
# ---------------------------------------------------------------------------
test_fallback_without_secret_source() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; rm -rf "'"$tmp_dir"'"' RETURN

    backup_repo_env_file "$tmp_dir/.env.local.backup" || true
    rm -f "$REPO_ROOT/.env.local"

    # Point to a non-existent secret file
    local output exit_code=0
    output=$(FJCLOUD_SECRET_FILE="/nonexistent/path/.env.secret" bash "$BOOTSTRAP_SCRIPT" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "0" "bootstrap should succeed without secret source"
    assert_contains "$output" "BOOTSTRAP_OK" \
        "should emit BOOTSTRAP_OK even without secret source"

    # Should still generate random values for placeholders
    local jwt_secret
    jwt_secret=$(grep '^JWT_SECRET=' "$REPO_ROOT/.env.local" | head -1 | cut -d= -f2-)
    assert_not_contains "$jwt_secret" "replace-with" \
        "JWT_SECRET should still be generated without secret source"
    if [[ "$jwt_secret" =~ ^[0-9a-f]{64}$ ]]; then
        pass "JWT_SECRET should be valid hex without secret source"
    else
        fail "JWT_SECRET should be valid hex without secret source (got: '$jwt_secret')"
    fi
}

# ---------------------------------------------------------------------------
# Test: template values not in secret source are preserved unchanged
# ---------------------------------------------------------------------------
test_secret_source_preserves_non_overlapping_values() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; rm -rf "'"$tmp_dir"'"' RETURN

    backup_repo_env_file "$tmp_dir/.env.local.backup" || true
    rm -f "$REPO_ROOT/.env.local"

    # Secret file with only one key — should not disturb other template values
    local mock_secret="$tmp_dir/minimal.env.secret"
    echo "FLAPJACK_ADMIN_KEY=from_secret" > "$mock_secret"

    FJCLOUD_SECRET_FILE="$mock_secret" bash "$BOOTSTRAP_SCRIPT" >/dev/null 2>&1

    local db_url environment
    db_url=$(grep '^DATABASE_URL=' "$REPO_ROOT/.env.local" | head -1 | cut -d= -f2-)
    environment=$(grep '^ENVIRONMENT=' "$REPO_ROOT/.env.local" | head -1 | cut -d= -f2-)

    assert_eq "$db_url" "postgres://griddle:griddle_local@localhost:5432/fjcloud_dev" \
        "DATABASE_URL should be preserved when secret source has unrelated keys"
    assert_eq "$environment" "local" \
        "ENVIRONMENT should be preserved when secret source has unrelated keys"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_suite_uses_isolated_fixture_repo
test_first_run_creates_env_local
test_generated_values_are_not_placeholders
test_generated_file_is_parseable
test_rerun_does_not_overwrite
test_fails_without_example_template
test_generated_values_are_random
test_preserves_non_placeholder_values
test_secret_source_overrides_template
test_default_secret_path_uses_repo_root
test_secret_file_env_override
test_denylist_API_URL_not_appended_from_secrets
test_denylist_admin_key_not_overridden
test_denylist_database_url_not_overridden
test_fallback_without_secret_source
test_secret_source_preserves_non_overlapping_values

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
