#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

validate_script="ops/terraform/validate_all.sh"
janitor_script="ops/scripts/live_e2e_ttl_janitor.sh"
bootstrap_script="ops/user-data/bootstrap.sh"
cloud_init_file="infra/api/src/provisioner/cloud_init.rs"
packer_file="ops/packer/flapjack-ami.pkr.hcl"
publication_script="ops/terraform/publish_support_email_canary_image.sh"
publication_dockerfile="ops/terraform/support_email_canary/Dockerfile"
publication_lambda_handler="ops/terraform/support_email_canary/lambda_handler.py"

assert_file_exists "$validate_script" "validate_all.sh exists"
if [[ -x "$validate_script" ]]; then
  pass "validate_all.sh is executable"
else
  fail "validate_all.sh is executable"
fi
assert_file_contains "$validate_script" 'networking' "validate_all.sh references networking module"
assert_file_contains "$validate_script" 'compute' "validate_all.sh references compute module"
assert_file_contains "$validate_script" 'data' "validate_all.sh references data module"
assert_file_contains "$validate_script" 'dns' "validate_all.sh references dns module"
assert_file_contains "$validate_script" 'monitoring' "validate_all.sh references monitoring module"
assert_file_contains "$validate_script" '_shared' "validate_all.sh references _shared module"
assert_file_contains "$validate_script" 'iam' "validate_all.sh references iam module"
assert_file_contains "$validate_script" '../iam' "validate_all.sh handles iam module path outside ops/terraform"
assert_file_contains "$validate_script" 'terraform init -backend=false' "validate_all.sh runs terraform init with backend disabled"
assert_file_contains "$validate_script" 'terraform validate' "validate_all.sh runs terraform validate"
assert_file_contains "$validate_script" 'run_security_group_audit' "validate_all.sh defines security-group audit entrypoint"
assert_file_contains "$validate_script" '0.0.0.0/0' "validate_all.sh audits for 0.0.0.0/0 ingress"
assert_file_contains "$validate_script" '80' "validate_all.sh allows port 80 for public ingress"
assert_file_contains "$validate_script" '443' "validate_all.sh allows port 443 for public ingress"
assert_file_contains "$validate_script" 'run_live_e2e_ttl_janitor_contract_audit' "validate_all.sh defines janitor contract audit entrypoint"
assert_file_contains "$validate_script" 'ops/scripts/live_e2e_ttl_janitor.sh' "validate_all.sh validates janitor contract owner path"
assert_file_contains "$validate_script" 'FJCLOUD_ALLOW_LIVE_E2E_DELETE=1' "validate_all.sh enforces explicit delete gate value in janitor contract"
assert_file_contains "$validate_script" '\-\-execute' "validate_all.sh checks janitor execute gate flag"
assert_file_contains "$validate_script" 'resourcegroupstaggingapi get-resources' "validate_all.sh checks janitor tagging API discovery contract"

assert_file_exists "$janitor_script" "live_e2e_ttl_janitor.sh exists"
if [[ -x "$janitor_script" ]]; then
  pass "live_e2e_ttl_janitor.sh is executable"
else
  fail "live_e2e_ttl_janitor.sh is executable"
fi
assert_file_contains "$janitor_script" '\-\-help' "live_e2e_ttl_janitor.sh exposes --help"
assert_file_contains "$janitor_script" '\-\-execute' "live_e2e_ttl_janitor.sh supports execute mode gate"
assert_file_contains "$janitor_script" 'FJCLOUD_ALLOW_LIVE_E2E_DELETE=1' "live_e2e_ttl_janitor.sh requires env gate for deletes"
assert_file_contains "$janitor_script" 'resourcegroupstaggingapi get-resources' "live_e2e_ttl_janitor.sh uses tagging API for discovery"
assert_file_contains "$janitor_script" 'test_run_id' "live_e2e_ttl_janitor.sh requires test_run_id tag"
assert_file_contains "$janitor_script" 'owner' "live_e2e_ttl_janitor.sh requires owner tag"
assert_file_contains "$janitor_script" 'ttl_expires_at' "live_e2e_ttl_janitor.sh requires ttl_expires_at tag"
assert_file_contains "$janitor_script" 'environment' "live_e2e_ttl_janitor.sh requires environment tag"

