#!/usr/bin/env bash
# Tests for scripts/local-signoff-commerce.sh: strict-env preflight,
# artifact initialization, scope guardrails, and the full commerce proof lane.
# Uses mock binaries — does NOT start real services.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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

# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/test_helpers.sh
source "$SCRIPT_DIR/lib/test_helpers.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Minimal strict env for the signoff script.
strict_env_vars() {
    cat <<'EOF'
STRIPE_LOCAL_MODE=1
MAILPIT_API_URL=http://localhost:8025
STRIPE_WEBHOOK_SECRET=whsec_test_secret
COLD_STORAGE_ENDPOINT=http://localhost:9000
FLAPJACK_REGIONS=us-east-1
API_URL=http://localhost:3001
ADMIN_KEY=test-admin-key
DATABASE_URL=postgres://griddle:griddle_local@127.0.0.1:15432/fjcloud_dev
EOF
}

TEST_TMP_DIR=""
TEST_CALL_LOG=""
CLEANUP_DIRS=()

cleanup_test_workspaces() {
    local tmp_dir
    for tmp_dir in "${CLEANUP_DIRS[@]}"; do
        rm -rf "$tmp_dir"
    done
}

trap cleanup_test_workspaces EXIT

setup_test_workspace() {
    TEST_TMP_DIR=$(mktemp -d)
    CLEANUP_DIRS+=("$TEST_TMP_DIR")
    mkdir -p "$TEST_TMP_DIR/bin" "$TEST_TMP_DIR/artifacts"
    TEST_CALL_LOG="$TEST_TMP_DIR/calls.log"
}

setup_health_test_workspace() {
    local curl_writer="${1:-write_health_mock_curl}"
    setup_test_workspace
    "$curl_writer" "$TEST_TMP_DIR/bin/curl" "$TEST_CALL_LOG"
}

setup_commerce_test_workspace() {
    local seed_writer="${1:-write_mock_seed_local}"
    setup_test_workspace
    write_commerce_mock_curl "$TEST_TMP_DIR/bin/curl" "$TEST_CALL_LOG"
    "$seed_writer" "$TEST_TMP_DIR/mock_seed.sh" "$TEST_CALL_LOG"
}

first_artifact_file() {
    local artifact_dir="$1" pattern="$2"
    local file
    for file in "$artifact_dir"/$pattern; do
        [ -e "$file" ] || continue
        printf '%s\n' "$file"
        return 0
    done
    return 1
}

# Run the signoff script with given env overrides.
# Usage: run_signoff "$tmp_dir" [VAR=val ...]
run_signoff() {
    local tmp_dir="$1"; shift
    local env_args=()
    while IFS= read -r line; do
        [ -n "$line" ] && env_args+=("$line")
    done < <(strict_env_vars)
    # Apply caller overrides (can override or unset vars)
    for arg in "$@"; do
        env_args+=("$arg")
    done
    env_args+=("PATH=$tmp_dir/bin:$PATH")
    env_args+=("TMPDIR=$tmp_dir/artifacts")
    # Use mock seed script if present
    if [ -f "$tmp_dir/mock_seed.sh" ]; then
        env_args+=("SEED_LOCAL_SCRIPT=$tmp_dir/mock_seed.sh")
    fi

    env "${env_args[@]}" \
        bash "$REPO_ROOT/scripts/local-signoff-commerce.sh" 2>&1 || return $?
}

# Write a mock curl that responds to /health and logs all calls.
write_health_mock_curl() {
    local path="$1" call_log="$2"
    cat > "$path" <<'MOCK'
#!/usr/bin/env bash
echo "curl $*" >> "__CALL_LOG__"
for arg in "$@"; do
    if [[ "$arg" == */health ]]; then
        echo '{"status":"ok"}'
        exit 0
    fi
done
echo '{"status":"ok"}'
exit 0
MOCK
    sed -i '' "s|__CALL_LOG__|$call_log|g" "$path"
    chmod +x "$path"
}

# Write a mock curl that fails /health (simulates API down).
write_failing_health_mock_curl() {
    local path="$1" call_log="$2"
    cat > "$path" <<'MOCK'
#!/usr/bin/env bash
echo "curl $*" >> "__CALL_LOG__"
for arg in "$@"; do
    if [[ "$arg" == */health ]]; then
        exit 1
    fi
done
exit 1
MOCK
    sed -i '' "s|__CALL_LOG__|$call_log|g" "$path"
    chmod +x "$path"
}

