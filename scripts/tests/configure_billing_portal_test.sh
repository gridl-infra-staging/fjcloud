#!/usr/bin/env bash
# Tests for scripts/stripe/configure_billing_portal.sh and shared account resolver.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/tests/lib/assertions.sh"

PASS_COUNT=0
FAIL_COUNT=0

fail() {
    echo "FAIL: $*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

write_mock_curl_with_sequence() {
    local path="$1"
    cat > "$path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

header_file=""
body_file=""
write_format=""
auth=""
method="GET"
url=""
request_data=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        -D)
            header_file="$2"
            shift 2
            ;;
        -o)
            body_file="$2"
            shift 2
            ;;
        -w)
            write_format="$2"
            shift 2
            ;;
        -u)
            auth="$2"
            shift 2
            ;;
        -X)
            method="$2"
            shift 2
            ;;
        -d|--data-urlencode)
            request_data+=("$2")
            shift 2
            ;;
        -G|-s|-S|-sS)
            shift
            ;;
        *)
            if [[ "$1" == https://* ]]; then
                url="$1"
            fi
            shift
            ;;
    esac
done

if [ -n "${STRIPE_TEST_CALL_LOG:-}" ]; then
    python_args=("$STRIPE_TEST_CALL_LOG" "$method" "$url" "$auth")
    if [ "${#request_data[@]}" -gt 0 ]; then
        python_args+=("${request_data[@]}")
    fi
    python3 - "${python_args[@]}" <<'PY'
import json
import sys
from pathlib import Path

log_path = Path(sys.argv[1])
entry = {
    "method": sys.argv[2],
    "url": sys.argv[3],
    "auth": sys.argv[4],
    "data": sys.argv[5:],
}
with log_path.open("a", encoding="utf-8") as fh:
    fh.write(json.dumps(entry) + "\n")
PY
fi

if [ -z "${STRIPE_TEST_RESPONSE_FILE:-}" ]; then
    echo "missing STRIPE_TEST_RESPONSE_FILE" >&2
    exit 1
fi

python3 - "$STRIPE_TEST_RESPONSE_FILE" "$header_file" "$body_file" "$write_format" <<'PY'
import json
import sys
from pathlib import Path

response_file, header_file, body_file, write_format = sys.argv[1:5]
path = Path(response_file)
data = json.loads(path.read_text())
idx = int(data.get("index", 0))
responses = data["responses"]
if idx >= len(responses):
    raise SystemExit("mock response sequence exhausted")
response = responses[idx]
data["index"] = idx + 1
path.write_text(json.dumps(data))

headers = response.get("headers", {})
body = response.get("body", "")
status = str(response.get("status", "200"))

if header_file:
    with open(header_file, "w", encoding="utf-8") as fh:
        for key, value in headers.items():
            fh.write(f"{key}: {value}\r\n")

if body_file:
    with open(body_file, "w", encoding="utf-8") as fh:
        fh.write(body)

if write_format == "%{http_code}":
    sys.stdout.write(status)
else:
    sys.stdout.write(body)
PY
MOCK
    chmod +x "$path"
}

write_catalog_mock_curl() {
    local path="$1"
    cat > "$path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

auth=""
method="GET"
url=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        -u)
            auth="$2"
            shift 2
            ;;
        -X)
            method="$2"
            shift 2
            ;;
        -G|-s|-S|-sS)
            shift
            ;;
        -d|--data-urlencode)
            shift 2
            ;;
        *)
            if [[ "$1" == https://* ]]; then
                url="$1"
            fi
            shift
            ;;
    esac
done

if [ -n "${STRIPE_TEST_CALL_LOG:-}" ]; then
    echo "$auth|$method|$url" >> "$STRIPE_TEST_CALL_LOG"
fi

case "$url" in
    https://api.stripe.com/v1/account)
        printf '{"id":"acct_catalog_mock"}'
        ;;
    https://api.stripe.com/v1/products)
        if [ "$method" = "POST" ]; then
            printf '{"id":"prod_mock"}'
        else
            printf '{"data":[]}'
        fi
        ;;
    https://api.stripe.com/v1/prices)
        if [ "$method" = "POST" ]; then
            printf '{"id":"price_mock"}'
        else
            printf '{"data":[]}'
        fi
        ;;
    *)
        printf '{"id":"mock_default"}'
        ;;
esac
MOCK
    chmod +x "$path"
}