assert_file_exists "$publication_script" "publish_support_email_canary_image.sh exists"
if [[ -x "$publication_script" ]]; then
  pass "publish_support_email_canary_image.sh is executable"
else
  fail "publish_support_email_canary_image.sh is executable"
fi
assert_file_exists "$publication_dockerfile" "support_email_canary Dockerfile exists"
assert_file_exists "$publication_lambda_handler" "support_email_canary lambda_handler.py exists"
assert_file_contains "$publication_script" 'docker build' "publish script builds support_email_canary image"
assert_file_contains "$publication_script" 'docker push' "publish script pushes support_email_canary image"
assert_file_contains "$publication_script" 'support_email_canary/Dockerfile' "publish script uses support_email_canary Dockerfile"
assert_file_contains "$publication_dockerfile" 'scripts/canary/support_email_deliverability.sh' "support_email_canary Dockerfile delegates to support_email_deliverability.sh"
assert_file_contains "$publication_dockerfile" 'scripts/validate_inbound_email_roundtrip.sh' "support_email_canary Dockerfile delegates to validate_inbound_email_roundtrip.sh"
assert_file_contains "$publication_lambda_handler" 'support_email_deliverability.sh' "support_email_canary lambda handler delegates to support_email_deliverability.sh"

tmp_output="$(mktemp)"
if PATH="/usr/bin:/bin" bash "$validate_script" >"$tmp_output" 2>&1; then
  pass "validate_all.sh runs audit-only mode when terraform is unavailable"
else
  fail "validate_all.sh runs audit-only mode when terraform is unavailable"
fi
rm -f "$tmp_output"

tmp_output="$(mktemp)"
if PATH="/usr/bin:/bin" bash "$validate_script" --audit-dir "ops/terraform/fixtures" >"$tmp_output" 2>&1; then
  fail "validate_all.sh fails SG audit on violating fixture"
else
  pass "validate_all.sh fails SG audit on violating fixture"
fi
if rg -q 'insecure public ingress' "$tmp_output"; then
  pass "validate_all.sh reports insecure ingress details for violating fixture"
else
  fail "validate_all.sh reports insecure ingress details for violating fixture"
fi
rm -f "$tmp_output"

tmp_output="$(mktemp)"
if PATH="/usr/bin:/bin" bash "$validate_script" --audit-dir "ops/terraform/fixtures/safe" >"$tmp_output" 2>&1; then
  pass "validate_all.sh ignores commented public-ingress lines"
else
  fail "validate_all.sh ignores commented public-ingress lines"
fi
rm -f "$tmp_output"

tmp_output="$(mktemp)"
if PATH="/usr/bin:/bin" bash "$validate_script" --audit-dir "ops/terraform/fixtures/inline" >"$tmp_output" 2>&1; then
  fail "validate_all.sh fails SG audit on insecure inline aws_security_group ingress"
else
  pass "validate_all.sh fails SG audit on insecure inline aws_security_group ingress"
fi
if rg -q 'resource=fixture_inline_sg' "$tmp_output"; then
  pass "validate_all.sh reports insecure inline aws_security_group resource details"
else
  fail "validate_all.sh reports insecure inline aws_security_group resource details"
fi
rm -f "$tmp_output"

tmp_output="$(mktemp)"
if PATH="/usr/bin:/bin" bash "$validate_script" --audit-dir "ops/terraform/fixtures/multiline" >"$tmp_output" 2>&1; then
  fail "validate_all.sh fails SG audit on insecure multiline cidr_blocks ingress"
else
  pass "validate_all.sh fails SG audit on insecure multiline cidr_blocks ingress"
fi
if rg -q 'resource=fixture_multiline_public' "$tmp_output"; then
  pass "validate_all.sh reports insecure multiline cidr_blocks resource details"
else
  fail "validate_all.sh reports insecure multiline cidr_blocks resource details"
fi
rm -f "$tmp_output"

assert_file_exists "$bootstrap_script" "bootstrap.sh exists"
assert_file_contains "$bootstrap_script" 'X-aws-ec2-metadata-token-ttl-seconds: 21600' "bootstrap.sh uses IMDS token TTL 21600"
assert_file_contains "$bootstrap_script" 'meta-data/tags/instance/customer_id' "bootstrap.sh reads customer_id from IMDS tags"
assert_file_contains "$bootstrap_script" 'meta-data/tags/instance/node_id' "bootstrap.sh reads node_id from IMDS tags"

