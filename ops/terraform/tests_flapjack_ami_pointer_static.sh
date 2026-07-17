#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

root_main="ops/terraform/_shared/main.tf"
root_variables="ops/terraform/_shared/variables.tf"
runtime_main="ops/terraform/runtime_params/main.tf"

assert_file_contains "$root_main" 'ami_id[[:space:]]*=[[:space:]]*var\.api_ami_id' \
  "compute receives the explicit API AMI"
assert_file_contains "$root_main" 'ami_id[[:space:]]*=[[:space:]]*var\.flapjack_ami_id' \
  "runtime parameters receive the explicit Flapjack AMI"
assert_file_contains "$root_variables" 'variable "api_ami_id"' \
  "root declares api_ami_id"
assert_file_contains "$root_variables" 'variable "flapjack_ami_id"' \
  "root declares flapjack_ami_id"
assert_file_not_contains "$root_variables" 'variable "ami_id"' \
  "root no longer exposes the coupled ami_id input"
assert_file_not_contains "$root_variables" 'default[[:space:]]*=[[:space:]]*var\.(api|flapjack)_ami_id' \
  "neither AMI variable copies the other by default"
assert_file_contains "$root_variables" 'trimspace\(var\.api_ami_id\)[[:space:]]*!=[[:space:]]*""' \
  "api_ami_id rejects empty input"
assert_file_contains "$root_variables" 'trimspace\(var\.flapjack_ami_id\)[[:space:]]*!=[[:space:]]*""' \
  "flapjack_ami_id rejects empty input"
assert_resource_block_contains "$runtime_main" "aws_ssm_parameter" "runtime_aws_ami_id" \
  'name[[:space:]]*=[[:space:]]*"/fjcloud/\$\{var\.env\}/aws_ami_id"' \
  "runtime pointer keeps its frozen external name"
assert_resource_block_contains "$runtime_main" "aws_ssm_parameter" "runtime_aws_ami_id" \
  'ignore_changes[[:space:]]*=[[:space:]]*\[value\]' \
  "runtime pointer ignores operational value drift"

test_summary "Flapjack AMI pointer static contract"