# ============================================================================
# Preflight Tests
# ============================================================================

test_rejects_missing_stripe_local_mode() {
    setup_health_test_workspace

    local output exit_code=0
    output=$(run_signoff "$TEST_TMP_DIR" "STRIPE_LOCAL_MODE=" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "1" "should fail when STRIPE_LOCAL_MODE is unset"
    assert_contains "$output" "STRIPE_LOCAL_MODE" \
        "should name the missing variable in the error"
}

test_rejects_missing_mailpit_api_url() {
    setup_health_test_workspace

    local output exit_code=0
    output=$(run_signoff "$TEST_TMP_DIR" "MAILPIT_API_URL=" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "1" "should fail when MAILPIT_API_URL is unset"
    assert_contains "$output" "MAILPIT_API_URL" \
        "should name the missing variable in the error"
}

test_rejects_missing_stripe_webhook_secret() {
    setup_health_test_workspace

    local output exit_code=0
    output=$(run_signoff "$TEST_TMP_DIR" "STRIPE_WEBHOOK_SECRET=" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "1" "should fail when STRIPE_WEBHOOK_SECRET is unset"
    assert_contains "$output" "STRIPE_WEBHOOK_SECRET" \
        "should name the missing variable in the error"
}

test_rejects_missing_cold_storage_endpoint() {
    setup_health_test_workspace

    local output exit_code=0
    output=$(run_signoff "$TEST_TMP_DIR" "COLD_STORAGE_ENDPOINT=" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "1" "should fail when COLD_STORAGE_ENDPOINT is unset"
    assert_contains "$output" "COLD_STORAGE_ENDPOINT" \
        "should name the missing variable in the error"
}

test_rejects_missing_flapjack_regions() {
    setup_health_test_workspace

    local output exit_code=0
    output=$(run_signoff "$TEST_TMP_DIR" "FLAPJACK_REGIONS=" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "1" "should fail when FLAPJACK_REGIONS is unset"
    assert_contains "$output" "FLAPJACK_REGIONS" \
        "should name the missing variable in the error"
}

test_rejects_skip_email_verification_set() {
    setup_health_test_workspace

    local output exit_code=0
    output=$(run_signoff "$TEST_TMP_DIR" "SKIP_EMAIL_VERIFICATION=1" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "1" "should fail when SKIP_EMAIL_VERIFICATION is set"
    assert_contains "$output" "SKIP_EMAIL_VERIFICATION" \
        "should name the forbidden variable in the error"
}

test_rejects_unhealthy_api() {
    setup_health_test_workspace write_failing_health_mock_curl

    local output exit_code=0
    output=$(run_signoff "$TEST_TMP_DIR" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "1" "should fail when API health check fails"
    assert_contains "$output" "health" \
        "should mention health check failure"
}

# ============================================================================
# Artifact Initialization Tests
# ============================================================================

test_creates_artifact_dir_outside_repo() {
    setup_health_test_workspace

    # Run with preflight only (will fail at commerce steps, but artifact dir should exist)
    local output exit_code=0
    output=$(run_signoff "$TEST_TMP_DIR" 2>&1) || exit_code=$?

    # Artifact dir should be created under TMPDIR
    local artifact_dir="$TEST_TMP_DIR/artifacts/fjcloud-commerce-signoff"
    if [ -d "$artifact_dir" ]; then
        pass "should create artifact directory under TMPDIR"
    else
        fail "should create artifact directory under TMPDIR (not found at $artifact_dir)"
    fi
}

# ============================================================================
# Scope Guardrail Tests
# ============================================================================

test_does_not_accept_cold_tier_mode() {
    setup_health_test_workspace

    local output exit_code=0
    output=$(run_signoff "$TEST_TMP_DIR" "SIGNOFF_COLD_TIER=1" 2>&1) || exit_code=$?

    # The script should either ignore or reject cold-tier flags — never act on them
    assert_not_contains "$output" "cold" \
        "should not mention or process cold-tier operations"
}

# ============================================================================
# Commerce Flow Mock
# ============================================================================

# Write a comprehensive mock curl that simulates the full commerce flow:
# health, login/register, sync-stripe, mailpit search/message,
# verify-email, billing/run, and tenant invoice polling.
write_commerce_mock_curl() {
    local path="$1" call_log="$2"
    cat > "$path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
echo "curl $*" >> "__CALL_LOG__"

method="GET"
url=""
request_body=""
bearer_token=""
admin_key=""

for ((i=1; i<=$#; i++)); do
    arg="${!i}"
    case "$arg" in
        -X) i=$((i + 1)); method="${!i}" ;;
        -d) i=$((i + 1)); request_body="${!i}" ;;
        -H) i=$((i + 1))
            header_value="${!i}"
            if [[ "$header_value" == Authorization:* ]]; then
                bearer_token="${header_value#Authorization: Bearer }"
            elif [[ "$header_value" == x-admin-key:* ]]; then
                admin_key="${header_value#x-admin-key: }"
            fi
            ;;
        -w|-o) i=$((i + 1)) ;;
        http://*|https://*) url="$arg" ;;
    esac
done

case "$url" in
    */health)
        echo '{"status":"ok"}'
        exit 0
        ;;
    */auth/login)
        if [[ "$request_body" == *'"email":"dev@example.com"'* ]] && [[ "$request_body" == *'"password":"localdev-password-1234"'* ]]; then
            printf '{"token":"dev-token","customer_id":"customer-dev"}\n200'
            exit 0
        fi
        printf '{"error":"invalid email or password"}\n400'
        exit 0
        ;;
    */auth/register)
        if [[ "$request_body" != *'"name":"Local Commerce Signoff"'* ]]; then
            printf '{"error":"name, email, and password are required"}\n400'
            exit 0
        fi
        printf '{"token":"fresh-signup-token","customer_id":"customer-fresh"}\n201'
        exit 0
        ;;
    */auth/verify-email)
        printf '{}\n200'
        exit 0
        ;;
    */admin/customers/*/sync-stripe)
        if [[ "$admin_key" != "test-admin-key" ]]; then
            printf '{"error":"invalid admin key"}\n401'
            exit 0
        fi
        cust="${url##*/admin/customers/}"
        cust="${cust%%/sync-stripe*}"
        printf '{"message":"customer already linked to stripe","stripe_customer_id":"cus_mock_%s"}\n200' "$cust"
        exit 0
        ;;
    */admin/billing/run)
        if [[ "$admin_key" != "test-admin-key" ]]; then
            printf '{"error":"invalid admin key"}\n401'
            exit 0
        fi
        if [[ "$request_body" != *'"month":"'* ]]; then
            printf '{"error":"month is required"}\n400'
            exit 0
        fi
        if [[ "${COMMERCE_MOCK_ALREADY_INVOICED:-}" == "1" ]]; then
            printf '{"month":"2026-03","invoices_created":0,"invoices_skipped":1,"results":[{"status":"skipped","invoice_id":null,"customer_id":"customer-dev","reason":"already_invoiced"}]}\n200'
            exit 0
        fi
        printf '{"month":"2026-03","invoices_created":1,"invoices_skipped":0,"results":[{"status":"created","invoice_id":"inv_test_001","customer_id":"customer-dev","reason":""}]}\n200'
        exit 0
        ;;
    */invoices)
        if [[ "$bearer_token" != "dev-token" ]]; then
            printf '{"error":"authentication required"}\n401'
            exit 0
        fi
        printf '[{"id":"inv_test_001","period_start":"2026-03-01","period_end":"2026-04-01","status":"paid"}]\n200'
        exit 0
        ;;
    */invoices/inv_test_001)
        if [[ "$bearer_token" != "dev-token" ]]; then
            printf '{"error":"authentication required"}\n401'
            exit 0
        fi
        printf '{"id":"inv_test_001","status":"paid","paid_at":"2026-03-30T12:00:00Z"}\n200'
        exit 0
        ;;
    */api/v1/search*)
        # Mailpit search — return a message matching the query
        if [[ "$url" == *subject:invoice* ]] && [[ "$url" != *to:dev@example.com* ]]; then
            printf '{"messages_count":0,"total":0,"messages":[]}'
            exit 0
        fi
        printf '{"messages_count":1,"total":1,"messages":[{"ID":"msg-001"}]}'
        exit 0
        ;;
    */api/v1/message/msg-001)
        # Mailpit message body with a verification token link
        printf '{"Text":"Click here to verify: http://localhost:3001/auth/verify-email?token=test_verify_token_abc","HTML":""}'
        exit 0
        ;;
