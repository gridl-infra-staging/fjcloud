#!/usr/bin/env bash
# Behavioral tests for runtime smoke assertions in tests_stage7_runtime_smoke.sh.
# Exercises ACM, ALB, target-group, health, deploy, migrate, and rollback paths
# via mock AWS/curl/terraform/bash commands — no live infrastructure required.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNTIME_SCRIPT="${SCRIPT_DIR}/tests_stage7_runtime_smoke.sh"

MOCK_DIR=""
MOCK_ENV_FILE=""
FAKE_SHA="a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
PREV_SHA="b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3"
RUN_SCRIPT_HEALTH_MAX_RETRIES=1
RUN_SCRIPT_HEALTH_RETRY_INTERVAL=0
RUN_SCRIPT_DEPLOY_HEALTH_MAX_CHECKS=
RUN_SCRIPT_TG_MAX_RETRIES=1
RUN_SCRIPT_TG_RETRY_INTERVAL=0

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

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

  cat > "${MOCK_DIR}/terraform" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"${MOCK_DIR}/terraform.log"
exit 0
EOF
  chmod +x "${MOCK_DIR}/terraform"

  printf '#!/bin/bash\nexit 0\n' > "${MOCK_DIR}/dig"
  chmod +x "${MOCK_DIR}/dig"

  # curl: succeed by default for both Cloudflare DNS API checks and health.
  cat > "${MOCK_DIR}/curl" <<'CURLMOCK'
#!/bin/bash
request="$*"
if [[ "$request" == *"-K -"* ]]; then
  request="${request} $(cat)"
fi
if [[ "$request" == *"api.cloudflare.com/client/v4/zones/cf_zone_foo_test/dns_records"* ]]; then
  printf '{"success":true,"result":[{"name":"flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com","proxied":false},{"name":"api.flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com","proxied":false},{"name":"www.flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com","proxied":false},{"name":"cloud.flapjack.foo","type":"CNAME","content":"staging.flapjack-cloud.pages.dev","proxied":true},{"name":"staging.flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com","proxied":false},{"name":"api.staging.flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com","proxied":false},{"name":"www.staging.flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com","proxied":false},{"name":"cloud.staging.flapjack.foo","type":"CNAME","content":"staging.flapjack-cloud.pages.dev","proxied":true}]}'
  exit 0
fi
if [[ "$request" == *"api.cloudflare.com/client/v4/zones/cf_zone_foo_test"* ]]; then
  printf '{"success":true,"result":{"id":"cf_zone_foo_test","name":"flapjack.foo"}}'
  exit 0
fi
echo "{}"
exit 0
CURLMOCK
  chmod +x "${MOCK_DIR}/curl"

  # Mock deploy/migrate/rollback scripts — succeed by default
  mkdir -p "${MOCK_DIR}/scripts"
  printf '#!/bin/bash\necho "mock deploy: $*"\nexit 0\n' \
    > "${MOCK_DIR}/scripts/deploy.sh"
  printf '#!/bin/bash\necho "mock migrate: $*"\nexit 0\n' \
    > "${MOCK_DIR}/scripts/migrate.sh"
  printf '#!/bin/bash\necho "mock rollback: $*"\nexit 0\n' \
    > "${MOCK_DIR}/scripts/rollback.sh"
  chmod +x "${MOCK_DIR}/scripts/"*.sh

  # dig: return NS records matching the default route53 mock
  cat > "${MOCK_DIR}/dig" <<'DIGMOCK'
#!/bin/bash
echo "ns-1.awsdns-01.org."
echo "ns-2.awsdns-02.co.uk."
DIGMOCK
  chmod +x "${MOCK_DIR}/dig"

  RUN_SCRIPT_HEALTH_MAX_RETRIES=1
  RUN_SCRIPT_HEALTH_RETRY_INTERVAL=0
  RUN_SCRIPT_DEPLOY_HEALTH_MAX_CHECKS=
  RUN_SCRIPT_TG_MAX_RETRIES=1
  RUN_SCRIPT_TG_RETRY_INTERVAL=0
}

teardown() {
  rm -rf "$MOCK_DIR" "$MOCK_ENV_FILE"
}

# ---------------------------------------------------------------------------
# AWS mock helpers
# ---------------------------------------------------------------------------

# Write a fully-passing AWS mock for all preflight + runtime checks.
# Callers can override individual branches by writing a new aws mock after this.
write_full_pass_aws_mock() {
  cat > "${MOCK_DIR}/aws" <<'MOCK'
#!/bin/bash
case "$1" in
  sts)
    echo "123456789012  arn:aws:iam::123456789012:user/test  AIDAEXAMPLE"
    exit 0 ;;
  ec2)
    [[ "$2" == "describe-images" ]] && echo "1" && exit 0
    echo "mock-ec2-unhandled: $*" >&2; exit 1 ;;
  s3api)
    echo "1"; exit 0 ;;
  route53)
    if [[ "$2" == "list-hosted-zones-by-name" ]]; then
      echo "/hostedzone/Z1234567890"; exit 0
    fi
    if [[ "$2" == "get-hosted-zone" ]]; then
      printf "ns-1.awsdns-01.org\tns-2.awsdns-02.co.uk"; exit 0
    fi
    echo "mock-route53-unhandled: $*" >&2; exit 1 ;;
  acm)
    if [[ "$2" == "list-certificates" ]]; then
      echo "arn:aws:acm:us-east-1:123456789012:certificate/test"; exit 0
    fi
    if [[ "$2" == "describe-certificate" ]]; then
      echo "ISSUED"; exit 0
    fi
    echo "mock-acm-unhandled: $*" >&2; exit 1 ;;
  elbv2)
    if [[ "$2" == "describe-load-balancers" ]]; then
      echo "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/fjcloud-staging-alb/abc123"
      exit 0
    fi
    if [[ "$2" == "describe-listeners" ]]; then
      echo "1"; exit 0
    fi
    if [[ "$2" == "describe-target-groups" ]]; then
      echo "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/fjcloud-staging-api-tg/xyz"
      exit 0
    fi
    if [[ "$2" == "describe-target-health" ]]; then
      echo "1"; exit 0
    fi
    echo "mock-elbv2-unhandled: $*" >&2; exit 1 ;;
  sesv2)
    [[ "$2" == "get-email-identity" ]] && printf "SUCCESS\tSUCCESS\n" && exit 0
    echo "mock-sesv2-unhandled: $*" >&2; exit 1 ;;
  *)
    echo "mock-aws-unhandled: $*" >&2; exit 1 ;;