assert_file_exists "$cloud_init_file" "cloud_init.rs exists"
assert_file_contains "$cloud_init_file" 'FLAPJACK_URL=' "cloud_init.rs writes FLAPJACK_URL to metering env"
assert_file_contains "$cloud_init_file" 'NODE_ID=' "cloud_init.rs writes NODE_ID to metering env"
assert_file_contains "$cloud_init_file" 'INTERNAL_KEY=' "cloud_init.rs writes INTERNAL_KEY to metering env"
assert_file_contains "$cloud_init_file" 'TENANT_MAP_URL=' "cloud_init.rs writes TENANT_MAP_URL to metering env"
assert_file_contains "$cloud_init_file" 'COLD_STORAGE_USAGE_URL=' "cloud_init.rs writes COLD_STORAGE_USAGE_URL to metering env"

assert_file_exists "$packer_file" "flapjack-ami.pkr.hcl exists"
assert_file_contains "$packer_file" 'source "amazon-ebs"' "packer template uses amazon-ebs source"
assert_file_contains "$packer_file" '../user-data/bootstrap.sh' "packer template copies bootstrap.sh into AMI"
assert_file_contains "$packer_file" 'packer \{' "packer template declares packer block"
assert_file_contains "$packer_file" 'required_version' "packer template declares required_version constraint"

# ============================================================================
# Stage 3 — Packer AMI contract: staging binary provisioning
# ============================================================================

# Packer must provision the three staging binaries, not legacy flapjack alone
assert_file_contains "$packer_file" '\$\{var.binary_dir\}/flapjack' "Packer template provisions flapjack engine binary"
assert_file_contains "$packer_file" 'fjcloud-api' "Packer template provisions fjcloud-api binary"
assert_file_contains "$packer_file" 'fjcloud-aggregation-job' "Packer template provisions fjcloud-aggregation-job binary"
assert_file_contains "$packer_file" 'fj-metering-agent' "Packer template provisions fj-metering-agent binary"

# Packer must create the fjcloud system user and directories
assert_file_contains "$packer_file" 'useradd.*fjcloud' "Packer template creates fjcloud system user"
assert_file_contains "$packer_file" '/var/lib/fjcloud' "Packer template creates /var/lib/fjcloud"
assert_file_contains "$packer_file" '/var/log/fjcloud' "Packer template creates /var/log/fjcloud"
assert_file_contains "$packer_file" '/etc/fjcloud' "Packer template creates /etc/fjcloud"

# Packer must tag AMI with Env for environment identification
assert_file_contains "$packer_file" 'Env' "Packer template tags AMI with Env"

# Packer must declare env variable for Env tag
assert_file_contains "$packer_file" 'variable "env"' "Packer template declares env variable"

# Packer binary install must match deploy.sh BINARIES array contract
assert_file_contains "$packer_file" 'install.*flapjack.*/usr/local/bin/flapjack' "Packer installs flapjack to /usr/local/bin/flapjack"
assert_file_contains "$packer_file" 'install.*fjcloud-api.*/usr/local/bin' "Packer installs fjcloud-api to /usr/local/bin"
assert_file_contains "$packer_file" 'install.*fjcloud-aggregation-job.*/usr/local/bin' "Packer installs fjcloud-aggregation-job to /usr/local/bin"
assert_file_contains "$packer_file" 'install.*fj-metering-agent.*/usr/local/bin' "Packer installs fj-metering-agent to /usr/local/bin"

# Packer must install firewalld before configuring firewall rules
assert_file_contains "$packer_file" 'dnf install.*firewalld' "Packer template installs firewalld before configuring firewall rules"

# ============================================================================
# Stage 3 — Metering agent service: fjcloud user consistency
# ============================================================================

systemd_metering_file="ops/systemd/fj-metering-agent.service"
assert_file_contains "$systemd_metering_file" '^User=fjcloud' "Metering agent uses User=fjcloud (not flapjack)"
assert_file_contains "$systemd_metering_file" '^Group=fjcloud' "Metering agent uses Group=fjcloud (not flapjack)"
assert_file_contains "$systemd_metering_file" 'EnvironmentFile.*-?/etc/fjcloud/' "Metering agent EnvironmentFile under /etc/fjcloud/"

test_summary "IaC validation static checks"
