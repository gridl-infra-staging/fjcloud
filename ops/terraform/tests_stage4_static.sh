#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

dns_main_file="ops/terraform/dns/main.tf"
dns_vars_file="ops/terraform/dns/variables.tf"
dns_providers_file="ops/terraform/dns/providers.tf"
dns_outputs_file="ops/terraform/dns/outputs.tf"
monitoring_main_file="ops/terraform/monitoring/main.tf"
monitoring_vars_file="ops/terraform/monitoring/variables.tf"
monitoring_outputs_file="ops/terraform/monitoring/outputs.tf"
runtime_params_main_file="ops/terraform/runtime_params/main.tf"
runtime_params_vars_file="ops/terraform/runtime_params/variables.tf"
shared_main_file="ops/terraform/_shared/main.tf"
shared_outputs_file="ops/terraform/_shared/outputs.tf"
shared_vars_file="ops/terraform/_shared/variables.tf"

# ============================================================================
# 4.1 — DNS module file existence
# ============================================================================

assert_file_exists "$dns_main_file" "dns/main.tf exists"
assert_file_exists "$dns_vars_file" "dns/variables.tf exists"
assert_file_exists "$dns_providers_file" "dns/providers.tf exists"
assert_file_exists "$dns_outputs_file" "dns/outputs.tf exists"

# ============================================================================
# 4.1 — ACM Certificate
# ============================================================================

assert_contains_active "$dns_main_file" 'resource "aws_acm_certificate"' \
  "ACM certificate resource exists"

assert_contains_active "$dns_main_file" 'domain_name\s*=\s*var\.domain' \
  "ACM certificate domain_name uses var.domain (not hardcoded)"

assert_contains_active "$dns_main_file" 'subject_alternative_names.*\*\.\$\{var\.domain\}' \
  "ACM certificate wildcard SAN uses var.domain"

assert_contains_active "$dns_main_file" 'validation_method.*=.*"DNS"' \
  "ACM certificate uses DNS validation"

assert_contains_active "$dns_main_file" 'resource "aws_acm_certificate_validation"' \
  "ACM certificate validation resource exists"

assert_contains_active "$dns_main_file" 'create_before_destroy\s*=\s*true' \
  "ACM certificate has lifecycle create_before_destroy = true"

# ============================================================================
# 4.2 — Application Load Balancer
# ============================================================================

assert_contains_active "$dns_main_file" 'resource "aws_lb"' \
  "ALB resource exists"

assert_contains_active "$dns_main_file" 'internal\s*=\s*false' \
  "ALB is internet-facing (internal = false)"

assert_contains_active "$dns_main_file" 'load_balancer_type\s*=\s*"application"' \
  "ALB type is application"

assert_contains_active "$dns_main_file" 'subnets\s*=\s*var\.public_subnet_ids' \
  "ALB subnets reference var.public_subnet_ids"

assert_contains_active "$dns_main_file" 'security_groups\s*=\s*\[var\.sg_alb_id\]' \
  "ALB security_groups reference var.sg_alb_id"

assert_contains_active "$dns_main_file" 'enable_deletion_protection\s*=\s*false' \
  "ALB deletion protection disabled (MVP)"

assert_contains_active "$dns_main_file" 'resource "aws_lb_target_group"' \
  "ALB target group exists"

assert_contains_active "$dns_main_file" 'port\s*=\s*3001' \
  "Target group port is 3001"

assert_contains_active "$dns_main_file" 'protocol\s*=\s*"HTTP"' \
  "Target group protocol is HTTP"

assert_contains_active "$dns_main_file" 'health_check' \
  "Target group has health_check block"

assert_contains_active "$dns_main_file" '/health' \
  "Health check path is /health"

assert_contains_active "$dns_main_file" 'matcher\s*=\s*"200"' \
  "Health check matcher explicitly set to 200"

assert_contains_active "$dns_main_file" 'deregistration_delay\s*=\s*30' \
  "Target group deregistration_delay is 30s (not default 300s)"

assert_contains_active "$dns_main_file" 'resource "aws_lb_target_group_attachment"' \
  "Target group attachment exists"

assert_contains_active "$dns_main_file" 'target_id\s*=\s*var\.api_instance_id' \
  "Target group attachment references var.api_instance_id"

assert_contains_active "$dns_main_file" 'resource "aws_lb_listener"' \
  "ALB listener resource exists"

# HTTPS listener on 443
assert_contains_active "$dns_main_file" 'port\s*=\s*443' \
  "HTTPS listener on port 443"

assert_contains_active "$dns_main_file" 'protocol\s*=\s*"HTTPS"' \
  "Listener protocol HTTPS"

assert_contains_active "$dns_main_file" 'certificate_arn' \
  "HTTPS listener references ACM certificate"