test_configure_billing_portal_resolves_suffixed_account_key() {
    local mock_dir response_file call_log output
    mock_dir="$(mktemp -d)"
    response_file="$mock_dir/responses.json"
    call_log="$mock_dir/calls.log"
    cat > "$response_file" <<'JSON'
{"index":0,"responses":[
  {"status":200,"body":"{\"id\":\"acct_live_mock\"}"},
  {"status":200,"body":"{\"data\":[{\"id\":\"bpc_existing\",\"is_default\":true,\"features\":{\"customer_update\":{\"enabled\":true},\"invoice_history\":{\"enabled\":false},\"payment_method_update\":{\"enabled\":true}},\"login_page\":{\"enabled\":true,\"url\":\"https://billing.flapjack.foo/login\"},\"default_return_url\":\"https://app.flapjack.foo/dashboard/billing\"}]}"},
  {"status":200,"body":"{\"id\":\"bpc_existing\",\"is_default\":true,\"features\":{\"customer_update\":{\"enabled\":true},\"invoice_history\":{\"enabled\":true},\"payment_method_update\":{\"enabled\":true}},\"login_page\":{\"enabled\":true,\"url\":\"https://billing.flapjack.foo/login\"},\"default_return_url\":\"https://app.flapjack.foo/dashboard/billing\"}"}
]}
JSON
    write_mock_curl_with_sequence "$mock_dir/curl"

    output="$(env -u STRIPE_SECRET_KEY STRIPE_SECRET_KEY_flapjack_cloud='sk_live_named_account' STRIPE_TEST_RESPONSE_FILE="$response_file" STRIPE_TEST_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/stripe/configure_billing_portal.sh" --account flapjack_cloud)"

    assert_valid_json "$output" "configure_billing_portal should emit valid JSON when --account is used"
    assert_contains "$output" '"target_account":"flapjack_cloud"' "configure_billing_portal should report the target account name"
    assert_contains "$output" '"account_id":"acct_live_mock"' "configure_billing_portal should include the Stripe account id"
    assert_contains "$output" '"configuration_id":"bpc_existing"' "configure_billing_portal should include the configuration id"

    local calls
    calls="$(cat "$call_log")"
    assert_contains "$calls" '"auth": "sk_live_named_account:"' "configure_billing_portal should authenticate with the suffixed account key"
    assert_contains "$calls" '"url": "https://api.stripe.com/v1/account"' "configure_billing_portal should fetch the active Stripe account first"
    assert_contains "$calls" '"url": "https://api.stripe.com/v1/billing_portal/configurations"' "configure_billing_portal should query portal configurations"
    assert_contains "$calls" '"url": "https://api.stripe.com/v1/billing_portal/configurations/bpc_existing"' "configure_billing_portal should update the existing default configuration"
    assert_contains "$calls" 'features[invoice_history][enabled]=true' "configure_billing_portal should enable invoice history"
    assert_contains "$calls" 'features[payment_method_update][enabled]=true' "configure_billing_portal should enable payment method updates"
    assert_contains "$calls" 'features[customer_update][allowed_updates][]=tax_id' "configure_billing_portal should configure customer-update fields"

    rm -rf "$mock_dir"
}

test_configure_billing_portal_errors_when_suffixed_key_missing() {
    local output exit_code
    output="$(env -u STRIPE_SECRET_KEY -u STRIPE_SECRET_KEY_flapjack_cloud bash "$REPO_ROOT/scripts/stripe/configure_billing_portal.sh" --account flapjack_cloud 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "2" "configure_billing_portal should exit 2 when --account key is missing"
    assert_contains "$output" 'STRIPE_SECRET_KEY_flapjack_cloud' "configure_billing_portal missing-key error should name the suffixed variable"
}

