#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

compute_main_file="ops/terraform/compute/main.tf"
compute_vars_file="ops/terraform/compute/variables.tf"
compute_providers_file="ops/terraform/compute/providers.tf"
compute_outputs_file="ops/terraform/compute/outputs.tf"
iam_file="ops/iam/fjcloud-instance-role.tf"
shared_main_file="ops/terraform/_shared/main.tf"
shared_outputs_file="ops/terraform/_shared/outputs.tf"
systemd_api_file="ops/systemd/fjcloud-api.service"
systemd_agg_file="ops/systemd/fjcloud-aggregation-job.service"
systemd_timer_file="ops/systemd/fjcloud-aggregation-job.timer"
systemd_retention_service_file="ops/systemd/fjcloud-retention-job.service"
systemd_retention_timer_file="ops/systemd/fjcloud-retention-job.timer"
systemd_metering_file="ops/systemd/fj-metering-agent.service"
env_vars_doc_file="docs/env-vars.md"

# ============================================================================
# 3.1 — Compute module file existence
# ============================================================================

assert_file_exists "$compute_main_file" "compute/main.tf exists"
assert_file_exists "$compute_vars_file" "compute/variables.tf exists"
assert_file_exists "$compute_providers_file" "compute/providers.tf exists"
assert_file_exists "$compute_outputs_file" "compute/outputs.tf exists"

# ============================================================================
# 3.1 — Variables
# ============================================================================

assert_contains_active "$compute_vars_file" 'contains\(\["staging", "prod"\], var\.env\)' "Compute env variable restricts values to staging/prod"
assert_contains_active "$compute_vars_file" '^[[:space:]]*variable[[:space:]]+"ami_id"' "Compute module declares ami_id input"
assert_contains_active "$compute_vars_file" '^[[:space:]]*variable[[:space:]]+"api_instance_type"' "Compute module declares api_instance_type input"
assert_contains_active "$compute_vars_file" '^[[:space:]]*variable[[:space:]]+"private_subnet_ids"' "Compute module declares private_subnet_ids input"
assert_contains_active "$compute_vars_file" '^[[:space:]]*variable[[:space:]]+"sg_api_id"' "Compute module declares sg_api_id input"
assert_contains_active "$compute_vars_file" '^[[:space:]]*variable[[:space:]]+"instance_profile_name"' "Compute module declares instance_profile_name input"

# ============================================================================
# 3.1 — EC2 instance resource
# ============================================================================

assert_contains_active "$compute_main_file" '^[[:space:]]*resource[[:space:]]+"aws_instance"[[:space:]]+"api"' "EC2 instance resource exists"
assert_contains_active "$compute_main_file" 'var\.ami_id' "AMI uses variable (no hardcoded AMI)"
assert_contains_active "$compute_main_file" 'var\.api_instance_type' "Instance type uses variable"
assert_contains_active "$compute_main_file" 'element\(var\.private_subnet_ids,[[:space:]]*0\)' "Instance placed in first private subnet"
assert_contains_active "$compute_main_file" 'var\.sg_api_id' "Security group references variable"
assert_contains_active "$compute_main_file" 'associate_public_ip_address[[:space:]]*=[[:space:]]*false' "Public IP explicitly disabled"

# ============================================================================
# 3.1 — IMDSv2 metadata options
# ============================================================================

assert_contains_active "$compute_main_file" 'metadata_options' "metadata_options block present"
assert_contains_active "$compute_main_file" 'http_tokens[[:space:]]*=[[:space:]]*"required"' "IMDSv2 enforced (http_tokens = required)"
assert_contains_active "$compute_main_file" 'http_endpoint[[:space:]]*=[[:space:]]*"enabled"' "IMDS endpoint enabled"
assert_contains_active "$compute_main_file" 'instance_metadata_tags[[:space:]]*=[[:space:]]*"enabled"' "Instance metadata tags enabled"

# ============================================================================
# 3.1 — Root block device
# ============================================================================

assert_contains_active "$compute_main_file" 'root_block_device' "root_block_device block present"
assert_contains_active "$compute_main_file" 'volume_type[[:space:]]*=[[:space:]]*"gp3"' "Root volume type is gp3"
assert_contains_active "$compute_main_file" 'volume_size[[:space:]]*=[[:space:]]*40' "Root volume size is 40GB"
assert_contains_active "$compute_main_file" 'encrypted[[:space:]]*=[[:space:]]*true' "Root volume is encrypted"
assert_contains_active "$compute_main_file" 'delete_on_termination[[:space:]]*=[[:space:]]*true' "Root volume deletes on termination"

# ============================================================================
# 3.1 — Key pair
# ============================================================================

