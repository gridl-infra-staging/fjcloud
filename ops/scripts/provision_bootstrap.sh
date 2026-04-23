#!/usr/bin/env bash
# provision_bootstrap.sh — Create AWS bootstrap prerequisites for fjcloud
#
# Idempotent counterpart to validate_bootstrap.sh: creates the resources
# that validate_bootstrap.sh checks. Safe to re-run — skips existing resources.
#
# Usage: provision_bootstrap.sh <env>
#   env: staging | prod
#
# Resources provisioned:
#   - S3 tfstate bucket (versioned, encrypted, public access blocked)
#   - S3 releases bucket (versioned, public access blocked)
#   - DynamoDB lock table with LockID key (shared across envs)
#   - SSM parameter /fjcloud/<env>/database_url as SecureString placeholder
#
# NOTE: Public DNS is NOT created here. The Terraform dns module publishes
# Cloudflare records, and validate_bootstrap.sh checks the Cloudflare token and
# zone ID before staging plans or applies.

set -euo pipefail

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------

if [[ $# -ne 1 ]]; then
  echo "Usage: provision_bootstrap.sh <env>"
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

CREATED=0
SKIPPED=0

resource_created() {
  printf 'CREATED: %s\n' "$1"
  CREATED=$((CREATED + 1))
}

resource_skipped() {
  printf 'SKIP: %s (already exists)\n' "$1"
  SKIPPED=$((SKIPPED + 1))
}

# ---------------------------------------------------------------------------
# S3 tfstate bucket
# ---------------------------------------------------------------------------

TFSTATE_BUCKET="fjcloud-tfstate-${ENV}"

echo ""
echo "=== S3 tfstate bucket: ${TFSTATE_BUCKET} ==="

if aws s3api head-bucket --bucket "${TFSTATE_BUCKET}" --region "${REGION}" 2>/dev/null; then
  resource_skipped "tfstate bucket ${TFSTATE_BUCKET}"
else
  aws s3api create-bucket \
    --bucket "${TFSTATE_BUCKET}" \
    --region "${REGION}" >/dev/null
  resource_created "tfstate bucket ${TFSTATE_BUCKET}"
fi

# Versioning (idempotent — always set to Enabled)
aws s3api put-bucket-versioning --bucket "${TFSTATE_BUCKET}" --region "${REGION}" --versioning-configuration Status=Enabled

# Encryption (idempotent — always set AES256)
aws s3api put-bucket-encryption \
  --bucket "${TFSTATE_BUCKET}" \
  --region "${REGION}" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# Public access block (idempotent)
aws s3api put-public-access-block \
  --bucket "${TFSTATE_BUCKET}" \
  --region "${REGION}" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

echo "  versioning=Enabled, encryption=AES256, public-access=blocked"

# ---------------------------------------------------------------------------
# S3 releases bucket
# ---------------------------------------------------------------------------

RELEASES_BUCKET="fjcloud-releases-${ENV}"

echo ""
echo "=== S3 releases bucket: ${RELEASES_BUCKET} ==="

if aws s3api head-bucket --bucket "${RELEASES_BUCKET}" --region "${REGION}" 2>/dev/null; then
  resource_skipped "releases bucket ${RELEASES_BUCKET}"
else
  aws s3api create-bucket \
    --bucket "${RELEASES_BUCKET}" \
    --region "${REGION}" >/dev/null
  resource_created "releases bucket ${RELEASES_BUCKET}"
fi

# Versioning (idempotent)
aws s3api put-bucket-versioning \
  --bucket "${RELEASES_BUCKET}" \
  --region "${REGION}" \
  --versioning-configuration Status=Enabled

# Public access block (idempotent)
aws s3api put-public-access-block \
  --bucket "${RELEASES_BUCKET}" \
  --region "${REGION}" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

echo "  versioning=Enabled, public-access=blocked"

# ---------------------------------------------------------------------------
# DynamoDB lock table (shared across envs)
# ---------------------------------------------------------------------------

LOCK_TABLE="fjcloud-tflock"

echo ""
echo "=== DynamoDB lock table: ${LOCK_TABLE} ==="

TABLE_STATUS=$(aws dynamodb describe-table --table-name "${LOCK_TABLE}" --region "${REGION}" --query 'Table.TableStatus' --output text 2>/dev/null || echo "NONE")
if [[ "${TABLE_STATUS}" == "ACTIVE" ]]; then
  resource_skipped "DynamoDB table ${LOCK_TABLE}"
else
  aws dynamodb create-table \
    --table-name "${LOCK_TABLE}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${REGION}" >/dev/null

  echo "  waiting for table to become ACTIVE..."
  aws dynamodb wait table-exists --table-name "${LOCK_TABLE}" --region "${REGION}"
  resource_created "DynamoDB table ${LOCK_TABLE}"
fi

# ---------------------------------------------------------------------------
# SSM parameter: database_url
# ---------------------------------------------------------------------------

DB_URL_PARAM="/fjcloud/${ENV}/database_url"

echo ""
echo "=== SSM parameter: ${DB_URL_PARAM} ==="

EXISTING_TYPE=$(aws ssm get-parameter --name "${DB_URL_PARAM}" --region "${REGION}" --query 'Parameter.Type' --output text 2>/dev/null || echo "NONE")
if [[ "${EXISTING_TYPE}" == "SecureString" ]]; then
  resource_skipped "SSM ${DB_URL_PARAM}"
else
  # Placeholder value — must be updated with real DB URL before deploy
  aws ssm put-parameter \
    --name "${DB_URL_PARAM}" \
    --type SecureString \
    --value "placeholder://update-before-deploy" \
    --description "PostgreSQL connection URL for fjcloud ${ENV}" \
    --region "${REGION}" >/dev/null
  resource_created "SSM ${DB_URL_PARAM} (placeholder — update with real DB URL)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

TOTAL=$((CREATED + SKIPPED))

echo ""
echo "=== Provision Summary (${ENV}) ==="
echo "CREATED: ${CREATED}"
echo "SKIP:    ${SKIPPED}"
echo "TOTAL:   ${TOTAL}"

if [[ ${CREATED} -gt 0 ]]; then
  echo ""
  echo "Run 'validate_bootstrap.sh ${ENV}' to verify all prerequisites."
fi

echo ""
echo "Bootstrap provisioning complete for ${ENV}."
