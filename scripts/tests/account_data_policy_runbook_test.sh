#!/usr/bin/env bash
# Contract tests for account data policy runbook content.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNBOOK_PATH="$REPO_ROOT/docs/runbooks/account_data_policy.md"
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

test_runbook_documents_soft_delete_contract() {
    local content
    content="$(cat "$RUNBOOK_PATH")"

    assert_contains "$content" "DELETE /account" "runbook should reference DELETE /account"
    assert_contains "$content" "CustomerRepo::soft_delete" "runbook should reference CustomerRepo::soft_delete"
    assert_contains "$content" "customers.status = 'deleted'" "runbook should reference customers.status = 'deleted'"
    assert_contains "$content" "retained audit rows" "runbook should state rows are retained for audit"
}

test_runbook_documents_auth_and_admin_audit_visibility() {
    local content
    content="$(cat "$RUNBOOK_PATH")"

    assert_contains "$content" "{\"error\":\"invalid email or password\"}" \
        "runbook should include the exact generic invalid-credentials response"
    assert_contains "$content" "admin audit visibility" "runbook should reference admin audit visibility"
}

test_runbook_documents_not_implemented_boundaries() {
    local content
    content="$(cat "$RUNBOOK_PATH")"

    assert_contains "$content" "export is not implemented" \
        "runbook should state account export is not implemented"
    assert_contains "$content" "hard erasure is not implemented" \
        "runbook should state hard erasure is not implemented"
    assert_contains "$content" "downstream cleanup is not implemented" \
        "runbook should state downstream cleanup is not implemented"
    assert_contains "$content" "retention duration is not yet automated" \
        "runbook should state retention duration automation is not implemented"
}

echo "=== account data policy runbook contract tests ==="
test_runbook_documents_soft_delete_contract
test_runbook_documents_auth_and_admin_audit_visibility
test_runbook_documents_not_implemented_boundaries

echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
