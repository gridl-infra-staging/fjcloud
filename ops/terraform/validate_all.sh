#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JANITOR_SCRIPT_RELATIVE_PATH="ops/scripts/live_e2e_ttl_janitor.sh"
JANITOR_SCRIPT="${SCRIPT_DIR}/../scripts/live_e2e_ttl_janitor.sh"

# Format: "<module-label>:<path-relative-to-ops/terraform>"
MODULE_SPECS=(
  "networking:networking"
  "compute:compute"
  "data:data"
  "dns:dns"
  "monitoring:monitoring"
  "_shared:_shared"
  "iam:../iam"
)
MONITORING_VARIABLES_FILE="${SCRIPT_DIR}/monitoring/variables.tf"
BUDGET_GUARDRAIL_REQUIRED_VARIABLES=(
  "env"
  "region"
  "api_instance_id"
  "db_instance_identifier"
  "alb_arn_suffix"
  "live_e2e_monthly_spend_limit_usd"
  "live_e2e_budget_action_enabled"
  "live_e2e_budget_action_principal_arn"
  "live_e2e_budget_action_policy_arn"
  "live_e2e_budget_action_role_name"
  "live_e2e_budget_action_execution_role_arn"
)
# Mirrors ops/scripts/live_e2e_budget_guardrail_prep.sh collect_missing_fields contract.
BUDGET_GUARDRAIL_MISSING_FIELD_FLAG_PAIRS=(
  "env:--env"
  "region:--region"
  "api_instance_id:--api-instance-id"
  "db_instance_identifier:--db-instance-identifier"
  "alb_arn_suffix:--alb-arn-suffix"
  "live_e2e_monthly_spend_limit_usd:--monthly-spend-limit-usd"
  "live_e2e_budget_action_principal_arn:--budget-action-principal-arn"
  "live_e2e_budget_action_policy_arn:--budget-action-policy-arn"
  "live_e2e_budget_action_role_name:--budget-action-role-name"
  "live_e2e_budget_action_execution_role_arn:--budget-action-execution-role-arn"
)

module_label_from_spec() {
  local spec="$1"
  printf '%s' "${spec%%:*}"
}

module_rel_path_from_spec() {
  local spec="$1"
  printf '%s' "${spec#*:}"
}

module_abs_dir_from_spec() {
  local spec="$1"
  local module_rel
  module_rel="$(module_rel_path_from_spec "$spec")"
  printf '%s/%s' "$SCRIPT_DIR" "$module_rel"
}

resolve_budget_guardrail_artifact_paths() {
  local artifact_input="$1"
  local summary_path=""
  local run_dir=""

  if [[ -d "$artifact_input" ]]; then
    run_dir="$artifact_input"
    summary_path="$artifact_input/summary.json"
  elif [[ -f "$artifact_input" ]]; then
    if [[ "$(basename "$artifact_input")" != "summary.json" ]]; then
      echo "ERROR: --budget-guardrail-artifact file input must be summary.json: $artifact_input" >&2
      return 1
    fi
    summary_path="$artifact_input"
    run_dir="$(dirname "$artifact_input")"
  else
    echo "ERROR: --budget-guardrail-artifact path does not exist: $artifact_input" >&2
    return 1
  fi

  if [[ ! -f "$summary_path" ]]; then
    echo "ERROR: budget guardrail summary.json missing: $summary_path" >&2
    return 1
  fi

  python3 - "$summary_path" "$run_dir" <<'PY'
import os
import sys
print(os.path.abspath(sys.argv[1]))
print(os.path.abspath(sys.argv[2]))
PY
}

parse_budget_guardrail_status() {
  local summary_path="$1"
  python3 - "$summary_path" <<'PY'
import json
import sys

summary_path = sys.argv[1]
with open(summary_path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)
status = payload.get("status")
if not isinstance(status, str) or not status:
    raise SystemExit(1)
print(status)
PY
}

