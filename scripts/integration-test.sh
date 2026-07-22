#!/usr/bin/env bash
# integration-test.sh — Run integration tests against an isolated stack.
#
# Brings up the integration stack, runs tests with INTEGRATION=1, then tears down.
# The stack is always torn down on exit (via trap).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/integration_stack_env.sh
source "$SCRIPT_DIR/lib/integration_stack_env.sh"

log() { echo "[integration-test] $*"; }

ensure_integration_internal_auth_token() {
    if [ -n "${INTEGRATION_INTERNAL_AUTH_TOKEN:-}" ]; then
        export INTEGRATION_INTERNAL_AUTH_TOKEN
        return 0
    fi

    INTEGRATION_INTERNAL_AUTH_TOKEN="$(
        python3 - <<'PY'
import secrets

print(secrets.token_hex(24))
PY
    )"
    export INTEGRATION_INTERNAL_AUTH_TOKEN
}

run_integration_tests() {
    init_integration_env_defaults
    ensure_integration_internal_auth_token

    log "Running integration tests..."

    INTEGRATION=1 \
        INTEGRATION_API_BASE="http://localhost:${API_PORT:-3099}" \
        INTEGRATION_FLAPJACK_BASE="http://127.0.0.1:${FLAPJACK_PORT:-7799}" \
        INTEGRATION_DB_URL="$INTEGRATION_DB_URL" \
        INTEGRATION_JWT_SECRET="integration-test-jwt-secret-000000" \
        INTEGRATION_ADMIN_KEY="integration-test-admin-key" \
        INTEGRATION_INTERNAL_AUTH_TOKEN="$INTEGRATION_INTERNAL_AUTH_TOKEN" \
        cargo test -p api --test platform integration_ -- --test-threads=1 "$@"

    log "Integration tests complete!"
}

main() {
    ensure_integration_internal_auth_token

    # Ensure teardown happens on any exit
    trap "$SCRIPT_DIR/integration-down.sh" EXIT

    # Bring up the stack
    "$SCRIPT_DIR/integration-up.sh"

    # Run integration tests (single-threaded to avoid port/DB conflicts)
    run_integration_tests "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