assert_contains_active "$dns_main_file" 'ssl_policy\s*=\s*"ELBSecurityPolicy-TLS13-1-2-2021-06"' \
  "HTTPS listener uses TLS 1.3 preferred policy"

# HTTP -> HTTPS redirect
assert_contains_active "$dns_main_file" 'port\s*=\s*80' \
  "HTTP listener on port 80"

assert_contains_active "$dns_main_file" 'redirect' \
  "HTTP listener has redirect action"

assert_contains_active "$dns_main_file" 'status_code\s*=\s*"HTTP_301"' \
  "HTTP redirect uses 301"

# ============================================================================
# 4.3 — Cloudflare public DNS
# ============================================================================

assert_not_contains_active "$dns_main_file" 'resource "aws_route53_zone"' \
  "DNS module no longer creates a Route53 public hosted zone"

assert_not_contains_active "$dns_main_file" 'resource "aws_route53_record"' \
  "DNS module no longer publishes public records through Route53"

assert_contains_active "$dns_main_file" 'removed\s*\{' \
  "DNS module declares removed blocks for historical Route53 resources"

assert_contains_active "$dns_main_file" 'from\s*=\s*aws_route53_zone\.primary' \
  "DNS module removes the legacy Route53 zone from Terraform state"

assert_contains_active "$dns_main_file" 'destroy\s*=\s*false' \
  "Legacy Route53 zone is removed from state without destroying the live hosted zone"

assert_contains_active "$dns_main_file" 'resource "cloudflare_dns_record" "public"' \
  "Cloudflare public DNS record resource exists"

assert_contains_active "$shared_main_file" 'data "cloudflare_dns_records" "existing_public"' \
  "Root module checks for pre-existing Cloudflare records before create"

assert_contains_active "$shared_main_file" 'exact\s*=\s*each\.value' \
  "Root Cloudflare public DNS lookup matches exact hostnames"

assert_contains_active "$shared_main_file" 'import\s*\{' \
  "Root module declares import blocks for existing Cloudflare records"

assert_contains_active "$shared_main_file" 'for_each\s*=\s*local\.existing_public_record_ids' \
  "Root Cloudflare public DNS imports iterate over discovered record IDs"

assert_contains_active "$shared_main_file" 'to\s*=\s*module\.dns\.cloudflare_dns_record\.public\[each\.key\]' \
  "Root Cloudflare public DNS imports target the canonical public records"

assert_contains_active "$shared_main_file" 'id\s*=\s*"\$\{var\.cloudflare_zone_id\}/\$\{each\.value\}"' \
  "Root Cloudflare public DNS imports use zone-id/record-id provider IDs"

assert_contains_active "$dns_main_file" 'for_each\s*=\s*local\.public_dns_records' \
  "Cloudflare public DNS records are driven by one local record map"

assert_contains_active "$dns_main_file" 'zone_id\s*=\s*var\.cloudflare_zone_id' \
  "Cloudflare records use var.cloudflare_zone_id"

assert_contains_active "$dns_main_file" 'name\s*=\s*each\.value\.name' \
  "Cloudflare records derive names from the canonical record map"

assert_contains_active "$dns_main_file" 'content\s*=\s*each\.value\.content' \
  "Cloudflare records derive content from the canonical record map"

assert_contains_active "$dns_main_file" 'type\s*=\s*each\.value\.type' \
  "Cloudflare records derive type from the canonical record map"

assert_contains_active "$dns_main_file" 'ttl\s*=\s*each\.value\.ttl' \
  "Cloudflare records derive TTL from the canonical record map"

assert_contains_active "$dns_main_file" 'proxied\s*=\s*false' \
  "Cloudflare public routing records stay DNS-only"

assert_contains_active "$dns_main_file" 'apex\s*=' \
  "Cloudflare record map includes apex hostname"

assert_contains_active "$dns_main_file" 'api\s*=' \
  "Cloudflare record map includes api hostname"

assert_contains_active "$dns_main_file" 'www\s*=' \
  "Cloudflare record map includes www hostname"

assert_contains_active "$dns_main_file" 'cloud\s*=' \
  "Cloudflare record map includes cloud hostname"

assert_contains_active "$dns_main_file" 'aws_lb\.api\.dns_name' \
  "Cloudflare public records point to the ALB dns_name"

# ACM validation records
assert_contains_active "$dns_main_file" 'resource "cloudflare_dns_record" "cert_validation"' \
  "ACM DNS validation records are published through Cloudflare"

assert_contains_active "$dns_main_file" 'acm_validation_records' \
  "ACM validation records are normalized through a local map"

assert_contains_active "$dns_main_file" 'for_each\s*=\s*local\.acm_validation_records' \
  "ACM validation records de-duplicate identical wildcard/apex CNAMEs"

