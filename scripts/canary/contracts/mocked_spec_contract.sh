#!/usr/bin/env bash
# Mocked-spec drift contract for chromium:mocked Playwright payload owners.
#
# Scope:
#   - Parse shape-map keys from inline route.fulfill(...) payloads in
#     web/tests/e2e-ui/mocked/auth_trust_states.spec.ts.
#   - Assert live wire payload keys for the two deterministic auth cases:
#       1) forgot-password resend success
#       2) reset-password invalid token
#   - Assert source-side payload fields for the two un-triggerable auth cases
#     (cooldown 429 + delivery_failure 503) directly in forgot-password server
#     source.
#   - Assert live billing page-load wire still exposes the BillingPageData
#     top-level keys upgradeStatus and paymentMethods.
#   - Assert +page.server.ts::load source still owns the nested fixture-rides-on-this
#     identifiers has_default_payment_method, upgrade_ready, paymentMethods,
#     and upgradeStatus.
#   - Assert UpgradeTestFixtureState fields/statuses still have matching backing
#     usage in UpgradeButton.svelte.
#
# IMPORTANT: This intentionally parses TypeScript/Svelte source using bash + a
# narrow Python helper to avoid introducing a second manifest/fixture owner.
# The coupling is explicit so reviewers can validate it.

set -euo pipefail

