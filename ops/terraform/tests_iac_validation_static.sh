#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

validate_script="ops/terraform/validate_all.sh"
janitor_script="ops/scripts/live_e2e_ttl_janitor.sh"
bootstrap_script="ops/user-data/bootstrap.sh"
cloud_init_file="infra/api/src/provisioner/cloud_init.rs"
packer_file="ops/packer/flapjack-ami.pkr.hcl"
caddy_unit_file="ops/systemd/caddy.service"
publication_script="ops/terraform/publish_support_email_canary_image.sh"
publication_dockerfile="ops/terraform/support_email_canary/Dockerfile"
publication_lambda_handler="ops/terraform/support_email_canary/lambda_handler.py"

assert_file_executable() {
  local file="$1"
  local description="$2"
  assert_file_exists "$file" "${description} exists"
  if [[ -x "$file" ]]; then
    pass "${description} is executable"
  else
    fail "${description} is executable"
  fi
}

assert_pattern_order() {
  local file="$1"
  local first_pattern="$2"
  local second_pattern="$3"
  local description="$4"
  local first_line
  local second_line

  first_line=$(rg -n "$first_pattern" "$file" | head -n 1 | cut -d: -f1 || true)
  second_line=$(rg -n "$second_pattern" "$file" | head -n 1 | cut -d: -f1 || true)

  if [[ -n "$first_line" && -n "$second_line" && "$first_line" -lt "$second_line" ]]; then
    pass "$description"
  else
    fail "$description"
  fi
}

