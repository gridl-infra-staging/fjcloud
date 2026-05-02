#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/ops/scripts/lib/generate_ssm_env.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

assert_contains_line() {
  local file="$1"
  local expected="$2"
  if grep -Fxq "$expected" "$file"; then
    pass "env file contains $expected"
  else
    fail "env file missing line: $expected"
  fi
}

assert_not_contains_prefix() {
  local file="$1"
  local prefix="$2"
  if grep -q "^${prefix}" "$file"; then
    fail "env file unexpectedly contains prefix ${prefix}"
  else
    pass "env file omits prefix ${prefix}"
  fi
}

test_omits_legacy_stripe_price_exports() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  local shim_dir="$tmpdir/shims"
  local out_env="$tmpdir/env"
  local out_metering="$tmpdir/metering-env"
  mkdir -p "$shim_dir"

  cat > "$shim_dir/aws" <<'AWS_EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ge 2 && "$1" == "ssm" && "$2" == "get-parameters-by-path" ]]; then
  cat <<'JSON_EOF'
{"Parameters":[
  {"Name":"/fjcloud/staging/stripe_secret_key","Value":"sk_test_123"},
  {"Name":"/fjcloud/staging/stripe_publishable_key","Value":"pk_test_123"},
  {"Name":"/fjcloud/staging/stripe_webhook_secret","Value":"whsec_123"},
  {"Name":"/fjcloud/staging/stripe_success_url","Value":"https://example.com/success"},
  {"Name":"/fjcloud/staging/stripe_cancel_url","Value":"https://example.com/cancel"},
  {"Name":"/fjcloud/staging/stripe_price_starter","Value":"price_starter"},
  {"Name":"/fjcloud/staging/stripe_price_pro","Value":"price_pro"},
  {"Name":"/fjcloud/staging/stripe_price_enterprise","Value":"price_enterprise"}
]}
JSON_EOF
  exit 0
fi
if [[ $# -ge 2 && "$1" == "ssm" && "$2" == "get-parameter" ]]; then
  echo "node_api_key"
  exit 0
fi
echo "unexpected aws invocation: $*" >&2
exit 1
AWS_EOF

  cat > "$shim_dir/curl" <<'CURL_EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *"latest/api/token"* ]]; then
  echo "token"
  exit 0
fi
if [[ "$*" == *"meta-data/placement/region"* ]]; then
  echo "us-east-1"
  exit 0
fi
if [[ "$*" == *"meta-data/tags/instance/customer_id"* ]]; then
  echo "None"
  exit 0
fi
if [[ "$*" == *"meta-data/tags/instance/node_id"* ]]; then
  echo "None"
  exit 0
fi
echo "unexpected curl invocation: $*" >&2
exit 1
CURL_EOF

  chmod +x "$shim_dir/aws" "$shim_dir/curl"

  local run_output
  run_output="$(
    PATH="$shim_dir:$PATH" \
    FJCLOUD_ENV_FILE="$out_env" \
    FJCLOUD_METERING_ENV_FILE="$out_metering" \
    FJCLOUD_SKIP_METERING_ENV_GENERATION="1" \
    bash "$TARGET_SCRIPT" staging 2>&1
  )"

  if [[ ! -f "$out_env" ]]; then
    fail "generate_ssm_env.sh did not write env output file. Output: $run_output"
    rm -rf "$tmpdir"
    return
  fi

  assert_contains_line "$out_env" "STRIPE_SECRET_KEY=sk_test_123"
  assert_contains_line "$out_env" "STRIPE_PUBLISHABLE_KEY=pk_test_123"
  assert_contains_line "$out_env" "STRIPE_WEBHOOK_SECRET=whsec_123"
  assert_contains_line "$out_env" "STRIPE_SUCCESS_URL=https://example.com/success"
  assert_contains_line "$out_env" "STRIPE_CANCEL_URL=https://example.com/cancel"

  assert_not_contains_prefix "$out_env" "STRIPE_PRICE_STARTER="
  assert_not_contains_prefix "$out_env" "STRIPE_PRICE_PRO="
  assert_not_contains_prefix "$out_env" "STRIPE_PRICE_ENTERPRISE="

  rm -rf "$tmpdir"
}

main() {
  echo "=== generate_ssm_env_test ==="
  if (( BASH_VERSINFO[0] < 4 )); then
    echo "SKIPPED: generate_ssm_env.sh requires bash >=4 (associative arrays); current bash is ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"
    exit 100
  fi
  test_omits_legacy_stripe_price_exports
  echo
  echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
  if [[ "$FAIL_COUNT" -ne 0 ]]; then
    exit 1
  fi
}

main "$@"
