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
  description = "Enable AWS Budgets action enforcement for live E2E resources. Defaults to disabled until operators provide canonical action inputs."
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
