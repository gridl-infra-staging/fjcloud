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
