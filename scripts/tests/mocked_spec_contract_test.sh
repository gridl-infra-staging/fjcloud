#!/usr/bin/env bash
# Stage 6 red/green test for mocked_spec_contract.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONTRACT_SCRIPT="$REPO_ROOT/scripts/canary/contracts/mocked_spec_contract.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

require_contract_script() {
  if [[ ! -f "$CONTRACT_SCRIPT" ]]; then
    fail "mocked_spec_contract.sh is missing"
    return 1
  fi
  if [[ ! -x "$CONTRACT_SCRIPT" ]]; then
    fail "mocked_spec_contract.sh must be executable"
    return 1
  fi
  pass "mocked_spec_contract.sh exists and is executable"
}

write_happy_auth_response_files() {
  local dir="$1"
  cat > "$dir/forgot_resend.json" <<'JSON'
{"type":"success","status":200,"data":"[{\"sent\":1,\"email\":2,\"resendStatus\":3},true,\"trust-state@example.com\",\"resent\"]"}
JSON
  cat > "$dir/reset_invalid.json" <<'JSON'
{"type":"failure","status":400,"data":"[{\"errors\":1,\"recoveryAction\":3},{\"form\":2},\"invalid or expired reset token\",\"invalid_or_expired_token\"]"}
JSON
}

write_happy_billing_response_file() {
  local dir="$1"
  cat > "$dir/billing_load.json" <<'JSON'
{"type":"data","nodes":[{"data":[{"upgradeStatus":1,"paymentMethods":2},{"has_default_payment_method":3,"upgrade_ready":4},[],true,true]}]}
JSON
}

copy_source_fixtures() {
  local dir="$1"
  cp "$REPO_ROOT/web/tests/e2e-ui/mocked/auth_trust_states.spec.ts" "$dir/auth_trust_states.spec.ts"
  cp "$REPO_ROOT/web/src/routes/forgot-password/+page.server.ts" "$dir/forgot_page.server.ts"
  cp "$REPO_ROOT/web/src/routes/reset-password/[token]/+page.server.ts" "$dir/reset_page.server.ts"
  cp "$REPO_ROOT/web/tests/fixtures/upgrade_fixture.ts" "$dir/upgrade_fixture.ts"
  cp "$REPO_ROOT/web/src/routes/console/billing/UpgradeButton.svelte" "$dir/UpgradeButton.svelte"
  cp "$REPO_ROOT/web/src/routes/console/billing/+page.server.ts" "$dir/billing_page.server.ts"
}

run_contract_with_fixtures() {
  local dir="$1"
  MOCKED_SPEC_CONTRACT_AUTH_SPEC_PATH="$dir/auth_trust_states.spec.ts" \
  MOCKED_SPEC_CONTRACT_FORGOT_ROUTE_PATH="$dir/forgot_page.server.ts" \
  MOCKED_SPEC_CONTRACT_RESET_ROUTE_PATH="$dir/reset_page.server.ts" \
  MOCKED_SPEC_CONTRACT_UPGRADE_FIXTURE_PATH="$dir/upgrade_fixture.ts" \
  MOCKED_SPEC_CONTRACT_UPGRADE_BUTTON_PATH="$dir/UpgradeButton.svelte" \
  MOCKED_SPEC_CONTRACT_BILLING_LOAD_PATH="$dir/billing_page.server.ts" \
  MOCKED_SPEC_CONTRACT_FORGOT_RESEND_RESPONSE_FILE="$dir/forgot_resend.json" \
  MOCKED_SPEC_CONTRACT_RESET_INVALID_RESPONSE_FILE="$dir/reset_invalid.json" \
  MOCKED_SPEC_CONTRACT_BILLING_LOAD_RESPONSE_FILE="$dir/billing_load.json" \
  bash "$CONTRACT_SCRIPT" staging
}

test_happy_path_passes() {
  local tmp_dir out status
  tmp_dir="$(mktemp -d -t mocked_spec_contract_test_XXXXXX)"
  copy_source_fixtures "$tmp_dir"
  write_happy_auth_response_files "$tmp_dir"
  write_happy_billing_response_file "$tmp_dir"

  status=0
  out="$(run_contract_with_fixtures "$tmp_dir" 2>&1)" || status=$?
  if [[ "$status" -ne 0 ]]; then
    fail "happy-path fixtures should pass mocked_spec_contract.sh. Output tail: $(echo "$out" | tail -20)"
    rm -rf "$tmp_dir"
    return
  fi
  pass "happy-path fixtures pass mocked_spec_contract.sh"
  rm -rf "$tmp_dir"
}

