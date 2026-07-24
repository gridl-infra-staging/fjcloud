#!/usr/bin/env bash
# Shared release-artifact publication helpers for GitHub Actions deploy jobs.

release_artifacts_existing_count() {
  local bucket="$1" prefix="$2"
  aws s3api list-objects-v2 \
    --bucket "$bucket" \
    --prefix "$prefix" \
    --max-items 1 \
    --query 'length(Contents || `[]`)' \
    --output text
}

release_artifacts_reuse_existing() {
  local bucket="$1" prefix="$2" expected_manifest="$3"
  local existing_manifest

  existing_manifest="$(mktemp "${TMPDIR:-/tmp}/fjcloud-release-manifest.XXXXXX")"
  if ! aws s3 cp "s3://${bucket}/${prefix}rollback_contract.json" "$existing_manifest"; then
    echo "ERROR: release artifacts already exist at ${prefix}, but rollback_contract.json is absent" >&2
    return 1
  fi
  if ! cmp -s "$expected_manifest" "$existing_manifest"; then
    echo "ERROR: release artifacts already exist at ${prefix}, but rollback_contract.json does not match this build" >&2
    return 1
  fi

  echo "Reusing existing release artifacts at s3://${bucket}/${prefix}"
}
