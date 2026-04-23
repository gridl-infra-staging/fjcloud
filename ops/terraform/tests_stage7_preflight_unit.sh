#!/usr/bin/env bash
# Behavioral tests for preflight checks in tests_stage7_runtime_smoke.sh.
# Uses mock AWS/terraform/dig/curl commands to validate exit codes and
# remediation messages without requiring live infrastructure.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNTIME_SCRIPT="${SCRIPT_DIR}/tests_stage7_runtime_smoke.sh"

MOCK_DIR=""
MOCK_ENV_FILE=""
FAKE_SHA="a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"

setup() {
  MOCK_DIR=$(mktemp -d)
  MOCK_ENV_FILE=$(mktemp)
  cat > "$MOCK_ENV_FILE" <<'ENVEOF'
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
AWS_DEFAULT_REGION=us-east-1
CLOUDFLARE_EDIT_READ_ZONE_DNS_API_TOKEN_FLAPJACK_FOO=cf_test_token
CLOUDFLARE_ZONE_ID_FLAPJACK_FOO=cf_zone_foo_test
ENVEOF
  # Default mock terraform/dig/curl that succeed silently
  for cmd in terraform dig; do
    printf '#!/bin/bash\nexit 0\n' > "${MOCK_DIR}/${cmd}"
    chmod +x "${MOCK_DIR}/${cmd}"
  done
  cat > "${MOCK_DIR}/curl" <<'CURLMOCK'
#!/bin/bash
if [[ "$*" == *"api.cloudflare.com/client/v4/zones/cf_zone_foo_test"* ]]; then
  if [[ "$*" == *"dns_records"* ]]; then
    printf '{"success":true,"result":[{"name":"flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com"},{"name":"api.flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com"},{"name":"www.flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com"},{"name":"cloud.flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com"}]}'
    exit 0
  fi
  printf '{"success":true,"result":{"id":"cf_zone_foo_test","name":"flapjack.foo","account":{"id":"acct_123","name":"Example Account"},"plan":{"id":"plan_free","name":"Free Website"}}}'
  exit 0
fi
exit 0
CURLMOCK
  chmod +x "${MOCK_DIR}/curl"
}

teardown() {
  rm -rf "$MOCK_DIR" "$MOCK_ENV_FILE"
}

write_aws_mock() {
  cat > "${MOCK_DIR}/aws" <<MOCK
#!/bin/bash
$1
MOCK
  chmod +x "${MOCK_DIR}/aws"
}

# Run the runtime smoke script with mocked PATH, capture output and exit code.
# Returns the script's exit code; stdout contains the script's combined output.
run_script() {
  local exit_code=0
  local output
  output=$(PATH="${MOCK_DIR}:${PATH}" bash "$RUNTIME_SCRIPT" \
    --env-file "$MOCK_ENV_FILE" \
    --ami-id ami-test1234567890abcdef0 \
    "$@" 2>&1) || exit_code=$?
  echo "$output"
  return "$exit_code"
}

echo ""
echo "=== Stage 7 Preflight Behavioral Tests ==="

# ---------- AWS credential validation ----------
echo ""
echo "--- AWS credentials invalid → exit 10 ---"

setup
write_aws_mock 'exit 255'

output=""
exit_code=0
output=$(run_script) || exit_code=$?

if [[ "$exit_code" -eq 10 ]]; then
  pass "Invalid AWS credentials exits with code 10"
else
  fail "Invalid AWS credentials exits with code 10 (got $exit_code)"
fi
if echo "$output" | rg -q 'PREFLIGHT FAIL \[aws_creds\]'; then
  pass "AWS credential failure outputs PREFLIGHT FAIL [aws_creds]"
else
  fail "AWS credential failure outputs PREFLIGHT FAIL [aws_creds]"
fi
if echo "$output" | rg -q 'aws sts get-caller-identity'; then
  pass "AWS credential remediation mentions sts command"
else
  fail "AWS credential remediation mentions sts command"
fi
teardown

# ---------- AMI missing ----------
echo ""
echo "--- Missing AMI → exit 13 ---"

