#!/usr/bin/env bash
# Static contract for Lambda canary image publishing.
#
# The wrapper entrypoints own canary-specific metadata, but shared publish
# orchestration must live in ops/terraform/publish_canary_image_shared.sh so
# customer-loop and support-email do not diverge.
#
# Build contract ownership also stays centralized in the shared helper:
# `docker buildx build --platform linux/arm64 --provenance=false --push`.
#
# Captured 2026-05-14 in the prod-env-provision lane post-mortem.
set -euo pipefail
cd "$(dirname "$0")/../.."

SHARED_HELPER="ops/terraform/publish_canary_image_shared.sh"
CUSTOMER_WRAPPER="ops/terraform/publish_customer_loop_canary_image.sh"
SUPPORT_WRAPPER="ops/terraform/publish_support_email_canary_image.sh"
WRAPPER_SCRIPTS=(
  "$CUSTOMER_WRAPPER"
  "$SUPPORT_WRAPPER"
)

SHARED_REQUIRED_PATTERNS=(
  'docker buildx build'
  '--provenance=false'
  '--push'
)
# Platform is a separate check: Stage 2 contract keeps linux/arm64 explicitly.
REQUIRED_PLATFORM_REGEX='--platform linux/arm64([[:space:]]|$|\\)'

INLINE_WRAPPER_BANNED_PATTERNS=(
  'aws ecr describe-repositories'
  'aws ecr get-login-password'
  'docker buildx build'
  'lambda_canary_invoke_contract\.sh'
)

USAGE_HEADER='Usage: $0 <staging|prod> [image_tag]'
CUSTOMER_USAGE_HEADER='Usage: $0 <staging|prod> [image_tag] [--allow-live-stripe]'
CUSTOMER_USAGE_BUILD_LINE='Builds scripts/canary/lambda_image/Dockerfile and pushes to:'
SUPPORT_USAGE_BUILD_LINE='Builds ops/terraform/support_email_canary/Dockerfile and pushes to:'
CUSTOMER_LIVE_STRIPE_WARNING='WARN: --allow-live-stripe set — invoking prod canary will create real Stripe customers/charges.'
CUSTOMER_LIVE_STRIPE_FLAG='--allow-live-stripe'
CUSTOMER_REPOSITORY_LITERAL='fjcloud-${env_name}-customer-loop-canary'
CUSTOMER_DOCKERFILE_LITERAL='scripts/canary/lambda_image/Dockerfile'
SUPPORT_REPOSITORY_LITERAL='fjcloud-${env_name}-support-email-canary'
SUPPORT_DOCKERFILE_LITERAL='ops/terraform/support_email_canary/Dockerfile'

fail=0

pass_check() {
  echo "PASS: $1"
}

fail_check() {
  echo "FAIL: $1"
  fail=1
}

assert_file_exists() {
  local file="$1"
  local missing_description="$2"
  if [[ -f "$file" ]]; then
    pass_check "$file exists"
  else
    fail_check "$missing_description"
  fi
}

assert_file_contains_regex() {
  local file="$1"
  local pattern="$2"
  local pass_description="$3"
  local fail_description="$4"
  if grep -qE -- "$pattern" "$file"; then
    pass_check "$pass_description"
  else
    fail_check "$fail_description"
  fi
}

assert_file_contains_fixed() {
  local file="$1"
  local pattern="$2"
  local pass_description="$3"
  local fail_description="$4"
  if grep -qF -- "$pattern" "$file"; then
    pass_check "$pass_description"
  else
    fail_check "$fail_description"
  fi
}

assert_file_not_contains_fixed() {
  local file="$1"
  local pattern="$2"
  local pass_description="$3"
  local fail_description="$4"
  if grep -qF -- "$pattern" "$file"; then
    fail_check "$fail_description"
  else
    pass_check "$pass_description"
  fi
}

assert_file_not_contains_regex() {
  local file="$1"
  local pattern="$2"
  local pass_description="$3"
  local fail_description="$4"
  if grep -qE -- "$pattern" "$file"; then
    fail_check "$fail_description"
  else
    pass_check "$pass_description"
  fi
}

assert_file_exists "$SHARED_HELPER" "missing shared publish owner $SHARED_HELPER"

for script in "${WRAPPER_SCRIPTS[@]}"; do
  if [[ ! -f "$script" ]]; then
    fail_check "$script missing"
    continue
  fi
  assert_file_contains_regex "$script" 'source .*publish_canary_image_shared\.sh' "$script sources shared helper" "$script must source publish_canary_image_shared.sh"
  for pat in "${INLINE_WRAPPER_BANNED_PATTERNS[@]}"; do
    assert_file_not_contains_regex "$script" "$pat" "$script delegates inline publish logic pattern '$pat'" "$script still owns inline publish logic pattern '$pat'"
  done
done

# Wrappers remain the owner of their canary-specific metadata.
if grep -qF -- "$CUSTOMER_REPOSITORY_LITERAL" "$CUSTOMER_WRAPPER" \
  && grep -qF -- "$CUSTOMER_DOCKERFILE_LITERAL" "$CUSTOMER_WRAPPER"; then
  pass_check "customer wrapper keeps repository + Dockerfile ownership"
