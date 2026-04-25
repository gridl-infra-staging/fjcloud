#!/usr/bin/env bash
# Red-first contract tests for ops/scripts/live_e2e_budget_guardrail_prep.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PREP_SCRIPT="$REPO_ROOT/ops/scripts/live_e2e_budget_guardrail_prep.sh"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/live_e2e_budget_guardrail_prep_harness.sh
source "$SCRIPT_DIR/lib/live_e2e_budget_guardrail_prep_harness.sh"

RUN_STDOUT=""
RUN_STDERR=""
RUN_EXIT_CODE=0
TEST_WORKSPACE=""
TEST_CALL_LOG=""
AWS_LOG=""
TERRAFORM_LOG=""
CLEANUP_DIRS=()
VALID_BUDGET_PRINCIPAL_ARN="arn:aws:iam::123456789012:user/live-e2e-budget-approver"
VALID_BUDGET_POLICY_ARN="arn:aws:iam::123456789012:policy/live-e2e-budget-policy"
VALID_BUDGET_ROLE_NAME="live-e2e-budget-target-role"
VALID_BUDGET_EXECUTION_ROLE_ARN="arn:aws:iam::123456789012:role/live-e2e-budget-execution"

cleanup_test_workspaces() {
    local d
    for d in "${CLEANUP_DIRS[@]:-}"; do
        [ -n "$d" ] && rm -rf "$d"
    done
}
trap cleanup_test_workspaces EXIT

test_script_exists_and_executable() {
    local exists="no"
    local executable="no"
    [ -f "$PREP_SCRIPT" ] && exists="yes"
    [ -x "$PREP_SCRIPT" ] && executable="yes"
    assert_eq "$exists" "yes" "live_e2e_budget_guardrail_prep.sh should exist"
    assert_eq "$executable" "yes" "live_e2e_budget_guardrail_prep.sh should be executable"
}

test_help_exits_zero_without_creating_artifacts() {
    require_budget_guardrail_script_for_contract "help contract" || return 0
    setup_workspace
    _run_budget_guardrail_prep --args "--help --artifact-dir $TEST_WORKSPACE/artifacts"
    assert_eq "$RUN_EXIT_CODE" "0" "--help should exit 0"
    assert_contains "$(printf '%s\n%s' "$RUN_STDOUT" "$RUN_STDERR")" "Usage:" "--help should print usage text"
    assert_eq "$(run_artifact_dir_count "$TEST_WORKSPACE/artifacts")" "0" "--help should not create run artifact directories"
}

test_cli_parse_failures_exit_2_and_emit_no_stdout_json() {
    require_budget_guardrail_script_for_contract "CLI parse contract" || return 0

    assert_cli_invalid_contract "missing --env" \
        "--artifact-dir \$TEST_WORKSPACE/artifacts" \
        "--env"

    assert_cli_invalid_contract "invalid --env value" \
        "--env qa --artifact-dir \$TEST_WORKSPACE/artifacts" \
        "--env"

    assert_cli_invalid_contract "missing --artifact-dir" \
        "--env staging" \
        "--artifact-dir"

    assert_cli_invalid_contract "missing value for --env" \
        "--env --artifact-dir \$TEST_WORKSPACE/artifacts" \
        "--env"

    assert_cli_invalid_contract "missing value for --artifact-dir" \
        "--env staging --artifact-dir" \
        "--artifact-dir"

    assert_cli_invalid_contract "unknown argument" \
        "--env staging --artifact-dir \$TEST_WORKSPACE/artifacts --unknown-flag" \
        "--unknown-flag"
}

