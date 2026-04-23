#!/usr/bin/env bash
# Contract tests for paid-beta RC signoff runbook content and discoverability.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNBOOK_PATH="$REPO_ROOT/docs/runbooks/paid_beta_rc_signoff.md"
READINESS_DOC="$REPO_ROOT/docs/LOCAL_LAUNCH_READINESS.md"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

test_runbook_exists_and_has_required_sections() {
    local content
    if [ -f "$RUNBOOK_PATH" ]; then
        pass "paid-beta RC runbook file exists"
    else
        fail "paid-beta RC runbook should exist at $RUNBOOK_PATH"
        return
    fi

    content="$(cat "$RUNBOOK_PATH")"
    assert_contains "$content" "# Paid-Beta RC Signoff Runbook" "runbook should define an operator-facing title"
    assert_contains "$content" "## Purpose" "runbook should include a purpose section"
    assert_contains "$content" "## Out Of Scope" "runbook should include an out-of-scope section"
    assert_contains "$content" "## Operator Prerequisites" "runbook should include operator prerequisites"
}

test_runbook_documents_canonical_coordinator_commands() {
    local content
    content="$(cat "$RUNBOOK_PATH")"

    assert_contains "$content" "bash scripts/launch/run_full_backend_validation.sh --dry-run --sha=<GIT_SHA>" "runbook should preserve dry-run compatibility command"
    assert_contains "$content" "--paid-beta-rc" "runbook should document paid-beta RC mode flag"
    assert_contains "$content" "--sha=<GIT_SHA>" "runbook should document SHA flag"
    assert_contains "$content" "--artifact-dir=<dir>" "runbook should document artifact-dir flag"
    assert_contains "$content" "--credential-env-file=<path>" "runbook should document credential-env-file flag"
    assert_contains "$content" "--billing-month=<YYYY-MM>" "runbook should document billing-month flag"
    assert_contains "$content" "--staging-smoke-ami-id=<ami-id>" "runbook should document staging smoke AMI flag"
}

test_runbook_documents_operator_facing_json_contract() {
    local content
    content="$(cat "$RUNBOOK_PATH")"

    assert_contains "$content" "mode=paid_beta_rc" "runbook should describe paid-beta RC mode field"
    assert_contains "$content" "ready" "runbook should describe ready field"
    assert_contains "$content" "verdict" "runbook should describe verdict field"
    assert_contains "$content" "steps[]" "runbook should describe steps[] field"
    assert_contains "$content" "pass" "runbook should describe pass status"
    assert_contains "$content" "fail" "runbook should describe fail status"
    assert_contains "$content" "blocked" "runbook should describe blocked status"
    assert_contains "$content" "scripts/tests/full_backend_validation_test.sh" "runbook should point to Stage 2 paid-beta RC step-name coverage"
    assert_contains "$content" "cargo_workspace_tests" "runbook should reference current paid-beta RC step names"
    assert_contains "$content" "backend_launch_gate" "runbook should reference current paid-beta RC step names"
    assert_contains "$content" "local_signoff" "runbook should reference current paid-beta RC step names"
    assert_contains "$content" "ses_readiness" "runbook should reference current paid-beta RC step names"
    assert_contains "$content" "staging_billing_rehearsal" "runbook should reference current paid-beta RC step names"
    assert_contains "$content" "browser_preflight" "runbook should reference current paid-beta RC step names"
    assert_contains "$content" "browser_auth_setup" "runbook should reference current paid-beta RC step names"
    assert_contains "$content" "terraform_static_guardrails" "runbook should reference current paid-beta RC step names"
    assert_contains "$content" "staging_runtime_smoke" "runbook should reference current paid-beta RC step names"
}

