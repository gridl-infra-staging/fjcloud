# Monitoring module: SNS + CloudWatch alarms for API, RDS, and ALB health.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  cloudtrail_name                                = var.cloudtrail_name_override != "" ? var.cloudtrail_name_override : "fjcloud-${var.env}-guardrails"
  cloudtrail_export_bucket_name                  = var.cloudtrail_export_bucket_name != "" ? var.cloudtrail_export_bucket_name : "fjcloud-${var.env}-cloudtrail-export"
  cloudtrail_source_arn                          = "arn:${data.aws_partition.current.partition}:cloudtrail:${var.region}:${data.aws_caller_identity.current.account_id}:trail/${local.cloudtrail_name}"
  ses_configuration_set_source_arn_pattern       = "arn:${data.aws_partition.current.partition}:ses:${var.region}:${data.aws_caller_identity.current.account_id}:configuration-set/*"
  live_e2e_budget_name                           = "fjcloud-${var.env}-live-e2e-spend"
  live_e2e_budget_configured                     = var.live_e2e_monthly_spend_limit_usd != null
  customer_loop_canary_ecr_repository_name       = "fjcloud-${var.env}-customer-loop-canary"
  customer_loop_canary_function_name             = "fjcloud-${var.env}-customer-loop-canary"
  customer_loop_canary_schedule_rule_name        = "fjcloud-${var.env}-customer-loop-canary"
  customer_loop_canary_image_uri                 = "${aws_ecr_repository.customer_loop_canary.repository_url}:${var.canary_image.tag}"
  customer_loop_canary_quiet_until_parameter_arn = "arn:${data.aws_partition.current.partition}:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/fjcloud/${var.env}/canary_quiet_until"
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

resource "aws_sns_topic" "ses_feedback" {
  name = "fjcloud-ses-feedback-${var.env}"

  tags = {
    Name = "fjcloud-ses-feedback-${var.env}"
  }
}

resource "aws_sns_topic_policy" "ses_feedback_publish" {
  arn = aws_sns_topic.ses_feedback.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSESPublishFromAccountConfigurationSets"
        Effect = "Allow"
        Principal = {
          Service = "ses.amazonaws.com"
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.ses_feedback.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnLike = {
            "aws:SourceArn" = local.ses_configuration_set_source_arn_pattern
          }
        }
      }
    ]
  })
}

resource "aws_sns_topic_subscription" "ses_feedback_webhook" {
  topic_arn = aws_sns_topic.ses_feedback.arn
  protocol  = "https"
  endpoint  = "https://api.${var.domain}/webhooks/ses/sns"
}

# Stage 5 canary packaging ownership: monitoring owns the canonical ECR path
# and Lambda/EventBridge wiring, while the runtime behavior remains in
# scripts/canary/customer_loop_synthetic.sh.
resource "aws_ecr_repository" "customer_loop_canary" {
  name                 = local.customer_loop_canary_ecr_repository_name
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Keep image history bounded so repeated SHA pushes do not grow indefinitely.
resource "aws_ecr_lifecycle_policy" "customer_loop_canary" {
  repository = aws_ecr_repository.customer_loop_canary.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep the 50 most recent canary image tags"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 50
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

resource "aws_iam_role" "customer_loop_canary_lambda" {
  name = "fjcloud-${var.env}-customer-loop-canary-lambda"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "customer_loop_canary_lambda" {
  name = "fjcloud-${var.env}-customer-loop-canary-lambda"
  role = aws_iam_role.customer_loop_canary_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:logs:${var.region}:${data.aws_caller_identity.current.account_id}:*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.customer_loop_canary_function_name}:*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter"
        ]
        Resource = local.customer_loop_canary_quiet_until_parameter_arn
      }
    ]
  })
}

resource "aws_lambda_function" "customer_loop_canary" {
  function_name = local.customer_loop_canary_function_name
  role          = aws_iam_role.customer_loop_canary_lambda.arn
  package_type  = "Image"
  image_uri     = local.customer_loop_canary_image_uri
  timeout       = 900
  memory_size   = 512

  image_config {
    # This command intentionally points at the existing canary owner script.
    command = ["scripts/canary/customer_loop_synthetic.sh"]
  }

  environment {
    variables = {
      ENVIRONMENT       = var.env
      CANARY_AWS_REGION = var.region
    }
  }
}

