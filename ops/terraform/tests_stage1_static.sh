#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

backend_file="ops/terraform/_shared/backend.tf"
shared_main_file="ops/terraform/_shared/main.tf"
networking_vars_file="ops/terraform/networking/variables.tf"
networking_main_file="ops/terraform/networking/main.tf"
networking_outputs_file="ops/terraform/networking/outputs.tf"
dns_main_file="ops/terraform/dns/main.tf"
data_main_file="ops/terraform/data/main.tf"
alert_lane_chat="chats/icg/may21_12pm_8_alert_emails.md"

assert_file_exists "$backend_file" "backend.tf exists"
assert_file_exists "$shared_main_file" "_shared/main.tf exists"
assert_file_exists "$networking_vars_file" "networking/variables.tf exists"
assert_file_exists "$networking_main_file" "networking/main.tf exists"
assert_file_exists "$networking_outputs_file" "networking/outputs.tf exists"
assert_file_exists "$dns_main_file" "dns/main.tf exists"
assert_file_exists "$data_main_file" "data/main.tf exists"
assert_file_exists "$alert_lane_chat" "Alert-email lane chat exists"

assert_contains_active "$backend_file" 'backend "s3"' "Remote state uses S3 backend"
assert_contains_active "$backend_file" 'dynamodb_table[[:space:]]*=[[:space:]]*"fjcloud-tflock"' "Backend defines DynamoDB lock table"
assert_contains_active "$backend_file" 'key[[:space:]]*=[[:space:]]*"terraform\.tfstate"' "Backend defines deterministic state key"

assert_contains_active "$networking_vars_file" 'variable "env"' "Networking module declares env variable"
assert_contains_active "$networking_vars_file" 'contains\(\["staging", "prod"\], var\.env\)' "Networking env variable restricts values to staging/prod"

