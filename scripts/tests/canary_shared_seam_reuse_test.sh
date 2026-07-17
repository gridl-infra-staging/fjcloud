#!/usr/bin/env bash
# Regression test: Stage 4 canary must reuse shared HTTP/Stripe request seams.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

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

test_canary_uses_shared_request_seams() {
    local canary_content local_signoff_content validate_stripe_content

    canary_content="$(cat "$REPO_ROOT/scripts/canary/customer_loop_synthetic.sh")"
    local_signoff_content="$(cat "$REPO_ROOT/scripts/local-signoff-commerce.sh")"
    validate_stripe_content="$(cat "$REPO_ROOT/scripts/validate-stripe.sh")"

    assert_not_contains "$canary_content" "api_json_call()" \
        "canary should not define api_json_call inline"
    assert_not_contains "$canary_content" "admin_call()" \
        "canary should not define admin_call inline"
    assert_not_contains "$canary_content" "tenant_call()" \
        "canary should not define tenant_call inline"
    assert_not_contains "$canary_content" "capture_json_response()" \
        "canary should not define capture_json_response inline"
    assert_not_contains "$canary_content" "stripe_request()" \
        "canary should not define stripe_request inline"

    assert_contains "$canary_content" "source \"\$REPO_ROOT/scripts/lib/http_json.sh\"" \
        "canary should source scripts/lib/http_json.sh"
    assert_contains "$canary_content" "source \"\$REPO_ROOT/scripts/lib/stripe_request.sh\"" \
        "canary should source scripts/lib/stripe_request.sh"

    assert_contains "$local_signoff_content" "source \"\$SCRIPT_DIR/lib/http_json.sh\"" \
        "local signoff owner should source scripts/lib/http_json.sh"
    assert_contains "$validate_stripe_content" "source \"\$SCRIPT_DIR/lib/stripe_request.sh\"" \
        "validate-stripe owner should source scripts/lib/stripe_request.sh"
}

main() {
    echo "=== canary_shared_seam_reuse_test.sh ==="
    echo ""

    test_canary_uses_shared_request_seams

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
