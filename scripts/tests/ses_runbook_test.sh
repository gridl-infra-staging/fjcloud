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
    assert_contains "$content" "/Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret" \
        "runbook should keep the canonical Stage 1 env source path in the identity-source contract"
    assert_contains "$content" "system@flapjack.foo" \
        "runbook should keep system@flapjack.foo in the readiness identity-source contract"
    assert_contains "$content" "ProductionAccessEnabled=true" \
        "runbook should keep production-access-enabled truth in the readiness identity-source contract"
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

test_runbook_requires_stage1_truth_values_and_removes_stale_snapshot() {
    local content
    content="$(cat "$RUNBOOK_PATH")"

    assert_contains "$content" "/Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret" \
        "runbook should document the canonical Stage 1 env source path"
    assert_contains "$content" "system@flapjack.foo" \
        "runbook should document system@flapjack.foo as the canonical sender identity"
    assert_contains "$content" 'inherited `flapjack.foo` domain identity/DKIM' \
        "runbook should document inherited flapjack.foo domain identity/DKIM for sender readiness"
    assert_contains "$content" "ProductionAccessEnabled=true (production access enabled)" \
        "runbook should document current production-access enabled state from Stage 1 truth"

    assert_not_contains "$content" "ProductionAccessEnabled=false" \
        "runbook should not preserve stale ProductionAccessEnabled=false blocker wording"
    assert_not_contains "$content" "still sandboxed" \
        "runbook should not preserve stale current-state sandbox wording"
    assert_not_contains "$content" "noreply@flapjack.foo" \
        "runbook should not drift to noreply@flapjack.foo as canonical sender identity"
    assert_not_contains "$content" "noreply@flapjack.cloud" \
        "runbook should not preserve stale flapjack.cloud sender references"
    assert_not_contains "$content" "/Users/stuart/repos/gridl/fjcloud/.secret/.env.secret" \
        "runbook should not preserve the stale /Users/stuart/repos/gridl/fjcloud/.secret/.env.secret path"
}

test_runbook_anchors_stage1_boundary_proof_surface() {
    local content
    content="$(cat "$RUNBOOK_PATH")"

    assert_contains "$content" "docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/reconciliation_summary.md" \
        "runbook should reference the Stage 1 checked-in reconciliation_summary owner path"
    assert_contains "$content" "docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/drift_blocker.md" \
        "runbook should reference the Stage 1 checked-in drift_blocker owner path"
    assert_contains "$content" "docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/first_send_retrieval_status.md" \
        "runbook should reference the Stage 3 first_send_retrieval_status companion artifact path"
    assert_contains "$content" "docs/runbooks/evidence/ses-deliverability/20260428T194527Z_stage3_live_probe/roundtrip.json" \
        "runbook should reference the latest Stage 3 live inbox roundtrip.json proof path"
    assert_contains "$content" "/Users/stuart/.matt/projects/fjcloud_dev-cd6902f9/apr23_am_1_ses_deliverability_refined.md-4c6ea1bd/artifacts/stage_04_ses_deliverability/fjcloud_ses_deliverability_evidence_20260423T063739Z_63867" \
        "runbook should reference the canonical Stage 4 wrapper run directory path"
    if [[ "$content" == *"bounce_blocker.txt"* ]] || [[ "$content" == *"bounce_event.json"* ]]; then
        pass "runbook references a Stage 4 bounce companion artifact path"
    else
        fail "runbook should reference either bounce_blocker.txt or bounce_event.json for Stage 4 bounce evidence status"
    fi
    if [[ "$content" == *"complaint_blocker.txt"* ]] || [[ "$content" == *"complaint_event.json"* ]]; then
        pass "runbook references a Stage 5 complaint companion artifact path"
    else
        fail "runbook should reference either complaint_blocker.txt or complaint_event.json for Stage 5 complaint evidence status"
    fi
    assert_contains "$content" "20260423T202158Z_ses_boundary_proof_full.txt" \
        "runbook should reference the preserved transcript path for historical context only"
    assert_not_contains "$content" "docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/summary.json" \
        "runbook should not introduce a second checked-in summary.json owner under Stage 1 boundary-proof evidence"
    assert_not_contains "$content" "proof complete" \
        "runbook should not claim proof-complete wording while deliverability boundaries remain open"
    assert_not_contains "$content" "proof captured" \
        "runbook should not claim proof-captured wording while deliverability boundaries remain open"
    assert_not_contains "$content" "proof-complete" \
        "runbook should not claim proof-complete marker wording while deliverability boundaries remain open"
    assert_not_contains "$content" "proof-captured" \
        "runbook should not claim proof-captured marker wording while deliverability boundaries remain open"
}

test_runbook_documents_bounce_complaint_follow_on_owner_contract() {
    local content
    content="$(cat "$RUNBOOK_PATH")"

    assert_contains "$content" "Bounce/Complaint Handling Gap (Follow-on Owner Contract)" \
        "runbook should include a dedicated bounce/complaint follow-on owner-contract subsection"
    assert_contains "$content" "docs/research/ses_bounce_complaint_gap.md" \
        "runbook subsection should point to the research note for deep rationale"
    assert_contains "$content" "infra/api/src/services/email.rs::SesEmailService::send_html_email" \
        "runbook subsection should name the outbound configuration-set attachment seam owner"
    assert_contains "$content" "ops/terraform/dns/main.tf" \
        "runbook subsection should name the DNS Terraform owner for SES wiring changes"
    assert_contains "$content" "ops/terraform/monitoring/" \
        "runbook subsection should name the monitoring Terraform owner for SES event-destination wiring"
    assert_contains "$content" "infra/api/src/routes/webhooks.rs" \
        "runbook subsection should name the existing API ingress seam candidate for downstream consumption"
    assert_contains "$content" "configuration set" \
        "runbook subsection should explicitly require one configuration-set attachment seam"
    assert_contains "$content" "event destination" \
        "runbook subsection should explicitly require one SES event-destination seam"
    assert_contains "$content" "bounce_complaint_handling=unproven" \
        "runbook subsection should preserve explicit unproven bounce/complaint status language"
}

echo "=== SES runbook contract tests ==="
test_runbook_references_readiness_contract_and_identity_source
test_runbook_cross_references_existing_staging_identity_proof
test_runbook_documents_canonical_wrapper_evidence_contract
test_runbook_documents_unproven_deliverability_boundaries
test_runbook_distinguishes_email_and_domain_identity_checks
test_runbook_preserves_optional_live_send_smoke_context
test_runbook_documents_blocked_prerequisites_and_preserved_stage3_status
test_runbook_requires_stage1_truth_values_and_removes_stale_snapshot
test_runbook_anchors_stage1_boundary_proof_surface
test_runbook_documents_bounce_complaint_follow_on_owner_contract

echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
