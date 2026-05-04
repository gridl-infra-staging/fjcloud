#!/usr/bin/env bash
# Static validation tests for Stage 7: Monitoring & Final Validation
# TDD: these tests define the contract; Terraform code must satisfy them.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

monitor_main_file="ops/terraform/monitoring/main.tf"
monitor_vars_file="ops/terraform/monitoring/variables.tf"
monitor_outputs_file="ops/terraform/monitoring/outputs.tf"
monitor_providers_file="ops/terraform/monitoring/providers.tf"
runtime_smoke_file="ops/terraform/tests_stage7_runtime_smoke.sh"
shared_main_file="ops/terraform/_shared/main.tf"
shared_vars_file="ops/terraform/_shared/variables.tf"
data_outputs_file="ops/terraform/data/outputs.tf"
dns_outputs_file="ops/terraform/dns/outputs.tf"
canary_lambda_image_dockerfile="scripts/canary/lambda_image/Dockerfile"
canary_lambda_image_bootstrap="scripts/canary/lambda_image/bootstrap"
canary_owner_script="scripts/canary/customer_loop_synthetic.sh"

assert_active_count_at_least() {
  local file="$1"
  local pattern="$2"
  local expected_minimum="$3"
  local description="$4"
  local count
  count=$(strip_comments "$file" | rg -c "$pattern" || true)
  if [[ -z "$count" ]]; then count=0; fi
  if [[ "$count" -ge "$expected_minimum" ]]; then
    pass "$description"
  else
    fail "$description (found $count, expected at least $expected_minimum)"
  fi
}

echo ""
echo "=== Stage 7 Static Tests: Monitoring & Final Validation ==="
echo ""

echo "--- Monitoring module file existence ---"
assert_file_exists "$monitor_main_file" "monitoring/main.tf exists"
assert_file_exists "$monitor_vars_file" "monitoring/variables.tf exists"
assert_file_exists "$monitor_outputs_file" "monitoring/outputs.tf exists"
assert_file_exists "$monitor_providers_file" "monitoring/providers.tf exists"

echo ""
echo "--- Runtime validation harness ---"
assert_file_exists "$runtime_smoke_file" "tests_stage7_runtime_smoke.sh exists"
assert_file_contains "$runtime_smoke_file" 'terraform init' "Runtime harness initializes Terraform backend"
assert_file_contains "$runtime_smoke_file" 'terraform plan' "Runtime harness runs Terraform plan"
assert_file_contains "$runtime_smoke_file" 'api\.cloudflare\.com/client/v4' "Runtime harness checks Cloudflare zone access"
assert_file_contains "$runtime_smoke_file" 'assert_cloudflare_zone_accessible' "Runtime harness validates Cloudflare DNS authority before apply"
assert_file_contains "$runtime_smoke_file" 'assert_cloudflare_public_records' "Runtime harness validates Cloudflare public records"
assert_file_contains "$runtime_smoke_file" 'assert_ses_identity_verified' "Runtime harness validates SES identity state"
assert_file_contains "$runtime_smoke_file" 'HEALTH_URL="https://api\.\$\{DOMAIN\}/health"' "Runtime harness builds health endpoint from --domain"
assert_file_contains "$runtime_smoke_file" 'curl -fsS --connect-timeout 10 --max-time 30 "\$HEALTH_URL"' "Runtime harness checks public health endpoint with timeout"
assert_file_contains "$runtime_smoke_file" 'deploy\.sh.*\$\{ENV\}' "Runtime harness invokes deploy script"
assert_file_contains "$runtime_smoke_file" 'migrate\.sh.*\$ENV' "Runtime harness invokes migrate script"
assert_file_contains "$runtime_smoke_file" '^assert_cloudflare_zone_accessible$' "Cloudflare DNS preflight runs unconditionally (not gated by --apply)"

