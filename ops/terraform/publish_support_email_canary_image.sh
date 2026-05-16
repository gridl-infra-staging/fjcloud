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

# why: AWS Lambda requires docker schema-2 manifests, but `docker build`
# (BuildKit, Docker 25+) emits OCI-index manifests by default and Lambda
# rejects the resulting image with "InvalidParameterValueException: image
# manifest, config or layer media type ... is not supported". Building
# with `buildx --provenance=false --push` produces a single-arch docker v2
# manifest that Lambda accepts. Mirrors the customer-loop publisher.
docker buildx build \
  --platform linux/arm64 \
  --provenance=false \
  --push \
  -f ops/terraform/support_email_canary/Dockerfile \
  -t "${repository_uri}:${image_tag}" \
  .

echo "Published support-email canary image: ${repository_uri}:${image_tag}"

# Post-publish contract: invoke the resulting Lambda once and assert it works.
# Catches the class of bug where the image pushes to ECR successfully but
# Lambda rejects it (OCI manifest, wrong arch, missing handler, etc).
#
# Gating: staging runs unconditionally. Prod has no live-money concern for the
# support-email canary specifically (no Stripe path), but we still gate it
# behind --allow-live-stripe for consistency with the customer-loop publisher
# and to keep the surface predictable across both publish scripts.
allow_live_stripe="${ALLOW_LIVE_STRIPE:-0}"
for arg in "$@"; do
  [[ "$arg" == "--allow-live-stripe" ]] && allow_live_stripe=1
done
post_publish_should_invoke=0
case "$env_name" in
  staging) post_publish_should_invoke=1 ;;
  prod)
    if [[ "$allow_live_stripe" == "1" ]]; then
      post_publish_should_invoke=1
    else
      echo "INFO: skipping post-publish prod invoke (default-off; pass --allow-live-stripe to enable)."
    fi
    ;;
esac
if [[ "$post_publish_should_invoke" == "1" ]] \
   && command -v aws >/dev/null 2>&1 \
   && aws sts get-caller-identity --region us-east-1 >/dev/null 2>&1; then
  bash "$(dirname "$0")/../../scripts/canary/contracts/lambda_canary_invoke_contract.sh" "$env_name" "support-email" \
    || { echo "ERROR: published image but post-publish Lambda invoke failed. Investigate manifest format / arch / handler before declaring this image good." >&2; exit 1; }
fi
