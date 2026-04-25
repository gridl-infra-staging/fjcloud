# Root configuration — composes all infrastructure modules.
#
# Usage:
#   cd ops/terraform/_shared
#   terraform init -backend-config=...
#   terraform plan -var="env=staging" -var="ami_id=ami-xxx"
#   terraform apply -var="env=staging" -var="ami_id=ami-xxx"

locals {
  dns_public_record_names = {
    apex  = var.domain
    api   = "api.${var.domain}"
    www   = "www.${var.domain}"
    cloud = "cloud.${var.domain}"
  }

  # Staging already had manual Cloudflare Pages records for some public hosts.
  # Discover them in the root module so Terraform can import and update them in
  # place during the cutover instead of failing with duplicate-record errors.
  existing_public_record_ids = {
    for key, lookup in data.cloudflare_dns_records.existing_public :
    key => lookup.result[0].id
    if length(lookup.result) > 0
  }
}

data "cloudflare_dns_records" "existing_public" {
  for_each = local.dns_public_record_names

  zone_id   = var.cloudflare_zone_id
  type      = "CNAME"
  max_items = 1

  name = {
    exact = each.value
  }
}

module "networking" {
  source = "../networking"

  env    = var.env
  region = var.region
}

module "data" {
  source = "../data"

  env                = var.env
  region             = var.region
  private_subnet_ids = module.networking.private_subnet_ids
  sg_rds_id          = module.networking.sg_rds_id
  db_instance_class  = var.db_instance_class
}

module "compute" {
  source = "../compute"

  env                   = var.env
  region                = var.region
  ami_id                = var.ami_id
  api_instance_type     = var.api_instance_type
  private_subnet_ids    = module.networking.private_subnet_ids
  sg_api_id             = module.networking.sg_api_id
  instance_profile_name = "fjcloud-instance-profile"
}

# Runtime-only provisioning inputs are owned by the dedicated runtime_params
# module. deploy.sh regenerates /etc/fjcloud/env on the host exclusively from
# Parameter Store, so these parameters must exist before a runtime deploy.
# Parameter NAMES (/fjcloud/${env}/*) are the external contract and preserved
# identically across the move.
module "runtime_params" {
  source = "../runtime_params"

  env                   = var.env
  ami_id                = var.ami_id
  subnet_id             = element(module.networking.public_subnet_ids, 0)
  security_group_ids    = module.networking.sg_flapjack_vm_id
  key_pair_name         = module.compute.ssh_key_pair_name
  instance_profile_name = "fjcloud-instance-profile"
  cloudflare_zone_id    = var.cloudflare_zone_id
  dns_domain            = var.domain
}

module "dns" {
  source = "../dns"

  env                = var.env
  region             = var.region
  domain             = var.domain
  cloudflare_zone_id = var.cloudflare_zone_id
  vpc_id             = module.networking.vpc_id
  public_subnet_ids  = module.networking.public_subnet_ids
  sg_alb_id          = module.networking.sg_alb_id
  api_instance_id    = module.compute.api_instance_id
}

module "monitoring" {
  source = "../monitoring"

  env                                       = var.env
  region                                    = var.region
  api_instance_id                           = module.compute.api_instance_id
  db_instance_identifier                    = module.data.db_instance_identifier
  alb_arn_suffix                            = module.dns.alb_arn_suffix
  alert_emails                              = var.alert_emails
  live_e2e_monthly_spend_limit_usd          = var.live_e2e_monthly_spend_limit_usd
  live_e2e_budget_action_enabled            = var.live_e2e_budget_action_enabled
  live_e2e_budget_action_principal_arn      = var.live_e2e_budget_action_principal_arn
  live_e2e_budget_action_policy_arn         = var.live_e2e_budget_action_policy_arn
  live_e2e_budget_action_role_name          = var.live_e2e_budget_action_role_name
  live_e2e_budget_action_execution_role_arn = var.live_e2e_budget_action_execution_role_arn
}

import {
  for_each = local.existing_public_record_ids
  to       = module.dns.cloudflare_dns_record.public[each.key]
  id       = "${var.cloudflare_zone_id}/${each.value}"
}

# Safe state migration for 2026-04-24 move of runtime SSM parameters into
# the dedicated runtime_params module. Prevents destroy+create of live
# SSM parameters that deploy.sh reads from Parameter Store at host boot.
moved {
  from = aws_ssm_parameter.runtime_aws_ami_id
  to   = module.runtime_params.aws_ssm_parameter.runtime_aws_ami_id
}

moved {
  from = aws_ssm_parameter.runtime_aws_subnet_id
  to   = module.runtime_params.aws_ssm_parameter.runtime_aws_subnet_id
}

moved {
  from = aws_ssm_parameter.runtime_aws_security_group_ids
  to   = module.runtime_params.aws_ssm_parameter.runtime_aws_security_group_ids
}

moved {
  from = aws_ssm_parameter.runtime_aws_key_pair_name
  to   = module.runtime_params.aws_ssm_parameter.runtime_aws_key_pair_name
}

moved {
  from = aws_ssm_parameter.runtime_aws_instance_profile_name
  to   = module.runtime_params.aws_ssm_parameter.runtime_aws_instance_profile_name
}

moved {
  from = aws_ssm_parameter.runtime_cloudflare_zone_id
  to   = module.runtime_params.aws_ssm_parameter.runtime_cloudflare_zone_id
}

moved {
  from = aws_ssm_parameter.runtime_dns_domain
  to   = module.runtime_params.aws_ssm_parameter.runtime_dns_domain
}
