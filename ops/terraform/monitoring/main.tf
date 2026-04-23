# Monitoring module: SNS + CloudWatch alarms for API, RDS, and ALB health.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  cloudtrail_name               = var.cloudtrail_name_override != "" ? var.cloudtrail_name_override : "fjcloud-${var.env}-guardrails"
  cloudtrail_export_bucket_name = var.cloudtrail_export_bucket_name != "" ? var.cloudtrail_export_bucket_name : "fjcloud-${var.env}-cloudtrail-export"
  cloudtrail_source_arn         = "arn:${data.aws_partition.current.partition}:cloudtrail:${var.region}:${data.aws_caller_identity.current.account_id}:trail/${local.cloudtrail_name}"
  live_e2e_budget_name          = "fjcloud-${var.env}-live-e2e-spend"
  live_e2e_budget_configured    = var.live_e2e_monthly_spend_limit_usd != null
}

resource "aws_sns_topic" "alerts" {
  name = "fjcloud-alerts-${var.env}"

  tags = {
    Name = "fjcloud-alerts-${var.env}"
  }
}

resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.alert_emails)

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.key
}

# CloudTrail ownership stays in monitoring so audit evidence and alarming live
# under one module contract. Stage 3 keeps this intentionally minimal.
resource "aws_s3_bucket" "cloudtrail_export" {
  bucket = local.cloudtrail_export_bucket_name

  tags = {
    Name = local.cloudtrail_export_bucket_name
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail_export" {
  bucket = aws_s3_bucket.cloudtrail_export.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail_export_retention" {
  bucket = aws_s3_bucket.cloudtrail_export.id

  rule {
    id     = "cloudtrail-export-retention"
    status = "Enabled"

    expiration {
      days = var.cloudtrail_retention_days
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail_export" {
  bucket = aws_s3_bucket.cloudtrail_export.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.cloudtrail_export.arn
        Condition = {
          StringEquals = {
            # Limit the service-principal grant to this account/trail so another
            # account cannot use CloudTrail as a confused deputy for this bucket.
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnEquals = {
            "aws:SourceArn" = local.cloudtrail_source_arn
          }
        }
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = format("%s/AWSLogs/%s/%s", aws_s3_bucket.cloudtrail_export.arn, data.aws_caller_identity.current.account_id, "*")
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"      = "bucket-owner-full-control"
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnEquals = {
            "aws:SourceArn" = local.cloudtrail_source_arn
          }
        }
      },
    ]
  })
}

resource "aws_cloudtrail" "cloudtrail" {
  name                          = local.cloudtrail_name
  s3_bucket_name                = aws_s3_bucket.cloudtrail_export.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true

  depends_on = [aws_s3_bucket_policy.cloudtrail_export]

  tags = {
    Name = local.cloudtrail_name
  }
}

# Stage 1 spend-control ownership: keep the budget contract in monitoring.
# The budget itself is only created when operators provide a monthly limit.
resource "aws_budgets_budget" "live_e2e_spend" {
  count = local.live_e2e_budget_configured ? 1 : 0

  name         = local.live_e2e_budget_name
  budget_type  = "COST"
  limit_amount = format("%.2f", var.live_e2e_monthly_spend_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"
}

# Enforcement is disabled by default and only becomes active when operators
# opt in and provide canonical principal/policy/role ownership values.
resource "aws_budgets_budget_action" "live_e2e_spend_enforcement" {
  count = var.live_e2e_budget_action_enabled ? 1 : 0

  budget_name        = local.live_e2e_budget_name
  action_type        = "APPLY_IAM_POLICY"
  notification_type  = "ACTUAL"
  approval_model     = "MANUAL"
  execution_role_arn = var.live_e2e_budget_action_execution_role_arn

  action_threshold {
    action_threshold_type  = "PERCENTAGE"
    action_threshold_value = 100
  }

  definition {
    iam_action_definition {
      policy_arn = var.live_e2e_budget_action_policy_arn
      roles      = [var.live_e2e_budget_action_role_name]
    }
  }

  subscriber {
    address           = var.live_e2e_budget_action_principal_arn
    subscription_type = "IAM"
  }

  depends_on = [aws_budgets_budget.live_e2e_spend]

  lifecycle {
    precondition {
      condition     = local.live_e2e_budget_configured
      error_message = "live_e2e_budget_action_enabled requires live_e2e_monthly_spend_limit_usd."
    }

    precondition {
      condition = (
        var.live_e2e_budget_action_principal_arn != "" &&
        var.live_e2e_budget_action_policy_arn != "" &&
        var.live_e2e_budget_action_role_name != "" &&
        var.live_e2e_budget_action_execution_role_arn != ""
      )
      error_message = "live_e2e_budget_action_enabled requires principal ARN, policy ARN, role name, and execution-role ARN inputs."
    }
  }
}

# ---------------------------------------------------------------------------
# API server CPU > 80% (sustained for 10m)
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "api_cpu_high" {
  alarm_name          = "fjcloud-${var.env}-api-cpu-high"
  alarm_description   = "API EC2 CPU utilization above 80% for 10 minutes"
  comparison_operator = "GreaterThanThreshold"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  treat_missing_data  = "notBreaching"
  datapoints_to_alarm = 2
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    InstanceId = var.api_instance_id
  }
}

