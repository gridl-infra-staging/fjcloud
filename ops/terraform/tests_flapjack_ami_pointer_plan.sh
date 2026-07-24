#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT

mkdir -p "$fixture_dir/compute" "$fixture_dir/runtime_params"
cp "$repo_root/ops/terraform/compute/main.tf" \
  "$repo_root/ops/terraform/compute/variables.tf" \
  "$repo_root/ops/terraform/compute/outputs.tf" \
  "$fixture_dir/compute/"
# The production compute module configures AWS itself. Tests inherit the
# mocked root provider while retaining the production resource and schema.
sed '/^provider "aws"/,$d' "$repo_root/ops/terraform/compute/providers.tf" \
  >"$fixture_dir/compute/providers.tf"
cp "$repo_root/ops/terraform/runtime_params/main.tf" \
  "$repo_root/ops/terraform/runtime_params/variables.tf" \
  "$repo_root/ops/terraform/runtime_params/providers.tf" \
  "$fixture_dir/runtime_params/"

cat >"$fixture_dir/main.tf" <<'EOF'
terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
    tls = { source = "hashicorp/tls" }
  }
}

variable "env" { type = string }
variable "api_ami_id" { type = string }
variable "flapjack_ami_id" { type = string }

module "compute" {
  source                = "./compute"
  env                   = var.env
  region                = "us-east-1"
  ami_id                = var.api_ami_id
  private_subnet_ids    = ["subnet-test"]
  sg_api_id             = "sg-test"
  instance_profile_name = "profile-test"
}

module "runtime_params" {
  source                     = "./runtime_params"
  env                        = var.env
  ami_id                     = var.flapjack_ami_id
  subnet_id                  = "subnet-test"
  security_group_ids         = "sg-test"
  key_pair_name              = "key-test"
  instance_profile_name      = "profile-test"
  cloudflare_zone_id         = "zone-test"
  dns_domain                 = "example.test"
  ses_configuration_set_name = "ses-test"
}
EOF

cat >"$fixture_dir/pointer.tftest.hcl" <<'EOF'
mock_provider "aws" {}
mock_provider "tls" {}

run "baseline_staging" {
  command = apply
  variables {
    env             = "staging"
    api_ami_id      = "ami-api-old"
    flapjack_ami_id = "ami-flapjack-old"
  }
}

# The state holds the old pointer while configuration carries a new value.
# ignore_changes models the same state/config difference as live SSM drift.
run "flapjack_staging_change_and_operational_drift" {
  command = plan
  variables {
    env             = "staging"
    api_ami_id      = "ami-api-old"
    flapjack_ami_id = "ami-flapjack-new"
  }
}

run "api_staging_change" {
  command = plan
  variables {
    env             = "staging"
    api_ami_id      = "ami-api-new"
    flapjack_ami_id = "ami-flapjack-old"
  }
}

run "baseline_prod" {
  command = apply
  variables {
    env             = "prod"
    api_ami_id      = "ami-api-old"
    flapjack_ami_id = "ami-flapjack-old"
  }
}

run "flapjack_prod_change_and_operational_drift" {
  command = plan
  variables {
    env             = "prod"
    api_ami_id      = "ami-api-old"
    flapjack_ami_id = "ami-flapjack-new"
  }
}

run "api_prod_change" {
  command = plan
  variables {
    env             = "prod"
    api_ami_id      = "ami-api-new"
    flapjack_ami_id = "ami-flapjack-old"
  }
}
EOF

plan_output="$fixture_dir/terraform_test.out"
(
  cd "$fixture_dir"
  terraform init -backend=false -input=false >/dev/null
  terraform test -verbose -no-color
) >"$plan_output"

extract_run_section() {
  local run_name="$1"
  awk -v marker="run \"${run_name}\"" '
    $0 ~ marker { in_section = 1 }
    in_section && /^[[:space:]]*run "/ && $0 !~ marker { exit }
    in_section { print }
  ' "$plan_output"
}