else
  fail_check "customer wrapper missing repository or Dockerfile ownership"
fi
if grep -qF -- "$SUPPORT_REPOSITORY_LITERAL" "$SUPPORT_WRAPPER" \
  && grep -qF -- "$SUPPORT_DOCKERFILE_LITERAL" "$SUPPORT_WRAPPER"; then
  pass_check "support-email wrapper keeps repository + Dockerfile ownership"
else
  fail_check "support-email wrapper missing repository or Dockerfile ownership"
fi
if grep -qF -- "$CUSTOMER_USAGE_HEADER" "$CUSTOMER_WRAPPER" \
  && grep -qF -- "$CUSTOMER_USAGE_BUILD_LINE" "$CUSTOMER_WRAPPER"; then
  pass_check "customer wrapper keeps usage text ownership"
else
  fail_check "customer wrapper missing required usage text ownership"
fi
if grep -qF -- "$USAGE_HEADER" "$SUPPORT_WRAPPER" \
  && grep -qF -- "$SUPPORT_USAGE_BUILD_LINE" "$SUPPORT_WRAPPER"; then
  pass_check "support-email wrapper keeps usage text ownership"
else
  fail_check "support-email wrapper missing required usage text ownership"
fi
assert_file_contains_fixed "$CUSTOMER_WRAPPER" "$CUSTOMER_LIVE_STRIPE_WARNING" "customer wrapper keeps live-Stripe warning ownership" "customer wrapper missing live-Stripe warning literal"
assert_file_contains_fixed "$CUSTOMER_WRAPPER" "$CUSTOMER_LIVE_STRIPE_FLAG" "customer wrapper keeps live-Stripe flag ownership" "customer wrapper missing live-Stripe flag literal"
if [[ -f "$SHARED_HELPER" ]]; then
  assert_file_not_contains_fixed "$SHARED_HELPER" "$USAGE_HEADER" "shared helper does not own wrapper usage text" "shared helper must not own wrapper usage text"
  assert_file_not_contains_fixed "$SHARED_HELPER" "$CUSTOMER_USAGE_BUILD_LINE" "shared helper does not own customer wrapper usage text" "shared helper must not own customer wrapper usage text"
  assert_file_not_contains_fixed "$SHARED_HELPER" "$SUPPORT_USAGE_BUILD_LINE" "shared helper does not own support-email wrapper usage text" "shared helper must not own support-email wrapper usage text"
  assert_file_not_contains_fixed "$SHARED_HELPER" "$CUSTOMER_LIVE_STRIPE_WARNING" "shared helper does not own customer live-Stripe warning literal" "shared helper must not own customer live-Stripe warning literal"
  assert_file_not_contains_fixed "$SHARED_HELPER" "$CUSTOMER_LIVE_STRIPE_FLAG" "shared helper does not own customer live-Stripe flag literal" "shared helper must not own customer live-Stripe flag literal"
  assert_file_not_contains_fixed "$SHARED_HELPER" "$CUSTOMER_REPOSITORY_LITERAL" "shared helper does not own customer repository literal" "shared helper must not own customer repository literal"
  assert_file_not_contains_fixed "$SHARED_HELPER" "$CUSTOMER_DOCKERFILE_LITERAL" "shared helper does not own customer Dockerfile literal" "shared helper must not own customer Dockerfile literal"
  assert_file_not_contains_fixed "$SHARED_HELPER" "$SUPPORT_REPOSITORY_LITERAL" "shared helper does not own support-email repository literal" "shared helper must not own support-email repository literal"
  assert_file_not_contains_fixed "$SHARED_HELPER" "$SUPPORT_DOCKERFILE_LITERAL" "shared helper does not own support-email Dockerfile literal" "shared helper must not own support-email Dockerfile literal"
fi

if [[ -f "$SHARED_HELPER" ]]; then
  for pat in "${SHARED_REQUIRED_PATTERNS[@]}"; do
    assert_file_contains_fixed "$SHARED_HELPER" "$pat" "shared helper contains '$pat'" "shared helper missing required pattern '$pat' -- Lambda will reject the published image"
  done
  assert_file_contains_regex "$SHARED_HELPER" "$REQUIRED_PLATFORM_REGEX" "shared helper declares --platform linux/arm64" "shared helper missing --platform linux/arm64 flag. Multi-arch builds produce OCI index manifests Lambda rejects."

  # Confirm shared helper does not regress to plain `docker build`.
  # Look for `docker build` (without `buildx`). Use a regex that excludes
  # `docker buildx build`.
  assert_file_not_contains_regex "$SHARED_HELPER" '^[[:space:]]*docker build[[:space:]]' "shared helper avoids plain 'docker build'" "$SHARED_HELPER uses plain 'docker build' -- must use 'docker buildx build --provenance=false'"
fi

if grep -qF -- 'allow_live_stripe="1"' "$CUSTOMER_WRAPPER" \
  && grep -qF -- '"customer-loop" "$allow_live_stripe" "$prod_live_stripe_warning"' "$CUSTOMER_WRAPPER"; then
  pass_check "customer wrapper forwards live-Stripe gate as explicit helper input"
else
  fail_check "customer wrapper must forward live-Stripe gate as explicit helper input"
fi

exit $fail