esac
MOCK
  chmod +x "${MOCK_DIR}/aws"
}

# Run the runtime smoke script with mocked PATH and scripts dir.
# Exports FJCLOUD_SCRIPTS_DIR so the smoke script uses mock deploy/migrate/rollback.
run_script() {
  local exit_code=0
  local output
  local health_max_retries="${RUN_SCRIPT_HEALTH_MAX_RETRIES:-1}"
  local health_retry_interval="${RUN_SCRIPT_HEALTH_RETRY_INTERVAL:-0}"
  local deploy_probe_checks="${RUN_SCRIPT_DEPLOY_HEALTH_MAX_CHECKS:-$health_max_retries}"
  output=$(FJCLOUD_SCRIPTS_DIR="${MOCK_DIR}/scripts" \
    FJCLOUD_RUNTIME_SMOKE_ARTIFACT_DIR="${MOCK_DIR}/artifacts" \
    HEALTH_MAX_RETRIES="$health_max_retries" \
    HEALTH_RETRY_INTERVAL="$health_retry_interval" \
    DEPLOY_HEALTH_MAX_CHECKS="$deploy_probe_checks" \
    TG_MAX_RETRIES="${RUN_SCRIPT_TG_MAX_RETRIES:-1}" \
    TG_RETRY_INTERVAL="${RUN_SCRIPT_TG_RETRY_INTERVAL:-0}" \
    PATH="${MOCK_DIR}:${PATH}" \
    bash "$RUNTIME_SCRIPT" \
    --env-file "$MOCK_ENV_FILE" \
    --api-ami-id ami-test1234567890abcdef0 \
    --flapjack-ami-id ami-test1234567890abcdef1 \
    "$@" 2>&1) || exit_code=$?
  echo "$output"
  return "$exit_code"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

echo ""
echo "=== Stage 7 Runtime Behavioral Tests ==="

echo ""
echo "--- Terraform plan receives distinct API and Flapjack AMIs ---"

setup
write_full_pass_aws_mock
output=""
exit_code=0
output=$(run_script \
  --api-ami-id ami-0aaa1111222233334 \
  --flapjack-ami-id ami-0bbb1111222233335) || exit_code=$?

terraform_log="$(cat "${MOCK_DIR}/terraform.log" 2>/dev/null || true)"
if [[ "$exit_code" -eq 0 ]]; then
  pass "Distinct AMI runtime plan exits 0"
else
  fail "Distinct AMI runtime plan exits 0 (got $exit_code): $output"
fi
if compgen -G "${MOCK_DIR}/artifacts/plan_staging_*.txt" >/dev/null && \
  compgen -G "${MOCK_DIR}/artifacts/evidence_staging_*.jsonl" >/dev/null; then
  pass "Runtime unit artifacts stay inside the isolated test workspace"
else
  fail "Runtime unit artifacts stay inside the isolated test workspace"
fi
if echo "$terraform_log" | rg -q 'api_ami_id=ami-0aaa1111222233334'; then
  pass "Runtime plan passes distinct API AMI to Terraform"
else
  fail "Runtime plan passes distinct API AMI to Terraform"
fi
if echo "$terraform_log" | rg -q 'flapjack_ami_id=ami-0bbb1111222233335'; then
  pass "Runtime plan passes distinct Flapjack AMI to Terraform"
else
  fail "Runtime plan passes distinct Flapjack AMI to Terraform"
fi
if echo "$terraform_log" | rg -q 'api_ami_id=ami-0bbb1111222233335|flapjack_ami_id=ami-0aaa1111222233334'; then
  fail "Runtime plan does not swap API and Flapjack AMIs"
else
  pass "Runtime plan does not swap API and Flapjack AMIs"
fi
teardown

# ---------- Terraform state alert subscriptions are preserved ----------
echo ""
echo "--- Runtime plan preserves alert email subscriptions from state ---"

setup
write_full_pass_aws_mock
cat > "${MOCK_DIR}/terraform" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"${MOCK_DIR}/terraform.log"
if [[ "\$1 \$2" == "state list" ]]; then
  printf '%s\n' 'module.monitoring.aws_sns_topic_subscription.email["ops@example.com"]'
fi
exit 0
EOF
chmod +x "${MOCK_DIR}/terraform"

output=""
exit_code=0
output=$(run_script \
  --api-ami-id ami-0aaa1111222233334 \
  --flapjack-ami-id ami-0bbb1111222233335) || exit_code=$?

terraform_log="$(cat "${MOCK_DIR}/terraform.log" 2>/dev/null || true)"
if [[ "$exit_code" -eq 0 ]]; then
  pass "State-preserved alert email runtime plan exits 0"
else
  fail "State-preserved alert email runtime plan exits 0 (got $exit_code): $output"
fi
if echo "$terraform_log" | rg -Fq 'state list'; then
  pass "Runtime plan reads Terraform state for alert subscriptions"
else
  fail "Runtime plan reads Terraform state for alert subscriptions"
fi
if echo "$terraform_log" | rg -Fq 'alert_emails=["ops@example.com"]'; then
  pass "Runtime plan preserves existing alert email subscriptions"
else
  fail "Runtime plan preserves existing alert email subscriptions"
fi
teardown

# ---------- ACM certificate not ISSUED → exit 20 ----------
echo ""
echo "--- ACM cert not ISSUED → exit 20 ---"

setup
write_full_pass_aws_mock
# Override: acm describe-certificate returns non-ISSUED status
cat > "${MOCK_DIR}/aws" <<'MOCK'
#!/bin/bash
case "$1" in
  sts) echo "123456789012  arn: test  AIDAEXAMPLE"; exit 0 ;;
  ec2) [[ "$2" == "describe-images" ]] && echo "1" && exit 0; exit 1 ;;
  route53)
    [[ "$2" == "list-hosted-zones-by-name" ]] && echo "/hostedzone/Z1234" && exit 0
    [[ "$2" == "get-hosted-zone" ]] && printf "ns-1.awsdns-01.org\tns-2.awsdns-02.co.uk" && exit 0
    exit 1 ;;
  acm)
    [[ "$2" == "list-certificates" ]] && echo "arn:aws:acm:us-east-1:123456789012:certificate/test" && exit 0
    [[ "$2" == "describe-certificate" ]] && echo "PENDING_VALIDATION" && exit 0
    exit 1 ;;
  elbv2)
    [[ "$2" == "describe-load-balancers" ]] && echo "arn:lb" && exit 0
    [[ "$2" == "describe-listeners" ]] && echo "1" && exit 0
    [[ "$2" == "describe-target-groups" ]] && echo "arn:tg" && exit 0
    [[ "$2" == "describe-target-health" ]] && echo "1" && exit 0
    exit 1 ;;
  *) echo "unhandled: $*" >&2; exit 1 ;;
