#!/usr/bin/env bash
# Contract tests for secret rotation runbook content.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNBOOK_PATH="$REPO_ROOT/docs/runbooks/secret_rotation.md"
LAUNCH_RUNBOOK_PATH="$REPO_ROOT/docs/runbooks/launch-backend.md"
INCIDENT_RUNBOOK_PATH="$REPO_ROOT/docs/runbooks/incident-response.md"
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

read_file_if_exists() {
    local path="$1"
    if [ -f "$path" ]; then
        cat "$path"
    fi
}

test_secret_rotation_runbook_exists() {
    if [ -f "$RUNBOOK_PATH" ]; then
        pass "secret rotation runbook should exist"
    else
        fail "secret rotation runbook should exist at docs/runbooks/secret_rotation.md"
    fi
}

test_runbook_references_env_vars_contract() {
    local content
    content="$(read_file_if_exists "$RUNBOOK_PATH")"

    assert_contains "$content" "docs/env-vars.md" "runbook should reference docs/env-vars.md as canonical variable contract"
    assert_contains "$content" "STRIPE_SECRET_KEY" "runbook should reference STRIPE_SECRET_KEY"
    assert_contains "$content" "STRIPE_WEBHOOK_SECRET" "runbook should reference STRIPE_WEBHOOK_SECRET"
    assert_contains "$content" "JWT_SECRET" "runbook should reference JWT_SECRET"
    assert_contains "$content" "SES_FROM_ADDRESS" "runbook should reference SES_FROM_ADDRESS"
    assert_contains "$content" "SES_REGION" "runbook should reference SES_REGION"
}

test_runbook_covers_required_rotation_sections() {
    local content
    content="$(read_file_if_exists "$RUNBOOK_PATH")"

    assert_contains "$content" "## Stripe Rotation" "runbook should include a Stripe rotation section"
    assert_contains "$content" "## SES Rotation" "runbook should include an SES rotation section"
    assert_contains "$content" "## JWT Rotation" "runbook should include a JWT rotation section"
    assert_contains "$content" "Prechecks" "runbook should include prechecks guidance"
    assert_contains "$content" "Cutover" "runbook should include cutover guidance"
    assert_contains "$content" "Rollback" "runbook should include rollback guidance"
    assert_contains "$content" "Post-rotation verification" "runbook should include post-rotation verification guidance"
}

test_runbook_anchors_stripe_contract_to_canonical_checks() {
    local content
    content="$(read_file_if_exists "$RUNBOOK_PATH")"

    assert_contains "$content" "resolve_stripe_secret_key" "runbook should reference resolve_stripe_secret_key"
    assert_contains "$content" "check_stripe_key_present" "runbook should reference check_stripe_key_present"
    assert_contains "$content" "check_stripe_key_live" "runbook should reference check_stripe_key_live"
    assert_contains "$content" "check_stripe_webhook_secret_present" "runbook should reference check_stripe_webhook_secret_present"
    assert_contains "$content" "scripts/validate-stripe.sh" "runbook should reference validate-stripe.sh"
    assert_contains "$content" "docs/runbooks/launch-backend.md" "runbook should cross-reference launch-backend guidance"
    assert_contains "$content" "STRIPE_TEST_SECRET_KEY" "runbook should document compatibility fallback behavior"
}

test_runbook_anchors_ses_contract_to_existing_readiness_docs() {
    local content
    content="$(read_file_if_exists "$RUNBOOK_PATH")"

    assert_contains "$content" "docs/runbooks/email-production.md" "runbook should cross-reference email-production SES procedure"
    assert_contains "$content" "scripts/validate_ses_readiness.sh" "runbook should reference validate_ses_readiness.sh"
    assert_contains "$content" "SesConfig::from_reader" "runbook should reference SesConfig::from_reader"
    assert_contains "$content" "AWS credential chain" "runbook should defer credential-chain handling to email-production"
    assert_not_contains "$content" "bash scripts/validate_ses_readiness.sh --identity \"\$SES_FROM_ADDRESS\" --region \"\$SES_REGION\"" "runbook should not expand SES args from inline-only assignments"
    assert_contains "$content" "bash scripts/validate_ses_readiness.sh --identity noreply@example.com --region us-east-1" "runbook should show SES readiness args with explicit placeholder literals"
}

test_runbook_documents_single_key_jwt_cutover_constraints() {
    local content
    content="$(read_file_if_exists "$RUNBOOK_PATH")"

    assert_contains "$content" "Config::from_reader" "runbook should reference Config::from_reader"
    assert_contains "$content" "issue_jwt" "runbook should reference issue_jwt"
    assert_contains "$content" "AuthenticatedTenant::from_request_parts" "runbook should reference JWT verify path in tenant extractor"
    assert_contains "$content" "extract_tenant_id_from_jwt" "runbook should reference JWT verify path in middleware"
    assert_contains "$content" "RequestSpan::extract_tenant_id" "runbook should reference JWT verify path in request logging"
    assert_contains "$content" "single JWT_SECRET" "runbook should state that one JWT secret is used"
    assert_contains "$content" "not seamless" "runbook should state JWT rotation is not seamless"
    assert_contains "$content" "invalidate outstanding bearer tokens" "runbook should state token invalidation impact"
    assert_contains "$content" "deploy/restart" "runbook should document deploy/restart requirement for new secret"
}

test_launch_and_incident_docs_link_secret_rotation_runbook() {
    local launch_content incident_content
    launch_content="$(cat "$LAUNCH_RUNBOOK_PATH")"
    incident_content="$(cat "$INCIDENT_RUNBOOK_PATH")"

    assert_contains "$launch_content" "docs/runbooks/secret_rotation.md" "launch-backend runbook should link to secret rotation runbook"
    assert_contains "$launch_content" "SELECT COUNT(*) FROM usage_records WHERE recorded_at >= NOW() - INTERVAL '1 hour'" "launch-backend runbook should use recorded_at for usage_records recency checks"
    assert_not_contains "$launch_content" "SELECT COUNT(*) FROM usage_records WHERE created_at >= NOW() - INTERVAL '1 hour'" "launch-backend runbook should not use created_at for usage_records recency checks"
    assert_contains "$incident_content" "docs/runbooks/secret_rotation.md" "incident-response runbook should link to secret rotation runbook"
}

echo "=== secret rotation runbook contract tests ==="
test_secret_rotation_runbook_exists
test_runbook_references_env_vars_contract
test_runbook_covers_required_rotation_sections
test_runbook_anchors_stripe_contract_to_canonical_checks
test_runbook_anchors_ses_contract_to_existing_readiness_docs
test_runbook_documents_single_key_jwt_cutover_constraints
test_launch_and_incident_docs_link_secret_rotation_runbook

echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