echo ""
echo "--- Stage 5 canary image packaging owner ---"
assert_file_exists "$canary_lambda_image_dockerfile" "Canary Lambda image Dockerfile exists"
assert_file_exists "$canary_lambda_image_bootstrap" "Canary Lambda runtime bootstrap exists"
assert_file_exists "$canary_owner_script" "Existing customer loop canary owner script exists"
assert_file_contains "$canary_lambda_image_dockerfile" '^FROM public\.ecr\.aws/lambda/provided:al2023' "Canary image uses AWS Lambda provided.al2023 base"
assert_file_contains "$canary_lambda_image_dockerfile" 'dnf install -y awscli bash curl python3' "Canary image installs runtime dependencies (awscli/bash/curl/python3)"
assert_file_contains "$canary_lambda_image_dockerfile" '^COPY scripts/ \./scripts/' "Canary image copies canonical scripts tree"
assert_file_contains "$canary_lambda_image_dockerfile" '^COPY scripts/canary/lambda_image/bootstrap /var/runtime/bootstrap' "Canary image wires bootstrap entrypoint from repo-owned file"
assert_file_contains "$canary_lambda_image_dockerfile" 'chmod 0755 /var/runtime/bootstrap \./scripts/canary/customer_loop_synthetic\.sh' "Canary image ensures bootstrap and owner script are executable"
assert_file_contains "$canary_lambda_image_bootstrap" 'handler_command="\$\{_HANDLER:-scripts/canary/customer_loop_synthetic\.sh\}"' "Bootstrap dispatches to Lambda handler command with canary owner default"
assert_file_contains "$canary_lambda_image_bootstrap" 'bash "\$handler_command"' "Bootstrap executes the canary owner script command instead of re-implementing flow logic"
assert_file_contains "$canary_lambda_image_bootstrap" '/2018-06-01/runtime/invocation/next' "Bootstrap polls Lambda Runtime API for invocations"
assert_file_contains "$canary_lambda_image_bootstrap" '/2018-06-01/runtime/invocation/\$\{request_id\}/response' "Bootstrap posts successful invocation responses to Lambda Runtime API"
assert_file_contains "$canary_lambda_image_bootstrap" '/2018-06-01/runtime/invocation/\$\{request_id\}/error' "Bootstrap posts invocation failures to Lambda Runtime API error endpoint"

echo ""
echo "--- Stage 7.6 runtime signal checks ---"
assert_file_contains "$runtime_smoke_file" 'aws acm describe-certificate' "Runtime harness verifies ACM certificate status"
assert_file_contains "$runtime_smoke_file" 'ISSUED' "Runtime harness asserts ACM cert status is ISSUED"
assert_file_contains "$runtime_smoke_file" 'aws elbv2 describe-listeners' "Runtime harness verifies ALB has HTTPS listener"
assert_file_contains "$runtime_smoke_file" "Port==.*443.*Protocol=='HTTPS'" "Runtime harness verifies HTTPS listener on port 443"
assert_file_contains "$runtime_smoke_file" 'aws elbv2 describe-target-health' "Runtime harness verifies target group health"
assert_file_contains "$runtime_smoke_file" 'aws sesv2 get-email-identity' "Runtime harness verifies SES identity state"

echo ""
echo "--- SNS topic and email subscription ---"
assert_contains_active "$monitor_main_file" 'resource "aws_sns_topic" "alerts"' "Monitoring defines SNS topic"
assert_contains_active "$monitor_main_file" 'name[[:space:]]*=[[:space:]]*"fjcloud-alerts-\$\{var\.env\}"' "SNS topic is named fjcloud-alerts-<env>"
assert_contains_active "$monitor_main_file" 'resource "aws_sns_topic_subscription" "email"' "Monitoring defines SNS email subscription resource"
assert_contains_active "$monitor_main_file" 'protocol[[:space:]]*=[[:space:]]*"email"' "SNS subscription uses email protocol"
assert_contains_active "$monitor_main_file" 'for_each[[:space:]]*=[[:space:]]*toset\(var\.alert_emails\)' "Email subscriptions iterate alert_emails list"