esac
MOCK
chmod +x "${MOCK_DIR}/aws"

output=""
exit_code=0
output=$(run_script) || exit_code=$?

if [[ "$exit_code" -eq 20 ]]; then
  pass "ACM cert not ISSUED exits with code 20"
else
  fail "ACM cert not ISSUED exits with code 20 (got $exit_code)"
fi
if echo "$output" | rg -q 'RUNTIME FAIL \[acm_not_issued\]'; then
  pass "ACM not-ISSUED outputs RUNTIME FAIL [acm_not_issued]"
else
  fail "ACM not-ISSUED outputs RUNTIME FAIL [acm_not_issued]"
fi
if echo "$output" | rg -qi 'PENDING_VALIDATION|dns.validation|certificate'; then
  pass "ACM not-ISSUED remediation mentions cert/validation state"
else
  fail "ACM not-ISSUED remediation mentions cert/validation state"
fi
teardown

# ---------- No ALB HTTPS listener → exit 21 ----------
echo ""
echo "--- No ALB HTTPS listener → exit 21 ---"

setup
write_full_pass_aws_mock
cat > "${MOCK_DIR}/aws" <<'MOCK'
#!/bin/bash
case "$1" in
  sts) echo "123456789012  arn: test  AIDAEXAMPLE"; exit 0 ;;
  ec2) [[ "$2" == "describe-images" ]] && echo "1" && exit 0; exit 1 ;;
  route53)
    [[ "$2" == "list-hosted-zones-by-name" ]] && echo "/hostedzone/Z1234" && exit 0
    [[ "$2" == "get-hosted-zone" ]] && printf "ns-1.awsdns-01.org\tns-2.awsdns-02.co.uk" && exit 0
    exit 1 ;;
  acm)
    [[ "$2" == "list-certificates" ]] && echo "arn:aws:acm:us-east-1:123456789012:certificate/test" && exit 0
    [[ "$2" == "describe-certificate" ]] && echo "ISSUED" && exit 0
    exit 1 ;;
  elbv2)
    [[ "$2" == "describe-load-balancers" ]] && echo "arn:lb" && exit 0
    [[ "$2" == "describe-listeners" ]] && echo "0" && exit 0  # ← 0 listeners
    [[ "$2" == "describe-target-groups" ]] && echo "arn:tg" && exit 0
    [[ "$2" == "describe-target-health" ]] && echo "1" && exit 0
    exit 1 ;;
  *) echo "unhandled: $*" >&2; exit 1 ;;
esac
MOCK
chmod +x "${MOCK_DIR}/aws"

output=""
exit_code=0
output=$(run_script) || exit_code=$?

if [[ "$exit_code" -eq 21 ]]; then
  pass "No ALB HTTPS listener exits with code 21"
else
  fail "No ALB HTTPS listener exits with code 21 (got $exit_code)"
fi
if echo "$output" | rg -q 'RUNTIME FAIL \[alb_no_listener\]'; then
  pass "No ALB listener outputs RUNTIME FAIL [alb_no_listener]"
else
  fail "No ALB listener outputs RUNTIME FAIL [alb_no_listener]"
fi
if echo "$output" | rg -qi '443|HTTPS|listener'; then
  pass "No ALB listener remediation mentions 443/HTTPS"
else
  fail "No ALB listener remediation mentions 443/HTTPS"
fi
teardown

# ---------- Unhealthy target group → exit 22 ----------
echo ""
echo "--- Unhealthy target group → exit 22 ---"

