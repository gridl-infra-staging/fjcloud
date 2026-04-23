#!/usr/bin/env bash
# Tests for scripts/e2e-preflight.sh messaging and failure hints.
#
# Covers:
#   - E2E_ADMIN_KEY fallback from ADMIN_KEY in .env.local
#   - Seeded user credential defaults (dev@example.com / localdev-password-1234)
#   - Explicit E2E_* overrides preserved over fallbacks
#   - Error output names the exact unresolved prerequisite
#   - Failure hint points to docs/runbooks/local-dev.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PREFLIGHT_SCRIPT="$REPO_ROOT/scripts/e2e-preflight.sh"
PLAYWRIGHT_CONTRACT_FILE="$REPO_ROOT/web/playwright.config.contract.ts"
LOCAL_DEV_RUNBOOK_FILE="$REPO_ROOT/docs/runbooks/local-dev.md"

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

# stage-2 preflight tests also exercise web/.env.local layering, so mirror the
# repo .env.local backup/restore helper for the web-side env file.
backup_web_env_file() {
    local backup_path="$1"
    if [ -f "$REPO_ROOT/web/.env.local" ]; then
        cp "$REPO_ROOT/web/.env.local" "$backup_path"
        return 0
    fi
    return 1
}

restore_web_env_file() {
    local backup_path="$1"
    if [ -f "$backup_path" ]; then
        cp "$backup_path" "$REPO_ROOT/web/.env.local"
    else
        rm -f "$REPO_ROOT/web/.env.local"
    fi
}

backup_preflight_env_files() {
    local tmp_dir="$1"
    backup_repo_env_file "$tmp_dir/env_backup" || true
    backup_web_env_file "$tmp_dir/web_env_backup" || true
}

restore_preflight_env_files() {
    local tmp_dir="$1"
    restore_repo_env_file "$tmp_dir/env_backup"
    restore_web_env_file "$tmp_dir/web_env_backup"
}

read_playwright_contract() {
    cat "$PLAYWRIGHT_CONTRACT_FILE"
}

read_local_dev_runbook() {
    cat "$LOCAL_DEV_RUNBOOK_FILE"
}

assert_contract_contains() {
    local needle="$1"
    local message="$2"
    assert_contains "$(read_playwright_contract)" "$needle" "$message"
}

assert_contract_not_contains() {
    local needle="$1"
    local message="$2"
    assert_not_contains "$(read_playwright_contract)" "$needle" "$message"
}

