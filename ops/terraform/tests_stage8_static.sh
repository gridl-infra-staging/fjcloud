#!/usr/bin/env bash
# Static validation tests for Stage 8: spend + cleanup guardrail ownership.
# TDD: these tests define the red contract before implementation.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

monitor_main_file="ops/terraform/monitoring/main.tf"
monitor_vars_file="ops/terraform/monitoring/variables.tf"
monitor_outputs_file="ops/terraform/monitoring/outputs.tf"
monitor_providers_file="ops/terraform/monitoring/providers.tf"
shared_main_file="ops/terraform/_shared/main.tf"
shared_vars_file="ops/terraform/_shared/variables.tf"
data_main_file="ops/terraform/data/main.tf"
janitor_script_file="ops/scripts/live_e2e_ttl_janitor.sh"
janitor_test_file="scripts/tests/live_e2e_ttl_janitor_test.sh"
prep_script_file="ops/scripts/live_e2e_budget_guardrail_prep.sh"
validate_all_file="ops/terraform/validate_all.sh"
strategy_doc_file="docs/design/aws_e2e_strategy.md"
constraints_doc_file="docs/research/aws_e2e_external_constraints.md"
stage1_budget_decision_file="deliverables/stage_01_budget_period_semantics_decision.md"
runtime_params_main_file="ops/terraform/runtime_params/main.tf"
iam_root_dir="ops/iam"
iam_provider_file="ops/iam/provider.tf"
iam_deploy_file="ops/iam/github-actions-deploy-role.tf"
iam_instance_file="ops/iam/fjcloud-instance-role.tf"
lane7_evidence_pointer_file=".lane7_evidence_dir"
stage1_evidence_root_dir=""
stage1_discovery_summary_file=""

assert_resource_ownership() {
  local resource_type="$1"
  local owner_file="$2"
  local description="$3"
  local hits

  hits=$(rg -n "^[[:space:]]*resource[[:space:]]+\"${resource_type}\"[[:space:]]+\"[^\"]+\"" ops/terraform || true)
  if [[ -z "$hits" ]]; then
    fail "$description (no ${resource_type} resource exists under ops/terraform)"
    return
  fi

  if echo "$hits" | rg -qv "^${owner_file}:"; then
    fail "$description (found ${resource_type} outside ${owner_file})"
    return
  fi

  pass "$description"
}

assert_role_name_owned_in_iam_root() {
  local role_name="$1"
  local description="$2"
  local all_hits terraform_hits

  all_hits="$(rg -n --glob '*.tf' "^[[:space:]]*name[[:space:]]*=[[:space:]]*\"${role_name}\"" "$iam_root_dir" ops/terraform || true)"
  terraform_hits="$(printf '%s\n' "$all_hits" | rg '^ops/terraform/' || true)"

  if [[ -z "$all_hits" ]]; then
    fail "$description (role name not declared in Terraform)"
    return
  fi

  if [[ -n "$terraform_hits" ]]; then
    fail "$description (found role name outside ${iam_root_dir})"
    return
  fi

  pass "$description"
}

assert_role_name_absent_in_tf() {
  local role_name="$1"
  local description="$2"
  local hits

  hits="$(rg -n --glob '*.tf' "^[[:space:]]*name[[:space:]]*=[[:space:]]*\"${role_name}\"" "$iam_root_dir" ops/terraform || true)"
  if [[ -n "$hits" ]]; then
    fail "$description (unexpected role declaration found)"
    return
  fi

  pass "$description"
}

load_stage1_evidence_paths() {
  local raw_pointer

  if [[ ! -f "$lane7_evidence_pointer_file" ]]; then
    fail "Lane 7 evidence pointer file exists"
    return 1
  fi

  raw_pointer="$(tr -d '\r' < "$lane7_evidence_pointer_file")"
  stage1_evidence_root_dir="${raw_pointer%/}"
  if [[ -z "$stage1_evidence_root_dir" ]]; then
    fail "Lane 7 evidence pointer must resolve to a non-empty directory"
    return 1
  fi

  if [[ ! -d "$stage1_evidence_root_dir" ]]; then
    fail "Lane 7 evidence root directory exists (${stage1_evidence_root_dir})"
    return 1
  fi

  stage1_discovery_summary_file="${stage1_evidence_root_dir}/discovery_summary.json"
  if [[ ! -f "$stage1_discovery_summary_file" ]]; then
    fail "Stage 1 discovery summary exists at the lane 7 evidence root"
    return 1
  fi

  pass "Lane 7 evidence pointer resolves to an existing evidence root"
  pass "Stage 1 discovery summary exists at the lane 7 evidence root"
}

