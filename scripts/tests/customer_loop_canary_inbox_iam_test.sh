#!/usr/bin/env bash
# Contract test: customer-loop canary Lambda IAM policy must read inbound inbox S3.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_FILE="$REPO_ROOT/ops/terraform/monitoring/main.tf"

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

main() {
    local content
    content="$(cat "$TARGET_FILE")"

    assert_contains "$content" "customer_loop_canary_inbound_roundtrip_s3_path_segments" "customer-loop locals parse inbound S3 URI into path segments"
    assert_contains "$content" "customer_loop_canary_inbound_roundtrip_bucket_arn" "customer-loop locals expose inbox bucket ARN"
    assert_contains "$content" "customer_loop_canary_inbound_roundtrip_object_arn" "customer-loop locals expose inbox object ARN"
    assert_contains "$content" "AllowCustomerLoopCanaryListInboundBucket" "customer-loop IAM policy includes list-bucket statement"
    assert_contains "$content" "\"s3:ListBucket\"" "customer-loop IAM policy grants s3:ListBucket"
    assert_contains "$content" "AllowCustomerLoopCanaryReadInboundObjects" "customer-loop IAM policy includes object-read statement"
    assert_contains "$content" "\"s3:GetObject\"" "customer-loop IAM policy grants s3:GetObject"

    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
