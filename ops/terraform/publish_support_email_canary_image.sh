#!/usr/bin/env bash
# Build + push the support-email canary Lambda container image to ECR.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/publish_canary_image_shared.sh"

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
if ! validate_canary_env_name "$env_name"; then
  exit 2
fi

image_tag="$(resolve_canary_image_tag "${2:-}")"
repository_name="fjcloud-${env_name}-support-email-canary"
dockerfile_path="ops/terraform/support_email_canary/Dockerfile"

publish_canary_image "$env_name" "$image_tag" "$repository_name" "$dockerfile_path" "support-email" "0" ""
