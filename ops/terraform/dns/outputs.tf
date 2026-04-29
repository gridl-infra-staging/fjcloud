output "alb_dns_name" {
  description = "DNS name of the application load balancer"
  value       = aws_lb.api.dns_name
}

output "alb_arn" {
  description = "ARN of the application load balancer"
  value       = aws_lb.api.arn
}

output "alb_arn_suffix" {
  description = "ARN suffix of the ALB (for CloudWatch metrics)"
  value       = aws_lb.api.arn_suffix
}

output "acm_certificate_arn" {
  description = "ARN of the ACM certificate used by the HTTPS listener"
  value       = aws_acm_certificate.main.arn
}

output "cloudflare_zone_id" {
  description = "Cloudflare zone ID used for public DNS records"
  value       = var.cloudflare_zone_id
}

output "ses_configuration_set_name" {
  description = "Canonical SES configuration-set name for bounce/complaint events"
  value       = aws_sesv2_configuration_set.feedback.configuration_set_name
}
