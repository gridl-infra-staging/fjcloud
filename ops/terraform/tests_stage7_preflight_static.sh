#!/usr/bin/env bash
# Static contract tests for preflight checks in tests_stage7_runtime_smoke.sh.
# Ensures all required preflight validations are wired and cannot be silently removed.
#
# These tests use grep-based pattern matching against the source file to verify
# that each preflight check exists, uses the correct exit code constant, and
# runs before terraform init.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

runtime_smoke="ops/terraform/tests_stage7_runtime_smoke.sh"

echo ""
echo "=== Stage 7 Preflight Static Contract Tests ==="

echo ""
echo "--- Exit code constants ---"
assert_file_contains "$runtime_smoke" 'EXIT_AWS_CREDS=' "EXIT_AWS_CREDS constant defined"
assert_file_contains "$runtime_smoke" 'EXIT_CLOUDFLARE_DNS=' "EXIT_CLOUDFLARE_DNS constant defined"
assert_file_contains "$runtime_smoke" 'EXIT_NO_ARTIFACT=' "EXIT_NO_ARTIFACT constant defined"
assert_file_contains "$runtime_smoke" 'EXIT_NO_AMI=' "EXIT_NO_AMI constant defined"

echo ""
echo "--- Shared preflight failure helper ---"
assert_file_contains "$runtime_smoke" 'preflight_fail()' "preflight_fail helper function defined"

echo ""
echo "--- AWS credential validation wired ---"
assert_file_contains "$runtime_smoke" 'aws sts get-caller-identity' "Preflight validates AWS credentials via STS"
assert_file_contains "$runtime_smoke" 'assert_aws_credentials_valid' "AWS credential check function exists"
assert_file_contains "$runtime_smoke" 'preflight_fail "\$EXIT_AWS_CREDS"' "AWS credential failure uses EXIT_AWS_CREDS exit code"

echo ""
echo "--- S3 release artifact validation wired ---"
assert_file_contains "$runtime_smoke" 'aws s3api list-objects-v2' "Preflight checks S3 for release artifacts"
assert_file_contains "$runtime_smoke" 'assert_release_artifact_exists' "S3 artifact check function exists"
assert_file_contains "$runtime_smoke" 'preflight_fail "\$EXIT_NO_ARTIFACT"' "Missing artifact failure uses EXIT_NO_ARTIFACT exit code"

echo ""
echo "--- AMI existence validation wired ---"
assert_file_contains "$runtime_smoke" 'aws ec2 describe-images' "Preflight checks for self-owned AMI"
assert_file_contains "$runtime_smoke" 'assert_ami_exists' "AMI existence check function exists"
assert_file_contains "$runtime_smoke" 'preflight_fail "\$EXIT_NO_AMI"' "Missing AMI failure uses EXIT_NO_AMI exit code"

echo ""
echo "--- Cloudflare DNS authority validation wired ---"
assert_file_contains "$runtime_smoke" 'CLOUDFLARE_API_TOKEN' "Preflight reads CLOUDFLARE_API_TOKEN"
assert_file_contains "$runtime_smoke" 'CLOUDFLARE_ZONE_ID' "Preflight reads CLOUDFLARE_ZONE_ID"
assert_file_contains "$runtime_smoke" 'CLOUDFLARE_EDIT_READ_ZONE_DNS_API_TOKEN_FLAPJACK_FOO' "Preflight accepts flapjack.foo token alias"
assert_file_contains "$runtime_smoke" 'CLOUDFLARE_ZONE_ID_FLAPJACK_FOO' "Preflight accepts flapjack.foo zone-id alias"
assert_file_contains "$runtime_smoke" 'api\.cloudflare\.com/client/v4' "Preflight queries Cloudflare API"
assert_file_contains "$runtime_smoke" 'assert_cloudflare_zone_accessible' "Cloudflare zone check function exists"
assert_file_contains "$runtime_smoke" 'preflight_fail "\$EXIT_CLOUDFLARE_DNS"' "Cloudflare DNS failure uses EXIT_CLOUDFLARE_DNS exit code"

echo ""
echo "--- Preflight execution ordering (checks run before terraform init) ---"

check_runs_before_terraform() {
  local pattern="$1"
  local label="$2"
  local check_line tf_line
  check_line=$(rg -n "$pattern" "$runtime_smoke" | head -1 | cut -d: -f1 || true)
  tf_line=$(rg -n 'terraform init' "$runtime_smoke" | head -1 | cut -d: -f1 || true)
  if [[ -n "$check_line" && -n "$tf_line" ]] && (( check_line < tf_line )); then
    pass "$label"
  else
    fail "$label (check at line ${check_line:-?}, terraform init at line ${tf_line:-?})"
  fi
}

check_runs_before_terraform 'assert_aws_credentials_valid' "AWS credential check runs before terraform init"
check_runs_before_terraform 'assert_ami_exists' "AMI existence check runs before terraform init"
check_runs_before_terraform 'assert_release_artifact_exists' "S3 artifact check runs before terraform init"
check_runs_before_terraform 'assert_cloudflare_zone_accessible' "Cloudflare DNS check runs before terraform init"

test_summary "Stage 7 preflight static contract"
