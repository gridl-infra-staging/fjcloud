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
