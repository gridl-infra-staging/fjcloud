variable "env" {
  description = "Deployment environment (staging or prod)"
  type        = string

  validation {
    condition     = contains(["staging", "prod"], var.env)
    error_message = "env must be 'staging' or 'prod'."
  }
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "domain" {
  description = "Root domain used to construct API webhook endpoints"
  type        = string
}

variable "api_instance_id" {
  description = "API EC2 instance ID"
  type        = string
}

variable "db_instance_identifier" {
  description = "RDS DB instance identifier"
  type        = string
}

variable "alb_arn_suffix" {
  description = "Application Load Balancer arn_suffix for CloudWatch dimensions"
  type        = string
}

variable "alert_emails" {
  description = "Email addresses to subscribe to monitoring alerts"
  type        = list(string)
  default     = []
}

variable "canary_image" {
  description = "Canonical canary image publication input. The deploy workflow publishes this tag to the monitoring-owned ECR repository."
  type = object({
    tag = string
  })
  default = {
    tag = "pending-publication"
  }

  validation {
    condition     = trimspace(var.canary_image.tag) != ""
    error_message = "canary_image.tag must be non-empty."
  }
}

variable "canary_schedule" {
  description = "Canonical canary schedule input. Keep disabled until operators explicitly activate runtime execution."
  type = object({
    expression = string
    enabled    = bool
  })
  default = {
    expression = "rate(15 minutes)"
    enabled    = false
  }

  validation {
    condition     = can(regex("^(rate|cron)\\(", trimspace(var.canary_schedule.expression)))
    error_message = "canary_schedule.expression must start with rate( or cron(."
  }
}

variable "canary_live_mode" {
  description = "Enables Stripe-mutating live-money flow in the customer-loop canary runtime."
  type        = bool
  default     = false
}

variable "cloudtrail_name_override" {
  description = "Optional explicit CloudTrail trail name; defaults to fjcloud-<env>-guardrails when empty"
  type        = string
  default     = ""
}

variable "cloudtrail_retention_days" {
  description = "Retention window in days for CloudTrail export objects in S3"
  type        = number
  default     = 365

  validation {
    condition     = var.cloudtrail_retention_days >= 30
    error_message = "cloudtrail_retention_days must be at least 30."
  }
}

variable "cloudtrail_export_bucket_name" {
  description = "Optional explicit S3 bucket name for CloudTrail exports; defaults to fjcloud-<env>-cloudtrail-export when empty"
  type        = string
  default     = ""
}

variable "live_e2e_monthly_spend_limit_usd" {
  description = "Optional monthly spend ceiling in USD for live E2E budget enforcement. Leave null until operators provide the canonical value."
  type        = number
  default     = null

  validation {
    condition     = var.live_e2e_monthly_spend_limit_usd == null || var.live_e2e_monthly_spend_limit_usd > 0
    error_message = "live_e2e_monthly_spend_limit_usd must be null or greater than 0."
  }
}

variable "live_e2e_budget_action_enabled" {
  description = "Enable AWS Budgets Actions auto-enforcement for live E2E resources. Defaults to disabled. For pre-launch fjcloud staging this is intentionally left disabled per the 2026-04-23 operator decision: alert-only notifications (see ops/scripts and docs/runbooks/staging-evidence.md) give the same signal without the risk of an auto-attached IAM policy locking staging out on breach. Enable only with a bounded-blast-radius role + policy pairing."
  type        = bool
  default     = false
}

variable "live_e2e_budget_action_principal_arn" {
  description = "IAM principal ARN that receives AWS Budgets action notifications/approvals. Leave empty until operators provide canonical ownership."
  type        = string
  default     = ""

  validation {
    condition     = var.live_e2e_budget_action_principal_arn == "" || can(regex("^arn:", var.live_e2e_budget_action_principal_arn))
    error_message = "live_e2e_budget_action_principal_arn must be empty or an ARN."
  }
}

variable "live_e2e_budget_action_policy_arn" {
  description = "IAM policy ARN applied by AWS Budgets action enforcement. Leave empty until operators provide canonical policy ownership."
  type        = string
  default     = ""

  validation {
    condition     = var.live_e2e_budget_action_policy_arn == "" || can(regex("^arn:", var.live_e2e_budget_action_policy_arn))
    error_message = "live_e2e_budget_action_policy_arn must be empty or an ARN."
  }
}

variable "live_e2e_budget_action_role_name" {
  description = "IAM role name targeted by AWS Budgets action enforcement. Leave empty until operators provide canonical role ownership."
  type        = string
  default     = ""

  validation {
    condition     = var.live_e2e_budget_action_role_name == "" || can(regex("^[A-Za-z0-9+=,.@_-]{1,64}$", var.live_e2e_budget_action_role_name))
    error_message = "live_e2e_budget_action_role_name must be empty or a valid IAM role name (1-64 chars, [A-Za-z0-9+=,.@_-])."
  }
}

variable "live_e2e_budget_action_execution_role_arn" {
  description = "IAM role ARN assumed by AWS Budgets to execute enforcement actions. Leave empty until operators provide canonical ownership."
  type        = string
  default     = ""

  validation {
    condition     = var.live_e2e_budget_action_execution_role_arn == "" || can(regex("^arn:", var.live_e2e_budget_action_execution_role_arn))
    error_message = "live_e2e_budget_action_execution_role_arn must be empty or an ARN."
  }
}

# T0.4 — CloudWatch billing alarm threshold.
#
# CRITICAL: AWS/Billing EstimatedCharges is the CUMULATIVE MONTHLY total —
# not a daily delta. The metric counts up across the calendar month and
# resets on the 1st. So a threshold like 50 USD will trip on day 2 of every
# month (cumulative > 50) and stay tripped until the next monthly reset —
# permanent false-positive paging.
#
# Correct semantics for THIS alarm (cumulative-monthly metric):
#   - Set threshold ABOVE the expected monthly spend ceiling.
#   - The alarm fires when we EXCEED the monthly budget, with ~6h latency
#     vs AWS Budgets's monthly-email cadence.
#   - It does NOT catch a sub-budget runaway spike (e.g. $200 spent in 1h
#     when budget is $600/mo). That requires a metric-math expression on
#     the rate-of-change; out of scope for Tier 0. T2.X may add it.
#
# Default 700 USD: slightly above the current 600 USD/mo Stuart budget,
# so the alarm fires when something has overspent the monthly cap rather
# than during normal accumulation. Adjust per-environment via tfvars.
variable "billing_alarm_threshold_usd" {
  description = "USD threshold for the AWS billing alarm (compared to AWS/Billing EstimatedCharges, which is CUMULATIVE for the current calendar month — set ABOVE expected monthly spend, not as a per-day rate)."
  type        = number
  default     = 700

  validation {
    condition     = var.billing_alarm_threshold_usd > 0
    error_message = "billing_alarm_threshold_usd must be greater than 0."
  }
}

variable "support_email_canary_image_uri" {
  description = "Optional explicit image URI (or digest URI) for the support-email canary Lambda. When empty, monitoring composes URI from its ECR repository URL plus support_email_canary_image_tag."
  type        = string
  default     = ""
}

variable "support_email_canary_image_tag" {
  description = "Tag used with monitoring-owned ECR repository when support_email_canary_image_uri is not explicitly set."
  type        = string
  default     = "latest"
}

variable "support_email_canary_ses_from_address" {
  description = "SES sender identity used by support-email canary runtime as SES_FROM_ADDRESS."
  type        = string
  default     = "system@flapjack.foo"

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+$", var.support_email_canary_ses_from_address))
    error_message = "support_email_canary_ses_from_address must be an email address."
  }
}