setup
write_aws_mock 'if [[ "$1" == "sts" ]]; then
  echo "123456789012  arn:aws:iam::123456789012:user/test  AIDAEXAMPLE"
  exit 0
fi
if [[ "$1" == "ec2" && "$2" == "describe-images" ]]; then
  echo "0"
  exit 0
fi
echo "mock-unhandled: $*" >&2
exit 1'

output=""
exit_code=0
output=$(run_script) || exit_code=$?

if [[ "$exit_code" -eq 13 ]]; then
  pass "Missing AMI exits with code 13"
else
  fail "Missing AMI exits with code 13 (got $exit_code)"
fi
if echo "$output" | rg -q 'PREFLIGHT FAIL \[ami_exists\]'; then
  pass "Missing AMI outputs PREFLIGHT FAIL [ami_exists]"
else
  fail "Missing AMI outputs PREFLIGHT FAIL [ami_exists]"
fi
if echo "$output" | rg -qi 'packer'; then
  pass "Missing AMI remediation mentions Packer build"
else
  fail "Missing AMI remediation mentions Packer build"
fi
teardown

# ---------- S3 release artifact missing ----------
echo ""
echo "--- Missing S3 release artifact → exit 12 ---"

setup
write_aws_mock 'if [[ "$1" == "sts" ]]; then
  echo "123456789012  arn:aws:iam::123456789012:user/test  AIDAEXAMPLE"
  exit 0
fi
if [[ "$1" == "ec2" && "$2" == "describe-images" ]]; then
  echo "1"
  exit 0
fi
if [[ "$1" == "s3api" ]]; then
  echo "0"
  exit 0
fi
echo "mock-unhandled: $*" >&2
exit 1'

output=""
exit_code=0
output=$(run_script --release-sha "$FAKE_SHA") || exit_code=$?

if [[ "$exit_code" -eq 12 ]]; then
  pass "Missing S3 artifact exits with code 12"
else
  fail "Missing S3 artifact exits with code 12 (got $exit_code)"
fi
if echo "$output" | rg -q 'PREFLIGHT FAIL \[release_artifact\]'; then
  pass "Missing artifact outputs PREFLIGHT FAIL [release_artifact]"
else
  fail "Missing artifact outputs PREFLIGHT FAIL [release_artifact]"
fi
if echo "$output" | rg -q 's3://'; then
  pass "Missing artifact remediation mentions S3 bucket path"
else
  fail "Missing artifact remediation mentions S3 bucket path"
fi
teardown

# ---------- Cloudflare token missing ----------
echo ""
echo "--- Cloudflare token missing → exit 11 ---"

setup
sed -i.bak '/^CLOUDFLARE_API_TOKEN=/d; /^CLOUDFLARE_EDIT_READ_ZONE_DNS_API_TOKEN_FLAPJACK_FOO=/d' "$MOCK_ENV_FILE"
write_aws_mock 'if [[ "$1" == "sts" ]]; then
  echo "123456789012  arn:aws:iam::123456789012:user/test  AIDAEXAMPLE"
  exit 0
fi
if [[ "$1" == "ec2" && "$2" == "describe-images" ]]; then
  echo "1"
  exit 0
fi
echo "mock-unhandled: $*" >&2
exit 1'

output=""
exit_code=0
output=$(run_script) || exit_code=$?

if [[ "$exit_code" -eq 11 ]]; then
  pass "Cloudflare token missing exits with code 11"
else
  fail "Cloudflare token missing exits with code 11 (got $exit_code)"
fi
if echo "$output" | rg -q 'PREFLIGHT FAIL \[cloudflare_dns\]'; then
  pass "Cloudflare token missing outputs PREFLIGHT FAIL [cloudflare_dns]"
else
  fail "Cloudflare token missing outputs PREFLIGHT FAIL [cloudflare_dns]"
fi
if echo "$output" | rg -q 'CLOUDFLARE_API_TOKEN'; then
  pass "Cloudflare token missing remediation mentions CLOUDFLARE_API_TOKEN"
else
  fail "Cloudflare token missing remediation mentions CLOUDFLARE_API_TOKEN"
fi
if echo "$output" | rg -q 'CLOUDFLARE_EDIT_READ_ZONE_DNS_API_TOKEN_FLAPJACK_FOO'; then
  pass "Cloudflare token missing remediation mentions flapjack.foo token alias"
