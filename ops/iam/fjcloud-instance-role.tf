# IAM role and instance profile for fjcloud VM instances.
#
# Grants the staging API enough access to bootstrap per-node secrets and
# manage customer EC2 instances that fetch those secrets at boot.
#
# Usage:
#   cd ops/iam
#   terraform init
#   terraform plan
#   terraform apply
#
# After applying, set the instance profile name in the API server config:
#   export AWS_INSTANCE_PROFILE_NAME="fjcloud-instance-profile"

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# --------------------------------------------------------------------------
# IAM Role — assumed by EC2 instances
# --------------------------------------------------------------------------

resource "aws_iam_role" "fjcloud_instance" {
  name = "fjcloud-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = {
    managed-by = "terraform"
    service    = "fjcloud"
  }
}

# --------------------------------------------------------------------------
# Policy — SSM read/write for /fjcloud/* parameters
# --------------------------------------------------------------------------

resource "aws_iam_role_policy" "fjcloud_ssm_read" {
  name = "fjcloud-ssm-read"
  role = aws_iam_role.fjcloud_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action = [
        "ssm:GetParameter",
        "ssm:GetParametersByPath",
        "ssm:PutParameter",
        "ssm:DeleteParameter",
      ]
      Resource = "arn:aws:ssm:*:*:parameter/fjcloud/*"
    }]
  })
}

# --------------------------------------------------------------------------
# Policy — EC2 lifecycle control for customer-managed VMs
# --------------------------------------------------------------------------

resource "aws_iam_role_policy" "fjcloud_ec2_control" {
  name = "fjcloud-ec2-control"
  role = aws_iam_role.fjcloud_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:RunInstances",
          "ec2:DescribeInstances",
          "ec2:StartInstances",
          "ec2:StopInstances",
          "ec2:TerminateInstances",
          "ec2:CreateTags",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = aws_iam_role.fjcloud_instance.arn
      },
    ]
  })
}

# --------------------------------------------------------------------------
# Policy — S3 read-only for release artifacts bucket
# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
# Managed Policy — SSM agent registration (required for deploy.sh send-command)
# --------------------------------------------------------------------------

resource "aws_iam_role_policy_attachment" "fjcloud_ssm_core" {
  role       = aws_iam_role.fjcloud_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "fjcloud_s3_releases_read" {
  name = "fjcloud-s3-releases-read"
  role = aws_iam_role.fjcloud_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:GetObject", "s3:ListBucket"]
      Resource = [
        "arn:aws:s3:::fjcloud-releases-*",
        "arn:aws:s3:::fjcloud-releases-*/*"
      ]
    }]
  })
}

# --------------------------------------------------------------------------
# Policy — SES send for flapjack.foo domain
# --------------------------------------------------------------------------

resource "aws_iam_role_policy" "fjcloud_ses_send" {
  name = "fjcloud-ses-send"
  role = aws_iam_role.fjcloud_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ses:SendEmail", "ses:SendRawEmail"]
      Resource = "arn:aws:ses:us-east-1:*:identity/flapjack.foo"
    }]
  })
}

# --------------------------------------------------------------------------
# Instance Profile — attached to EC2 instances at launch
# --------------------------------------------------------------------------

resource "aws_iam_instance_profile" "fjcloud_instance" {
  name = "fjcloud-instance-profile"
  role = aws_iam_role.fjcloud_instance.name

  tags = {
    managed-by = "terraform"
    service    = "fjcloud"
  }
}

# --------------------------------------------------------------------------
# Outputs
# --------------------------------------------------------------------------

output "instance_profile_name" {
  value       = aws_iam_instance_profile.fjcloud_instance.name
  description = "Instance profile name to set as AWS_INSTANCE_PROFILE_NAME"
}

output "instance_profile_arn" {
  value       = aws_iam_instance_profile.fjcloud_instance.arn
  description = "Instance profile ARN"
}

output "role_arn" {
  value       = aws_iam_role.fjcloud_instance.arn
  description = "IAM role ARN"
}
