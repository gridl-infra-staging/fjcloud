#!/usr/bin/env bash
# Build + push the customer-loop canary Lambda container image to ECR.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/publish_canary_image_shared.sh"

usage() {
  cat <<USAGE
Usage: $0 <staging|prod> [image_tag] [--allow-live-stripe]

Builds scripts/canary/lambda_image/Dockerfile and pushes to:
  <account>.dkr.ecr.<region>.amazonaws.com/fjcloud-<env>-customer-loop-canary:<tag>
USAGE
}

env_name=""
image_tag_override=""
allow_live_stripe="0"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-live-stripe)
      allow_live_stripe="1"
      shift
      ;;
    *)
      if [[ -z "$env_name" ]]; then
        env_name="$1"
      elif [[ -z "$image_tag_override" ]]; then
        image_tag_override="$1"
      else
        usage
        exit 2
      fi
      shift
      ;;
  esac
done

if [[ -z "$env_name" ]]; then
  usage
  exit 2
fi

if ! validate_canary_env_name "$env_name"; then
  exit 2
fi

image_tag="$(resolve_canary_image_tag "$image_tag_override")"
repository_name="fjcloud-${env_name}-customer-loop-canary"
dockerfile_path="scripts/canary/lambda_image/Dockerfile"
prod_live_stripe_warning="WARN: --allow-live-stripe set — invoking prod canary will create real Stripe customers/charges."

publish_canary_image "$env_name" "$image_tag" "$repository_name" "$dockerfile_path" "customer-loop" "$allow_live_stripe" "$prod_live_stripe_warning"