assert_contains_active "$networking_main_file" 'resource "aws_nat_gateway" "main"' "Networking includes NAT gateway"
assert_contains_active "$networking_main_file" 'resource "aws_vpc_security_group_ingress_rule" "rds_from_api"' "RDS ingress rule is present"
assert_contains_active "$networking_main_file" 'referenced_security_group_id[[:space:]]*=[[:space:]]*aws_security_group\.api\.id' "RDS ingress references API SG"
assert_contains_active "$networking_main_file" 'ignore_changes[[:space:]]*=[[:space:]]*\[description\]' "API security group ignores description drift to avoid metadata-only replacement"
assert_named_resource_count "$networking_main_file" "aws_vpc_security_group_ingress_rule" "flapjack_public_data_plane" 1 "Networking declares exactly one named public Flapjack data-plane ingress rule"
assert_resource_block_contains "$networking_main_file" "aws_vpc_security_group_ingress_rule" "flapjack_public_data_plane" 'security_group_id[[:space:]]*=[[:space:]]*aws_security_group\.flapjack_vm\.id' "Public Flapjack data-plane ingress targets the Flapjack VM security group"
assert_resource_block_contains "$networking_main_file" "aws_vpc_security_group_ingress_rule" "flapjack_public_data_plane" 'cidr_ipv4[[:space:]]*=[[:space:]]*"0\.0\.0\.0/0"' "Public Flapjack data-plane ingress uses the public IPv4 CIDR"
assert_resource_block_contains "$networking_main_file" "aws_vpc_security_group_ingress_rule" "flapjack_public_data_plane" 'from_port[[:space:]]*=[[:space:]]*7700' "Public Flapjack data-plane ingress starts at port 7700"
assert_resource_block_contains "$networking_main_file" "aws_vpc_security_group_ingress_rule" "flapjack_public_data_plane" 'to_port[[:space:]]*=[[:space:]]*7700' "Public Flapjack data-plane ingress ends at port 7700"
assert_resource_block_contains "$networking_main_file" "aws_vpc_security_group_ingress_rule" "flapjack_public_data_plane" 'ip_protocol[[:space:]]*=[[:space:]]*"tcp"' "Public Flapjack data-plane ingress uses TCP"
assert_resource_block_not_contains "$networking_main_file" "aws_vpc_security_group_ingress_rule" "flapjack_public_data_plane" 'var\.env|^[[:space:]]*(count|for_each)[[:space:]]*=' "Public Flapjack data-plane ingress is unconditional and environment-independent"
assert_named_resource_count "$networking_main_file" "aws_vpc_security_group_ingress_rule" "flapjack_acme_http" 1 "Networking declares exactly one named public Flapjack ACME HTTP ingress rule"
assert_resource_block_contains "$networking_main_file" "aws_vpc_security_group_ingress_rule" "flapjack_acme_http" 'security_group_id[[:space:]]*=[[:space:]]*aws_security_group\.flapjack_vm\.id' "Public Flapjack ACME HTTP ingress targets the Flapjack VM security group"
assert_resource_block_contains "$networking_main_file" "aws_vpc_security_group_ingress_rule" "flapjack_acme_http" 'cidr_ipv4[[:space:]]*=[[:space:]]*"0\.0\.0\.0/0"' "Public Flapjack ACME HTTP ingress uses the public IPv4 CIDR"
assert_resource_block_contains "$networking_main_file" "aws_vpc_security_group_ingress_rule" "flapjack_acme_http" 'from_port[[:space:]]*=[[:space:]]*80' "Public Flapjack ACME HTTP ingress starts at port 80"
assert_resource_block_contains "$networking_main_file" "aws_vpc_security_group_ingress_rule" "flapjack_acme_http" 'to_port[[:space:]]*=[[:space:]]*80' "Public Flapjack ACME HTTP ingress ends at port 80"
assert_resource_block_contains "$networking_main_file" "aws_vpc_security_group_ingress_rule" "flapjack_acme_http" 'ip_protocol[[:space:]]*=[[:space:]]*"tcp"' "Public Flapjack ACME HTTP ingress uses TCP"
assert_named_resource_count "$networking_main_file" "aws_vpc_security_group_ingress_rule" "flapjack_customer_https" 1 "Networking declares exactly one named public Flapjack customer HTTPS ingress rule"
assert_resource_block_contains "$networking_main_file" "aws_vpc_security_group_ingress_rule" "flapjack_customer_https" 'security_group_id[[:space:]]*=[[:space:]]*aws_security_group\.flapjack_vm\.id' "Public Flapjack customer HTTPS ingress targets the Flapjack VM security group"
assert_resource_block_contains "$networking_main_file" "aws_vpc_security_group_ingress_rule" "flapjack_customer_https" 'cidr_ipv4[[:space:]]*=[[:space:]]*"0\.0\.0\.0/0"' "Public Flapjack customer HTTPS ingress uses the public IPv4 CIDR"
assert_resource_block_contains "$networking_main_file" "aws_vpc_security_group_ingress_rule" "flapjack_customer_https" 'from_port[[:space:]]*=[[:space:]]*443' "Public Flapjack customer HTTPS ingress starts at port 443"
assert_resource_block_contains "$networking_main_file" "aws_vpc_security_group_ingress_rule" "flapjack_customer_https" 'to_port[[:space:]]*=[[:space:]]*443' "Public Flapjack customer HTTPS ingress ends at port 443"
assert_resource_block_contains "$networking_main_file" "aws_vpc_security_group_ingress_rule" "flapjack_customer_https" 'ip_protocol[[:space:]]*=[[:space:]]*"tcp"' "Public Flapjack customer HTTPS ingress uses TCP"
public_data_plane_resource_count=$(rg -g '*.tf' -g '!**/fixtures/**' -g '!**/.terraform/**' -c 'resource "aws_vpc_security_group_ingress_rule" "flapjack_public_data_plane"' ops/terraform | awk -F: '{ count += $2 } END { print count + 0 }')
if [[ "$public_data_plane_resource_count" == "1" ]]; then
  pass "Terraform modules declare the named public Flapjack data-plane rule exactly once"
else
  fail "Terraform modules must declare the named public Flapjack data-plane rule exactly once (found ${public_data_plane_resource_count})"
fi
assert_contains_active "$networking_outputs_file" 'output "sg_rds_id"' "Networking outputs include sg_rds_id"

assert_contains_active "$shared_main_file" 'deployment_domain[[:space:]]*=[[:space:]]*var\.env[[:space:]]*==[[:space:]]*"staging"[[:space:]]*&&[[:space:]]*var\.domain[[:space:]]*==[[:space:]]*"flapjack\.foo"[[:space:]]*\?[[:space:]]*"staging\.flapjack\.foo"[[:space:]]*:[[:space:]]*var\.domain' "Shared Terraform normalizes staging root-domain input to staging subdomain"
assert_contains_active "$shared_main_file" 'domain[[:space:]]*=[[:space:]]*local\.deployment_domain' "Shared Terraform passes normalized deployment domain to DNS module"
assert_not_contains_active "$shared_main_file" 'flapjack_public_data_plane' "Shared Terraform delegates the public Flapjack data-plane rule to the networking module"
networking_module_count=$(strip_comments "$shared_main_file" | rg -c '^[[:space:]]*module[[:space:]]+"networking"[[:space:]]*\{' || true)
if [[ "$networking_module_count" == "1" ]]; then
  pass "Shared Terraform instantiates the networking module exactly once"
