#!/usr/bin/env bash
# Red/green contract test for customer_loop_admin_cleanup_live_contract.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONTRACT_SCRIPT="$REPO_ROOT/scripts/canary/contracts/customer_loop_admin_cleanup_live_contract.sh"
ZERO_UUID="00000000-0000-0000-0000-000000000000"
ADMIN_KEY_PARAM="/fjcloud/prod/admin_key"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$msg"
  else
    fail "$msg (missing: $needle)"
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    fail "$msg (found unexpected: $needle)"
  else
    pass "$msg"
  fi
}

run_probe_with_stubs() {
  local sts_mode="$1"
  local ssm_mode="$2"
  local http_status="$3"
  local admin_key_value="$4"
  local tmp_dir bin_dir stdout_file stderr_file output

  tmp_dir="$(mktemp -d -t admin_cleanup_live_contract_test_XXXXXX)"
  bin_dir="$tmp_dir/bin"
  mkdir -p "$bin_dir"
  stdout_file="$tmp_dir/stdout"
  stderr_file="$tmp_dir/stderr"
  AWS_CALLS_LOG="$tmp_dir/aws.calls"
  CURL_CALLS_LOG="$tmp_dir/curl.calls"
  : > "$AWS_CALLS_LOG"
  : > "$CURL_CALLS_LOG"

  cat > "$bin_dir/aws" <<'EOF_AWS'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${AWS_CALLS_LOG:?}"

if [[ "${1:-}" == "sts" && "${2:-}" == "get-caller-identity" ]]; then
  if [[ "${AWS_STS_MODE:-ok}" == "fail" ]]; then
    echo "Unable to locate credentials" >&2
    exit 255
  fi
  echo '{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/stub","UserId":"AIDASTUB"}'
  exit 0
fi

if [[ "${1:-}" == "ssm" && "${2:-}" == "get-parameter" ]]; then
  if [[ "${AWS_SSM_MODE:-ok}" == "fail" ]]; then
    echo "AccessDeniedException" >&2
    exit 254
  fi
  printf '%s\n' "${AWS_SSM_VALUE:-resolved-live-admin-key}"
  exit 0
fi

echo "unexpected aws invocation: $*" >&2
exit 99
EOF_AWS

  cat > "$bin_dir/curl" <<'EOF_CURL'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${CURL_CALLS_LOG:?}"
printf 'HTTP/1.1 %s synthetic\r\nContent-Length: 0\r\n\r\n' "${CURL_HTTP_STATUS:-204}"
EOF_CURL

  chmod +x "$bin_dir/aws" "$bin_dir/curl"

  RUN_STATUS=0
  RUN_STDOUT=""
  RUN_STDERR=""
  set +e
  PATH="$bin_dir:$PATH" \
    AWS_STS_MODE="$sts_mode" \
    AWS_SSM_MODE="$ssm_mode" \
    AWS_SSM_VALUE="$admin_key_value" \
    CURL_HTTP_STATUS="$http_status" \
    AWS_CALLS_LOG="$AWS_CALLS_LOG" \
    CURL_CALLS_LOG="$CURL_CALLS_LOG" \
    EVDIR="$tmp_dir/artifacts" \
    bash "$CONTRACT_SCRIPT" >"$stdout_file" 2>"$stderr_file"
  RUN_STATUS=$?
  set -e

  RUN_STDOUT="$(cat "$stdout_file")"
  RUN_STDERR="$(cat "$stderr_file")"
  output="${RUN_STDOUT}"$'\n'"${RUN_STDERR}"
  RUN_OUTPUT="$output"
  RUN_AWS_CALLS="$(cat "$AWS_CALLS_LOG")"
  RUN_CURL_CALLS="$(cat "$CURL_CALLS_LOG")"

  rm -rf "$tmp_dir"
}

test_contract_script_exists_and_executable() {
  if [[ -f "$CONTRACT_SCRIPT" ]]; then
    pass "customer_loop_admin_cleanup_live_contract.sh exists"
  else
    fail "customer_loop_admin_cleanup_live_contract.sh is missing"
    return
  fi

  if [[ -x "$CONTRACT_SCRIPT" ]]; then
    pass "customer_loop_admin_cleanup_live_contract.sh is executable"
  else
    fail "customer_loop_admin_cleanup_live_contract.sh must be executable"
  fi
}

