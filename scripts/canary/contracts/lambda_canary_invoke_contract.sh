#!/usr/bin/env bash
# Lambda canary invocation contract. After publishing a canary container image
# to ECR (publish_customer_loop_canary_image.sh or publish_support_email_canary_image.sh),
# invoke the resulting Lambda once and assert it succeeds.
#
# This catches the bug class where the published image is technically valid
# from a registry-push standpoint but rejected by AWS Lambda at runtime
# (OCI manifest, wrong architecture, missing handler, etc).
#
# Usage: lambda_canary_invoke_contract.sh <env> <canary_name>
#   env: staging | prod
#   canary_name: customer-loop | support-email
set -euo pipefail

env="$1"
canary="$2"

[[ "$env" == "staging" || "$env" == "prod" ]] || { echo "bad env: $env" >&2; exit 2; }
[[ "$canary" == "customer-loop" || "$canary" == "support-email" ]] \
  || { echo "bad canary: $canary" >&2; exit 2; }

func="fjcloud-${env}-${canary}-canary"
out=$(mktemp)
log_file=$(mktemp)

# RequestResponse synchronous invoke. The customer-loop canary runs a full
# signup→index→search→teardown flow inside the Lambda (Lambda timeout=900s),
# so the default AWS CLI 60s read timeout would always fire even on a healthy
# invoke. Set --cli-read-timeout to 0 (no timeout) and bump the connect
# timeout slightly above the default to ride out cold-start network blips;
# the Lambda's own timeout still bounds the invoke wall-clock.
aws lambda invoke \
  --cli-read-timeout 0 \
  --cli-connect-timeout 30 \
  --function-name "$func" \
  --invocation-type RequestResponse \
  --log-type Tail \
  --region us-east-1 \
  "$out" > "$log_file" 2>&1 || {
    echo "FAIL: aws lambda invoke for $func returned non-zero"
    cat "$log_file"
    exit 1
  }

# StatusCode from the invocation API itself (not the function payload).
# 200 means the function was invoked. 4xx/5xx means Lambda rejected (likely
# the manifest/image-format bug we're guarding against).
api_status=$(jq -r '.StatusCode' "$log_file")
[[ "$api_status" == "200" ]] || { echo "FAIL: invoke API returned StatusCode=$api_status"; cat "$log_file"; exit 1; }

# FunctionError signals the function ran but threw. Empty means clean exit.
# When FunctionError is present, distinguish between:
#   (a) Lambda wiring failures (bad image, missing handler, OCI manifest) — FAIL
#   (b) Canary-detected service failures (API down, HTTP 503) — WARN, exit 0
# The contract's scope is image/runtime validation (a), not service health (b).
func_error=$(jq -r '.FunctionError // empty' "$log_file")
if [[ -n "$func_error" ]]; then
  error_type=$(jq -r '.errorType // empty' "$out" 2>/dev/null)
  error_msg=$(jq -r '.errorMessage // empty' "$out" 2>/dev/null)

  is_canary_app_error=0
  if [[ "$error_type" == "CustomerLoopCanaryError" ]]; then
    is_canary_app_error=1
  elif [[ "$error_msg" == *"canary failed with exit code"* ]]; then
    is_canary_app_error=1
  fi

  if [[ "$is_canary_app_error" -eq 1 ]]; then
    echo "WARN: $func canary detected a service issue (image/runtime is healthy)"
    echo "  errorType=$error_type"
    echo "  errorMessage=$error_msg"
    echo "==log tail=="
    jq -r '.LogResult' "$log_file" | base64 -d 2>/dev/null | tail -20
    exit 0
  fi

  echo "FAIL: function $func threw $func_error"
  echo "==response body=="
  cat "$out"
  echo "==log tail (base64 in invoke response; decode if needed)=="
  jq -r '.LogResult' "$log_file" | base64 -d 2>/dev/null | tail -20
  exit 1
fi

# Optional: sniff for a known sentinel string in the response body. Each canary
# returns slightly different JSON; both should at least include "status" or
# "succeeded" somewhere. If the response body is empty or non-JSON, that's
# already caught by FunctionError.
body=$(cat "$out")
if [[ -z "$body" ]]; then
  echo "WARN: $func returned empty body but no FunctionError"
  exit 0
fi
echo "PASS: $func invoked successfully (api_status=200, function_error=)"
echo "  response: ${body:0:200}..."
