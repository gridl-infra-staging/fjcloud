#!/usr/bin/env bash
# Contract test for Stage 3 non-zero refund execution path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
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

STAGE2_DIR="$REPO_ROOT/docs/runbooks/evidence/prod_db_leak_cleanup/20260521T180304Z_stage2_refund_proposal"
STAGE3_DIR="$REPO_ROOT/docs/runbooks/evidence/prod_db_leak_cleanup/20260521T182407Z_stage3_refund_execution"
RUN_SCRIPT="$STAGE3_DIR/00_commands.sh"
STAGE2_DISPOSITIONS_JSON="$STAGE2_DIR/runs/primary/31_refund_dispositions.json"
STAGE2_SUMMARY_JSON="$STAGE2_DIR/40_refund_proposal_summary.json"
STAGE2_APPROVAL_JSON="$STAGE2_DIR/41_operator_approval_input.json"
STAGE3_APPROVAL_JSON="$STAGE3_DIR/05_operator_approval.json"

extract_dispositions_summary_python_block() {
    local source_script output_py
    source_script="$1"
    output_py="$2"
    awk '
        $0 ~ /^python3 - "\$RUN_DIR\/20_refund_execution_plan.json" "\$RUN_DIR\/24_refund_attempts.tsv" "\$RUN_DIR\/30_refund_execution_dispositions.json" "\$RUN_DIR\/31_refund_execution_dispositions.csv" "\$RUN_DIR\/40_refund_execution_summary.json" "\$STAGE2_APPROVAL_JSON" "\$STAGE3_APPROVAL_JSON" "\$RUN_DIR" <<'\''PY'\''$/ { capture=1; next }
        capture && $0 == "PY" { capture=0; exit }
        capture { print }
    ' "$source_script" > "$output_py"
    [ -s "$output_py" ]
}

test_stage3_nonzero_path_captures_refund_and_refetch_artifacts() {
    local tmp_dir stage3_backup stage2_dispositions_backup stage2_summary_backup
    local stage2_approval_backup stage3_approval_backup mock_dir secret_file
    local output rc
    tmp_dir="$(mktemp -d)"
    stage3_backup="$tmp_dir/stage3_backup"
    stage2_dispositions_backup="$tmp_dir/stage2_dispositions.json.orig"
    stage2_summary_backup="$tmp_dir/stage2_summary.json.orig"
    stage2_approval_backup="$tmp_dir/stage2_approval.json.orig"
    stage3_approval_backup="$tmp_dir/stage3_approval.json.orig"
    mock_dir="$tmp_dir/mock_bin"
    secret_file="$tmp_dir/.env.secret"
    mkdir -p "$mock_dir"

    cp -R "$STAGE3_DIR" "$stage3_backup"
    cp "$STAGE2_DISPOSITIONS_JSON" "$stage2_dispositions_backup"
    cp "$STAGE2_SUMMARY_JSON" "$stage2_summary_backup"
    cp "$STAGE2_APPROVAL_JSON" "$stage2_approval_backup"
    cp "$STAGE3_APPROVAL_JSON" "$stage3_approval_backup"

    cleanup() {
        rm -rf "$STAGE3_DIR"
        cp -R "$stage3_backup" "$STAGE3_DIR"
        cp "$stage2_dispositions_backup" "$STAGE2_DISPOSITIONS_JSON"
        cp "$stage2_summary_backup" "$STAGE2_SUMMARY_JSON"
        cp "$stage2_approval_backup" "$STAGE2_APPROVAL_JSON"
        cp "$stage3_approval_backup" "$STAGE3_APPROVAL_JSON"
        rm -rf "$tmp_dir"
    }
    trap cleanup EXIT

    cat > "$STAGE2_DISPOSITIONS_JSON" <<'JSON'
[
  {
    "customer_id": "cust_stage3_001",
    "email": "cust_stage3_001@example.test",
    "stripe_customer_id": "cus_stage3_001",
    "charge_id": "ch_test_123",
    "amount": 123,
    "currency": "usd",
    "disposition": "refund_eligible",
    "reason": "eligible_for_cleanup"
  }
]
JSON
    cat > "$STAGE2_SUMMARY_JSON" <<'JSON'
{
  "refund_eligible_charge_count": 1,
  "refund_total_cents": 123
}
JSON
    cat > "$STAGE2_APPROVAL_JSON" <<'JSON'
{
  "refund_eligible_charge_count": 1,
  "refund_total_cents": 123,
  "refund_eligible_charge_ids_by_customer": {
    "cust_stage3_001": [
      "ch_test_123"
    ]
  },
  "zero_refund_explanation": ""
}
JSON
    cat > "$STAGE3_APPROVAL_JSON" <<'JSON'
{
  "refund_eligible_charge_count": 1,
  "refund_total_cents": 123
}
JSON
    cat > "$secret_file" <<'EOF'
STRIPE_SECRET_KEY_flapjack_cloud=rk_live_mock_stage3
EOF

    cat > "$mock_dir/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

header_file=""
body_file=""
write_format=""
method="GET"
url=""
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
        -X)
            method="$2"
            shift 2
            ;;
        http://*|https://*)
            url="$1"
            shift
            ;;
        *)
            shift
            ;;
    esac
done

status="404"
request_id="req_unmatched"
body='{"error":{"code":"not_found"}}'
if [ "$method" = "GET" ] && [ "$url" = "https://api.stripe.com/v1/balance" ]; then
    status="200"
    request_id="req_balance"
    body='{"available":[]}'
