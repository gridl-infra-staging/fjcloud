#!/usr/bin/env bash
# Contract tests for the launch-readiness evidence bundle docs.
#
# This suite focuses on the parts that are easy to regress when docs drift:
# discoverability, canonical cross-links, safe filename conventions, and
# protection against accidentally checking secret-looking values into prose.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
EVIDENCE_FILE="$REPO_ROOT/docs/runbooks/launch_readiness_evidence_20260420.md"
READINESS_DOC="$REPO_ROOT/docs/LOCAL_LAUNCH_READINESS.md"
ROADMAP_DOC="$REPO_ROOT/ROADMAP.md"
GAPS_AND_RISKS_DOC="$REPO_ROOT/docs/checklists/apr21_pm_2_post_phase6_gaps_and_risks.md"
STAGING_EVIDENCE_DOC="$REPO_ROOT/docs/runbooks/staging-evidence.md"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

test_evidence_bundle_exists_with_repo_safe_filename() {
    local basename
    basename="$(basename "$EVIDENCE_FILE")"

    if [ -f "$EVIDENCE_FILE" ]; then
        pass "evidence bundle file exists"
    else
        fail "evidence bundle file should exist at $EVIDENCE_FILE"
    fi

    assert_not_contains "$basename" "-" "evidence bundle filename should use underscores instead of dashes"
}

test_local_launch_readiness_links_latest_snapshot() {
    local readiness_content
    readiness_content="$(cat "$READINESS_DOC")"

    assert_contains "$readiness_content" "launch_readiness_evidence_20260420.md" \
        "LOCAL_LAUNCH_READINESS should link the latest evidence snapshot"
}

test_evidence_bundle_references_canonical_docs() {
    local evidence_content
    evidence_content="$(cat "$EVIDENCE_FILE")"

    assert_contains "$evidence_content" "docs/runbooks/staging-evidence.md" \
        "evidence bundle should link staging evidence"
    assert_contains "$evidence_content" "ROADMAP.md" \
        "evidence bundle should link roadmap status"
    assert_contains "$evidence_content" "PRIORITIES.md" \
        "evidence bundle should link priorities status"
    assert_contains "$evidence_content" "docs/LOCAL_LAUNCH_READINESS.md" \
        "evidence bundle should link local launch readiness"
}

test_evidence_bundle_covers_required_sections() {
    local evidence_content
    evidence_content="$(cat "$EVIDENCE_FILE")"

    assert_contains "$evidence_content" "## Summary Table" \
        "evidence bundle should include a summary table section"
    assert_contains "$evidence_content" "## Local Signoff" \
        "evidence bundle should include local signoff evidence"
    assert_contains "$evidence_content" "## Staging Infra" \
        "evidence bundle should include staging infrastructure evidence"
    assert_contains "$evidence_content" "## Browser Signoff" \
        "evidence bundle should include browser signoff evidence"
    assert_contains "$evidence_content" "## Cloudflare And DNS" \
        "evidence bundle should include Cloudflare/DNS status"
    assert_contains "$evidence_content" "## Billing Dry Run" \
        "evidence bundle should include billing dry-run status"
    assert_contains "$evidence_content" "## Deferred And Future" \
        "evidence bundle should include deferred/future items"
}

test_evidence_bundle_has_no_secret_like_values() {
    if grep -Eq "AKIA|sk_live|sk_test|whsec_|CLOUDFLARE.*=" "$EVIDENCE_FILE"; then
        fail "evidence bundle should not contain secret-looking values"
    else
        pass "evidence bundle avoids secret-looking values"
    fi
}

test_status_docs_reference_stage123_canonical_artifacts() {
    local roadmap_content risk_content staging_evidence_content status_docs_content
    roadmap_content="$(cat "$ROADMAP_DOC")"
    risk_content="$(cat "$GAPS_AND_RISKS_DOC")"
    staging_evidence_content="$(cat "$STAGING_EVIDENCE_DOC")"
    status_docs_content="$(printf '%s\n%s\n%s\n' "$roadmap_content" "$risk_content" "$staging_evidence_content")"

    assert_contains "$status_docs_content" "scripts/validate_ses_readiness.sh" \
        "status docs should reference scripts/validate_ses_readiness.sh"
    assert_contains "$status_docs_content" "scripts/launch/ses_deliverability_evidence.sh" \
        "status docs should reference scripts/launch/ses_deliverability_evidence.sh"
    assert_contains "$status_docs_content" "docs/runbooks/email-production.md" \
        "status docs should reference docs/runbooks/email-production.md"
    assert_contains "$status_docs_content" "docs/runbooks/account_data_policy.md" \
        "status docs should reference docs/runbooks/account_data_policy.md"
    assert_contains "$status_docs_content" "docs/runbooks/secret_rotation.md" \
        "status docs should reference docs/runbooks/secret_rotation.md"
    assert_contains "$status_docs_content" "load_env_file" \
        "status docs should preserve the canonical env-loader reference"
    assert_contains "$status_docs_content" "the SES account remains sandboxed" \
        "status docs should preserve the sanitized SES sandbox blocker detail"
    assert_not_contains "$status_docs_content" "fix unsupported assignment syntax" \
        "status docs should not preserve stale SES env syntax blocker wording"
}

