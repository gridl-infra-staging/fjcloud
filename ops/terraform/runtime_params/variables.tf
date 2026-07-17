variable "env" {
  description = "Deployment environment (staging or prod)"
  type        = string

  validation {
    condition     = contains(["staging", "prod"], var.env)
    error_message = "env must be 'staging' or 'prod'."
  }
}

variable "ami_id" {
  description = "Packer-built AMI ID for flapjack VMs"
  type        = string
}

variable "subnet_id" {
  description = "Public subnet ID used as the default runtime subnet"
  type        = string
}

variable "security_group_ids" {
  description = "Security group ID (single, comma-joined if multi) applied to flapjack VMs at runtime"
  type        = string
}

variable "key_pair_name" {
  description = "EC2 key pair name used for runtime-provisioned flapjack VMs"
  type        = string
}

variable "instance_profile_name" {
  description = "IAM instance profile name applied to runtime-provisioned flapjack VMs"
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for the public DNS zone"
  type        = string
}

variable "dns_domain" {
  description = "Root DNS domain (e.g. flapjack.foo)"
  type        = string
}

variable "ses_configuration_set_name" {
  description = "SES configuration set name consumed by application runtime"
  type        = string
}
