#!/usr/bin/env bash
# Static contract tests for live E2E evidence runbook coverage.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

STAGING_EVIDENCE_DOC="$REPO_ROOT/docs/runbooks/staging-evidence.md"
GUARDRAILS_DOC="$REPO_ROOT/docs/runbooks/aws_live_e2e_guardrails.md"
INFRA_BUNDLE_DOC="$REPO_ROOT/docs/runbooks/infra-evidence-bundle.md"
DOC_FILES=(
    "$STAGING_EVIDENCE_DOC"
    "$GUARDRAILS_DOC"
    "$INFRA_BUNDLE_DOC"
)
MISSING_REQUIRED_DOCS=0

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

read_doc() {
    local path="$1"
    cat "$path"
}

read_all_docs() {
    cat "$STAGING_EVIDENCE_DOC" "$GUARDRAILS_DOC" "$INFRA_BUNDLE_DOC"
}

test_docs_exist() {
    local doc
    for doc in "${DOC_FILES[@]}"; do
        if [ -f "$doc" ]; then
            pass "$(basename "$doc") exists"
        else
            fail "missing required runbook: $doc"
            MISSING_REQUIRED_DOCS=1
        fi
    done
}

test_wrapper_entrypoint_artifact_dir_and_summary_are_documented() {
    local doc content
    for doc in "${DOC_FILES[@]}"; do
        content="$(read_doc "$doc")"
        assert_contains "$content" "scripts/launch/live_e2e_evidence.sh" "$(basename "$doc") should document wrapper entrypoint"
        assert_contains "$content" "--artifact-dir" "$(basename "$doc") should document --artifact-dir"
        assert_contains "$content" "summary.json" "$(basename "$doc") should document summary.json"
    done
}

test_owner_script_boundary_is_preserved() {
    local all_docs
    all_docs="$(read_all_docs)"

    assert_contains "$all_docs" "ops/terraform/tests_stage7_runtime_smoke.sh" "runbooks should keep runtime smoke owner-script boundary"
    assert_contains "$all_docs" "scripts/staging_billing_rehearsal.sh" "runbooks should keep billing owner-script boundary"
    assert_not_contains "$all_docs" "run_runtime_smoke_check" "runbooks should not expose wrapper internal runtime helper details"
    assert_not_contains "$all_docs" "run_credentialed_billing_lane_if_requested" "runbooks should not expose wrapper internal billing helper details"
}

test_failed_run_artifact_follow_up_uses_wrapper_run_dir() {
    local content
    content="$(read_doc "$GUARDRAILS_DOC")"

    assert_contains "$content" 'run directory under `--artifact-dir`' "guardrails runbook should direct failed runs to wrapper-selected run directory"
    assert_contains "$content" "summary.json" "guardrails runbook should direct failed-run triage to summary.json in wrapper run directory"
    assert_not_contains "$content" 'artifact path from `ops/terraform/artifacts/`' "guardrails runbook should not direct failed runs to a fixed artifact root"
}

test_budget_guardrail_prep_artifact_contract_is_documented() {
    local content
    content="$(read_doc "$GUARDRAILS_DOC")"

    assert_contains "$content" "proposal_ready" "guardrails runbook should describe proposal_ready prep status"
    assert_contains "$content" "--budget-guardrail-artifact" "guardrails runbook should document validate_all --budget-guardrail-artifact entrypoint"
    assert_contains "$content" "proposal.auto.tfvars.example" "guardrails runbook should document proposal var-file artifact"
    assert_contains "$content" "terraform_plan_command.txt" "guardrails runbook should document plan command artifact"
    assert_contains "$content" "missing_fields" "guardrails runbook should document blocked missing_fields reporting"
    assert_contains "$content" "missing_flags" "guardrails runbook should document blocked missing_flags reporting"
    assert_contains "$content" "plan_command" "guardrails runbook should document blocked omission of plan_command payload"
    assert_contains "$content" "proposed_variables" "guardrails runbook should document blocked omission of proposed_variables payload"
    assert_contains "$content" "omits" "guardrails runbook should explicitly call out blocked-artifact omission semantics"
    assert_not_contains "$content" "collect_missing_fields" "guardrails runbook should not expose prep-script internal helper names"
    assert_not_contains "$content" "emit_blocked_summary" "guardrails runbook should not expose prep-script internal helper names"
    assert_not_contains "$content" "emit_proposal_summary" "guardrails runbook should not expose prep-script internal helper names"
}

