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

variable "ami_id" {
  description = "AMI ID for the API server (stock Amazon Linux 2023 ARM64 for MVP)"
  type        = string
}

variable "api_instance_type" {
  description = "EC2 instance type for the API server"
  type        = string
  default     = "t4g.small"
}

variable "private_subnet_ids" {
  description = "Private subnet IDs (instance uses element 0)"
  type        = list(string)
}

variable "sg_api_id" {
  description = "Security group ID for the API server"
  type        = string
}

variable "instance_profile_name" {
  description = "IAM instance profile name for the API server"
  type        = string
}
