# Root-level outputs aggregated from child modules.
# These are consumed by deploy scripts and other automation.

output "vpc_id" {
  description = "VPC ID"
  value       = module.networking.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (for ALB)"
  value       = module.networking.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs (for RDS and internal EC2)"
  value       = module.networking.private_subnet_ids
}

output "db_endpoint" {
  description = "RDS PostgreSQL endpoint"
  value       = module.data.db_endpoint
}

output "api_instance_ip" {
  description = "API EC2 instance private IP"
  value       = module.compute.api_private_ip
}

output "alb_dns_name" {
  description = "ALB DNS name"
  value       = module.dns.alb_dns_name
}

output "acm_certificate_arn" {
  description = "ACM certificate ARN used by the ALB HTTPS listener"
  value       = module.dns.acm_certificate_arn
}

output "cloudflare_zone_id" {
  description = "Cloudflare zone ID used by the public DNS module"
  value       = module.dns.cloudflare_zone_id
}