esac

echo "mock-curl: unhandled url: $url" >&2
exit 1
MOCK
    sed -i '' "s|__CALL_LOG__|$call_log|g" "$path"
    chmod +x "$path"
}

# Write a mock seed_local.sh that just succeeds.
write_mock_seed_local() {
    local path="$1" call_log="$2"
    cat > "$path" <<MOCK
#!/usr/bin/env bash
echo "seed_local.sh \$*" >> "$call_log"
exit 0
MOCK
    chmod +x "$path"
}

# Write a mock seed_local.sh that fails.
write_failing_mock_seed_local() {
    local path="$1" call_log="$2"
    cat > "$path" <<MOCK
#!/usr/bin/env bash
echo "seed_local.sh \$*" >> "$call_log"
exit 1
MOCK
    chmod +x "$path"
}

# ============================================================================
# Commerce Proof Lane Tests
# ============================================================================

test_full_commerce_proof_lane() {
    setup_commerce_test_workspace

    local output exit_code=0
    output=$(run_signoff "$TEST_TMP_DIR" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "0" "full commerce proof lane should pass"
    assert_contains "$output" "Commerce signoff PASSED" \
        "should report overall pass"
}

test_emits_json_evidence_file() {
    setup_commerce_test_workspace

    local output exit_code=0
    output=$(run_signoff "$TEST_TMP_DIR" 2>&1) || exit_code=$?

    local artifact_dir="$TEST_TMP_DIR/artifacts/fjcloud-commerce-signoff"
    local json_file
    json_file=$(first_artifact_file "$artifact_dir" "*.json" 2>/dev/null || true)
    if [ -n "$json_file" ]; then
        pass "should write JSON evidence file"
        local json_content
        json_content=$(cat "$json_file")
        assert_valid_json "$json_content" "JSON evidence should be valid JSON"
        assert_contains "$json_content" '"passed":true' \
            "JSON evidence should report passed=true"
        assert_contains "$json_content" '"steps"' \
            "JSON evidence should contain steps array"
    else
        fail "should write JSON evidence file (no .json found in $artifact_dir)"
    fi
}

test_emits_operator_summary_file() {
    setup_commerce_test_workspace

    local output exit_code=0
    output=$(run_signoff "$TEST_TMP_DIR" 2>&1) || exit_code=$?

    local artifact_dir="$TEST_TMP_DIR/artifacts/fjcloud-commerce-signoff"
    local txt_file
    txt_file=$(first_artifact_file "$artifact_dir" "*.txt" 2>/dev/null || true)
    if [ -n "$txt_file" ]; then
        pass "should write operator summary file"
        local txt_content
        txt_content=$(cat "$txt_file")
        assert_contains "$txt_content" "PASSED" \
            "operator summary should report PASSED"
        assert_contains "$txt_content" "Steps:" \
            "operator summary should list steps"
        assert_contains "$txt_content" "[PASS] seed_pass_1" \
            "operator summary should render individual step details"
    else
        fail "should write operator summary file (no .txt found in $artifact_dir)"
    fi
}

test_calls_seed_local_twice() {
    setup_commerce_test_workspace

    local output exit_code=0
    output=$(run_signoff "$TEST_TMP_DIR" 2>&1) || exit_code=$?

    local seed_calls
    seed_calls=$(grep -c "seed_local.sh" "$TEST_CALL_LOG" 2>/dev/null || echo "0")
    assert_eq "$seed_calls" "2" "should call seed_local.sh exactly twice"
}

test_verifies_stripe_link_for_seeded_customer() {
    setup_commerce_test_workspace

    local output exit_code=0
    output=$(run_signoff "$TEST_TMP_DIR" 2>&1) || exit_code=$?

    local calls
    calls=$(cat "$TEST_CALL_LOG")
    assert_contains "$calls" "sync-stripe" \
        "should call sync-stripe endpoint to verify Stripe linkage"
    assert_contains "$calls" "x-admin-key: test-admin-key" \
        "should authenticate sync-stripe with x-admin-key"
    assert_contains "$output" "Stripe link verified" \
        "should log Stripe link verification"
}

test_registers_fresh_signup_and_verifies_email() {
    setup_commerce_test_workspace

    local output exit_code=0
    output=$(run_signoff "$TEST_TMP_DIR" 2>&1) || exit_code=$?

    local calls
    calls=$(cat "$TEST_CALL_LOG")
    assert_contains "$calls" "/auth/register" \
        "should call /auth/register for fresh signup"
    assert_contains "$calls" '"name":"Local Commerce Signoff"' \
        "should include the required name field in register payload"
    assert_contains "$calls" "/api/v1/search" \
        "should query Mailpit for verification email"
    assert_contains "$calls" "/auth/verify-email" \
        "should call /auth/verify-email with extracted token"
    assert_contains "$output" "Email verified" \
        "should log successful email verification"
}

test_runs_batch_billing_and_checks_invoice() {
    setup_commerce_test_workspace

    local output exit_code=0
    output=$(run_signoff "$TEST_TMP_DIR" 2>&1) || exit_code=$?

    local calls
    calls=$(cat "$TEST_CALL_LOG")
    assert_contains "$calls" "/admin/billing/run" \
        "should call POST /admin/billing/run"
    assert_contains "$calls" "x-admin-key: test-admin-key" \
        "should authenticate batch billing with x-admin-key"
    assert_contains "$calls" '"month":"' \
        "should include the required month payload for batch billing"
    assert_contains "$calls" "/invoices/inv_test_001" \
        "should poll for invoice paid status"
    assert_contains "$calls" "Authorization: Bearer dev-token" \
        "should poll invoice status with the seeded tenant JWT"
    assert_contains "$calls" "to:dev@example.com+subject:invoice" \
        "should verify invoice email evidence for the billed seeded user"
    assert_contains "$output" "inv_test_001 is paid" \
        "should log invoice paid confirmation"
}

test_accepts_already_invoiced_rerun_when_existing_invoice_is_paid() {
    setup_commerce_test_workspace

    local output exit_code=0
    output=$(run_signoff "$TEST_TMP_DIR" \
        "COMMERCE_MOCK_ALREADY_INVOICED=1" \
        "SIGNOFF_MONTH=2026-03" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "0" \
        "commerce proof lane should pass when seeded customer was already invoiced"
    local calls
    calls=$(cat "$TEST_CALL_LOG")
    assert_contains "$calls" "GET http://localhost:3001/invoices" \
        "should list tenant invoices to resolve an already-invoiced rerun"
    assert_contains "$calls" "/invoices/inv_test_001" \
        "should still verify paid status on the existing invoice"
    assert_contains "$output" "already invoiced" \
        "should explain the idempotent rerun path"
}

test_fails_when_seed_fails() {
    setup_commerce_test_workspace write_failing_mock_seed_local

    local output exit_code=0
    output=$(run_signoff "$TEST_TMP_DIR" 2>&1) || exit_code=$?

    assert_eq "$exit_code" "1" "should fail when seed_local.sh fails"
    assert_contains "$output" "seed" \
        "should mention seed failure"
}

# ============================================================================
# Run Tests
# ============================================================================

echo "=== local-signoff-commerce.sh tests ==="
echo ""
echo "--- Preflight ---"
test_rejects_missing_stripe_local_mode
test_rejects_missing_mailpit_api_url
test_rejects_missing_stripe_webhook_secret
test_rejects_missing_cold_storage_endpoint
test_rejects_missing_flapjack_regions
test_rejects_skip_email_verification_set
test_rejects_unhealthy_api

echo ""
echo "--- Artifact Initialization ---"
test_creates_artifact_dir_outside_repo

echo ""
echo "--- Scope Guardrails ---"
test_does_not_accept_cold_tier_mode

echo ""
echo "--- Commerce Proof Lane ---"
test_full_commerce_proof_lane
test_emits_json_evidence_file
test_emits_operator_summary_file
test_calls_seed_local_twice
test_verifies_stripe_link_for_seeded_customer
test_registers_fresh_signup_and_verifies_email
test_runs_batch_billing_and_checks_invoice
test_accepts_already_invoiced_rerun_when_existing_invoice_is_paid
test_fails_when_seed_fails

echo ""
echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ] || exit 1