echo ""
echo "--- Stage 5 canary runtime packaging contract ---"
assert_contains_active "$monitor_main_file" 'resource "aws_ecr_repository" "customer_loop_canary"' "Monitoring defines dedicated ECR repository for canary image"
assert_contains_active "$monitor_main_file" 'resource "aws_iam_role" "customer_loop_canary_lambda"' "Monitoring defines IAM role for canary Lambda runtime"
assert_contains_active "$monitor_main_file" 'resource "aws_iam_role_policy" "customer_loop_canary_lambda"' "Monitoring defines IAM policy for canary Lambda runtime"
assert_contains_active "$monitor_main_file" 'resource "aws_lambda_function" "customer_loop_canary"' "Monitoring defines canary Lambda function"
assert_contains_active "$monitor_main_file" 'package_type[[:space:]]*=[[:space:]]*"Image"' "Canary Lambda uses image package type"
assert_contains_active "$monitor_main_file" 'image_uri[[:space:]]*=[[:space:]]*local\.customer_loop_canary_image_uri' "Canary Lambda image URI comes from canonical local image contract"
assert_contains_active "$monitor_main_file" 'command[[:space:]]*=[[:space:]]*\["scripts/canary/customer_loop_synthetic.sh"\]' "Canary Lambda command invokes the existing customer loop owner script"
assert_contains_active "$monitor_main_file" 'resource "aws_cloudwatch_event_rule" "customer_loop_canary"' "Monitoring defines EventBridge schedule rule for canary"
assert_contains_active "$monitor_main_file" 'schedule_expression[[:space:]]*=[[:space:]]*var\.canary_schedule\.expression' "Canary schedule expression is provided via canonical monitoring input"
assert_contains_active "$monitor_main_file" 'is_enabled[[:space:]]*=[[:space:]]*var\.canary_schedule\.enabled' "Canary schedule enable state is operator-controlled input"
assert_contains_active "$monitor_main_file" 'resource "aws_cloudwatch_event_target" "customer_loop_canary"' "Monitoring defines EventBridge target for canary Lambda"
assert_contains_active "$monitor_main_file" 'resource "aws_lambda_permission" "customer_loop_canary_eventbridge"' "Monitoring allows EventBridge to invoke canary Lambda"
assert_contains_active "$monitor_main_file" 'principal[[:space:]]*=[[:space:]]*"events\.amazonaws\.com"' "Lambda invoke permission grants EventBridge principal"
assert_contains_active "$monitor_main_file" 'ssm:GetParameter' "Canary Lambda IAM policy grants SSM GetParameter access"
assert_contains_active "$monitor_main_file" '/fjcloud/\$\{var\.env\}/canary_quiet_until' "Canary Lambda IAM policy is scoped to canonical quiet-window parameter path"

echo ""
echo "--- Monitoring resource count ---"
# Resource count breakdown:
#   2 alerts SNS (topic + email subscription)
#   3 SES feedback SNS (topic + topic_policy + HTTPS subscription) — added 2026-04-29 in
#     commits 6ce1329d/b7f79168 alongside the bounce/complaint suppression handler. Test
#     was previously asserting 24 (pre-feedback) and would silently fail-fast on staging
#     terraform_stage7_static gate every run; updated to 27 now.
#   8 customer-loop canary (ECR repo + lifecycle, IAM role+policy, Lambda, EventBridge rule+target, Lambda permission)
#   4 cloudtrail export (S3 bucket + public-access-block + lifecycle + bucket-policy + cloudtrail itself = 5)
#   2 budget (budget + budget action)
#   8 cloudwatch metric alarms (6 infra + 1 heartbeat + 1 billing)
# Sum: 2 + 3 + 8 + 5 + 2 + 8 = 28.
assert_resource_count "$monitor_main_file" 28 "monitoring/main.tf has exactly 28 resources (alerts + SES feedback + canary + cloudtrail + budget + alarms)"

echo ""
echo "--- API CPU alarm ---"
assert_contains_active "$monitor_main_file" 'resource "aws_cloudwatch_metric_alarm" "api_cpu_high"' "API CPU alarm resource exists"
assert_contains_active "$monitor_main_file" 'alarm_name[[:space:]]*=[[:space:]]*"fjcloud-\$\{var\.env\}-api-cpu-high"' "API CPU alarm name follows naming convention"
assert_contains_active "$monitor_main_file" 'metric_name[[:space:]]*=[[:space:]]*"CPUUtilization"' "API and RDS alarms use CPUUtilization metric"
assert_contains_active "$monitor_main_file" 'namespace[[:space:]]*=[[:space:]]*"AWS/EC2"' "API CPU alarm targets AWS/EC2 namespace"
assert_contains_active "$monitor_main_file" 'InstanceId[[:space:]]*=[[:space:]]*var\.api_instance_id' "API CPU alarm dimensions use API instance id"