# Helper: run preflight in a clean env with a caller-provided curl mock body.
# Accepts additional env vars as KEY=VALUE arguments after the curl body.
run_preflight_isolated_with_curl_body() {
    local tmp_dir="$1"
    local curl_body="$2"
    shift 2

    mkdir -p "$tmp_dir/bin"
    write_mock_script "$tmp_dir/bin/curl" "$curl_body"

    if [ $# -gt 0 ]; then
        env -i \
            HOME="$HOME" \
            PATH="$tmp_dir/bin:/usr/bin:/bin" \
            "$@" \
            bash "$PREFLIGHT_SCRIPT" 2>&1 || true
    else
        env -i \
            HOME="$HOME" \
            PATH="$tmp_dir/bin:/usr/bin:/bin" \
            bash "$PREFLIGHT_SCRIPT" 2>&1 || true
    fi
}

# Helper: run preflight in a clean env with mock curl (services always "down").
# Accepts additional env vars as KEY=VALUE arguments after the tmp_dir.
run_preflight_isolated() {
    local tmp_dir="$1"
    shift
    run_preflight_isolated_with_curl_body "$tmp_dir" 'exit 1' "$@"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test_admin_key_resolves_from_env_local() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    backup_preflight_env_files "$tmp_dir"
    trap 'restore_preflight_env_files "'"$tmp_dir"'"; rm -rf "'"$tmp_dir"'"; trap - RETURN' RETURN

    # Isolate the repo-level fallback by removing any web/.env.local overrides.
    rm -f "$REPO_ROOT/web/.env.local"

    # Write .env.local with ADMIN_KEY only — no E2E_ADMIN_KEY
    cat > "$REPO_ROOT/.env.local" <<'EOF'
ADMIN_KEY=test-admin-key-for-preflight
EOF

    local output
    output=$(run_preflight_isolated "$tmp_dir")

    # E2E_ADMIN_KEY should resolve from ADMIN_KEY in .env.local, not appear as FAIL
    assert_not_contains "$output" "FAIL: E2E_ADMIN_KEY" \
        "E2E_ADMIN_KEY should resolve from ADMIN_KEY in .env.local"
}

test_seeded_user_credentials_default_from_seed() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    backup_preflight_env_files "$tmp_dir"
    trap 'restore_preflight_env_files "'"$tmp_dir"'"; rm -rf "'"$tmp_dir"'"; trap - RETURN' RETURN

    # Keep web/.env.local out of the picture so this exercises the default seed path.
    rm -f "$REPO_ROOT/web/.env.local"

    # Provide ADMIN_KEY so that check passes; user creds should resolve from seed defaults
    cat > "$REPO_ROOT/.env.local" <<'EOF'
ADMIN_KEY=test-admin-key-for-preflight
EOF

    local output
    output=$(run_preflight_isolated "$tmp_dir")

    assert_not_contains "$output" "FAIL: E2E_USER_EMAIL" \
        "E2E_USER_EMAIL should default to seeded value (dev@example.com)"
    assert_not_contains "$output" "FAIL: E2E_USER_PASSWORD" \
        "E2E_USER_PASSWORD should default to seeded value"
}

test_explicit_e2e_overrides_preserved() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    backup_preflight_env_files "$tmp_dir"
    trap 'restore_preflight_env_files "'"$tmp_dir"'"; rm -rf "'"$tmp_dir"'"; trap - RETURN' RETURN

    # Layered env files provide fallbacks that explicit E2E_* values must override.
    cat > "$REPO_ROOT/.env.local" <<'EOF'
ADMIN_KEY=fallback-admin-key
SEED_USER_EMAIL=repo-seed@example.com
SEED_USER_PASSWORD=repo-seed-password
EOF
    cat > "$REPO_ROOT/web/.env.local" <<'EOF'
ADMIN_KEY=web-fallback-admin-key
SEED_USER_EMAIL=web-seed@example.com
SEED_USER_PASSWORD=web-seed-password
EOF

    local verify_explicit_curl_body
    verify_explicit_curl_body=$(cat <<'EOF'
[ "${E2E_ADMIN_KEY:-}" = "explicit-override-key" ] || exit 1
[ "${E2E_USER_EMAIL:-}" = "custom@test.com" ] || exit 1
[ "${E2E_USER_PASSWORD:-}" = "custom-pass" ] || exit 1
exit 0
EOF
)

    local output
    output=$(run_preflight_isolated_with_curl_body "$tmp_dir" "$verify_explicit_curl_body" \
        "E2E_ADMIN_KEY=explicit-override-key" \
        "E2E_USER_EMAIL=custom@test.com" \
        "E2E_USER_PASSWORD=custom-pass")

    # All three should pass — explicit overrides take precedence
    assert_not_contains "$output" "FAIL: E2E_ADMIN_KEY" \
        "explicit E2E_ADMIN_KEY should be preserved over .env.local ADMIN_KEY"
    assert_not_contains "$output" "FAIL: E2E_USER_EMAIL" \
        "explicit E2E_USER_EMAIL should be preserved"
    assert_not_contains "$output" "FAIL: E2E_USER_PASSWORD" \
        "explicit E2E_USER_PASSWORD should be preserved"
    assert_not_contains "$output" "FAIL: API is not reachable" \
        "curl probe should accept only the explicit E2E_* values after fallback resolution"
    assert_not_contains "$output" "FAIL: Web frontend is not reachable" \
        "curl probe should accept only the explicit E2E_* values after fallback resolution"
}

