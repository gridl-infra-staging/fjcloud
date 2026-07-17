#!/usr/bin/env bash
# Regression test: web_form_login contract must match /dashboard -> /console route-owner move.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONTRACT_SCRIPT="$REPO_ROOT/scripts/canary/contracts/web_form_login_contract.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

assert_redirect_contract_targets_console() {
  if grep -Fq "\$location\" == \"/console\"" "$CONTRACT_SCRIPT"; then
    pass "assert_redirect_json_shape requires /console location"
  else
    fail "assert_redirect_json_shape must require /console location"
  fi

  if grep -Fq "good=\"{\\\"type\\\":\\\"redirect\\\",\\\"status\\\":303,\\\"location\\\":\\\"/console\\\"}\"" "$CONTRACT_SCRIPT"; then
    pass "self-test known-good redirect payload uses /console"
  else
    fail "self-test known-good redirect payload must use /console"
  fi

  if grep -Fq "redirected to /console" "$CONTRACT_SCRIPT"; then
    pass "probe success output documents /console redirect"
  else
    fail "probe success output must document /console redirect"
  fi

  if grep -Fq "\$location\" == \"/dashboard\"" "$CONTRACT_SCRIPT" || \
     grep -Fq "good=\"{\\\"type\\\":\\\"redirect\\\",\\\"status\\\":303,\\\"location\\\":\\\"/dashboard\\\"}\"" "$CONTRACT_SCRIPT" || \
     grep -Fq "redirected to /dashboard" "$CONTRACT_SCRIPT"; then
    fail "stale /dashboard redirect expectations remain in web_form_login contract"
  else
    pass "no stale /dashboard redirect expectations remain"
  fi
}

main() {
  echo "=== web_form_login_contract_test ==="
  if [[ ! -f "$CONTRACT_SCRIPT" ]]; then
    fail "web_form_login_contract.sh is missing"
  else
    assert_redirect_contract_targets_console
  fi

  echo
  echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
  if [[ "$FAIL_COUNT" -ne 0 ]]; then
    exit 1
  fi
}

main "$@"