setup
write_full_pass_aws_mock
cat > "${MOCK_DIR}/aws" <<'MOCK'
#!/bin/bash
case "$1" in
  sts) echo "123456789012  arn: test  AIDAEXAMPLE"; exit 0 ;;
  ec2) [[ "$2" == "describe-images" ]] && echo "1" && exit 0; exit 1 ;;
  route53)
    [[ "$2" == "list-hosted-zones-by-name" ]] && echo "/hostedzone/Z1234" && exit 0
    [[ "$2" == "get-hosted-zone" ]] && printf "ns-1.awsdns-01.org\tns-2.awsdns-02.co.uk" && exit 0
    exit 1 ;;
  acm)
    [[ "$2" == "list-certificates" ]] && echo "arn:aws:acm:us-east-1:123456789012:certificate/test" && exit 0
    [[ "$2" == "describe-certificate" ]] && echo "ISSUED" && exit 0
    exit 1 ;;
  elbv2)
    [[ "$2" == "describe-load-balancers" ]] && echo "arn:lb" && exit 0
    [[ "$2" == "describe-listeners" ]] && echo "1" && exit 0
    [[ "$2" == "describe-target-groups" ]] && echo "arn:tg" && exit 0
    [[ "$2" == "describe-target-health" ]] && echo "0" && exit 0  # ← 0 healthy targets
    exit 1 ;;
  *) echo "unhandled: $*" >&2; exit 1 ;;
esac
MOCK
chmod +x "${MOCK_DIR}/aws"

output=""
exit_code=0
output=$(run_script) || exit_code=$?

if [[ "$exit_code" -eq 22 ]]; then
  pass "Unhealthy target group exits with code 22"
else
  fail "Unhealthy target group exits with code 22 (got $exit_code)"
fi
if echo "$output" | rg -q 'RUNTIME FAIL \[tg_unhealthy\]'; then
  pass "Unhealthy TG outputs RUNTIME FAIL [tg_unhealthy]"
else
  fail "Unhealthy TG outputs RUNTIME FAIL [tg_unhealthy]"
fi
if echo "$output" | rg -qi 'health|instance|target'; then
  pass "Unhealthy TG remediation mentions health/instance/target"
else
  fail "Unhealthy TG remediation mentions health/instance/target"
fi
teardown

# ---------- Target group registration settles before timeout → exit 0 ----------
echo ""
echo "--- Target group registration settles before timeout → exit 0 ---"

setup
write_full_pass_aws_mock
RUN_SCRIPT_TG_MAX_RETRIES=3
RUN_SCRIPT_TG_RETRY_INTERVAL=0
cat > "${MOCK_DIR}/aws" <<'MOCK'
#!/bin/bash
STATE_FILE="$(cd "$(dirname "$0")" && pwd)/tg_retry_state"
case "$1" in
  sts) echo "123456789012  arn: test  AIDAEXAMPLE"; exit 0 ;;
  ec2) [[ "$2" == "describe-images" ]] && echo "1" && exit 0; exit 1 ;;
  route53)
    [[ "$2" == "list-hosted-zones-by-name" ]] && echo "/hostedzone/Z1234" && exit 0
    [[ "$2" == "get-hosted-zone" ]] && printf "ns-1.awsdns-01.org\tns-2.awsdns-02.co.uk" && exit 0
    exit 1 ;;
  acm)
    [[ "$2" == "list-certificates" ]] && echo "arn:aws:acm:us-east-1:123456789012:certificate/test" && exit 0
    [[ "$2" == "describe-certificate" ]] && echo "ISSUED" && exit 0
    exit 1 ;;
  elbv2)
    if [[ "$2" == "describe-load-balancers" ]]; then
      echo "arn:lb"; exit 0
    fi
    if [[ "$2" == "describe-listeners" ]]; then
      echo "1"; exit 0
    fi
    if [[ "$2" == "describe-target-groups" ]]; then
      echo "arn:tg"; exit 0
    fi
    if [[ "$2" == "describe-target-health" ]]; then
      count=0
      if [[ -f "$STATE_FILE" ]]; then
        count=$(cat "$STATE_FILE")
      fi
      count=$((count + 1))
      printf '%s' "$count" > "$STATE_FILE"
      if [[ "$count" -lt 2 ]]; then
        echo "0"; exit 0
      fi
      echo "1"; exit 0
    fi
    exit 1 ;;
  sesv2)
    [[ "$2" == "get-email-identity" ]] && printf "SUCCESS\tSUCCESS\n" && exit 0
    exit 1 ;;
  *) echo "unhandled: $*" >&2; exit 1 ;;
esac
MOCK
chmod +x "${MOCK_DIR}/aws"

output=""
exit_code=0
output=$(run_script) || exit_code=$?

if [[ "$exit_code" -eq 0 ]]; then
  pass "Target group registration retry exits 0 once healthy"
else
  fail "Target group registration retry exits 0 once healthy (got $exit_code)"
fi
if ! echo "$output" | rg -q 'RUNTIME FAIL \[tg_unhealthy\]'; then
  pass "Target group registration retry avoids tg_unhealthy failure"
else
  fail "Target group registration retry avoids tg_unhealthy failure"
fi
teardown

# ---------- Cloudflare public record mismatch → exit 27 ----------
echo ""
echo "--- Cloudflare public record mismatch → exit 27 ---"

setup
write_full_pass_aws_mock
cat > "${MOCK_DIR}/curl" <<'CURLMOCK'
#!/bin/bash
request="$*"
if [[ "$request" == *"-K -"* ]]; then
  request="${request} $(cat)"
fi
if [[ "$request" == *"api.cloudflare.com/client/v4/zones/cf_zone_foo_test/dns_records"* ]]; then
  printf '{"success":true,"result":[{"name":"api.flapjack.foo","type":"CNAME","content":"wrong.example.com"}]}'
  exit 0
fi
if [[ "$request" == *"api.cloudflare.com/client/v4/zones/cf_zone_foo_test"* ]]; then
  printf '{"success":true,"result":{"id":"cf_zone_foo_test","name":"flapjack.foo"}}'
  exit 0
fi
echo "{}"
exit 0
CURLMOCK
chmod +x "${MOCK_DIR}/curl"

output=""
exit_code=0
output=$(run_script) || exit_code=$?

if [[ "$exit_code" -eq 27 ]]; then
  pass "Cloudflare public record mismatch exits with code 27"