test_layered_env_files_feed_preflight_fallback_chain() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    backup_preflight_env_files "$tmp_dir"
    trap 'restore_preflight_env_files "'"$tmp_dir"'"; rm -rf "'"$tmp_dir"'"; trap - RETURN' RETURN

    # Repo-level defaults.
    cat > "$REPO_ROOT/.env.local" <<'EOF'
ADMIN_KEY=repo-admin-key
SEED_USER_EMAIL=repo-seed@example.com
SEED_USER_PASSWORD=repo-seed-password
EOF
    # web/.env.local should override repo-level values when explicit E2E_* vars are unset.
    cat > "$REPO_ROOT/web/.env.local" <<'EOF'
ADMIN_KEY=web-admin-key
SEED_USER_EMAIL=web-seed@example.com
SEED_USER_PASSWORD=web-seed-password
EOF

    local verify_layered_curl_body
    verify_layered_curl_body=$(cat <<'EOF'
[ "${E2E_ADMIN_KEY:-}" = "web-admin-key" ] || exit 1
[ "${E2E_USER_EMAIL:-}" = "web-seed@example.com" ] || exit 1
[ "${E2E_USER_PASSWORD:-}" = "web-seed-password" ] || exit 1
exit 0
EOF
)

    local output
    output=$(run_preflight_isolated_with_curl_body "$tmp_dir" "$verify_layered_curl_body")

    assert_not_contains "$output" "FAIL: API is not reachable" \
        "E2E_ADMIN_KEY should resolve from layered ADMIN_KEY in web/.env.local"
    assert_not_contains "$output" "FAIL: Web frontend is not reachable" \
        "E2E_USER_EMAIL/E2E_USER_PASSWORD should resolve from layered SEED_USER_* in web/.env.local"
}

test_api_base_url_override_drives_api_probe() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    backup_preflight_env_files "$tmp_dir"
    trap 'restore_preflight_env_files "'"$tmp_dir"'"; rm -rf "'"$tmp_dir"'"; trap - RETURN' RETURN

    local verify_api_base_url_curl_body
    verify_api_base_url_curl_body=$(cat <<'EOF'
if [ "$2" = "http://127.0.0.1:3999/health" ]; then
    exit 0
fi
if [ "$2" = "http://localhost:5173" ]; then
    exit 0
fi
exit 1
EOF
)

    local output
    output=$(run_preflight_isolated_with_curl_body "$tmp_dir" "$verify_api_base_url_curl_body" \
        "ADMIN_KEY=test-admin-key-for-preflight" \
        "API_BASE_URL=http://127.0.0.1:3999")

    assert_not_contains "$output" "FAIL: API is not reachable at http://127.0.0.1:3999/health" \
        "API_BASE_URL should drive the API health probe when API_URL is unset"
    assert_not_contains "$output" "FAIL: API is not reachable at http://localhost:3001/health" \
        "preflight should not fall back to the default API URL when API_BASE_URL is provided"
    assert_not_contains "$output" "FAIL: Web frontend is not reachable" \
        "the mocked BASE_URL probe should still pass while verifying API_BASE_URL precedence"
}

