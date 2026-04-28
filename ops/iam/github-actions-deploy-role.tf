# GitHub Actions OIDC provider and least-privilege deploy role for
# staging CI/CD. The deploy role is assumed by the deploy-staging
# workflow in gridl-infra-staging/fjcloud via OIDC federation.

# --------------------------------------------------------------------------
# OIDC Provider — GitHub Actions token issuer
# --------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = {
    managed-by = "terraform"
    service    = "fjcloud"
  }
}

# --------------------------------------------------------------------------
# IAM Role — assumed by GitHub Actions via OIDC
# --------------------------------------------------------------------------

resource "aws_iam_role" "fjcloud_deploy" {
  name = "fjcloud-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRoleWithWebIdentity"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github_actions.arn
      }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:sub" = "repo:gridl-infra-staging/fjcloud:ref:refs/heads/main"
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    managed-by = "terraform"
    service    = "fjcloud"
  }
}

# --------------------------------------------------------------------------
# Policy — S3 artifact upload/list on staging release bucket
# --------------------------------------------------------------------------

resource "aws_iam_role_policy" "fjcloud_deploy_s3" {
  name = "fjcloud-deploy-s3"
  role = aws_iam_role.fjcloud_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:PutObject",
        "s3:GetObject",
        "s3:ListBucket",
      ]
      Resource = [
        "arn:aws:s3:::fjcloud-releases-staging",
        "arn:aws:s3:::fjcloud-releases-staging/*",
      ]
    }]
  })
}

# --------------------------------------------------------------------------
# Policy — EC2 instance discovery for deploy target lookup
# --------------------------------------------------------------------------

resource "aws_iam_role_policy" "fjcloud_deploy_ec2" {
  name = "fjcloud-deploy-ec2"
  role = aws_iam_role.fjcloud_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:DescribeInstances"]
      Resource = "*"
    }]
  })
}

# --------------------------------------------------------------------------
# Policy — SSM parameter and command execution for deploy orchestration
# --------------------------------------------------------------------------

resource "aws_iam_role_policy" "fjcloud_deploy_ssm" {
  name = "fjcloud-deploy-ssm"
  role = aws_iam_role.fjcloud_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:PutParameter",
          "ssm:DeleteParameter",
        ]
        Resource = "arn:aws:ssm:*:*:parameter/fjcloud/*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:SendCommand",
          "ssm:GetCommandInvocation",
        ]
        Resource = "*"
      },
    ]
  })
}

# --------------------------------------------------------------------------
# Output — deploy role ARN (consumed as DEPLOY_IAM_ROLE_ARN secret)
# --------------------------------------------------------------------------

output "deploy_role_arn" {
  value       = aws_iam_role.fjcloud_deploy.arn
  description = "Deploy role ARN for GitHub Actions OIDC assumption"
}