echo ""
echo "=== Stage 8 Static Tests: Spend + Cleanup Ownership Guardrails ==="
echo ""

echo "--- Ownership anchor file existence ---"
assert_file_exists "$monitor_main_file" "monitoring/main.tf exists"
assert_file_exists "$monitor_vars_file" "monitoring/variables.tf exists"
assert_file_exists "$monitor_outputs_file" "monitoring/outputs.tf exists"
assert_file_exists "$monitor_providers_file" "monitoring/providers.tf exists"
assert_file_exists "$shared_main_file" "_shared/main.tf exists"
assert_file_exists "$shared_vars_file" "_shared/variables.tf exists"
assert_file_exists "$validate_all_file" "validate_all.sh exists"
assert_file_exists "$prep_script_file" "live_e2e_budget_guardrail_prep.sh exists"
load_stage1_evidence_paths

echo ""
echo "--- Stage 2 IAM ownership and evidence-gate contract ---"
assert_file_exists "$iam_deploy_file" "IAM deploy-role owner file exists"
assert_file_exists "$iam_instance_file" "IAM instance-role owner file exists"
assert_contains_active "$iam_provider_file" '^[[:space:]]*provider[[:space:]]+"aws"[[:space:]]*\{' "IAM root declares an active aws provider block in provider.tf"
assert_contains_active "$iam_provider_file" 'allowed_account_ids[[:space:]]*=' "IAM provider guard exposes allowed_account_ids"
assert_contains_active "$iam_deploy_file" 'token\.actions\.githubusercontent\.com:sub"[[:space:]]*=[[:space:]]*"repo:gridl-infra-staging/fjcloud:ref:refs/heads/main"' "Deploy role trust subject is pinned to staging main branch"
assert_contains_active "$iam_instance_file" '^[[:space:]]*resource[[:space:]]+"aws_iam_role"[[:space:]]+"fjcloud_instance"' "Instance role resource remains checked in"
assert_role_name_owned_in_iam_root "fjcloud-deploy" "Deploy role name is owned only by ops/iam"
assert_role_name_owned_in_iam_root "fjcloud-instance-role" "Instance role name is owned only by ops/iam"

local_dev_role_name="$(
  python3 - "$stage1_discovery_summary_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)
value = payload.get("local_dev_role_name")
if not isinstance(value, str) or not value:
    raise SystemExit(1)
print(value)
PY
)"

human_sso_role_name="$(
  python3 - "$stage1_discovery_summary_file" <<'PY'
import json
import re
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)
managed_roles = payload.get("managed_roles")
if not isinstance(managed_roles, list):
    raise SystemExit(1)
for role in managed_roles:
    if not isinstance(role, dict):
        continue
    role_name = role.get("role_name")
    category = role.get("category")
    role_name_text = role_name if isinstance(role_name, str) else ""
    category_text = category if isinstance(category, str) else ""
    if re.search(r"human[-_]?sso", role_name_text, re.IGNORECASE) or re.search(r"human[-_]?sso", category_text, re.IGNORECASE):
        print(role_name_text if role_name_text else "human_sso")
        raise SystemExit(0)
print("missing")
PY
)"

staging_account_id="$(
  python3 - "$stage1_discovery_summary_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)
value = payload.get("staging_account_id")
if not isinstance(value, str) or not value:
    raise SystemExit(1)
print(value)
PY
)"

assert_contains_active "$iam_provider_file" "allowed_account_ids[[:space:]]*=[[:space:]]*\\[\"${staging_account_id}\"\\]" "IAM provider guard is pinned to the Stage 1-discovered staging account"
assert_contains_active "$iam_provider_file" '^[[:space:]]*data[[:space:]]+"aws_caller_identity"[[:space:]]+"current"' "IAM root exposes aws_caller_identity for account-scoped policy ARNs"
assert_contains_active "$iam_instance_file" 'arn:aws:ses:us-east-1:\$\{data\.aws_caller_identity\.current\.account_id\}:identity/flapjack\.foo' "Instance-role SES policy derives the identity ARN from the verified caller account"
assert_not_contains_active "$iam_instance_file" 'arn:aws:ses:us-east-1:\*:identity/flapjack\.foo' "Instance-role SES policy does not wildcard the AWS account segment"

if [[ "$local_dev_role_name" == "missing" ]]; then
  pass "Stage 1 evidence keeps local_dev optional (local_dev_role_name=missing)"
  assert_role_name_absent_in_tf "local_dev" "No speculative local_dev role is required when Stage 1 evidence marks it missing"
