locals {
  support_email_canary_name                = "fjcloud-${var.env}-support-email-canary"
  support_email_canary_ecr_repository_name = "fjcloud-${var.env}-support-email-canary"
  support_email_canary_log_group_name      = "/aws/lambda/${local.support_email_canary_name}"

  support_email_canary_slack_webhook_parameter_name = var.support_email_canary_slack_webhook_parameter_name != "" ? var.support_email_canary_slack_webhook_parameter_name : "/fjcloud/${var.env}/slack_webhook_url"
  support_email_canary_discord_webhook_parameter_name = var.support_email_canary_discord_webhook_parameter_name != "" ? var.support_email_canary_discord_webhook_parameter_name : "/fjcloud/${var.env}/discord_webhook_url"

  support_email_canary_inbound_roundtrip_s3_path_segments = split("/", trimprefix(var.support_email_canary_inbound_roundtrip_s3_uri, "s3://"))
  support_email_canary_inbound_roundtrip_s3_bucket        = local.support_email_canary_inbound_roundtrip_s3_path_segments[0]
  support_email_canary_inbound_roundtrip_s3_prefix        = join("/", slice(local.support_email_canary_inbound_roundtrip_s3_path_segments, 1, length(local.support_email_canary_inbound_roundtrip_s3_path_segments)))
  support_email_canary_inbound_roundtrip_s3_prefix_clean  = trim(local.support_email_canary_inbound_roundtrip_s3_prefix, "/")
  support_email_canary_inbound_roundtrip_list_prefixes    = local.support_email_canary_inbound_roundtrip_s3_prefix_clean == "" ? [""] : [local.support_email_canary_inbound_roundtrip_s3_prefix_clean, "${local.support_email_canary_inbound_roundtrip_s3_prefix_clean}/*"]

  support_email_canary_inbound_roundtrip_bucket_arn = "arn:${data.aws_partition.current.partition}:s3:::${local.support_email_canary_inbound_roundtrip_s3_bucket}"
  support_email_canary_inbound_roundtrip_object_arn = local.support_email_canary_inbound_roundtrip_s3_prefix_clean == "" ? "${local.support_email_canary_inbound_roundtrip_bucket_arn}/*" : "${local.support_email_canary_inbound_roundtrip_bucket_arn}/${local.support_email_canary_inbound_roundtrip_s3_prefix_clean}/*"

  support_email_canary_slack_webhook_parameter_arn = "arn:${data.aws_partition.current.partition}:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/${trimprefix(local.support_email_canary_slack_webhook_parameter_name, "/")}"
  support_email_canary_discord_webhook_parameter_arn = "arn:${data.aws_partition.current.partition}:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/${trimprefix(local.support_email_canary_discord_webhook_parameter_name, "/")}"

  support_email_canary_ses_identity_domain = length(split("@", var.support_email_canary_ses_from_address)) > 1 ? split("@", var.support_email_canary_ses_from_address)[1] : var.support_email_canary_ses_from_address
  support_email_canary_ses_email_identity_arn = "arn:${data.aws_partition.current.partition}:ses:${var.region}:${data.aws_caller_identity.current.account_id}:identity/${var.support_email_canary_ses_from_address}"
  support_email_canary_ses_domain_identity_arn = "arn:${data.aws_partition.current.partition}:ses:${var.region}:${data.aws_caller_identity.current.account_id}:identity/${local.support_email_canary_ses_identity_domain}"

  support_email_canary_image_uri = var.support_email_canary_image_uri != "" ? var.support_email_canary_image_uri : "${aws_ecr_repository.support_email_canary.repository_url}:${var.support_email_canary_image_tag}"

  support_email_canary_environment_base = {
    ENVIRONMENT                       = var.env
    SES_FROM_ADDRESS                  = var.support_email_canary_ses_from_address
    SES_REGION                        = var.region
    INBOUND_ROUNDTRIP_S3_URI          = var.support_email_canary_inbound_roundtrip_s3_uri
    INBOUND_ROUNDTRIP_RECIPIENT_DOMAIN = var.support_email_canary_recipient_domain_default
    SLACK_WEBHOOK_URL                 = local.support_email_canary_slack_webhook_parameter_name
    DISCORD_WEBHOOK_URL               = local.support_email_canary_discord_webhook_parameter_name
  }

  support_email_canary_environment = var.support_email_canary_recipient_local_part_default == "" ? local.support_email_canary_environment_base : merge(
    local.support_email_canary_environment_base,
    { INBOUND_ROUNDTRIP_RECIPIENT_LOCALPART = var.support_email_canary_recipient_local_part_default }
  )
}

resource "aws_ecr_repository" "support_email_canary" {
  name                 = local.support_email_canary_ecr_repository_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = local.support_email_canary_ecr_repository_name
  }
}

resource "aws_cloudwatch_log_group" "support_email_canary" {
  name              = local.support_email_canary_log_group_name
  retention_in_days = 14

  tags = {
    Name = local.support_email_canary_log_group_name
  }
}

resource "aws_iam_role" "support_email_canary" {
  name = "fjcloud-${var.env}-support-email-canary-lambda-role"

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

resource "aws_iam_role_policy" "support_email_canary" {
  name = "fjcloud-${var.env}-support-email-canary-lambda-policy"
  role = aws_iam_role.support_email_canary.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCanaryLogWrites"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = [
          aws_cloudwatch_log_group.support_email_canary.arn,
          "${aws_cloudwatch_log_group.support_email_canary.arn}:*"
        ]
      },
      {
        Sid    = "AllowCanarySesSend"
        Effect = "Allow"
        Action = [
          "ses:SendEmail",
          "ses:SendRawEmail"
        ]
        Resource = [
          local.support_email_canary_ses_email_identity_arn,
          local.support_email_canary_ses_domain_identity_arn
        ]
      },
      {
        Sid      = "AllowCanaryListInboundBucket"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = local.support_email_canary_inbound_roundtrip_bucket_arn
        Condition = {
          StringLike = {
            "s3:prefix" = local.support_email_canary_inbound_roundtrip_list_prefixes
          }
        }
      },
      {
        Sid      = "AllowCanaryReadInboundObjects"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = local.support_email_canary_inbound_roundtrip_object_arn
      },
      {
        Sid    = "AllowCanaryWebhookParameterReads"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = [
          local.support_email_canary_slack_webhook_parameter_arn,
          local.support_email_canary_discord_webhook_parameter_arn
        ]
      }
    ]
  })
}

resource "aws_lambda_function" "support_email_canary" {
  function_name = local.support_email_canary_name
  package_type  = "Image"
  image_uri     = local.support_email_canary_image_uri
  role          = aws_iam_role.support_email_canary.arn
  timeout       = 300
  memory_size   = 512

  environment {
    variables = local.support_email_canary_environment
  }

  depends_on = [aws_cloudwatch_log_group.support_email_canary]
}

resource "aws_cloudwatch_event_rule" "support_email_canary" {
  name                = "fjcloud-${var.env}-support-email-canary-schedule"
  description         = "Runs the support email deliverability canary on a fixed schedule"
  schedule_expression = var.support_email_canary_schedule_expression
}

resource "aws_cloudwatch_event_target" "support_email_canary" {
  rule      = aws_cloudwatch_event_rule.support_email_canary.name
  target_id = "support-email-canary"
  arn       = aws_lambda_function.support_email_canary.arn
}

resource "aws_lambda_permission" "support_email_canary_eventbridge" {
  statement_id  = "AllowEventBridgeInvokeSupportEmailCanary"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.support_email_canary.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.support_email_canary.arn
}