validate_blocked_budget_guardrail_artifact() {
  local summary_path="$1"
  local run_dir="$2"
  local proposal_file="$run_dir/proposal.auto.tfvars.example"
  local plan_command_file="$run_dir/terraform_plan_command.txt"

  python3 -m json.tool "$summary_path" >/dev/null

  if ! python3 - "$summary_path" "${BUDGET_GUARDRAIL_MISSING_FIELD_FLAG_PAIRS[@]}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)
status = payload.get("status")
if status != "blocked":
    raise SystemExit(1)
missing_fields = payload.get("missing_fields")
missing_flags = payload.get("missing_flags")
if not isinstance(missing_fields, list) or not isinstance(missing_flags, list):
    raise SystemExit(2)
if len(missing_fields) == 0 or len(missing_flags) == 0:
    raise SystemExit(3)
if len(missing_fields) != len(missing_flags):
    raise SystemExit(4)
if len(set(missing_fields)) != len(missing_fields):
    raise SystemExit(5)
if len(set(missing_flags)) != len(missing_flags):
    raise SystemExit(6)

canonical_pairs = []
for pair in sys.argv[2:]:
    parts = pair.split(":", 1)
    if len(parts) != 2:
        raise SystemExit(7)
    canonical_pairs.append((parts[0], parts[1]))
canonical_field_to_flag = {field: flag for field, flag in canonical_pairs}
canonical_field_positions = {field: index for index, (field, _flag) in enumerate(canonical_pairs)}

previous_position = -1
for field, flag in zip(missing_fields, missing_flags):
    if not isinstance(field, str) or not isinstance(flag, str):
        raise SystemExit(8)
    expected_flag = canonical_field_to_flag.get(field)
    if expected_flag is None:
        raise SystemExit(9)
    if flag != expected_flag:
        raise SystemExit(10)
    field_position = canonical_field_positions[field]
    if field_position <= previous_position:
        raise SystemExit(11)
    previous_position = field_position

if "plan_command" in payload or "proposed_variables" in payload:
    raise SystemExit(12)
PY
  then
    echo "ERROR: blocked budget-guardrail artifact must preserve exact Stage 2 missing_fields/missing_flags pairing and omit plan payloads: $summary_path" >&2
    return 1
  fi

  if [[ -f "$proposal_file" ]]; then
    echo "ERROR: blocked budget-guardrail artifact must not include proposal file: $proposal_file" >&2
    return 1
  fi
  if [[ -f "$plan_command_file" ]]; then
    echo "ERROR: blocked budget-guardrail artifact must not include terraform_plan_command.txt: $plan_command_file" >&2
    return 1
  fi

  echo "Budget-guardrail artifact is blocked; summary shape is valid and Terraform planning is intentionally skipped."
}

