terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# Default provider — pinned to var.region. Used by all RDS / EC2 / ALB
# alarms whose target resources live in the application region.
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      managed-by = "terraform"
      service    = "fjcloud"
      env        = var.env
    }
  }
}

# us-east-1 alias used ONLY for AWS/Billing metrics.
#
# AWS publishes the EstimatedCharges metric exclusively in us-east-1
# regardless of which region(s) the account's resources actually live in.
# A CloudWatch alarm on AWS/Billing in any other region will silently
# never receive data points and therefore will never fire.
#
# Future agent: do NOT delete this alias or move the billing alarm back
# to the default provider, even when consolidating providers feels
# cleaner. The alarm in main.tf depends on `provider = aws.us_east_1`.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      managed-by = "terraform"
      service    = "fjcloud"
      env        = var.env
    }
  }
}