else
  assert_role_name_owned_in_iam_root "$local_dev_role_name" "Stage 1-discovered local_dev role is owned only by ops/iam"
fi

if [[ "$human_sso_role_name" == "missing" ]]; then
  pass "Stage 1 evidence keeps human_sso optional (managed_roles has no human_sso role)"
  assert_role_name_absent_in_tf "human_sso" "No speculative human_sso role is required when Stage 1 evidence has none"
else
  assert_role_name_owned_in_iam_root "$human_sso_role_name" "Stage 1-discovered human_sso role is owned only by ops/iam"
fi

echo ""
echo "--- CloudTrail ownership contract ---"
assert_resource_ownership "aws_cloudtrail" "$monitor_main_file" "CloudTrail resources are owned in monitoring/main.tf"
assert_contains_active "$monitor_main_file" '^[[:space:]]*resource[[:space:]]+"aws_cloudtrail"[[:space:]]+"[^"]+"' "Monitoring module declares an active aws_cloudtrail resource"
assert_contains_active "$monitor_main_file" 'data "aws_partition" "current"' "Monitoring module builds CloudTrail source ARN with AWS partition data"
assert_contains_active "$monitor_main_file" 'cloudtrail_source_arn[[:space:]]*=[[:space:]]*"arn:\$\{data\.aws_partition\.current\.partition\}:cloudtrail:\$\{var\.region\}:\$\{data\.aws_caller_identity\.current\.account_id\}:trail/\$\{local\.cloudtrail_name\}"' "Monitoring module derives exact CloudTrail source ARN"
assert_contains_active "$monitor_main_file" '"aws:SourceAccount"[[:space:]]*=[[:space:]]*data\.aws_caller_identity\.current\.account_id' "CloudTrail bucket policy restricts service principal by source account"
assert_contains_active "$monitor_main_file" '"aws:SourceArn"[[:space:]]*=[[:space:]]*local\.cloudtrail_source_arn' "CloudTrail bucket policy restricts service principal by source trail ARN"

echo ""
echo "--- Spend-control ownership contract ---"
assert_resource_ownership "aws_budgets_budget" "$monitor_main_file" "AWS Budgets budget resources are owned in monitoring/main.tf"
assert_resource_ownership "aws_budgets_budget_action" "$monitor_main_file" "AWS Budgets action resources are owned in monitoring/main.tf"
assert_contains_active "$monitor_main_file" '^[[:space:]]*resource[[:space:]]+"aws_budgets_budget"[[:space:]]+"[^"]+"' "Monitoring module declares aws_budgets_budget"
assert_contains_active "$monitor_main_file" '^[[:space:]]*resource[[:space:]]+"aws_budgets_budget_action"[[:space:]]+"[^"]+"' "Monitoring module declares aws_budgets_budget_action"
assert_contains_active "$monitor_main_file" 'live_e2e_budget_configured[[:space:]]*=[[:space:]]*var\.live_e2e_monthly_spend_limit_usd[[:space:]]*!=[[:space:]]*null' "Budget gate remains derived from live_e2e_monthly_spend_limit_usd null-check"
assert_contains_active "$monitor_main_file" 'count[[:space:]]*=[[:space:]]*local\.live_e2e_budget_configured[[:space:]]*\?[[:space:]]*1[[:space:]]*:[[:space:]]*0' "Budget resource remains null-gated by local.live_e2e_budget_configured"
assert_contains_active "$monitor_main_file" 'limit_amount[[:space:]]*=[[:space:]]*format\("%\.2f",[[:space:]]*var\.live_e2e_monthly_spend_limit_usd\)' "Budget limit_amount is formatted from live_e2e_monthly_spend_limit_usd"
assert_contains_active "$monitor_main_file" 'time_unit[[:space:]]*=[[:space:]]*"MONTHLY"' "Budget time_unit remains MONTHLY"
assert_contains_active "$monitor_main_file" 'count[[:space:]]*=[[:space:]]*var\.live_e2e_budget_action_enabled[[:space:]]*\?[[:space:]]*1[[:space:]]*:[[:space:]]*0' "Budget action is disabled by default unless explicitly enabled"
assert_contains_active "$monitor_vars_file" '^[[:space:]]*variable[[:space:]]+"live_e2e_budget_action_enabled"' "monitoring/variables.tf exposes budget-action gate"
assert_contains_active "$monitor_vars_file" '^[[:space:]]*variable[[:space:]]+"live_e2e_monthly_spend_limit_usd"' "monitoring/variables.tf exposes monthly spend limit input"
assert_contains_active "$monitor_vars_file" '^[[:space:]]*variable[[:space:]]+"live_e2e_budget_action_principal_arn"' "monitoring/variables.tf exposes budget-action principal input"
assert_contains_active "$monitor_vars_file" '^[[:space:]]*variable[[:space:]]+"live_e2e_budget_action_policy_arn"' "monitoring/variables.tf exposes budget-action policy input"
assert_contains_active "$monitor_vars_file" '^[[:space:]]*variable[[:space:]]+"live_e2e_budget_action_role_name"' "monitoring/variables.tf exposes budget-action role-name input"
assert_contains_active "$monitor_vars_file" '^[[:space:]]*variable[[:space:]]+"live_e2e_budget_action_execution_role_arn"' "monitoring/variables.tf exposes budget-action execution-role input"
assert_contains_active "$monitor_vars_file" 'live_e2e_budget_action_role_name must be empty or a valid IAM role name' "monitoring/variables.tf validates budget-action role-name input"
assert_contains_active "$monitor_vars_file" 'default[[:space:]]*=[[:space:]]*false' "Budget action gate defaults to disabled"
assert_contains_active "$monitor_outputs_file" '^[[:space:]]*output[[:space:]]+"live_e2e_budget_name"' "monitoring/outputs.tf exposes budget name"
assert_contains_active "$monitor_outputs_file" '^[[:space:]]*output[[:space:]]+"live_e2e_budget_action_enabled"' "monitoring/outputs.tf exposes budget-action enabled state"
assert_contains_active "$monitor_main_file" 'depends_on[[:space:]]*=[[:space:]]*\[aws_budgets_budget\.live_e2e_spend\]' "Budget action explicitly depends on budget creation"
assert_file_contains "$prep_script_file" 'LIVE_E2E_MONTHLY_SPEND_LIMIT_USD:live_e2e_monthly_spend_limit_usd:--monthly-spend-limit-usd' "prep script maps budget limit through live_e2e_monthly_spend_limit_usd only"