fixture_run_variable() {
  local fixture_file="$1"
  local run_name="$2"
  local variable_name="$3"
  awk -v run_marker="run \"${run_name}\"" -v variable_name="$variable_name" '
    !in_run && index($0, run_marker) { in_run = 1 }
    in_run {
      opens = gsub(/{/, "{", $0)
      closes = gsub(/}/, "}", $0)
      depth += opens - closes

      if ($1 == variable_name && $2 == "=") {
        value = $0
        sub("^[[:space:]]*" variable_name "[[:space:]]*=[[:space:]]*\"", "", value)
        sub("\"[[:space:]]*$", "", value)
        print value
        exit
      }

      if (depth == 0) { exit }
    }
  ' "$fixture_file"
}

fixture_run_has_distinct_ami_inputs() {
  local fixture_file="$1"
  local run_name="$2"
  local api_ami_id flapjack_ami_id
  api_ami_id="$(fixture_run_variable "$fixture_file" "$run_name" api_ami_id)"
  flapjack_ami_id="$(fixture_run_variable "$fixture_file" "$run_name" flapjack_ami_id)"

  [[ -n "$api_ami_id" && -n "$flapjack_ami_id" && "$api_ami_id" != "$flapjack_ami_id" ]]
}

assert_section_nonempty() {
  local section="$1"
  local label="$2"
  if [[ -n "$section" ]]; then
    pass "$label"
  else
    fail "$label"
  fi
}

assert_distinct_inputs() {
  local env_name="$1"
  if fixture_run_has_distinct_ami_inputs \
      "$fixture_dir/pointer.tftest.hcl" "baseline_${env_name}"; then
    pass "${env_name}: API and Flapjack AMI test inputs are nonempty and distinct"
  else
    fail "${env_name}: API and Flapjack AMI test inputs are nonempty and distinct"
  fi
}

assert_recoupled_fixture_is_rejected() {
  local recoupled_fixture="$fixture_dir/recoupled_pointer.tftest.hcl"
  sed 's/flapjack_ami_id = "ami-flapjack-old"/flapjack_ami_id = "ami-api-old"/' \
    "$fixture_dir/pointer.tftest.hcl" >"$recoupled_fixture"

  if fixture_run_has_distinct_ami_inputs "$recoupled_fixture" "baseline_staging" \
      || fixture_run_has_distinct_ami_inputs "$recoupled_fixture" "baseline_prod"; then
    fail "Recoupled staging and prod fixtures fail the distinct-input invariant"
  else
    pass "Recoupled staging and prod fixtures fail the distinct-input invariant"
  fi
}

assert_env_plan_contract() {
  local env_name="$1"
  local flapjack_plan api_plan
  assert_distinct_inputs "$env_name"

  flapjack_plan="$(extract_run_section "flapjack_${env_name}_change_and_operational_drift")"
  api_plan="$(extract_run_section "api_${env_name}_change")"
  assert_section_nonempty "$flapjack_plan" "${env_name}: Flapjack plan classifier has a nonempty denominator"
  assert_section_nonempty "$api_plan" "${env_name}: API plan classifier has a nonempty denominator"

  if rg -q 'No changes\.' <<<"$flapjack_plan"; then
    pass "${env_name}: Flapjack-only change and operational pointer drift produce no plan"
  else
    fail "${env_name}: Flapjack-only change and operational pointer drift produce no plan"
  fi

  if rg -q 'aws_instance\.api.*(destroy|replace)|-/\+ resource "aws_instance" "api"' <<<"$flapjack_plan"; then
    fail "${env_name}: Flapjack-only change does not replace the API instance"
  else
    pass "${env_name}: Flapjack-only change does not replace the API instance"
  fi

  if rg -q 'module\.compute\.aws_instance\.api' <<<"$api_plan"; then
    pass "${env_name}: API-only change is isolated to the compute instance"
  else
    fail "${env_name}: API-only change is isolated to the compute instance"
  fi

  if rg -q 'runtime_aws_ami_id' <<<"$api_plan"; then
    fail "${env_name}: API-only change does not rewrite the runtime pointer"
  else
    pass "${env_name}: API-only change does not rewrite the runtime pointer"
  fi
}

assert_recoupled_fixture_is_rejected
assert_env_plan_contract staging
assert_env_plan_contract prod

test_summary "Flapjack AMI pointer Terraform plan contract"
