#!/usr/bin/env bash
# Regression test: when Lambda bootstrap has already hydrated SSM-backed env
# vars into actual secret values, the canary's load_canary_env helper must NOT
# attempt to resolve those values as SSM parameter names a second time.
#
# Without this guard, a resolved secret value that happens to start with "/"
# (e.g. a URL-safe random admin key beginning with "/") gets misinterpreted by
# resolve_ssm_parameter_if_configured as another SSM path and the canary exits
# with "failed to resolve SSM parameter <value>" while the underlying value is
# already correct.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CANARY_SCRIPT="$REPO_ROOT/scripts/canary/customer_loop_synthetic.sh"

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

if [ ! -f "$CANARY_SCRIPT" ]; then
    fail "canary script exists at scripts/canary/customer_loop_synthetic.sh"
    exit 1
fi

# shellcheck source=scripts/canary/customer_loop_synthetic.sh
source "$CANARY_SCRIPT"

AWS_CALLS=0
aws() {
    AWS_CALLS=$((AWS_CALLS + 1))
    # Behave like the live SSM endpoint refusing to resolve the value-as-path.
    return 254
}

test_skips_second_pass_when_bootstrap_hydrated() {
    AWS_CALLS=0
    export CANARY_AWS_REGION="us-east-1"
    export CANARY_SSM_HYDRATED="1"
    # Already-hydrated value that happens to start with "/" — must NOT be
    # re-resolved against SSM.
    export ADMIN_KEY="/uiaeMnmRzsOPw0aEglARrv5hW6GX0pi"

    local err_file
    err_file="$(mktemp)"
    if ! resolve_ssm_parameter_if_configured "ADMIN_KEY" 2>"$err_file"; then
        local err
        err="$(cat "$err_file" 2>/dev/null || true)"
        rm -f "$err_file"
        unset CANARY_SSM_HYDRATED
        fail "resolve_ssm_parameter_if_configured must succeed when CANARY_SSM_HYDRATED=1; stderr: ${err}"
        return
    fi
    rm -f "$err_file"

    assert_eq "$AWS_CALLS" "0" \
        "resolve_ssm_parameter_if_configured must not call aws when CANARY_SSM_HYDRATED=1"
    assert_eq "$ADMIN_KEY" "/uiaeMnmRzsOPw0aEglARrv5hW6GX0pi" \
        "resolve_ssm_parameter_if_configured must preserve the hydrated value verbatim"
    unset CANARY_SSM_HYDRATED
}

test_resolves_when_not_hydrated() {
    AWS_CALLS=0
    export CANARY_AWS_REGION="us-east-1"
    unset CANARY_SSM_HYDRATED || true
    export ADMIN_KEY="/fjcloud/prod/admin_key"

    # Local override of aws that succeeds with a captured value.
    aws() {
        AWS_CALLS=$((AWS_CALLS + 1))
        if [ "${1:-}" = "ssm" ] && [ "${2:-}" = "get-parameter" ]; then
            printf '%s\n' "resolved-admin-value"
            return 0
        fi
        return 1
    }

    if ! resolve_ssm_parameter_if_configured "ADMIN_KEY"; then
        fail "resolve_ssm_parameter_if_configured should resolve via aws when CANARY_SSM_HYDRATED unset"
        return
    fi
    # AWS_CALLS lives in caller scope and the helper invokes aws within $(...)
    # subshell, so the counter is not observable here; assert via the resolved
    # value, which proves the helper actually ran the aws path.
    assert_eq "$ADMIN_KEY" "resolved-admin-value" \
        "resolve_ssm_parameter_if_configured should overwrite ADMIN_KEY with resolved value"
}

main() {
    echo "=== customer_loop_canary_skip_double_ssm_resolution_test.sh ==="
    echo ""

    test_skips_second_pass_when_bootstrap_hydrated
    test_resolves_when_not_hydrated

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
