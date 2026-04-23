#!/usr/bin/env bash
# Static contract tests for ops/scripts/validate_bootstrap.sh
# TDD red phase for Task 4 — Production Bootstrap Parity
#
# These tests validate that validate_bootstrap.sh has correct structural
# checks for all prerequisites (AWS bootstrap resources plus Cloudflare
# public DNS credentials) across both environments.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

bootstrap_file="ops/scripts/validate_bootstrap.sh"

echo ""
echo "=== Bootstrap Validation Static Tests ==="
echo ""

# ---------------------------------------------------------------------------
# File existence and basics
# ---------------------------------------------------------------------------

echo "--- validate_bootstrap.sh: file and arg validation ---"
assert_file_exists "$bootstrap_file" "validate_bootstrap.sh exists"
assert_file_contains "$bootstrap_file" 'set -euo pipefail' "validate_bootstrap.sh uses strict mode"
assert_file_contains "$bootstrap_file" 'Usage: validate_bootstrap\.sh <env>' "validate_bootstrap.sh documents usage"
assert_file_contains "$bootstrap_file" '"staging" && "\$ENV" != "prod"' "validate_bootstrap.sh validates env is staging|prod"

# ---------------------------------------------------------------------------
# S3 tfstate bucket checks
# ---------------------------------------------------------------------------

echo ""
echo "--- validate_bootstrap.sh: S3 tfstate bucket ---"
assert_file_contains "$bootstrap_file" 'fjcloud-tfstate-\$\{ENV\}' "checks env-specific tfstate bucket name"
assert_file_contains "$bootstrap_file" 'aws s3api head-bucket' "uses head-bucket to verify tfstate bucket exists"
assert_file_contains "$bootstrap_file" 'get-bucket-versioning.*TFSTATE_BUCKET' "checks tfstate bucket versioning via variable"
assert_file_contains "$bootstrap_file" 'Enabled' "validates versioning is Enabled"
assert_file_contains "$bootstrap_file" 'get-bucket-encryption.*TFSTATE_BUCKET' "checks tfstate bucket encryption via variable"
assert_file_contains "$bootstrap_file" 'get-public-access-block.*TFSTATE_BUCKET' "checks tfstate bucket public access block via variable"

# ---------------------------------------------------------------------------
# S3 releases bucket checks
# ---------------------------------------------------------------------------

echo ""
echo "--- validate_bootstrap.sh: S3 releases bucket ---"
assert_file_contains "$bootstrap_file" 'fjcloud-releases-\$\{ENV\}' "checks env-specific releases bucket name"
assert_file_contains "$bootstrap_file" 'aws s3api head-bucket.*RELEASES_BUCKET' "uses head-bucket to verify releases bucket exists via variable"
assert_file_contains "$bootstrap_file" 'get-bucket-versioning.*RELEASES_BUCKET' "checks releases bucket versioning via variable"
assert_file_contains "$bootstrap_file" 'get-public-access-block.*RELEASES_BUCKET' "checks releases bucket public access block via variable"

# ---------------------------------------------------------------------------
# DynamoDB lock table check
# ---------------------------------------------------------------------------

echo ""
echo "--- validate_bootstrap.sh: DynamoDB lock table ---"
assert_file_contains "$bootstrap_file" 'fjcloud-tflock' "checks for DynamoDB lock table"
assert_file_contains "$bootstrap_file" 'aws dynamodb describe-table' "uses describe-table to verify lock table exists"
assert_file_contains "$bootstrap_file" 'LockID' "validates lock table has LockID key"

# ---------------------------------------------------------------------------
# SSM parameter checks
# ---------------------------------------------------------------------------

echo ""
echo "--- validate_bootstrap.sh: SSM parameters ---"
assert_file_contains "$bootstrap_file" '/fjcloud/\$\{ENV\}/database_url' "checks env-specific database_url SSM param"
assert_file_contains "$bootstrap_file" 'aws ssm get-parameter' "uses get-parameter to verify SSM params exist"
assert_file_contains "$bootstrap_file" 'SecureString' "validates database_url is SecureString type"

# ---------------------------------------------------------------------------
# Cloudflare public DNS check
# ---------------------------------------------------------------------------

echo ""
echo "--- validate_bootstrap.sh: Cloudflare public DNS ---"
assert_file_contains "$bootstrap_file" 'CLOUDFLARE_API_TOKEN' "checks CLOUDFLARE_API_TOKEN exists"
assert_file_contains "$bootstrap_file" 'CLOUDFLARE_ZONE_ID' "checks CLOUDFLARE_ZONE_ID exists"
assert_file_contains "$bootstrap_file" 'CLOUDFLARE_EDIT_READ_ZONE_DNS_API_TOKEN_FLAPJACK_FOO' "checks flapjack.foo Cloudflare token alias exists"
assert_file_contains "$bootstrap_file" 'CLOUDFLARE_ZONE_ID_FLAPJACK_FOO' "checks flapjack.foo Cloudflare zone-id alias exists"
assert_file_contains "$bootstrap_file" 'api.cloudflare.com/client/v4/zones' "checks Cloudflare zone API"
assert_file_contains "$bootstrap_file" 'flapjack\.foo' "validates flapjack.foo zone"
assert_file_contains "$bootstrap_file" 'check_fail.*Cloudflare' "fails on Cloudflare DNS credential/zone mismatch"
assert_file_not_contains "$bootstrap_file" 'aws route53 list-hosted-zones-by-name' "does not check Route53 public hosted zone"

# ---------------------------------------------------------------------------
# Output and summary behavior
# ---------------------------------------------------------------------------

echo ""
echo "--- validate_bootstrap.sh: output and summary ---"
assert_file_contains "$bootstrap_file" 'PASS' "reports passing checks"
assert_file_contains "$bootstrap_file" 'FAIL' "reports failing checks"
assert_file_contains "$bootstrap_file" 'exit 1' "exits non-zero on failure"

# ---------------------------------------------------------------------------
# No hardcoded credentials or secrets
# ---------------------------------------------------------------------------

echo ""
echo "--- validate_bootstrap.sh: security ---"
assert_file_not_contains "$bootstrap_file" 'AKIA[A-Z0-9]' "no hardcoded AWS access key IDs"
assert_file_not_contains "$bootstrap_file" 'password=' "no hardcoded passwords"
assert_file_not_contains "$bootstrap_file" 'secret=' "no hardcoded secrets"

# ---------------------------------------------------------------------------
# Cross-environment parity
# ---------------------------------------------------------------------------

echo ""
echo "--- validate_bootstrap.sh: environment parity ---"
assert_file_not_contains "$bootstrap_file" 'fjcloud-tfstate-staging[^$]' "does not hardcode staging bucket — uses \${ENV}"
assert_file_not_contains "$bootstrap_file" 'fjcloud-releases-staging[^$]' "does not hardcode staging releases bucket — uses \${ENV}"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

test_summary "Bootstrap Validation Static Tests"