test_status_docs_preserve_stage123_residual_boundaries() {
    local roadmap_content risk_content staging_evidence_content status_docs_content
    roadmap_content="$(cat "$ROADMAP_DOC")"
    risk_content="$(cat "$GAPS_AND_RISKS_DOC")"
    staging_evidence_content="$(cat "$STAGING_EVIDENCE_DOC")"
    status_docs_content="$(printf '%s\n%s\n%s\n' "$roadmap_content" "$risk_content" "$staging_evidence_content")"

    assert_contains "$status_docs_content" "SPF" \
        "status docs should keep SPF as unproven deliverability evidence"
    assert_contains "$status_docs_content" "MAIL FROM" \
        "status docs should keep MAIL FROM as unproven deliverability evidence"
    assert_contains "$status_docs_content" "bounce/complaint" \
        "status docs should keep bounce/complaint handling as unproven evidence"
    assert_contains "$status_docs_content" "first-send" \
        "status docs should keep first-send evidence as unproven"
    assert_contains "$status_docs_content" "inbox-receipt" \
        "status docs should keep inbox-receipt evidence as unproven"
    assert_contains "$status_docs_content" "soft-delete" \
        "status docs should keep account deletion as soft-delete only"
    assert_contains "$status_docs_content" "export is not implemented" \
        "status docs should keep account export as not implemented"
    assert_contains "$status_docs_content" "hard erasure is not implemented" \
        "status docs should keep hard erasure as not implemented"
    assert_contains "$status_docs_content" "downstream cleanup is not implemented" \
        "status docs should keep downstream cleanup as not implemented"
    assert_contains "$status_docs_content" "retention duration is not yet automated" \
        "status docs should keep retention-duration automation as not implemented"
    assert_contains "$status_docs_content" "live rotations have not been executed" \
        "status docs should keep live secret rotations as not yet executed"
    assert_contains "$status_docs_content" "centralized/external reporting" \
        "status docs should keep centralized browser error reporting as an open gap"
    assert_contains "$status_docs_content" "30-day RDS PostgreSQL CloudWatch log-retention coverage" \
        "status docs should document 30-day RDS PostgreSQL CloudWatch log retention"
    assert_contains "$status_docs_content" "ops/terraform/data/main.tf" \
        "status docs should anchor RDS log retention to ops/terraform/data/main.tf"
    assert_contains "$status_docs_content" "docs/runbooks/infra-terraform-apply.md" \
        "status docs should reference terraform import/adoption runbook"
    assert_contains "$status_docs_content" "docs/runbooks/infra-alarm-triage.md" \
        "status docs should reference alarm triage runbook"
    assert_contains "$status_docs_content" "docs/runbooks/launch-backend.md" \
        "status docs should reference launch backend triage runbook"
    assert_contains "$status_docs_content" "/aws/rds/instance/fjcloud-<env>/postgresql" \
        "status docs should reference the RDS PostgreSQL CloudWatch log group"
    assert_contains "$status_docs_content" "journalctl" \
        "status docs should keep host journalctl as API evidence source"

    assert_not_contains "$risk_content" "API application logs are centralized in CloudWatch" \
        "risk doc should not claim centralized API application logs in CloudWatch"
    assert_not_contains "$risk_content" "CloudWatch is the source of truth for API application logs" \
        "risk doc should not claim CloudWatch as API application log source of truth"
}

echo "=== launch_readiness_evidence docs tests ==="
test_evidence_bundle_exists_with_repo_safe_filename
test_local_launch_readiness_links_latest_snapshot
test_evidence_bundle_references_canonical_docs
test_evidence_bundle_covers_required_sections
test_evidence_bundle_has_no_secret_like_values
test_status_docs_reference_stage123_canonical_artifacts
test_status_docs_preserve_stage123_residual_boundaries
run_test_summary