test_missing_admin_key_names_exact_prerequisite() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    backup_preflight_env_files "$tmp_dir"
    trap 'restore_preflight_env_files "'"$tmp_dir"'"; rm -rf "'"$tmp_dir"'"; trap - RETURN' RETURN

    # No .env.local anywhere — ADMIN_KEY not available from either layered source.
    rm -f "$REPO_ROOT/.env.local"
    rm -f "$REPO_ROOT/web/.env.local"

    local output
    output=$(run_preflight_isolated "$tmp_dir")

    # Error should name the exact missing variable
    assert_contains "$output" "FAIL: E2E_ADMIN_KEY" \
        "should report E2E_ADMIN_KEY as missing when ADMIN_KEY unavailable"
    # Error should mention the fallback source so operators know where to configure it
    assert_contains "$output" "ADMIN_KEY" \
        "should mention ADMIN_KEY as the fallback source"
    assert_contains "$output" ".env.local" \
        "should mention .env.local as the configuration path"
    assert_contains "$output" "scripts/bootstrap-env-local.sh" \
        "missing admin key guidance should point to bootstrap-env-local.sh"
    assert_contains "$output" "docs/runbooks/local-dev.md" \
        "missing admin key guidance should still point to the local-dev runbook"
    assert_not_contains "$output" ".env.local.example" \
        "preflight should not suggest alternate env-bootstrap entrypoints"
}

test_service_connectivity_failure_includes_bootstrap_remediation() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    backup_preflight_env_files "$tmp_dir"
    trap 'restore_preflight_env_files "'"$tmp_dir"'"; rm -rf "'"$tmp_dir"'"; trap - RETURN' RETURN

    # Ensure env variables pass so failures are connectivity-only.
    cat > "$REPO_ROOT/.env.local" <<'EOF'
ADMIN_KEY=test-admin-key-for-preflight
SEED_USER_EMAIL=dev@example.com
SEED_USER_PASSWORD=localdev-password-1234
EOF

    local output
    output=$(run_preflight_isolated "$tmp_dir" "BASE_URL=http://localhost:5173")

    assert_contains "$output" "FAIL: API is not reachable" \
        "service failure should include API connectivity diagnostics"
    assert_contains "$output" "FAIL: Web frontend is not reachable" \
        "service failure should include web connectivity diagnostics"
    assert_contains "$output" "scripts/bootstrap-env-local.sh" \
        "service connectivity failures should include bootstrap remediation command"
    assert_contains "$output" "docs/runbooks/local-dev.md" \
        "service connectivity failures should still reference the local-dev runbook"
    assert_not_contains "$output" ".env.local.example" \
        "service connectivity guidance should keep .env.local as the only bootstrap flow"
}

test_preflight_skips_web_probe_when_playwright_starts_web_server() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    backup_preflight_env_files "$tmp_dir"
    trap 'restore_preflight_env_files "'"$tmp_dir"'"; rm -rf "'"$tmp_dir"'"; trap - RETURN' RETURN

    # Provide the minimum env contract so only service ownership behavior is
    # under test.
    cat > "$REPO_ROOT/.env.local" <<'EOF'
ADMIN_KEY=test-admin-key-for-preflight
SEED_USER_EMAIL=dev@example.com
SEED_USER_PASSWORD=localdev-password-1234
EOF

    local api_only_curl_body
    api_only_curl_body='for arg in "$@"; do
    case "$arg" in
        http://localhost:*/health)
            exit 0
            ;;
        http://localhost:*/auth/login)
            printf 200
            exit 0
            ;;
    esac
done
exit 1'

    local output
    output=$(run_preflight_isolated_with_curl_body "$tmp_dir" "$api_only_curl_body")

    assert_not_contains "$output" "FAIL: Web frontend is not reachable" \
        "preflight should not require a separate web server when BASE_URL is unset"
    assert_contains "$output" "Playwright will start the local web frontend" \
        "preflight should explain that the default Playwright runtime owns the web server"
    assert_contains "$output" "PREFLIGHT PASSED" \
        "preflight should pass when API readiness succeeds and Playwright owns the web server"
}

test_auth_login_failure_is_reported_before_browser_run() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    backup_preflight_env_files "$tmp_dir"
    trap 'restore_preflight_env_files "'"$tmp_dir"'"; rm -rf "'"$tmp_dir"'"; trap - RETURN' RETURN

    cat > "$REPO_ROOT/.env.local" <<'EOF'