test_invalid_operator_inputs_fail_closed_without_proposal_or_terraform() {
    require_budget_guardrail_script_for_contract "invalid-value contract" || return 0

    assert_invalid_value_fails_closed "nonpositive monthly spend limit" \
        "--monthly-spend-limit-usd" \
        --env staging --region us-east-1 --artifact-dir "\$TEST_WORKSPACE/artifacts" \
        --monthly-spend-limit-usd 0 \
        --budget-action-principal-arn "$VALID_BUDGET_PRINCIPAL_ARN" \
        --budget-action-policy-arn "$VALID_BUDGET_POLICY_ARN" \
        --budget-action-role-name "$VALID_BUDGET_ROLE_NAME" \
        --budget-action-execution-role-arn "$VALID_BUDGET_EXECUTION_ROLE_ARN"

    assert_invalid_value_fails_closed "malformed principal ARN" \
        "--budget-action-principal-arn" \
        --env staging --region us-east-1 --artifact-dir "\$TEST_WORKSPACE/artifacts" \
        --monthly-spend-limit-usd 123.45 \
        --budget-action-principal-arn malformed-principal \
        --budget-action-policy-arn "$VALID_BUDGET_POLICY_ARN" \
        --budget-action-role-name "$VALID_BUDGET_ROLE_NAME" \
        --budget-action-execution-role-arn "$VALID_BUDGET_EXECUTION_ROLE_ARN"

    assert_invalid_value_fails_closed "malformed policy ARN" \
        "--budget-action-policy-arn" \
        --env staging --region us-east-1 --artifact-dir "\$TEST_WORKSPACE/artifacts" \
        --monthly-spend-limit-usd 123.45 \
        --budget-action-principal-arn "$VALID_BUDGET_PRINCIPAL_ARN" \
        --budget-action-policy-arn malformed-policy \
        --budget-action-role-name "$VALID_BUDGET_ROLE_NAME" \
        --budget-action-execution-role-arn "$VALID_BUDGET_EXECUTION_ROLE_ARN"

    assert_invalid_value_fails_closed "malformed execution-role ARN" \
        "--budget-action-execution-role-arn" \
        --env staging --region us-east-1 --artifact-dir "\$TEST_WORKSPACE/artifacts" \
        --monthly-spend-limit-usd 123.45 \
        --budget-action-principal-arn "$VALID_BUDGET_PRINCIPAL_ARN" \
        --budget-action-policy-arn "$VALID_BUDGET_POLICY_ARN" \
        --budget-action-role-name "$VALID_BUDGET_ROLE_NAME" \
        --budget-action-execution-role-arn malformed-execution

    assert_invalid_value_fails_closed "terraform-invalid role name" \
        "--budget-action-role-name" \
        --env staging --region us-east-1 --artifact-dir "\$TEST_WORKSPACE/artifacts" \
        --monthly-spend-limit-usd 123.45 \
        --budget-action-principal-arn "$VALID_BUDGET_PRINCIPAL_ARN" \
        --budget-action-policy-arn "$VALID_BUDGET_POLICY_ARN" \
        --budget-action-role-name invalid/role/name \
        --budget-action-execution-role-arn "$VALID_BUDGET_EXECUTION_ROLE_ARN"

    assert_invalid_value_fails_closed "empty role name" \
        "--budget-action-role-name" \
        --env staging --region us-east-1 --artifact-dir "\$TEST_WORKSPACE/artifacts" \
        --monthly-spend-limit-usd 123.45 \
        --budget-action-principal-arn "$VALID_BUDGET_PRINCIPAL_ARN" \
        --budget-action-policy-arn "$VALID_BUDGET_POLICY_ARN" \
        --budget-action-role-name "" \
        --budget-action-execution-role-arn "$VALID_BUDGET_EXECUTION_ROLE_ARN"
}