echo ""
echo "--- API StatusCheckFailed alarm ---"
assert_contains_active "$monitor_main_file" 'resource "aws_cloudwatch_metric_alarm" "api_status_check_failed"' "API StatusCheckFailed alarm resource exists"
assert_contains_active "$monitor_main_file" 'alarm_name[[:space:]]*=[[:space:]]*"fjcloud-\$\{var\.env\}-api-status-check-failed"' "API StatusCheckFailed alarm name follows naming convention"
assert_contains_active "$monitor_main_file" 'metric_name[[:space:]]*=[[:space:]]*"StatusCheckFailed"' "API StatusCheckFailed alarm uses StatusCheckFailed metric"
assert_contains_active "$monitor_main_file" 'comparison_operator[[:space:]]*=[[:space:]]*"GreaterThanOrEqualToThreshold"' "API StatusCheckFailed uses GreaterThanOrEqualToThreshold operator"
assert_contains_active "$monitor_main_file" 'statistic[[:space:]]*=[[:space:]]*"Maximum"' "API StatusCheckFailed uses Maximum statistic"

echo ""
echo "--- RDS CPU alarm ---"
assert_contains_active "$monitor_main_file" 'resource "aws_cloudwatch_metric_alarm" "rds_cpu_high"' "RDS CPU alarm resource exists"
assert_contains_active "$monitor_main_file" 'alarm_name[[:space:]]*=[[:space:]]*"fjcloud-\$\{var\.env\}-rds-cpu-high"' "RDS CPU alarm name follows naming convention"
assert_contains_active "$monitor_main_file" 'namespace[[:space:]]*=[[:space:]]*"AWS/RDS"' "RDS CPU alarm targets AWS/RDS namespace"
assert_contains_active "$monitor_main_file" 'DBInstanceIdentifier[[:space:]]*=[[:space:]]*var\.db_instance_identifier' "RDS alarms use DBInstanceIdentifier dimension"

echo ""
echo "--- RDS free storage alarm ---"
assert_contains_active "$monitor_main_file" 'resource "aws_cloudwatch_metric_alarm" "rds_free_storage_low"' "RDS free storage alarm resource exists"
assert_contains_active "$monitor_main_file" 'alarm_name[[:space:]]*=[[:space:]]*"fjcloud-\$\{var\.env\}-rds-free-storage-low"' "RDS storage alarm name follows naming convention"
assert_contains_active "$monitor_main_file" 'metric_name[[:space:]]*=[[:space:]]*"FreeStorageSpace"' "RDS free storage alarm uses FreeStorageSpace metric"
assert_contains_active "$monitor_main_file" 'comparison_operator[[:space:]]*=[[:space:]]*"LessThanThreshold"' "RDS free storage alarm uses less-than threshold"
assert_contains_active "$monitor_main_file" 'threshold[[:space:]]*=[[:space:]]*2147483648' "RDS free storage alarm threshold is 2 GiB"

echo ""
echo "--- ALB 5XX error rate alarm ---"
assert_contains_active "$monitor_main_file" 'resource "aws_cloudwatch_metric_alarm" "alb_5xx_error_rate"' "ALB 5xx rate alarm resource exists"
assert_contains_active "$monitor_main_file" 'alarm_name[[:space:]]*=[[:space:]]*"fjcloud-\$\{var\.env\}-alb-5xx-error-rate"' "ALB 5XX alarm name follows naming convention"
assert_contains_active "$monitor_main_file" 'metric_query' "ALB 5xx alarm uses metric_query blocks"
assert_contains_active "$monitor_main_file" 'HTTPCode_ELB_5XX_Count' "ALB 5xx alarm uses HTTPCode_ELB_5XX_Count metric"
assert_contains_active "$monitor_main_file" 'RequestCount' "ALB 5xx alarm uses RequestCount metric"
assert_contains_active "$monitor_main_file" 'm2 / m1' "ALB 5xx alarm uses m2/m1 ratio"
assert_contains_active "$monitor_main_file" '\\* 100' "ALB 5xx alarm scales ratio to percentage"