test_infra_bundle_uses_staging_evidence_as_current_status_authority() {
    local content
    content="$(read_doc "$INFRA_BUNDLE_DOC")"

    assert_contains "$content" "docs/runbooks/staging-evidence.md" "infra evidence bundle should point current blocker status readers to staging-evidence.md"
    assert_contains "$content" "canonical blocker-status document" "infra evidence bundle should explicitly declare staging-evidence.md as canonical blocker-status authority"
    assert_not_contains "$content" "cert is PENDING_VALIDATION" "infra evidence bundle should not duplicate stale unresolved ACM blocker text"
    assert_not_contains "$content" "ALB HTTPS listener on 443" "infra evidence bundle should not duplicate stale unresolved ALB blocker text"
    assert_not_contains "$content" "| ACM cert ISSUED | DEFERRED |" "infra evidence bundle should not keep stale deferred ACM status rows"
    assert_not_contains "$content" "| ALB HTTPS listener (443) | DEFERRED |" "infra evidence bundle should not keep stale deferred ALB status rows"
    assert_not_contains "$content" "| Target group healthy | DEFERRED |" "infra evidence bundle should not keep stale deferred target-group rows"
    assert_not_contains "$content" "| Health endpoint 200 | DEFERRED |" "infra evidence bundle should not keep stale deferred public-health rows"
}

test_safety_contract_is_documented() {
    local all_docs
    all_docs="$(read_all_docs)"

    assert_contains "$all_docs" "non-mutating" "runbooks should document non-mutating default mode"
    assert_contains "$all_docs" "blocked" "runbooks should document blocked verdict semantics"
    assert_contains "$all_docs" 'exits `0`' "runbooks should document blocked runs exiting 0"
    assert_contains "$all_docs" "--run-billing-rehearsal --month <YYYY-MM> --confirm-live-mutation" "runbooks should document full paid billing opt-in gate"
}

test_summary_json_lane_contract_and_blocked_semantics_are_documented() {
    local content
    content="$(read_doc "$GUARDRAILS_DOC")"

    assert_contains "$content" '`checks` for runtime-smoke owner results' "guardrails runbook should describe checks lane ownership"
    assert_contains "$content" '`credentialed_checks` for optional billing rehearsal' "guardrails runbook should describe credentialed_checks lane ownership"
    assert_contains "$content" '`external_blockers` for caller/operator blockers' "guardrails runbook should describe external_blockers ownership"
    assert_contains "$content" "generated rerun commands are shell-escaped" "guardrails runbook should describe shell-escaped blocker remediation commands"
    assert_contains "$content" '`overall_verdict` values' "guardrails runbook should describe overall_verdict semantics"
    assert_contains "$content" 'blocked prerequisites exit `0`' "guardrails runbook should document blocked prerequisite exit semantics"
    assert_contains "$content" "do not imply launch readiness" "guardrails runbook should separate blocked wrapper output from readiness status"
    assert_contains "$content" 'blocked credentialed billing rows keep `artifact_path` empty' "guardrails runbook should document blocked credentialed artifact_path behavior"
}

test_docs_do_not_include_secret_like_values() {
    if grep -Eq "AKIA|sk_live|sk_test|whsec_" "$STAGING_EVIDENCE_DOC" "$GUARDRAILS_DOC" "$INFRA_BUNDLE_DOC"; then
        fail "runbooks should not contain secret-looking values"
    else
        pass "runbooks avoid secret-looking values"
    fi

    if grep -Eq "(^|[^A-Z0-9_])(AWS_[A-Z0-9_]*|CLOUDFLARE_[A-Z0-9_]*|STRIPE_[A-Z0-9_]*)=" "$STAGING_EVIDENCE_DOC" "$GUARDRAILS_DOC" "$INFRA_BUNDLE_DOC"; then
        fail "runbooks should not contain direct Cloudflare/AWS/Stripe env assignments"
    else
        pass "runbooks avoid Cloudflare/AWS/Stripe env assignments"
    fi
}

run_all_tests() {
    echo "=== live_e2e_evidence docs static tests ==="
    test_docs_exist
    if [ "$MISSING_REQUIRED_DOCS" -eq 1 ]; then
        run_test_summary
    fi
    test_wrapper_entrypoint_artifact_dir_and_summary_are_documented
    test_owner_script_boundary_is_preserved
    test_failed_run_artifact_follow_up_uses_wrapper_run_dir
    test_budget_guardrail_prep_artifact_contract_is_documented
    test_infra_bundle_uses_staging_evidence_as_current_status_authority
    test_safety_contract_is_documented
    test_summary_json_lane_contract_and_blocked_semantics_are_documented
    test_docs_do_not_include_secret_like_values
    run_test_summary
}

run_all_tests
