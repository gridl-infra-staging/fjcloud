data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  deployment_domain     = var.env == "staging" && var.domain == "flapjack.foo" ? "staging.flapjack.foo" : var.domain
  api_domain            = "api.${local.deployment_domain}"
  www_domain            = "www.${local.deployment_domain}"
  cloud_domain          = "cloud.${local.deployment_domain}"
  default_event_bus_arn = "arn:${data.aws_partition.current.partition}:events:${var.region}:${data.aws_caller_identity.current.account_id}:event-bus/default"

  # Canonical CloudWatch Logs group name for SES SEND/DELIVERY events routed via
  # the feedback configuration set. The staging billing rehearsal evidence
  # script consumes this owner as the queryable channel for invoice-id message
  # tags, replacing the CloudTrail lookup-events path which does not observe
  # SES v2 SendEmail data events.
  ses_send_events_log_group_name = "/fjcloud/${var.env}/ses/send-events"
  ses_send_events_rule_name      = "fjcloud-${var.env}-ses-send-events"
  # Staging keeps a distinct Pages hostname; prod uses the canonical host.
  cloud_pages_hostname = var.env == "staging" ? "staging.flapjack-cloud.pages.dev" : "flapjack-cloud.pages.dev"

  # Cloudflare does CNAME flattening at the zone apex, which is the closest
  # equivalent to the prior Route53 ALIAS record for the public ALB.
  public_dns_records = {
    apex = {
      name    = local.deployment_domain
      type    = "CNAME"
      content = aws_lb.api.dns_name
      ttl     = var.dns_ttl
      proxied = false
    }
    api = {
      name    = local.api_domain
      type    = "CNAME"
      content = aws_lb.api.dns_name
      ttl     = var.dns_ttl
      proxied = false
    }
    www = {
      name    = local.www_domain
      type    = "CNAME"
      content = aws_lb.api.dns_name
      ttl     = var.dns_ttl
      proxied = false
    }
    cloud = {
      name = local.cloud_domain
      type = "CNAME"
      # The canonical cloud hostname still uses the existing Pages-backed web
      # deploy while runtime/API traffic stays on the ALB-backed hosts.
      content = local.cloud_pages_hostname
      ttl     = 1
      proxied = true
    }
  }

  # ACM returns the same DNS validation CNAME for the apex and wildcard names in
  # this certificate shape. Keep the Cloudflare owner keyed by configuration, not
  # by ACM's apply-time record name, so plans can replace certificates safely.
  acm_validation_record_keys = toset([local.deployment_domain])

  acm_validation_record_groups = {
    (local.deployment_domain) = [
      for dvo in aws_acm_certificate.main.domain_validation_options : {
        record_name  = trimsuffix(dvo.resource_record_name, ".")
        record_type  = dvo.resource_record_type
        record_value = trimsuffix(dvo.resource_record_value, ".")
      }
      if dvo.domain_name == local.deployment_domain
    ]
  }

  acm_validation_records = {
    for key in local.acm_validation_record_keys : key => {
      record_name  = one(local.acm_validation_record_groups[key]).record_name
      record_type  = one(local.acm_validation_record_groups[key]).record_type
      record_value = one(local.acm_validation_record_groups[key]).record_value
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

  # Keep the configuration-set name deterministic from the existing
  # environment/domain contract so runtime publication can consume one SSOT.
  ses_configuration_set_name = "fjcloud-${var.env}-${replace(local.deployment_domain, ".", "-")}-feedback"
}

resource "aws_acm_certificate" "main" {
  domain_name               = local.deployment_domain
  subject_alternative_names = ["*.${local.deployment_domain}"]
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
  for_each = local.acm_validation_record_keys

  zone_id = var.cloudflare_zone_id
  name    = local.acm_validation_records[each.key].record_name
  type    = local.acm_validation_records[each.key].record_type
  content = local.acm_validation_records[each.key].record_value
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
  email_identity = local.deployment_domain

  tags = {
    Name = "fjcloud-${var.env}-ses-domain"
    Env  = var.env
  }
}

resource "aws_sesv2_configuration_set" "feedback" {
  configuration_set_name = local.ses_configuration_set_name
}

resource "aws_sesv2_configuration_set_event_destination" "feedback_sns" {
  configuration_set_name = aws_sesv2_configuration_set.feedback.configuration_set_name
  event_destination_name = "sns-feedback"

  event_destination {
    enabled              = true
    matching_event_types = ["BOUNCE", "COMPLAINT"]

    sns_destination {
      topic_arn = var.ses_feedback_topic_arn
    }
  }
}

# SES v2 does not deliver events directly to CloudWatch Logs; the supported
# destination types are cloud_watch (metrics only), event_bridge, kinesis_firehose,
# pinpoint, and sns. We route SEND (and DELIVERY, for completeness) through the
# default EventBridge bus and land the raw event payload — which carries the
# `invoice_id` message tag we already attach in SesEmailService — in a
# dedicated CloudWatch Logs group. The staging billing rehearsal evidence
# script queries this group by message tag to prove SES actually processed
# each rehearsal invoice email, without depending on CloudTrail lookup-events.
resource "aws_sesv2_configuration_set_event_destination" "feedback_eventbridge_send" {
  configuration_set_name = aws_sesv2_configuration_set.feedback.configuration_set_name
  event_destination_name = "eventbridge-send"

  event_destination {
    enabled              = true
    matching_event_types = ["SEND", "DELIVERY"]

    event_bridge_destination {
      event_bus_arn = local.default_event_bus_arn
    }
  }
}

resource "aws_cloudwatch_log_group" "ses_send_events" {
  name              = local.ses_send_events_log_group_name
  retention_in_days = 14

  tags = {
    Name = "fjcloud-${var.env}-ses-send-events"
    Env  = var.env
  }
}

resource "aws_cloudwatch_event_rule" "ses_send_events" {
  name        = local.ses_send_events_rule_name
  description = "Route SES SEND and DELIVERY events (with invoice_id message tag) to CloudWatch Logs for rehearsal evidence"

  event_pattern = jsonencode({
    source      = ["aws.ses"]
    detail-type = ["Email Sent", "Email Delivered"]
  })
}

resource "aws_cloudwatch_event_target" "ses_send_events_logs" {
  rule = aws_cloudwatch_event_rule.ses_send_events.name
  arn  = aws_cloudwatch_log_group.ses_send_events.arn
}

resource "aws_cloudwatch_log_resource_policy" "eventbridge_ses_send_events" {
  policy_name = "fjcloud-${var.env}-eventbridge-ses-send-events"

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEventBridgeToWriteSESSendEvents"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.ses_send_events.arn}:*"
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_cloudwatch_event_rule.ses_send_events.arn
          }
        }
      }
    ]
  })
}

resource "cloudflare_dns_record" "ses_dkim" {
  count = 3

  zone_id = var.cloudflare_zone_id
  name    = "${aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens[count.index]}._domainkey.${local.deployment_domain}"
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
  # Staging target attachment drifts are reconciled by the runtime deploy path;
  # keep Terraform ownership focused on prod where drift must be declarative.
  for_each = var.env == "prod" ? toset(["prod"]) : toset([])

  target_group_arn = aws_lb_target_group.api.arn
  target_id        = var.api_instance_id
  port             = 3001
}

# Preserve state continuity after moving the prod-only attachment from a
# singleton address to a keyed for_each address.
moved {
  from = aws_lb_target_group_attachment.api
  to   = aws_lb_target_group_attachment.api["prod"]
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
  proxied = each.value.proxied
  comment = "fjcloud ${var.env} public route"
}
