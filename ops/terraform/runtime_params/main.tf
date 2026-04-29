# Runtime provisioning inputs in SSM Parameter Store.
#
# deploy.sh regenerates /etc/fjcloud/env on the host exclusively from Parameter
# Store, so these parameters must exist before a runtime deploy can succeed.
#
# Parameter NAMES are the external contract and must not change. Terraform
# logical paths (aws_ssm_parameter.runtime_*) are internal and may be reshaped
# freely.

resource "aws_ssm_parameter" "runtime_aws_ami_id" {
  name  = "/fjcloud/${var.env}/aws_ami_id"
  type  = "String"
  value = var.ami_id
}

resource "aws_ssm_parameter" "runtime_aws_subnet_id" {
  name  = "/fjcloud/${var.env}/aws_subnet_id"
  type  = "String"
  value = var.subnet_id
}

resource "aws_ssm_parameter" "runtime_aws_security_group_ids" {
  name  = "/fjcloud/${var.env}/aws_security_group_ids"
  type  = "String"
  value = var.security_group_ids
}

resource "aws_ssm_parameter" "runtime_aws_key_pair_name" {
  name  = "/fjcloud/${var.env}/aws_key_pair_name"
  type  = "String"
  value = var.key_pair_name
}

resource "aws_ssm_parameter" "runtime_aws_instance_profile_name" {
  name  = "/fjcloud/${var.env}/aws_instance_profile_name"
  type  = "String"
  value = var.instance_profile_name
}

resource "aws_ssm_parameter" "runtime_cloudflare_zone_id" {
  name  = "/fjcloud/${var.env}/cloudflare_zone_id"
  type  = "String"
  value = var.cloudflare_zone_id
}

resource "aws_ssm_parameter" "runtime_dns_domain" {
  name  = "/fjcloud/${var.env}/dns_domain"
  type  = "String"
  value = var.dns_domain
}

resource "aws_ssm_parameter" "runtime_ses_configuration_set" {
  name  = "/fjcloud/${var.env}/ses_configuration_set"
  type  = "String"
  value = var.ses_configuration_set_name
}