else
  fail "Cloudflare public record mismatch exits with code 27 (got $exit_code)"
fi
if echo "$output" | rg -q 'RUNTIME FAIL \[dns_record_mismatch\]'; then
  pass "Cloudflare public record mismatch outputs RUNTIME FAIL [dns_record_mismatch]"
else
  fail "Cloudflare public record mismatch outputs RUNTIME FAIL [dns_record_mismatch]"
fi
if echo "$output" | rg -qi 'Cloudflare|api\.flapjack\.foo|ALB'; then
  pass "Cloudflare public record mismatch remediation mentions Cloudflare/ALB"
else
  fail "Cloudflare public record mismatch remediation mentions Cloudflare/ALB"
fi
teardown

# ---------- Cloudflare public records on wrong env ALB → exit 27 ----------
echo ""
echo "--- Cloudflare public records on wrong env ALB → exit 27 ---"

setup
write_full_pass_aws_mock
cat > "${MOCK_DIR}/curl" <<'CURLMOCK'
#!/bin/bash
request="$*"
if [[ "$request" == *"-K -"* ]]; then
  request="${request} $(cat)"
fi
if [[ "$request" == *"api.cloudflare.com/client/v4/zones/cf_zone_foo_test/dns_records"* ]]; then
  printf '{"success":true,"result":[{"name":"flapjack.foo","type":"CNAME","content":"fjcloud-prod-alb-1846218892.us-east-1.elb.amazonaws.com","proxied":false},{"name":"api.flapjack.foo","type":"CNAME","content":"fjcloud-prod-alb-1846218892.us-east-1.elb.amazonaws.com","proxied":false},{"name":"www.flapjack.foo","type":"CNAME","content":"fjcloud-prod-alb-1846218892.us-east-1.elb.amazonaws.com","proxied":false},{"name":"cloud.flapjack.foo","type":"CNAME","content":"staging.flapjack-cloud.pages.dev","proxied":true}]}'
  exit 0
fi
if [[ "$request" == *"api.cloudflare.com/client/v4/zones/cf_zone_foo_test"* ]]; then
  printf '{"success":true,"result":{"id":"cf_zone_foo_test","name":"flapjack.foo"}}'
  exit 0
fi
echo "{}"
exit 0
CURLMOCK
chmod +x "${MOCK_DIR}/curl"

output=""
exit_code=0
output=$(run_script) || exit_code=$?

if [[ "$exit_code" -eq 27 ]]; then
  pass "Cloudflare wrong-env ALB records exit with code 27"
else
  fail "Cloudflare wrong-env ALB records exit with code 27 (got $exit_code)"
fi
if echo "$output" | rg -q 'fjcloud-staging-alb'; then
  pass "Cloudflare wrong-env ALB remediation names the expected staging ALB"
else
  fail "Cloudflare wrong-env ALB remediation names the expected staging ALB"
fi
teardown

# ---------- Staging root input ignores prod-root DNS records ----------
echo ""
echo "--- Staging root input validates staging subdomain records ---"

setup
write_full_pass_aws_mock
cat > "${MOCK_DIR}/curl" <<'CURLMOCK'
#!/bin/bash
request="$*"
if [[ "$request" == *"-K -"* ]]; then
  request="${request} $(cat)"
fi
if [[ "$request" == *"api.cloudflare.com/client/v4/zones/cf_zone_foo_test/dns_records"* ]]; then
  printf '{"success":true,"result":[{"name":"flapjack.foo","type":"CNAME","content":"fjcloud-prod-alb-1846218892.us-east-1.elb.amazonaws.com","proxied":false},{"name":"api.flapjack.foo","type":"CNAME","content":"fjcloud-prod-alb-1846218892.us-east-1.elb.amazonaws.com","proxied":false},{"name":"www.flapjack.foo","type":"CNAME","content":"fjcloud-prod-alb-1846218892.us-east-1.elb.amazonaws.com","proxied":false},{"name":"cloud.flapjack.foo","type":"CNAME","content":"flapjack-cloud.pages.dev","proxied":true},{"name":"staging.flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com","proxied":false},{"name":"api.staging.flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com","proxied":false},{"name":"www.staging.flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com","proxied":false},{"name":"cloud.staging.flapjack.foo","type":"CNAME","content":"staging.flapjack-cloud.pages.dev","proxied":true}]}'
  exit 0
fi
if [[ "$request" == *"api.cloudflare.com/client/v4/zones/cf_zone_foo_test"* ]]; then
  printf '{"success":true,"result":{"id":"cf_zone_foo_test","name":"flapjack.foo"}}'
  exit 0
fi
echo "{}"
exit 0
CURLMOCK
chmod +x "${MOCK_DIR}/curl"

output=""
exit_code=0
output=$(run_script --env staging --domain flapjack.foo) || exit_code=$?

if [[ "$exit_code" -eq 0 ]]; then
  pass "Staging root input validates staging subdomain records"
else
  fail "Staging root input validates staging subdomain records (got $exit_code)"
  echo "--- output tail ---"
  echo "$output" | tail -20
  echo "--- end ---"
fi
if echo "$output" | rg -q 'https://api\.staging\.flapjack\.foo/health'; then
  pass "Staging root input uses staging health endpoint"
else
  fail "Staging root input uses staging health endpoint"
fi
teardown

# ---------- SES identity not verified → exit 28 ----------
echo ""
echo "--- SES identity not verified → exit 28 ---"