test_runbook_links_delegated_proof_owners() {
    local content
    content="$(cat "$RUNBOOK_PATH")"

    assert_contains "$content" "docs/runbooks/local-dev.md" "runbook should link local signoff owner runbook"
    assert_contains "$content" "docs/LOCAL_LAUNCH_READINESS.md" "runbook should link local signoff canonical context"
    assert_contains "$content" "docs/runbooks/email-production.md" "runbook should link SES runbook owner"
    assert_contains "$content" "scripts/validate_ses_readiness.sh" "runbook should link SES readiness owner script"
    assert_contains "$content" "docs/runbooks/staging_billing_dry_run.md" "runbook should link billing rehearsal runbook owner"
    assert_contains "$content" "scripts/staging_billing_rehearsal.sh" "runbook should link billing rehearsal owner script"
    assert_contains "$content" "scripts/e2e-preflight.sh" "runbook should link browser preflight owner script"
    assert_contains "$content" "ops/terraform/tests_stage7_static.sh" "runbook should link Terraform stage7 static owner"
    assert_contains "$content" "ops/terraform/tests_stage8_static.sh" "runbook should link Terraform stage8 static owner"
    assert_contains "$content" "ops/terraform/tests_stage7_runtime_smoke.sh" "runbook should link Terraform runtime smoke owner"
    assert_contains "$content" "docs/runbooks/infra-terraform-apply.md" "runbook should link Terraform apply runbook owner"
}

test_runbook_documents_blocker_reasons_and_ready_false_rule() {
    local content
    content="$(cat "$RUNBOOK_PATH")"

    assert_contains "$content" "credentialed_ses_identity_missing" "runbook should document credentialed SES identity blocker reason"
    assert_contains "$content" "credentialed_env_file_missing" "runbook should document missing credential env file blocker reason"
    assert_contains "$content" "credentialed_env_file_parse_failed" "runbook should document credential env parse blocker reason"
    assert_contains "$content" "credentialed_billing_env_file_missing" "runbook should document billing env file blocker reason"
    assert_contains "$content" "credentialed_billing_month_missing" "runbook should document billing month blocker reason"
    assert_contains "$content" "delegated billing classifications" "runbook should call out delegated billing classifications"
    assert_contains "$content" "credentialed_staging_smoke_inputs_missing" "runbook should document staging smoke blocker reason"
    assert_contains "$content" "ready=false" "runbook should state blocked required proofs force ready=false"
    assert_contains "$content" "local_signoff is useful local evidence only" "runbook should keep local_signoff scoped to local evidence"
    assert_contains "$content" "local webhook replay acceptance is local/mock evidence only" "runbook should keep webhook replay scoped to local/mock evidence"
    assert_contains "$content" "local/mock pass results do not satisfy credentialed billing/webhook/SES proof" "runbook should prevent local/mock proof from satisfying credentialed RC proofs"
}

test_runbook_discoverability_and_evidence_safety() {
    local runbook_content readiness_content
    runbook_content="$(cat "$RUNBOOK_PATH")"
    readiness_content="$(cat "$READINESS_DOC")"

    assert_contains "$readiness_content" "runbooks/paid_beta_rc_signoff.md" "LOCAL_LAUNCH_READINESS should link paid-beta RC runbook"
    assert_contains "$runbook_content" "docs/runbooks/staging-evidence.md" "runbook should point to staging-evidence as dated authority"

    if grep -Eq "AKIA|sk_live|sk_test|whsec_|CLOUDFLARE.*=|aws_account_id|[0-9]{12}" "$RUNBOOK_PATH"; then
        fail "runbook should not contain secret-looking values or account-id-looking values"
    else
        pass "runbook avoids secret-looking values and account ID literals"
    fi
}

echo "=== paid-beta RC runbook contract tests ==="
test_runbook_exists_and_has_required_sections
test_runbook_documents_canonical_coordinator_commands
test_runbook_documents_operator_facing_json_contract
test_runbook_links_delegated_proof_owners
test_runbook_documents_blocker_reasons_and_ready_false_rule
test_runbook_discoverability_and_evidence_safety
run_test_summary