env_arg="${1:-staging}"
[[ "$env_arg" == "staging" ]] || { echo "usage: $0 [staging]" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PARSER="$REPO_ROOT/scripts/lib/mocked_spec_contract_parser.py"

AUTH_SPEC_PATH="${MOCKED_SPEC_CONTRACT_AUTH_SPEC_PATH:-$REPO_ROOT/web/tests/e2e-ui/mocked/auth_trust_states.spec.ts}"
FORGOT_ROUTE_PATH="${MOCKED_SPEC_CONTRACT_FORGOT_ROUTE_PATH:-$REPO_ROOT/web/src/routes/forgot-password/+page.server.ts}"
RESET_ROUTE_PATH="${MOCKED_SPEC_CONTRACT_RESET_ROUTE_PATH:-$REPO_ROOT/web/src/routes/reset-password/[token]/+page.server.ts}"
UPGRADE_FIXTURE_PATH="${MOCKED_SPEC_CONTRACT_UPGRADE_FIXTURE_PATH:-$REPO_ROOT/web/tests/fixtures/upgrade_fixture.ts}"
UPGRADE_BUTTON_PATH="${MOCKED_SPEC_CONTRACT_UPGRADE_BUTTON_PATH:-$REPO_ROOT/web/src/routes/dashboard/billing/UpgradeButton.svelte}"
BILLING_LOAD_PATH="${MOCKED_SPEC_CONTRACT_BILLING_LOAD_PATH:-$REPO_ROOT/web/src/routes/dashboard/billing/+page.server.ts}"

FORGOT_RESPONSE_FILE="${MOCKED_SPEC_CONTRACT_FORGOT_RESEND_RESPONSE_FILE:-}"
RESET_RESPONSE_FILE="${MOCKED_SPEC_CONTRACT_RESET_INVALID_RESPONSE_FILE:-}"
BILLING_RESPONSE_FILE="${MOCKED_SPEC_CONTRACT_BILLING_LOAD_RESPONSE_FILE:-}"

api_origin="https://api.staging.flapjack.foo"
web_origin="https://cloud.staging.flapjack.foo"

fail=0

say_fail() {
  echo "FAIL: $1"
  fail=1
}

join_csv() {
  awk 'NF{printf("%s%s", (NR==1?",":""), $0)} END{print ""}' | sed 's/^,//'
}

to_sorted_lines() {
  printf '%s\n' "$1" | awk 'NF' | sort -u
}

assert_subset() {
  local context="$1" expected_lines="$2" actual_lines="$3"
  local missing
  missing="$(comm -23 <(to_sorted_lines "$expected_lines") <(to_sorted_lines "$actual_lines") || true)"
  if [[ -n "$missing" ]]; then
    say_fail "$context missing keys: $(printf '%s\n' "$missing" | join_csv)"
  else
    echo "PASS: $context contains expected keys"
  fi
}

assert_value_equals() {
  local context="$1" actual="$2" expected="$3"
  if [[ "$actual" != "$expected" ]]; then
    say_fail "$context expected '$expected' but got '$actual'"
  else
    echo "PASS: $context value is '$expected'"
  fi
}

read_or_fetch_forgot_resend() {
  if [[ -n "$FORGOT_RESPONSE_FILE" ]]; then
    cat "$FORGOT_RESPONSE_FILE"
    return
  fi
  curl -sS --max-time 20 \
    -X POST "${web_origin}/forgot-password" \
    -H 'Accept: application/json' \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -H "Origin: ${web_origin}" \
    -H "Referer: ${web_origin}/forgot-password" \
    -H 'x-sveltekit-action: true' \
    --data 'intent=resend&email=trust-state@example.com' || true
}

read_or_fetch_reset_invalid() {
  if [[ -n "$RESET_RESPONSE_FILE" ]]; then
    cat "$RESET_RESPONSE_FILE"
    return
  fi
  curl -sS --max-time 20 \
    -X POST "${web_origin}/reset-password/browser-invalid-reset-token" \
    -H 'Accept: application/json' \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -H "Origin: ${web_origin}" \
    -H "Referer: ${web_origin}/reset-password/browser-invalid-reset-token" \
    -H 'x-sveltekit-action: true' \
    --data 'password=ValidPassword123!&confirm_password=ValidPassword123!' || true
}

read_or_fetch_billing_load() {
  if [[ -n "$BILLING_RESPONSE_FILE" ]]; then
    cat "$BILLING_RESPONSE_FILE"
    return
  fi

  # Mint a throwaway staging auth token (same pattern as
  # web_server_load_api_url_contract.sh). The wire-side check below only asserts
  # the page-load wire succeeded and returned the BillingPageData top-level
  # keys; the nested fixture-rides-on-this keys are validated source-side
  # against +page.server.ts::load below.
  local seed probe_email probe_password register_body register_response token
  seed="$(date -u +%s)-$RANDOM"
  probe_email="probe-mocked-contract-${seed}@e2e.griddle.test"
  probe_password="ContractProbe123!"
  register_body="$(printf '{"name":"mocked contract %s","email":"%s","password":"%s"}' "$seed" "$probe_email" "$probe_password")"
  register_response="$(curl -sS --max-time 20 -H 'Content-Type: application/json' -d "$register_body" "${api_origin}/auth/register" || true)"
  token="$(printf '%s' "$register_response" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("token", ""))' 2>/dev/null || true)"

  if [[ -z "$token" ]]; then
    say_fail "billing auth probe could not mint staging auth token"
    echo '{}'
    return
  fi

  curl -sS --max-time 30 -b "auth_token=${token}" "${web_origin}/dashboard/billing/__data.json" || true
}

write_temp_json() {
  local raw="$1" tmp
  tmp="$(mktemp)"
  printf '%s' "$raw" > "$tmp"
  echo "$tmp"
}

expected_auth_keys() {
  local index="$1"
  python3 "$PARSER" mock-shape-keys --spec "$AUTH_SPEC_PATH" --index "$index"
}

actual_auth_keys_from_response_file() {
  local response_file="$1"
  python3 "$PARSER" action-shape-keys --response "$response_file"
}

actual_recovery_value_from_response_file() {
  local response_file="$1"
  python3 "$PARSER" action-recovery-value --response "$response_file"
}

check_source_tokens() {
  local label="$1" source_path="$2"
  shift 2
  local missing
  if missing="$(python3 "$PARSER" missing-tokens --path "$source_path" "$@" 2>/dev/null)"; then
    echo "PASS: $label source tokens present"
  else
    say_fail "$label source drift missing tokens: $(printf '%s\n' "$missing" | join_csv)"
  fi
}

source_fail_keys_for_function() {
  local source_path="$1" function_name="$2"
  python3 "$PARSER" fail-function-keys --path "$source_path" --function "$function_name"
}

check_source_fail_keys_subset() {
  local context="$1" source_path="$2" function_name="$3" expected_lines="$4"
  local actual_lines
  actual_lines="$(source_fail_keys_for_function "$source_path" "$function_name" 2>/dev/null || true)"
  if [[ -z "$actual_lines" ]]; then
    say_fail "$context source function $function_name could not be parsed"
    return
  fi
  assert_subset "$context" "$expected_lines" "$actual_lines"
}

check_fixture_field_backing() {
  local fixture_fields backing_fields missing
  fixture_fields="$(python3 "$PARSER" fixture-fields --fixture "$UPGRADE_FIXTURE_PATH")"
  backing_fields="$(python3 "$PARSER" fixture-field-backings --button "$UPGRADE_BUTTON_PATH")"
  missing="$(comm -23 <(to_sorted_lines "$fixture_fields") <(to_sorted_lines "$backing_fields") || true)"
  if [[ -n "$missing" ]]; then
    say_fail "fixture forward drift: UpgradeTestFixtureState fields missing in UpgradeButton backing: $(printf '%s\n' "$missing" | join_csv)"
  else
    echo "PASS: UpgradeTestFixtureState fields have UpgradeButton backing"
  fi
}

check_fixture_status_backing() {
  local fixture_statuses button_statuses missing
  fixture_statuses="$(python3 "$PARSER" fixture-statuses --fixture "$UPGRADE_FIXTURE_PATH")"
  button_statuses="$(python3 "$PARSER" button-statuses --button "$UPGRADE_BUTTON_PATH")"
  missing="$(comm -23 <(to_sorted_lines "$fixture_statuses") <(to_sorted_lines "$button_statuses") || true)"
  if [[ -n "$missing" ]]; then
    say_fail "fixture status drift: upgrade_outcome statuses missing from UpgradeButton logic: $(printf '%s\n' "$missing" | join_csv)"
  else
    echo "PASS: upgrade_outcome statuses are represented in UpgradeButton logic"
  fi
}

# Read wire responses first and persist them so parse errors are surfaced clearly.
forgot_raw="$(read_or_fetch_forgot_resend)"
reset_raw="$(read_or_fetch_reset_invalid)"

forgot_tmp="$(write_temp_json "$forgot_raw")"
reset_tmp="$(write_temp_json "$reset_raw")"
billing_tmp="$(mktemp)"
read_or_fetch_billing_load > "$billing_tmp"
billing_raw="$(cat "$billing_tmp")"
trap 'rm -f "$forgot_tmp" "$reset_tmp" "$billing_tmp"' EXIT

forgot_expected_keys="$(expected_auth_keys 0 2>/dev/null || true)"
if [[ -z "$forgot_expected_keys" ]]; then
  say_fail "could not extract mocked forgot-password resend shape-map keys"
else
  forgot_actual_keys="$(actual_auth_keys_from_response_file "$forgot_tmp" 2>/dev/null || true)"
  if [[ -z "$forgot_actual_keys" ]]; then
    say_fail "wire forgot-password/resend response was not parseable as action JSON"
  else
    assert_subset "wire forgot-password/resend" "$forgot_expected_keys" "$forgot_actual_keys"
  fi
fi

reset_expected_keys="$(expected_auth_keys 3 2>/dev/null || true)"
if [[ -z "$reset_expected_keys" ]]; then
  say_fail "could not extract mocked reset-password invalid-token shape-map keys"
else
  reset_actual_keys="$(actual_auth_keys_from_response_file "$reset_tmp" 2>/dev/null || true)"
  if [[ -z "$reset_actual_keys" ]]; then
    say_fail "wire reset-password invalid-token response was not parseable as action JSON"
  else
    assert_subset "wire reset-password invalid-token" "$reset_expected_keys" "$reset_actual_keys"
    recovery_value="$(actual_recovery_value_from_response_file "$reset_tmp" 2>/dev/null || true)"
    if [[ -z "$recovery_value" ]]; then
      say_fail "wire reset-password invalid-token response missing recoveryAction value"
    else
      assert_value_equals "wire reset-password invalid-token recoveryAction" "$recovery_value" "invalid_or_expired_token"
    fi
  fi
fi

# Source-side checks for un-triggerable forgot-password cooldown + delivery_failure payloads.
cooldown_expected_keys="$(expected_auth_keys 1 2>/dev/null || true)"
delivery_expected_keys="$(expected_auth_keys 2 2>/dev/null || true)"
if [[ -z "$cooldown_expected_keys" || -z "$delivery_expected_keys" ]]; then
  say_fail "could not extract mocked source-side keys for un-triggerable auth cases"
else
  check_source_fail_keys_subset "source forgot-password cooldown fail(...)" "$FORGOT_ROUTE_PATH" "resendCooldown" "$cooldown_expected_keys"
  check_source_fail_keys_subset "source forgot-password delivery_failure fail(...)" "$FORGOT_ROUTE_PATH" "resendDeliveryFailure" "$delivery_expected_keys"
fi

# Reset source ownership sanity: recovery action wiring should remain explicitly named.
check_source_tokens "source reset-password invalid-token fail(...)" "$RESET_ROUTE_PATH" \
  --token recoveryAction --token INVALID_TOKEN_RECOVERY_ACTION

# Billing page-load contract (fixture-rides-on-this seam).
#
# The fixture (UpgradeTestFixtureState) is a client-side window-global override
# of UpgradeButton.svelte props that the real billing page-load supplies; there
# is no separate wire shape to diff. The drift surface is therefore split:
#
#   wire-side:  the live page-load actually exposes the BillingPageData
#               top-level keys paymentMethods and upgradeStatus. A throwaway
#               probe customer with no Stripe linkage returns upgradeStatus
#               as null but the key MUST still appear in the response.
#   source-side: +page.server.ts::load source still owns the nested
#                identifier names has_default_payment_method, upgrade_ready,
#                paymentMethods, and upgradeStatus. Any rename or removal of
#                these keys in the source breaks the fixture seam.
#
# The previous /account/upgrade-status fallback was removed because it could
# mask page-load drift (it asserted against a different API endpoint than the
# one the fixture rides on).
if [[ -z "$billing_raw" ]]; then
  say_fail "billing page-load response was empty"
else
  billing_wire_requirements=(
    '"upgradeStatus"'
    '"paymentMethods"'
  )
  missing_billing_wire=()
  for token in "${billing_wire_requirements[@]}"; do
    if [[ "$billing_raw" != *$token* ]]; then
      missing_billing_wire+=("$token")
    fi
  done
  if [[ "${#missing_billing_wire[@]}" -gt 0 ]]; then
    say_fail "wire billing page-load drift missing top-level keys: ${missing_billing_wire[*]}"
  else
    echo "PASS: wire billing page-load contains upgradeStatus and paymentMethods top-level keys"
  fi
fi

check_source_tokens "source billing +page.server.ts::load nested identifiers" "$BILLING_LOAD_PATH" \
  --token paymentMethods \
  --token upgradeStatus \
  --token has_default_payment_method \
  --token upgrade_ready

check_fixture_field_backing
check_fixture_status_backing

exit "$fail"