assert_contains_active "$dns_main_file" 'trimsuffix\(dvo\.resource_record_name, "\."\)' \
  "ACM validation record names strip AWS trailing dots before Cloudflare"

assert_contains_active "$dns_main_file" 'trimsuffix\(dvo\.resource_record_value, "\."\)' \
  "ACM validation record values strip AWS trailing dots before Cloudflare"

# SES verification / DKIM records
assert_contains_active "$dns_main_file" 'resource "aws_sesv2_email_identity" "domain"' \
  "SES domain identity is managed for the canonical domain"

assert_contains_active "$dns_main_file" 'email_identity\s*=\s*var\.domain' \
  "SES identity uses var.domain"

assert_contains_active "$dns_main_file" 'resource "cloudflare_dns_record" "ses_dkim"' \
  "SES DKIM records are published through Cloudflare"

assert_contains_active "$dns_main_file" 'dkim_signing_attributes\[0\]\.tokens' \
  "SES DKIM records derive from SES identity tokens"

assert_contains_active "$dns_main_file" '_domainkey\.\$\{var\.domain\}' \
  "SES DKIM record names use the canonical domain"

assert_contains_active "$dns_main_file" 'ses_dkim_hosted_zone' \
  "SES DKIM records derive the hosted zone from a region-aware local"

assert_contains_active "$dns_main_file" 'lookup\(' \
  "SES DKIM hosted zone is computed via lookup"

assert_contains_active "$dns_main_file" 'local\.ses_region_specific_dkim_domains' \
  "SES DKIM lookup uses the region-specific exception map"

assert_contains_active "$dns_main_file" '"dkim\.amazonses\.com"' \
  "SES DKIM hosted zone falls back to the default domain outside region-specific exceptions"

# ============================================================================
# 4.4 — Variables
# ============================================================================

assert_contains_active "$dns_vars_file" 'variable "env"' \
  "dns variables: env"

assert_contains_active "$dns_vars_file" 'contains\(\["staging", "prod"\], var\.env\)' \
  "dns env variable restricts values to staging/prod"

assert_contains_active "$dns_vars_file" 'variable "region"' \
  "dns variables: region"

assert_contains_active "$dns_vars_file" 'variable "domain"' \
  "dns variables: domain"

assert_contains_active "$dns_vars_file" 'variable "cloudflare_zone_id"' \
  "dns variables: cloudflare_zone_id"

assert_contains_active "$dns_vars_file" 'variable "dns_ttl"' \
  "dns variables: dns_ttl"

assert_contains_active "$dns_vars_file" 'variable "vpc_id"' \
  "dns variables: vpc_id"

assert_contains_active "$dns_vars_file" 'variable "public_subnet_ids"' \
  "dns variables: public_subnet_ids"

assert_contains_active "$dns_vars_file" 'variable "sg_alb_id"' \
  "dns variables: sg_alb_id"

assert_contains_active "$dns_vars_file" 'variable "api_instance_id"' \
  "dns variables: api_instance_id"

# ============================================================================
# 4.4 — Outputs
# ============================================================================

assert_contains_active "$dns_outputs_file" 'output "alb_dns_name"' \
  "dns outputs: alb_dns_name"

assert_contains_active "$dns_outputs_file" 'output "alb_arn"' \
  "dns outputs: alb_arn"

assert_contains_active "$dns_outputs_file" 'output "acm_certificate_arn"' \
  "dns outputs: acm_certificate_arn"

assert_contains_active "$dns_outputs_file" 'output "cloudflare_zone_id"' \
  "dns outputs: cloudflare_zone_id"

# ============================================================================
# 4.4 — Providers
# ============================================================================

assert_contains_active "$dns_providers_file" 'required_providers' \
  "dns providers: required_providers block"

assert_contains_active "$dns_providers_file" 'hashicorp/aws' \
  "dns providers: hashicorp/aws source"

assert_contains_active "$dns_providers_file" 'cloudflare/cloudflare' \
  "dns providers: cloudflare/cloudflare source"

# ============================================================================
# 4.4 — Root module wiring
# ============================================================================

assert_contains_active "$shared_main_file" 'module "dns"' \
  "Root main.tf wires dns module"

assert_contains_active "$shared_main_file" 'source.*=.*"../dns"' \
  "Root main.tf dns module source is ../dns"

assert_contains_active "$shared_outputs_file" 'alb_dns_name' \
  "Root outputs include alb_dns_name"

assert_contains_active "$shared_vars_file" 'variable "domain"' \
  "Root variables: domain variable exists"

assert_contains_active "$shared_vars_file" 'variable "cloudflare_zone_id"' \
  "Root variables: cloudflare_zone_id variable exists"

assert_contains_active "$shared_main_file" 'cloudflare_zone_id\s*=\s*var\.cloudflare_zone_id' \
  "Root main.tf passes cloudflare_zone_id into dns module"

