#!/usr/bin/env bash
# ci_stripe_local_mode_test.sh — Contract test: e2e-deployed CI job must set
# STRIPE_LOCAL_MODE: "1" in its env block so Playwright runs use the local
# Stripe mock instead of hitting live Stripe in staging.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW_FILE="$REPO_ROOT/.github/workflows/ci.yml"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

job_block() {
    local job_name="$1"
    awk -v job="$job_name" '
        $0 ~ "^  " job ":$" { in_job=1; print; next }
        in_job && $0 ~ "^  [a-zA-Z0-9_-]+:$" { exit }
        in_job { print }
    ' "$WORKFLOW_FILE"
}

test_e2e_deployed_has_stripe_local_mode() {
    local block
    block="$(job_block "e2e-deployed")"
    if [[ -z "$block" ]]; then
        fail "e2e-deployed job block not found in ci.yml"
        return
    fi
    if echo "$block" | grep -E 'STRIPE_LOCAL_MODE:[[:space:]]+"1"' >/dev/null 2>&1; then
        pass "e2e-deployed env contains STRIPE_LOCAL_MODE: \"1\""
    else
        fail "e2e-deployed env missing STRIPE_LOCAL_MODE: \"1\""
    fi
}

main() {
    echo "=== ci_stripe_local_mode_test.sh ==="
    echo ""

    test_e2e_deployed_has_stripe_local_mode

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