validate_proposal_ready_budget_guardrail_artifact() {
  local summary_path="$1"
  local run_dir="$2"
  local proposal_file="$run_dir/proposal.auto.tfvars.example"
  local plan_command_file="$run_dir/terraform_plan_command.txt"

  if [[ ! -f "$proposal_file" ]]; then
    echo "ERROR: proposal_ready artifact missing var-file: $proposal_file" >&2
    return 1
  fi
  if [[ ! -f "$plan_command_file" ]]; then
    echo "ERROR: proposal_ready artifact missing terraform_plan_command.txt: $plan_command_file" >&2
    return 1
  fi

  python3 -m json.tool "$summary_path" >/dev/null

  if ! python3 - "$summary_path" "$proposal_file" "$plan_command_file" "$MONITORING_VARIABLES_FILE" "${BUDGET_GUARDRAIL_REQUIRED_VARIABLES[@]}" <<'PY'
import json
import pathlib
import re
import sys

summary_path = pathlib.Path(sys.argv[1])
proposal_file = pathlib.Path(sys.argv[2])
plan_command_file = pathlib.Path(sys.argv[3])
variables_file = pathlib.Path(sys.argv[4])
required_variables = set(sys.argv[5:])

def norm(path_value: str) -> str:
    return str(pathlib.Path(path_value).resolve())

payload = json.loads(summary_path.read_text(encoding="utf-8"))
if payload.get("status") != "proposal_ready":
    raise SystemExit(1)
if payload.get("missing_fields") != [] or payload.get("missing_flags") != []:
    raise SystemExit(2)
plan_command = payload.get("plan_command")
if not isinstance(plan_command, list) or any(not isinstance(token, str) for token in plan_command):
    raise SystemExit(3)
if len(plan_command) != 4:
    raise SystemExit(4)
if plan_command[0:3] != ["terraform", "plan", "-input=false"]:
    raise SystemExit(5)
if "TF_VAR_" in " ".join(plan_command):
    raise SystemExit(6)
if not plan_command[3].startswith("-var-file="):
    raise SystemExit(7)
plan_var_file = plan_command[3].split("=", 1)[1]
if norm(plan_var_file) != norm(str(proposal_file)):
    raise SystemExit(8)

proposed_variables = payload.get("proposed_variables")
if not isinstance(proposed_variables, dict):
    raise SystemExit(9)
if not required_variables.issubset(set(proposed_variables.keys())):
    raise SystemExit(10)

variables_text = variables_file.read_text(encoding="utf-8")
declared_variables = set(re.findall(r'(?m)^\s*variable\s+"([^"]+)"\s*\{', variables_text))
if not required_variables.issubset(declared_variables):
    raise SystemExit(11)

proposal_text = proposal_file.read_text(encoding="utf-8")
for variable_name in required_variables:
    assignment_re = rf'(?m)^\s*{re.escape(variable_name)}\s*='
    if re.search(assignment_re, proposal_text) is None:
        raise SystemExit(12)

enabled_match = re.search(r'(?m)^\s*live_e2e_budget_action_enabled\s*=\s*(true|false)\s*$', proposal_text)
if enabled_match is None:
    raise SystemExit(13)
enabled_in_file = enabled_match.group(1) == "true"
if bool(proposed_variables.get("live_e2e_budget_action_enabled")) != enabled_in_file:
    raise SystemExit(14)

command_text = plan_command_file.read_text(encoding="utf-8").strip()
if "terraform apply" in command_text:
    raise SystemExit(15)
if "TF_VAR_" in command_text:
    raise SystemExit(16)
if "cd ops/terraform/monitoring &&" not in command_text:
    raise SystemExit(17)
if "terraform plan -input=false" not in command_text:
    raise SystemExit(18)
command_var_file_match = re.search(r'-var-file="([^"]+)"', command_text)
if command_var_file_match is None:
    raise SystemExit(19)
command_var_file = command_var_file_match.group(1)
if norm(command_var_file) != norm(str(proposal_file)):
    raise SystemExit(20)
if norm(command_var_file) != norm(plan_var_file):
    raise SystemExit(21)
PY
  then
    echo "ERROR: proposal_ready artifact contract mismatch between summary.json, terraform_plan_command.txt, and proposal.auto.tfvars.example" >&2
    return 1
  fi
}