test_live_contract_passes_on_204() {
  local expected_key="resolved-live-admin-key"
  run_probe_with_stubs "ok" "ok" "204" "$expected_key"

  if [[ "$RUN_STATUS" -eq 0 ]]; then
    pass "probe exits 0 on HTTP 204"
  else
    fail "probe should exit 0 on HTTP 204 (status=$RUN_STATUS output=$RUN_OUTPUT)"
  fi

  assert_contains "$RUN_AWS_CALLS" "sts get-caller-identity" \
    "probe preflights aws sts get-caller-identity"
  assert_contains "$RUN_AWS_CALLS" "ssm get-parameter --name $ADMIN_KEY_PARAM" \
    "probe resolves $ADMIN_KEY_PARAM from SSM"
  assert_contains "$RUN_CURL_CALLS" "-X DELETE https://api.flapjack.foo/admin/tenants/$ZERO_UUID" \
    "probe calls DELETE /admin/tenants/$ZERO_UUID"
  assert_contains "$RUN_CURL_CALLS" "x-admin-key: $expected_key" \
    "probe sends resolved admin key via x-admin-key header"
  assert_contains "$RUN_OUTPUT" "PASS:" \
    "probe reports PASS on HTTP 204"
  assert_not_contains "$RUN_OUTPUT" "$expected_key" \
    "probe output does not leak resolved admin key value"
}

test_live_contract_passes_on_404() {
  run_probe_with_stubs "ok" "ok" "404" "resolved-live-admin-key"

  if [[ "$RUN_STATUS" -eq 0 ]]; then
    pass "probe exits 0 on HTTP 404"
  else
    fail "probe should exit 0 on HTTP 404 (status=$RUN_STATUS output=$RUN_OUTPUT)"
  fi

  assert_contains "$RUN_OUTPUT" "PASS:" \
    "probe reports PASS on HTTP 404"
}

test_live_contract_fails_on_401() {
  run_probe_with_stubs "ok" "ok" "401" "resolved-live-admin-key"

  if [[ "$RUN_STATUS" -ne 0 ]]; then
    pass "probe exits non-zero on HTTP 401"
  else
    fail "probe should exit non-zero on HTTP 401"
  fi

  assert_contains "$RUN_OUTPUT" "FAIL:" \
    "probe reports FAIL on HTTP 401"
}

test_live_contract_skips_when_aws_auth_unavailable() {
  run_probe_with_stubs "fail" "ok" "204" "resolved-live-admin-key"

  if [[ "$RUN_STATUS" -eq 0 ]]; then
    pass "probe exits 0 with SKIP when aws auth is unavailable"
  else
    fail "probe should exit 0 with SKIP on missing aws auth (status=$RUN_STATUS output=$RUN_OUTPUT)"
  fi

  assert_contains "$RUN_OUTPUT" "SKIP:" \
    "probe prints SKIP prefix when aws auth is unavailable"
  assert_contains "$RUN_OUTPUT" "aws sts get-caller-identity" \
    "probe SKIP message names aws sts preflight remediation"
  if [[ -z "$RUN_CURL_CALLS" ]]; then
    pass "probe does not call curl when aws auth preflight fails"
  else
    fail "probe should not call curl when aws auth preflight fails (calls=$RUN_CURL_CALLS)"
  fi
}

test_live_contract_skips_when_ssm_resolution_unavailable() {
  run_probe_with_stubs "ok" "fail" "204" "resolved-live-admin-key"

  if [[ "$RUN_STATUS" -eq 0 ]]; then
    pass "probe exits 0 with SKIP when SSM lookup is unavailable"
  else
    fail "probe should exit 0 with SKIP when SSM lookup fails (status=$RUN_STATUS output=$RUN_OUTPUT)"
  fi

  assert_contains "$RUN_OUTPUT" "SKIP:" \
    "probe prints SKIP prefix when SSM lookup is unavailable"
  assert_contains "$RUN_OUTPUT" "$ADMIN_KEY_PARAM" \
    "probe SKIP message names missing SSM parameter path"
  if [[ -z "$RUN_CURL_CALLS" ]]; then
    pass "probe does not call curl when SSM lookup fails"
  else
    fail "probe should not call curl when SSM lookup fails (calls=$RUN_CURL_CALLS)"
  fi
}

main() {
  echo "=== customer_loop_admin_cleanup_live_contract_test ==="
  test_contract_script_exists_and_executable
  test_live_contract_passes_on_204
  test_live_contract_passes_on_404
  test_live_contract_fails_on_401
  test_live_contract_skips_when_aws_auth_unavailable
  test_live_contract_skips_when_ssm_resolution_unavailable
  echo
  echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
  if [[ "$FAIL_COUNT" -ne 0 ]]; then
    exit 1
  fi
}

main "$@"
