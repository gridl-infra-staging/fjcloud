variable "env" {
  description = "Deployment environment"
  type        = string

  validation {
    condition     = contains(["staging", "prod"], var.env)
    error_message = "env must be 'staging' or 'prod'."
  }
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "domain" {
  description = "Root domain (e.g. flapjack.foo)"
  type        = string
  default     = "flapjack.foo"
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for the public DNS zone"
  type        = string
}

variable "ami_id" {
  description = "Packer-built AMI ID for flapjack VMs"
  type        = string
}

variable "db_instance_class" {
  description = "RDS instance class (e.g. db.t4g.small for staging, db.t4g.medium for prod)"
  type        = string
  default     = "db.t4g.small"
}

variable "api_instance_type" {
  description = "EC2 instance type for the API server (e.g. t4g.small for staging, t4g.medium for prod)"
  type        = string
  default     = "t4g.small"
}

variable "alert_emails" {
  description = "Email addresses to subscribe to operational monitoring alerts"
  type        = list(string)
  default     = []
}

variable "canary_image" {
  description = "Canonical canary image publication input forwarded to the monitoring module"
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
  description = "Canonical canary schedule input forwarded to the monitoring module"
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

variable "live_e2e_monthly_spend_limit_usd" {
  description = "Optional monthly spend ceiling in USD for live E2E budget enforcement"
  type        = number
  default     = null

  validation {
    condition     = var.live_e2e_monthly_spend_limit_usd == null || var.live_e2e_monthly_spend_limit_usd > 0
    error_message = "live_e2e_monthly_spend_limit_usd must be null or greater than 0."
  }
}

variable "live_e2e_budget_action_enabled" {
  description = "Enable AWS Budgets action enforcement for live E2E resources"
  type        = bool
  default     = false
}

variable "live_e2e_budget_action_principal_arn" {
  description = "IAM principal ARN used for AWS Budgets action ownership"
  type        = string
  default     = ""
}

variable "live_e2e_budget_action_policy_arn" {
  description = "IAM policy ARN applied by AWS Budgets action enforcement"
  type        = string
  default     = ""
}

variable "live_e2e_budget_action_role_name" {
  description = "IAM role name targeted by AWS Budgets action enforcement"
  type        = string
  default     = ""
}

variable "live_e2e_budget_action_execution_role_arn" {
  description = "IAM role ARN assumed by AWS Budgets to execute enforcement actions"
  type        = string
  default     = ""
}

variable "support_email_canary_image_uri" {
  description = "Optional explicit image URI (or digest URI) for the support-email canary Lambda."
  type        = string
  default     = ""
}

variable "support_email_canary_image_tag" {
  description = "Tag used with monitoring-owned ECR repository when support_email_canary_image_uri is not explicitly set."
  type        = string
  default     = "latest"
}

variable "support_email_canary_ses_from_address" {
  description = "SES sender identity for support-email canary runtime."
  type        = string
  default     = "system@flapjack.foo"
}

variable "support_email_canary_schedule_expression" {
  description = "EventBridge schedule expression for support-email canary runs."
  type        = string
  default     = "rate(6 hours)"
}

variable "support_email_canary_inbound_roundtrip_s3_uri" {
  description = "S3 URI passed to INBOUND_ROUNDTRIP_S3_URI for support-email canary runtime."
  type        = string
  default     = "s3://flapjack-cloud-releases/e2e-emails/"
}

variable "support_email_canary_recipient_domain_default" {
  description = "Default INBOUND_ROUNDTRIP_RECIPIENT_DOMAIN for support-email canary runtime."
  type        = string
  default     = "test.flapjack.foo"
}

variable "support_email_canary_recipient_local_part_default" {
  description = "Optional fixed INBOUND_ROUNDTRIP_RECIPIENT_LOCALPART for support-email canary runtime."
  type        = string
  default     = ""
}

variable "support_email_canary_slack_webhook_parameter_name" {
  description = "Optional explicit SSM parameter name for Slack webhook URL. Empty defaults to /fjcloud/<env>/slack_webhook_url."
  type        = string
  default     = ""
}

variable "support_email_canary_discord_webhook_parameter_name" {
  description = "Optional explicit SSM parameter name for Discord webhook URL. Empty defaults to /fjcloud/<env>/discord_webhook_url."
  type        = string
  default     = ""
}