test_configure_billing_portal_errors_when_account_value_missing() {
    local output exit_code
    output="$(bash "$REPO_ROOT/scripts/stripe/configure_billing_portal.sh" --account 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "2" "configure_billing_portal should exit 2 when --account value is missing"
    assert_contains "$output" 'ERROR: --account requires a value' "configure_billing_portal missing-value error should be explicit"
}

test_configure_billing_portal_uses_canonical_key_without_account_flag() {
    local mock_dir response_file call_log output
    mock_dir="$(mktemp -d)"
    response_file="$mock_dir/responses.json"
    call_log="$mock_dir/calls.log"
    cat > "$response_file" <<'JSON'
{"index":0,"responses":[
  {"status":200,"body":"{\"id\":\"acct_live_canonical\"}"},
  {"status":200,"body":"{\"data\":[]}"},
  {"status":200,"body":"{\"id\":\"bpc_new_default\",\"is_default\":true,\"features\":{\"customer_update\":{\"enabled\":true},\"invoice_history\":{\"enabled\":true},\"payment_method_update\":{\"enabled\":true}},\"login_page\":{\"enabled\":false,\"url\":null},\"default_return_url\":null}"}
]}
JSON
    write_mock_curl_with_sequence "$mock_dir/curl"

    output="$(STRIPE_SECRET_KEY='sk_live_canonical_key' STRIPE_TEST_RESPONSE_FILE="$response_file" STRIPE_TEST_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/stripe/configure_billing_portal.sh")"

    assert_valid_json "$output" "configure_billing_portal should emit valid JSON with canonical key"
    assert_contains "$output" '"target_account":"canonical"' "configure_billing_portal should mark canonical key path when --account is omitted"
    assert_contains "$output" '"configuration_id":"bpc_new_default"' "configure_billing_portal should include newly created configuration id"

    local calls
    calls="$(cat "$call_log")"
    assert_contains "$calls" '"auth": "sk_live_canonical_key:"' "configure_billing_portal should use canonical STRIPE_SECRET_KEY when --account is omitted"
    assert_contains "$calls" '"url": "https://api.stripe.com/v1/billing_portal/configurations"' "configure_billing_portal should create a configuration when none exists"

    rm -rf "$mock_dir"
}

test_create_catalog_still_supports_account_flag_via_shared_helper() {
    local mock_dir call_log output
    mock_dir="$(mktemp -d)"
    call_log="$mock_dir/calls.log"
    write_catalog_mock_curl "$mock_dir/curl"

    output="$(env -u STRIPE_SECRET_KEY STRIPE_SECRET_KEY_flapjack_cloud='sk_live_catalog_regression' STRIPE_TEST_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" bash "$REPO_ROOT/scripts/stripe/create_catalog.sh" --account flapjack_cloud)"

    assert_valid_json "$output" "create_catalog should still emit valid JSON when using --account after helper extraction"
    assert_contains "$output" '"account_id":"acct_catalog_mock"' "create_catalog regression path should still fetch account id"
    assert_contains "$(cat "$call_log")" 'sk_live_catalog_regression:|GET|https://api.stripe.com/v1/account' "create_catalog should still resolve STRIPE_SECRET_KEY_<account> for --account runs"

    rm -rf "$mock_dir"
}

test_create_catalog_errors_when_account_value_missing() {
    local output exit_code
    output="$(bash "$REPO_ROOT/scripts/stripe/create_catalog.sh" --account 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "2" "create_catalog should exit 2 when --account value is missing"
    assert_contains "$output" 'ERROR: --account requires a value' "create_catalog missing-value error should be explicit"
}

echo "=== configure_billing_portal.sh tests ==="
test_configure_billing_portal_resolves_suffixed_account_key
test_configure_billing_portal_errors_when_suffixed_key_missing
test_configure_billing_portal_errors_when_account_value_missing
test_configure_billing_portal_uses_canonical_key_without_account_flag
test_create_catalog_still_supports_account_flag_via_shared_helper
test_create_catalog_errors_when_account_value_missing

echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