test_enable_action_missing_operator_inputs_fail_closed_without_proposal_or_terraform() {
    require_budget_guardrail_script_for_contract "enable-action omission contract" || return 0

    assert_invalid_value_fails_closed "enable-action proposal missing principal ARN" \
        "--budget-action-principal-arn" \
        --env staging --region us-east-1 --artifact-dir "\$TEST_WORKSPACE/artifacts" \
        --monthly-spend-limit-usd 99 \
        --budget-action-policy-arn "$VALID_BUDGET_POLICY_ARN" \
        --budget-action-role-name "$VALID_BUDGET_ROLE_NAME" \
        --budget-action-execution-role-arn "$VALID_BUDGET_EXECUTION_ROLE_ARN" \
        --enable-action-proposal

    assert_invalid_value_fails_closed "enable-action proposal missing policy ARN" \
        "--budget-action-policy-arn" \
        --env staging --region us-east-1 --artifact-dir "\$TEST_WORKSPACE/artifacts" \
        --monthly-spend-limit-usd 99 \
        --budget-action-principal-arn "$VALID_BUDGET_PRINCIPAL_ARN" \
        --budget-action-role-name "$VALID_BUDGET_ROLE_NAME" \
        --budget-action-execution-role-arn "$VALID_BUDGET_EXECUTION_ROLE_ARN" \
        --enable-action-proposal

    assert_invalid_value_fails_closed "enable-action proposal missing role name" \
        "--budget-action-role-name" \
        --env staging --region us-east-1 --artifact-dir "\$TEST_WORKSPACE/artifacts" \
        --monthly-spend-limit-usd 99 \
        --budget-action-principal-arn "$VALID_BUDGET_PRINCIPAL_ARN" \
        --budget-action-policy-arn "$VALID_BUDGET_POLICY_ARN" \
        --budget-action-execution-role-arn "$VALID_BUDGET_EXECUTION_ROLE_ARN" \
        --enable-action-proposal

    assert_invalid_value_fails_closed "enable-action proposal missing execution-role ARN" \
        "--budget-action-execution-role-arn" \
        --env staging --region us-east-1 --artifact-dir "\$TEST_WORKSPACE/artifacts" \
        --monthly-spend-limit-usd 99 \
        --budget-action-principal-arn "$VALID_BUDGET_PRINCIPAL_ARN" \
        --budget-action-policy-arn "$VALID_BUDGET_POLICY_ARN" \
        --budget-action-role-name "$VALID_BUDGET_ROLE_NAME" \
        --enable-action-proposal

    assert_invalid_value_fails_closed "enable-action proposal with missing action inputs" \
        "--enable-action-proposal" \
        --env staging --region us-east-1 --artifact-dir "\$TEST_WORKSPACE/artifacts" \
        --monthly-spend-limit-usd 99 --enable-action-proposal
}

test_mock_aws_parser_handles_global_options_before_service() {
    setup_workspace
    local output
    output="$("$TEST_WORKSPACE/bin/aws" --region us-east-1 --no-cli-pager sts get-caller-identity)"
    assert_contains "$output" "\"Account\":\"123456789012\"" "mock aws parser should ignore global option values before service token"
    assert_not_contains "$output" "\"mock\":\"aws\"" "mock aws parser should not fall back to generic payload for valid sts discovery"
}

test_primary_blocked_input_reports_exact_missing_fields() {
    require_budget_guardrail_script_for_contract "blocked-input contract" || return 0
    setup_workspace
    _run_budget_guardrail_prep --args "--env staging --region us-east-1 --artifact-dir $TEST_WORKSPACE/artifacts"

    assert_eq "$RUN_EXIT_CODE" "0" "missing operator-owned budget inputs should exit 0 as blocked"
    assert_valid_json "$RUN_STDOUT" "blocked run should emit valid JSON"

    local run_dir
    run_dir="$(find_run_artifact_dir "$TEST_WORKSPACE/artifacts")"
    if [ -n "$run_dir" ]; then
        pass "blocked run should create run-scoped artifact directory"
    else
        fail "blocked run should create run-scoped artifact directory"
    fi

    assert_status_and_summary_match "$RUN_STDOUT" "$run_dir" "blocked"
    assert_missing_fields_exact "$RUN_STDOUT" \
        "api_instance_id" \
        "alb_arn_suffix" \
        "db_instance_identifier" \
        "live_e2e_monthly_spend_limit_usd" \
        "live_e2e_budget_action_principal_arn" \
        "live_e2e_budget_action_policy_arn" \
        "live_e2e_budget_action_role_name" \
        "live_e2e_budget_action_execution_role_arn"
    assert_missing_flags_exact "$RUN_STDOUT" \
        "--api-instance-id" \
        "--alb-arn-suffix" \
        "--db-instance-identifier" \
        "--monthly-spend-limit-usd" \
        "--budget-action-principal-arn" \
        "--budget-action-policy-arn" \
        "--budget-action-role-name" \
        "--budget-action-execution-role-arn"
    assert_blocked_artifact_contract "$RUN_STDOUT" "$run_dir"
    assert_plan_command_absent "$run_dir"
    assert_no_terraform_calls
}

