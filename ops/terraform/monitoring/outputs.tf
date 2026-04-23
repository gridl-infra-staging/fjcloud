output "sns_topic_arn" {
  description = "SNS topic ARN for infrastructure alerts"
  value       = aws_sns_topic.alerts.arn
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