ADMIN_KEY=test-admin-key-for-preflight
SEED_USER_EMAIL=dev@example.com
SEED_USER_PASSWORD=localdev-password-1234
EOF

    local auth_probe_failure_curl_body
    auth_probe_failure_curl_body='for arg in "$@"; do
    case "$arg" in
        http://localhost:5173|http://localhost:*/health)
            exit 0
            ;;
        http://localhost:*/auth/login)
            exit 28
            ;;
    esac
done
exit 1'

    local output
    output=$(run_preflight_isolated_with_curl_body "$tmp_dir" "$auth_probe_failure_curl_body")

    assert_contains "$output" "FAIL: Browser auth login failed" \
        "preflight should fail fast when the seeded browser login probe cannot complete"
    assert_contains "$output" "/auth/login" \
        "auth login failure should name the exact endpoint"
}

test_failure_hint_points_to_local_dev_runbook() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    mkdir -p "$tmp_dir/bin"
    write_mock_script "$tmp_dir/bin/curl" 'exit 1'

    local output exit_code=0
    output=$(
        env -i \
            HOME="$HOME" \
            PATH="$tmp_dir/bin:/usr/bin:/bin" \
            bash "$PREFLIGHT_SCRIPT" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" "should fail when required preflight state is missing"
    assert_contains "$output" "docs/runbooks/local-dev.md" \
        "should direct preflight failures to the local-dev runbook"
}

# ---------------------------------------------------------------------------
# Local-dev runbook alignment tests
# ---------------------------------------------------------------------------

test_runbook_uses_bash_seed_local_invocation() {
    local runbook_content
    runbook_content="$(read_local_dev_runbook)"

    assert_contains "$runbook_content" "bash scripts/seed_local.sh" \
        "runbook should invoke seed_local.sh via bash to match tracked script mode"
    assert_not_contains "$runbook_content" "./scripts/seed_local.sh" \
        "runbook should not require execute-bit invocation for seed_local.sh"
}

test_runbook_covers_web_dependency_before_playwright() {
    local runbook_content
    runbook_content="$(read_local_dev_runbook)"

    assert_contains "$runbook_content" "cd web && npm ci" \
        "runbook should document installing web dependencies before Playwright commands"
}

# ---------------------------------------------------------------------------
# Playwright contract env propagation tests
# ---------------------------------------------------------------------------
# The fallback chain lives in playwright.config.contract.ts (single source of
# truth). playwright.config.ts is a thin consumer that calls
# applyPlaywrightProcessEnvDefaults.  These tests verify the contract file
# contains the expected resolution logic and seed defaults.

test_contract_resolves_e2e_user_email() {
    assert_contract_contains "E2E_USER_EMAIL" \
        "contract should resolve E2E_USER_EMAIL"
    assert_contract_contains "dev@example.com" \
        "contract should define the same seed default email as e2e-preflight.sh"
}

test_contract_resolves_e2e_user_password() {
    assert_contract_contains "E2E_USER_PASSWORD" \
        "contract should resolve E2E_USER_PASSWORD"
    assert_contract_contains "localdev-password-1234" \
        "contract should define the same seed default password as e2e-preflight.sh"
}

test_contract_resolves_e2e_admin_key() {
    assert_contract_contains "E2E_ADMIN_KEY" \
        "contract should resolve E2E_ADMIN_KEY"
    assert_contract_contains "processEnv.E2E_ADMIN_KEY" \
        "contract should read processEnv.E2E_ADMIN_KEY in the fallback chain"
}

test_contract_web_server_uses_strict_port() {
    assert_contract_contains "--port 5173 --strictPort" \
        "contract should keep Playwright's owned web server on the exact checked local port"
}

test_contract_does_not_invent_admin_key_fallback() {
    assert_contract_not_contains "integration-test-admin-key" \
        "contract should not inject a hard-coded admin key that drifts from local-dev and preflight contracts"
}

