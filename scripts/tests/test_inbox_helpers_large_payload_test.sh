#!/usr/bin/env bash
# Regression test: test_inbox_find_matching_object_key must scan candidates and
# locate a matching email even when the underlying s3api list-objects-v2
# payload is large enough to exceed Lambda's ARG_MAX (~128 KB) when passed as
# argv. Reproduces the Stage 3 prod customer-loop seam where the helper
# silently produced zero candidates because the python parser invocations were
# passing the full list JSON via sys.argv.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$REPO_ROOT/scripts/lib/test_inbox_helpers.sh"

# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=scripts/lib/test_inbox_helpers.sh
source "$HELPER"

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

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

NONCE="canary-large-payload-probe-$$"
TARGET_KEY="e2e-emails/target-${NONCE}-key"
LIST_PAYLOAD_FILE="$WORK_DIR/list.json"

# Build a synthetic list payload large enough to exceed the typical Lambda
# ARG_MAX ceiling. Each entry is ~250 bytes; 600 entries ~= 150 KB. The target
# key is in the most-recent slot so the body-scan fallback would find it on
# attempt 1 if and only if the helper does NOT pass the JSON via argv.
python3 - "$LIST_PAYLOAD_FILE" "$TARGET_KEY" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone

out_path = sys.argv[1]
target_key = sys.argv[2]

base = datetime(2026, 5, 18, 0, 0, 0, tzinfo=timezone.utc)
contents = []
for i in range(600):
    contents.append({
        "Key": f"e2e-emails/synthetic-padding-key-{i:06d}-{'x' * 80}",
        "LastModified": (base + timedelta(seconds=i)).isoformat().replace("+00:00", "Z"),
        "Size": 4096,
        "ETag": "\"" + "0" * 32 + "\"",
        "StorageClass": "STANDARD",
    })
# Target is most-recent so it shows up in the top-25 candidate window.
contents.append({
    "Key": target_key,
    "LastModified": (base + timedelta(hours=10)).isoformat().replace("+00:00", "Z"),
    "Size": 4096,
    "ETag": "\"" + "1" * 32 + "\"",
    "StorageClass": "STANDARD",
})
payload = {"Contents": contents}
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh)
print(f"payload-bytes={sum(len(c['Key']) for c in contents) + 200 * len(contents)}", file=sys.stderr)
PY

PAYLOAD_BYTES=$(wc -c < "$LIST_PAYLOAD_FILE")
echo "synthetic list payload bytes: $PAYLOAD_BYTES"

# Stub aws + test_inbox_fetch_rfc822 so the helper exercises the body-scan path
# without any real S3 calls. The fetch stub returns RFC822 containing the
# nonce only for the target key, mirroring the SES inbound behavior where the
# nonce lives in the message body rather than the key.
aws() {
    if [ "${1:-}" = "s3api" ] && [ "${2:-}" = "list-objects-v2" ]; then
        cat "$LIST_PAYLOAD_FILE"
        return 0
    fi
    echo "unexpected aws invocation: $*" >&2
    return 1
}

test_inbox_fetch_rfc822() {
    local key="$2"
    if [ "$key" = "$TARGET_KEY" ]; then
        printf 'To: probe@test.flapjack.foo\r\n\r\nBody with nonce %s here\r\n' "$NONCE"
        return 0
    fi
    printf 'To: other@test.flapjack.foo\r\n\r\nNo nonce here\r\n'
    return 0
}

test_finds_match_with_large_list_payload() {
    local output
    if ! output="$(test_inbox_find_matching_object_key flapjack-cloud-releases e2e-emails/ "$NONCE" us-east-1 1 0 2>&1)"; then
        fail "helper must succeed with large list payload; output: ${output}"
        return
    fi
    assert_eq "$output" "$TARGET_KEY" \
        "helper should return the target key whose body contains the nonce"
}

main() {
    echo "=== test_inbox_helpers_large_payload_test.sh ==="
    echo ""

    test_finds_match_with_large_list_payload

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