test_wire_side_drift_fails_for_missing_auth_shape_key() {
  local tmp_dir out status
  tmp_dir="$(mktemp -d -t mocked_spec_contract_test_XXXXXX)"
  copy_source_fixtures "$tmp_dir"
  write_happy_auth_response_files "$tmp_dir"
  write_happy_billing_response_file "$tmp_dir"

  # Remove resendStatus from the wire-side forgot-password action shape-map.
  cat > "$tmp_dir/forgot_resend.json" <<'JSON'
{"type":"success","status":200,"data":"[{\"sent\":1,\"email\":2},true,\"trust-state@example.com\",\"resent\"]"}
JSON

  status=0
  out="$(run_contract_with_fixtures "$tmp_dir" 2>&1)" || status=$?
  if [[ "$status" -eq 1 && "$out" == *"wire forgot-password/resend missing keys"* ]]; then
    pass "wire-side drift fails with forgotten auth shape-map key"
  else
    fail "wire-side drift should fail with auth shape-map key message. status=$status tail=$(echo "$out" | tail -20)"
  fi
  rm -rf "$tmp_dir"
}

test_source_side_drift_fails_for_missing_fail_payload_field() {
  local tmp_dir out status
  tmp_dir="$(mktemp -d -t mocked_spec_contract_test_XXXXXX)"
  copy_source_fixtures "$tmp_dir"
  write_happy_auth_response_files "$tmp_dir"
  write_happy_billing_response_file "$tmp_dir"

  # Delete retryAfterSeconds field from resendCooldown fail payload.
  sed -i '' 's/retryAfterSeconds//' "$tmp_dir/forgot_page.server.ts"

  status=0
  out="$(run_contract_with_fixtures "$tmp_dir" 2>&1)" || status=$?
  if [[ "$status" -eq 1 && "$out" == *"source forgot-password cooldown fail(...) missing keys"* ]]; then
    pass "source-side drift fails when fail(...) payload field disappears"
  else
    fail "source-side drift should fail with fail(...) payload message. status=$status tail=$(echo "$out" | tail -20)"
  fi
  rm -rf "$tmp_dir"
}

test_reset_recovery_action_drift_fails_for_wrong_value() {
  local tmp_dir out status
  tmp_dir="$(mktemp -d -t mocked_spec_contract_test_XXXXXX)"
  copy_source_fixtures "$tmp_dir"
  write_happy_auth_response_files "$tmp_dir"
  write_happy_billing_response_file "$tmp_dir"

  # Keep shape-map keys intact but drift the recoveryAction payload value.
  cat > "$tmp_dir/reset_invalid.json" <<'JSON'
{"type":"failure","status":400,"data":"[{\"errors\":1,\"recoveryAction\":3},{\"form\":2},\"invalid or expired reset token\",\"totally_different_value\"]"}
JSON

  status=0
  out="$(run_contract_with_fixtures "$tmp_dir" 2>&1)" || status=$?
  if [[ "$status" -eq 1 \
        && "$out" == *"wire reset-password invalid-token recoveryAction expected"* \
        && "$out" == *"invalid_or_expired_token"* ]]; then
    pass "reset recoveryAction drift fails when value no longer matches contract"
  else
    fail "reset recoveryAction drift should fail with value-mismatch message. status=$status tail=$(echo "$out" | tail -20)"
  fi
  rm -rf "$tmp_dir"
}

test_billing_wire_drift_fails_for_missing_top_level_key() {
  local tmp_dir out status
  tmp_dir="$(mktemp -d -t mocked_spec_contract_test_XXXXXX)"
  copy_source_fixtures "$tmp_dir"
  write_happy_auth_response_files "$tmp_dir"
  write_happy_billing_response_file "$tmp_dir"

  # Remove upgradeStatus top-level key from billing wire payload. The throwaway
  # probe customer in real staging returns upgradeStatus: null but the key MUST
  # still appear -- losing the key entirely means BillingPageData drifted.
  cat > "$tmp_dir/billing_load.json" <<'JSON'
{"type":"data","nodes":[{"data":[{"paymentMethods":1},[]]}]}
JSON

  status=0
  out="$(run_contract_with_fixtures "$tmp_dir" 2>&1)" || status=$?
  if [[ "$status" -eq 1 && "$out" == *"wire billing page-load drift missing top-level keys"* && "$out" == *'"upgradeStatus"'* ]]; then
    pass "billing wire drift fails when upgradeStatus top-level key disappears"
  else
    fail "billing wire drift should fail with upgradeStatus top-level message. status=$status tail=$(echo "$out" | tail -20)"
  fi
  rm -rf "$tmp_dir"
}