echo ""
echo "--- ALB P99 latency alarm ---"
assert_contains_active "$monitor_main_file" 'resource "aws_cloudwatch_metric_alarm" "alb_p99_target_response_time"' "ALB P99 latency alarm resource exists"
assert_contains_active "$monitor_main_file" 'alarm_name[[:space:]]*=[[:space:]]*"fjcloud-\$\{var\.env\}-alb-p99-target-response-time"' "ALB P99 alarm name follows naming convention"
assert_contains_active "$monitor_main_file" 'metric_name[[:space:]]*=[[:space:]]*"TargetResponseTime"' "ALB P99 alarm uses TargetResponseTime metric"
assert_contains_active "$monitor_main_file" 'extended_statistic[[:space:]]*=[[:space:]]*"p99"' "ALB latency alarm uses p99 extended statistic"
assert_contains_active "$monitor_main_file" 'namespace[[:space:]]*=[[:space:]]*"AWS/ApplicationELB"' "ALB alarms target AWS/ApplicationELB namespace"

echo ""
echo "--- Cross-alarm contract checks ---"
assert_contains_active "$monitor_main_file" 'comparison_operator[[:space:]]*=[[:space:]]*"GreaterThanThreshold"' "CPU/latency alarms use GreaterThanThreshold operator"
assert_contains_active "$monitor_main_file" 'period[[:space:]]*=[[:space:]]*300' "Alarms use 5-minute period"
assert_contains_active "$monitor_main_file" 'evaluation_periods[[:space:]]*=[[:space:]]*2' "EC2/RDS alarms evaluate over 10 minutes (2 periods)"
assert_active_count_at_least "$monitor_main_file" 'alarm_actions[[:space:]]*=[[:space:]]*\[aws_sns_topic\.alerts\.arn\]' 6 "All 6 alarms wire alarm_actions to SNS topic"
assert_active_count_at_least "$monitor_main_file" 'ok_actions[[:space:]]*=[[:space:]]*\[aws_sns_topic\.alerts\.arn\]' 6 "All 6 alarms wire ok_actions to SNS topic (recovery notifications)"
assert_active_count_at_least "$monitor_main_file" 'treat_missing_data[[:space:]]*=[[:space:]]*"notBreaching"' 6 "All 6 alarms treat missing data as not breaching"

echo ""
echo "--- Monitoring module variables ---"
assert_contains_active "$monitor_vars_file" 'variable "alert_emails"' "Monitoring has alert_emails variable"
assert_contains_active "$monitor_vars_file" 'variable "api_instance_id"' "Monitoring has api_instance_id variable"
assert_contains_active "$monitor_vars_file" 'variable "db_instance_identifier"' "Monitoring has db_instance_identifier variable"
assert_contains_active "$monitor_vars_file" 'variable "alb_arn_suffix"' "Monitoring has alb_arn_suffix variable"
assert_contains_active "$monitor_vars_file" 'variable "env"' "Monitoring has env variable"
assert_contains_active "$monitor_vars_file" 'variable "region"' "Monitoring has region variable"
assert_contains_active "$monitor_vars_file" 'variable "canary_image"' "Monitoring has canary_image publication input"
assert_contains_active "$monitor_vars_file" 'tag[[:space:]]*=[[:space:]]*string' "canary_image variable includes image tag field"
assert_contains_active "$monitor_vars_file" 'variable "canary_schedule"' "Monitoring has canary_schedule input"
assert_contains_active "$monitor_vars_file" 'expression[[:space:]]*=[[:space:]]*string' "canary_schedule variable includes schedule expression field"
assert_contains_active "$monitor_vars_file" 'enabled[[:space:]]*=[[:space:]]*bool' "canary_schedule variable includes operator enable flag"

