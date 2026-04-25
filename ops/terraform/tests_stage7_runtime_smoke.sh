#!/usr/bin/env bash
# Runtime validation harness for Stage 7.6 Definition of Done.
#
# This script intentionally runs only targeted runtime checks and keeps
# destructive operations opt-in.

set -euo pipefail

# Preflight exit codes — one per blocker class for actionable triage.
EXIT_AWS_CREDS=10
EXIT_CLOUDFLARE_DNS=11
EXIT_NO_ARTIFACT=12
EXIT_NO_AMI=13

# Runtime assertion exit codes — one per check class.
EXIT_ACM_NOT_ISSUED=20
EXIT_ALB_NO_LISTENER=21
EXIT_TG_UNHEALTHY=22
EXIT_HEALTH_FAIL=23
EXIT_DEPLOY_HEALTH_FAIL=24
EXIT_MIGRATE_FAIL=25
EXIT_MIGRATE_IDEMPOTENCY=25
EXIT_ROLLBACK_FAIL=26
EXIT_DNS_RECORD_MISMATCH=27
EXIT_SES_NOT_VERIFIED=28

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF_DIR="${ROOT_DIR}/ops/terraform/_shared"
ENV_FILE="${ROOT_DIR}/.secret/.env.secret"
# Allow tests to override the scripts directory (e.g. with mock scripts)
SCRIPTS_DIR="${FJCLOUD_SCRIPTS_DIR:-${ROOT_DIR}/ops/scripts}"
# Immutable artifact directory for timestamped plan/apply outputs
ARTIFACT_DIR="${ROOT_DIR}/ops/terraform/artifacts"
FLAPJACK_FOO_CLOUDFLARE_TOKEN_ALIAS="CLOUDFLARE_EDIT_READ_ZONE_DNS_API_TOKEN_FLAPJACK_FOO"
FLAPJACK_FOO_CLOUDFLARE_ZONE_ID_ALIAS="CLOUDFLARE_ZONE_ID_FLAPJACK_FOO"
ENV="staging"
DOMAIN="flapjack.foo"
AMI_ID=""
RELEASE_SHA=""
ROLLBACK_SHA=""
ALERT_EMAILS=()
RUN_APPLY=false
RUN_DEPLOY=false
RUN_MIGRATE=false
RUN_ROLLBACK=false

# Health check tuning (overridable via env for tests)
HEALTH_MAX_RETRIES="${HEALTH_MAX_RETRIES:-3}"
HEALTH_RETRY_INTERVAL="${HEALTH_RETRY_INTERVAL:-2}"
TG_MAX_RETRIES="${TG_MAX_RETRIES:-12}"
TG_RETRY_INTERVAL="${TG_RETRY_INTERVAL:-10}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") --ami-id <ami-xxxxxxxxxxxxxxxxx> [options]

Options:
  --env <staging|prod>            Deployment environment (default: staging)
  --domain <domain>               Root domain (default: flapjack.foo)
  --ami-id <ami-id>               AMI ID for compute module (required)
  --alert-email <email>           Alert email (repeatable)
  --release-sha <40-char-sha>     Release SHA for deploy checks
  --rollback-sha <40-char-sha>    Previous SHA for rollback validation
  --apply                         Run terraform apply after plan
  --run-deploy                    Run ops/scripts/deploy.sh (requires --release-sha)
  --run-migrate                   Run ops/scripts/migrate.sh and verify idempotency
  --run-rollback                  Run ops/scripts/rollback.sh (requires --rollback-sha)
  --env-file <path>               AWS env file (default: .secret/.env.secret)
  -h, --help                      Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      ENV="$2"
      shift 2
      ;;
    --domain)
      DOMAIN="$2"
      shift 2
      ;;
    --ami-id)
      AMI_ID="$2"
      shift 2
      ;;
    --alert-email)
      ALERT_EMAILS+=("$2")
      shift 2
      ;;
    --release-sha)
      RELEASE_SHA="$2"
      shift 2
      ;;
    --rollback-sha)
      ROLLBACK_SHA="$2"
      shift 2
      ;;
    --apply)
      RUN_APPLY=true
      shift
      ;;
    --run-deploy)
      RUN_DEPLOY=true
      shift
      ;;
    --run-migrate)
      RUN_MIGRATE=true
      shift
      ;;
    --run-rollback)
      RUN_ROLLBACK=true
      shift
      ;;
    --env-file)
      ENV_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ "$ENV" != "staging" && "$ENV" != "prod" ]]; then
  echo "ERROR: --env must be staging or prod"
  exit 1
