locals {
  api_domain   = "api.${var.domain}"
  www_domain   = "www.${var.domain}"
  cloud_domain = "cloud.${var.domain}"

  # Cloudflare does CNAME flattening at the zone apex, which is the closest
  # equivalent to the prior Route53 ALIAS record for the public ALB.
  public_dns_records = {
    apex = {
      name    = var.domain
      type    = "CNAME"
      content = aws_lb.api.dns_name
      ttl     = var.dns_ttl
    }
    api = {
      name    = local.api_domain
      type    = "CNAME"
      content = aws_lb.api.dns_name
      ttl     = var.dns_ttl
    }
    www = {
      name    = local.www_domain
      type    = "CNAME"
      content = aws_lb.api.dns_name
      ttl     = var.dns_ttl
    }
    cloud = {
      name    = local.cloud_domain
      type    = "CNAME"
      content = aws_lb.api.dns_name
      ttl     = var.dns_ttl
    }
  }

  # ACM can return the same DNS validation CNAME for the apex and wildcard
  # names. Key by the normalized record name so Terraform manages one record in
  # Cloudflare instead of attempting a duplicate create.
  acm_validation_record_groups = {
    for dvo in aws_acm_certificate.main.domain_validation_options :
    trimsuffix(dvo.resource_record_name, ".") => {
      domain_name  = dvo.domain_name
      record_name  = trimsuffix(dvo.resource_record_name, ".")
      record_type  = dvo.resource_record_type
      record_value = trimsuffix(dvo.resource_record_value, ".")
    }...
  }

  acm_validation_records = {
    for _, records in local.acm_validation_record_groups :
    (
      contains([for record in records : record.domain_name], var.domain)
      ? var.domain
      : replace(records[0].domain_name, "*.", "wildcard.")
      ) => {
      record_name  = records[0].record_name
      record_type  = records[0].record_type
      record_value = records[0].record_value
    }
  }

  # AWS SES uses region-specific Easy DKIM hosted zones for a small set of
  # regions. Keep the default domain for all other regions so the module stays
  # correct when var.region changes instead of assuming us-east-1 forever.
  # Source: AWS General Reference "Amazon SES endpoints and quotas".
  ses_region_specific_dkim_domains = {
    "af-south-1"     = "dkim.af-south-1.amazonses.com"
    "ap-south-2"     = "dkim.ap-south-2.amazonses.com"
    "ap-southeast-3" = "dkim.ap-southeast-3.amazonses.com"
    "ap-southeast-5" = "dkim.ap-southeast-5.amazonses.com"
    "ca-west-1"      = "dkim.ca-west-1.amazonses.com"
    "ap-northeast-3" = "dkim.ap-northeast-3.amazonses.com"
    "eu-south-1"     = "dkim.eu-south-1.amazonses.com"
    "eu-central-2"   = "dkim.eu-central-2.amazonses.com"
    "il-central-1"   = "dkim.il-central-1.amazonses.com"
    "me-central-1"   = "dkim.me-central-1.amazonses.com"
    "us-gov-east-1"  = "dkim.us-gov-east-1.amazonses.com"
  }

  ses_dkim_hosted_zone = lookup(
    local.ses_region_specific_dkim_domains,
    var.region,
    "dkim.amazonses.com",
  )
}

resource "aws_acm_certificate" "main" {
  domain_name               = var.domain
  subject_alternative_names = ["*.${var.domain}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "fjcloud-${var.env}-certificate"
    Env  = var.env
  }
}

removed {
  from = aws_route53_zone.primary

  lifecycle {
    destroy = false
  }
}

resource "cloudflare_dns_record" "cert_validation" {
  for_each = local.acm_validation_records

  zone_id = var.cloudflare_zone_id
  name    = each.value.record_name
  type    = each.value.record_type
  content = each.value.record_value
  ttl     = 60
  proxied = false
  comment = "fjcloud ${var.env} ACM validation"
}

resource "aws_acm_certificate_validation" "main" {
  certificate_arn = aws_acm_certificate.main.arn

  validation_record_fqdns = [
    for record in cloudflare_dns_record.cert_validation : record.name
  ]
}

resource "aws_sesv2_email_identity" "domain" {
  email_identity = var.domain

  tags = {
    Name = "fjcloud-${var.env}-ses-domain"
    Env  = var.env
  }
}

resource "cloudflare_dns_record" "ses_dkim" {
  count = 3

  zone_id = var.cloudflare_zone_id
  name    = "${aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens[count.index]}._domainkey.${var.domain}"
  type    = "CNAME"
  content = "${aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens[count.index]}.${local.ses_dkim_hosted_zone}"
  ttl     = var.dns_ttl
  proxied = false
  comment = "fjcloud ${var.env} SES DKIM validation"
}

resource "aws_lb" "api" {
  name                       = "fjcloud-${var.env}-alb"
  internal                   = false
  load_balancer_type         = "application"
  subnets                    = var.public_subnet_ids
  security_groups            = [var.sg_alb_id]
  enable_deletion_protection = false

  tags = {
    Name = "fjcloud-${var.env}-alb"
    Env  = var.env
  }
}

resource "aws_lb_target_group" "api" {
  name                 = "fjcloud-${var.env}-api-tg"
  port                 = 3001
  protocol             = "HTTP"
  vpc_id               = var.vpc_id
  target_type          = "instance"
  deregistration_delay = 30

  health_check {
    path     = "/health"
    matcher  = "200"
    protocol = "HTTP"
  }

  tags = {
    Name = "fjcloud-${var.env}-api-tg"
    Env  = var.env
  }
}

resource "aws_lb_target_group_attachment" "api" {
  target_group_arn = aws_lb_target_group.api.arn
  target_id        = var.api_instance_id
  port             = 3001
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.api.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.main.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.api.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "cloudflare_dns_record" "public" {
  for_each = local.public_dns_records

  zone_id = var.cloudflare_zone_id
  name    = each.value.name
  type    = each.value.type
  content = each.value.content
  ttl     = each.value.ttl
  proxied = false
  comment = "fjcloud ${var.env} public ALB route"
}