setup
write_full_pass_aws_mock
cat > "${MOCK_DIR}/aws" <<'MOCK'
#!/bin/bash
case "$1" in
  sts) echo "123456789012  arn: test  AIDAEXAMPLE"; exit 0 ;;
  ec2) [[ "$2" == "describe-images" ]] && echo "1" && exit 0; exit 1 ;;
  route53)
    [[ "$2" == "list-hosted-zones-by-name" ]] && echo "/hostedzone/Z1234" && exit 0
    [[ "$2" == "get-hosted-zone" ]] && printf "ns-1.awsdns-01.org\tns-2.awsdns-02.co.uk" && exit 0
    exit 1 ;;
  acm)
    [[ "$2" == "list-certificates" ]] && echo "arn:aws:acm:us-east-1:123456789012:certificate/test" && exit 0
    [[ "$2" == "describe-certificate" ]] && echo "ISSUED" && exit 0
    exit 1 ;;
  elbv2)
    [[ "$2" == "describe-load-balancers" ]] && echo "arn:lb" && exit 0
    [[ "$2" == "describe-listeners" ]] && echo "1" && exit 0
    [[ "$2" == "describe-target-groups" ]] && echo "arn:tg" && exit 0
    [[ "$2" == "describe-target-health" ]] && echo "1" && exit 0
    exit 1 ;;
  sesv2)
    [[ "$2" == "get-email-identity" ]] && printf "FAILED\tFAILED\n" && exit 0
    exit 1 ;;
  *) echo "unhandled: $*" >&2; exit 1 ;;
esac
MOCK
chmod +x "${MOCK_DIR}/aws"

output=""
exit_code=0
output=$(run_script) || exit_code=$?

if [[ "$exit_code" -eq 28 ]]; then
  pass "SES identity not verified exits with code 28"
else
  fail "SES identity not verified exits with code 28 (got $exit_code)"
fi
if echo "$output" | rg -q 'RUNTIME FAIL \[ses_not_verified\]'; then
  pass "SES identity not verified outputs RUNTIME FAIL [ses_not_verified]"
else
  fail "SES identity not verified outputs RUNTIME FAIL [ses_not_verified]"
fi
if echo "$output" | rg -qi 'SES|DKIM|flapjack\.foo'; then
  pass "SES identity not verified remediation mentions SES/DKIM/domain"
else
  fail "SES identity not verified remediation mentions SES/DKIM/domain"
fi
teardown

# ---------- Health endpoint non-200 → exit 23 ----------
echo ""
echo "--- Health endpoint non-200 → exit 23 ---"

setup
write_full_pass_aws_mock

# curl mock that passes Cloudflare checks, then fails health.
cat > "${MOCK_DIR}/curl" <<'CURLMOCK'
#!/bin/bash
request="$*"
if [[ "$request" == *"-K -"* ]]; then
  request="${request} $(cat)"
fi
if [[ "$request" == *"api.cloudflare.com/client/v4/zones/cf_zone_foo_test/dns_records"* ]]; then
  printf '{"success":true,"result":[{"name":"flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com","proxied":false},{"name":"api.flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com","proxied":false},{"name":"www.flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com","proxied":false},{"name":"cloud.flapjack.foo","type":"CNAME","content":"staging.flapjack-cloud.pages.dev","proxied":true},{"name":"staging.flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com","proxied":false},{"name":"api.staging.flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com","proxied":false},{"name":"www.staging.flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com","proxied":false},{"name":"cloud.staging.flapjack.foo","type":"CNAME","content":"staging.flapjack-cloud.pages.dev","proxied":true}]}'
  exit 0
fi
if [[ "$request" == *"api.cloudflare.com/client/v4/zones/cf_zone_foo_test"* ]]; then
  printf '{"success":true,"result":{"id":"cf_zone_foo_test","name":"flapjack.foo"}}'
  exit 0
fi
echo "service unavailable"
exit 1
CURLMOCK
chmod +x "${MOCK_DIR}/curl"

output=""
exit_code=0
output=$(run_script) || exit_code=$?

if [[ "$exit_code" -eq 23 ]]; then
  pass "Health endpoint non-200 exits with code 23"
else
  fail "Health endpoint non-200 exits with code 23 (got $exit_code)"
fi
if echo "$output" | rg -q 'RUNTIME FAIL \[health_fail\]'; then
  pass "Health failure outputs RUNTIME FAIL [health_fail]"
else
  fail "Health failure outputs RUNTIME FAIL [health_fail]"
fi
if echo "$output" | rg -qi 'https://api|health|curl'; then
  pass "Health failure remediation mentions health URL or curl"
else
  fail "Health failure remediation mentions health URL or curl"
fi
teardown

# ---------- Deploy with post-deploy health failure → exit 24 ----------
echo ""
echo "--- Deploy post-deploy health failure → exit 24 ---"

setup
write_full_pass_aws_mock

# curl: succeed on first call only, fail on second (post-deploy) call.
# Uses $PPID so all curl invocations from the same smoke script share the counter file.
cat > "${MOCK_DIR}/curl" <<'CURLMOCK'
#!/bin/bash
request="$*"
if [[ "$request" == *"-K -"* ]]; then
  request="${request} $(cat)"
fi
if [[ "$request" == *"api.cloudflare.com/client/v4/zones/cf_zone_foo_test/dns_records"* ]]; then
  printf '{"success":true,"result":[{"name":"flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com","proxied":false},{"name":"api.flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com","proxied":false},{"name":"www.flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com","proxied":false},{"name":"cloud.flapjack.foo","type":"CNAME","content":"staging.flapjack-cloud.pages.dev","proxied":true},{"name":"staging.flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com","proxied":false},{"name":"api.staging.flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com","proxied":false},{"name":"www.staging.flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com","proxied":false},{"name":"cloud.staging.flapjack.foo","type":"CNAME","content":"staging.flapjack-cloud.pages.dev","proxied":true}]}'
  exit 0
fi
if [[ "$request" == *"api.cloudflare.com/client/v4/zones/cf_zone_foo_test"* ]]; then
  printf '{"success":true,"result":{"id":"cf_zone_foo_test","name":"flapjack.foo"}}'
  exit 0
