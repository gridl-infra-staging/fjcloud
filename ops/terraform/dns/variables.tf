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
}

variable "domain" {
  description = "Root domain name managed in Cloudflare"
  type        = string
  default     = "flapjack.foo"
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for the public DNS zone"
  type        = string
}

variable "dns_ttl" {
  description = "TTL, in seconds, for Cloudflare-managed public DNS records"
  type        = number
  default     = 300

  validation {
    condition     = var.dns_ttl >= 60 && var.dns_ttl <= 86400
    error_message = "dns_ttl must be between 60 and 86400 seconds."
  }
}

variable "vpc_id" {
  description = "VPC ID for ALB target group attachment"
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for the internet-facing ALB"
  type        = list(string)
}

variable "sg_alb_id" {
  description = "Security group ID for the ALB"
  type        = string
}

variable "api_instance_id" {
  description = "EC2 instance ID for the API target"
  type        = string
}

variable "ses_feedback_topic_arn" {
  description = "SNS topic ARN used by SES configuration-set event destination"
  type        = string
}