monitor_budget_limit_surface_count="$(rg -n '^[[:space:]]*variable[[:space:]]+"live_e2e_.*spend_limit_usd"' "$monitor_vars_file" | wc -l | tr -d ' ')"
if [[ "$monitor_budget_limit_surface_count" == "1" ]]; then
  pass "monitoring/variables.tf keeps exactly one live_e2e_*spend_limit_usd input surface"
else
  fail "monitoring/variables.tf keeps exactly one live_e2e_*spend_limit_usd input surface (found $monitor_budget_limit_surface_count)"
fi

shared_budget_limit_surface_count="$(rg -n '^[[:space:]]*variable[[:space:]]+"live_e2e_.*spend_limit_usd"' "$shared_vars_file" | wc -l | tr -d ' ')"
if [[ "$shared_budget_limit_surface_count" == "1" ]]; then
  pass "_shared/variables.tf keeps exactly one live_e2e_*spend_limit_usd pass-through input surface"
else
  fail "_shared/variables.tf keeps exactly one live_e2e_*spend_limit_usd pass-through input surface (found $shared_budget_limit_surface_count)"
fi

assert_not_contains_active "$shared_main_file" '^[[:space:]]*resource[[:space:]]+"aws_cloudtrail"[[:space:]]+"[^"]+"' "_shared/main.tf does not directly own CloudTrail resources"
assert_not_contains_active "$shared_main_file" '^[[:space:]]*resource[[:space:]]+"aws_budgets_budget"[[:space:]]+"[^"]+"' "_shared/main.tf does not directly own aws_budgets_budget"
assert_not_contains_active "$shared_main_file" '^[[:space:]]*resource[[:space:]]+"aws_budgets_budget_action"[[:space:]]+"[^"]+"' "_shared/main.tf does not directly own aws_budgets_budget_action"
assert_not_contains_active "$shared_main_file" '^[[:space:]]*resource[[:space:]]+"aws_[^"]+"' "_shared/main.tf remains wiring-only (no direct aws_* resources)"