echo "--- Monitoring module canary outputs ---"
assert_contains_active "$monitor_outputs_file" 'output "customer_loop_canary_ecr_repository_url"' "Monitoring exports canary ECR repository URL"
assert_contains_active "$monitor_outputs_file" 'output "customer_loop_canary_image_uri"' "Monitoring exports canonical canary image URI"
assert_contains_active "$monitor_outputs_file" 'output "customer_loop_canary_lambda_function_arn"' "Monitoring exports canary Lambda function ARN"
assert_contains_active "$monitor_outputs_file" 'output "customer_loop_canary_schedule_rule_name"' "Monitoring exports canary schedule rule name"

echo "--- Shared module contract updates ---"
assert_contains_active "$data_outputs_file" 'output "db_instance_identifier"' "Data module exports db_instance_identifier"
assert_contains_active "$data_outputs_file" 'value[[:space:]]*=[[:space:]]*aws_db_instance\.main\.identifier' "db_instance_identifier output uses aws_db_instance.main.identifier"
assert_contains_active "$dns_outputs_file" 'output "alb_arn_suffix"' "DNS module exports ALB arn suffix"
assert_contains_active "$shared_main_file" 'module "monitoring"' "Root main wires monitoring module"
assert_contains_active "$shared_main_file" 'source[[:space:]]*=[[:space:]]*"../monitoring"' "monitoring module source is ../monitoring"
assert_contains_active "$shared_main_file" 'api_instance_id[[:space:]]*=[[:space:]]*module\.compute\.api_instance_id' "monitoring module receives API instance id"
assert_contains_active "$shared_main_file" 'db_instance_identifier[[:space:]]*=[[:space:]]*module\.data\.db_instance_identifier' "monitoring module receives DB instance identifier"
assert_contains_active "$shared_main_file" 'alb_arn_suffix[[:space:]]*=[[:space:]]*module\.dns\.alb_arn_suffix' "monitoring module receives ALB arn suffix"
assert_contains_active "$shared_main_file" 'alert_emails[[:space:]]*=[[:space:]]*terraform_data\.prod_alert_emails_guard\.output' "root forwards guard-normalized alert_emails to monitoring"
assert_contains_active "$shared_main_file" 'canary_image[[:space:]]*=[[:space:]]*var\.canary_image' "root forwards canonical canary image input to monitoring"
assert_contains_active "$shared_main_file" 'canary_schedule[[:space:]]*=[[:space:]]*var\.canary_schedule' "root forwards canonical canary schedule input to monitoring"
assert_file_contains "$shared_vars_file" 'variable "alert_emails"' "shared variables define alert_emails"
assert_contains_active "$shared_vars_file" 'alltrue\(\[' "shared alert_emails validation enforces each normalized entry"
assert_contains_active "$shared_vars_file" 'trimspace\(email\)[[:space:]]*!=[[:space:]]*""' "shared alert_emails validation rejects blank values after normalization"
assert_contains_active "$shared_vars_file" 'can\(regex\(' "shared alert_emails validation enforces email-shaped values"
assert_contains_active "$shared_main_file" 'resource "terraform_data" "prod_alert_emails_guard"' "root module defines prod alert_emails guard resource"
assert_contains_active "$shared_main_file" 'condition[[:space:]]*=[[:space:]]*var\.env[[:space:]]*!=[[:space:]]*"prod"[[:space:]]*\|\|[[:space:]]*length\(local\.alert_emails_normalized\)[[:space:]]*>[[:space:]]*0' "prod alert_emails guard rejects empty normalized list in prod"
assert_file_contains "$shared_vars_file" 'variable "canary_image"' "shared variables define canary_image"
assert_file_contains "$shared_vars_file" 'variable "canary_schedule"' "shared variables define canary_schedule"

echo ""
echo "--- Hardening checks ---"
assert_not_contains_active "$monitor_main_file" 'arn:[0-9A-Za-z:/-]+' "Monitoring config contains no hardcoded ARNs"
assert_not_contains_active "$monitor_main_file" '[0-9]{12}' "Monitoring config contains no hardcoded AWS account IDs"

test_summary "Stage 7 static checks"