assert_contains_active "$compute_main_file" 'resource[[:space:]]+"tls_private_key"' "TLS private key resource exists"
assert_contains_active "$compute_main_file" 'algorithm[[:space:]]*=[[:space:]]*"ED25519"' "SSH key uses ED25519 algorithm"
assert_contains_active "$compute_main_file" 'resource[[:space:]]+"aws_key_pair"' "AWS key pair resource exists"

# ============================================================================
# 3.1 — IAM instance profile wired
# ============================================================================

assert_contains_active "$compute_main_file" 'iam_instance_profile' "IAM instance profile wired on EC2 instance"

# ============================================================================
# 3.1 — User data present
# ============================================================================

assert_contains_active "$compute_main_file" 'user_data' "User data present on EC2 instance"
assert_contains_active "$compute_main_file" 'user_data_replace_on_change[[:space:]]*=[[:space:]]*false' "user_data_replace_on_change remains false"
assert_contains_active "$compute_main_file" 'amazon-cloudwatch-agent' "Compute bootstrap installs CloudWatch agent"
assert_contains_active "$compute_main_file" 'disk_used_percent' "Compute bootstrap configures disk_used_percent collection"
assert_contains_active "$compute_main_file" 'amazon-cloudwatch-agent-ctl' "Compute bootstrap starts CloudWatch agent via ctl"

# ============================================================================
# 3.1 — Tags
# ============================================================================

assert_contains_active "$compute_main_file" 'Name[[:space:]]*=' "Name tag present on instance"
assert_contains_active "$compute_main_file" 'Env[[:space:]]*=' "Env tag present on instance"

# ============================================================================
# 3.1 — Outputs
# ============================================================================

assert_contains_active "$compute_outputs_file" '^[[:space:]]*output[[:space:]]+"api_instance_id"' "Output api_instance_id exists"
assert_contains_active "$compute_outputs_file" '^[[:space:]]*output[[:space:]]+"api_private_ip"' "Output api_private_ip exists"
assert_contains_active "$compute_outputs_file" '^[[:space:]]*output[[:space:]]+"ssh_key_pair_name"' "Output ssh_key_pair_name exists"

# ============================================================================
# 3.2 — IAM policy updates
# ============================================================================

assert_file_contains "$iam_file" 'ssm:GetParametersByPath' "IAM policy includes ssm:GetParametersByPath"
assert_file_contains "$iam_file" 'ssm:PutParameter' "IAM policy includes ssm:PutParameter"
assert_file_contains "$iam_file" 'ssm:DeleteParameter' "IAM policy includes ssm:DeleteParameter"
assert_file_not_contains "$iam_file" 'ssm:DescribeParameters' "IAM policy does not grant account-wide SSM parameter metadata enumeration"
assert_file_contains "$iam_file" 'ec2:RunInstances' "IAM policy includes ec2:RunInstances"
assert_file_contains "$iam_file" 'ec2:DescribeInstances' "IAM policy includes ec2:DescribeInstances"
assert_file_contains "$iam_file" 'ec2:StartInstances' "IAM policy includes ec2:StartInstances"
assert_file_contains "$iam_file" 'ec2:StopInstances' "IAM policy includes ec2:StopInstances"
assert_file_contains "$iam_file" 'ec2:TerminateInstances' "IAM policy includes ec2:TerminateInstances"
assert_file_contains "$iam_file" 'ec2:CreateTags' "IAM policy includes ec2:CreateTags"
assert_file_contains "$iam_file" 'iam:PassRole' "IAM policy includes iam:PassRole"
assert_file_contains "$iam_file" 's3:GetObject' "IAM policy includes s3:GetObject"
assert_file_contains "$iam_file" 's3:ListBucket' "IAM policy includes s3:ListBucket"
assert_file_contains "$iam_file" 'fjcloud-releases' "IAM S3 policy references fjcloud-releases bucket"
assert_file_contains "$iam_file" 'cloudwatch:PutMetricData' "IAM policy includes cloudwatch:PutMetricData"
assert_file_contains "$iam_file" 'CWAgent' "IAM policy allows CWAgent namespace metric publish"
assert_file_contains "$iam_file" 'logs:CreateLogGroup' "IAM policy includes logs:CreateLogGroup"
assert_file_contains "$iam_file" 'logs:CreateLogStream' "IAM policy includes logs:CreateLogStream"
assert_file_contains "$iam_file" 'logs:PutLogEvents' "IAM policy includes logs:PutLogEvents"
assert_file_contains "$iam_file" 'logs:DescribeLogStreams' "IAM policy includes logs:DescribeLogStreams"