assert_contains_active "$shared_vars_file" '^[[:space:]]*variable[[:space:]]+"live_e2e_monthly_spend_limit_usd"' "_shared/variables.tf exposes live_e2e_monthly_spend_limit_usd"
assert_contains_active "$shared_vars_file" '^[[:space:]]*variable[[:space:]]+"live_e2e_budget_action_enabled"' "_shared/variables.tf exposes live_e2e_budget_action_enabled"
assert_contains_active "$shared_vars_file" '^[[:space:]]*variable[[:space:]]+"live_e2e_budget_action_principal_arn"' "_shared/variables.tf exposes live_e2e_budget_action_principal_arn"
assert_contains_active "$shared_vars_file" '^[[:space:]]*variable[[:space:]]+"live_e2e_budget_action_policy_arn"' "_shared/variables.tf exposes live_e2e_budget_action_policy_arn"
assert_contains_active "$shared_vars_file" '^[[:space:]]*variable[[:space:]]+"live_e2e_budget_action_role_name"' "_shared/variables.tf exposes live_e2e_budget_action_role_name"
assert_contains_active "$shared_vars_file" '^[[:space:]]*variable[[:space:]]+"live_e2e_budget_action_execution_role_arn"' "_shared/variables.tf exposes live_e2e_budget_action_execution_role_arn"
assert_contains_active "$shared_main_file" 'live_e2e_monthly_spend_limit_usd[[:space:]]*=[[:space:]]*var\.live_e2e_monthly_spend_limit_usd' "_shared/main.tf passes through monthly spend limit to monitoring"
assert_contains_active "$shared_main_file" 'live_e2e_budget_action_enabled[[:space:]]*=[[:space:]]*var\.live_e2e_budget_action_enabled' "_shared/main.tf passes through action-enabled gate to monitoring"
assert_contains_active "$shared_main_file" 'live_e2e_budget_action_principal_arn[[:space:]]*=[[:space:]]*var\.live_e2e_budget_action_principal_arn' "_shared/main.tf passes through action principal ARN to monitoring"
assert_contains_active "$shared_main_file" 'live_e2e_budget_action_policy_arn[[:space:]]*=[[:space:]]*var\.live_e2e_budget_action_policy_arn' "_shared/main.tf passes through action policy ARN to monitoring"
assert_contains_active "$shared_main_file" 'live_e2e_budget_action_role_name[[:space:]]*=[[:space:]]*var\.live_e2e_budget_action_role_name' "_shared/main.tf passes through action role name to monitoring"
assert_contains_active "$shared_main_file" 'live_e2e_budget_action_execution_role_arn[[:space:]]*=[[:space:]]*var\.live_e2e_budget_action_execution_role_arn' "_shared/main.tf passes through action execution-role ARN to monitoring"