fi
COUNT_FILE="/tmp/curl_mock_count_${PPID}"
count=0
if [[ -f "$COUNT_FILE" ]]; then
  count=$(cat "$COUNT_FILE")
fi
count=$((count + 1))
echo "$count" > "$COUNT_FILE"
if [[ "$count" -le 1 ]]; then
  echo "{}"
  exit 0
fi
echo "service unavailable"
exit 1
CURLMOCK
chmod +x "${MOCK_DIR}/curl"

output=""
exit_code=0
output=$(run_script --run-deploy --release-sha "$FAKE_SHA") || exit_code=$?
rm -f /tmp/curl_mock_count_*

if [[ "$exit_code" -eq 24 ]]; then
  pass "Post-deploy health failure exits with code 24"
else
  fail "Post-deploy health failure exits with code 24 (got $exit_code)"
fi
if echo "$output" | rg -q 'RUNTIME FAIL \[deploy_health_fail\]'; then
  pass "Post-deploy health failure outputs RUNTIME FAIL [deploy_health_fail]"
else
  fail "Post-deploy health failure outputs RUNTIME FAIL [deploy_health_fail]"
fi
teardown

# ---------- Deploy rollout probe degradation → exit 24 ----------
echo ""
echo "--- Deploy rollout probe degradation → exit 24 ---"

setup
write_full_pass_aws_mock

cat > "${MOCK_DIR}/scripts/deploy.sh" <<'DEPMOCK'
#!/bin/bash
touch /tmp/rollout_probe_marker
sleep 1
rm -f /tmp/rollout_probe_marker
echo "mock deploy: $*"
exit 0
DEPMOCK
chmod +x "${MOCK_DIR}/scripts/deploy.sh"

cat > "${MOCK_DIR}/curl" <<'CURLMOCK'
#!/bin/bash
request="$*"
if [[ "$request" == *"-K -"* ]]; then
  request="${request} $(cat)"
fi
if [[ "$request" == *"api.cloudflare.com/client/v4/zones/cf_zone_foo_test/dns_records"* ]]; then
  printf '{"success":true,"result":[{"name":"flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com","proxied":false},{"name":"api.flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com","proxied":false},{"name":"www.flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com","proxied":false},{"name":"cloud.flapjack.foo","type":"CNAME","content":"staging.flapjack-cloud.pages.dev","proxied":true},{"name":"staging.flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com","proxied":false},{"name":"api.staging.flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com","proxied":false},{"name":"www.staging.flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com","proxied":false},{"name":"cloud.staging.flapjack.foo","type":"CNAME","content":"staging.flapjack-cloud.pages.dev","proxied":true}]}'
  exit 0
fi
if [[ "$request" == *"api.cloudflare.com/client/v4/zones/cf_zone_foo_test"* ]]; then
  printf '{"success":true,"result":{"id":"cf_zone_foo_test","name":"flapjack.foo"}}'
  exit 0
fi
if [[ -f /tmp/rollout_probe_marker ]]; then
  echo "service unavailable"
  exit 1
fi
echo "{}"
exit 0
CURLMOCK
chmod +x "${MOCK_DIR}/curl"

RUN_SCRIPT_HEALTH_MAX_RETRIES=3
RUN_SCRIPT_HEALTH_RETRY_INTERVAL=0
RUN_SCRIPT_DEPLOY_HEALTH_MAX_CHECKS=3
output=""
exit_code=0
output=$(run_script --run-deploy --release-sha "$FAKE_SHA") || exit_code=$?
rm -f /tmp/rollout_probe_marker

if [[ "$exit_code" -eq 24 ]]; then
  pass "Deploy rollout probe failure exits with code 24"
else
  fail "Deploy rollout probe failure exits with code 24 (got $exit_code)"
fi
if echo "$output" | rg -q 'RUNTIME FAIL \[deploy_health_fail\]'; then
  pass "Deploy rollout probe failure outputs RUNTIME FAIL [deploy_health_fail]"
else
  fail "Deploy rollout probe failure outputs RUNTIME FAIL [deploy_health_fail]"
fi
teardown

# ---------- Migration failure → exit 25 ----------
echo ""
echo "--- Migration failure → exit 25 ---"

setup
write_full_pass_aws_mock

# Override migrate.sh mock to fail
printf '#!/bin/bash\necho "migration FAILED: connection refused"\nexit 1\n' \
  > "${MOCK_DIR}/scripts/migrate.sh"
chmod +x "${MOCK_DIR}/scripts/migrate.sh"

output=""
exit_code=0
output=$(run_script --run-migrate) || exit_code=$?

if [[ "$exit_code" -eq 25 ]]; then
  pass "Migration failure exits with code 25"
else
  fail "Migration failure exits with code 25 (got $exit_code)"
fi
if echo "$output" | rg -q 'RUNTIME FAIL \[migrate_fail\]'; then
  pass "Migration failure outputs RUNTIME FAIL [migrate_fail]"
else
  fail "Migration failure outputs RUNTIME FAIL [migrate_fail]"
fi
teardown

# ---------- Migration non-idempotent (second run fails) → exit 25 ----------
echo ""
echo "--- Migration non-idempotent re-run → exit 25 ---"

setup
write_full_pass_aws_mock

# migrate mock: first call succeeds, second call fails (idempotency broken).
# Uses $PPID so both migrate invocations from the same smoke script share the counter file.
cat > "${MOCK_DIR}/scripts/migrate.sh" <<'MIGRATEMOCK'
#!/bin/bash
COUNT_FILE="/tmp/migrate_count_${PPID}"
count=0
[[ -f "$COUNT_FILE" ]] && count=$(cat "$COUNT_FILE")
count=$((count + 1))
echo "$count" > "$COUNT_FILE"
if [[ "$count" -eq 1 ]]; then
  echo "migrate run 1: success"
  exit 0