test_partial_input_blocked_list_is_precise_and_contains_no_placeholders() {
    require_budget_guardrail_script_for_contract "partial-input contract" || return 0
    setup_workspace
    _run_budget_guardrail_prep --args "--env staging --region us-east-1 --artifact-dir $TEST_WORKSPACE/artifacts \
--monthly-spend-limit-usd 150.00 \
--budget-action-principal-arn arn:aws:iam::123456789012:user/live-e2e-budget-approver"

    assert_eq "$RUN_EXIT_CODE" "0" "partial operator inputs should remain blocked"
    assert_valid_json "$RUN_STDOUT" "partial-input blocked run should emit valid JSON"

    local run_dir
    run_dir="$(find_run_artifact_dir "$TEST_WORKSPACE/artifacts")"
    if [ -n "$run_dir" ]; then
        pass "partial-input blocked run should create run-scoped artifact directory"
    else
        fail "partial-input blocked run should create run-scoped artifact directory"
    fi
    assert_status_and_summary_match "$RUN_STDOUT" "$run_dir" "blocked"
    assert_eq "$(json_field "$RUN_STDOUT" "status")" "blocked" "partial input run should report blocked status"
    assert_missing_fields_exact "$RUN_STDOUT" \
        "api_instance_id" \
        "alb_arn_suffix" \
        "db_instance_identifier" \
        "live_e2e_budget_action_execution_role_arn" \
        "live_e2e_budget_action_policy_arn" \
        "live_e2e_budget_action_role_name"
    assert_missing_flags_exact "$RUN_STDOUT" \
        "--api-instance-id" \
        "--alb-arn-suffix" \
        "--db-instance-identifier" \
        "--budget-action-execution-role-arn" \
        "--budget-action-policy-arn" \
        "--budget-action-role-name"
    assert_blocked_artifact_contract "$RUN_STDOUT" "$run_dir"
    assert_plan_command_absent "$run_dir"
    assert_no_proposal_placeholder_values "$RUN_STDOUT" "$run_dir"
    assert_no_terraform_calls
    assert_no_owner_or_delegated_script_calls
}

test_discovery_backed_proposal_generation_includes_monitoring_inputs() {
    require_budget_guardrail_script_for_contract "discovery-backed proposal contract" || return 0
    setup_workspace

    local principal_arn policy_arn role_name execution_role_arn spend_limit expected_api expected_db expected_alb run_dir
    principal_arn="arn:aws:iam::123456789012:user/live-e2e-budget-approver"
    policy_arn="arn:aws:iam::123456789012:policy/live-e2e-budget-policy"
    role_name="live-e2e-budget-target-role"
    execution_role_arn="arn:aws:iam::123456789012:role/live-e2e-budget-execution"
    spend_limit="245.50"
    expected_api="$(mock_discovery_value "staging" "api_instance_id")"
    expected_db="$(mock_discovery_value "staging" "db_instance_identifier")"
    expected_alb="$(mock_discovery_value "staging" "alb_arn_suffix")"

    _run_budget_guardrail_prep --args "--env staging --region us-east-1 --artifact-dir $TEST_WORKSPACE/artifacts \
--monthly-spend-limit-usd $spend_limit \
--budget-action-principal-arn $principal_arn \
--budget-action-policy-arn $policy_arn \
--budget-action-role-name $role_name \
--budget-action-execution-role-arn $execution_role_arn"

    assert_eq "$RUN_EXIT_CODE" "0" "complete operator inputs plus resolvable monitoring discovery should build proposal artifact"
    assert_valid_json "$RUN_STDOUT" "discovery-backed run should emit valid JSON"
    assert_eq "$(json_field "$RUN_STDOUT" "status")" "proposal_ready" "discovery-backed run should report proposal_ready status"
    assert_eq "$(json_field "$RUN_STDOUT" "terraform_module")" "ops/terraform/monitoring" "proposal should target monitoring terraform module"

    run_dir="$(find_run_artifact_dir "$TEST_WORKSPACE/artifacts")"
    assert_status_and_summary_match "$RUN_STDOUT" "$run_dir" "proposal_ready"
    assert_plan_command_contract "$RUN_STDOUT" "$run_dir"
    assert_proposal_variables_contract "$RUN_STDOUT" "$run_dir" "false" \
        "$principal_arn" "$policy_arn" "$role_name" "$execution_role_arn" "$spend_limit" \
        "staging" "us-east-1" "$expected_api" "$expected_db" "$expected_alb"
    assert_no_terraform_calls
}

