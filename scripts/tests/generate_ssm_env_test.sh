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

assert_file_missing() {
  local file="$1"
  if [[ -e "$file" ]]; then
    fail "expected file to be absent: $file"
  else
    pass "file is absent as expected: $file"
  fi
}

assert_output_contains() {
  local output="$1"
  local expected="$2"
  if grep -Fq "$expected" <<<"$output"; then
    pass "output contains $expected"
  else
    fail "output missing text: $expected"
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
    "${BASH:-bash}" "$TARGET_SCRIPT" staging 2>&1
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

test_maps_runtime_rate_limit_exports() {
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
  {"Name":"/fjcloud/staging/tenant_rate_limit_rpm","Value":"5000"},
  {"Name":"/fjcloud/staging/default_max_query_rps","Value":"100"},
  {"Name":"/fjcloud/staging/default_max_write_rps","Value":"100"}
]}
JSON_EOF
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
    "${BASH:-bash}" "$TARGET_SCRIPT" staging 2>&1
  )"

  if [[ ! -f "$out_env" ]]; then
    fail "generate_ssm_env.sh did not write env output file. Output: $run_output"
    rm -rf "$tmpdir"
    return
  fi

  assert_contains_line "$out_env" "TENANT_RATE_LIMIT_RPM=5000"
  assert_contains_line "$out_env" "DEFAULT_MAX_QUERY_RPS=100"
  assert_contains_line "$out_env" "DEFAULT_MAX_WRITE_RPS=100"

  rm -rf "$tmpdir"
}

test_maps_algolia_migration_availability_export() {
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
  {"Name":"/fjcloud/staging/algolia_migration_enabled","Value":"true"}
]}
JSON_EOF
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
    "${BASH:-bash}" "$TARGET_SCRIPT" staging 2>&1
  )"

  if [[ ! -f "$out_env" ]]; then
    fail "generate_ssm_env.sh did not write env output file. Output: $run_output"
    rm -rf "$tmpdir"
    return
  fi

  assert_contains_line "$out_env" "FJCLOUD_ALGOLIA_MIGRATION_ENABLED=true"

  rm -rf "$tmpdir"
}

test_skips_metering_env_without_customer_tags() {
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
  {"Name":"/fjcloud/staging/database_url","Value":"postgres://db"},
  {"Name":"/fjcloud/staging/dns_domain","Value":"flapjack.foo"}
]}
JSON_EOF
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
  printf 'stale=true\n' > "$out_metering"

  local run_output
  run_output="$(
    PATH="$shim_dir:$PATH" \
    FJCLOUD_ENV_FILE="$out_env" \
    FJCLOUD_METERING_ENV_FILE="$out_metering" \
    "${BASH:-bash}" "$TARGET_SCRIPT" staging 2>&1
  )"

  if [[ ! -f "$out_env" ]]; then
    fail "generate_ssm_env.sh did not write env output file for control-plane path. Output: $run_output"
    rm -rf "$tmpdir"
    return
  fi

  assert_contains_line "$out_env" "DATABASE_URL=postgres://db"
  assert_contains_line "$out_env" "DNS_DOMAIN=flapjack.foo"
  assert_file_missing "$out_metering"
  if grep -Fq "skipping metering-env generation (control-plane instance)" <<<"$run_output"; then
    pass "control-plane path logs metering-env skip"
  else
    fail "control-plane path did not log metering-env skip. Output: $run_output"
  fi

  rm -rf "$tmpdir"
}

test_writes_metering_env_for_customer_vm() {
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
  {"Name":"/fjcloud/staging/database_url","Value":"postgres://db"},
  {"Name":"/fjcloud/staging/dns_domain","Value":"flapjack.foo"},
  {"Name":"/fjcloud/staging/internal_auth_token","Value":"internal_456"},
  {"Name":"/fjcloud/staging/slack_webhook_url","Value":"https://hooks.slack.test/abc"},
  {"Name":"/fjcloud/staging/discord_webhook_url","Value":"https://discord.test/abc"}
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
  echo "us-west-2"
  exit 0
fi
if [[ "$*" == *"meta-data/tags/instance/customer_id"* ]]; then
  echo "tenant_123"
  exit 0
fi
if [[ "$*" == *"meta-data/tags/instance/node_id"* ]]; then
  echo "node_abc"
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
    "${BASH:-bash}" "$TARGET_SCRIPT" staging 2>&1
  )"

  if [[ ! -f "$out_metering" ]]; then
    fail "generate_ssm_env.sh did not write metering env file for customer-vm path. Output: $run_output"
    rm -rf "$tmpdir"
    return
  fi

  assert_contains_line "$out_metering" "FLAPJACK_URL=http://node_abc:7700"
  assert_contains_line "$out_metering" "FLAPJACK_API_KEY=node_api_key"
  assert_contains_line "$out_metering" "INTERNAL_KEY=internal_456"
  assert_contains_line "$out_metering" "CUSTOMER_ID=tenant_123"
  assert_contains_line "$out_metering" "NODE_ID=node_abc"
  assert_contains_line "$out_metering" "REGION=us-west-2"
  assert_contains_line "$out_metering" "TENANT_MAP_URL=https://api.flapjack.foo/internal/tenant-map"
  assert_contains_line "$out_metering" "COLD_STORAGE_USAGE_URL=https://api.flapjack.foo/internal/cold-storage-usage"
  assert_contains_line "$out_metering" "SLACK_WEBHOOK_URL=https://hooks.slack.test/abc"
  assert_contains_line "$out_metering" "DISCORD_WEBHOOK_URL=https://discord.test/abc"

  rm -rf "$tmpdir"
}

test_rejects_multiline_envfile_values() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  local shim_dir="$tmpdir/shims"
  local out_env="$tmpdir/env"
  mkdir -p "$shim_dir"

  cat > "$shim_dir/aws" <<'AWS_EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ge 2 && "$1" == "ssm" && "$2" == "get-parameters-by-path" ]]; then
  python3 - <<'PY'
import json

print(json.dumps({
    "Parameters": [
        {"Name": "/fjcloud/staging/database_url", "Value": "postgres://db"},
        {"Name": "/fjcloud/staging/jwt_secret", "Value": "good-line\nINJECTED=1"},
    ]
}))
PY
  exit 0
fi
echo "unexpected aws invocation: $*" >&2
exit 1
AWS_EOF

  chmod +x "$shim_dir/aws"

  local run_output
  local status=0
  run_output="$(
    PATH="$shim_dir:$PATH" \
    FJCLOUD_ENV_FILE="$out_env" \
    FJCLOUD_SKIP_METERING_ENV_GENERATION="1" \
    "${BASH:-bash}" "$TARGET_SCRIPT" staging 2>&1
  )" || status=$?

  if [[ "$status" -eq 0 ]]; then
    fail "generate_ssm_env.sh accepted a multiline SSM value"
    rm -rf "$tmpdir"
    return
  fi

  assert_output_contains "$run_output" "ERROR: JWT_SECRET contains newline bytes"
  assert_file_missing "$out_env"
  rm -rf "$tmpdir"
}

main() {
  echo "=== generate_ssm_env_test ==="
  test_omits_legacy_stripe_price_exports
  test_maps_runtime_rate_limit_exports
  test_maps_algolia_migration_availability_export
  test_skips_metering_env_without_customer_tags
  test_writes_metering_env_for_customer_vm
  test_rejects_multiline_envfile_values
  echo
  echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
  if [[ "$FAIL_COUNT" -ne 0 ]]; then
    exit 1
  fi
}

main "$@"
