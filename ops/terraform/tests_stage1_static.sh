#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

backend_file="ops/terraform/_shared/backend.tf"
networking_vars_file="ops/terraform/networking/variables.tf"
networking_main_file="ops/terraform/networking/main.tf"
networking_outputs_file="ops/terraform/networking/outputs.tf"
dns_main_file="ops/terraform/dns/main.tf"
data_main_file="ops/terraform/data/main.tf"
alert_lane_chat="chats/icg/may21_12pm_8_alert_emails.md"

assert_file_exists "$backend_file" "backend.tf exists"
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
assert_contains_active "$networking_outputs_file" 'output "sg_rds_id"' "Networking outputs include sg_rds_id"

assert_contains_active "$dns_main_file" 'cloud_pages_hostname[[:space:]]*=[[:space:]]*var\.env[[:space:]]*==[[:space:]]*"staging"[[:space:]]*\?[[:space:]]*"staging\.flapjack-cloud\.pages\.dev"[[:space:]]*:[[:space:]]*"flapjack-cloud\.pages\.dev"' "DNS cloud CNAME hostname is environment-aware (staging keeps staging Pages target)"
assert_public_dns_record_content "$dns_main_file" "cloud" "local.cloud_pages_hostname" "DNS cloud CNAME content uses canonical cloud_pages_hostname local"
assert_resource_block_contains "$dns_main_file" "aws_lb_target_group_attachment" "api" 'for_each[[:space:]]*=[[:space:]]*var\.env[[:space:]]*==[[:space:]]*"prod"[[:space:]]*\?[[:space:]]*toset\(\["prod"\]\)[[:space:]]*:[[:space:]]*toset\(\[\]\)' "DNS API target-group attachment is Terraform-managed only in prod"
assert_resource_block_contains "$data_main_file" "aws_s3_bucket_server_side_encryption_configuration" "cold" 'blocked_encryption_types[[:space:]]*=[[:space:]]*\["SSE-C"\]' "Cold bucket SSE blocks SSE-C uploads to match deployed contract"
assert_resource_block_contains "$data_main_file" "aws_s3_bucket_server_side_encryption_configuration" "cold" 'bucket_key_enabled[[:space:]]*=[[:space:]]*false' "Cold bucket SSE leaves bucket_key_enabled disabled to match deployed contract"
assert_file_not_contains "$alert_lane_chat" 'source \.secret/session/alert_emails\.env' "Alert-email lane does not execute the session env file as shell code"
assert_file_contains "$alert_lane_chat" "sed -n 's/\\^PROD_ALERT_EMAILS_JSON=//p' \\.secret/session/alert_emails\\.env" "Alert-email lane parses prod alert email JSON from the session file"
assert_file_contains "$alert_lane_chat" "sed -n 's/\\^STAGING_ALERT_EMAILS_JSON=//p' \\.secret/session/alert_emails\\.env" "Alert-email lane parses staging alert email JSON from the session file"

# Internet-exposure audit: only ALB ingress rules should have 0.0.0.0/0.
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
      if (name != "alb_http" && name != "alb_https") {
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
  pass "Only ALB ingress rules are internet-exposed"
else
  fail "Unexpected internet-exposed ingress rules: ${offenders//$'\n'/, }"
fi

test_summary "Stage 1 static checks"