test_monthly_equivalent_600_proposal_keeps_single_budget_limit_surface() {
    require_budget_guardrail_script_for_contract "monthly-equivalent budget proposal contract" || return 0
    setup_workspace

    local principal_arn policy_arn role_name execution_role_arn spend_limit expected_api expected_db expected_alb run_dir summary_payload proposal_path
    principal_arn="arn:aws:iam::123456789012:user/live-e2e-budget-approver"
    policy_arn="arn:aws:iam::123456789012:policy/live-e2e-budget-policy"
    role_name="live-e2e-budget-target-role"
    execution_role_arn="arn:aws:iam::123456789012:role/live-e2e-budget-execution"
    spend_limit="600"
    expected_api="$(mock_discovery_value "staging" "api_instance_id")"
    expected_db="$(mock_discovery_value "staging" "db_instance_identifier")"
    expected_alb="$(mock_discovery_value "staging" "alb_arn_suffix")"

    _run_budget_guardrail_prep --args "--env staging --region us-east-1 --artifact-dir $TEST_WORKSPACE/artifacts \
--monthly-spend-limit-usd $spend_limit \
--budget-action-principal-arn $principal_arn \
--budget-action-policy-arn $policy_arn \
--budget-action-role-name $role_name \
--budget-action-execution-role-arn $execution_role_arn"

    assert_eq "$RUN_EXIT_CODE" "0" "monthly-equivalent 600 input should produce proposal artifact"
    assert_valid_json "$RUN_STDOUT" "monthly-equivalent proposal run should emit valid JSON"
    assert_eq "$(json_field "$RUN_STDOUT" "status")" "proposal_ready" "monthly-equivalent proposal run should report proposal_ready status"

    run_dir="$(find_run_artifact_dir "$TEST_WORKSPACE/artifacts")"
    summary_payload="$(read_file_or_empty "$run_dir/summary.json")"
    proposal_path="$run_dir/proposal.auto.tfvars.example"
    assert_status_and_summary_match "$RUN_STDOUT" "$run_dir" "proposal_ready"
    assert_proposal_variables_contract "$RUN_STDOUT" "$run_dir" "false" \
        "$principal_arn" "$policy_arn" "$role_name" "$execution_role_arn" "$spend_limit" \
        "staging" "us-east-1" "$expected_api" "$expected_db" "$expected_alb"

    if python3 - "$summary_payload" "$proposal_path" <<'PY'
import json
import pathlib
import re
import sys

summary = json.loads(sys.argv[1])
proposal_path = pathlib.Path(sys.argv[2])
proposed = summary.get("proposed_variables")
if not isinstance(proposed, dict):
    raise SystemExit(1)

spend_keys = sorted([k for k in proposed.keys() if "spend_limit_usd" in k])
if spend_keys != ["live_e2e_monthly_spend_limit_usd"]:
    raise SystemExit(2)
if float(proposed.get("live_e2e_monthly_spend_limit_usd")) != 600.0:
    raise SystemExit(3)
if proposed.get("live_e2e_budget_action_enabled") is not False:
    raise SystemExit(4)

text = proposal_path.read_text(encoding="utf-8")
file_spend_keys = re.findall(r'(?m)^\s*(live_e2e_[A-Za-z0-9_]*spend_limit_usd)\s*=', text)
if file_spend_keys != ["live_e2e_monthly_spend_limit_usd"]:
    raise SystemExit(5)
if len(re.findall(r'(?m)^\s*live_e2e_budget_action_enabled\s*=\s*false\s*$', text)) != 1:
    raise SystemExit(6)
PY
    then
        pass "monthly-equivalent proposal emits only live_e2e_monthly_spend_limit_usd and keeps live_e2e_budget_action_enabled false without --enable-action-proposal"
    else
        fail "monthly-equivalent proposal emits only live_e2e_monthly_spend_limit_usd and keeps live_e2e_budget_action_enabled false without --enable-action-proposal"
    fi
    assert_no_terraform_calls
}