run_budget_guardrail_artifact_validation() {
  local artifact_input="$1"
  local summary_path run_dir status resolved_paths

  resolved_paths="$(resolve_budget_guardrail_artifact_paths "$artifact_input" || true)"
  summary_path="$(printf '%s\n' "$resolved_paths" | sed -n '1p')"
  run_dir="$(printf '%s\n' "$resolved_paths" | sed -n '2p')"

  if [[ -z "$summary_path" || -z "$run_dir" ]]; then
    echo "ERROR: failed to resolve budget-guardrail artifact input: $artifact_input" >&2
    return 1
  fi

  status="$(parse_budget_guardrail_status "$summary_path" || true)"
  if [[ -z "$status" ]]; then
    echo "ERROR: budget guardrail summary.json is missing a valid status field: $summary_path" >&2
    return 1
  fi

  if [[ "$status" == "proposal_ready" ]]; then
    validate_proposal_ready_budget_guardrail_artifact "$summary_path" "$run_dir" || return 1
    if ! command -v terraform >/dev/null 2>&1; then
      echo "ERROR: terraform is required for proposal_ready budget-guardrail artifact validation." >&2
      return 1
    fi
    local proposal_file="$run_dir/proposal.auto.tfvars.example"
    echo "==> budget-guardrail plan validation: $run_dir"
    (
      cd "${SCRIPT_DIR}/monitoring"
      terraform init -backend=false -input=false
      terraform plan -input=false -var-file="$proposal_file"
    )
    return 0
  fi

  if [[ "$status" != "blocked" ]]; then
    echo "ERROR: unsupported budget-guardrail artifact status '$status' in $summary_path" >&2
    return 1
  fi

  validate_blocked_budget_guardrail_artifact "$summary_path" "$run_dir"
}

is_allowed_public_ingress_ports() {
  local from_port="$1"
  local to_port="$2"
  [[ ( "$from_port" == "80" && "$to_port" == "80" ) || ( "$from_port" == "443" && "$to_port" == "443" ) ]]
}

strip_hcl_comments() {
  local line="$1"
  printf '%s' "$line" | sed -E 's/[[:space:]]+#.*$//; s@(^|[[:space:]])//.*$@\1@'
}

run_terraform_validation() {
  local module_spec module module_dir
  local failed=0

  for module_spec in "${MODULE_SPECS[@]}"; do
    module="$(module_label_from_spec "$module_spec")"
    module_dir="$(module_abs_dir_from_spec "$module_spec")"

    if [[ ! -d "$module_dir" ]]; then
      echo "ERROR: terraform module directory missing: $module_dir" >&2
      failed=1
      continue
    fi

    echo "==> terraform validate: $module"
    if ! (
      cd "$module_dir"
      terraform init -backend=false
      terraform validate
    ); then
      echo "ERROR: terraform validation failed for module: $module" >&2
      failed=1
    fi
  done

  return "$failed"
}

