#!/usr/bin/env bash
# validate_bootstrap.sh — Verify AWS bootstrap prerequisites for fjcloud
#
# Checks that all infrastructure prerequisites exist and are correctly
# configured before running terraform init or deploy scripts.
#
# Usage: validate_bootstrap.sh <env>
#   env: staging | prod
#
# Prerequisites checked:
#   - S3 tfstate bucket (versioned, encrypted, public access blocked)
#   - S3 releases bucket (versioned, public access blocked)
#   - DynamoDB lock table with LockID key
#   - SSM parameters (database_url as SecureString)
#   - Cloudflare DNS credentials for the public staging zone

set -euo pipefail

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------

if [[ $# -ne 1 ]]; then
  echo "Usage: validate_bootstrap.sh <env>"
  echo "  env: staging | prod"
  exit 1
fi

ENV="$1"
REGION="us-east-1"

if [[ "$ENV" != "staging" && "$ENV" != "prod" ]]; then
  echo "ERROR: env must be 'staging' or 'prod' (got: ${ENV})"
  exit 1
fi

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------

CHECKS_PASS=0
CHECKS_FAIL=0
FAILURES=()

check_pass() {
  printf 'PASS: %s\n' "$1"
  CHECKS_PASS=$((CHECKS_PASS + 1))
}

check_fail() {
  printf 'FAIL: %s\n' "$1"
  CHECKS_FAIL=$((CHECKS_FAIL + 1))
  FAILURES+=("$1")
}

# ---------------------------------------------------------------------------
# S3 tfstate bucket
# ---------------------------------------------------------------------------

TFSTATE_BUCKET="fjcloud-tfstate-${ENV}"

echo ""
echo "=== S3 tfstate bucket: ${TFSTATE_BUCKET} ==="

if aws s3api head-bucket --bucket "${TFSTATE_BUCKET}" --region "${REGION}" 2>/dev/null; then
  check_pass "tfstate bucket ${TFSTATE_BUCKET} exists"
else
  check_fail "tfstate bucket ${TFSTATE_BUCKET} does not exist"
fi

VERSIONING=$(aws s3api get-bucket-versioning --bucket "${TFSTATE_BUCKET}" --region "${REGION}" --query 'Status' --output text 2>/dev/null || echo "NONE")
if [[ "${VERSIONING}" == "Enabled" ]]; then
  check_pass "tfstate bucket versioning is Enabled"
else
  check_fail "tfstate bucket versioning is ${VERSIONING} (expected Enabled)"
fi

ENCRYPTION=$(aws s3api get-bucket-encryption --bucket "${TFSTATE_BUCKET}" --region "${REGION}" --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text 2>/dev/null || echo "NONE")
if [[ "${ENCRYPTION}" != "NONE" ]]; then
  check_pass "tfstate bucket encryption configured (${ENCRYPTION})"
else
  check_fail "tfstate bucket encryption not configured"
fi

PUBLIC_BLOCK=$(aws s3api get-public-access-block --bucket "${TFSTATE_BUCKET}" --region "${REGION}" --query 'PublicAccessBlockConfiguration.BlockPublicAcls' --output text 2>/dev/null || echo "NONE")
if [[ "${PUBLIC_BLOCK}" == "True" ]]; then
  check_pass "tfstate bucket public access blocked"
else
  check_fail "tfstate bucket public access block not configured"
fi

# ---------------------------------------------------------------------------
# S3 releases bucket
# ---------------------------------------------------------------------------

RELEASES_BUCKET="fjcloud-releases-${ENV}"

echo ""
echo "=== S3 releases bucket: ${RELEASES_BUCKET} ==="

if aws s3api head-bucket --bucket "${RELEASES_BUCKET}" --region "${REGION}" 2>/dev/null; then
  check_pass "releases bucket ${RELEASES_BUCKET} exists"
else
  check_fail "releases bucket ${RELEASES_BUCKET} does not exist"
fi

REL_VERSIONING=$(aws s3api get-bucket-versioning --bucket "${RELEASES_BUCKET}" --region "${REGION}" --query 'Status' --output text 2>/dev/null || echo "NONE")
if [[ "${REL_VERSIONING}" == "Enabled" ]]; then
  check_pass "releases bucket versioning is Enabled"
else
  check_fail "releases bucket versioning is ${REL_VERSIONING} (expected Enabled)"
fi

REL_PUBLIC_BLOCK=$(aws s3api get-public-access-block --bucket "${RELEASES_BUCKET}" --region "${REGION}" --query 'PublicAccessBlockConfiguration.BlockPublicAcls' --output text 2>/dev/null || echo "NONE")
if [[ "${REL_PUBLIC_BLOCK}" == "True" ]]; then
  check_pass "releases bucket public access blocked"
else
  check_fail "releases bucket public access block not configured"
fi

# ---------------------------------------------------------------------------
# DynamoDB lock table
# ---------------------------------------------------------------------------

echo ""
echo "=== DynamoDB lock table: fjcloud-tflock ==="

TABLE_STATUS=$(aws dynamodb describe-table --table-name "fjcloud-tflock" --region "${REGION}" --query 'Table.TableStatus' --output text 2>/dev/null || echo "NONE")
if [[ "${TABLE_STATUS}" == "ACTIVE" ]]; then
  check_pass "DynamoDB lock table fjcloud-tflock exists (ACTIVE)"
else
  check_fail "DynamoDB lock table fjcloud-tflock status: ${TABLE_STATUS} (expected ACTIVE)"
fi

KEY_SCHEMA=$(aws dynamodb describe-table --table-name "fjcloud-tflock" --region "${REGION}" --query 'Table.KeySchema[0].AttributeName' --output text 2>/dev/null || echo "NONE")
if [[ "${KEY_SCHEMA}" == "LockID" ]]; then
  check_pass "lock table key schema has LockID attribute"
else
  check_fail "lock table key schema: ${KEY_SCHEMA} (expected LockID)"
fi

# ---------------------------------------------------------------------------
# SSM parameters
# ---------------------------------------------------------------------------

echo ""
echo "=== SSM parameters: /fjcloud/${ENV}/ ==="

DB_URL_PARAM="/fjcloud/${ENV}/database_url"
DB_URL_TYPE=$(aws ssm get-parameter --name "${DB_URL_PARAM}" --region "${REGION}" --query 'Parameter.Type' --output text 2>/dev/null || echo "NONE")
if [[ "${DB_URL_TYPE}" == "SecureString" ]]; then
  check_pass "SSM ${DB_URL_PARAM} exists (SecureString)"
elif [[ "${DB_URL_TYPE}" != "NONE" ]]; then
  check_fail "SSM ${DB_URL_PARAM} exists but type is ${DB_URL_TYPE} (expected SecureString)"
else
  check_fail "SSM ${DB_URL_PARAM} does not exist"
fi

# ---------------------------------------------------------------------------
# Cloudflare public DNS
# ---------------------------------------------------------------------------

DOMAIN="flapjack.foo"
CLOUDFLARE_TOKEN_ALIAS="CLOUDFLARE_EDIT_READ_ZONE_DNS_API_TOKEN_FLAPJACK_FOO"
CLOUDFLARE_ZONE_ID_ALIAS="CLOUDFLARE_ZONE_ID_FLAPJACK_FOO"
CLOUDFLARE_API_TOKEN_EFFECTIVE="${CLOUDFLARE_API_TOKEN:-${CLOUDFLARE_EDIT_READ_ZONE_DNS_API_TOKEN_FLAPJACK_FOO:-}}"
CLOUDFLARE_ZONE_ID_EFFECTIVE="${CLOUDFLARE_ZONE_ID:-${CLOUDFLARE_ZONE_ID_FLAPJACK_FOO:-}}"

echo ""
echo "=== Cloudflare public DNS zone: ${DOMAIN} ==="

if [[ -z "${CLOUDFLARE_API_TOKEN_EFFECTIVE}" ]]; then
  check_fail "Cloudflare API token missing (set CLOUDFLARE_API_TOKEN or ${CLOUDFLARE_TOKEN_ALIAS})"
else
  check_pass "Cloudflare API token is present"
fi

if [[ -z "${CLOUDFLARE_ZONE_ID_EFFECTIVE}" ]]; then
  check_fail "Cloudflare zone ID missing (set CLOUDFLARE_ZONE_ID or ${CLOUDFLARE_ZONE_ID_ALIAS})"
else
  check_pass "Cloudflare zone ID is present"
fi

if [[ -n "${CLOUDFLARE_API_TOKEN_EFFECTIVE}" && -n "${CLOUDFLARE_ZONE_ID_EFFECTIVE}" ]]; then
  ZONE_RESPONSE=$(curl -fsS \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN_EFFECTIVE}" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID_EFFECTIVE}" 2>/dev/null || true)

  if ! printf '%s' "${ZONE_RESPONSE}" | rg -q '"success"[[:space:]]*:[[:space:]]*true'; then
    check_fail "Cloudflare zone lookup failed for ${DOMAIN}"
  else
    ZONE_NAME=$(printf '%s' "${ZONE_RESPONSE}" | sed -nE 's/.*"name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -1)
    if [[ "${ZONE_NAME}" == "${DOMAIN}" ]]; then
      check_pass "Cloudflare zone matches ${DOMAIN}"
    else
      check_fail "Cloudflare zone mismatch: ${ZONE_NAME:-unknown} (expected ${DOMAIN})"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

TOTAL=$((CHECKS_PASS + CHECKS_FAIL))

echo ""
echo "=== Bootstrap Validation Summary (${ENV}) ==="
echo "PASS: ${CHECKS_PASS}/${TOTAL}"
echo "FAIL: ${CHECKS_FAIL}/${TOTAL}"

if [[ ${CHECKS_FAIL} -gt 0 ]]; then
  echo ""
  echo "Failures:"
  for f in "${FAILURES[@]}"; do
    echo "  - ${f}"
  done
  echo ""
  echo "See ops/BOOTSTRAP.md for setup instructions."
  exit 1
fi

echo ""
echo "All bootstrap prerequisites verified for ${ENV}."