else
  fail "Shared Terraform must instantiate the networking module exactly once (found ${networking_module_count:-0})"
fi
assert_contains_active "$dns_main_file" 'deployment_domain[[:space:]]*=[[:space:]]*var\.env[[:space:]]*==[[:space:]]*"staging"[[:space:]]*&&[[:space:]]*var\.domain[[:space:]]*==[[:space:]]*"flapjack\.foo"[[:space:]]*\?[[:space:]]*"staging\.flapjack\.foo"[[:space:]]*:[[:space:]]*var\.domain' "DNS module normalizes staging root-domain input to staging subdomain"
assert_contains_active "$dns_main_file" 'cloud_pages_hostname[[:space:]]*=[[:space:]]*var\.env[[:space:]]*==[[:space:]]*"staging"[[:space:]]*\?[[:space:]]*"staging\.flapjack-cloud\.pages\.dev"[[:space:]]*:[[:space:]]*"flapjack-cloud\.pages\.dev"' "DNS cloud CNAME hostname is environment-aware (staging keeps staging Pages target)"
assert_public_dns_record_content "$dns_main_file" "cloud" "local.cloud_pages_hostname" "DNS cloud CNAME content uses canonical cloud_pages_hostname local"
assert_resource_block_contains "$dns_main_file" "aws_lb_target_group_attachment" "api" 'for_each[[:space:]]*=[[:space:]]*var\.env[[:space:]]*==[[:space:]]*"prod"[[:space:]]*\?[[:space:]]*toset\(\["prod"\]\)[[:space:]]*:[[:space:]]*toset\(\[\]\)' "DNS API target-group attachment is Terraform-managed only in prod"
assert_resource_block_contains "$data_main_file" "aws_s3_bucket_server_side_encryption_configuration" "cold" 'blocked_encryption_types[[:space:]]*=[[:space:]]*\["SSE-C"\]' "Cold bucket SSE blocks SSE-C uploads to match deployed contract"
assert_resource_block_contains "$data_main_file" "aws_s3_bucket_server_side_encryption_configuration" "cold" 'bucket_key_enabled[[:space:]]*=[[:space:]]*false' "Cold bucket SSE leaves bucket_key_enabled disabled to match deployed contract"
assert_file_not_contains "$alert_lane_chat" 'source \.secret/session/alert_emails\.env' "Alert-email lane does not execute the session env file as shell code"
assert_file_contains "$alert_lane_chat" "sed -n 's/\\^PROD_ALERT_EMAILS_JSON=//p' \\.secret/session/alert_emails\\.env" "Alert-email lane parses prod alert email JSON from the session file"
assert_file_contains "$alert_lane_chat" "sed -n 's/\\^STAGING_ALERT_EMAILS_JSON=//p' \\.secret/session/alert_emails\\.env" "Alert-email lane parses staging alert email JSON from the session file"

# Internet-exposure audit: only ALB ingress and the exact named Flapjack
# data-plane exception should have 0.0.0.0/0.
# Uses awk with its own comment-line skipping for multi-line block context.
offenders=$(awk '
  BEGIN { in_block = 0; depth = 0; name = "" }
  /^[[:space:]]*#/ { next }
  /^[[:space:]]*\/\// { next }
  /^resource "aws_vpc_security_group_ingress_rule" "/ {
    in_block = 1
    name = $3
    gsub(/"/, "", name)
    depth = 1
    next
  }
  in_block {
    opens = gsub(/{/, "{")
    closes = gsub(/}/, "}")
    depth += opens - closes
    if ($0 ~ /cidr_ipv4[[:space:]]*=[[:space:]]*"0\.0\.0\.0\/0"/) {
      if (name != "alb_http" && name != "alb_https" && name != "flapjack_public_data_plane" && name != "flapjack_acme_http" && name != "flapjack_customer_https") {
        print name
      }
    }
    if (depth <= 0) {
      in_block = 0
      depth = 0
      name = ""
    }
  }
' "$networking_main_file" | sort -u)

if [[ -z "$offenders" ]]; then
  pass "Only ALB ingress and named Flapjack ACME, HTTPS, and data-plane rules are internet-exposed"
else
  fail "Unexpected internet-exposed ingress resource names: ${offenders//$'\n'/, }"
fi

test_summary "Stage 1 static checks"
