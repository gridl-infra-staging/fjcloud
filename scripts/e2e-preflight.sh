#!/usr/bin/env bash
# Preflight checks for Stage 6 browser (Playwright) test runs.
# Validates that required environment variables and services are available
# before invoking Playwright, to produce clear errors instead of cryptic failures.
#
# Loads .env.local via the shared env parser so that ADMIN_KEY and other
# local-dev values are available without manual exports.  Explicit E2E_*
# overrides always take precedence.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLAYWRIGHT_CONTRACT_FILE="$REPO_ROOT/web/playwright.config.contract.ts"
SHARED_REMEDIATION="Run scripts/bootstrap-env-local.sh to bootstrap .env.local, then start the local stack with scripts/local-dev-up.sh and the Rust API with scripts/api-dev.sh. If you set BASE_URL, start the web frontend with scripts/web-dev.sh too. See docs/runbooks/local-dev.md for setup instructions."

# shellcheck source=lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"

extract_contract_string_constant() {
    local constant_name="$1"
    local constant_line

    constant_line="$(grep -E "^[[:space:]]*export const ${constant_name} = '.*';[[:space:]]*$" "$PLAYWRIGHT_CONTRACT_FILE" | head -n 1 || true)"
    if [ -z "$constant_line" ]; then
        echo "ERROR: Could not resolve ${constant_name} from ${PLAYWRIGHT_CONTRACT_FILE}" >&2
        exit 1
    fi

    printf '%s\n' "$constant_line" | sed -E "s/^[[:space:]]*export const ${constant_name} = '(.*)';[[:space:]]*$/\\1/"
}

set_env_default_if_unset() {
    local var_name="$1"
    local fallback_value="${2:-}"

    if [ -n "${!var_name:-}" ] || [ -z "$fallback_value" ]; then
        return
    fi

    printf -v "$var_name" '%s' "$fallback_value"
    export "$var_name"
}

# ---------------------------------------------------------------------------
# Load local env context (safe parser, no shell execution). Match the
# Playwright config's precedence by reading repo env first, then web env so
# later web-specific overrides can win without clobbering explicit shell exports.
# ---------------------------------------------------------------------------
load_layered_env_files "$REPO_ROOT/.env.local" "$REPO_ROOT/web/.env.local"

# Keep playwright.config.contract.ts as the single owner for browser fallback defaults.
CONTRACT_DEFAULT_API_URL="$(extract_contract_string_constant "DEFAULT_API_URL")"
CONTRACT_DEFAULT_BASE_URL="$(extract_contract_string_constant "DEFAULT_PLAYWRIGHT_BASE_URL")"
CONTRACT_DEFAULT_E2E_USER_EMAIL="$(extract_contract_string_constant "DEFAULT_E2E_USER_EMAIL")"
CONTRACT_DEFAULT_E2E_USER_PASSWORD="$(extract_contract_string_constant "DEFAULT_E2E_USER_PASSWORD")"

# ---------------------------------------------------------------------------
# Resolve E2E credential defaults from local env context / seed conventions
# ---------------------------------------------------------------------------
# E2E_ADMIN_KEY: explicit override > ADMIN_KEY from .env.local
# (matches Playwright config's resolution: E2E_ADMIN_KEY ?? ADMIN_KEY)
set_env_default_if_unset "E2E_ADMIN_KEY" "${ADMIN_KEY:-}"

# E2E_USER_EMAIL / E2E_USER_PASSWORD: explicit override > SEED_USER_* > seed defaults
# The seed defaults match scripts/seed_local.sh so preflight resolves the
# credentials that seeding actually creates.
set_env_default_if_unset "E2E_USER_EMAIL" "${SEED_USER_EMAIL:-$CONTRACT_DEFAULT_E2E_USER_EMAIL}"
set_env_default_if_unset "E2E_USER_PASSWORD" "${SEED_USER_PASSWORD:-$CONTRACT_DEFAULT_E2E_USER_PASSWORD}"

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
errors=0

shared_remediation_suffix() {
    printf ' — %s' "$SHARED_REMEDIATION"
}

check_var() {
    local var_name="$1"
    local hint="${2:-}"
    if [ -z "${!var_name:-}" ]; then
        echo "FAIL: $var_name is not set${hint:+ — $hint}$(shared_remediation_suffix)" >&2
        errors=$((errors + 1))
    else
        echo "  OK: $var_name is set"
    fi
}

check_service() {
    local success_message="$1"
    local failure_message="$2"
    local url="$3"

    if curl -sf "$url" > /dev/null 2>&1; then
        echo "  OK: $success_message"
        return
    fi

    echo "FAIL: $failure_message$(shared_remediation_suffix)" >&2
    errors=$((errors + 1))
}

json_login_payload() {
    python3 - "$1" "$2" <<'PY'
import json
import sys

print(json.dumps({"email": sys.argv[1], "password": sys.argv[2]}))
PY
}