echo ""
echo "--- Runtime parameter ownership contract ---"
assert_file_exists "$runtime_params_main_file" "runtime_params/main.tf exists"
assert_contains_active "$shared_main_file" '^[[:space:]]*module[[:space:]]+"runtime_params"' "_shared/main.tf delegates runtime parameters via module \"runtime_params\""
# Runtime SSM parameters use the runtime_* logical-name prefix. data/main.tf
# legitimately owns its own non-runtime aws_ssm_parameter resources (db_password,
# database_url, internal_auth_token, cold_bucket_name), so the ownership contract
# is scoped to the runtime_* prefix rather than every aws_ssm_parameter resource.
runtime_ssm_hits="$(rg -n '^[[:space:]]*resource[[:space:]]+"aws_ssm_parameter"[[:space:]]+"runtime_[^"]+"' ops/terraform --glob '!*.sh' || true)"
if [[ -z "$runtime_ssm_hits" ]]; then
  fail "Runtime aws_ssm_parameter resources (runtime_*) are owned in runtime_params/main.tf (none found)"
elif echo "$runtime_ssm_hits" | rg -qv "^${runtime_params_main_file}:"; then
  fail "Runtime aws_ssm_parameter resources (runtime_*) are owned in runtime_params/main.tf (found runtime_* outside ${runtime_params_main_file})"
else
  pass "Runtime aws_ssm_parameter resources (runtime_*) are owned in runtime_params/main.tf"
fi
assert_not_contains_active "$shared_main_file" '^[[:space:]]*resource[[:space:]]+"aws_ssm_parameter"[[:space:]]+"runtime_' "_shared/main.tf does not directly own runtime aws_ssm_parameter resources"
assert_contains_active "$shared_main_file" 'to[[:space:]]*=[[:space:]]*module\.runtime_params\.aws_ssm_parameter\.runtime_aws_ami_id' "_shared/main.tf retains moved-block migration for runtime_aws_ami_id"
assert_contains_active "$shared_main_file" 'to[[:space:]]*=[[:space:]]*module\.runtime_params\.aws_ssm_parameter\.runtime_aws_subnet_id' "_shared/main.tf retains moved-block migration for runtime_aws_subnet_id"
assert_contains_active "$shared_main_file" 'to[[:space:]]*=[[:space:]]*module\.runtime_params\.aws_ssm_parameter\.runtime_aws_security_group_ids' "_shared/main.tf retains moved-block migration for runtime_aws_security_group_ids"
assert_contains_active "$shared_main_file" 'to[[:space:]]*=[[:space:]]*module\.runtime_params\.aws_ssm_parameter\.runtime_aws_key_pair_name' "_shared/main.tf retains moved-block migration for runtime_aws_key_pair_name"
assert_contains_active "$shared_main_file" 'to[[:space:]]*=[[:space:]]*module\.runtime_params\.aws_ssm_parameter\.runtime_aws_instance_profile_name' "_shared/main.tf retains moved-block migration for runtime_aws_instance_profile_name"
assert_contains_active "$shared_main_file" 'to[[:space:]]*=[[:space:]]*module\.runtime_params\.aws_ssm_parameter\.runtime_cloudflare_zone_id' "_shared/main.tf retains moved-block migration for runtime_cloudflare_zone_id"
assert_contains_active "$shared_main_file" 'to[[:space:]]*=[[:space:]]*module\.runtime_params\.aws_ssm_parameter\.runtime_dns_domain' "_shared/main.tf retains moved-block migration for runtime_dns_domain"

echo ""
echo "--- Stage 3 budget-guardrail plan-gating contract ---"
assert_file_contains "$validate_all_file" '[[:space:]]--budget-guardrail-artifact' "validate_all exposes --budget-guardrail-artifact entrypoint"
assert_file_contains "$validate_all_file" 'summary\.json' "validate_all resolves summary.json from artifact path input"
assert_file_contains "$validate_all_file" 'proposal_ready' "validate_all branches explicitly on proposal_ready artifact status"
assert_file_contains "$validate_all_file" 'python3 -m json.tool' "validate_all blocked path validates summary.json shape via json.tool"
assert_file_contains "$validate_all_file" 'terraform init -backend=false -input=false' "validate_all ready path runs non-interactive terraform init"
assert_file_contains "$validate_all_file" 'terraform plan -input=false -var-file="\$proposal_file"' "validate_all ready path runs non-interactive terraform plan against proposal var-file"
assert_file_not_contains "$validate_all_file" '^[[:space:]]*terraform[[:space:]]+apply([[:space:]]|$)' "validate_all Stage 3 entrypoint must never invoke terraform apply"
assert_file_not_contains "$validate_all_file" 'TF_VAR_live_e2e_budget_action_enabled' "validate_all Stage 3 entrypoint must not override live_e2e_budget_action_enabled via TF_VAR"
assert_file_not_contains "$validate_all_file" '\\-\\-var[[:space:]=]+live_e2e_budget_action_enabled' "validate_all Stage 3 entrypoint must not override live_e2e_budget_action_enabled via CLI var flags"
assert_file_contains "$prep_script_file" 'if \[ "\$LIVE_E2E_ENABLE_ACTION_PROPOSAL" -eq 1 \]; then' "prep script computes live_e2e_budget_action_enabled from Stage 2 enable flag"
assert_file_contains "$prep_script_file" 'live_e2e_budget_action_enabled = \$action_enabled_literal' "proposal.auto.tfvars.example keeps Stage 2 emitted action-enabled boolean literal"

blocked_contract_tmpdir="$(mktemp -d)"
blocked_contract_valid_dir="$blocked_contract_tmpdir/valid"
blocked_contract_invalid_dir="$blocked_contract_tmpdir/invalid"
mkdir -p "$blocked_contract_valid_dir" "$blocked_contract_invalid_dir"

cat >"$blocked_contract_valid_dir/summary.json" <<'JSON'
{
  "status": "blocked",
  "missing_fields": ["api_instance_id", "alb_arn_suffix"],
  "missing_flags": ["--api-instance-id", "--alb-arn-suffix"]
}
JSON

cat >"$blocked_contract_invalid_dir/summary.json" <<'JSON'
{
  "status": "blocked",
  "missing_fields": ["api_instance_id", "alb_arn_suffix"],
  "missing_flags": ["--api-instance-id", "--db-instance-identifier"]
}
JSON

blocked_contract_output="$(mktemp)"
if PATH="/usr/bin:/bin" bash "$validate_all_file" --budget-guardrail-artifact "$blocked_contract_valid_dir" >"$blocked_contract_output" 2>&1; then
  pass "validate_all accepts blocked artifacts only when missing_fields and missing_flags preserve canonical Stage 2 pairs"
else
  fail "validate_all accepts blocked artifacts only when missing_fields and missing_flags preserve canonical Stage 2 pairs"
fi

if PATH="/usr/bin:/bin" bash "$validate_all_file" --budget-guardrail-artifact "$blocked_contract_invalid_dir" >"$blocked_contract_output" 2>&1; then
  fail "validate_all rejects blocked artifacts when missing_fields and missing_flags drift from canonical Stage 2 pairs"
else
  pass "validate_all rejects blocked artifacts when missing_fields and missing_flags drift from canonical Stage 2 pairs"
fi

rm -f "$blocked_contract_output"
rm -rf "$blocked_contract_tmpdir"

proposal_contract_tmpdir="$(mktemp -d)"
proposal_contract_dir="$proposal_contract_tmpdir/proposal"
proposal_contract_bin="$proposal_contract_tmpdir/bin"
proposal_contract_tf_log="$proposal_contract_tmpdir/terraform.log"
proposal_contract_output="$(mktemp)"
mkdir -p "$proposal_contract_dir" "$proposal_contract_bin"

cat >"$proposal_contract_dir/proposal.auto.tfvars.example" <<'EOF'
env = "staging"
region = "us-east-1"
api_instance_id = "i-0a11b22c33d44e55f"
db_instance_identifier = "fjcloud-staging"
alb_arn_suffix = "app/fjcloud-staging-alb/abcd1234efgh5678"
live_e2e_monthly_spend_limit_usd = 245.5
live_e2e_budget_action_enabled = false
live_e2e_budget_action_principal_arn = "arn:aws:iam::123456789012:user/live-e2e-budget-approver"
live_e2e_budget_action_policy_arn = "arn:aws:iam::123456789012:policy/live-e2e-budget-policy"
live_e2e_budget_action_role_name = "live-e2e-budget-target-role"
live_e2e_budget_action_execution_role_arn = "arn:aws:iam::123456789012:role/live-e2e-budget-execution"
EOF

cat >"$proposal_contract_dir/terraform_plan_command.txt" <<EOF
cd ops/terraform/monitoring && terraform plan -input=false -var-file="$proposal_contract_dir/proposal.auto.tfvars.example"
EOF

cat >"$proposal_contract_dir/summary.json" <<EOF
{
  "status": "proposal_ready",
  "missing_fields": [],
  "missing_flags": [],
  "plan_command": ["terraform", "plan", "-input=false", "-var-file=$proposal_contract_dir/proposal.auto.tfvars.example"],
  "proposed_variables": {
    "env": "staging",
    "region": "us-east-1",
    "api_instance_id": "i-0a11b22c33d44e55f",
    "db_instance_identifier": "fjcloud-staging",
    "alb_arn_suffix": "app/fjcloud-staging-alb/abcd1234efgh5678",
    "live_e2e_monthly_spend_limit_usd": 245.5,
    "live_e2e_budget_action_enabled": false,
    "live_e2e_budget_action_principal_arn": "arn:aws:iam::123456789012:user/live-e2e-budget-approver",
    "live_e2e_budget_action_policy_arn": "arn:aws:iam::123456789012:policy/live-e2e-budget-policy",
    "live_e2e_budget_action_role_name": "live-e2e-budget-target-role",
    "live_e2e_budget_action_execution_role_arn": "arn:aws:iam::123456789012:role/live-e2e-budget-execution"
  }
}
EOF

cat >"$proposal_contract_bin/terraform" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$PROPOSAL_TERRAFORM_LOG"
exit 0
MOCK
chmod +x "$proposal_contract_bin/terraform"

if PATH="$proposal_contract_bin:/usr/bin:/bin" PROPOSAL_TERRAFORM_LOG="$proposal_contract_tf_log" bash "$validate_all_file" --budget-guardrail-artifact "$proposal_contract_dir/summary.json" >"$proposal_contract_output" 2>&1; then
  pass "validate_all executes the proposal_ready artifact path when summary.json is passed directly"
else
  fail "validate_all executes the proposal_ready artifact path when summary.json is passed directly"
fi

if grep -Fxq 'init -backend=false -input=false' "$proposal_contract_tf_log" && grep -Fxq "plan -input=false -var-file=$proposal_contract_dir/proposal.auto.tfvars.example" "$proposal_contract_tf_log"; then
  pass "validate_all proposal_ready path runs non-interactive terraform init and plan against the artifact var-file"
else
  fail "validate_all proposal_ready path runs non-interactive terraform init and plan against the artifact var-file"
fi

rm -f "$proposal_contract_output"
rm -rf "$proposal_contract_tmpdir"

echo ""
echo "--- Lifecycle-tag cleanup vocabulary contract ---"
assert_file_exists "$janitor_script_file" "ops/scripts/live_e2e_ttl_janitor.sh exists"
assert_file_exists "$janitor_test_file" "scripts/tests/live_e2e_ttl_janitor_test.sh exists"
assert_file_contains "$janitor_script_file" 'test_run_id' "Janitor cleanup contract references test_run_id tag"
assert_file_contains "$janitor_script_file" 'owner' "Janitor cleanup contract references owner tag"
assert_file_contains "$janitor_script_file" 'ttl_expires_at' "Janitor cleanup contract references ttl_expires_at tag"
assert_file_contains "$janitor_script_file" 'environment' "Janitor cleanup contract references environment tag"
assert_file_contains "$janitor_test_file" 'test_run_id' "Janitor tests assert test_run_id contract"
assert_file_contains "$janitor_test_file" 'owner' "Janitor tests assert owner contract"
assert_file_contains "$janitor_test_file" 'ttl_expires_at' "Janitor tests assert ttl_expires_at contract"
assert_file_contains "$janitor_test_file" 'environment' "Janitor tests assert environment contract"
assert_file_not_contains "$data_main_file" 'test_run_id' "Durable data module does not own test_run_id TTL tag"
assert_file_not_contains "$data_main_file" 'owner' "Durable data module does not own owner TTL tag"
assert_file_not_contains "$data_main_file" 'ttl_expires_at' "Durable data module does not own ttl_expires_at TTL tag"

echo ""
echo "--- Documented budget-action deferral contract ---"
assert_file_exists "$strategy_doc_file" "aws_e2e_strategy.md exists"
assert_file_exists "$constraints_doc_file" "aws_e2e_external_constraints.md exists"
assert_file_contains "$strategy_doc_file" '^## fjcloud-Specific Follow-up Prerequisites \(Not Closed in Stage 3\)' "Strategy doc keeps explicit unresolved-prerequisites section"
assert_file_contains "$strategy_doc_file" 'Which IAM principal/team will own AWS Budgets action approvals for e2e test resources\?' "Strategy doc explicitly keeps unresolved budget-action owner question"
assert_file_not_contains "$strategy_doc_file" 'Monitoring module currently owns CloudWatch alarms only' "Strategy doc no longer claims monitoring lacks CloudTrail ownership"
assert_file_contains "$constraints_doc_file" '^## CloudWatch and CloudTrail Evidence Capture Constraints' "Constraints doc keeps CloudWatch/CloudTrail constraint section"
assert_file_contains "$constraints_doc_file" 'CloudTrail ownership is resolved in Terraform' "Constraints doc records that CloudTrail ownership is now resolved"
assert_file_contains "$constraints_doc_file" 'Which IAM principal should approve/operate AWS Budgets actions for test-runner EC2/RDS resources' "Constraints doc explicitly keeps unresolved budget-action principal question"

echo ""
echo "--- Stage 1 budget-period decision deliverable contract ---"
assert_file_exists "$stage1_budget_decision_file" "Stage 1 budget-period decision deliverable exists"
assert_file_contains "$stage1_budget_decision_file" '^\# Stage 1 Budget Period Semantics Decision' "Decision deliverable has canonical Stage 1 decision heading"
assert_file_contains "$stage1_budget_decision_file" 'https://docs\.aws\.amazon\.com/aws-cost-management/latest/APIReference/API_budgets_Budget\.html' "Decision deliverable cites AWS Budgets API Budget.TimeUnit reference"
assert_file_contains "$stage1_budget_decision_file" 'https://docs\.aws\.amazon\.com/cost-management/latest/userguide/create-cost-budget\.html' "Decision deliverable cites AWS cost budget period reference"
assert_file_contains "$stage1_budget_decision_file" 'https://raw\.githubusercontent\.com/hashicorp/terraform-provider-aws/main/website/docs/r/budgets_budget\.html\.markdown' "Decision deliverable cites Terraform aws_budgets_budget time_unit reference"
assert_file_contains "$stage1_budget_decision_file" '\$20/day guardrail intent is implemented as a monthly-equivalent ceiling via live_e2e_monthly_spend_limit_usd' "Decision deliverable records Stage 2 monthly-equivalent interpretation"
assert_file_contains "$stage1_budget_decision_file" 'Exact calendar-day enforcement remains a Stage 3 implementation gap if strict per-day enforcement is required\.' "Decision deliverable records Stage 3 daily-enforcement gap conditionally"
assert_file_contains "$stage1_budget_decision_file" 'Open questions: none' "Decision deliverable explicitly closes Stage 1 open questions"

test_summary "Stage 8 static checks"