# ---------------------------------------------------------------------------
# Contract .env.local layered source propagation tests
# ---------------------------------------------------------------------------
# Verify the contract's applyPlaywrightProcessEnvDefaults reads E2E_USER_EMAIL,
# E2E_USER_PASSWORD, and E2E_ADMIN_KEY from all three sources (processEnv,
# repoEnv, webEnv), not just a subset.

test_contract_reads_dotenv_e2e_admin_key() {
    assert_contract_contains "repoEnv.E2E_ADMIN_KEY" \
        "contract should check repoEnv.E2E_ADMIN_KEY from parsed repo .env.local"
    assert_contract_contains "webEnv.E2E_ADMIN_KEY" \
        "contract should check webEnv.E2E_ADMIN_KEY from parsed web .env.local"
}

test_contract_reads_dotenv_e2e_user_email() {
    assert_contract_contains "repoEnv.E2E_USER_EMAIL" \
        "contract should check repoEnv.E2E_USER_EMAIL from parsed repo .env.local"
    assert_contract_contains "webEnv.E2E_USER_EMAIL" \
        "contract should check webEnv.E2E_USER_EMAIL from parsed web .env.local"
}

test_contract_reads_dotenv_e2e_user_password() {
    assert_contract_contains "repoEnv.E2E_USER_PASSWORD" \
        "contract should check repoEnv.E2E_USER_PASSWORD from parsed repo .env.local"
    assert_contract_contains "webEnv.E2E_USER_PASSWORD" \
        "contract should check webEnv.E2E_USER_PASSWORD from parsed web .env.local"
}

# ---------------------------------------------------------------------------
# Preflight + Playwright contract alignment test
# ---------------------------------------------------------------------------
# Verify preflight consumes seed defaults from the contract (single source of truth)
# instead of hardcoding fallback literals.

test_preflight_and_contract_share_seed_defaults() {
    local preflight_content
    preflight_content=$(cat "$PREFLIGHT_SCRIPT")

    # Contract owns the fallback literal values.
    assert_contract_contains "dev@example.com" \
        "contract seed default email is present"
    assert_contract_contains "localdev-password-1234" \
        "contract seed default password is present"

    # Preflight should reference the contract file and avoid re-declaring those literals.
    assert_contains "$preflight_content" "web/playwright.config.contract.ts" \
        "preflight should read fallback defaults from the contract file"
    assert_not_contains "$preflight_content" "dev@example.com" \
        "preflight should not hardcode fallback email literal"
    assert_not_contains "$preflight_content" "localdev-password-1234" \
        "preflight should not hardcode fallback password literal"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    echo "=== e2e-preflight.sh tests ==="
    echo ""

    test_admin_key_resolves_from_env_local
    test_seeded_user_credentials_default_from_seed
    test_explicit_e2e_overrides_preserved
    test_layered_env_files_feed_preflight_fallback_chain
    test_api_base_url_override_drives_api_probe
    test_missing_admin_key_names_exact_prerequisite
    test_service_connectivity_failure_includes_bootstrap_remediation
    test_preflight_skips_web_probe_when_playwright_starts_web_server
    test_auth_login_failure_is_reported_before_browser_run
    test_failure_hint_points_to_local_dev_runbook

    echo ""
    echo "--- Local-dev runbook alignment ---"
    test_runbook_uses_bash_seed_local_invocation
    test_runbook_covers_web_dependency_before_playwright

    echo ""
    echo "--- Playwright contract env propagation ---"
    test_contract_resolves_e2e_user_email
    test_contract_resolves_e2e_user_password
    test_contract_resolves_e2e_admin_key
    test_contract_web_server_uses_strict_port
    test_contract_does_not_invent_admin_key_fallback
    test_preflight_and_contract_share_seed_defaults

    echo ""
    echo "--- Contract .env.local layered source propagation ---"
    test_contract_reads_dotenv_e2e_admin_key
    test_contract_reads_dotenv_e2e_user_email
    test_contract_reads_dotenv_e2e_user_password

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