elif [ "$method" = "POST" ] && [ "$url" = "https://api.stripe.com/v1/refunds" ]; then
    status="200"
    request_id="req_refund"
    body='{"object":"refund","id":"re_test_123"}'
elif [ "$method" = "GET" ] && [ "$url" = "https://api.stripe.com/v1/charges/ch_test_123" ]; then
    status="200"
    request_id="req_charge_refetch"
    body='{"id":"ch_test_123","refunded":true,"amount_refunded":123}'
fi

if [ -n "$header_file" ]; then
    printf 'Request-Id: %s\n' "$request_id" > "$header_file"
fi
if [ -n "$body_file" ]; then
    printf '%s' "$body" > "$body_file"
fi
if [ "$write_format" = "%{http_code}" ]; then
    printf '%s' "$status"
fi
MOCK
    chmod +x "$mock_dir/curl"

    rc=0
    output="$(
        FJCLOUD_SECRET_FILE="$secret_file" \
        PATH="$mock_dir:$PATH" \
        bash "$RUN_SCRIPT" primary 2>&1
    )" || rc=$?

    assert_eq "${rc}" "0" "stage3 runner should succeed on mocked non-zero refund path"
    assert_contains "${output}" "Stage 3 refund execution run complete:" \
        "stage3 runner should emit completion line on success"
    assert_file_exists "$STAGE3_DIR/runs/primary/24_refund_attempts/ch_test_123_refund.json" \
        "non-zero path should persist raw refund body per charge"
    assert_file_exists "$STAGE3_DIR/runs/primary/24_refund_attempts/ch_test_123_refund.meta.json" \
        "non-zero path should persist refund metadata per charge"
    assert_file_exists "$STAGE3_DIR/runs/primary/25_charge_refetches/ch_test_123_charge.json" \
        "non-zero path should persist post-refetch charge body per charge"
    assert_file_exists "$STAGE3_DIR/runs/primary/25_charge_refetches/ch_test_123_charge.meta.json" \
        "non-zero path should persist post-refetch charge metadata per charge"
    assert_contains "$(cat "$STAGE3_DIR/runs/primary/40_refund_execution_summary.json")" "\"refund_post_count\": 1" \
        "summary should count one refund POST in non-zero path"
    assert_contains "$(cat "$STAGE3_DIR/runs/primary/30_refund_execution_dispositions.json")" "\"execution_disposition\": \"refund_created\"" \
        "dispositions should mark successful refund creation"

    trap - EXIT
    cleanup
}

test_stage3_summary_counts_only_recorded_refund_attempts() {
    local tmp_dir plan_path attempts_path dispositions_path csv_path summary_path
    local stage2_approval_path stage3_approval_path summary_py
    tmp_dir="$(mktemp -d)"
    plan_path="$tmp_dir/20_refund_execution_plan.json"
    attempts_path="$tmp_dir/24_refund_attempts.tsv"
    dispositions_path="$tmp_dir/30_refund_execution_dispositions.json"
    csv_path="$tmp_dir/31_refund_execution_dispositions.csv"
    summary_path="$tmp_dir/40_refund_execution_summary.json"
    stage2_approval_path="$tmp_dir/41_operator_approval_input.json"
    stage3_approval_path="$tmp_dir/05_operator_approval.json"
    summary_py="$tmp_dir/stage3_dispositions_summary.py"

    cat > "$plan_path" <<'JSON'
[
  {
    "customer_id": "cust_stage3_missing_attempt",
    "email": "missing_attempt@example.test",
    "stripe_customer_id": "cus_missing_attempt",
    "charge_id": "ch_missing_attempt",
    "amount": 123,
    "currency": "usd",
    "stage2_disposition": "refund_eligible",
    "stage2_reason": "eligible_for_cleanup",
    "idempotency_key": "refund_ch_missing_attempt_prod_db_leak_cleanup_20260521"
  }
]
JSON
    : > "$attempts_path"
    cat > "$stage2_approval_path" <<'JSON'
{
  "zero_refund_explanation": ""
}
JSON
    cat > "$stage3_approval_path" <<'JSON'
{
  "refund_eligible_charge_count": 1,
  "refund_total_cents": 123
}
JSON

    if extract_dispositions_summary_python_block "$RUN_SCRIPT" "$summary_py"; then
        pass "runner should expose the dispositions+summary Python block for contract execution"
    else
        fail "runner should expose the dispositions+summary Python block for contract execution"
    fi
    python3 "$summary_py" \
        "$plan_path" \
        "$attempts_path" \
        "$dispositions_path" \
        "$csv_path" \
        "$summary_path" \
        "$stage2_approval_path" \
        "$stage3_approval_path" \
        "$tmp_dir"

    assert_contains "$(cat "$dispositions_path")" "\"execution_disposition\": \"execution_missing_attempt\"" \
        "eligible row without attempt artifact should be marked execution_missing_attempt"
    assert_contains "$(cat "$summary_path")" "\"refund_post_count\": 0" \
        "summary should count zero refund POSTs when no attempt artifacts were recorded"

    rm -rf "$tmp_dir"
}

echo "=== stage3_refund_execution_nonzero_path_test.sh ==="
test_stage3_nonzero_path_captures_refund_and_refetch_artifacts
test_stage3_summary_counts_only_recorded_refund_attempts
echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