test_first_proposal_does_not_require_existing_budget() {
    require_budget_guardrail_script_for_contract "missing-budget proposal contract" || return 0
    setup_workspace

    local principal_arn policy_arn role_name execution_role_arn spend_limit expected_api expected_db expected_alb run_dir aws_calls
    principal_arn="arn:aws:iam::123456789012:user/live-e2e-budget-approver"
    policy_arn="arn:aws:iam::123456789012:policy/live-e2e-budget-policy"
    role_name="live-e2e-budget-target-role"
    execution_role_arn="arn:aws:iam::123456789012:role/live-e2e-budget-execution"
    spend_limit="245.50"
    expected_api="$(mock_discovery_value "staging" "api_instance_id")"
    expected_db="$(mock_discovery_value "staging" "db_instance_identifier")"
    expected_alb="$(mock_discovery_value "staging" "alb_arn_suffix")"

    _run_budget_guardrail_prep \
        "MOCK_AWS_BUDGET_MODE=missing" \
        --args "--env staging --region us-east-1 --artifact-dir $TEST_WORKSPACE/artifacts \
--monthly-spend-limit-usd $spend_limit \
--budget-action-principal-arn $principal_arn \
--budget-action-policy-arn $policy_arn \
--budget-action-role-name $role_name \
--budget-action-execution-role-arn $execution_role_arn"

    assert_eq "$RUN_EXIT_CODE" "0" "missing managed budget should not block first proposal generation"
    assert_valid_json "$RUN_STDOUT" "missing-budget run should emit valid JSON"
    assert_eq "$(json_field "$RUN_STDOUT" "status")" "proposal_ready" "missing-budget run should still report proposal_ready status"

    run_dir="$(find_run_artifact_dir "$TEST_WORKSPACE/artifacts")"
    assert_status_and_summary_match "$RUN_STDOUT" "$run_dir" "proposal_ready"
    assert_plan_command_contract "$RUN_STDOUT" "$run_dir"
    assert_proposal_variables_contract "$RUN_STDOUT" "$run_dir" "false" \
        "$principal_arn" "$policy_arn" "$role_name" "$execution_role_arn" "$spend_limit" \
        "staging" "us-east-1" "$expected_api" "$expected_db" "$expected_alb"
    aws_calls="$(read_file_or_empty "$AWS_LOG")"
    assert_not_contains "$aws_calls" "budgets describe-budget" "prep contract should not require a pre-existing managed budget"
    assert_no_terraform_calls
}

test_proposal_file_escapes_untrusted_string_values() {
    require_budget_guardrail_script_for_contract "proposal escaping contract" || return 0
    setup_workspace

    local injected_api run_dir proposal_path
    injected_api=$'i-safe"\nextra_injected = "boom'

    _run_budget_guardrail_prep_argv \
        --env staging \
        --region us-east-1 \
        --artifact-dir "$TEST_WORKSPACE/artifacts" \
        --monthly-spend-limit-usd 245.50 \
        --budget-action-principal-arn arn:aws:iam::123456789012:user/live-e2e-budget-approver \
        --budget-action-policy-arn arn:aws:iam::123456789012:policy/live-e2e-budget-policy \
        --budget-action-role-name live-e2e-budget-target-role \
        --budget-action-execution-role-arn arn:aws:iam::123456789012:role/live-e2e-budget-execution \
        --api-instance-id "$injected_api" \
        --db-instance-identifier fjcloud-staging \
        --alb-arn-suffix app/fjcloud-staging-alb/abcd1234efgh5678

    assert_eq "$RUN_EXIT_CODE" "0" "quoted or multiline operator inputs should still produce a proposal artifact"
    run_dir="$(find_run_artifact_dir "$TEST_WORKSPACE/artifacts")"
    proposal_path="$run_dir/proposal.auto.tfvars.example"
    assert_valid_json "$RUN_STDOUT" "escaped-input run should emit valid JSON"
    assert_status_and_summary_match "$RUN_STDOUT" "$run_dir" "proposal_ready"

    if python3 - "$proposal_path" "$RUN_STDOUT" "$injected_api" <<'PY'
import json
import pathlib
import re
import sys

proposal_path = pathlib.Path(sys.argv[1])
payload = json.loads(sys.argv[2])
injected_api = sys.argv[3]
text = proposal_path.read_text(encoding="utf-8")

if len(re.findall(r'(?m)^\s*api_instance_id\s*=', text)) != 1:
    raise SystemExit(1)
if len(re.findall(r'(?m)^\s*live_e2e_budget_action_enabled\s*=', text)) != 1:
    raise SystemExit(2)
if re.search(r'(?m)^\s*extra_injected\s*=', text):
    raise SystemExit(3)
if '\\nextra_injected = \\"boom' not in text:
    raise SystemExit(4)
if payload.get("proposed_variables", {}).get("api_instance_id") != injected_api:
    raise SystemExit(5)
PY
    then
        pass "proposal artifact should escape untrusted string values instead of emitting extra Terraform assignments"
    else
        fail "proposal artifact should escape untrusted string values instead of emitting extra Terraform assignments"
    fi
    assert_no_terraform_calls
}