run_sg_audit_for_file() {
  local tf_file="$1"
  local failed=0
  local line active_line opens closes
  local in_ingress_rule=0
  local ingress_rule_depth=0
  local ingress_rule_has_public=0
  local ingress_rule_name=""
  local ingress_rule_from_port=""
  local ingress_rule_to_port=""
  local ingress_rule_cidr_blocks_depth=0
  local in_security_group=0
  local security_group_depth=0
  local security_group_name=""
  local in_security_group_ingress=0
  local security_group_ingress_depth=0
  local security_group_ingress_has_public=0
  local security_group_ingress_from_port=""
  local security_group_ingress_to_port=""
  local security_group_ingress_cidr_blocks_depth=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    active_line="$(strip_hcl_comments "$line")"

    if [[ "$in_ingress_rule" -eq 0 && "$in_security_group" -eq 0 ]]; then
      if [[ "$active_line" =~ ^[[:space:]]*resource[[:space:]]+\"aws_vpc_security_group_ingress_rule\"[[:space:]]+\"([^\"]+)\" ]]; then
        in_ingress_rule=1
        ingress_rule_depth=0
        ingress_rule_has_public=0
        ingress_rule_name="${BASH_REMATCH[1]}"
        ingress_rule_from_port=""
        ingress_rule_to_port=""
        ingress_rule_cidr_blocks_depth=0
      elif [[ "$active_line" =~ ^[[:space:]]*resource[[:space:]]+\"aws_security_group\"[[:space:]]+\"([^\"]+)\" ]]; then
        in_security_group=1
        security_group_depth=0
        security_group_name="${BASH_REMATCH[1]}"
        in_security_group_ingress=0
        security_group_ingress_depth=0
        security_group_ingress_has_public=0
        security_group_ingress_from_port=""
        security_group_ingress_to_port=""
        security_group_ingress_cidr_blocks_depth=0
      else
        continue
      fi
    fi

    if [[ "$in_ingress_rule" -eq 1 ]]; then
      if [[ "$active_line" =~ ^[[:space:]]*cidr_ipv4[[:space:]]*=[[:space:]]*\"0\.0\.0\.0/0\" ]]; then
        ingress_rule_has_public=1
      fi
      if [[ "$active_line" =~ ^[[:space:]]*cidr_blocks[[:space:]]*= ]]; then
        if [[ "$active_line" =~ \"0\.0\.0\.0/0\" ]]; then
          ingress_rule_has_public=1
        fi
        opens="${active_line//[^\[]/}"
        closes="${active_line//[^\]]/}"
        ingress_rule_cidr_blocks_depth=$((ingress_rule_cidr_blocks_depth + ${#opens} - ${#closes}))
      elif [[ "$ingress_rule_cidr_blocks_depth" -gt 0 ]]; then
        if [[ "$active_line" =~ \"0\.0\.0\.0/0\" ]]; then
          ingress_rule_has_public=1
        fi
        opens="${active_line//[^\[]/}"
        closes="${active_line//[^\]]/}"
        ingress_rule_cidr_blocks_depth=$((ingress_rule_cidr_blocks_depth + ${#opens} - ${#closes}))
      fi
      if [[ "$active_line" =~ ^[[:space:]]*from_port[[:space:]]*=[[:space:]]*([0-9]+) ]]; then
        ingress_rule_from_port="${BASH_REMATCH[1]}"
      fi
      if [[ "$active_line" =~ ^[[:space:]]*to_port[[:space:]]*=[[:space:]]*([0-9]+) ]]; then
        ingress_rule_to_port="${BASH_REMATCH[1]}"
      fi

      opens="${active_line//[^\{]/}"
      closes="${active_line//[^\}]/}"
      ingress_rule_depth=$((ingress_rule_depth + ${#opens} - ${#closes}))

      if [[ "$ingress_rule_depth" -le 0 ]]; then
        if [[ "$ingress_rule_has_public" -eq 1 ]] && ! is_allowed_public_ingress_ports "$ingress_rule_from_port" "$ingress_rule_to_port"; then
          echo "ERROR: insecure public ingress in $tf_file (resource=${ingress_rule_name:-unknown}, from_port=${ingress_rule_from_port:-unset}, to_port=${ingress_rule_to_port:-unset})" >&2
          failed=1
        fi

        in_ingress_rule=0
        ingress_rule_depth=0
        ingress_rule_has_public=0
        ingress_rule_name=""
        ingress_rule_from_port=""
        ingress_rule_to_port=""
        ingress_rule_cidr_blocks_depth=0
      fi
      continue
    fi

    if [[ "$in_security_group" -eq 1 ]]; then
      if [[ "$in_security_group_ingress" -eq 0 ]] && [[ "$active_line" =~ ^[[:space:]]*ingress[[:space:]]*\{ ]]; then
        in_security_group_ingress=1
        security_group_ingress_depth=0
        security_group_ingress_has_public=0
        security_group_ingress_from_port=""
        security_group_ingress_to_port=""
        security_group_ingress_cidr_blocks_depth=0
      fi

      if [[ "$in_security_group_ingress" -eq 1 ]]; then
        if [[ "$active_line" =~ ^[[:space:]]*cidr_ipv4[[:space:]]*=[[:space:]]*\"0\.0\.0\.0/0\" ]]; then
          security_group_ingress_has_public=1
        fi
        if [[ "$active_line" =~ ^[[:space:]]*cidr_blocks[[:space:]]*= ]]; then
          if [[ "$active_line" =~ \"0\.0\.0\.0/0\" ]]; then
            security_group_ingress_has_public=1
          fi
          opens="${active_line//[^\[]/}"
          closes="${active_line//[^\]]/}"
          security_group_ingress_cidr_blocks_depth=$((security_group_ingress_cidr_blocks_depth + ${#opens} - ${#closes}))
        elif [[ "$security_group_ingress_cidr_blocks_depth" -gt 0 ]]; then
          if [[ "$active_line" =~ \"0\.0\.0\.0/0\" ]]; then
            security_group_ingress_has_public=1
          fi
          opens="${active_line//[^\[]/}"
          closes="${active_line//[^\]]/}"
          security_group_ingress_cidr_blocks_depth=$((security_group_ingress_cidr_blocks_depth + ${#opens} - ${#closes}))
        fi
        if [[ "$active_line" =~ ^[[:space:]]*from_port[[:space:]]*=[[:space:]]*([0-9]+) ]]; then
          security_group_ingress_from_port="${BASH_REMATCH[1]}"
        fi
        if [[ "$active_line" =~ ^[[:space:]]*to_port[[:space:]]*=[[:space:]]*([0-9]+) ]]; then
          security_group_ingress_to_port="${BASH_REMATCH[1]}"
        fi

        opens="${active_line//[^\{]/}"
        closes="${active_line//[^\}]/}"
        security_group_ingress_depth=$((security_group_ingress_depth + ${#opens} - ${#closes}))

        if [[ "$security_group_ingress_depth" -le 0 ]]; then
          if [[ "$security_group_ingress_has_public" -eq 1 ]] && ! is_allowed_public_ingress_ports "$security_group_ingress_from_port" "$security_group_ingress_to_port"; then
            echo "ERROR: insecure public ingress in $tf_file (resource=${security_group_name:-unknown}, ingress=inline, from_port=${security_group_ingress_from_port:-unset}, to_port=${security_group_ingress_to_port:-unset})" >&2
            failed=1
          fi

          in_security_group_ingress=0
          security_group_ingress_depth=0
          security_group_ingress_has_public=0
          security_group_ingress_from_port=""
          security_group_ingress_to_port=""
          security_group_ingress_cidr_blocks_depth=0
        fi
      fi

      opens="${active_line//[^\{]/}"
      closes="${active_line//[^\}]/}"
      security_group_depth=$((security_group_depth + ${#opens} - ${#closes}))

      if [[ "$security_group_depth" -le 0 ]]; then
        in_security_group=0
        security_group_depth=0
        security_group_name=""
        in_security_group_ingress=0
        security_group_ingress_depth=0
        security_group_ingress_has_public=0
        security_group_ingress_from_port=""
        security_group_ingress_to_port=""
        security_group_ingress_cidr_blocks_depth=0
      fi
    fi
  done <"$tf_file"

  return "$failed"
}

run_security_group_audit() {
  local -a audit_dirs=("$@")
  local module_spec module_dir tf_file
  local failed=0

  # Default scope: only real module directories (no fixtures).
  if [[ "${#audit_dirs[@]}" -eq 0 ]]; then
    for module_spec in "${MODULE_SPECS[@]}"; do
      module_dir="$(module_abs_dir_from_spec "$module_spec")"
      audit_dirs+=("$module_dir")
    done
  fi

  for module_dir in "${audit_dirs[@]}"; do
    if [[ ! -d "$module_dir" ]]; then
      echo "ERROR: security-group audit directory missing: $module_dir" >&2
      failed=1
      continue
    fi

    while IFS= read -r -d '' tf_file; do
      if ! run_sg_audit_for_file "$tf_file"; then
        failed=1
      fi
    done < <(find "$module_dir" -type f -name '*.tf' -print0)
  done

  if [[ "$failed" -eq 0 ]]; then
    echo "Security-group audit passed (public 0.0.0.0/0 ingress limited to ports 80/443)."
  fi

  return "$failed"
}

assert_janitor_contract_pattern() {
  local pattern="$1"
  local description="$2"
  if grep -Eq -- "$pattern" "$JANITOR_SCRIPT"; then
    return 0
  fi

  echo "ERROR: janitor contract check failed: ${description}" >&2
  return 1
}

run_live_e2e_ttl_janitor_contract_audit() {
  local failed=0

  echo "==> janitor contract audit: ${JANITOR_SCRIPT_RELATIVE_PATH}"

  if [[ ! -f "$JANITOR_SCRIPT" ]]; then
    echo "ERROR: janitor script missing: ${JANITOR_SCRIPT_RELATIVE_PATH}" >&2
    return 1
  fi

  if [[ ! -x "$JANITOR_SCRIPT" ]]; then
    echo "ERROR: janitor script must be executable: ${JANITOR_SCRIPT_RELATIVE_PATH}" >&2
    failed=1
  fi

  if ! assert_janitor_contract_pattern '--help' "help entrypoint is missing"; then
    failed=1
  fi
  if ! assert_janitor_contract_pattern '--execute' "execute flag gate is missing"; then
    failed=1
  fi
  if ! assert_janitor_contract_pattern 'FJCLOUD_ALLOW_LIVE_E2E_DELETE=1' "explicit delete env gate value is missing"; then
    failed=1
  fi
  if ! assert_janitor_contract_pattern 'resourcegroupstaggingapi get-resources' "tagging API discovery contract is missing"; then
    failed=1
  fi
  if ! assert_janitor_contract_pattern 'test_run_id' "test_run_id tag contract is missing"; then
    failed=1
  fi
  if ! assert_janitor_contract_pattern 'owner' "owner tag contract is missing"; then
    failed=1
  fi
  if ! assert_janitor_contract_pattern 'ttl_expires_at' "ttl_expires_at tag contract is missing"; then
    failed=1
  fi
  if ! assert_janitor_contract_pattern 'environment' "environment tag contract is missing"; then
    failed=1
  fi

  if grep -Eq 'AWS_SECRET_ACCESS_KEY|AWS_SESSION_TOKEN' "$JANITOR_SCRIPT"; then
    echo "ERROR: janitor script includes secret-looking token names in output paths" >&2
    failed=1
  fi

  if [[ "$failed" -eq 0 ]]; then
    echo "Janitor contract audit passed (presence and safety gates only; no destructive actions)."
  fi

  return "$failed"
}

main() {
  local -a audit_dirs=()
  local budget_guardrail_artifact=""
  local terraform_status=0
  local audit_status=0
  local janitor_contract_status=0

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --audit-dir)
        if [[ "$#" -lt 2 ]]; then
          echo "ERROR: --audit-dir requires a path argument" >&2
          exit 1
        fi
        audit_dirs+=("$2")
        shift 2
        ;;
      --budget-guardrail-artifact)
        if [[ "$#" -lt 2 ]]; then
          echo "ERROR: --budget-guardrail-artifact requires a path argument" >&2
          exit 1
        fi
        budget_guardrail_artifact="$2"
        shift 2
        ;;
      *)
        echo "ERROR: unknown argument: $1" >&2
        exit 1
        ;;
    esac
  done

  if [[ -n "$budget_guardrail_artifact" ]]; then
    run_budget_guardrail_artifact_validation "$budget_guardrail_artifact"
    return $?
  fi

  if command -v terraform >/dev/null 2>&1; then
    run_terraform_validation || terraform_status=$?
  else
    echo "WARN: terraform is not installed; skipping terraform init/validate (deferred to CI/Stuart environment)."
  fi

  if [[ "${#audit_dirs[@]}" -gt 0 ]]; then
    run_security_group_audit "${audit_dirs[@]}" || audit_status=$?
  else
    run_security_group_audit || audit_status=$?
  fi

  run_live_e2e_ttl_janitor_contract_audit || janitor_contract_status=$?

  if [[ "$terraform_status" -ne 0 || "$audit_status" -ne 0 || "$janitor_contract_status" -ne 0 ]]; then
    exit 1
  fi
}

main "$@"
