#!/usr/bin/env bash
# Test for scripts/launch/hydrate_seeder_env_from_ssm.sh.
#
# Approach: shim `aws` in PATH so each invocation returns a canned value
# keyed by the SSM parameter name. The hydrate script is a thin wrapper
# around `aws ssm get-parameter`, so behavior-level coverage is possible
# without touching real SSM.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HYDRATE_SCRIPT="$REPO_ROOT/scripts/launch/hydrate_seeder_env_from_ssm.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    local actual="$1"
    local expected_substr="$2"
    local msg="$3"
    if [[ "$actual" != *"$expected_substr"* ]]; then
        fail "$msg (expected substring: $expected_substr)"
    fi
}

# Build a PATH-shimmed `aws` binary that returns canned SSM values.
# Each canned value is the suffix of the SSM parameter name; this is
# enough to assert the right SSM path was queried for the right env var.
make_aws_shim() {
    local shim_dir="$1"
    mkdir -p "$shim_dir"
    cat >"$shim_dir/aws" <<'SHIM_EOF'
#!/usr/bin/env bash
# Stub for `aws` that handles `aws ssm get-parameter --name X --with-decryption ... --query Parameter.Value --output text`.
# Every other invocation exits non-zero so unintended AWS calls are caught loudly.
if [ "${1:-}" != "ssm" ] || [ "${2:-}" != "get-parameter" ]; then
    echo "STUB-AWS unexpected invocation: $*" >&2
    exit 99
fi

# Find --name argument
name=""
while [ $# -gt 0 ]; do
    if [ "$1" = "--name" ]; then
        name="$2"
        break
    fi
    shift
done

# Map SSM parameter paths to canned values.
case "$name" in
    /fjcloud/staging/admin_key)              echo "stub-admin-key" ;;
    /fjcloud/staging/database_url)           echo "postgres://stub@stub-db/stub" ;;
    /fjcloud/staging/dns_domain)             echo "flapjack.foo" ;;
    /fjcloud/staging/stripe_secret_key)      echo "rk_test_stub" ;;
    /fjcloud/staging/ses_from_address)       echo "system@flapjack.foo" ;;
    /fjcloud/staging/stripe_webhook_secret)  echo "whsec_stub" ;;
    *) echo "STUB-AWS unknown SSM param: $name" >&2; exit 98 ;;
esac
SHIM_EOF
    chmod +x "$shim_dir/aws"
}

# ---------------------------------------------------------------------------
# Test 1: All canonical exports appear with right values for `staging`.
# ---------------------------------------------------------------------------
test_exports_full_staging_set() {
    local shim_dir
    shim_dir="$(mktemp -d)"
    make_aws_shim "$shim_dir"
    local out
    # PATH-shim aws; preserve the rest of PATH so `bash`, `awk`, etc. resolve.
    out="$(PATH="$shim_dir:$PATH" bash "$HYDRATE_SCRIPT" staging)"
    rm -rf "$shim_dir"

    assert_contains "$out" "export ADMIN_KEY=stub-admin-key" "ADMIN_KEY export missing"
    # printf %q quotes special chars; postgres URL has none so it appears as-is.
    assert_contains "$out" "export DATABASE_URL=postgres://stub@stub-db/stub" "DATABASE_URL export missing"
    assert_contains "$out" "export API_URL=https://api.flapjack.foo" "API_URL derivation missing"
    assert_contains "$out" "export FLAPJACK_URL=" "FLAPJACK_URL fallback missing"
    assert_contains "$out" "export STRIPE_SECRET_KEY=rk_test_stub" "STRIPE_SECRET_KEY export missing"

    # New exports added in this change. These are the red-then-green deltas.
    assert_contains "$out" "export SES_FROM_ADDRESS=system@flapjack.foo" "SES_FROM_ADDRESS export missing — required to fix RC ses_inbound DMARC fail"
    assert_contains "$out" "export STRIPE_WEBHOOK_SECRET=whsec_stub" "STRIPE_WEBHOOK_SECRET export missing — required by staging billing rehearsal"
    assert_contains "$out" "export STAGING_API_URL=https://api.flapjack.foo" "STAGING_API_URL derivation missing — required by staging billing rehearsal"
    assert_contains "$out" "export STAGING_STRIPE_WEBHOOK_URL=https://api.flapjack.foo/webhooks/stripe" "STAGING_STRIPE_WEBHOOK_URL derivation missing — RC misclassifies as dns_or_cloudflare_blocked when unset"

    echo "  PASS test_exports_full_staging_set"
}

# ---------------------------------------------------------------------------
# Test 2: Script fails loudly when an SSM parameter is missing.
# Regression: a silent empty value would propagate and the rehearsal would
# fail downstream with a confusing classification.
# ---------------------------------------------------------------------------
test_fails_on_missing_ssm_param() {
    local shim_dir
    shim_dir="$(mktemp -d)"
    # Shim that returns "None" for ses_from_address (simulates AWS CLI
    # behavior when the parameter doesn't exist) and canned values for
    # others.
    cat >"$shim_dir/aws" <<'SHIM_EOF'
#!/usr/bin/env bash
name=""
while [ $# -gt 0 ]; do
    if [ "$1" = "--name" ]; then name="$2"; break; fi
    shift
done
case "$name" in
    /fjcloud/staging/admin_key)              echo "stub-admin-key" ;;
    /fjcloud/staging/database_url)           echo "postgres://stub@stub-db/stub" ;;
    /fjcloud/staging/dns_domain)             echo "flapjack.foo" ;;
    /fjcloud/staging/stripe_secret_key)      echo "rk_test_stub" ;;
    /fjcloud/staging/ses_from_address)       echo "None" ;;  # missing param
    /fjcloud/staging/stripe_webhook_secret)  echo "whsec_stub" ;;
    *) exit 98 ;;
esac
SHIM_EOF
    chmod +x "$shim_dir/aws"

    local exit_status=0
    PATH="$shim_dir:$PATH" bash "$HYDRATE_SCRIPT" staging >/dev/null 2>&1 || exit_status=$?
    rm -rf "$shim_dir"

    if [ "$exit_status" = "0" ]; then
        fail "expected non-zero exit when ses_from_address SSM param is missing, got 0"
    fi
    echo "  PASS test_fails_on_missing_ssm_param"
}

echo "Running hydrate_seeder_env_from_ssm tests..."
test_exports_full_staging_set
test_fails_on_missing_ssm_param
echo "All hydrate_seeder_env_from_ssm tests passed."
