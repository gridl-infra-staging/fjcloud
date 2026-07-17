#!/usr/bin/env bash
# Regression test: customer-loop Lambda image must normalize lib helper
# permissions so runtime users can source shared shell libraries.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCKERFILE="$REPO_ROOT/scripts/canary/lambda_image/Dockerfile"

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

main() {
    local content

    echo "=== customer_loop_lambda_image_permissions_test.sh ==="
    echo ""

    if [ ! -f "$DOCKERFILE" ]; then
        fail "Dockerfile exists at scripts/canary/lambda_image/Dockerfile"
    else
        content="$(cat "$DOCKERFILE")"
        assert_contains "$content" "chmod 0755 /var/runtime/bootstrap ./scripts/canary/customer_loop_synthetic.sh" \
            "Dockerfile should keep bootstrap + customer-loop owner executable"
        assert_contains "$content" "chmod 0644 ./scripts/lib/*.sh" \
            "Dockerfile should normalize shared lib helper permissions for Lambda runtime users"
    fi

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