ses_send_events_read_policy="fjcloud_ses_send_events_read"
ses_send_events_filter_group='arn:aws:logs:us-east-1:\$\{data\.aws_caller_identity\.current\.account_id\}:log-group:/fjcloud/staging/ses/send-events:\*'
ses_send_events_get_stream='arn:aws:logs:us-east-1:\$\{data\.aws_caller_identity\.current\.account_id\}:log-group:/fjcloud/staging/ses/send-events:log-stream:\*'
ses_send_events_wildcard_read_actions='"logs:(Describe|Filter|Get|Read)[^"]*\*"'
ses_send_events_disallowed_sibling_read_actions='"logs:(DescribeLogGroups|FilterLogEvents|GetLogEvents|\*|(Describe|Filter|Get|Read)[^"]*\*)"'

assert_named_resource_count "$iam_file" "aws_iam_role_policy" "$ses_send_events_read_policy" "1" "IAM defines exactly one SES send-events read policy resource"
assert_resource_block_contains "$iam_file" "aws_iam_role_policy" "$ses_send_events_read_policy" 'name[[:space:]]*=[[:space:]]*"fjcloud-ses-send-events-read"' "SES send-events read policy has canonical inline policy name"
assert_resource_block_contains "$iam_file" "aws_iam_role_policy" "$ses_send_events_read_policy" 'role[[:space:]]*=[[:space:]]*aws_iam_role\.fjcloud_instance\.id' "SES send-events read policy attaches to fjcloud instance role"
assert_resource_block_contains_multiline "$iam_file" "aws_iam_role_policy" "$ses_send_events_read_policy" '\{[[:space:]]*Effect[[:space:]]*=[[:space:]]*"Allow"[[:space:]]*Action[[:space:]]*=[[:space:]]*\["logs:DescribeLogGroups"\][[:space:]]*Resource[[:space:]]*=[[:space:]]*"\*"[[:space:]]*\}' "SES send-events read policy keeps DescribeLogGroups unscoped"
assert_resource_block_contains_multiline "$iam_file" "aws_iam_role_policy" "$ses_send_events_read_policy" '\{[[:space:]]*Effect[[:space:]]*=[[:space:]]*"Allow"[[:space:]]*Action[[:space:]]*=[[:space:]]*\["logs:FilterLogEvents"\][[:space:]]*Resource[[:space:]]*=[[:space:]]*"'"$ses_send_events_filter_group"'"[[:space:]]*\}' "SES send-events read policy scopes FilterLogEvents to staging send-events log group"
assert_resource_block_contains_multiline "$iam_file" "aws_iam_role_policy" "$ses_send_events_read_policy" '\{[[:space:]]*Effect[[:space:]]*=[[:space:]]*"Allow"[[:space:]]*Action[[:space:]]*=[[:space:]]*\["logs:GetLogEvents"\][[:space:]]*Resource[[:space:]]*=[[:space:]]*"'"$ses_send_events_get_stream"'"[[:space:]]*\}' "SES send-events read policy scopes GetLogEvents to staging send-events log streams"
assert_resource_block_pattern_count "$iam_file" "aws_iam_role_policy" "$ses_send_events_read_policy" '"logs:DescribeLogGroups"' "1" "SES send-events read policy has exactly one DescribeLogGroups grant"
assert_resource_block_pattern_count "$iam_file" "aws_iam_role_policy" "$ses_send_events_read_policy" '"logs:FilterLogEvents"' "1" "SES send-events read policy has exactly one FilterLogEvents grant"
assert_resource_block_pattern_count "$iam_file" "aws_iam_role_policy" "$ses_send_events_read_policy" '"logs:GetLogEvents"' "1" "SES send-events read policy has exactly one GetLogEvents grant"
assert_resource_block_pattern_count "$iam_file" "aws_iam_role_policy" "$ses_send_events_read_policy" 'Effect[[:space:]]*=[[:space:]]*"Allow"' "3" "SES send-events read policy has exactly three allow statements"
assert_resource_block_pattern_count "$iam_file" "aws_iam_role_policy" "$ses_send_events_read_policy" 'Action[[:space:]]*=' "3" "SES send-events read policy has exactly three action grants"
assert_resource_block_not_contains "$iam_file" "aws_iam_role_policy" "$ses_send_events_read_policy" 'NotAction[[:space:]]*=' "SES send-events read policy does not use NotAction grants"
assert_resource_block_not_contains "$iam_file" "aws_iam_role_policy" "$ses_send_events_read_policy" '"logs:\*"|log-group:/fjcloud/\*' "SES send-events read policy does not use wildcard Logs actions or broad fjcloud log-group scope"
assert_resource_block_not_contains "$iam_file" "aws_iam_role_policy" "$ses_send_events_read_policy" "$ses_send_events_wildcard_read_actions" "SES send-events read policy does not use wildcard-family Logs read actions"
assert_sibling_resource_blocks_not_contains "$iam_file" "aws_iam_role_policy" "$ses_send_events_read_policy" "$ses_send_events_disallowed_sibling_read_actions" "SES send-events read actions have no sibling IAM policy owner"