else
  fail "Cloudflare token missing remediation mentions flapjack.foo token alias"
fi
teardown

# ---------- Cloudflare zone/domain mismatch ----------
echo ""
echo "--- Cloudflare zone/domain mismatch → exit 11 ---"

setup
write_aws_mock 'if [[ "$1" == "sts" ]]; then
  echo "123456789012  arn:aws:iam::123456789012:user/test  AIDAEXAMPLE"
  exit 0
fi
if [[ "$1" == "ec2" && "$2" == "describe-images" ]]; then
  echo "1"
  exit 0
fi
echo "mock-unhandled: $*" >&2
exit 1'

cat > "${MOCK_DIR}/curl" <<'CURLMOCK'
#!/bin/bash
if [[ "$*" == *"api.cloudflare.com/client/v4/zones/cf_zone_foo_test"* ]]; then
  printf '{"success":true,"result":{"id":"cf_zone_foo_test","name":"wrong.example"}}'
  exit 0
fi
exit 0
CURLMOCK
chmod +x "${MOCK_DIR}/curl"

output=""
exit_code=0
output=$(run_script) || exit_code=$?

if [[ "$exit_code" -eq 11 ]]; then
  pass "Cloudflare zone/domain mismatch exits with code 11"
else
  fail "Cloudflare zone/domain mismatch exits with code 11 (got $exit_code)"
fi
if echo "$output" | rg -q 'PREFLIGHT FAIL \[cloudflare_dns\]'; then
  pass "Cloudflare zone/domain mismatch outputs PREFLIGHT FAIL [cloudflare_dns]"
else
  fail "Cloudflare zone/domain mismatch outputs PREFLIGHT FAIL [cloudflare_dns]"
fi
if echo "$output" | rg -qi 'Cloudflare zone|flapjack\.foo|wrong\.example'; then
  pass "Cloudflare zone/domain mismatch remediation mentions zone/domain"
else
  fail "Cloudflare zone/domain mismatch remediation mentions zone/domain"
fi
teardown

# ---------- All preflight checks pass ----------
echo ""
echo "--- All preflight checks pass with valid mocks ---"

setup
write_aws_mock 'if [[ "$1" == "sts" ]]; then
  echo "123456789012  arn:aws:iam::123456789012:user/test  AIDAEXAMPLE"
  exit 0
fi
if [[ "$1" == "ec2" && "$2" == "describe-images" ]]; then
  echo "1"
  exit 0
fi
if [[ "$1" == "s3api" ]]; then
  echo "1"
  exit 0
fi
if [[ "$1" == "acm" && "$2" == "list-certificates" ]]; then
  echo "arn:aws:acm:us-east-1:123456789012:certificate/test"
  exit 0
fi
if [[ "$1" == "acm" && "$2" == "describe-certificate" ]]; then
  echo "ISSUED"
  exit 0
fi
if [[ "$1" == "elbv2" && "$2" == "describe-load-balancers" ]]; then
  echo "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/test/1234"
  exit 0
fi
if [[ "$1" == "elbv2" && "$2" == "describe-listeners" ]]; then
  echo "1"
  exit 0
fi
if [[ "$1" == "elbv2" && "$2" == "describe-target-groups" ]]; then
  echo "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/test/1234"
  exit 0
fi
if [[ "$1" == "elbv2" && "$2" == "describe-target-health" ]]; then
  echo "1"
  exit 0
fi
if [[ "$1" == "sesv2" && "$2" == "get-email-identity" ]]; then
  printf "SUCCESS\tSUCCESS\n"
  exit 0
fi
exit 0'

output=""
exit_code=0
output=$(run_script --release-sha "$FAKE_SHA") || exit_code=$?

if [[ "$exit_code" -eq 0 ]]; then
  pass "All preflight checks pass with valid mocks (exit 0)"
else
  fail "All preflight checks pass with valid mocks (got exit $exit_code)"
  echo "--- script output ---"
  echo "$output" | tail -20
  echo "--- end ---"
fi
teardown

test_summary "Stage 7 preflight behavioral"