# ============================================================================
# 4.5 — Security: no hardcoded values
# ============================================================================

assert_not_contains_active "$dns_main_file" 'arn:aws:acm:' \
  "No hardcoded ACM ARNs in dns/main.tf"

assert_not_contains_active "$dns_main_file" 'sg-[0-9a-f]' \
  "No hardcoded security group IDs in dns/main.tf"

assert_not_contains_active "$dns_main_file" 'subnet-[0-9a-f]' \
  "No hardcoded subnet IDs in dns/main.tf"

# ============================================================================
# 4.X — SES feedback wiring contract
# ============================================================================

assert_contains_active "$monitoring_vars_file" 'variable "domain"' \
  "monitoring variables: domain input exists for SNS subscription endpoint"

assert_contains_active "$monitoring_main_file" 'resource "aws_sns_topic" "ses_feedback"' \
  "monitoring defines a dedicated SNS topic for SES feedback events"

assert_contains_active "$monitoring_main_file" 'resource "aws_sns_topic_subscription" "ses_feedback_webhook"' \
  "monitoring defines an HTTPS webhook subscription for SES feedback topic"

assert_contains_active "$monitoring_main_file" 'resource "aws_sns_topic_policy" "ses_feedback_publish"' \
  "monitoring defines a dedicated SNS topic policy for SES feedback publish"

assert_contains_active "$monitoring_main_file" 'Service\s*=\s*"ses\.amazonaws\.com"' \
  "SES feedback topic policy grants publish principal to ses.amazonaws.com"

assert_contains_active "$monitoring_main_file" '"sns:Publish"' \
  "SES feedback topic policy allows sns:Publish action"

assert_contains_active "$monitoring_main_file" 'topic_arn\s*=\s*aws_sns_topic\.ses_feedback\.arn' \
  "SES feedback webhook subscription uses dedicated feedback topic"

assert_contains_active "$monitoring_main_file" 'protocol\s*=\s*"https"' \
  "SES feedback webhook subscription uses HTTPS protocol"

assert_contains_active "$monitoring_main_file" 'endpoint\s*=\s*"https://api\.\$\{var\.domain\}/webhooks/ses/sns"' \
  "SES feedback webhook subscription endpoint uses canonical api.<domain> path"

assert_contains_active "$monitoring_outputs_file" 'output "ses_feedback_sns_topic_arn"' \
  "monitoring outputs ses_feedback_sns_topic_arn"

assert_contains_active "$monitoring_outputs_file" 'value\s*=\s*aws_sns_topic\.ses_feedback\.arn' \
  "monitoring output ses_feedback_sns_topic_arn references dedicated feedback topic"

assert_contains_active "$dns_vars_file" 'variable "ses_feedback_topic_arn"' \
  "dns variables: ses_feedback_topic_arn input exists"

assert_contains_active "$dns_main_file" 'resource "aws_sesv2_configuration_set"' \
  "dns defines an SES configuration set resource"

assert_contains_active "$dns_main_file" 'resource "aws_sesv2_configuration_set_event_destination"' \
  "dns defines SES configuration set event destination"

assert_contains_active "$dns_main_file" 'topic_arn\s*=\s*var\.ses_feedback_topic_arn' \
  "SES configuration set event destination publishes to monitoring-owned feedback topic input"

assert_contains_active "$dns_main_file" 'matching_event_types\s*=\s*\["BOUNCE",\s*"COMPLAINT"\]' \
  "SES event destination includes BOUNCE and COMPLAINT event types"

assert_contains_active "$dns_outputs_file" 'output "ses_configuration_set_name"' \
  "dns outputs ses_configuration_set_name"

assert_contains_active "$runtime_params_vars_file" 'variable "ses_configuration_set_name"' \
  "runtime_params variables: ses_configuration_set_name input exists"

assert_contains_active "$runtime_params_main_file" 'name\s*=\s*"/fjcloud/\$\{var\.env\}/ses_configuration_set"' \
  "runtime_params publishes SES configuration set parameter path"

assert_contains_active "$runtime_params_main_file" 'value\s*=\s*var\.ses_configuration_set_name' \
  "runtime_params SES configuration set parameter value is module input"

assert_contains_active "$shared_main_file" 'domain\s*=\s*var\.domain' \
  "root main.tf passes domain into monitoring module"

assert_contains_active "$shared_main_file" 'ses_feedback_topic_arn\s*=\s*module\.monitoring\.ses_feedback_sns_topic_arn' \
  "root main.tf passes monitoring SES feedback topic output into dns module"

assert_contains_active "$shared_main_file" 'ses_configuration_set_name\s*=\s*module\.dns\.ses_configuration_set_name' \
  "root main.tf passes dns SES configuration set output into runtime_params module"

test_summary "Stage 4 static checks"
