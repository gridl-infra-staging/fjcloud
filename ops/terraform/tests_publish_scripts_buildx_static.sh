#!/usr/bin/env bash
# Static test: both Lambda canary publish scripts use buildx with the flags
# required for AWS Lambda compatibility (docker schema-2 manifest).
#
# AWS Lambda rejects OCI manifests. The fix is `docker buildx build
# --provenance=false --push --platform linux/arm64`. Both scripts must use
# this pattern. If either drifts back to plain `docker build`, this test
# catches it before publish.
#
# Captured 2026-05-14 in the prod-env-provision lane post-mortem.
set -euo pipefail
cd "$(dirname "$0")/../.."

REQUIRED_PATTERNS=(
  'docker buildx build'
  '--provenance=false'
  '--push'
)
# Platform is a separate check: must be single-platform (arm64 OR amd64), not
# multi-arch. Lambda accepts either single-arch but rejects multi-arch OCI.
# Accepting either avoids a brittle hardcode if a canary legitimately moves
# off arm64.
REQUIRED_PLATFORM_REGEX='--platform linux/(arm64|amd64)([[:space:]]|$|\\)'

SCRIPTS=(
  ops/terraform/publish_customer_loop_canary_image.sh
  ops/terraform/publish_support_email_canary_image.sh
)

fail=0
for script in "${SCRIPTS[@]}"; do
  if [[ ! -f "$script" ]]; then
    echo "FAIL: $script missing"
    fail=1
    continue
  fi
  for pat in "${REQUIRED_PATTERNS[@]}"; do
    if grep -qF -- "$pat" "$script"; then
      echo "PASS: $script contains '$pat'"
    else
      echo "FAIL: $script missing required pattern '$pat' -- Lambda will reject the published image"
      fail=1
    fi
  done
  if grep -qE -- "$REQUIRED_PLATFORM_REGEX" "$script"; then
    echo "PASS: $script declares a single-platform --platform linux/(arm64|amd64)"
  else
    echo "FAIL: $script missing single-platform --platform flag (linux/arm64 or linux/amd64). Multi-arch builds produce OCI index manifests Lambda rejects."
    fail=1
  fi
done

# Confirm neither script has the BANNED plain `docker build` pattern that
# would silently produce an OCI manifest.
for script in "${SCRIPTS[@]}"; do
  # Look for `docker build` (without `buildx`). Use a regex that excludes
  # `docker buildx build`.
  if grep -E '^[[:space:]]*docker build[[:space:]]' "$script" >/dev/null; then
    echo "FAIL: $script uses plain 'docker build' -- must use 'docker buildx build --provenance=false'"
    fail=1
  fi
done

exit $fail
