#!/usr/bin/env bash
# Static contract tests for ops/scripts/provision_bootstrap.sh
# TDD red phase — tests written before the script exists
#
# provision_bootstrap.sh is the counterpart to validate_bootstrap.sh:
# it CREATES the AWS bootstrap resources that validate_bootstrap.sh checks.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

provision_file="ops/scripts/provision_bootstrap.sh"

echo ""
echo "=== Provision Bootstrap Static Tests ==="
echo ""

# ---------------------------------------------------------------------------
# File existence and basics
# ---------------------------------------------------------------------------

echo "--- provision_bootstrap.sh: file and arg validation ---"
assert_file_exists "$provision_file" "provision_bootstrap.sh exists"
assert_file_contains "$provision_file" 'set -euo pipefail' "uses strict mode"
assert_file_contains "$provision_file" 'Usage: provision_bootstrap\.sh <env>' "documents usage"
assert_file_contains "$provision_file" '"staging" && "\$ENV" != "prod"' "validates env is staging|prod"

# ---------------------------------------------------------------------------
# S3 tfstate bucket provisioning
# ---------------------------------------------------------------------------

echo ""
echo "--- provision_bootstrap.sh: S3 tfstate bucket ---"
assert_file_contains "$provision_file" 'fjcloud-tfstate-\$\{ENV\}' "uses env-specific tfstate bucket name"
assert_file_contains "$provision_file" 'aws s3api create-bucket' "creates bucket via create-bucket"
assert_file_contains "$provision_file" 'put-bucket-versioning.*Status=Enabled' "enables versioning"
assert_file_contains "$provision_file" 'put-bucket-encryption' "configures encryption"
assert_file_contains "$provision_file" 'AES256' "uses AES256 encryption"
assert_file_contains "$provision_file" 'put-public-access-block' "configures public access block"
assert_file_contains "$provision_file" 'BlockPublicAcls=true' "blocks public ACLs"
assert_file_contains "$provision_file" 'RestrictPublicBuckets=true' "restricts public buckets"

# ---------------------------------------------------------------------------
# S3 releases bucket provisioning
# ---------------------------------------------------------------------------

echo ""
echo "--- provision_bootstrap.sh: S3 releases bucket ---"
assert_file_contains "$provision_file" 'fjcloud-releases-\$\{ENV\}' "uses env-specific releases bucket name"
# Releases bucket also needs versioning and public access block
assert_file_contains "$provision_file" 'RELEASES_BUCKET' "uses RELEASES_BUCKET variable"
assert_file_contains "$provision_file" 'service_status\.json exception' "documents service_status.json exception for reruns"
assert_file_contains "$provision_file" 'RestrictPublicBuckets=true on every rerun' "documents rerun behavior that resets public policy flags"

# ---------------------------------------------------------------------------
# DynamoDB lock table provisioning
# ---------------------------------------------------------------------------

echo ""
echo "--- provision_bootstrap.sh: DynamoDB lock table ---"
assert_file_contains "$provision_file" 'fjcloud-tflock' "uses correct lock table name"
assert_file_contains "$provision_file" 'aws dynamodb create-table' "creates DynamoDB table"
assert_file_contains "$provision_file" 'LockID' "uses LockID as key attribute"
assert_file_contains "$provision_file" 'PAY_PER_REQUEST' "uses on-demand billing"

# ---------------------------------------------------------------------------
# SSM parameter provisioning
# ---------------------------------------------------------------------------

echo ""
echo "--- provision_bootstrap.sh: SSM parameters ---"
assert_file_contains "$provision_file" '/fjcloud/\$\{ENV\}/database_url' "provisions env-specific database_url"
assert_file_contains "$provision_file" 'aws ssm put-parameter' "creates SSM parameter"
assert_file_contains "$provision_file" 'SecureString' "creates as SecureString type"

# ---------------------------------------------------------------------------
# Idempotency — must check before creating
# ---------------------------------------------------------------------------

echo ""
echo "--- provision_bootstrap.sh: idempotency ---"
assert_file_contains "$provision_file" 'head-bucket.*TFSTATE_BUCKET' "checks if tfstate bucket exists before creating"
assert_file_contains "$provision_file" 'head-bucket.*RELEASES_BUCKET' "checks if releases bucket exists before creating"
assert_file_contains "$provision_file" 'aws dynamodb describe-table' "checks if DynamoDB table exists before creating"
assert_file_contains "$provision_file" 'aws ssm get-parameter' "checks if SSM param exists before creating"
assert_file_contains "$provision_file" 'already exists' "reports when resource already exists"

# ---------------------------------------------------------------------------
# Output and summary behavior
# ---------------------------------------------------------------------------

echo ""
echo "--- provision_bootstrap.sh: output ---"
assert_file_contains "$provision_file" 'CREATED' "reports created resources"
assert_file_contains "$provision_file" 'SKIP' "reports skipped (existing) resources"

# ---------------------------------------------------------------------------
# Security — no hardcoded secrets
# ---------------------------------------------------------------------------

echo ""
echo "--- provision_bootstrap.sh: security ---"
assert_file_not_contains "$provision_file" 'AKIA[A-Z0-9]' "no hardcoded AWS access key IDs"
assert_file_not_contains "$provision_file" 'password=' "no hardcoded passwords"
assert_file_not_contains "$provision_file" 'secret=' "no hardcoded secrets"

# ---------------------------------------------------------------------------
# Cross-environment parity — no hardcoded env names
# ---------------------------------------------------------------------------

echo ""
echo "--- provision_bootstrap.sh: environment parity ---"
assert_file_not_contains "$provision_file" 'fjcloud-tfstate-staging[^$]' "does not hardcode staging bucket"
assert_file_not_contains "$provision_file" 'fjcloud-releases-staging[^$]' "does not hardcode staging releases bucket"

# ---------------------------------------------------------------------------
# Integration: provision + validate should agree on resource names
# ---------------------------------------------------------------------------

validate_file="ops/scripts/validate_bootstrap.sh"

echo ""
echo "--- Cross-script parity: provision vs validate ---"
# Both scripts must use the same bucket/table/param naming conventions
assert_file_contains "$provision_file" 'fjcloud-tfstate-\$\{ENV\}' "provision uses same tfstate bucket pattern as validate"
assert_file_contains "$provision_file" 'fjcloud-releases-\$\{ENV\}' "provision uses same releases bucket pattern as validate"
assert_file_contains "$provision_file" 'fjcloud-tflock' "provision uses same DynamoDB table name as validate"
assert_file_contains "$provision_file" '/fjcloud/\$\{ENV\}/database_url' "provision uses same SSM param path as validate"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

test_summary "Provision Bootstrap Static Tests"