fi

DOMAIN="${DOMAIN%.}"

if [[ -z "$AMI_ID" ]]; then
  echo "ERROR: --ami-id is required"
  usage
  exit 1
fi

if [[ "$RUN_DEPLOY" == true && -z "$RELEASE_SHA" ]]; then
  echo "ERROR: --run-deploy requires --release-sha"
  exit 1
fi

if [[ "$RUN_ROLLBACK" == true && -z "$ROLLBACK_SHA" ]]; then
  echo "ERROR: --run-rollback requires --rollback-sha"
  exit 1
fi

if [[ -n "$RELEASE_SHA" && ! "$RELEASE_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "ERROR: --release-sha must be a 40-char lowercase hex SHA"
  exit 1
fi

if [[ -n "$ROLLBACK_SHA" && ! "$ROLLBACK_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "ERROR: --rollback-sha must be a 40-char lowercase hex SHA"
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: AWS env file not found: $ENV_FILE"
  exit 1
fi

# Parse only the credentials this harness needs to avoid sourcing non-shell-safe
# env files. sub() strips only the first "KEY=" prefix, preserving any "=" in
# values such as AWS secret-key padding.
read_env_value() {
  local key="$1"
  awk -v key="$key" '$0 ~ "^" key "=" {sub(/^[^=]*=/, ""); print; exit}' "$ENV_FILE"
}

domain_env_suffix() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | sed -E 's/[^A-Z0-9]+/_/g'
}

AWS_ACCESS_KEY_ID="$(read_env_value AWS_ACCESS_KEY_ID)"
AWS_SECRET_ACCESS_KEY="$(read_env_value AWS_SECRET_ACCESS_KEY)"
AWS_DEFAULT_REGION="$(read_env_value AWS_DEFAULT_REGION)"
DOMAIN_ENV_SUFFIX="$(domain_env_suffix "$DOMAIN")"
DOMAIN_TOKEN_KEY="CLOUDFLARE_EDIT_READ_ZONE_DNS_API_TOKEN_${DOMAIN_ENV_SUFFIX}"
DOMAIN_ZONE_ID_KEY="CLOUDFLARE_ZONE_ID_${DOMAIN_ENV_SUFFIX}"
if [[ "$DOMAIN" == "flapjack.foo" ]]; then
  DOMAIN_TOKEN_KEY="$FLAPJACK_FOO_CLOUDFLARE_TOKEN_ALIAS"
  DOMAIN_ZONE_ID_KEY="$FLAPJACK_FOO_CLOUDFLARE_ZONE_ID_ALIAS"
fi
CLOUDFLARE_API_TOKEN="$(read_env_value CLOUDFLARE_API_TOKEN)"
CLOUDFLARE_ZONE_ID="$(read_env_value CLOUDFLARE_ZONE_ID)"

if [[ -z "$CLOUDFLARE_API_TOKEN" ]]; then
  CLOUDFLARE_API_TOKEN="$(read_env_value "$DOMAIN_TOKEN_KEY")"
fi

if [[ -z "$CLOUDFLARE_ZONE_ID" ]]; then
  CLOUDFLARE_ZONE_ID="$(read_env_value "$DOMAIN_ZONE_ID_KEY")"
fi

if [[ -z "$AWS_ACCESS_KEY_ID" || -z "$AWS_SECRET_ACCESS_KEY" || -z "$AWS_DEFAULT_REGION" ]]; then
  echo "ERROR: Missing AWS credentials in $ENV_FILE"
  exit 1
fi

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION CLOUDFLARE_API_TOKEN

# --- Evidence bundle ---

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$ARTIFACT_DIR"
EVIDENCE_FILE="${ARTIFACT_DIR}/evidence_${ENV}_${TIMESTAMP}.jsonl"

evidence_log() {
  local command="$1" verdict="$2" output="${3:-}" artifact_path="${4:-}"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local safe_output
  safe_output="$(printf '%s' "$output" | head -20 | tr '\n' ' ' | sed 's/"/\\"/g')"
  printf '{"command":"%s","timestamp":"%s","verdict":"%s","output":"%s","artifact_path":"%s"}\n' \
    "$command" "$ts" "$verdict" "$safe_output" "$artifact_path" \
    >> "$EVIDENCE_FILE"
}

# --- Shared preflight failure helper ---

preflight_fail() {
  local code="$1"
  local check_name="$2"
  local message="$3"
  local remediation="$4"
  printf '\nPREFLIGHT FAIL [%s]: %s\n\n  Remediation:\n' "$check_name" "$message"
  while IFS= read -r line; do
    printf '    %s\n' "$line"
  done <<< "$remediation"
  printf '\n'
  evidence_log "preflight:${check_name}" "FAIL" "$message"
  exit "$code"
}

# --- Shared runtime assertion failure helper ---

runtime_fail() {
  local code="$1"
  local check_name="$2"
  local message="$3"
  local remediation="${4:-}"
  printf '\nRUNTIME FAIL [%s]: %s\n' "$check_name" "$message"
  if [[ -n "$remediation" ]]; then
    printf '\n  Remediation:\n'
    while IFS= read -r line; do
      printf '    %s\n' "$line"
    done <<< "$remediation"
    printf '\n'
  fi
  evidence_log "runtime:${check_name}" "FAIL" "$message"
  exit "$code"
}

# --- Preflight assertion functions ---

assert_aws_credentials_valid() {
  if ! aws sts get-caller-identity --output text >/dev/null 2>&1; then
    preflight_fail "$EXIT_AWS_CREDS" "aws_creds" \
      "AWS credentials are missing or invalid." \
      "Ensure AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, and AWS_DEFAULT_REGION
are correctly set in ${ENV_FILE}.
Test manually with: aws sts get-caller-identity"
  fi
  evidence_log "preflight:aws_creds" "PASS"
}

assert_ami_exists() {
  local ami_count
  ami_count=$(aws ec2 describe-images --owners self \
    --filters "Name=image-id,Values=${AMI_ID}" \
    --query 'Images | length(@)' --output text 2>/dev/null || echo "0")
  if [[ "$ami_count" -lt 1 ]]; then
    preflight_fail "$EXIT_NO_AMI" "ami_exists" \
      "AMI '${AMI_ID}' not found or not owned by this account." \
      "Build an AMI with Packer:
  cd ops/packer && packer build flapjack-ami.pkr.hcl
Then pass the resulting AMI ID via --ami-id."
  fi
  evidence_log "preflight:ami_exists" "PASS"
}

assert_release_artifact_exists() {
  if [[ -z "$RELEASE_SHA" ]]; then
    return 0
  fi
  local bucket="fjcloud-releases-${ENV}"
  local artifact_count
  artifact_count=$(aws s3api list-objects-v2 \
    --bucket "$bucket" \
    --prefix "${RELEASE_SHA}/" \
    --query 'KeyCount' --output text 2>/dev/null || echo "0")
  if [[ "$artifact_count" -lt 1 ]]; then
    preflight_fail "$EXIT_NO_ARTIFACT" "release_artifact" \
      "No release artifacts found in s3://${bucket}/${RELEASE_SHA}/." \
      "Build and upload release binaries, or trigger a CI build on main:
  cargo build --release --target aarch64-unknown-linux-gnu
  aws s3 cp target/aarch64-unknown-linux-gnu/release/flapjack-api \\
    s3://${bucket}/${RELEASE_SHA}/flapjack-api"
  fi
  evidence_log "preflight:release_artifact" "PASS"
}

EMAILS_HCL="[]"
if [[ ${#ALERT_EMAILS[@]} -gt 0 ]]; then
  joined=""
  for email in "${ALERT_EMAILS[@]}"; do
    if [[ -n "$joined" ]]; then
      joined+=","
    fi
    joined+="\"${email}\""
  done
  EMAILS_HCL="[${joined}]"
fi

cloudflare_api_get() {
  local path="$1"
  curl -fsS \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4${path}"
}

json_field_value() {
  local json="$1"
  local jq_filter="$2"
  printf '%s' "$json" | jq -r "${jq_filter} // empty"
}

# Verify Terraform is allowed to mutate the intended Cloudflare zone before
# plan/apply. This catches wrong tokens and wrong-zone IDs without exposing the
# token in logs.
assert_cloudflare_zone_accessible() {
  local response zone_name

  if [[ -z "$CLOUDFLARE_API_TOKEN" ]]; then
    preflight_fail "$EXIT_CLOUDFLARE_DNS" "cloudflare_dns" \
      "CLOUDFLARE_API_TOKEN or ${DOMAIN_TOKEN_KEY} is missing from ${ENV_FILE}." \
      "Add a Cloudflare API token with Zone:Read and DNS:Edit for ${DOMAIN}, using CLOUDFLARE_API_TOKEN or ${DOMAIN_TOKEN_KEY}, then rerun."
  fi

  if [[ -z "$CLOUDFLARE_ZONE_ID" ]]; then
    preflight_fail "$EXIT_CLOUDFLARE_DNS" "cloudflare_dns" \
      "CLOUDFLARE_ZONE_ID or ${DOMAIN_ZONE_ID_KEY} is missing from ${ENV_FILE}." \
      "Set CLOUDFLARE_ZONE_ID or ${DOMAIN_ZONE_ID_KEY} to the Cloudflare zone ID for ${DOMAIN}, then rerun."
  fi

  if ! response="$(cloudflare_api_get "/zones/${CLOUDFLARE_ZONE_ID}" 2>&1)"; then
    preflight_fail "$EXIT_CLOUDFLARE_DNS" "cloudflare_dns" \
      "Cloudflare zone lookup failed for ${DOMAIN}." \
      "Verify CLOUDFLARE_API_TOKEN/${DOMAIN_TOKEN_KEY} and CLOUDFLARE_ZONE_ID/${DOMAIN_ZONE_ID_KEY}. Redacted response: ${response}"
  fi

  if ! printf '%s' "$response" | rg -q '"success"[[:space:]]*:[[:space:]]*true'; then
    preflight_fail "$EXIT_CLOUDFLARE_DNS" "cloudflare_dns" \
      "Cloudflare API did not report success for zone ${CLOUDFLARE_ZONE_ID}." \
      "Verify the token has access to the intended zone. Redacted response: ${response}"
  fi

  zone_name="$(json_field_value "$response" '.result.name')"
  if [[ "$zone_name" != "$DOMAIN" ]]; then
    preflight_fail "$EXIT_CLOUDFLARE_DNS" "cloudflare_dns" \
      "Cloudflare zone '${CLOUDFLARE_ZONE_ID}' is '${zone_name}', expected '${DOMAIN}'." \
      "Use the Cloudflare zone ID for ${DOMAIN}, or pass --domain ${zone_name} if that is the intended staging domain."
  fi

  evidence_log "preflight:cloudflare_dns" "PASS"
}

echo "==> preflight: verifying AWS credentials"
assert_aws_credentials_valid
echo "    OK: AWS credentials valid"

echo "==> preflight: verifying AMI ${AMI_ID} exists"
assert_ami_exists
echo "    OK: AMI ${AMI_ID} found"

echo "==> preflight: verifying release artifacts for ${RELEASE_SHA:-<none>}"
assert_release_artifact_exists
echo "    OK: release artifacts present${RELEASE_SHA:+ for ${RELEASE_SHA}}"

echo "==> preflight: verifying Cloudflare DNS authority for ${DOMAIN}"
assert_cloudflare_zone_accessible
echo "    OK: Cloudflare zone ${CLOUDFLARE_ZONE_ID} matches ${DOMAIN}"

cd "$TF_DIR"

echo "==> terraform init (${ENV})"
terraform init \
  -backend-config="bucket=fjcloud-tfstate-${ENV}" \
  -backend-config="key=terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=fjcloud-tflock"

TF_VARS=(
  -var="env=${ENV}"
  -var="domain=${DOMAIN}"
  -var="cloudflare_zone_id=${CLOUDFLARE_ZONE_ID}"
  -var="ami_id=${AMI_ID}"
  -var="alert_emails=${EMAILS_HCL}"
)

PLAN_ARTIFACT="${ARTIFACT_DIR}/plan_${ENV}_${TIMESTAMP}.txt"
echo "==> terraform plan (${ENV}) -> ${PLAN_ARTIFACT}"
terraform plan "${TF_VARS[@]}" 2>&1 | tee "$PLAN_ARTIFACT"
evidence_log "terraform plan" "PASS" "plan captured" "$PLAN_ARTIFACT"

if [[ "$RUN_APPLY" == true ]]; then
  APPLY_ARTIFACT="${ARTIFACT_DIR}/apply_${ENV}_${TIMESTAMP}.txt"
  echo "==> terraform apply (${ENV}) -> ${APPLY_ARTIFACT}"
  terraform apply -auto-approve "${TF_VARS[@]}" 2>&1 | tee "$APPLY_ARTIFACT"
  evidence_log "terraform apply" "PASS" "apply captured" "$APPLY_ARTIFACT"
fi

cd "$ROOT_DIR"

ALB_NAME="fjcloud-${ENV}-alb"
TG_NAME="fjcloud-${ENV}-api-tg"
HEALTH_URL="https://api.${DOMAIN}/health"

cloudflare_record_matches_alb() {
  local records_json="$1"
  local record_name="$2"
  printf '%s' "$records_json" \
    | tr '}' '\n' \
    | rg -F "\"name\":\"${record_name}\"" \
    | rg -F '"type":"CNAME"' \
    | rg -F '"proxied":false' \
    | rg -q 'elb.amazonaws.com'
}

cloudflare_record_matches_pages() {
  local records_json="$1"
  local record_name="$2"
  local expected_target="$3"
  printf '%s' "$records_json" \
    | tr '}' '\n' \
    | rg -F "\"name\":\"${record_name}\"" \
    | rg -F '"type":"CNAME"' \
    | rg -F "\"content\":\"${expected_target}\"" \
    | rg -F '"proxied":true' \
    >/dev/null
}

assert_acm_cert_issued() {
  local cert_arn status
  cert_arn=$(aws acm list-certificates \
    --query "CertificateSummaryList[?DomainName=='${DOMAIN}'] | [0].CertificateArn" \
    --output text)

  if [[ -z "$cert_arn" || "$cert_arn" == "None" ]]; then
    runtime_fail "$EXIT_ACM_NOT_ISSUED" "acm_not_issued" \
      "No ACM certificate found for ${DOMAIN}." \
      "Run terraform apply to provision the certificate, then rerun."
  fi

  status=$(aws acm describe-certificate \
    --certificate-arn "$cert_arn" \
    --query 'Certificate.Status' \
    --output text)

  if [[ "$status" != "ISSUED" ]]; then
    runtime_fail "$EXIT_ACM_NOT_ISSUED" "acm_not_issued" \
      "ACM certificate for ${DOMAIN} status is '${status}', expected ISSUED." \
      "Ensure DNS validation records exist and propagation is complete.
Certificate status: ${status}
Domain: ${DOMAIN}"
  fi
  evidence_log "assert:acm_cert_issued" "PASS"
}

assert_alb_https_listener() {
  local alb_arn listener_count
  alb_arn=$(aws elbv2 describe-load-balancers \
    --names "$ALB_NAME" \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text 2>/dev/null)

  if [[ -z "$alb_arn" || "$alb_arn" == "None" ]]; then
    runtime_fail "$EXIT_ALB_NO_LISTENER" "alb_no_listener" \
      "ALB '${ALB_NAME}' not found." \
      "Run terraform apply to provision the ALB, then rerun."
  fi

  listener_count=$(aws elbv2 describe-listeners \
    --load-balancer-arn "$alb_arn" \
    --query "Listeners[?Port==\`443\` && Protocol=='HTTPS'] | length(@)" \
    --output text)

  if [[ "$listener_count" -lt 1 ]]; then
    runtime_fail "$EXIT_ALB_NO_LISTENER" "alb_no_listener" \
      "ALB '${ALB_NAME}' has no HTTPS listener on port 443." \
      "Verify the aws_lb_listener.https resource was applied.
Expected: HTTPS listener on port 443."
  fi
  evidence_log "assert:alb_https_listener" "PASS"
}

assert_target_group_healthy() {
  local tg_arn healthy_count attempt=0
  tg_arn=$(aws elbv2 describe-target-groups \
    --names "$TG_NAME" \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text 2>/dev/null)

  if [[ -z "$tg_arn" || "$tg_arn" == "None" ]]; then
    runtime_fail "$EXIT_TG_UNHEALTHY" "tg_unhealthy" \
      "Target group '${TG_NAME}' not found." \
      "Run terraform apply to provision the target group, then rerun."
  fi

  while [[ "$attempt" -lt "$TG_MAX_RETRIES" ]]; do
    healthy_count=$(aws elbv2 describe-target-health \
      --target-group-arn "$tg_arn" \
      --query "TargetHealthDescriptions[?TargetHealth.State=='healthy'] | length(@)" \
      --output text)

    if [[ "$healthy_count" -ge 1 ]]; then
      evidence_log "assert:target_group_healthy" "PASS"
      return 0
    fi

    attempt=$((attempt + 1))
    if [[ "$attempt" -lt "$TG_MAX_RETRIES" ]]; then
      sleep "$TG_RETRY_INTERVAL"
    fi
  done

  runtime_fail "$EXIT_TG_UNHEALTHY" "tg_unhealthy" \
    "Target group '${TG_NAME}' has no healthy targets after ${TG_MAX_RETRIES} checks." \
    "Check that the API instance is running and passing health checks.
Expected: at least 1 target with state 'healthy'."
  evidence_log "assert:target_group_healthy" "PASS"
}

# Verify the Cloudflare zone contains the canonical public routing records
# Terraform owns. Apex/api/www stay DNS-only ALB routes, while cloud stays
# proxied to the current Pages host until the dedicated cloud-host deploy path
# replaces it. We intentionally assert CNAME targets instead of exact IPs
# because Cloudflare flattens apex CNAME responses and ALB IPs rotate.
assert_cloudflare_public_records() {
  local response expected_name
  local alb_backed_names=(
    "$DOMAIN"
    "api.${DOMAIN}"
    "www.${DOMAIN}"
  )

  if ! response="$(cloudflare_api_get "/zones/${CLOUDFLARE_ZONE_ID}/dns_records?type=CNAME&per_page=100" 2>&1)"; then
    runtime_fail "$EXIT_DNS_RECORD_MISMATCH" "dns_record_mismatch" \
      "Cloudflare DNS record lookup failed for ${DOMAIN}." \
      "Verify Cloudflare token permissions and inspect DNS records for ${DOMAIN}."
  fi

  for expected_name in "${alb_backed_names[@]}"; do
    if ! cloudflare_record_matches_alb "$response" "$expected_name"; then
      runtime_fail "$EXIT_DNS_RECORD_MISMATCH" "dns_record_mismatch" \
        "Cloudflare record ${expected_name} is missing or does not CNAME to an ALB target." \
        "Expected ${expected_name} to be a DNS-only CNAME pointing at an AWS ALB (*.elb.amazonaws.com). Check the Cloudflare DNS tab and Terraform state."
    fi
  done

  if ! cloudflare_record_matches_pages "$response" "cloud.${DOMAIN}" "flapjack-cloud.pages.dev"; then
    runtime_fail "$EXIT_DNS_RECORD_MISMATCH" "dns_record_mismatch" \
      "Cloudflare record cloud.${DOMAIN} is missing or does not route to the expected Pages host." \
      "Expected cloud.${DOMAIN} to stay proxied to flapjack-cloud.pages.dev until the full cloud-host deploy path replaces the current Pages-backed surface."
  fi

  evidence_log "assert:cloudflare_public_records" "PASS"
}

assert_ses_identity_verified() {
  local identity_state verification_status dkim_status
  identity_state=$(aws sesv2 get-email-identity \
    --email-identity "$DOMAIN" \
    --query '[VerificationStatus,DkimAttributes.Status]' \
    --output text 2>/dev/null || echo "NONE NONE")

  verification_status="$(awk '{print $1}' <<< "$identity_state")"
  dkim_status="$(awk '{print $2}' <<< "$identity_state")"

  if [[ "$verification_status" != "SUCCESS" || "$dkim_status" != "SUCCESS" ]]; then
    runtime_fail "$EXIT_SES_NOT_VERIFIED" "ses_not_verified" \
      "SES identity ${DOMAIN} is not fully verified (identity=${verification_status}, dkim=${dkim_status})." \
      "Publish the SES Easy DKIM CNAME records in Cloudflare, then rerun:
  aws sesv2 get-email-identity --email-identity ${DOMAIN}
  dig +short CNAME '*._domainkey.${DOMAIN}'"
  fi

  evidence_log "assert:ses_identity_verified" "PASS"
}

# Health endpoint assertion with bounded retry/polling and deterministic timeout.
# $1: fail tag (default: health_fail), $2: exit code (default: EXIT_HEALTH_FAIL)
check_health_once() {
  curl -fsS --connect-timeout 10 --max-time 30 "$HEALTH_URL" >/dev/null 2>&1
}

# Deploy health sampling configuration.
# $1: fail tag (default: deploy_health_fail), $2: exit code (default: EXIT_DEPLOY_HEALTH_FAIL)
run_deploy_with_health_sampling() {
  local attempt=0
  local deploy_pid

  bash "${SCRIPTS_DIR}/deploy.sh" "${ENV}" "${RELEASE_SHA}" &
  deploy_pid=$!
  while kill -0 "$deploy_pid" 2>/dev/null; do
    if ! check_health_once; then
      kill "$deploy_pid" 2>/dev/null || true
      wait "$deploy_pid" 2>/dev/null || true
      runtime_fail "$EXIT_DEPLOY_HEALTH_FAIL" "deploy_health_fail" \
        "Deploy rollout health probe failed while deployment was in progress."
    fi
    evidence_log "assert:deploy_health_sample_${attempt}" "PASS"
    attempt=$((attempt + 1))
    sleep "$HEALTH_RETRY_INTERVAL"
  done

  if ! wait "$deploy_pid"; then
    runtime_fail "$EXIT_DEPLOY_HEALTH_FAIL" "deploy_health_fail" \
      "Deploy script failed for SHA ${RELEASE_SHA}." \
      "Review deploy logs: ${SCRIPTS_DIR}/deploy.sh ${ENV} ${RELEASE_SHA}"
  fi
}

assert_health_endpoint() {
  local tag="${1:-health_fail}"
  local code="${2:-$EXIT_HEALTH_FAIL}"
  local attempt=0

  while [[ "$attempt" -lt "$HEALTH_MAX_RETRIES" ]]; do
    if check_health_once; then
      evidence_log "assert:${tag}" "PASS"
      return 0
    fi
    attempt=$((attempt + 1))
    if [[ "$attempt" -lt "$HEALTH_MAX_RETRIES" ]]; then
      sleep "$HEALTH_RETRY_INTERVAL"
    fi
  done

  runtime_fail "$code" "$tag" \
    "Health endpoint ${HEALTH_URL} did not return 200 after ${HEALTH_MAX_RETRIES} attempts." \
    "Verify the service is running and reachable:
  curl -v ${HEALTH_URL}
Check target group health and application logs."
}

echo "==> verifying ACM certificate status"
assert_acm_cert_issued
echo "    OK: ACM cert status is ISSUED"

echo "==> verifying ALB HTTPS listener on 443"
assert_alb_https_listener
echo "    OK: HTTPS listener present on port 443"

echo "==> verifying target group health"
assert_target_group_healthy
echo "    OK: target group has healthy targets"

echo "==> verifying Cloudflare public routing records"
assert_cloudflare_public_records
echo "    OK: Cloudflare public records match the canonical ALB/Pages split"

echo "==> verifying SES identity and DKIM status"
assert_ses_identity_verified
echo "    OK: SES identity and DKIM are verified"

echo "==> public health check (retry: ${HEALTH_MAX_RETRIES}x, interval: ${HEALTH_RETRY_INTERVAL}s)"
assert_health_endpoint
echo "    OK: ${HEALTH_URL} returned 200"

if [[ "$RUN_DEPLOY" == true ]]; then
  echo "==> deploy: pre-deploy health probe"
  check_health_once || true

  echo "==> deploy: running deploy.sh ${ENV} ${RELEASE_SHA} with health sampling"
  run_deploy_with_health_sampling

  evidence_log "deploy.sh" "PASS" "exit 0"

  echo "==> deploy: post-deploy no-downtime health assertion"
  assert_health_endpoint "deploy_health_fail" "$EXIT_DEPLOY_HEALTH_FAIL"
  echo "    OK: post-deploy health check passed"
fi

if [[ "$RUN_MIGRATE" == true ]]; then
  echo "==> migration: first run (${ENV})"
  if ! bash "${SCRIPTS_DIR}/migrate.sh" "$ENV"; then
    runtime_fail "$EXIT_MIGRATE_FAIL" "migrate_fail" \
      "Migration failed for environment ${ENV}." \
      "Review migration logs: ${SCRIPTS_DIR}/migrate.sh ${ENV}"
  fi
  evidence_log "migrate.sh (run 1)" "PASS" "exit 0"
  echo "    OK: migration first run succeeded"

  echo "==> migration: idempotency re-run (${ENV})"
  if ! bash "${SCRIPTS_DIR}/migrate.sh" "$ENV"; then
    runtime_fail "$EXIT_MIGRATE_IDEMPOTENCY" "migrate_idempotency" \
      "Migration idempotency check failed: second run of migrate.sh exited non-zero." \
      "Ensure migrations are idempotent (safe to re-run).
Review migration logs: ${SCRIPTS_DIR}/migrate.sh ${ENV}"
  fi
  evidence_log "migrate.sh (run 2 idempotency)" "PASS" "exit 0"
  echo "    OK: migration idempotency re-run succeeded"
fi

if [[ "$RUN_ROLLBACK" == true ]]; then
  echo "==> rollback: running rollback.sh ${ENV} ${ROLLBACK_SHA}"
  if ! bash "${SCRIPTS_DIR}/rollback.sh" "$ENV" "$ROLLBACK_SHA"; then
    runtime_fail "$EXIT_ROLLBACK_FAIL" "rollback_fail" \
      "Rollback to SHA ${ROLLBACK_SHA} failed for environment ${ENV}." \
      "Review rollback logs: ${SCRIPTS_DIR}/rollback.sh ${ENV} ${ROLLBACK_SHA}"
  fi
  evidence_log "rollback.sh" "PASS" "exit 0"
  echo "    OK: rollback to ${ROLLBACK_SHA} succeeded"

  echo "==> rollback: post-rollback health assertion"
  assert_health_endpoint
  echo "    OK: post-rollback health check passed"

  echo "==> rollback: post-rollback target group assertion"
  assert_target_group_healthy
  echo "    OK: post-rollback target group healthy"
fi

echo "==> evidence bundle: ${EVIDENCE_FILE}"
echo "==> stage 7 runtime smoke checks completed"