assert_caddy_configure_block_has_no_exit() {
  local file="$1"
  local description="$2"
  local block

  block=$(awk '
    /^configure_caddy\(\)[[:space:]]*\{/ { in_block = 1 }
    in_block { print }
    in_block && /^}[[:space:]]*$/ { exit }
  ' "$file")

  if [[ -z "$block" ]]; then
    fail "$description (configure_caddy block missing)"
    return
  fi

  if rg -q '^[[:space:]]*exit([[:space:]]|$)' <<<"$block"; then
    fail "$description"
  else
    pass "$description"
  fi
}

assert_validate_script_result() {
  local description="$1"
  local expected_success="$2"
  local audit_dir="${3:-}"
  local expected_output_pattern="${4:-}"
  local expected_output_description="${5:-}"
  local tmp_output
  local cmd=(bash "$validate_script")

  if [[ -n "$audit_dir" ]]; then
    cmd+=(--audit-dir "$audit_dir")
  fi

  tmp_output="$(mktemp)"
  if PATH="/usr/bin:/bin" "${cmd[@]}" >"$tmp_output" 2>&1; then
    if [[ "$expected_success" == "1" ]]; then
      pass "$description"
    else
      fail "$description"
    fi
  else
    if [[ "$expected_success" == "1" ]]; then
      fail "$description"
    else
      pass "$description"
    fi
  fi

  if [[ -n "$expected_output_pattern" ]]; then
    if rg -q "$expected_output_pattern" "$tmp_output"; then
      pass "$expected_output_description"
    else
      fail "$expected_output_description"
    fi
  fi

  rm -f "$tmp_output"
}

assert_file_executable "$validate_script" "validate_all.sh"
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
assert_file_contains "$validate_script" 'flapjack_public_data_plane' "validate_all.sh names the public Flapjack data-plane exception"
assert_file_contains "$validate_script" '7700' "validate_all.sh shape-checks public Flapjack port 7700"
assert_file_contains "$validate_script" 'tcp' "validate_all.sh shape-checks public ingress protocols"
assert_file_contains "$validate_script" 'run_live_e2e_ttl_janitor_contract_audit' "validate_all.sh defines janitor contract audit entrypoint"
assert_file_contains "$validate_script" 'ops/scripts/live_e2e_ttl_janitor.sh' "validate_all.sh validates janitor contract owner path"
assert_file_contains "$validate_script" 'FJCLOUD_ALLOW_LIVE_E2E_DELETE=1' "validate_all.sh enforces explicit delete gate value in janitor contract"
assert_file_contains "$validate_script" '\-\-execute' "validate_all.sh checks janitor execute gate flag"
assert_file_contains "$validate_script" 'resourcegroupstaggingapi get-resources' "validate_all.sh checks janitor tagging API discovery contract"

assert_file_executable "$janitor_script" "live_e2e_ttl_janitor.sh"
assert_file_contains "$janitor_script" '\-\-help' "live_e2e_ttl_janitor.sh exposes --help"
assert_file_contains "$janitor_script" '\-\-execute' "live_e2e_ttl_janitor.sh supports execute mode gate"
assert_file_contains "$janitor_script" 'FJCLOUD_ALLOW_LIVE_E2E_DELETE=1' "live_e2e_ttl_janitor.sh requires env gate for deletes"
assert_file_contains "$janitor_script" 'resourcegroupstaggingapi get-resources' "live_e2e_ttl_janitor.sh uses tagging API for discovery"
assert_file_contains "$janitor_script" 'test_run_id' "live_e2e_ttl_janitor.sh requires test_run_id tag"
assert_file_contains "$janitor_script" 'owner' "live_e2e_ttl_janitor.sh requires owner tag"
assert_file_contains "$janitor_script" 'ttl_expires_at' "live_e2e_ttl_janitor.sh requires ttl_expires_at tag"
assert_file_contains "$janitor_script" 'environment' "live_e2e_ttl_janitor.sh requires environment tag"

assert_file_executable "$publication_script" "publish_support_email_canary_image.sh"
assert_file_exists "$publication_dockerfile" "support_email_canary Dockerfile exists"
assert_file_exists "$publication_lambda_handler" "support_email_canary lambda_handler.py exists"
assert_file_contains "$publication_script" 'source .*publish_canary_image_shared\.sh' "publish script sources shared canary publish helper"
assert_file_not_contains "$publication_script" '^[[:space:]]*docker build' "publish script does not own inline docker build body"
assert_file_not_contains "$publication_script" 'docker push' "publish script does not own inline docker push body"
assert_file_not_contains "$publication_script" 'aws ecr get-login-password' "publish script does not own inline ECR login flow"
assert_file_contains "$publication_script" 'support_email_canary/Dockerfile' "publish script uses support_email_canary Dockerfile"
assert_file_contains "$publication_dockerfile" 'scripts/canary/support_email_deliverability.sh' "support_email_canary Dockerfile delegates to support_email_deliverability.sh"
assert_file_contains "$publication_dockerfile" 'scripts/validate_inbound_email_roundtrip.sh' "support_email_canary Dockerfile delegates to validate_inbound_email_roundtrip.sh"
assert_file_contains "$publication_lambda_handler" 'support_email_deliverability.sh' "support_email_canary lambda handler delegates to support_email_deliverability.sh"

assert_validate_script_result "validate_all.sh runs audit-only mode when terraform is unavailable" 1
assert_validate_script_result "validate_all.sh accepts the exact named TCP 7700 Flapjack fixture" 1 "ops/terraform/fixtures/safe"
assert_validate_script_result "validate_all.sh rejects a differently named public TCP 7700 rule" 0 "ops/terraform/fixtures/wrong_name_public_7700" 'insecure public ingress.*resource=fixture_public_data_plane' "validate_all.sh reports the unexpected public 7700 resource name"
assert_validate_script_result "validate_all.sh rejects the named public 7700 rule with the wrong protocol" 0 "ops/terraform/fixtures/wrong_protocol_public_data_plane" 'insecure public ingress.*resource=flapjack_public_data_plane.*from_port=7700.*to_port=7700.*protocol=udp' "validate_all.sh reports the wrong public data-plane protocol"
assert_validate_script_result "validate_all.sh rejects the named public 7700 rule with the wrong range" 0 "ops/terraform/fixtures/wrong_range_public_data_plane" 'insecure public ingress.*resource=flapjack_public_data_plane.*from_port=7700.*to_port=7701.*protocol=tcp' "validate_all.sh reports the wrong public data-plane port range"
assert_validate_script_result "validate_all.sh fails SG audit on the public SSH fixture" 0 "ops/terraform/fixtures" 'insecure public ingress.*resource=fixture_ssh_public.*from_port=22.*to_port=22' "validate_all.sh reports insecure ingress details for the public SSH fixture"
assert_validate_script_result "validate_all.sh ignores commented public-ingress lines" 1 "ops/terraform/fixtures/safe"
assert_validate_script_result "validate_all.sh fails SG audit on insecure inline aws_security_group ingress" 0 "ops/terraform/fixtures/inline" 'resource=fixture_inline_sg' "validate_all.sh reports insecure inline aws_security_group resource details"
assert_validate_script_result "validate_all.sh fails SG audit on insecure multiline cidr_blocks ingress" 0 "ops/terraform/fixtures/multiline" 'resource=fixture_multiline_public' "validate_all.sh reports insecure multiline cidr_blocks resource details"

assert_file_exists "$bootstrap_script" "bootstrap.sh exists"
assert_file_contains "$bootstrap_script" 'X-aws-ec2-metadata-token-ttl-seconds: 21600' "bootstrap.sh uses IMDS token TTL 21600"
assert_file_contains "$bootstrap_script" 'meta-data/tags/instance/customer_id' "bootstrap.sh reads customer_id from IMDS tags"
assert_file_contains "$bootstrap_script" 'meta-data/tags/instance/node_id' "bootstrap.sh reads node_id from IMDS tags"
assert_file_contains "$bootstrap_script" 'meta-data/tags/instance/Name' "bootstrap.sh reads Name from IMDS tags for served hostname"
assert_file_contains "$bootstrap_script" 'Name=fj-' "bootstrap.sh documents the Name=fj-{hostname} hostname source"
assert_file_contains "$bootstrap_script" 'NODE_ID.*\*.\*' "bootstrap.sh falls back to NODE_ID only when it is already an FQDN"
assert_file_contains "$bootstrap_script" 'FLAPJACK_DISABLE_DASHBOARD=1' "bootstrap.sh disables unauthenticated Flapjack dashboard"
assert_file_contains "$bootstrap_script" 'umask 077' "bootstrap.sh restricts secret env file permissions from first write"
assert_file_contains "$bootstrap_script" 'systemctl enable --now flapjack fj-metering-agent' "bootstrap.sh atomically enables and starts Flapjack plus metering agent"
assert_file_not_contains "$bootstrap_script" '^systemctl enable flapjack fj-metering-agent$' "bootstrap.sh does not split metering service enablement from start"
assert_file_not_contains "$bootstrap_script" '^systemctl start flapjack fj-metering-agent$' "bootstrap.sh does not start metering service separately after enablement"
assert_file_contains "$bootstrap_script" 'cat > /etc/caddy/Caddyfile' "bootstrap.sh renders /etc/caddy/Caddyfile"
assert_file_contains "$bootstrap_script" 'reverse_proxy 127\.0\.0\.1:7700' "bootstrap.sh Caddyfile proxies to the local Flapjack engine"
assert_file_contains "$bootstrap_script" '^is_safe_caddy_hostname\(\)' "bootstrap.sh defines served-hostname validation before writing Caddy config"
assert_file_contains "$bootstrap_script" 'unsafe served hostname' "bootstrap.sh skips Caddy setup for invalid served hostnames"
assert_file_contains "$bootstrap_script" 'systemctl enable --now caddy' "bootstrap.sh enables and starts Caddy"
assert_file_contains "$bootstrap_script" 'systemctl reload-or-restart caddy' "bootstrap.sh reloads active Caddy after rewriting the Caddyfile"
assert_file_contains "$bootstrap_script" 'WARN.*Caddy' "bootstrap.sh logs and skips Caddy setup failures"
assert_file_not_contains "$bootstrap_script" '/etc/caddy/Caddyfile.*\$API_KEY|/etc/caddy/Caddyfile.*\$DB_URL|/etc/caddy/Caddyfile.*\$INTERNAL_AUTH_TOKEN' "bootstrap.sh does not write secret material to Caddy config"
assert_pattern_order "$bootstrap_script" 'systemctl enable --now flapjack fj-metering-agent' 'if ! configure_caddy' "bootstrap.sh configures Caddy only after Flapjack services are started"
assert_pattern_order "$bootstrap_script" 'systemctl enable --now caddy' 'systemctl reload-or-restart caddy' "bootstrap.sh reloads Caddy only after it is enabled"
assert_caddy_configure_block_has_no_exit "$bootstrap_script" "bootstrap.sh Caddy configure block has no unguarded exit"

assert_file_exists "$cloud_init_file" "cloud_init.rs exists"
assert_file_contains "$cloud_init_file" 'FLAPJACK_URL=' "cloud_init.rs writes FLAPJACK_URL to metering env"
assert_file_contains "$cloud_init_file" 'NODE_ID=' "cloud_init.rs writes NODE_ID to metering env"
assert_file_contains "$cloud_init_file" 'INTERNAL_KEY=' "cloud_init.rs writes INTERNAL_KEY to metering env"
assert_file_contains "$cloud_init_file" 'TENANT_MAP_URL=' "cloud_init.rs writes TENANT_MAP_URL to metering env"
assert_file_contains "$cloud_init_file" 'COLD_STORAGE_USAGE_URL=' "cloud_init.rs writes COLD_STORAGE_USAGE_URL to metering env"
assert_file_contains "$cloud_init_file" 'umask 077' "cloud_init.rs restricts secret env file permissions from first write"
assert_file_contains "$cloud_init_file" 'pub caddy_runtime: CaddyRuntime' "cloud_init params carry the provider-specific Caddy runtime"
assert_file_contains "$cloud_init_file" 'CADDY_SERVED_HOSTNAME=\{quoted_hostname\}' "cloud_init.rs assigns the served hostname once for Caddy"
assert_file_contains "$cloud_init_file" 'cat > /etc/caddy/Caddyfile' "cloud_init.rs renders /etc/caddy/Caddyfile"
assert_file_contains "$cloud_init_file" '^  reverse_proxy 127\.0\.0\.1:7700' "cloud_init.rs Caddyfile proxies to the local Flapjack engine"
assert_file_contains "$cloud_init_file" 'fn is_safe_caddy_hostname' "cloud_init.rs validates served hostnames before rendering Caddy config"
assert_file_contains "$cloud_init_file" 'unsafe served hostname' "cloud_init.rs skips Caddy setup for invalid served hostnames"
assert_file_contains "$cloud_init_file" 'systemctl enable --now caddy' "cloud_init.rs enables and starts Caddy"
assert_file_contains "$cloud_init_file" 'systemctl reload-or-restart caddy' "cloud_init.rs reloads active Caddy after rewriting the Caddyfile"
assert_file_contains "$cloud_init_file" 'WARN.*Caddy' "cloud_init.rs logs and skips Caddy setup failures"
assert_file_not_contains "$cloud_init_file" '/etc/caddy/Caddyfile.*\$API_KEY|/etc/caddy/Caddyfile.*\$DB_URL|/etc/caddy/Caddyfile.*\$INTERNAL_AUTH_TOKEN' "cloud_init.rs does not write secret material to Caddy config"
assert_pattern_order "$cloud_init_file" 'systemctl start flapjack fj-metering-agent' '\{caddy_shell_contract\}' "cloud_init.rs configures Caddy only after Flapjack services are started"
assert_pattern_order "$cloud_init_file" 'systemctl enable --now caddy' 'systemctl reload-or-restart caddy' "cloud_init.rs reloads Caddy only after it is enabled"
assert_caddy_configure_block_has_no_exit "$cloud_init_file" "cloud_init.rs Caddy configure block has no unguarded exit"

assert_file_exists "$packer_file" "flapjack-ami.pkr.hcl exists"
assert_file_contains "$packer_file" 'source "amazon-ebs"' "packer template uses amazon-ebs source"
assert_file_contains "$packer_file" '../user-data/bootstrap.sh' "packer template copies bootstrap.sh into AMI"
assert_file_contains "$packer_file" 'packer \{' "packer template declares packer block"
assert_file_contains "$packer_file" 'required_version' "packer template declares required_version constraint"
assert_file_exists "$caddy_unit_file" "caddy.service exists"
assert_file_contains "$caddy_unit_file" 'ExecStart=/usr/local/bin/caddy run --config /etc/caddy/Caddyfile' "caddy.service starts the baked Caddy binary with the Caddyfile"
assert_file_contains "$caddy_unit_file" '^User=caddy' "caddy.service uses the caddy user"
assert_file_contains "$caddy_unit_file" '^Group=caddy' "caddy.service uses the caddy group"
assert_file_contains "$caddy_unit_file" 'AmbientCapabilities=CAP_NET_BIND_SERVICE' "caddy.service has low-port bind capability"

# ============================================================================
# Stage 3 — Packer AMI contract: staging binary provisioning
# ============================================================================

# Packer must provision Flapjack only from the upstream E3 manifest/archive pair
assert_file_contains "$packer_file" 'variable "flapjack_manifest_path"' "Packer template requires upstream Flapjack manifest"
assert_file_contains "$packer_file" 'variable "flapjack_archive_path"' "Packer template requires upstream Flapjack archive"
assert_file_contains "$packer_file" 'validate_flapjack_ami_input\.sh' "Packer template validates upstream Flapjack archive before install"
assert_file_not_contains "$packer_file" '\$\{var\.binary_dir\}/flapjack' "Packer template does not provision loose flapjack binary from binary_dir"
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
assert_file_not_contains "$packer_file" 'dnf install[^"]*[[:space:]]curl([[:space:]]|")' "Packer template preserves the AL2023 curl-minimal package"
assert_file_contains "$packer_file" 'caddy_2\.10\.0_linux_arm64\.tar\.gz' "Packer template pins the Caddy linux-arm64 release artifact"
assert_file_contains "$packer_file" '7976e98c44ddfaa32fed4e658246d6cc56b318183354c10a2a3c95219a4898a6' "Packer template pins the Caddy linux-arm64 SHA256"
assert_file_contains "$packer_file" 'sha256sum -c' "Packer template verifies the Caddy archive checksum before extraction"
assert_file_contains "$packer_file" 'file /tmp/caddy-extract/caddy' "Packer template verifies extracted Caddy binary architecture"
assert_file_contains "$packer_file" 'useradd.*caddy' "Packer template creates caddy system user"
assert_file_contains "$packer_file" '/etc/caddy' "Packer template creates /etc/caddy"
assert_file_contains "$packer_file" '/var/lib/caddy' "Packer template creates /var/lib/caddy"
assert_file_contains "$packer_file" '/var/log/caddy' "Packer template creates /var/log/caddy"
assert_file_contains "$packer_file" '../systemd/caddy.service' "Packer template copies caddy.service from ops/systemd"
assert_file_contains "$packer_file" 'install -m 0644 /tmp/caddy.service /etc/systemd/system/caddy.service' "Packer template installs caddy.service"
assert_file_contains "$packer_file" 'install -m 0755 /tmp/caddy-extract/caddy /usr/local/bin/caddy' "Packer template installs Caddy to /usr/local/bin/caddy"
assert_file_contains "$packer_file" 'firewall-cmd --permanent --add-port=80/tcp' "Packer template opens tcp/80 in firewalld"

# ============================================================================
# Stage 3 — Metering agent service: fjcloud user consistency
# ============================================================================

systemd_metering_file="ops/systemd/fj-metering-agent.service"
assert_file_contains "$systemd_metering_file" '^User=fjcloud' "Metering agent uses User=fjcloud (not flapjack)"
assert_file_contains "$systemd_metering_file" '^Group=fjcloud' "Metering agent uses Group=fjcloud (not flapjack)"
assert_file_contains "$systemd_metering_file" 'EnvironmentFile.*-?/etc/fjcloud/' "Metering agent EnvironmentFile under /etc/fjcloud/"

test_summary "IaC validation static checks"
