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

read_stage7_runtime_wrapper_rerun_block() {
    awk '
        $0 == "## Current External Blockers" {
            in_external_blockers = 1
            next
        }
        in_external_blockers && /^## / {
            exit
        }
        in_external_blockers && /^- Latest Stage 7 runtime wrapper rerun artifact:/ {
            in_runtime_block = 1
        }
        in_runtime_block && /^- / && $0 !~ /^- Latest Stage 7 runtime wrapper rerun artifact:/ {
            exit
        }
        in_runtime_block {
            print
        }
    ' "$STAGING_EVIDENCE_DOC"
}

contains_private_local_evidence_path() {
    local content="$1"
    local private_evidence_path_regex

    private_evidence_path_regex='(^|[^A-Za-z0-9_.-])(/Users|/private/tmp|/tmp|/var/folders|/private/var)/[^[:space:]`]*[^[:space:]`/]'
    printf '%s\n' "$content" |
        grep -Eq "$private_evidence_path_regex"
}

assert_no_private_local_evidence_paths() {
    local content="$1" msg="$2"

    if contains_private_local_evidence_path "$content"; then
        fail "$msg (found private local evidence or artifact path)"
    else
        pass "$msg"
    fi
}

assert_contains_private_local_evidence_path() {
    local content="$1" msg="$2"

    if contains_private_local_evidence_path "$content"; then
        pass "$msg"
    else
        fail "$msg"
    fi
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

test_staging_evidence_tracks_current_runtime_rerun_boundary() {
    local runtime_block
    runtime_block="$(read_stage7_runtime_wrapper_rerun_block)"

    assert_contains "$runtime_block" "Latest Stage 7 runtime wrapper rerun artifact" "staging-evidence should keep a Stage 7 runtime wrapper rerun block"
    if [[ "$runtime_block" == *"docs/runbooks/evidence/"* ]]; then
        pass "Stage 7 runtime wrapper rerun block cites a checked-in evidence root"
    elif [[ "$runtime_block" == *"pending owner artifact"* ]]; then
        pass "Stage 7 runtime wrapper rerun block marks missing current-state evidence as pending owner artifact"
    else
        fail "Stage 7 runtime wrapper rerun block should cite checked-in evidence or pending owner artifact handling"
    fi
    assert_contains "$runtime_block" "ops/terraform/tests_stage7_runtime_smoke.sh" "Stage 7 runtime wrapper rerun block should keep the delegated runtime owner command explicit"
    assert_contains "$runtime_block" "historical runtime-smoke failure context" "Stage 7 runtime wrapper rerun block should classify preserved runtime artifacts as historical"
    assert_contains "$runtime_block" "via \`scripts/launch/live_e2e_evidence.sh\`" "Stage 7 runtime wrapper rerun block should keep the wrapper boundary explicit"
    assert_no_private_local_evidence_paths "$runtime_block" "Stage 7 runtime wrapper rerun block should not rely on private temp artifact paths"
}

test_private_local_evidence_path_guard_is_generic() {
    local bare_prefix_prose checked_in_path future_tmp_json_path future_tmp_log_path future_tmp_md_path future_tmp_out_path future_tmp_path future_tmp_summary_path future_tmp_transcript_path future_tmp_tsv_path future_users_log_path future_users_md_path future_users_path future_users_transcript_path guardrails_path infra_bundle_path markdown_link_path assignment_path json_quoted_path angle_bracket_path retired_path var_folders_transcript_path
    retired_path="Historical evidence: /Users/stuart/.matt/projects/fjcloud_dev-17570fdc/live_e2e_runtime_rerun_artifacts/run/summary.json"
    future_users_path="Current evidence: /Users/stuart/.matt/projects/fjcloud_dev-new/live_e2e_runtime_rerun_artifacts/run/summary.json"
    future_users_log_path="Current runtime log: /Users/stuart/logs/runtime_smoke.log"
    future_users_transcript_path="Current runtime transcript: /Users/stuart/logs/runtime_smoke.txt"
    future_tmp_path="Current evidence: /private/tmp/fjcloud/live_e2e_artifacts/run/summary.json"
    future_tmp_summary_path="Current evidence: /tmp/run42/summary.json"
    future_tmp_json_path="Current runtime payload: /tmp/run42/runtime_snapshot_recheck.json"
    future_tmp_log_path="Current runtime log: /tmp/run42/runtime_smoke.log"
    future_tmp_transcript_path="Current runtime transcript: /tmp/run42/53_runtime_snapshot_recheck.txt"
    future_tmp_tsv_path="Current runtime table: /tmp/run42/runtime_snapshot_recheck.tsv"
    future_tmp_out_path="Current runtime output: /tmp/run42/current_runtime_snapshot.out"
    future_tmp_md_path="Current runtime notes: /tmp/run42/runtime_snapshot_recheck.md"
    future_users_md_path="Current runtime notes: /Users/stuart/logs/runtime_smoke.md"
    guardrails_path="Guardrails evidence: /tmp/fjcloud/aws_live_e2e_guardrails/live_e2e_artifacts/run/summary.json"
    infra_bundle_path="Infra bundle evidence: /var/folders/fjcloud/infra-evidence-bundle/artifact_logs/summary.json"
    var_folders_transcript_path="Infra bundle transcript: /var/folders/fjcloud/current_runtime_snapshot.txt"
    markdown_link_path="Runtime artifact: [artifact](/tmp/run42/runtime_snapshot_recheck.txt)"
    assignment_path="path=/tmp/run42/runtime_snapshot_recheck.txt"
    json_quoted_path='Runtime payload: "path":"/tmp/run42/runtime_snapshot_recheck.json"'
    angle_bracket_path="See </Users/stuart/logs/runtime_smoke.log>"
    bare_prefix_prose="The retired live_e2e_runtime_rerun_artifacts prefix is historical context, not current evidence."
    checked_in_path="Current evidence: docs/runbooks/evidence/ses-deliverability/example/summary.json"

    assert_contains_private_local_evidence_path "$retired_path" "private-path guard rejects the retired runtime rerun artifact prefix"

    assert_contains_private_local_evidence_path "$future_users_path" "private-path guard rejects future /Users runtime rerun artifact paths"

    assert_contains_private_local_evidence_path "$future_users_log_path" "private-path guard rejects generic /Users runtime log paths"

    assert_contains_private_local_evidence_path "$future_users_transcript_path" "private-path guard rejects generic /Users runtime transcript paths"

    assert_contains_private_local_evidence_path "$future_tmp_path" "private-path guard rejects future temp live_e2e artifact paths"

    assert_contains_private_local_evidence_path "$future_tmp_summary_path" "private-path guard rejects generic /tmp summary paths"

    assert_contains_private_local_evidence_path "$future_tmp_json_path" "private-path guard rejects generic /tmp JSON evidence paths"

    assert_contains_private_local_evidence_path "$future_tmp_log_path" "private-path guard rejects generic /tmp runtime log paths"

    assert_contains_private_local_evidence_path "$future_tmp_transcript_path" "private-path guard rejects generic /tmp runtime transcript paths"

    assert_contains_private_local_evidence_path "$future_tmp_tsv_path" "private-path guard rejects generic /tmp TSV artifact paths"

    assert_contains_private_local_evidence_path "$future_tmp_out_path" "private-path guard rejects generic /tmp output artifact paths"

    assert_contains_private_local_evidence_path "$future_tmp_md_path" "private-path guard rejects generic /tmp markdown artifact paths"

    assert_contains_private_local_evidence_path "$future_users_md_path" "private-path guard rejects generic /Users markdown artifact paths"

    assert_contains_private_local_evidence_path "$guardrails_path" "private-path guard rejects local guardrails runbook artifact paths"

    assert_contains_private_local_evidence_path "$infra_bundle_path" "private-path guard rejects local infra bundle evidence paths"

    assert_contains_private_local_evidence_path "$var_folders_transcript_path" "private-path guard rejects generic /var/folders transcript paths"

    assert_contains_private_local_evidence_path "$markdown_link_path" "private-path guard rejects markdown-link-delimited private paths"

    assert_contains_private_local_evidence_path "$assignment_path" "private-path guard rejects assignment-style private paths"

    assert_contains_private_local_evidence_path "$json_quoted_path" "private-path guard rejects JSON-quoted private paths"

    assert_contains_private_local_evidence_path "$angle_bracket_path" "private-path guard rejects angle-bracket-delimited private paths"

    if contains_private_local_evidence_path "$checked_in_path"; then
        fail "private-path guard should allow checked-in evidence roots"
    else
        pass "private-path guard allows checked-in evidence roots"
    fi

    if contains_private_local_evidence_path "$bare_prefix_prose"; then
        fail "private-path guard should allow bare retired-prefix prose"
    else
        pass "private-path guard allows bare retired-prefix prose"
    fi
}

test_runbooks_do_not_include_private_local_evidence_paths() {
    local doc content
    for doc in "${DOC_FILES[@]}"; do
        content="$(read_doc "$doc")"
        assert_no_private_local_evidence_paths "$content" "$(basename "$doc") should not rely on private temp artifact paths"
    done
}

test_budget_guardrail_prep_artifact_contract_is_documented() {
    local content
    content="$(read_doc "$GUARDRAILS_DOC")"

    assert_contains "$content" '`$20/day` means `$600/month`' 'guardrails runbook should document monthly-equivalent $20/day interpretation'
    assert_contains "$content" "strict calendar-day enforcement is not implemented" "guardrails runbook should document that strict calendar-day enforcement is not implemented"
    assert_contains "$content" "proposal_ready" "guardrails runbook should describe proposal_ready prep status"
    assert_contains "$content" '`blocked`' "guardrails runbook should document blocked prep status explicitly"
    assert_contains "$content" "--budget-guardrail-artifact" "guardrails runbook should document validate_all --budget-guardrail-artifact entrypoint"
    assert_contains "$content" "proposal.auto.tfvars.example" "guardrails runbook should document proposal var-file artifact"
    assert_contains "$content" "terraform_plan_command.txt" "guardrails runbook should document plan command artifact"
    assert_contains "$content" "missing_fields" "guardrails runbook should document blocked missing_fields reporting"
    assert_contains "$content" "missing_flags" "guardrails runbook should document blocked missing_flags reporting"
    assert_contains "$content" "plan_command" "guardrails runbook should document blocked omission of plan_command payload"
    assert_contains "$content" "proposed_variables" "guardrails runbook should document blocked omission of proposed_variables payload"
    assert_contains "$content" "omits" "guardrails runbook should explicitly call out blocked-artifact omission semantics"
    assert_contains "$content" "api_instance_id" "guardrails runbook should list blocked api_instance_id requirement"
    assert_contains "$content" "db_instance_identifier" "guardrails runbook should list blocked db_instance_identifier requirement"
    assert_contains "$content" "alb_arn_suffix" "guardrails runbook should list blocked alb_arn_suffix requirement"
    assert_contains "$content" "live_e2e_budget_action_principal_arn" "guardrails runbook should list blocked budget action principal requirement"
    assert_contains "$content" "live_e2e_budget_action_policy_arn" "guardrails runbook should list blocked budget action policy requirement"
    assert_contains "$content" "live_e2e_budget_action_role_name" "guardrails runbook should list blocked budget action role requirement"
    assert_contains "$content" "live_e2e_budget_action_execution_role_arn" "guardrails runbook should list blocked budget action execution role requirement"
    assert_contains "$content" "--api-instance-id" "guardrails runbook should list blocked --api-instance-id flag"
    assert_contains "$content" "--db-instance-identifier" "guardrails runbook should list blocked --db-instance-identifier flag"
    assert_contains "$content" "--alb-arn-suffix" "guardrails runbook should list blocked --alb-arn-suffix flag"
    assert_contains "$content" "--budget-action-principal-arn" "guardrails runbook should list blocked --budget-action-principal-arn flag"
    assert_contains "$content" "--budget-action-policy-arn" "guardrails runbook should list blocked --budget-action-policy-arn flag"
    assert_contains "$content" "--budget-action-role-name" "guardrails runbook should list blocked --budget-action-role-name flag"
    assert_contains "$content" "--budget-action-execution-role-arn" "guardrails runbook should list blocked --budget-action-execution-role-arn flag"
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

test_runbooks_use_repo_local_secret_file_contract() {
    local doc content
    for doc in "${DOC_FILES[@]}"; do
        content="$(read_doc "$doc")"
        assert_contains "$content" ".secret/.env.secret" "$(basename "$doc") should document the repo-local secret file contract"
        assert_not_contains "$content" "/Users/stuart/repos/gridl/fjcloud/.secret/.env.secret" "$(basename "$doc") should not keep the deprecated shared absolute secret path"
    done
}

test_docs_do_not_include_secret_like_values() {
    if grep -Eq "AKIA|sk_live|sk_test|whsec_" "$STAGING_EVIDENCE_DOC" "$GUARDRAILS_DOC" "$INFRA_BUNDLE_DOC"; then
        fail "runbooks should not contain secret-looking values"
    else
        pass "runbooks avoid secret-looking values"
    fi

    if grep -Eq "arn:aws:iam::[0-9]{12}" "$GUARDRAILS_DOC"; then
        fail "guardrails runbook should not contain private IAM account IDs"
    else
        pass "guardrails runbook avoids private IAM account IDs"
    fi

    if grep -Eq "(^|[^0-9])[0-9]{12}([^0-9]|$)" "$GUARDRAILS_DOC"; then
        fail "guardrails runbook should not contain private 12-digit account identifiers"
    else
        pass "guardrails runbook avoids private 12-digit account identifiers"
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
    test_staging_evidence_tracks_current_runtime_rerun_boundary
    test_private_local_evidence_path_guard_is_generic
    test_runbooks_do_not_include_private_local_evidence_paths
    test_budget_guardrail_prep_artifact_contract_is_documented
    test_infra_bundle_uses_staging_evidence_as_current_status_authority
    test_safety_contract_is_documented
    test_summary_json_lane_contract_and_blocked_semantics_are_documented
    test_runbooks_use_repo_local_secret_file_contract
    test_docs_do_not_include_secret_like_values
    run_test_summary
}

run_all_tests