# ============================================================================
# 3.2 — CloudWatch ownership drift guardrails
# ============================================================================

assert_file_not_contains "$compute_vars_file" 'cloudwatch-agent|cwagent|disk_used_percent' "Compute variables do not introduce CloudWatch agent parallel owner"
assert_file_not_contains "$compute_outputs_file" 'cloudwatch-agent|cwagent|disk_used_percent' "Compute outputs do not introduce CloudWatch agent parallel owner"
assert_file_not_contains "$shared_main_file" 'cloudwatch-agent|cwagent|disk_used_percent' "Shared terraform does not introduce CloudWatch agent parallel owner"
assert_file_not_contains "$shared_outputs_file" 'cloudwatch-agent|cwagent|disk_used_percent' "Shared terraform outputs do not introduce CloudWatch agent parallel owner"

# ============================================================================
# 3.3 — systemd service files
# ============================================================================

assert_file_exists "$systemd_api_file" "fjcloud-api.service exists"
assert_file_exists "$systemd_agg_file" "fjcloud-aggregation-job.service exists"
assert_file_exists "$systemd_timer_file" "fjcloud-aggregation-job.timer exists"
assert_file_exists "$systemd_retention_service_file" "fjcloud-retention-job.service exists"
assert_file_exists "$systemd_retention_timer_file" "fjcloud-retention-job.timer exists"

# API service checks (use assert_file_contains — systemd files are not Terraform)
assert_file_contains "$systemd_api_file" '^Type=exec' "API service Type=exec"
assert_file_contains "$systemd_api_file" '^User=fjcloud' "API service User=fjcloud"
assert_file_contains "$systemd_api_file" 'ExecStart=/usr/local/bin/fjcloud-api' "API service ExecStart correct"
assert_file_contains "$systemd_api_file" 'EnvironmentFile=-/etc/fjcloud/env' "API service EnvironmentFile with dash prefix"
assert_file_contains "$systemd_api_file" 'ENVIRONMENT is prod/production' "API service documents prod/production alert-webhook requirement"
assert_file_contains "$systemd_api_file" 'SLACK_WEBHOOK_URL or DISCORD_WEBHOOK_URL' "API service names accepted production alert webhook variables"
assert_file_contains "$systemd_api_file" 'Restart=on-failure' "API service Restart=on-failure"
assert_file_contains "$systemd_api_file" 'RestartSec=5' "API service RestartSec=5"
assert_file_contains "$systemd_api_file" 'NoNewPrivileges=true' "API service NoNewPrivileges=true"
assert_file_contains "$systemd_api_file" 'ProtectSystem=strict' "API service ProtectSystem=strict"
assert_file_contains "$systemd_api_file" 'ProtectHome=true' "API service ProtectHome=true"
assert_file_contains "$systemd_api_file" 'PrivateTmp=true' "API service PrivateTmp=true"

# Aggregation job service checks
assert_file_contains "$systemd_agg_file" '^Type=oneshot' "Aggregation service Type=oneshot"
assert_file_contains "$systemd_agg_file" '^User=fjcloud' "Aggregation service User=fjcloud"
assert_file_contains "$systemd_agg_file" 'ExecStart=/usr/local/bin/fjcloud-aggregation-job' "Aggregation service ExecStart correct"
assert_file_contains "$systemd_agg_file" 'EnvironmentFile=-/etc/fjcloud/env' "Aggregation service EnvironmentFile with dash prefix"
assert_file_contains "$systemd_agg_file" 'NoNewPrivileges=true' "Aggregation service NoNewPrivileges=true"
assert_file_contains "$systemd_agg_file" 'ProtectSystem=strict' "Aggregation service ProtectSystem=strict"
assert_file_contains "$systemd_agg_file" 'ProtectHome=true' "Aggregation service ProtectHome=true"
assert_file_contains "$systemd_agg_file" 'PrivateTmp=true' "Aggregation service PrivateTmp=true"