# ---------------------------------------------------------------------------
# API EC2 instance status check failed (system or instance impairment)
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "api_status_check_failed" {
  alarm_name          = "fjcloud-${var.env}-api-status-check-failed"
  alarm_description   = "API EC2 status check failed — instance or system impairment"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 1
  treat_missing_data  = "notBreaching"
  datapoints_to_alarm = 2
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    InstanceId = var.api_instance_id
  }
}

# ---------------------------------------------------------------------------
# RDS CPU > 80% (sustained for 10m)
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  alarm_name          = "fjcloud-${var.env}-rds-cpu-high"
  alarm_description   = "RDS CPU utilization above 80% for 10 minutes"
  comparison_operator = "GreaterThanThreshold"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  treat_missing_data  = "notBreaching"
  datapoints_to_alarm = 2
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    DBInstanceIdentifier = var.db_instance_identifier
  }
}

# ---------------------------------------------------------------------------
# RDS free storage space < 2 GiB (critical storage headroom)
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "rds_free_storage_low" {
  alarm_name          = "fjcloud-${var.env}-rds-free-storage-low"
  alarm_description   = "RDS free storage below 2 GiB"
  comparison_operator = "LessThanThreshold"
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 2147483648 # 2 GiB
  treat_missing_data  = "notBreaching"
  datapoints_to_alarm = 2
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    DBInstanceIdentifier = var.db_instance_identifier
  }
}

# ---------------------------------------------------------------------------
# ALB 5XX rate > 1% over 5m
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "alb_5xx_error_rate" {
  alarm_name          = "fjcloud-${var.env}-alb-5xx-error-rate"
  alarm_description   = "ALB 5XX error rate above 1% over 5 minutes"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 1
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  metric_query {
    id          = "m1"
    return_data = false
    metric {
      metric_name = "RequestCount"
      namespace   = "AWS/ApplicationELB"
      period      = 300
      stat        = "Sum"
      unit        = "Count"
      dimensions = {
        LoadBalancer = var.alb_arn_suffix
      }
    }
  }

  metric_query {
    id          = "m2"
    return_data = false
    metric {
      metric_name = "HTTPCode_ELB_5XX_Count"
      namespace   = "AWS/ApplicationELB"
      period      = 300
      stat        = "Sum"
      unit        = "Count"
      dimensions = {
        LoadBalancer = var.alb_arn_suffix
      }
    }
  }

  metric_query {
    id          = "e1"
    expression  = "IF(m1 > 0, (m2 / m1) * 100, 0)"
    label       = "ALB 5XX Error Rate (%)"
    return_data = true
  }
}

# ---------------------------------------------------------------------------
# ALB target response P99 > 2s over 5m
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "alb_p99_target_response_time" {
  alarm_name          = "fjcloud-${var.env}-alb-p99-target-response-time"
  alarm_description   = "ALB P99 target response time above 2s over 5 minutes"
  comparison_operator = "GreaterThanThreshold"
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  extended_statistic  = "p99"
  period              = 300
  evaluation_periods  = 1
  threshold           = 2
  treat_missing_data  = "notBreaching"
  datapoints_to_alarm = 1
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }
}
