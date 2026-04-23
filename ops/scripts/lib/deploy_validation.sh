#!/usr/bin/env bash
# Shared pre-deployment validation adapter for deploy gate checks.

set -euo pipefail

DEPLOY_GATE_MODE="${DEPLOY_GATE_MODE:-mock}"

ci_status_is_passing() {
  local sha="$1"

  if [[ "$DEPLOY_GATE_MODE" == "mock" ]]; then
    case "${DEPLOY_GATE_MOCK_CI_STATUS:-pass}" in
      pass)
        return 0
        ;;
      fail)
        echo "ERROR: CI status check failed for SHA ${sha} (mock status=fail)"
        return 1
        ;;
      error)
        echo "ERROR: CI status lookup error for SHA ${sha} (mock status=error)"
        return 2
        ;;
      *)
        echo "ERROR: invalid DEPLOY_GATE_MOCK_CI_STATUS='${DEPLOY_GATE_MOCK_CI_STATUS:-}' (expected pass|fail|error)"
        return 2
        ;;
    esac
  fi

  if [[ "$DEPLOY_GATE_MODE" != "live" ]]; then
    echo "ERROR: invalid DEPLOY_GATE_MODE='${DEPLOY_GATE_MODE}' (expected mock|live)"
    return 2
  fi

  local repo token state
  repo="${DEPLOY_GATE_GITHUB_REPO:-${GITHUB_REPOSITORY:-}}"
  token="${DEPLOY_GATE_GITHUB_TOKEN:-${GITHUB_TOKEN:-}}"

  if [[ -z "$repo" || -z "$token" ]]; then
    echo "ERROR: live CI status check requires DEPLOY_GATE_GITHUB_REPO/GITHUB_REPOSITORY and DEPLOY_GATE_GITHUB_TOKEN/GITHUB_TOKEN"
    return 2
  fi

  state="$(
    curl -fsSL \
      -H "Authorization: Bearer ${token}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${repo}/commits/${sha}/status" \
      | jq -r '.state'
  2>/dev/null || true)"

  if [[ "$state" == "success" ]]; then
    return 0
  fi

  if [[ -z "$state" || "$state" == "null" ]]; then
    echo "ERROR: CI status lookup error for SHA ${sha} (live status unavailable)"
    return 2
  fi

  echo "ERROR: CI status check failed for SHA ${sha} (live status=${state})"
  return 1
}

artifact_exists_for_sha() {
  local env="$1"
  local sha="$2"
  local region="${3:-${AWS_REGION:-us-east-1}}"

  if [[ "$DEPLOY_GATE_MODE" == "mock" ]]; then
    case "${DEPLOY_GATE_MOCK_ARTIFACT_STATUS:-exists}" in
      exists)
        return 0
        ;;
      missing)
        echo "ERROR: release artifact check failed for SHA ${sha} (mock status=missing)"
        return 1
        ;;
      error)
        echo "ERROR: release artifact lookup error for SHA ${sha} (mock status=error)"
        return 2
        ;;
      *)
        echo "ERROR: invalid DEPLOY_GATE_MOCK_ARTIFACT_STATUS='${DEPLOY_GATE_MOCK_ARTIFACT_STATUS:-}' (expected exists|missing|error)"
        return 2
        ;;
    esac
  fi

  if [[ "$DEPLOY_GATE_MODE" != "live" ]]; then
    echo "ERROR: invalid DEPLOY_GATE_MODE='${DEPLOY_GATE_MODE}' (expected mock|live)"
    return 2
  fi

  local bucket prefix object_count
  bucket="fjcloud-releases-${env}"
  prefix="${env}/${sha}/"

  object_count="$(
    aws s3api list-objects-v2 \
      --region "$region" \
      --bucket "$bucket" \
      --prefix "$prefix" \
      --max-items 1 \
      --query 'length(Contents)' \
      --output text
  2>/dev/null || true)"

  if [[ -z "$object_count" ]]; then
    echo "ERROR: release artifact lookup error for SHA ${sha} (live lookup failed)"
    return 2
  fi

  if [[ "$object_count" == "None" || "$object_count" == "0" ]]; then
    echo "ERROR: release artifact check failed for SHA ${sha} (no objects at s3://${bucket}/${prefix})"
    return 1
  fi

  return 0
}

predeploy_validate_release() {
  local env="$1"
  local sha="$2"
  local region="${3:-${AWS_REGION:-us-east-1}}"
  local status=0

  echo "==> Pre-deploy validation: mode=${DEPLOY_GATE_MODE}, sha=${sha}"

  ci_status_is_passing "$sha" || status=$?
  if [[ "$status" -ne 0 ]]; then
    if [[ "$status" -eq 2 ]]; then
      echo "ERROR: pre-deploy validation failed for SHA ${sha}: CI status lookup error"
    else
      echo "ERROR: pre-deploy validation failed for SHA ${sha}: CI status is not passing"
    fi
    return 1
  fi

  artifact_exists_for_sha "$env" "$sha" "$region" || status=$?
  if [[ "$status" -ne 0 ]]; then
    if [[ "$status" -eq 2 ]]; then
      echo "ERROR: pre-deploy validation failed for SHA ${sha}: artifact lookup error"
    else
      echo "ERROR: pre-deploy validation failed for SHA ${sha}: artifact missing"
    fi
    return 1
  fi

  echo "==> Pre-deploy validation passed for SHA ${sha}"
}
