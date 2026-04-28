#!/usr/bin/env bash
# Build + push the support-email canary Lambda container image to ECR.
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 <staging|prod> [image_tag]

Builds ops/terraform/support_email_canary/Dockerfile and pushes to:
  <account>.dkr.ecr.<region>.amazonaws.com/fjcloud-<env>-support-email-canary:<tag>
USAGE
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 2
fi

env_name="$1"
if [[ "$env_name" != "staging" && "$env_name" != "prod" ]]; then
  echo "ERROR: env must be staging or prod" >&2
  exit 2
fi

image_tag="${2:-$(git rev-parse --short=12 HEAD)}"
region="${AWS_REGION:-us-east-1}"

account_id="$(aws sts get-caller-identity --query Account --output text --region "$region")"
repository_name="fjcloud-${env_name}-support-email-canary"
repository_uri="${account_id}.dkr.ecr.${region}.amazonaws.com/${repository_name}"

if ! aws ecr describe-repositories --repository-names "$repository_name" --region "$region" >/dev/null 2>&1; then
  echo "ERROR: ECR repository ${repository_name} does not exist in ${region} for account ${account_id}." >&2
  echo "Run Terraform apply for the monitoring module first so infrastructure ownership stays in Terraform." >&2
  exit 1
fi

aws ecr get-login-password --region "$region" | docker login --username AWS --password-stdin "${account_id}.dkr.ecr.${region}.amazonaws.com"

docker build \
  -f ops/terraform/support_email_canary/Dockerfile \
  -t "${repository_uri}:${image_tag}" \
  .

docker push "${repository_uri}:${image_tag}"

echo "Published support-email canary image: ${repository_uri}:${image_tag}"
