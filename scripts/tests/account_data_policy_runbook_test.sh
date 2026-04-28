#!/usr/bin/env bash
# Contract tests for account data policy runbook content.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNBOOK_PATH="$REPO_ROOT/docs/runbooks/account_data_policy.md"
ROADMAP_PATH="$REPO_ROOT/ROADMAP.md"
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
    assert_contains "$content" "deleted_at metadata" \
        "runbook should state soft delete stamps deleted_at metadata"
    assert_contains "$content" "retained audit rows" "runbook should state rows are retained for audit"
}

test_runbook_documents_auth_and_admin_audit_visibility() {
    local content
    content="$(cat "$RUNBOOK_PATH")"

    assert_contains "$content" "{\"error\":\"invalid email or password\"}" \
        "runbook should include the exact generic invalid-credentials response"
    assert_contains "$content" "admin audit visibility" "runbook should reference admin audit visibility"
}

test_runbook_documents_export_and_not_implemented_boundaries() {
    local content
    content="$(cat "$RUNBOOK_PATH")"

    assert_contains "$content" 'authenticated `GET /account/export` profile wrapper' \
        "runbook should state the authenticated account export boundary"
    assert_contains "$content" "actions.exportAccount" \
        "runbook should reference the settings-page export action owner"
    assert_contains "$content" "CustomerRepo::list_deleted_before_cutoff" \
        "runbook should reference the future cleanup selector seam in CustomerRepo"
    assert_contains "$content" "PgCustomerRepo::list_deleted_before_cutoff" \
        "runbook should reference the future cleanup selector seam in PgCustomerRepo"
    assert_contains "$content" "hard erasure is not implemented" \
        "runbook should state hard erasure is not implemented"
    assert_contains "$content" "downstream cleanup is not implemented" \
        "runbook should state downstream cleanup is not implemented"
    assert_contains "$content" "retention duration is not yet automated" \
        "runbook should state retention duration automation is not implemented"
}

test_runbook_documents_beta_launch_policy_section_and_owner_anchors() {
    local content
    content="$(cat "$RUNBOOK_PATH")"

    assert_contains "$content" "## Beta launch policy" \
        "runbook should include a dedicated beta launch policy section"
    assert_contains "$content" "infra/api/src/routes/account.rs::delete_account" \
        "runbook should reference delete_account owner path"
    assert_contains "$content" "infra/api/src/routes/account.rs::export_account" \
        "runbook should reference export_account owner path"
    assert_contains "$content" "web/src/routes/dashboard/settings/+page.server.ts::actions.exportAccount" \
        "runbook should reference settings export action owner path"
    assert_contains "$content" "CustomerRepo::soft_delete retention boundary" \
        "runbook should explicitly label the soft-delete retention boundary owner"
}

test_roadmap_documents_delete_precondition_and_status_gaps() {
    local open_items_section account_data_status_block
    open_items_section="$(
        awk '
            /^## Open \/ Not Yet Implemented$/ { in_open_items=1; next }
            /^## / { if (in_open_items) exit }
            in_open_items { print }
        ' "$ROADMAP_PATH"
    )"
    account_data_status_block="$(
        printf '%s\n' "$open_items_section" | awk '
            /^- Account-data policy status coverage is implemented via `docs\/runbooks\/account_data_policy\.md`;/ { in_account_data=1 }
            /^- / && in_account_data && $0 !~ /^- Account-data policy status coverage is implemented via `docs\/runbooks\/account_data_policy\.md`;/ {
                exit
            }
            in_account_data { print }
        '
    )"

    assert_contains "$account_data_status_block" "- Account-data policy status coverage is implemented via \`docs/runbooks/account_data_policy.md\`;" \
        "ROADMAP should keep the canonical account-data status owner in Open / Not Yet Implemented"
    assert_contains "$account_data_status_block" "deleted_at metadata exists" \
        "ROADMAP should document deleted_at metadata for retained soft-delete rows"
    assert_contains "$account_data_status_block" "future cutoff-based cleanup selector exists via \`CustomerRepo::list_deleted_before_cutoff\` / \`PgCustomerRepo::list_deleted_before_cutoff\`" \
        "ROADMAP should document the future cutoff-based cleanup selector seam"
    assert_contains "$account_data_status_block" "hard erasure is not implemented" \
        "ROADMAP should keep the hard-erasure gap status label"
    assert_contains "$account_data_status_block" "downstream cleanup is not implemented" \
        "ROADMAP should keep the downstream cleanup gap status label"
    assert_contains "$account_data_status_block" "retention duration is not yet automated" \
        "ROADMAP should keep the retention automation gap status label"
}

echo "=== account data policy runbook contract tests ==="
test_runbook_documents_soft_delete_contract
test_runbook_documents_auth_and_admin_audit_visibility
test_runbook_documents_export_and_not_implemented_boundaries
test_runbook_documents_beta_launch_policy_section_and_owner_anchors
test_roadmap_documents_delete_precondition_and_status_gaps

echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
