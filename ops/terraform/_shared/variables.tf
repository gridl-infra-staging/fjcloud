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
