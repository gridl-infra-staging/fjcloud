output "sns_topic_arn" {
  description = "SNS topic ARN for infrastructure alerts"
  value       = aws_sns_topic.alerts.arn
}

output "ses_feedback_sns_topic_arn" {
  description = "SNS topic ARN for SES bounce/complaint webhook delivery"
  value       = aws_sns_topic.ses_feedback.arn
}

output "customer_loop_canary_ecr_repository_url" {
  description = "ECR repository URL for the customer loop canary Lambda image"
  value       = aws_ecr_repository.customer_loop_canary.repository_url
}

output "customer_loop_canary_image_uri" {
  description = "Canonical image URI used by the customer loop canary Lambda"
  value       = local.customer_loop_canary_image_uri
}

output "customer_loop_canary_lambda_function_arn" {
  description = "Lambda function ARN for the customer loop canary runtime"
  value       = aws_lambda_function.customer_loop_canary.arn
}

output "customer_loop_canary_schedule_rule_name" {
  description = "EventBridge schedule rule name for the customer loop canary runtime"
  value       = aws_cloudwatch_event_rule.customer_loop_canary.name
}

output "api_cpu_high_alarm_arn" {
  description = "CloudWatch alarm ARN for API CPU over 80%"
  value       = aws_cloudwatch_metric_alarm.api_cpu_high.arn
}

output "api_status_check_failed_alarm_arn" {
  description = "CloudWatch alarm ARN for API EC2 status check failure"
  value       = aws_cloudwatch_metric_alarm.api_status_check_failed.arn
}

output "rds_cpu_high_alarm_arn" {
  description = "CloudWatch alarm ARN for RDS CPU over 80%"
  value       = aws_cloudwatch_metric_alarm.rds_cpu_high.arn
}

output "rds_free_storage_low_alarm_arn" {
  description = "CloudWatch alarm ARN for low RDS free storage"
  value       = aws_cloudwatch_metric_alarm.rds_free_storage_low.arn
}

output "alb_5xx_error_rate_alarm_arn" {
  description = "CloudWatch alarm ARN for ALB 5XX error rate"
  value       = aws_cloudwatch_metric_alarm.alb_5xx_error_rate.arn
}

output "alb_p99_target_response_time_alarm_arn" {
  description = "CloudWatch alarm ARN for ALB P99 target response time"
  value       = aws_cloudwatch_metric_alarm.alb_p99_target_response_time.arn
}

output "cloudtrail_arn" {
  description = "CloudTrail ARN for audit-evidence ownership in monitoring"
  value       = aws_cloudtrail.cloudtrail.arn
}

output "cloudtrail_retention_days" {
  description = "CloudTrail export retention policy in days"
  value       = var.cloudtrail_retention_days
}

output "cloudtrail_export_bucket_name" {
  description = "S3 bucket name used as CloudTrail export destination"
  value       = aws_s3_bucket.cloudtrail_export.bucket
}

output "cloudtrail_export_bucket_arn" {
  description = "S3 bucket ARN used as CloudTrail export destination"
  value       = aws_s3_bucket.cloudtrail_export.arn
}

output "live_e2e_budget_name" {
  description = "Canonical AWS Budgets budget name for live E2E spend guardrails"
  value       = local.live_e2e_budget_name
}

output "live_e2e_budget_configured" {
  description = "Whether a live E2E monthly spend ceiling is currently configured"
  value       = local.live_e2e_budget_configured
}

output "live_e2e_budget_action_enabled" {
  description = "Whether live E2E AWS Budgets action enforcement is operator-enabled"
  value       = var.live_e2e_budget_action_enabled
}

output "support_email_canary_ecr_repository_url" {
  description = "ECR repository URL for support-email canary image publication"
  value       = aws_ecr_repository.support_email_canary.repository_url
}

output "support_email_canary_lambda_function_name" {
  description = "Lambda function name for support-email canary"
  value       = aws_lambda_function.support_email_canary.function_name
}

output "support_email_canary_lambda_function_arn" {
  description = "Lambda function ARN for support-email canary"
  value       = aws_lambda_function.support_email_canary.arn
}

output "support_email_canary_schedule_name" {
  description = "EventBridge schedule rule name for support-email canary"
  value       = aws_cloudwatch_event_rule.support_email_canary.name
}

output "support_email_canary_schedule_arn" {
  description = "EventBridge schedule rule ARN for support-email canary"
  value       = aws_cloudwatch_event_rule.support_email_canary.arn
}

output "support_email_canary_log_group_name" {
  description = "CloudWatch log group name for support-email canary Lambda"
  value       = aws_cloudwatch_log_group.support_email_canary.name
}