test_billing_source_drift_fails_for_missing_nested_identifier() {
  local tmp_dir out status
  tmp_dir="$(mktemp -d -t mocked_spec_contract_test_XXXXXX)"
  copy_source_fixtures "$tmp_dir"
  write_happy_auth_response_files "$tmp_dir"
  write_happy_billing_response_file "$tmp_dir"

  # Delete every occurrence of has_default_payment_method from the billing
  # +page.server.ts copy. The fixture-rides-on-this contract requires this
  # identifier to remain in the source; losing it means UpgradeButton.svelte's
  # fixture override can no longer map to the live page-load shape.
  sed -i '' 's/has_default_payment_method//g' "$tmp_dir/billing_page.server.ts"

  status=0
  out="$(run_contract_with_fixtures "$tmp_dir" 2>&1)" || status=$?
  if [[ "$status" -eq 1 \
        && "$out" == *"source billing +page.server.ts::load nested identifiers source drift missing tokens"* \
        && "$out" == *"has_default_payment_method"* ]]; then
    pass "billing source drift fails when +page.server.ts loses has_default_payment_method"
  else
    fail "billing source drift should fail with nested-identifier message. status=$status tail=$(echo "$out" | tail -20)"
  fi
  rm -rf "$tmp_dir"
}

test_fixture_status_drift_fails_without_button_status_support() {
  local tmp_dir out status
  tmp_dir="$(mktemp -d -t mocked_spec_contract_test_XXXXXX)"
  copy_source_fixtures "$tmp_dir"
  write_happy_auth_response_files "$tmp_dir"
  write_happy_billing_response_file "$tmp_dir"

  # Rename one fixture status literal so UpgradeButton no longer references it.
  sed -i '' "s/status: 'already_shared'/status: 'already_on_shared'/g" "$tmp_dir/upgrade_fixture.ts"

  status=0
  out="$(run_contract_with_fixtures "$tmp_dir" 2>&1)" || status=$?
  if [[ "$status" -eq 1 \
        && "$out" == *"fixture status drift"* \
        && "$out" == *"already_on_shared"* ]]; then
    pass "fixture status drift fails when fixture enum no longer matches UpgradeButton logic"
  else
    fail "fixture status drift should fail with missing status message. status=$status tail=$(echo "$out" | tail -20)"
  fi
  rm -rf "$tmp_dir"
}

test_fixture_forward_drift_fails_without_backing_field() {
  local tmp_dir out status
  tmp_dir="$(mktemp -d -t mocked_spec_contract_test_XXXXXX)"
  copy_source_fixtures "$tmp_dir"
  write_happy_auth_response_files "$tmp_dir"
  write_happy_billing_response_file "$tmp_dir"

  # Add a new fixture field without adding corresponding UpgradeButton backing usage.
  perl -0pi -e "s/has_payment_method: boolean;\n/has_payment_method: boolean;\n\tnew_forward_field: boolean;\n/" "$tmp_dir/upgrade_fixture.ts"

  status=0
  out="$(run_contract_with_fixtures "$tmp_dir" 2>&1)" || status=$?
  if [[ "$status" -eq 1 && "$out" == *"fixture forward drift"* && "$out" == *"new_forward_field"* ]]; then
    pass "forward drift fails when UpgradeTestFixtureState adds unbacked field"
  else
    fail "forward drift should fail with unbacked fixture field message. status=$status tail=$(echo "$out" | tail -20)"
  fi
  rm -rf "$tmp_dir"
}

main() {
  echo "=== mocked_spec_contract_test ==="
  require_contract_script || true
  test_happy_path_passes
  test_wire_side_drift_fails_for_missing_auth_shape_key
  test_source_side_drift_fails_for_missing_fail_payload_field
  test_reset_recovery_action_drift_fails_for_wrong_value
  test_billing_wire_drift_fails_for_missing_top_level_key
  test_billing_source_drift_fails_for_missing_nested_identifier
  test_fixture_status_drift_fails_without_button_status_support
  test_fixture_forward_drift_fails_without_backing_field
  echo
  echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
  if [[ "$FAIL_COUNT" -ne 0 ]]; then
    exit 1
  fi
}

main "$@"
