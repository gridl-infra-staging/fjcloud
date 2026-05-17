#!/usr/bin/env bash
# Shared canary Lambda image publish orchestration.
# Wrapper scripts remain owners of canary-specific metadata.

# TODO: Document validate_canary_env_name.
validate_canary_env_name() {
  local env_name="$1"
  if [[ "$env_name" == "staging" || "$env_name" == "prod" ]]; then
    return 0
  fi

  echo "ERROR: env must be staging or prod" >&2
  return 1
}

resolve_canary_image_tag() {
  local image_tag_override="${1:-}"
  if [[ -n "$image_tag_override" ]]; then
    printf '%s\n' "$image_tag_override"
    return 0
  fi

  git rev-parse --short=12 HEAD
}

should_invoke_post_publish_contract() {
  local env_name="$1"
  local prod_post_publish_invoke_enabled="$2"
  local prod_post_publish_warning="$3"

  case "$env_name" in
    staging)
      return 0
      ;;
    prod)
      if [[ "$prod_post_publish_invoke_enabled" == "1" ]]; then
        if [[ -n "$prod_post_publish_warning" ]]; then
          echo "$prod_post_publish_warning"
        fi
        return 0
      fi

      echo "INFO: skipping post-publish prod invoke because the wrapper did not enable it."
      return 1
      ;;
  esac

  return 1
}

publish_canary_image() {
  local env_name="$1"
  local image_tag="$2"
  local repository_name="$3"
  local dockerfile_path="$4"
  local canary_name="$5"
  local prod_post_publish_invoke_enabled="$6"
  local prod_post_publish_warning="$7"

  local region="${AWS_REGION:-us-east-1}"

  local account_id
  account_id="$(aws sts get-caller-identity --query Account --output text --region "$region")"

  local repository_uri="${account_id}.dkr.ecr.${region}.amazonaws.com/${repository_name}"

  if ! aws ecr describe-repositories --repository-names "$repository_name" --region "$region" >/dev/null 2>&1; then
    echo "ERROR: ECR repository ${repository_name} does not exist in ${region} for account ${account_id}." >&2
    echo "Run Terraform apply for the monitoring module first so infrastructure ownership stays in Terraform." >&2
    return 1
  fi

  aws ecr get-login-password --region "$region" | docker login --username AWS --password-stdin "${account_id}.dkr.ecr.${region}.amazonaws.com"

  # why: AWS Lambda requires docker schema-2 manifests, but `docker build`
  # (BuildKit, Docker 25+) emits OCI-index manifests by default and Lambda
  # rejects the resulting image with "InvalidParameterValueException: image
  # manifest, config or layer media type ... is not supported". Building
  # with `buildx --platform linux/arm64 --provenance=false --push` produces
  # a single-arch docker v2 manifest that Lambda accepts.
  docker buildx build \
    --platform linux/arm64 \
    --provenance=false \
    --push \
    -f "$dockerfile_path" \
    -t "${repository_uri}:${image_tag}" \
    .

  echo "Published ${canary_name} canary image: ${repository_uri}:${image_tag}"

  if should_invoke_post_publish_contract "$env_name" "$prod_post_publish_invoke_enabled" "$prod_post_publish_warning" \
    && command -v aws >/dev/null 2>&1 \
    && aws sts get-caller-identity --region us-east-1 >/dev/null 2>&1; then
    bash "$(dirname "${BASH_SOURCE[0]}")/../../scripts/canary/contracts/lambda_canary_invoke_contract.sh" "$env_name" "$canary_name" \
      || {
        echo "ERROR: published image but post-publish Lambda invoke failed. Investigate manifest format / arch / handler before declaring this image good." >&2
        return 1
      }
  fi
}
