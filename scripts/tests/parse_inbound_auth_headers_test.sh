#!/usr/bin/env bash
# Tests for scripts/lib/parse_inbound_auth_headers.py
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/tests/lib/assertions.sh"

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

json_field() {
    local json_payload="$1" field_name="$2"
    python3 - "$json_payload" "$field_name" <<PY 2>/dev/null || echo ""
import json
import sys
payload = json.loads(sys.argv[1])
value = payload.get(sys.argv[2], "")
if isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, list):
    print(",".join(str(item) for item in value))
else:
    print(str(value))
PY
}

write_fixture() {
    local fixture_path="$1" fixture_mode="$2"
    case "$fixture_mode" in
        all_pass)
            cat > "$fixture_path" <<RFC822
From: sender@example.com
To: receiver@example.com
Subject: pass fixture
Authentication-Results: mx.google.com; dkim=pass header.i=@flapjack.foo; spf=pass smtp.mailfrom=flapjack.foo; dmarc=pass header.from=flapjack.foo

body
RFC822
            ;;
        missing_header)
            cat > "$fixture_path" <<RFC822
From: sender@example.com
To: receiver@example.com
Subject: missing auth header fixture

body
RFC822
            ;;
        mixed_failure)
            cat > "$fixture_path" <<RFC822
From: sender@example.com
To: receiver@example.com
Subject: mixed failure fixture
Authentication-Results: mx.google.com; dkim=fail header.i=@flapjack.foo; spf=pass smtp.mailfrom=flapjack.foo; dmarc=fail header.from=flapjack.foo

body
RFC822
            ;;
        *)
            echo "unknown fixture mode: $fixture_mode" >&2
            return 1
            ;;
    esac
}

test_parser_passes_when_all_auth_results_pass() {
    local fixture output exit_code
    fixture="$(mktemp)"
    write_fixture "$fixture" all_pass

    output="$(python3 "$REPO_ROOT/scripts/lib/parse_inbound_auth_headers.py" "$fixture" 2>&1)" || exit_code=$?

    rm -f "$fixture"

    assert_eq "${exit_code:-0}" "0" "parser should return zero exit when dkim/spf/dmarc pass"
    assert_valid_json "$output" "parser pass output should be valid JSON"
    assert_eq "$(json_field "$output" "passed")" "true" "parser pass output should report passed=true"
    assert_eq "$(json_field "$output" "dkim")" "pass" "parser pass output should report dkim=pass"
    assert_eq "$(json_field "$output" "spf")" "pass" "parser pass output should report spf=pass"
    assert_eq "$(json_field "$output" "dmarc")" "pass" "parser pass output should report dmarc=pass"
    assert_eq "$(json_field "$output" "failed_components")" "" "parser pass output should keep failed_components empty"
}

test_parser_uses_auth_verdict_exit_code_for_missing_authentication_results() {
    local fixture output exit_code failed_components
    fixture="$(mktemp)"
    write_fixture "$fixture" missing_header

    output="$(python3 "$REPO_ROOT/scripts/lib/parse_inbound_auth_headers.py" "$fixture" 2>&1)" || exit_code=$?

    rm -f "$fixture"

    assert_eq "${exit_code:-0}" "22" "missing Authentication-Results should return auth-verdict exit code 22"
    assert_valid_json "$output" "missing-header output should be valid JSON"
    assert_eq "$(json_field "$output" "passed")" "false" "missing-header output should report passed=false"
    assert_eq "$(json_field "$output" "dkim")" "missing" "missing-header output should report dkim=missing"
    assert_eq "$(json_field "$output" "spf")" "missing" "missing-header output should report spf=missing"
    assert_eq "$(json_field "$output" "dmarc")" "missing" "missing-header output should report dmarc=missing"
    failed_components="$(json_field "$output" "failed_components")"
    assert_contains "$failed_components" "dkim" "missing-header failure should name dkim as failed"
    assert_contains "$failed_components" "spf" "missing-header failure should name spf as failed"
    assert_contains "$failed_components" "dmarc" "missing-header failure should name dmarc as failed"
}

test_parser_names_specific_failed_components() {
    local fixture output exit_code failed_components
    fixture="$(mktemp)"
    write_fixture "$fixture" mixed_failure

    output="$(python3 "$REPO_ROOT/scripts/lib/parse_inbound_auth_headers.py" "$fixture" 2>&1)" || exit_code=$?

    rm -f "$fixture"

    assert_eq "${exit_code:-0}" "22" "mixed auth failures should return auth-verdict exit code 22"
    assert_valid_json "$output" "mixed-failure output should be valid JSON"
    assert_eq "$(json_field "$output" "passed")" "false" "mixed-failure output should report passed=false"
    assert_eq "$(json_field "$output" "dkim")" "fail" "mixed-failure output should report dkim=fail"
    assert_eq "$(json_field "$output" "spf")" "pass" "mixed-failure output should report spf=pass"
    assert_eq "$(json_field "$output" "dmarc")" "fail" "mixed-failure output should report dmarc=fail"
    failed_components="$(json_field "$output" "failed_components")"
    assert_contains "$failed_components" "dkim" "mixed-failure output should name dkim as failed"
    assert_not_contains "$failed_components" "spf" "mixed-failure output should not mark spf as failed"
    assert_contains "$failed_components" "dmarc" "mixed-failure output should name dmarc as failed"
}

echo "=== parse_inbound_auth_headers.py tests ==="
test_parser_passes_when_all_auth_results_pass
test_parser_uses_auth_verdict_exit_code_for_missing_authentication_results
test_parser_names_specific_failed_components

echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