test_missing_or_ambiguous_discovery_stays_blocked_without_plan_artifact() {
    require_budget_guardrail_script_for_contract "discovery-missing or ambiguous contract" || return 0
    setup_workspace

    local principal_arn policy_arn role_name execution_role_arn spend_limit run_dir
    principal_arn="arn:aws:iam::123456789012:user/live-e2e-budget-approver"
    policy_arn="arn:aws:iam::123456789012:policy/live-e2e-budget-policy"
    role_name="live-e2e-budget-target-role"
    execution_role_arn="arn:aws:iam::123456789012:role/live-e2e-budget-execution"
    spend_limit="320.00"

    _run_budget_guardrail_prep \
        "MOCK_AWS_EC2_MODE=ambiguous" \
        "MOCK_AWS_RDS_MODE=missing" \
        "MOCK_AWS_ALB_MODE=ambiguous" \
        --args "--env staging --region us-east-1 --artifact-dir $TEST_WORKSPACE/artifacts \
--monthly-spend-limit-usd $spend_limit \
--budget-action-principal-arn $principal_arn \
--budget-action-policy-arn $policy_arn \
--budget-action-role-name $role_name \
--budget-action-execution-role-arn $execution_role_arn \
--enable-action-proposal"

    assert_eq "$RUN_EXIT_CODE" "0" "ambiguous or missing monitoring discovery should return blocked summary"
    assert_valid_json "$RUN_STDOUT" "blocked discovery run should emit valid JSON"
    run_dir="$(find_run_artifact_dir "$TEST_WORKSPACE/artifacts")"
    assert_status_and_summary_match "$RUN_STDOUT" "$run_dir" "blocked"
    assert_missing_fields_exact "$RUN_STDOUT" \
        "api_instance_id" \
        "alb_arn_suffix" \
        "db_instance_identifier"
    assert_missing_flags_exact "$RUN_STDOUT" \
        "--api-instance-id" \
        "--alb-arn-suffix" \
        "--db-instance-identifier"
    assert_blocked_artifact_contract "$RUN_STDOUT" "$run_dir"
    assert_no_proposal_placeholder_values "$RUN_STDOUT" "$run_dir"
    assert_plan_command_absent "$run_dir"
    assert_no_terraform_calls
}

test_mocked_aws_discovery_commands_are_unattended_and_read_only() {
    require_budget_guardrail_script_for_contract "aws discovery command contract" || return 0
    setup_workspace

    _run_budget_guardrail_prep --args "--env staging --region us-east-1 --artifact-dir $TEST_WORKSPACE/artifacts \
--monthly-spend-limit-usd 125.00 \
--budget-action-principal-arn arn:aws:iam::123456789012:user/live-e2e-budget-approver \
--budget-action-policy-arn arn:aws:iam::123456789012:policy/live-e2e-budget-policy \
--budget-action-role-name live-e2e-budget-target-role \
--budget-action-execution-role-arn arn:aws:iam::123456789012:role/live-e2e-budget-execution \
--enable-action-proposal"

    assert_eq "$RUN_EXIT_CODE" "0" "proposal-ready run should succeed for aws-discovery assertions"
    assert_aws_calls_safe_and_read_only "us-east-1"
    assert_no_terraform_calls
}