fi
echo "migrate run $count: FAILED (idempotency error)"
exit 1
MIGRATEMOCK
chmod +x "${MOCK_DIR}/scripts/migrate.sh"

output=""
exit_code=0
output=$(run_script --run-migrate) || exit_code=$?
rm -f /tmp/migrate_count_*

if [[ "$exit_code" -eq 25 ]]; then
  pass "Non-idempotent migration re-run exits with code 25"
else
  fail "Non-idempotent migration re-run exits with code 25 (got $exit_code)"
fi
if echo "$output" | rg -q 'RUNTIME FAIL \[migrate_idempotency\]'; then
  pass "Non-idempotent migration outputs RUNTIME FAIL [migrate_idempotency]"
else
  fail "Non-idempotent migration outputs RUNTIME FAIL [migrate_idempotency]"
fi
teardown

# ---------- Rollback failure → exit 26 ----------
echo ""
echo "--- Rollback failure → exit 26 ---"

setup
write_full_pass_aws_mock

# Override rollback.sh mock to fail
printf '#!/bin/bash\necho "rollback FAILED: instance unreachable"\nexit 1\n' \
  > "${MOCK_DIR}/scripts/rollback.sh"
chmod +x "${MOCK_DIR}/scripts/rollback.sh"

output=""
exit_code=0
output=$(run_script \
  --run-deploy --release-sha "$FAKE_SHA" \
  --run-rollback --rollback-sha "$PREV_SHA") || exit_code=$?

if [[ "$exit_code" -eq 26 ]]; then
  pass "Rollback failure exits with code 26"
else
  fail "Rollback failure exits with code 26 (got $exit_code)"
fi
if echo "$output" | rg -q 'RUNTIME FAIL \[rollback_fail\]'; then
  pass "Rollback failure outputs RUNTIME FAIL [rollback_fail]"
else
  fail "Rollback failure outputs RUNTIME FAIL [rollback_fail]"
fi
teardown

# ---------- Post-rollback health failure → exit 23 ----------
echo ""
echo "--- Post-rollback health failure → exit 23 ---"

setup
write_full_pass_aws_mock

# curl: fail only after rollback starts by marker file.
# Uses $PPID so all curl invocations from the same smoke script share the counter file.
cat > "${MOCK_DIR}/curl" <<'CURLMOCK'
#!/bin/bash
request="$*"
if [[ "$request" == *"-K -"* ]]; then
  request="${request} $(cat)"
fi
if [[ "$request" == *"api.cloudflare.com/client/v4/zones/cf_zone_foo_test/dns_records"* ]]; then
  printf '{"success":true,"result":[{"name":"flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com","proxied":false},{"name":"api.flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com","proxied":false},{"name":"www.flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com","proxied":false},{"name":"cloud.flapjack.foo","type":"CNAME","content":"staging.flapjack-cloud.pages.dev","proxied":true},{"name":"staging.flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com","proxied":false},{"name":"api.staging.flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com","proxied":false},{"name":"www.staging.flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com","proxied":false},{"name":"cloud.staging.flapjack.foo","type":"CNAME","content":"staging.flapjack-cloud.pages.dev","proxied":true}]}'
  exit 0
fi
if [[ "$request" == *"api.cloudflare.com/client/v4/zones/cf_zone_foo_test"* ]]; then
  printf '{"success":true,"result":{"id":"cf_zone_foo_test","name":"flapjack.foo"}}'
  exit 0
fi
if [[ -f /tmp/rollback_probe_marker ]]; then
  echo "service unavailable"
  exit 1
fi
echo "{}"
exit 0
CURLMOCK
chmod +x "${MOCK_DIR}/curl"

cat > "${MOCK_DIR}/scripts/rollback.sh" <<'ROLLBACKMOCK'
#!/bin/bash
touch /tmp/rollback_probe_marker
echo "mock rollback: $*"
exit 0
ROLLBACKMOCK
chmod +x "${MOCK_DIR}/scripts/rollback.sh"

output=""
exit_code=0
output=$(run_script \
  --run-deploy --release-sha "$FAKE_SHA" \
  --run-rollback --rollback-sha "$PREV_SHA") || exit_code=$?
rm -f /tmp/rollback_probe_marker

if [[ "$exit_code" -eq 23 ]]; then
  pass "Post-rollback health failure exits with code 23"
else
  fail "Post-rollback health failure exits with code 23 (got $exit_code)"
fi
if echo "$output" | rg -q 'RUNTIME FAIL \[health_fail\]'; then
  pass "Post-rollback health failure outputs RUNTIME FAIL [health_fail]"
else
  fail "Post-rollback health failure outputs RUNTIME FAIL [health_fail]"
fi
teardown

# ---------- Full successful staging sequence ----------
echo ""
echo "--- Full successful staging sequence (all mocked, all pass) ---"

setup
write_full_pass_aws_mock

output=""
exit_code=0
output=$(run_script --domain staging.flapjack.foo \
  --run-deploy --release-sha "$FAKE_SHA" \
  --run-migrate \
  --run-rollback --rollback-sha "$PREV_SHA") || exit_code=$?

if [[ "$exit_code" -eq 0 ]]; then
  pass "Full staged sequence exits 0 with all mocks passing"
else
  fail "Full staged sequence exits 0 with all mocks passing (got $exit_code)"
  echo "--- output tail ---"
  echo "$output" | tail -20
  echo "--- end ---"
fi
if echo "$output" | rg -q 'stage 7 runtime smoke checks completed'; then
  pass "Full sequence emits completion message"
else
  fail "Full sequence emits completion message"
fi
teardown

test_summary "Stage 7 runtime behavioral"
