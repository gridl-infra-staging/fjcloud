#!/usr/bin/env bash
# Contract tests for SES production runbook content.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNBOOK_PATH="$REPO_ROOT/docs/runbooks/email-production.md"
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

test_runbook_references_readiness_contract_and_identity_source() {
    local content
    content="$(cat "$RUNBOOK_PATH")"

    assert_contains "$content" "scripts/validate_ses_readiness.sh" "runbook should reference validate_ses_readiness.sh"
    assert_contains "$content" "--identity" "runbook should document readiness command identity argument"
    assert_contains "$content" "SES_FROM_ADDRESS" "runbook should document canonical SES identity input source"
    assert_contains "$content" "canonical SES identity input" "runbook should call out the single canonical identity input"
}

test_runbook_cross_references_existing_staging_identity_proof() {
    local content
    content="$(cat "$RUNBOOK_PATH")"

    assert_contains "$content" "ops/terraform/tests_stage7_runtime_smoke.sh" "runbook should cross-reference staging runtime smoke script"
    assert_contains "$content" "assert_ses_identity_verified" "runbook should cross-reference assert_ses_identity_verified"
}

test_runbook_documents_canonical_wrapper_evidence_contract() {
    local content
    content="$(cat "$RUNBOOK_PATH")"

    assert_contains "$content" "scripts/launch/ses_deliverability_evidence.sh" "runbook should name the SES deliverability wrapper as the canonical evidence entrypoint"
    assert_contains "$content" "fjcloud_ses_deliverability_evidence_" "runbook should document run-scoped SES evidence directory naming"
    assert_contains "$content" "summary.json" "runbook should document summary.json as the run-level verdict artifact"
    assert_contains "$content" "overall_verdict" "runbook should document the overall_verdict field"
    assert_contains "$content" "sender" "runbook should document the sender field"
    assert_contains "$content" "account_status" "runbook should document the account_status field"
    assert_contains "$content" "identity_status" "runbook should document the identity_status field"
    assert_contains "$content" "recipient_preflight" "runbook should document the recipient_preflight field"
    assert_contains "$content" "send_attempt" "runbook should document the send_attempt field"
    assert_contains "$content" "suppression_check" "runbook should document the suppression_check field"
    assert_contains "$content" "deliverability_boundaries" "runbook should document the deliverability_boundaries field"
    assert_contains "$content" "redaction" "runbook should document the redaction field"
}

test_runbook_documents_unproven_deliverability_boundaries() {
    local content
    content="$(cat "$RUNBOOK_PATH")"

    assert_contains "$content" "unproven_deliverability_items" "runbook should reference the unproven_deliverability_items JSON step"
    assert_contains "$content" "SPF" "runbook should call SPF unproven in this stage"
    assert_contains "$content" "MAIL FROM" "runbook should call MAIL FROM unproven in this stage"
    assert_contains "$content" "bounce/complaint" "runbook should call bounce/complaint handling unproven in this stage"
    assert_contains "$content" "first-send" "runbook should call first-send evidence unproven in this stage"
    assert_contains "$content" "inbox-receipt" "runbook should call inbox-receipt evidence unproven in this stage"
}

test_runbook_distinguishes_email_and_domain_identity_checks() {
    local content
    content="$(cat "$RUNBOOK_PATH")"

    assert_contains "$content" "email identities it reports that DKIM verification is not applicable" "runbook should state that DKIM is not required for email identities"
    assert_contains "$content" 'IdentityType: EMAIL_ADDRESS' "runbook should show email identity output as a valid case"
    assert_contains "$content" 'IdentityType: DOMAIN' "runbook should still show domain identity output as a valid case"
    assert_contains "$content" 'DkimAttributes.Status: SUCCESS' "runbook should keep DKIM success as the domain-identity requirement"
    assert_contains "$content" "configured SES sender identity is verified; if it is a domain identity, DKIM is passing" "deployment checklist should not force a domain-only identity model"
}

test_runbook_preserves_optional_live_send_smoke_context() {
    local content
    content="$(cat "$RUNBOOK_PATH")"

    assert_contains "$content" "infra/api/tests/email_test.rs::ses_live_smoke_sends_verification_email" "runbook should reference the delegated ignored live-send seam path"
    assert_contains "$content" "diagnostic" "runbook should scope direct cargo usage to diagnostics/delegated seam execution"
    assert_contains "$content" "ses_live_smoke_sends_verification_email" "runbook should reference the optional live SES smoke test"
    assert_contains "$content" "Stage 1 does not run or replace" "runbook should state stage scope for live-send smoke"
    assert_contains "$content" "ignored" "runbook should clarify live smoke remains ignored by default"
}

test_runbook_documents_blocked_prerequisites_and_preserved_stage3_status() {
    local content
    content="$(cat "$RUNBOOK_PATH")"

    assert_contains "$content" "If \`SES_FROM_ADDRESS\` is missing, the wrapper blocks before it can delegate readiness." \
        "runbook should describe SES_FROM_ADDRESS as a readiness delegation blocker"
    assert_contains "$content" "If \`SES_REGION\` is missing, the wrapper blocks readiness delegation, recipient preflight, and the canonical live-send seam." \
        "runbook should describe SES_REGION as a blocker for readiness, recipient preflight, and live-send seam"
    assert_contains "$content" "AWS credentials alone are not enough for the wrapper to produce a meaningful" \
        "runbook should state AWS credentials alone are insufficient for meaningful wrapper evidence"
    assert_contains "$content" "preserved Stage 3 artifact is a blocked-path evidence run rather than a passing live-send proof" \
        "runbook should document preserved Stage 3 artifact as blocked-path evidence only"
    assert_contains "$content" "If omitted, the wrapper attempts verified self-recipient discovery from \`SES_FROM_ADDRESS\` and blocks when no verified recipient can be proven." \
        "runbook should document wrapper self-recipient discovery and blocking behavior"
    assert_contains "$content" "In sandbox mode, non-simulator recipients must be verified; otherwise the wrapper reports recipient-preflight blocked and does not attempt the live-send seam." \
        "runbook should document sandbox non-simulator verified-recipient requirement"
}

echo "=== SES runbook contract tests ==="
test_runbook_references_readiness_contract_and_identity_source
test_runbook_cross_references_existing_staging_identity_proof
test_runbook_documents_canonical_wrapper_evidence_contract
test_runbook_documents_unproven_deliverability_boundaries
test_runbook_distinguishes_email_and_domain_identity_checks
test_runbook_preserves_optional_live_send_smoke_context
test_runbook_documents_blocked_prerequisites_and_preserved_stage3_status

echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