resource "aws_cloudwatch_event_rule" "customer_loop_canary" {
  name                = local.customer_loop_canary_schedule_rule_name
  description         = "Scheduled trigger for customer loop synthetic canary"
  schedule_expression = var.canary_schedule.expression
  is_enabled          = var.canary_schedule.enabled
}

resource "aws_cloudwatch_event_target" "customer_loop_canary" {
  rule      = aws_cloudwatch_event_rule.customer_loop_canary.name
  target_id = "customer-loop-canary"
  arn       = aws_lambda_function.customer_loop_canary.arn
}

resource "aws_lambda_permission" "customer_loop_canary_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridgeSchedule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.customer_loop_canary.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.customer_loop_canary.arn
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
#
# Pre-launch operational note: as of 2026-04-23, fjcloud-staging runs an
# out-of-band alert-only budget named `fjcloud-staging-monthly` created via
# AWS CLI (see docs/runbooks/staging-evidence.md "AWS Budget And Spend
# Alerting"). That budget exists specifically because the operator declined
# auto-enforcement via `aws_budgets_budget_action` below and wanted email
# alerts without standing up the 4 IAM enforcement inputs. Setting
# `var.live_e2e_monthly_spend_limit_usd` here would create a second budget
# named `fjcloud-<env>-live-e2e-spend` — intentional duplication should be
# avoided; either import the existing manual budget into this resource, or
# delete the manual budget before setting the variable.
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

# ---------------------------------------------------------------------------
# AWS account cumulative-monthly charges > threshold (T0.4 — budget-exceeded page).
#
# What this catches: cumulative monthly spend has already crossed the
# operator-set threshold (default 700 USD, slightly above the 600 USD/mo
# budget). Pages within ~6h of the breach via the existing
# aws_sns_topic.alerts — much faster than AWS Budgets's monthly-email
# cadence, which would only surface the overspend at month-end.
#
# What this does NOT catch: sub-budget spikes (e.g. a runaway loop
# spending 200 USD in one hour while still under the monthly cap). That
# requires a metric-math rate-of-change expression which AWS/Billing's
# 6h publish cadence makes brittle. Out of scope for Tier 0; T2.X may
# add it as a supplementary alarm.
#
# Three AWS-Billing-specific quirks worth keeping in mind so a future
# agent doesn't undo them:
#
#   1. EstimatedCharges is published ONLY in us-east-1. The
#      `provider = aws.us_east_1` line below is REQUIRED — without it,
#      the alarm receives no data points and never fires. See
#      providers.tf for the alias definition.
#
#   2. The metric is CUMULATIVE FOR THE CURRENT CALENDAR MONTH (a
#      monotonically-increasing running total that resets on the 1st),
#      not a daily delta. Setting the threshold to a small per-day
#      number (e.g. 50 USD) would alarm permanently mid-month —
#      see variables.tf:billing_alarm_threshold_usd for the
#      semantically-correct tuning.
#
#   3. AWS publishes EstimatedCharges every ~6h with a 24-72h delay,
#      so the smallest meaningful period is 21600s. Tighter periods
#      evaluate against missing data points and produce noise.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "billing_estimated_charges_high" {
  provider = aws.us_east_1

  alarm_name          = "fjcloud-${var.env}-billing-estimated-charges-high"
  alarm_description   = "AWS cumulative monthly charges crossed the configured threshold"
  comparison_operator = "GreaterThanThreshold"
  metric_name         = "EstimatedCharges"
  namespace           = "AWS/Billing"
  statistic           = "Maximum"
  period              = 21600 # 6h — AWS/Billing's published cadence
  evaluation_periods  = 1
  threshold           = var.billing_alarm_threshold_usd
  treat_missing_data  = "notBreaching"
  datapoints_to_alarm = 1

  # Reuse the existing alerts SNS topic — same routing as every other
  # operational alarm in this module, including email subscriptions in
  # var.alert_emails. No new topic / subscription needed.
  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  dimensions = {
    Currency = "USD"
  }
}
