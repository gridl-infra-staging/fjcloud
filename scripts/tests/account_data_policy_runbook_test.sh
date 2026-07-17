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

test_runbook_documents_export_and_lifecycle_boundaries() {
    local content
    content="$(cat "$RUNBOOK_PATH")"

    assert_contains "$content" 'authenticated `GET /account/export` profile wrapper' \
        "runbook should state the authenticated account export boundary"
    assert_contains "$content" "actions.exportAccount" \
        "runbook should reference the settings-page export action owner"
    assert_contains "$content" "CustomerRepo::list_deleted_before_cutoff" \
        "runbook should reference the cleanup selector seam in CustomerRepo"
    assert_contains "$content" "PgCustomerRepo::list_deleted_before_cutoff" \
        "runbook should reference the cleanup selector seam in PgCustomerRepo"
    assert_contains "$content" "hard erasure is implemented" \
        "runbook should state hard erasure is implemented"
    assert_contains "$content" "downstream cleanup is handled inline by the hard-erase transaction" \
        "runbook should state downstream cleanup is handled by hard erase"
    assert_contains "$content" "retention duration is automated by fjcloud-retention-job" \
        "runbook should state retention duration automation is implemented"
    assert_contains "$content" "POST /admin/customers/:id/hard-erase" \
        "runbook should reference the hard-erase route used by the retention loop"
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

test_runbook_documents_retention_job_operator_contract() {
    local content
    content="$(cat "$RUNBOOK_PATH")"

    assert_contains "$content" "fjcloud-retention-job" \
        "runbook should name the retention job binary"
    assert_contains "$content" "RETENTION_DRY_RUN" \
        "runbook should document the dry-run operator switch"
    assert_contains "$content" "RETENTION_MAX_ERASE_PER_RUN" \
        "runbook should document the per-run erasure bound"
    assert_contains "$content" "skipped-by-bound" \
        "runbook should document the bounded-run summary field"
    assert_contains "$content" "SyslogIdentifier=fjcloud-retention-job" \
        "runbook should document the journald identifier"
    assert_contains "$content" "Name=fjcloud-api-<env>" \
        "runbook should document the API host selector contract"
}

test_roadmap_documents_delete_precondition_and_status_gaps() {
    local planned_section account_retention_block
    planned_section="$(
        awk '
            /^## Planned$/ { in_planned=1; next }
            /^## / { if (in_planned) exit }
            in_planned { print }
        ' "$ROADMAP_PATH"
    )"
    account_retention_block="$(
        printf '%s\n' "$planned_section" | awk '
            /^- \*\*Account-retention automation implemented\.\*\*/ { in_account_data=1 }
            /^- / && in_account_data && $0 !~ /^- \*\*Account-retention automation implemented\.\*\*/ {
                exit
            }
            in_account_data { print }
        '
    )"

    assert_contains "$account_retention_block" "- **Account-retention automation implemented.**" \
        "ROADMAP should mark account-retention automation implemented"
    assert_contains "$account_retention_block" "Owner: \`docs/runbooks/account_data_policy.md\`" \
        "ROADMAP should point account-retention detail at the runbook owner"
    assert_contains "$account_retention_block" "fjcloud-retention-job" \
        "ROADMAP should point to the implemented retention job"
    assert_not_contains "$planned_section" "Account-retention automation remains open" \
        "ROADMAP should not leave account-retention automation marked open"
}

echo "=== account data policy runbook contract tests ==="
test_runbook_documents_soft_delete_contract
test_runbook_documents_auth_and_admin_audit_visibility
test_runbook_documents_export_and_lifecycle_boundaries
test_runbook_documents_beta_launch_policy_section_and_owner_anchors
test_runbook_documents_retention_job_operator_contract
test_roadmap_documents_delete_precondition_and_status_gaps

echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