test_redaction_and_artifact_permissions_contract() {
    require_budget_guardrail_script_for_contract "secret-redaction and permission contract" || return 0
    setup_workspace

    local original_umask run_dir summary_payload proposal_payload logs_payload
    original_umask="$(umask)"
    umask 022
    _run_budget_guardrail_prep \
        "AWS_SECRET_ACCESS_KEY=super-secret-contract-value" \
        "CLOUDFLARE_API_TOKEN=cf-secret-contract-value" \
        "STRIPE_SECRET_KEY=stripe-live-secret-contract-value" \
        "STRIPE_WEBHOOK_SECRET=stripe-webhook-secret-contract-value" \
        "MOCK_AWS_ECHO_SECRETS=1" \
        --args "--env staging --region us-east-1 --artifact-dir $TEST_WORKSPACE/artifacts \
--monthly-spend-limit-usd 410.25 \
--budget-action-principal-arn arn:aws:iam::123456789012:user/live-e2e-budget-approver \
--budget-action-policy-arn arn:aws:iam::123456789012:policy/live-e2e-budget-policy \
--budget-action-role-name live-e2e-budget-target-role \
--budget-action-execution-role-arn arn:aws:iam::123456789012:role/live-e2e-budget-execution \
--enable-action-proposal"
    umask "$original_umask"

    run_dir="$(find_run_artifact_dir "$TEST_WORKSPACE/artifacts")"
    summary_payload="$(read_file_or_empty "$run_dir/summary.json")"
    proposal_payload="$(read_file_or_empty "$run_dir/proposal.auto.tfvars.example")"
    logs_payload="$(cat "$run_dir"/logs/* 2>/dev/null || true)"

    assert_eq "$RUN_EXIT_CODE" "0" "redaction run should still complete as proposal_ready"
    assert_valid_json "$RUN_STDOUT" "redaction run should emit valid JSON"
    assert_status_and_summary_match "$RUN_STDOUT" "$run_dir" "proposal_ready"
    assert_private_artifact_modes "$run_dir"

    assert_not_contains "$RUN_STDOUT" "super-secret-contract-value" "stdout JSON should not leak AWS secret values"
    assert_not_contains "$RUN_STDOUT" "cf-secret-contract-value" "stdout JSON should not leak Cloudflare secret values"
    assert_not_contains "$RUN_STDOUT" "stripe-live-secret-contract-value" "stdout JSON should not leak Stripe secret values"
    assert_not_contains "$RUN_STDOUT" "stripe-webhook-secret-contract-value" "stdout JSON should not leak Stripe webhook secret values"

    assert_not_contains "$summary_payload" "super-secret-contract-value" "summary.json should not leak AWS secret values"
    assert_not_contains "$summary_payload" "cf-secret-contract-value" "summary.json should not leak Cloudflare secret values"
    assert_not_contains "$summary_payload" "stripe-live-secret-contract-value" "summary.json should not leak Stripe secret values"
    assert_not_contains "$summary_payload" "stripe-webhook-secret-contract-value" "summary.json should not leak Stripe webhook secret values"

    assert_not_contains "$proposal_payload" "super-secret-contract-value" "proposal artifact should not leak AWS secret values"
    assert_not_contains "$proposal_payload" "cf-secret-contract-value" "proposal artifact should not leak Cloudflare secret values"
    assert_not_contains "$proposal_payload" "stripe-live-secret-contract-value" "proposal artifact should not leak Stripe secret values"
    assert_not_contains "$proposal_payload" "stripe-webhook-secret-contract-value" "proposal artifact should not leak Stripe webhook secret values"

    assert_not_contains "$logs_payload" "super-secret-contract-value" "delegated logs should not leak AWS secret values"
    assert_not_contains "$logs_payload" "cf-secret-contract-value" "delegated logs should not leak Cloudflare secret values"
    assert_not_contains "$logs_payload" "stripe-live-secret-contract-value" "delegated logs should not leak Stripe secret values"
    assert_not_contains "$logs_payload" "stripe-webhook-secret-contract-value" "delegated logs should not leak Stripe webhook secret values"
}

run_all_tests() {
    echo "=== live_e2e_budget_guardrail_prep.sh contract tests ==="
    test_mock_aws_parser_handles_global_options_before_service
    test_script_exists_and_executable
    test_help_exits_zero_without_creating_artifacts
    test_cli_parse_failures_exit_2_and_emit_no_stdout_json
    test_invalid_operator_inputs_fail_closed_without_proposal_or_terraform
    test_enable_action_missing_operator_inputs_fail_closed_without_proposal_or_terraform
    test_primary_blocked_input_reports_exact_missing_fields
    test_partial_input_blocked_list_is_precise_and_contains_no_placeholders
    test_discovery_backed_proposal_generation_includes_monitoring_inputs
    test_monthly_equivalent_600_proposal_keeps_single_budget_limit_surface
    test_first_proposal_does_not_require_existing_budget
    test_proposal_file_escapes_untrusted_string_values
    test_missing_or_ambiguous_discovery_stays_blocked_without_plan_artifact
    test_mocked_aws_discovery_commands_are_unattended_and_read_only
    test_redaction_and_artifact_permissions_contract
    run_test_summary
}

run_all_tests