# Timer checks
assert_file_contains "$systemd_timer_file" 'OnCalendar=\*-\*-\* 01:00:00' "Timer fires at 01:00 UTC daily"
assert_file_contains "$systemd_timer_file" 'OnCalendar=\*-\*-\* 01:00:00 UTC' "Timer schedule explicitly uses UTC timezone"
assert_file_contains "$systemd_timer_file" 'Persistent=true' "Timer is persistent (catches missed runs)"

# Retention job service checks
assert_file_contains "$systemd_retention_service_file" '^Type=oneshot' "Retention service Type=oneshot"
assert_file_contains "$systemd_retention_service_file" '^User=fjcloud' "Retention service User=fjcloud"
assert_file_contains "$systemd_retention_service_file" 'ExecStart=/usr/local/bin/fjcloud-retention-job' "Retention service ExecStart correct"
assert_file_contains "$systemd_retention_service_file" 'EnvironmentFile=-/etc/fjcloud/env' "Retention service EnvironmentFile with dash prefix"
assert_file_contains "$systemd_retention_service_file" 'Environment=API_URL=http://127.0.0.1:3001' "Retention service pins API_URL to local control plane"
assert_file_contains "$systemd_retention_service_file" 'defaults to dry-run' "Retention service comments the dry-run default before overriding"
assert_file_contains "$systemd_retention_service_file" 'Environment=RETENTION_DRY_RUN=0' "Retention service pins RETENTION_DRY_RUN=0 for live purge"
assert_file_contains "$systemd_retention_service_file" 'NoNewPrivileges=true' "Retention service NoNewPrivileges=true"
assert_file_contains "$systemd_retention_service_file" 'ProtectSystem=strict' "Retention service ProtectSystem=strict"
assert_file_contains "$systemd_retention_service_file" 'ProtectHome=true' "Retention service ProtectHome=true"
assert_file_contains "$systemd_retention_service_file" 'PrivateTmp=true' "Retention service PrivateTmp=true"

# Retention job timer checks
assert_file_contains "$systemd_retention_timer_file" 'OnCalendar=\*-\*-\* [0-9][0-9]:[0-9][0-9]:[0-9][0-9] UTC' "Retention timer fires daily with explicit UTC timezone"
assert_file_contains "$systemd_retention_timer_file" 'Persistent=true' "Retention timer is persistent (catches missed runs)"

# Metering agent security check (existing file)
assert_file_contains "$systemd_metering_file" 'ConditionPathExists=/etc/fjcloud/metering-env' "Metering agent condition path uses /etc/fjcloud/metering-env"
assert_file_contains "$systemd_metering_file" 'EnvironmentFile=-/etc/fjcloud/metering-env' "Metering agent EnvironmentFile uses /etc/fjcloud/metering-env"
assert_file_contains "$systemd_metering_file" 'NoNewPrivileges=true' "Metering agent has NoNewPrivileges=true"
assert_file_contains "$systemd_metering_file" 'ProtectSystem=strict' "Metering agent has ProtectSystem=strict"
assert_file_contains "$systemd_metering_file" 'ProtectHome=true' "Metering agent has ProtectHome=true"
assert_file_contains "$systemd_metering_file" 'PrivateTmp=true' "Metering agent has PrivateTmp=true"
assert_file_contains "$env_vars_doc_file" 'When set to `prod` or `production`, startup requires at least one non-blank alert webhook' "ENVIRONMENT docs mention production alert-webhook startup contract"
assert_file_contains "$env_vars_doc_file" 'startup fails closed unless at least one webhook is non-blank' "Alerting docs mention fail-closed production webhook gate"
assert_file_contains "$env_vars_doc_file" 'Outside `prod`/`production`, if both webhook variables are absent or blank, alerts fall back to `LogAlertService`' "Alerting docs preserve non-production log fallback contract"

# ============================================================================
# 3.4 — Module wiring
# ============================================================================

assert_contains_active "$shared_main_file" 'module[[:space:]]+"compute"' "Compute module wired in shared main.tf"
assert_contains_active "$shared_main_file" 'module[[:space:]]+"data"' "Data module wired in shared main.tf"

# Check compute module output is uncommented in shared outputs
assert_contains_active "$shared_outputs_file" '^[[:space:]]*output[[:space:]]+"api_instance_ip"' "api_instance_ip output uncommented in shared outputs"

# ============================================================================
# 3.1 — No hardcoded AMI IDs
# ============================================================================

assert_not_contains_active "$compute_main_file" 'ami[[:space:]]*=[[:space:]]*"ami-[0-9a-f]' "No hardcoded AMI IDs in compute main.tf"
assert_not_contains_active "$compute_main_file" 'ignore_changes[[:space:]]*=[[:space:]]*\[ami\]' "EC2 lifecycle does not ignore AMI changes"

test_summary "Stage 3 static checks"