variable "support_email_canary_schedule_expression" {
  description = "EventBridge schedule expression for support-email canary runs."
  type        = string
  default     = "rate(6 hours)"

  validation {
    condition     = can(regex("^(rate|cron)\\(.*\\)$", var.support_email_canary_schedule_expression))
    error_message = "support_email_canary_schedule_expression must be a valid EventBridge rate(...) or cron(...) expression."
  }
}

variable "support_email_canary_inbound_roundtrip_s3_uri" {
  description = "S3 URI passed to INBOUND_ROUNDTRIP_S3_URI for support-email canary runtime."
  type        = string
  default     = "s3://flapjack-cloud-releases/e2e-emails/"

  validation {
    condition     = can(regex("^s3://[^/]+(/.*)?$", var.support_email_canary_inbound_roundtrip_s3_uri))
    error_message = "support_email_canary_inbound_roundtrip_s3_uri must be an s3:// URI."
  }
}

variable "support_email_canary_recipient_domain_default" {
  description = "Default INBOUND_ROUNDTRIP_RECIPIENT_DOMAIN for support-email canary runtime."
  type        = string
  default     = "test.flapjack.foo"
}

variable "support_email_canary_recipient_local_part_default" {
  description = "Optional fixed INBOUND_ROUNDTRIP_RECIPIENT_LOCALPART for support-email canary runtime. Leave empty to use script-generated nonce local parts."
  type        = string
  default     = ""
}

variable "support_email_canary_slack_webhook_parameter_name" {
  description = "Optional explicit SSM parameter name for Slack webhook URL. Empty defaults to /fjcloud/<env>/slack_webhook_url."
  type        = string
  default     = ""

  validation {
    condition     = var.support_email_canary_slack_webhook_parameter_name == "" || can(regex("^/", var.support_email_canary_slack_webhook_parameter_name))
    error_message = "support_email_canary_slack_webhook_parameter_name must start with '/' when set."
  }
}

variable "support_email_canary_discord_webhook_parameter_name" {
  description = "Optional explicit SSM parameter name for Discord webhook URL. Empty defaults to /fjcloud/<env>/discord_webhook_url."
  type        = string
  default     = ""

  validation {
    condition     = var.support_email_canary_discord_webhook_parameter_name == "" || can(regex("^/", var.support_email_canary_discord_webhook_parameter_name))
    error_message = "support_email_canary_discord_webhook_parameter_name must start with '/' when set."
  }
}