check_browser_auth_login() {
    local api_url="$1"
    local email="$2"
    local password="$3"
    local login_url="${api_url}/auth/login"
    local body_file
    local payload
    local status
    local response_summary=""

    body_file="$(mktemp)"
    payload="$(json_login_payload "$email" "$password")"
    status="$(
        curl -sS -m 10 -o "$body_file" -w '%{http_code}' \
            -H "Content-Type: application/json" \
            -d "$payload" \
            "$login_url" 2>/dev/null || true
    )"

    if [ "$status" = "200" ]; then
        rm -f "$body_file"
        echo "  OK: Browser auth login succeeded at ${login_url}"
        return
    fi

    if [ -s "$body_file" ]; then
        response_summary="$(tr '\n' ' ' < "$body_file" | cut -c 1-160)"
    fi
    rm -f "$body_file"

    # /health can stay green while the DB-backed auth path is timing out. Probe
    # the exact login route the browser setup uses so Playwright fails fast with
    # actionable remediation instead of a 30-second setup timeout.
    echo "FAIL: Browser auth login failed at ${login_url} (status: ${status:-curl_error})${response_summary:+ — response: ${response_summary}} — verify the seeded browser user with scripts/seed_local.sh and ensure the API can reach Postgres$(shared_remediation_suffix)" >&2
    errors=$((errors + 1))
}

echo "=== E2E Browser Test Preflight ==="
echo ""
echo "--- Required environment variables ---"
check_var E2E_USER_EMAIL "set E2E_USER_EMAIL or run scripts/seed_local.sh first"
check_var E2E_USER_PASSWORD "set E2E_USER_PASSWORD or run scripts/seed_local.sh first"
check_var E2E_ADMIN_KEY "set E2E_ADMIN_KEY or ADMIN_KEY in .env.local"

echo ""
echo "--- Onboarding prerequisites ---"
# DATABASE_URL is required by the chromium:onboarding project's setup step
# (onboarding.auth.setup.ts) to verify freshly signed-up test users via psql.
if [ -n "${DATABASE_URL:-}" ]; then
    echo "  OK: DATABASE_URL is set (required for onboarding lane)"
else
    echo "WARN: DATABASE_URL is not set — chromium:onboarding setup will fail" >&2
    echo "      Set DATABASE_URL in .env.local (e.g. postgres://user:pass@localhost:5432/fjcloud)" >&2
fi

echo ""
echo "--- Node secret manager ---"
backend="${NODE_SECRET_BACKEND:-auto}"
if [ "$backend" = "memory" ]; then
    echo "  OK: NODE_SECRET_BACKEND=memory (local dev mode)"
elif [ "$backend" = "ssm" ]; then
    echo "  OK: NODE_SECRET_BACKEND=ssm (requires AWS credentials)"
elif [ "$backend" = "auto" ]; then
    echo "WARN: NODE_SECRET_BACKEND=auto — will use SSM if AWS is configured, otherwise disabled" >&2
    echo "      Set NODE_SECRET_BACKEND=memory in .env.local for local dev" >&2
else
    echo "WARN: NODE_SECRET_BACKEND=$backend — unrecognized value" >&2
fi

echo ""
echo "--- Service connectivity ---"

# Browser setup touches the API through both fixture-side API_URL and the
# spawned web server's API_BASE_URL, so preflight must honor either override.
api_url="${API_URL:-${API_BASE_URL:-$CONTRACT_DEFAULT_API_URL}}"
check_service \
    "API is reachable at ${api_url}/health" \
    "API is not reachable at ${api_url}/health — start it first" \
    "${api_url}/health"

base_url="${BASE_URL:-$CONTRACT_DEFAULT_BASE_URL}"
# Keep the preflight ownership boundary aligned with resolvePlaywrightRuntime():
# when BASE_URL is unset, Playwright starts the local Svelte dev server itself
# with reuse disabled, so only the API must already be available. When BASE_URL
# is set, the caller has opted out of the spawned web server and preflight must
# verify that externally managed frontend before the browser run begins.
if [ -n "${BASE_URL:-}" ]; then
    check_service \
        "Web frontend is reachable at ${base_url}" \
        "Web frontend is not reachable at ${base_url} — start it first" \
        "${base_url}"
else
    echo "  OK: Playwright will start the local web frontend at ${base_url}"
fi

echo ""
echo "--- Browser auth readiness ---"
if [ -n "${E2E_USER_EMAIL:-}" ] && [ -n "${E2E_USER_PASSWORD:-}" ] \
    && curl -sf "${api_url}/health" > /dev/null 2>&1; then
    check_browser_auth_login "$api_url" "$E2E_USER_EMAIL" "$E2E_USER_PASSWORD"
fi

echo ""
if [ "$errors" -gt 0 ]; then
    echo "PREFLIGHT FAILED: $errors issue(s) must be resolved before running browser tests.$(shared_remediation_suffix)" >&2
    exit 1
else
    echo "PREFLIGHT PASSED: all checks OK."
fi
